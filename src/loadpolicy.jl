# Explicit load/compile policy object (issue #277, Phase A).
#
# Today every compile/load front door carries its own copy of four decisions:
#
#   1. the `dlopen` flag set (`RTLD_LOCAL` vs `RTLD_GLOBAL`)          — 12 sites
#   2. the panic strategy of the produced artifact (`abort` vs `unwind`)
#      and what the generated `extern "C"` boundary does about it
#   3. whether the loaded handle is registered in `RUST_LIBRARIES`, under what
#      kind of key, whether an existing entry is replaced or kept, and whether
#      `CURRENT_LIB` moves                                            — 8 sites
#   4. the finalizer / ownership policy of the types the artifact produces
#
# Because the policy lives at the call site, the same user-visible construct
# behaves differently depending on which door it came through — an inline
# `rust"""` block is RTLD_LOCAL without `// cargo-deps:` and RTLD_GLOBAL with
# it (#250).  This file introduces one record that names
# those four decisions, plus one named constructor per existing front door, so
# that Phase B can move call sites onto the shared loader one at a time without
# having to agree on the target policy first.
#
# Phase A was strictly additive.  Phase B (#277) makes this file the *only*
# place that opens, registers and unloads a compiled artifact: `load_artifact!`
# / `unload_artifact!` / `alias_artifact!` below own the `dlopen`, the
# `RUST_LIBRARIES` entry, the per-library symbol and return-type tables, the
# function-pointer cache and `CURRENT_LIB`, as one transaction under
# `REGISTRY_LOCK`.  Each named constructor still records the policy of its own
# front door, so a migration is behaviour-neutral at the moment of the swap and
# any later change of policy is one edit in one place.
#
# Related issues: #244 (panic containment), #249 (finalizers), #250 (symbol
# visibility / unload), #252, #255 (failed hot reload empties the registry),
# #269 (follow-up), #251 (registry consolidation).

"""
    SYMBOL_VISIBILITY_RULE

Prose statement of the rule Phase B should apply when choosing `RTLD_GLOBAL`
over `RTLD_LOCAL`.  Kept as data so the tests and the docs quote one text.

The rule: a library is loaded `RTLD_GLOBAL` **only** when other libraries
loaded later must resolve undefined symbols against it.  **No artifact RustCall
loads is in that category, so every policy is `RTLD_LOCAL | RTLD_NOW`** (#277
Phase B2).

Why the category is empty:

* Nothing in `src/` writes a `ccall((:name, "lib"), ...)`. Every call goes
  through a pointer obtained from `Libdl.dlsym` **on a specific handle**, and
  `dlsym` on a handle works identically whether the image was opened LOCAL or
  GLOBAL. The cross-library fallback in `_resolve_call` iterates the handles in
  `RUST_LIBRARIES`, not the process-global namespace, so it keeps working too.
* Every artifact RustCall builds is a self-contained `cdylib`. Under `RTLD_NOW`
  a genuinely unresolved symbol fails at load rather than at first call.
* The ownership helper library (`deps/rust_helpers`) looked like the one
  exception and is not: every user reaches it through `RUST_HELPERS_LIB[]` plus
  `dlsym`, and no artifact links against it.
* PyO3 crates look like an exception and are not: their `Py_*` symbols resolve
  against libpython, which PythonCall has already loaded globally. RustCall's
  own flag does not affect that.

What `RTLD_LOCAL` buys: two `rust\"\"\"` blocks that both export `f` no longer
shadow one another in the process-global namespace, so which one a call reaches
stops depending on load order (#250).

Before B2 the rule was exactly inverted — leaf artifacts were mostly
`RTLD_GLOBAL` and the helper library was `RTLD_LOCAL` — and the split among
inline blocks ran along the dependency axis: no `// cargo-deps:` meant
`RTLD_LOCAL`, `// cargo-deps:` meant `RTLD_GLOBAL`, for the same construct.

`RUSTCALL_DLOPEN_GLOBAL=1` restores the old process-global behaviour for one
release; see `dlopen_flags`.
"""
const SYMBOL_VISIBILITY_RULE = """
RTLD_GLOBAL is for libraries whose symbols other libraries resolve against; \
no artifact RustCall loads is one, because every call goes through dlsym on a \
specific handle, so every artifact is RTLD_LOCAL.\
"""

"""
    LoadPolicy

One explicit record of the load/compile policy for a single compiled artifact.

Construct one through a named constructor (see `inline_rustc_policy`,
`inline_cargo_policy`, `crate_direct_policy`, `helper_library_policy`, and the rest of
`ALL_LOAD_POLICIES`) rather than calling this constructor directly, so that
every front door keeps a name.

# Fields

- `name::String` — the front door this policy describes, for diagnostics.

- `dlopen_flags::UInt32` — the exact flag set handed to `Libdl.dlopen`.
  Subsumes the 12 open-coded flag sets listed in `call_sites`.

- `global_symbols::Bool` — whether the flag set includes `RTLD_GLOBAL`, i.e.
  whether this artifact publishes its symbols into the process-global
  namespace.  See `SYMBOL_VISIBILITY_RULE` for when that is legitimate.

- `panic_strategy::Symbol` — the panic strategy the artifact is *compiled*
  with, one of:
    * `:abort` — RustCall passes `-C panic=abort` (`src/compiler.jl:219`, `:381`);
    * `:unwind` — the artifact is pinned to unwinding;
    * `:cargo_default` — RustCall drives Cargo but pins nothing: the generated
      `[profile.release]` writes only `opt-level`/`lto`
      (`src/cargoproject.jl:126-128`), and the helper library has no profile
      section at all, so the result is *Cargo's default for the profile,
      subject to `CARGO_PROFILE_<PROFILE>_PANIC` from the environment*.
      `build_cargo_project` (`src/cargobuild.jl`) runs Cargo with the Julia
      process environment unless a captured snapshot is replayed through
      `setenv` (the `env` keyword, #272), and `deps/build.jl` always inherits,
      so `CARGO_PROFILE_RELEASE_PANIC=abort` silently produces an aborting
      artifact.  Resolve it with `effective_panic_strategy`;
    * `:crate_profile` — RustCall does **not** control the build: Cargo runs in
      the *user's* crate, so the effective profile (the crate's own
      `[profile.release]`, a workspace profile, `.cargo/config.toml`, or
      `CARGO_PROFILE_RELEASE_PANIC`) decides, and `panic = "abort"` there is
      honoured.  Unknown to Phase A, hence a separate value rather than a
      guess.

- `boundary_catches_panics::Bool` — whether the generated `extern "C"` wrapper
  is expected to wrap the user body in `std::panic::catch_unwind`.  There are
  zero `catch_unwind` in the tree today, so this is `false` everywhere; on the
  `:unwind` paths that means a panic crossing the boundary is undefined
  behaviour (#244).

- `registry::Symbol` — where the loaded handle is recorded:
  `:rust_libraries` (the `RUST_LIBRARIES` dict), `:module_local` (a `Ref` in
  the generated `@rust_crate` module), `:helper_slot` (`RUST_HELPERS_LIB`), or
  `:none`.

- `registry_key_kind::Symbol` — the shape of the key used with
  `:rust_libraries`: `:content_hash` (`rust_<hash>` from the inline paths),
  `:lib_basename` (unused since #278), `:irust_hash` (`irust_<short id>`),
  `:crate_lib_name` (hot reload), or `:none`.

- `registration_mode::Symbol` — `:replace` (assign unconditionally, as the
  five `src/ruststr.jl` sites do) or `:insert_only` (keep an existing entry, as
  `src/generics.jl:250-253` deliberately does behind `if !haskey(...)`).  The
  distinction matters because `_unique_source_name` (`src/compiler.jl:68-72`)
  gives every non-debug compilation the same `rust_code` basename, so the
  generics key collides across instantiations and an unconditional assignment
  would drop the live handle together with its function-pointer cache.

- `sets_current_lib::Bool` — whether the site also moves `CURRENT_LIB[]`.

- `finalizer_frees::Bool` — whether objects produced by this artifact free
  their Rust allocation in their finalizer.  `false` for inline `#[julia]`
  structs (`src/structs.jl:157-159`, `:282-285`, disabled "to diagnose
  segfault"), `true` for `@rust_crate` structs (`src/crate_bindings.jl:550`) —
  opposite lifetime semantics for the same user-visible construct (#249).

- `call_sites::Vector{String}` — the `file:line` sites this policy is intended
  to subsume in Phase B.

- `issues::Vector{Int}` — the open issues caused by this policy's divergence.

- `notes::String` — free-form description of the divergence.
"""
struct LoadPolicy
    name::String
    dlopen_flags::UInt32
    global_symbols::Bool
    panic_strategy::Symbol
    cargo_profile::Symbol
    boundary_catches_panics::Bool
    registry::Symbol
    registry_key_kind::Symbol
    registration_mode::Symbol
    sets_current_lib::Bool
    finalizer_frees::Bool
    call_sites::Vector{String}
    issues::Vector{Int}
    notes::String
end

const _VALID_PANIC_STRATEGIES = (:abort, :unwind, :cargo_default, :crate_profile)
const _VALID_REGISTRIES = (:rust_libraries, :module_local, :helper_slot, :none)
const _VALID_KEY_KINDS = (:content_hash, :lib_basename, :irust_hash, :crate_lib_name, :none)
const _VALID_REGISTRATION_MODES = (:replace, :insert_only)

"""
    LoadPolicy(name; kwargs...) -> LoadPolicy

Keyword constructor with the conservative defaults Phase B should converge on:
`RTLD_LOCAL | RTLD_NOW`, `panic=abort`, registration in `RUST_LIBRARIES` under
a content hash replacing any previous entry, `CURRENT_LIB` untouched, and
finalizers that free.

Every named constructor below overrides whatever its call sites do differently.
"""
function LoadPolicy(name::AbstractString;
                    dlopen_flags::Integer = Libdl.RTLD_LOCAL | Libdl.RTLD_NOW,
                    panic_strategy::Symbol = :abort,
                    cargo_profile::Symbol = :release,
                    boundary_catches_panics::Bool = false,
                    registry::Symbol = :rust_libraries,
                    registry_key_kind::Symbol = :content_hash,
                    registration_mode::Symbol = :replace,
                    sets_current_lib::Bool = false,
                    finalizer_frees::Bool = true,
                    call_sites::AbstractVector{<:AbstractString} = String[],
                    issues::AbstractVector{<:Integer} = Int[],
                    notes::AbstractString = "")
    panic_strategy in _VALID_PANIC_STRATEGIES ||
        throw(ArgumentError("invalid panic_strategy $(panic_strategy); expected one of $(_VALID_PANIC_STRATEGIES)"))
    registry in _VALID_REGISTRIES ||
        throw(ArgumentError("invalid registry $(registry); expected one of $(_VALID_REGISTRIES)"))
    registry_key_kind in _VALID_KEY_KINDS ||
        throw(ArgumentError("invalid registry_key_kind $(registry_key_kind); expected one of $(_VALID_KEY_KINDS)"))
    registration_mode in _VALID_REGISTRATION_MODES ||
        throw(ArgumentError("invalid registration_mode $(registration_mode); expected one of $(_VALID_REGISTRATION_MODES)"))
    if registry !== :rust_libraries && registry_key_kind !== :none
        throw(ArgumentError("registry_key_kind must be :none unless registry is :rust_libraries"))
    end
    flags = UInt32(dlopen_flags)
    return LoadPolicy(String(name), flags,
                      (flags & UInt32(Libdl.RTLD_GLOBAL)) != 0,
                      panic_strategy, cargo_profile, boundary_catches_panics,
                      registry, registry_key_kind, registration_mode, sets_current_lib,
                      finalizer_frees,
                      String[String(s) for s in call_sites],
                      Int[Int(i) for i in issues],
                      String(notes))
end

# ---------------------------------------------------------------------------
# Named constructors: one per front door that exists on current `main`.
# Each reproduces today's behaviour so a Phase B migration is behaviour-neutral
# at the moment of the swap.
# ---------------------------------------------------------------------------

"""
    inline_rustc_policy() -> LoadPolicy

Inline `rust\"\"\"...\"\"\"` block with **no** `// cargo-deps:`, compiled straight by
`rustc`.  Covers the path on both cache states — a disk-cache hit
(`src/cache.jl:270`, registered at `src/ruststr.jl:251`) and a cache miss
(`src/ruststr.jl:284`, registered at `:291`) both load `RTLD_LOCAL`, so
visibility does **not** depend on the cache.  Compiled with `-C panic=abort`
(`src/compiler.jl:381`).

The visibility divergence runs along the *dependency* axis, not the cache axis:
this door is `RTLD_LOCAL` while `inline_cargo_policy` — the same `rust\"\"\"`
construct that happens to declare `// cargo-deps:` — is `RTLD_GLOBAL` on both
of its cache states (#250).
"""
inline_rustc_policy() = LoadPolicy("inline-rustc";
    dlopen_flags = Libdl.RTLD_LOCAL | Libdl.RTLD_NOW,
    panic_strategy = :unwind,
    boundary_catches_panics = true,
    registry = :rust_libraries,
    registry_key_kind = :content_hash,
    registration_mode = :replace,
    sets_current_lib = true,
    finalizer_frees = true,
    call_sites = ["src/cache.jl:270", "src/ruststr.jl:251",
                  "src/ruststr.jl:284", "src/ruststr.jl:291",
                  "src/compiler.jl:381", "src/structs.jl:282-285"],
    issues = [244, 249, 250],
    notes = "RTLD_LOCAL on both cache states, as every policy is since B2; " *
            "inline #[julia] struct finalizers free, as crate ones always " *
            "have (B4).")

"""
    inline_cargo_policy() -> LoadPolicy

Inline `rust\"\"\"...\"\"\"` block carrying `// cargo-deps:`, built through a
generated Cargo project.

Covers both cache states: the Cargo cache hit (`src/ruststr.jl:386`,
registered at `:389`) and the fresh build (`:419`, registered at `:426`) both
load `RTLD_GLOBAL`, so — as with `inline_rustc_policy` — visibility does not
depend on the cache.  The axis along which visibility differs is whether the
block declares `// cargo-deps:` (#250).

The generated `Cargo.toml` writes only `opt-level`/`lto`
(`src/cargoproject.jl:126-128`) and never pins `panic`, so the strategy is
`:cargo_default`: Cargo's release default (`unwind`) *unless*
`CARGO_PROFILE_RELEASE_PANIC` is set in the Julia process, which
`build_cargo_project` inherits (`src/cargobuild.jl` runs Cargo with the
process environment unless a snapshot `env` is replayed, #272).  Either way the direct `rustc` path aborts and this one may not, and
no boundary catches an unwind (#244).  Use `effective_panic_strategy` to
resolve it; Phase B should pin `panic` in the generated manifest.
"""
inline_cargo_policy() = LoadPolicy("inline-cargo";
    dlopen_flags = Libdl.RTLD_LOCAL | Libdl.RTLD_NOW,
    panic_strategy = :unwind,
    cargo_profile = :release,
    boundary_catches_panics = true,
    registry = :rust_libraries,
    registry_key_kind = :content_hash,
    sets_current_lib = true,
    finalizer_frees = true,
    call_sites = ["src/ruststr.jl:386", "src/ruststr.jl:389",
                  "src/ruststr.jl:409", "src/ruststr.jl:419",
                  "src/ruststr.jl:426", "src/cargobuild.jl:25-67",
                  "src/cargoproject.jl:126-128"],
    issues = [244, 250],
    notes = "Cargo path takes Cargo's release default (unwind, or abort under " *
            "CARGO_PROFILE_RELEASE_PANIC) while the rustc path always aborts.")

"""
    crate_direct_policy() -> LoadPolicy

`@rust_crate` for a crate that already declares `crate-type = ["cdylib"]`, so
RustCall builds it in place: `src/crate_bindings.jl:852` calls
`build_crate_directly`, which points a `CargoProject` at `info.path` and runs
Cargo there (`:914-925`).  The Cargo root is then the **user's** manifest, so
their `[profile.release] panic = "abort"`, a workspace profile,
`.cargo/config.toml` or `CARGO_PROFILE_RELEASE_PANIC` all decide — hence
`:crate_profile`, which `effective_panic_strategy` deliberately leaves
unresolved.  Phase B must read the effective profile (`cargo metadata` /
`cargo config get`) or force the strategy explicitly (#244).

Loading and ownership are shared with `crate_wrapper_policy`.  The generated
module still keeps its own generation record — that is how its wrappers reach
the handle without a registry lookup per call — but the handle is
*published through `load_artifact!`* since #277 Phase B5, so it appears in
`RUST_LIBRARIES` under `crate_library_name(info)` and `unload_library` can see
it.  The module also captures the artifact's liveness flag, which is what makes
its struct finalizers safe against an unload (#249).
"""
crate_direct_policy() = LoadPolicy("rust-crate-direct";
    dlopen_flags = Libdl.RTLD_LOCAL | Libdl.RTLD_NOW,
    panic_strategy = :crate_profile,
    cargo_profile = :release,
    boundary_catches_panics = true,
    registry = :rust_libraries,
    registry_key_kind = :crate_lib_name,
    sets_current_lib = false,
    finalizer_frees = true,
    call_sites = ["src/crate_bindings.jl:344", "src/crate_bindings.jl:550",
                  "src/crate_bindings.jl:852", "src/crate_bindings.jl:914-925",
                  "src/crate_bindings.jl:1360"],
    issues = [244, 249, 250],
    notes = "Cargo runs with the user's manifest as the root, so the panic " *
            "strategy is whatever their effective profile says; the generated " *
            "boundary catches regardless.")

"""
    crate_wrapper_policy() -> LoadPolicy

`@rust_crate` for a crate without `cdylib`, where RustCall generates a wrapper
crate around it and builds *that* (`src/crate_bindings.jl:854-868`).  The Cargo
root is then RustCall's own generated manifest, whose `[profile.release]` sets
only `opt-level`/`lto` (`src/crate_bindings.jl:266-269`) and pins no `panic` —
so this door is `:cargo_default`, exactly like `inline_cargo_policy`: Cargo's
release default unless `CARGO_PROFILE_RELEASE_PANIC` is set in the inherited
environment.  Resolve with `effective_panic_strategy`; Phase B should pin
`panic` in the generated wrapper manifest.

The two `@rust_crate` build paths therefore have different panic semantics for
the same user-visible macro, chosen by `crate_has_cdylib` (#244).  Everything
else — `RTLD_GLOBAL`, the module-local handle, freeing finalizers — matches
`crate_direct_policy`.
"""
crate_wrapper_policy() = LoadPolicy("rust-crate-wrapper";
    dlopen_flags = Libdl.RTLD_LOCAL | Libdl.RTLD_NOW,
    panic_strategy = :unwind,
    cargo_profile = :release,
    boundary_catches_panics = true,
    registry = :rust_libraries,
    registry_key_kind = :crate_lib_name,
    sets_current_lib = false,
    finalizer_frees = true,
    call_sites = ["src/crate_bindings.jl:266-269", "src/crate_bindings.jl:344",
                  "src/crate_bindings.jl:550", "src/crate_bindings.jl:854-868",
                  "src/crate_bindings.jl:1360"],
    issues = [244, 249, 250],
    notes = "RustCall's generated wrapper manifest is the Cargo root and pins " *
            "no panic, so this @rust_crate path takes Cargo's default while " *
            "the direct-cdylib path takes the user's profile.")

"""
    helper_library_policy() -> LoadPolicy

The ownership helper library `deps/rust_helpers`, loaded by
`src/memory.jl:215` and `:321` into `RUST_HELPERS_LIB`.

It looked like the one library other artifacts could legitimately need to
resolve symbols against, and is not: every user goes through
`RUST_HELPERS_LIB[]` plus `dlsym` (`src/memory.jl`), and no artifact links
against it, so nothing would resolve anything against it even if it were
`RTLD_GLOBAL`.  `SYMBOL_VISIBILITY_RULE`'s "provides symbols to other
artifacts" category is therefore empty, and this policy stays `RTLD_LOCAL`
(#277 Phase B2).

Panic strategy is `:cargo_default`, not `:abort`: the helper library is built by
`deps/build.jl:97-98` with a plain `cargo build --release --manifest-path ...`,
and `deps/rust_helpers/Cargo.toml` (9 lines, `[package]`/`[lib]`/`[dependencies]`
only) declares no `[profile.release]` and therefore no `panic` key, so Cargo's
release default (`unwind`) applies — unless `CARGO_PROFILE_RELEASE_PANIC` is set
in the environment `Pkg.build` inherits, in which case the same source produces
an aborting artifact.  Either way no `catch_unwind` boundary contains it (#244);
`effective_panic_strategy` resolves the value.
"""
helper_library_policy() = LoadPolicy("helper-library";
    dlopen_flags = Libdl.RTLD_LOCAL | Libdl.RTLD_NOW,
    panic_strategy = :unwind,
    cargo_profile = :release,
    boundary_catches_panics = true,
    registry = :helper_slot,
    registry_key_kind = :none,
    sets_current_lib = false,
    finalizer_frees = true,
    call_sites = ["src/memory.jl:215", "src/memory.jl:321",
                  "deps/build.jl:97-98", "deps/rust_helpers/Cargo.toml"],
    issues = [244, 250],
    notes = "Every user reaches it through RUST_HELPERS_LIB[] and dlsym and " *
            "nothing links against it, so RTLD_LOCAL is right after all " *
            "(B2); built by plain `cargo build --release`, so it takes " *
            "Cargo's release default like the other Cargo-backed artifacts, " *
            "environment overrides included.")

"""
    generics_policy() -> LoadPolicy

Monomorphized generic instantiation, registered under
`rust_generic_<artifact_short_id>` and never touching `CURRENT_LIB`.

The key used to be `basename(lib_path)`. `_unique_source_name`
(`src/compiler.jl`) returns the fixed base name `rust_code` whenever debug mode
is off, so every instantiation compiled into its own temp directory yielded the
same `librust_code` basename and they all collided on one `RUST_LIBRARIES`
entry. Since #278 Phase B the key is the artifact identity of the
instantiation (`_monomorphization_id`), so distinct instantiations are distinct
entries.

Registration mode stays `:insert_only`: the entry is written only
`if !haskey(RUST_LIBRARIES, lib_name)`. With a content key a second write would
be the same library anyway, and replacing the entry would swap the live handle
and throw away the accumulated function-pointer cache.
"""
generics_policy() = LoadPolicy("generics-monomorphization";
    dlopen_flags = Libdl.RTLD_LOCAL | Libdl.RTLD_NOW,
    panic_strategy = :unwind,
    boundary_catches_panics = true,
    registry = :rust_libraries,
    registry_key_kind = :content_hash,
    registration_mode = :insert_only,
    sets_current_lib = false,
    finalizer_frees = false,
    call_sites = ["src/generics.jl (monomorphize_function)"],
    issues = [247, 250],
    notes = "Keyed by the monomorphization artifact identity since #278; " *
            "written only when absent, unlike every other RUST_LIBRARIES writer.")

"""
    irust_policy() -> LoadPolicy

`@irust` snippet compilation, registered under an `irust_<artifact_short_id>`
key together with the `IRUST_FUNCTIONS` entry. Since #278 the snippet's identity
is `artifact_key` of an `ArtifactId` over the source and the argument types it
is compiled for; it used to be Julia's session-randomized `hash`.
"""
irust_policy() = LoadPolicy("irust";
    dlopen_flags = Libdl.RTLD_LOCAL | Libdl.RTLD_NOW,
    panic_strategy = :unwind,
    boundary_catches_panics = false,
    registry = :rust_libraries,
    registry_key_kind = :irust_hash,
    sets_current_lib = false,
    finalizer_frees = false,
    call_sites = ["src/ruststr.jl (_compile_and_call_irust)"],
    issues = [250, 278],
    notes = "IRUST_FUNCTIONS is dropped with the library by " *
            "unload_artifact! since B1, so an unloaded snippet leaves no memo " *
            "behind.")

"""
    hot_reload_policy() -> LoadPolicy

Hot reload of a `@rust_crate` crate (`src/hot_reload.jl:205`, re-registered at
`:210`).  The rebuild happens outside `REGISTRY_LOCK`, and a failed rebuild
currently leaves the registry without the previous entry (#255).

Like `crate_direct_policy`, the panic strategy is `:crate_profile`: `rebuild_crate`
runs `cargo build --release --manifest-path <user crate>` against their crate
(`src/hot_reload.jl:264`), so their profile decides.
"""
hot_reload_policy() = LoadPolicy("hot-reload";
    dlopen_flags = Libdl.RTLD_LOCAL | Libdl.RTLD_NOW,
    panic_strategy = :crate_profile,
    boundary_catches_panics = true,
    registry = :rust_libraries,
    registry_key_kind = :crate_lib_name,
    registration_mode = :replace,
    sets_current_lib = false,
    finalizer_frees = true,
    call_sites = ["src/hot_reload.jl:205", "src/hot_reload.jl:210",
                  "src/hot_reload.jl:264"],
    issues = [244, 250, 255],
    notes = "Registration is not transactional with the rebuild, so a failed " *
            "rebuild can leave the registry without the previous entry.")

"""
    llvm_policy() -> LoadPolicy

The deprecated LLVM IR path (`src/llvmcodegen.jl:347`).  Loads `RTLD_GLOBAL`
and does not register in `RUST_LIBRARIES` at all.  Scheduled for removal with
#265 Phase 2; recorded here only so the inventory is complete.
"""
llvm_policy() = LoadPolicy("llvm-ir";
    dlopen_flags = Libdl.RTLD_LOCAL | Libdl.RTLD_NOW,
    panic_strategy = :abort,
    boundary_catches_panics = false,
    registry = :none,
    registry_key_kind = :none,
    sets_current_lib = false,
    finalizer_frees = false,
    call_sites = ["src/llvmcodegen.jl:347"],
    issues = [250],
    notes = "Deprecated path (#265 Phase 2); handle is never registered.")

"""
    ALL_LOAD_POLICIES

Every named policy, in the order the inventory in the #277 PR body lists them.
Used by `test/test_loadpolicy.jl` to pin down the current divergences.
"""
const ALL_LOAD_POLICIES = (
    inline_rustc_policy,
    inline_cargo_policy,
    crate_direct_policy,
    crate_wrapper_policy,
    helper_library_policy,
    generics_policy,
    irust_policy,
    hot_reload_policy,
    llvm_policy,
)

# ---------------------------------------------------------------------------
# Accessors — the API Phase B call sites will use instead of open-coding.
# ---------------------------------------------------------------------------

"""
    DLOPEN_GLOBAL_OVERRIDE

Whether `RUSTCALL_DLOPEN_GLOBAL` was set in the environment at `__init__`.

**Deprecated escape hatch, for one minor release.**  Before #277 Phase B2 most
artifacts were opened `RTLD_GLOBAL`, so a block could reach another block's
`#[no_mangle]` symbol through the process-global namespace rather than through
its own handle.  That is exactly the shadowing #250 is about, and it is not a
supported way to call across blocks — `_resolve_call`'s cross-library search
is.  Code that depended on it can set `RUSTCALL_DLOPEN_GLOBAL=1` to get the old
behaviour while it is being fixed; a single `@warn` names the issue.

Read once, at `__init__`: a load policy must not change halfway through a
session, or two artifacts of one program would disagree about the namespace
they published into.
"""
const DLOPEN_GLOBAL_OVERRIDE = Ref(false)
const _DLOPEN_GLOBAL_WARNED = Ref(false)

# Called from `RustCall.__init__`.
function _init_dlopen_global_override!(env = ENV)
    value = strip(String(get(env, "RUSTCALL_DLOPEN_GLOBAL", "")))
    DLOPEN_GLOBAL_OVERRIDE[] = value in ("1", "true", "TRUE", "yes", "on")
    _DLOPEN_GLOBAL_WARNED[] = false
    return DLOPEN_GLOBAL_OVERRIDE[]
end

"""
    dlopen_flags(policy::LoadPolicy) -> UInt32

The flag set to hand to `Libdl.dlopen`: `policy.dlopen_flags`, which is
`RTLD_LOCAL | RTLD_NOW` for every policy since #277 Phase B2
(`SYMBOL_VISIBILITY_RULE`).

`RTLD_GLOBAL` is ORed in when `RUSTCALL_DLOPEN_GLOBAL` was set at `__init__`,
with one `@warn` per session naming the issue.  On Windows `LoadLibrary` has no
LOCAL/GLOBAL distinction, so neither the flag nor the override changes anything
there.
"""
function dlopen_flags(policy::LoadPolicy)
    DLOPEN_GLOBAL_OVERRIDE[] || return policy.dlopen_flags
    if !_DLOPEN_GLOBAL_WARNED[]
        _DLOPEN_GLOBAL_WARNED[] = true
        @warn """
        RUSTCALL_DLOPEN_GLOBAL is set: every compiled artifact is being opened \
        RTLD_GLOBAL, publishing its symbols into the process-global namespace.

        That is the pre-#250 behaviour, in which two `rust\"\"\"` blocks that \
        both export `f` shadow one another and which one a call reaches depends \
        on load order. It is deprecated and will be removed in a future \
        release. Calling across blocks does not need it — `@rust f(...)` \
        searches the loaded libraries by handle.

        See https://github.com/AtelierArith/RustCall.jl/issues/250
        """
    end
    return policy.dlopen_flags | UInt32(Libdl.RTLD_GLOBAL)
end

"""
    uses_global_symbols(policy::LoadPolicy) -> Bool

Whether this policy publishes the artifact's symbols process-globally.

`false` for every policy since #277 Phase B2 (`SYMBOL_VISIBILITY_RULE`). This
reports the *policy*, not the deprecated `RUSTCALL_DLOPEN_GLOBAL` override,
which `dlopen_flags` applies on top.
"""
uses_global_symbols(policy::LoadPolicy) = policy.global_symbols

"""
    rustc_panic_flags(policy::LoadPolicy) -> Vector{String}

The `rustc` arguments implied by the policy's panic strategy: `["-C",
"panic=abort"]` for `:abort`, `["-C", "panic=unwind"]` for `:unwind`, and
`missing` for `:cargo_default` and `:crate_profile`, where Cargo drives the
build and RustCall does not invoke `rustc` itself.

`:unwind` is passed explicitly rather than left to rustc's default so that the
strategy is stated at every compile site, and so that the flag list of a policy
is evidence of what was built (the panic parity test compares the two inline
doors through this function).
"""
function rustc_panic_flags(policy::LoadPolicy)
    policy.panic_strategy in (:crate_profile, :cargo_default) && return missing
    return ["-C", "panic=$(policy.panic_strategy)"]
end

"""
    cargo_profile_panic_line(policy::LoadPolicy) -> Union{String, Nothing}

The line the generated `[profile.release]` section needs to honour the policy's
panic strategy, or `nothing` when the Cargo default already matches.
`src/cargoproject.jl` emits no such line today, which is why the Cargo path
unwinds (#244).

`:unwind` and `:abort` are both **pinned**, so both produce a line.  Writing
`panic = "unwind"` explicitly even though it is Cargo's release default is the
point: without it, `CARGO_PROFILE_RELEASE_PANIC=abort` in the caller's
environment silently produces a library whose `catch_unwind` boundary can never
fire, and the same source aborts the Julia session instead of raising
`RustPanicError` (#244).  A manifest key beats the environment variable.

Returns `nothing` for `:cargo_default` — "whatever Cargo decides" is by
definition not a line to write, and no RustCall-owned door carries that value
any more.

Returns `missing` for `:crate_profile`: RustCall generates no `Cargo.toml` for
those doors — the manifest is the user's — so there is no line for it to write.
A crate that pins `panic = "abort"` itself aborts on a panic, which is the
user's decision and is documented as such.
"""
function cargo_profile_panic_line(policy::LoadPolicy)
    policy.panic_strategy === :crate_profile && return missing
    policy.panic_strategy === :cargo_default && return nothing
    return "panic = \"$(policy.panic_strategy)\""
end

"""
    cargo_panic_env_var(policy::LoadPolicy) -> String

The `CARGO_PROFILE_<PROFILE>_PANIC` variable that overrides this policy's panic
strategy, derived from `policy.cargo_profile` — `CARGO_PROFILE_RELEASE_PANIC`
for every Cargo-backed door today.
"""
cargo_panic_env_var(policy::LoadPolicy) =
    "CARGO_PROFILE_$(uppercase(String(policy.cargo_profile)))_PANIC"

"""
    effective_panic_strategy(policy::LoadPolicy; env = ENV) -> Symbol
    effective_panic_strategy(policy::LoadPolicy, snapshot_env) -> Symbol

Resolve `policy.panic_strategy` against the environment a build would inherit.

- `:abort` and `:unwind` are pinned by RustCall and returned unchanged.
- `:cargo_default` is resolved by reading `cargo_panic_env_var(policy)` out of
  the environment: `"abort"` gives `:abort`, `"unwind"` gives `:unwind`, and
  anything else — unset, empty, unrecognised — gives `:unwind`, Cargo's default
  for the `release` profile.  Both doors that carry `:cargo_default` let the
  Julia process environment reach the build (`src/cargobuild.jl` only calls
  `setenv` to replay a captured snapshot, #272; `deps/build.jl:97-98` never
  does), so `CARGO_PROFILE_RELEASE_PANIC=abort` really does change the
  artifact.
- `:crate_profile` is returned unchanged: the environment is only one of the
  inputs there, and the user's manifest — which Phase A does not read — can
  pin `panic`.  Still unknowable without reading it.

# Which environment

**The `env = ENV` default answers for an artifact built in *this* process, and
only for that.**  A cached or reloaded artifact was built under the environment
that was live at *build* time, which may differ from the current one, so
resolving it against `ENV` can report the opposite strategy from what the `.so`
on disk actually does.  For those, the caller MUST pass the environment
captured at build time — PR #272 records it on `RustBlockSnapshot.cargo_env` as
serialized `KEY=VALUE` text, one entry per line — using the second method:

    effective_panic_strategy(policy, snapshot.cargo_env)

which accepts that text (parsed by `parse_cargo_env_snapshot`) or any
`AbstractDict`.  Never resolve a cached artifact against the live `ENV`.

The related cache-*identity* problem — the Cargo cache key at
`src/ruststr.jl:380-386` not covering the panic setting, so two artifacts built
under different `CARGO_PROFILE_*` values share a key — is closed by #272 adding
the `CARGO_PROFILE_` allowlist to `_cargo_block_identity`; the structural fix is
tracked in #278.  Phase A only models the resolution, not the key.
"""
function effective_panic_strategy(policy::LoadPolicy; env = ENV)
    policy.panic_strategy === :cargo_default || return policy.panic_strategy
    raw = get(env, cargo_panic_env_var(policy), "")
    value = lowercase(strip(String(raw)))
    value == "abort" && return :abort
    return :unwind
end

effective_panic_strategy(policy::LoadPolicy, snapshot_env::Union{AbstractDict, AbstractString}) =
    effective_panic_strategy(policy; env = _as_env(snapshot_env))

"""
    parse_cargo_env_snapshot(text::AbstractString) -> Dict{String, String}

Parse a serialized build-time environment snapshot — one `KEY=VALUE` per line,
the shape PR #272 stores in `RustBlockSnapshot.cargo_env` — into a dictionary
suitable as the `env` of `effective_panic_strategy`.

Blank lines and lines without `=` are skipped; the value keeps everything after
the first `=`, so `KEY=a=b` yields `"a=b"`.  Surrounding whitespace is trimmed
from the key only, since a value's whitespace can be significant.
"""
_as_env(env::AbstractDict) = env
_as_env(env::AbstractString) = parse_cargo_env_snapshot(env)

function parse_cargo_env_snapshot(text::AbstractString)
    out = Dict{String, String}()
    for line in eachsplit(text, '\n')
        entry = strip(line)
        isempty(entry) && continue
        sep = findfirst(isequal('='), entry)
        sep === nothing && continue
        key = strip(entry[1:prevind(entry, sep)])
        isempty(key) && continue
        out[String(key)] = String(entry[nextind(entry, sep):end])
    end
    return out
end

"""
    requires_catch_unwind_boundary(policy::LoadPolicy; env = ENV) -> Union{Bool, Missing}

Whether a generated `extern "C"` wrapper for this artifact must wrap the user
body in `std::panic::catch_unwind` to keep a panic from crossing the FFI
boundary.  `true` exactly when the artifact unwinds and the boundary does not
already catch — which, with no `CARGO_PROFILE_RELEASE_PANIC` set, is every path
RustCall builds with Cargo today (#244).

Routes through `effective_panic_strategy`, so a `:cargo_default` policy answers
`false` under `CARGO_PROFILE_RELEASE_PANIC=abort`.  Returns **`missing`** for
`:crate_profile`, whose answer depends on the user's manifest.  Callers that
need a decision rather than a fact should use `must_assume_unwind`, which
resolves the unknown conservatively.
"""
function requires_catch_unwind_boundary(policy::LoadPolicy; env = ENV)
    policy.boundary_catches_panics && return false
    strategy = effective_panic_strategy(policy; env)
    strategy === :crate_profile && return missing
    return strategy === :unwind
end

# Same build-time-snapshot contract as effective_panic_strategy: pass the
# captured environment for a cached or reloaded artifact, never the live ENV.
requires_catch_unwind_boundary(policy::LoadPolicy, snapshot_env::Union{AbstractDict, AbstractString}) =
    requires_catch_unwind_boundary(policy; env = _as_env(snapshot_env))

"""
    must_assume_unwind(policy::LoadPolicy; env = ENV) -> Bool

The conservative resolution of `requires_catch_unwind_boundary`: `true` unless
the artifact is known to abort or the boundary already catches.  An unknown
(`:crate_profile`) strategy resolves to `true`, because a boundary that catches
a panic that cannot happen is merely redundant, while a missing boundary on an
unwinding artifact is undefined behaviour (#244).
"""
function must_assume_unwind(policy::LoadPolicy; env = ENV)
    policy.boundary_catches_panics && return false
    return effective_panic_strategy(policy; env) !== :abort
end

must_assume_unwind(policy::LoadPolicy, snapshot_env::Union{AbstractDict, AbstractString}) =
    must_assume_unwind(policy; env = _as_env(snapshot_env))

"""
    registers_in_rust_libraries(policy::LoadPolicy) -> Bool

Whether `register_library!` will write into `RUST_LIBRARIES`.
"""
registers_in_rust_libraries(policy::LoadPolicy) = policy.registry === :rust_libraries

"""
    finalizer_frees(policy::LoadPolicy) -> Bool

Whether objects produced by this artifact free their allocation on finalization
(#249).
"""
finalizer_frees(policy::LoadPolicy) = policy.finalizer_frees

# ---------------------------------------------------------------------------
# Registration — the locking half of the policy (#251).
# ---------------------------------------------------------------------------

"""
    register_library!(policy::LoadPolicy, lib_name::AbstractString,
                      handle::Ptr{Cvoid}) -> String

Record a loaded handle according to `policy`, as one transaction under
`REGISTRY_LOCK`: the `RUST_LIBRARIES` entry, its fresh function-pointer cache
and (when `policy.sets_current_lib`) `CURRENT_LIB[]` are installed together, so
no other task can observe a half-registered library.

`policy.registration_mode` decides what happens when the key is already taken:
`:replace` overwrites the entry (what the five `src/ruststr.jl` sites do),
`:insert_only` leaves the existing handle and its function-pointer cache
untouched (what `src/generics.jl:250-253` does behind `if !haskey(...)`, which
matters because the generics key collides — see `generics_policy`).

Returns `lib_name`.  A no-op returning `lib_name` for policies that do not use
`RUST_LIBRARIES` (`:module_local`, `:helper_slot`, `:none`), so a Phase B call
site can call it unconditionally.

Subsumes the five remaining open-coded `RUST_LIBRARIES[...] = ...` sites:
`_register_manifest` and the `@irust` loader in `src/ruststr.jl`,
`src/generics.jl`, `src/hot_reload.jl`, and the reload alias in
`src/rustmacro.jl` (#272).  The four inline-block sites collapsed into
`_register_manifest`, which publishes the handle together with the manifest's
name-to-symbol mappings so the two cannot be observed apart (#279); a Phase B
`register_library!` has to keep that guarantee, which is what the `symbols`
argument this function will grow is for.  Not called from `src/` yet (Phase A
is additive).
"""
function register_library!(policy::LoadPolicy, lib_name::AbstractString, handle::Ptr{Cvoid})
    name = String(lib_name)
    if !registers_in_rust_libraries(policy)
        return name
    end
    handle == C_NULL && throw(ArgumentError("refusing to register a NULL handle for $(name)"))
    lock(REGISTRY_LOCK) do
        if policy.registration_mode === :insert_only && haskey(RUST_LIBRARIES, name)
            @debug "register_library!: keeping the existing entry" lib_name=name policy=policy.name
            return
        end
        RUST_LIBRARIES[name] = (handle, Dict{String, Ptr{Cvoid}}())
        if policy.sets_current_lib
            CURRENT_LIB[] = name
        end
    end
    return name
end

"""
    unregister_library!(policy::LoadPolicy, lib_name::AbstractString) -> Bool

Remove the `RUST_LIBRARIES` entry, its function-pointer cache and the
library's registry metadata — its name-to-symbol mappings and return-type
hints (`clear_library_metadata!`, #279) — under
`REGISTRY_LOCK`, clearing `CURRENT_LIB[]` if it pointed at `lib_name`.
Returns whether an entry was removed.  Does not `dlclose`: Phase B decides that
together with the unload purge described in #250.

Not called from `src/` yet, so the live unload paths purge the symbol mappings
themselves (`unload_library` in `src/ruststr.jl`, `_reload_library_locked` in
`src/hot_reload.jl`); Phase B (#277) folds them into this one hook.
"""
function unregister_library!(policy::LoadPolicy, lib_name::AbstractString)
    name = String(lib_name)
    registers_in_rust_libraries(policy) || return false
    return lock(REGISTRY_LOCK) do
        removed = haskey(RUST_LIBRARIES, name)
        if removed
            delete!(RUST_LIBRARIES, name)
        end
        clear_library_metadata!(name)
        if CURRENT_LIB[] == name
            CURRENT_LIB[] = ""
        end
        return removed
    end
end

function Base.show(io::IO, policy::LoadPolicy)
    vis = policy.global_symbols ? "RTLD_GLOBAL" : "RTLD_LOCAL"
    print(io, "LoadPolicy(", policy.name, ": ", vis,
          ", panic=", policy.panic_strategy,
          ", registry=", policy.registry,
          "/", policy.registration_mode,
          ", finalizer_frees=", policy.finalizer_frees, ")")
end

# ---------------------------------------------------------------------------
# The one load / unload / alias path (#277 Phase B).
#
# Every front door goes through the three functions below.  They own the
# `dlopen`, the `RUST_LIBRARIES` entry, its function-pointer cache, the
# per-library symbol and return-type tables, `CURRENT_LIB` and the liveness
# flag finalizers capture; a call site supplies only a `LoadPolicy`, a path and
# the metadata the artifact publishes.
# ---------------------------------------------------------------------------

"""
    LoadedArtifact

One loaded shared library, as returned by `load_artifact!`.

# Fields

- `name::String` — the `RUST_LIBRARIES` key the artifact is registered under
  (still meaningful for policies that register nowhere: it names the artifact
  in diagnostics).
- `handle::Ptr{Cvoid}` — the live `dlopen` handle. For an `:insert_only`
  policy that lost the race this is the *existing* handle, not the duplicate
  that was opened and immediately closed.
- `path::String` — the file that was opened.
- `policy::LoadPolicy` — the policy it was opened under.
- `alive::Ref{Bool}` — flipped to `false` by `unload_artifact!` and by a
  `:replace` registration that evicts this artifact. Objects produced by the
  artifact capture this `Ref` at construction so their finalizer can skip a
  call into a `dlclose`d image **without taking a lock or doing a lookup**
  (#249): a finalizer may run while the running thread holds `REGISTRY_LOCK`,
  so it must never take it.
- `assumed_unwind::Bool` — `must_assume_unwind` resolved against the
  environment the artifact was *built* under (`snapshot_env`), recorded at load
  time because the live `ENV` is not evidence about a cached artifact (#244).
"""
struct LoadedArtifact
    name::String
    handle::Ptr{Cvoid}
    path::String
    policy::LoadPolicy
    alive::Ref{Bool}
    assumed_unwind::Bool
    # Which generation of `name` this is. Anything resolved against `handle`
    # belongs to this generation and may be cached with it (#277).
    generation::Int
end

LoadedArtifact(name, handle, path, policy, alive, assumed_unwind) =
    LoadedArtifact(name, handle, path, policy, alive, assumed_unwind, 0)

function Base.show(io::IO, a::LoadedArtifact)
    print(io, "LoadedArtifact(", a.name, " @ ", repr(a.handle),
          ", ", a.policy.name, a.alive[] ? "" : ", dead", ")")
end

"""
    ARTIFACT_ALIVE

`lib_name` → the liveness flag of the artifact currently registered under it.

The flag is a `Ref{Bool}` rather than a registry lookup on purpose: a finalizer
must be able to answer "is my library still loaded?" with a single load of a
captured `Ref`, taking no lock and touching no dictionary (#249).  Flipping the
flag is the *only* thing that makes an object produced by an unloaded library
inert; the object itself is unreachable from here by then.

Guarded by `REGISTRY_LOCK`.  An alias (`alias_artifact!`) shares the flag of
the artifact it aliases, so unloading either name retires both.
"""
const ARTIFACT_ALIVE = Dict{String, Ref{Bool}}()

"""
    artifact_alive_ref(lib_name) -> Ref{Bool}

The liveness flag of `lib_name`, created (as `true`) when the library has none
yet — a library loaded before this session's first `load_artifact!`, or one
registered by a path that predates the loader.

Capture this once, at construction time, into any object whose finalizer calls
back into the library; never look it up from the finalizer.
"""
function artifact_alive_ref(lib_name::AbstractString)
    name = String(lib_name)
    lock(REGISTRY_LOCK) do
        get!(() -> Ref(true), ARTIFACT_ALIVE, name)
    end
end

# Retire the flag of whatever is registered under `name`.  Caller holds
# REGISTRY_LOCK.
function _retire_alive!(name::String)
    old = get(ARTIFACT_ALIVE, name, nothing)
    old === nothing || (old[] = false)
    return nothing
end

# A fresh live flag for a new generation, leaving any previous one alone: the
# image it belongs to may still be mapped and its objects must still free
# through it (`RETIRED_HANDLES`).  Caller holds REGISTRY_LOCK.
function _new_alive!(name::String)
    ref = Ref(true)
    ARTIFACT_ALIVE[name] = ref
    return ref
end

"""
    ARTIFACT_GENERATIONS

`lib_name` → how many times an image has been installed under that name.

The number a snapshot carries. It is what makes "these values came from one
generation" checkable rather than merely intended: a `CallTarget`, an
`ArtifactGeneration` and a crate module's `CrateGeneration` all record it, so a
test — or a future assertion — can compare two snapshots instead of comparing
raw pointers, and the reload stress test can watch for a call that straddled a
swap.

Guarded by `REGISTRY_LOCK`.
"""
const ARTIFACT_GENERATIONS = Dict{String, Int}()

# The generation being installed for `name`. Caller holds REGISTRY_LOCK.
function _next_artifact_generation!(name::String)
    generation = get(ARTIFACT_GENERATIONS, name, 0) + 1
    ARTIFACT_GENERATIONS[name] = generation
    return generation
end

"""
    artifact_generation(lib_name) -> Int

Which generation of `lib_name` is installed now; `0` if none ever was.
"""
artifact_generation(lib_name::AbstractString) =
    lock(() -> get(ARTIFACT_GENERATIONS, String(lib_name), 0), REGISTRY_LOCK)

"""
    CrateGeneration

What a generated `@rust_crate` module knows about the image it calls: the
handle, the liveness flag of that image, and the generation number — as **one
immutable value**.

# Why one value and not three `Ref`s

The module used to keep the handle and the flag in two separate `Ref`s,
written by `_update_handle_mirrors!` under `REGISTRY_LOCK` and read by the
module's wrappers under the module's own lock. Two unrelated locks over two
cells is not a snapshot: a constructor could read the old handle, the writer
could then run, and the constructor would pair that handle with the
*replacement's* liveness flag. The object then believed itself live after the
image it was allocated by had been closed, and its finalizer jumped through an
unmapped destructor.

One immutable record in one `Ref` removes the question. The record is not
`isbits` (it holds the flag), so the `Ref` holds a pointer to it and publishing
a new generation is a single pointer store; a reader's single deref therefore
yields a handle and a flag that were always written together. Readers take no
lock at all.
"""
struct CrateGeneration
    handle::Ptr{Cvoid}
    alive::Base.RefValue{Bool}
    generation::Int
end

CrateGeneration() = CrateGeneration(C_NULL, Ref(false), 0)

"""
    HANDLE_MIRRORS

`lib_name` → the module-local copies of that library's handle and liveness flag
that the loader keeps in sync.

A generated `@rust_crate` module resolves its symbols through its own
generation record rather than through a registry lookup per call — that is the
whole point of the module-local `Ref`. But a raw copy of a handle goes **stale**
the moment the library is replaced or unloaded: a hot reload closes the previous
image, and `unload_library` drops it, after which a raw copy of the handle
would be read against an image nothing points at any more. Registering the
module's `Ref` here lets the transaction that swaps the handle swap the mirror
in the same critical section, so the fast path stays a `Ref` read and can never
point at a closed image (#277 Phase B).

The mirrors survive an unload rather than being dropped with it: a hot reload is
"unload then load under the same name", and the module that registered them is
still there waiting for the new handle.

Guarded by `REGISTRY_LOCK`.
"""
const HANDLE_MIRRORS = Dict{String, Vector{Base.RefValue{CrateGeneration}}}()

"""
    register_handle_mirror!(lib_name, gen_ref)

Keep `gen_ref` — a generated `@rust_crate` module's `_LIB_GEN` — in step with
the library registered as `lib_name`, and set it to what is registered *now*.

Called by the module's `__init__`, **before** it loads the library, so that the
`load_artifact!` transaction is what publishes the first generation: an
assignment after the load would overwrite whatever a concurrent reload had
already published.

Idempotent: a module re-initialised in a new session registers the same `Ref`
again and it is not duplicated.
"""
function register_handle_mirror!(lib_name::AbstractString,
                                 gen_ref::Base.RefValue{CrateGeneration})
    name = String(lib_name)
    lock(REGISTRY_LOCK) do
        mirrors = get!(() -> Base.RefValue{CrateGeneration}[], HANDLE_MIRRORS, name)
        any(m -> m === gen_ref, mirrors) || push!(mirrors, gen_ref)
        entry = get(RUST_LIBRARIES, name, nothing)
        if entry !== nothing
            gen_ref[] = CrateGeneration(entry[1],
                                        get!(() -> Ref(true), ARTIFACT_ALIVE, name),
                                        get(ARTIFACT_GENERATIONS, name, 0))
        end
    end
    return nothing
end

# Publish one generation to every mirror of `name`: one pointer store each, so
# a reader's single deref can never pair one generation's handle with
# another's flag. Caller holds REGISTRY_LOCK.
function _update_handle_mirrors!(name::String, handle::Ptr{Cvoid},
                                 alive::Base.RefValue{Bool}, generation::Int)
    published = CrateGeneration(handle, alive, generation)
    for gen_ref in get(HANDLE_MIRRORS, name, ())
        gen_ref[] = published
    end
    return nothing
end

# The library is gone: a mirror must say so rather than keep a handle that is
# about to be closed. The *mirror* stays registered — a reload under the same
# name fills it in again. Caller holds REGISTRY_LOCK.
function _retire_handle_mirrors!(name::String)
    retired = CrateGeneration(C_NULL, Ref(false), get(ARTIFACT_GENERATIONS, name, 0))
    for gen_ref in get(HANDLE_MIRRORS, name, ())
        gen_ref[] = retired
    end
    return nothing
end

"""
    RetiredImage

An image that has left the registry but is **still mapped**.

Carries what closing it later needs: where it came from, the liveness flag its
objects captured, and the names it was known by (for diagnostics and for
`unload_library(name; close = true)`).
"""
struct RetiredImage
    path::String
    alive::Base.RefValue{Bool}
    names::Vector{String}
    # How many owned opens this image had when it was retired — the number of
    # `dlclose`s the retirement is responsible for, captured **then** rather
    # than read from the live counter later. A concurrent reopen of the same
    # path increments the live counter, and draining "until the counter says
    # zero" would close that reopen's reference too, unmapping an image the
    # program is using (#277).
    owned::Int
end

"""
    alive_ref_for_handle(handle, lib_name) -> Base.RefValue{Bool}

The liveness flag that belongs to **the image `handle` names**, not to whatever
is registered under `lib_name` now. Caller holds `REGISTRY_LOCK`.

This is what a cached pointer needs. `artifact_alive_ref(name)` answers "is the
library called `name` loaded?", and for a pointer resolved a while ago that is
the wrong question: if the library was replaced or unloaded in between, the
name's flag belongs to a *different* image — or, worse, `artifact_alive_ref`
invents a fresh `Ref(true)` for a name nothing is registered under, and an
object holding it believes itself live forever while its destructor points into
an image that has since been closed.

So the flag is found by handle: the registered one when `handle` is still what
`lib_name` resolves to, the retired image's own flag when it has been retired
(that flag is flipped when the image is finally closed, which is exactly when
the pointer stops being callable), and a permanently-false flag when the image
is neither — in which case the object goes inert and leaks rather than calling
into nothing.
"""
function alive_ref_for_handle(handle::Ptr{Cvoid}, lib_name::AbstractString)
    name = String(lib_name)
    entry = get(RUST_LIBRARIES, name, nothing)
    if entry !== nothing && entry[1] == handle
        return get!(() -> Ref(true), ARTIFACT_ALIVE, name)
    end
    retired = get(RETIRED_HANDLES, handle, nothing)
    retired === nothing || return retired.alive
    return DEAD_ARTIFACT
end

"""
    DEAD_ARTIFACT

A liveness flag that is `false` and stays `false`: the answer for a pointer
whose image is neither registered nor retired. Shared, because it is immutable
in practice — nothing ever flips it.
"""
const DEAD_ARTIFACT = Ref(false)

"""
    RETIRED_HANDLES

Every image that has left the registry and is still mapped, keyed by **handle**.

An image leaves the registry two ways — a hot reload replaces it, or
`unload_library` drops it — and neither may close it. In both cases a task can
already hold a function pointer it read out of that image: the pointer was
resolved before the swap, and the call is in flight. Closing the image under it
is a use-after-`dlclose`, which is a segfault. RustCall has no per-call reader
pin that would make closing safe, and adding one would put two atomics on the
hot path of *every* FFI call to guard against something that happens at most
once per reload.

So a retired image stays mapped. Nothing new can enter it — the registry, the
metadata tables, the panic channels and the module mirrors all stop pointing at
it — and the calls already inside finish normally. **Its liveness flag stays
`true`**, so an object allocated by that image still runs its destructor, which
lives in that image and is still mapped: the allocator contract holds by
construction (#249). Only closing the image flips the flag, and only then do
its objects become inert.

Keyed by handle rather than by library name so a record cannot be lost when the
name goes: `unload_library(name)` removes the name, and the image it retired
must remain reclaimable afterwards.

Reclaiming is explicit — `unload_library(name; close = true)`,
`unload_all_libraries(; close = true)` — and is the caller stating that no call
into those images is in flight. A REPL session editing Rust in a loop never
needs it; a long-running process or a test harness does.

Guarded by `REGISTRY_LOCK`.
"""
const RETIRED_HANDLES = Dict{Ptr{Cvoid}, RetiredImage}()

"""
    retired_handles() -> Vector{Ptr{Cvoid}}
    retired_handles(lib_name) -> Vector{Ptr{Cvoid}}

The images that have left the registry and are still mapped: all of them, or
those that were known by `lib_name`.
"""
retired_handles() = lock(() -> collect(keys(RETIRED_HANDLES)), REGISTRY_LOCK)

retired_handles(lib_name::AbstractString) = lock(REGISTRY_LOCK) do
    name = String(lib_name)
    [h for (h, r) in RETIRED_HANDLES if name in r.names]
end

# Record an image that has left the registry. Its liveness flag stays as it is
# — `true` — because the image is still mapped and its objects must still be
# able to free through it. Caller holds REGISTRY_LOCK.
function _record_retired!(handle::Ptr{Cvoid}, names::Vector{String},
                          alive::Union{Nothing, Base.RefValue{Bool}},
                          path::AbstractString = "")
    handle == C_NULL && return nothing
    # Still live under some name (an alias that was not part of this removal):
    # it has not left the registry at all.
    isempty(library_names_for_handle(handle)) || return nothing
    existing = get(RETIRED_HANDLES, handle, nothing)
    # One handle can back several generations over a session — the same file
    # loaded, unloaded and loaded again is the same image, and `dlopen`
    # refcounts it. The record must therefore carry the flag of the generation
    # being retired *now*: keeping an older one would flip the wrong flag when
    # the image is finally closed, leaving live objects believing their library
    # is still there.
    merged = existing === nothing ? copy(names) : existing.names
    if existing !== nothing
        for n in names
            n in merged || push!(merged, n)
        end
    end
    RETIRED_HANDLES[handle] =
        RetiredImage(String(path), alive === nothing ?
                     (existing === nothing ? Ref(true) : existing.alive) : alive,
                     merged, get(OWNED_HANDLES, handle, 0))
    return nothing
end

"""
    close_retired_handles!(handles = retired_handles()) -> Int

Release retired images and return how many records were released.

**The caller guarantees that no call into them is in flight.** Each image's
liveness flag is flipped to `false` first, so an object that outlives it
becomes inert instead of calling into what is about to be unmapped, and then
the image is closed — once, through `close_artifact_handle!`.

An image RustCall did not open is released from the bookkeeping but not
closed: closing it belongs to whoever opened it (`OWNED_HANDLES`).
"""
function close_retired_handles!(handles = retired_handles())
    records = lock(REGISTRY_LOCK) do
        found = Pair{Ptr{Cvoid}, RetiredImage}[]
        for handle in handles
            record = get(RETIRED_HANDLES, handle, nothing)
            record === nothing && continue
            # Flip under the lock, before the close: an object finalized in
            # between must see `false`, not a handle that is about to go.
            record.alive[] = false
            delete!(RETIRED_HANDLES, handle)
            push!(found, handle => record)
        end
        found
    end
    for (handle, record) in records
        # Close once per owned open **this retirement owned**. One image loaded
        # under two names owes two closes, and closing once left the last
        # loader reference unreclaimable. Draining the *live* counter instead
        # would go too far the other way: a task reopening the same path while
        # this loop runs increments that counter, and closing its reference
        # would unmap an image it is about to call (#277).
        for _ in 1:record.owned
            close_artifact_handle!(handle) || break
        end
    end
    return length(records)
end

"""
    artifact_handle_is_owned(handle) -> Bool

Whether RustCall opened this image and may close it.
"""
artifact_handle_is_owned(handle::Ptr{Cvoid}) =
    lock(() -> get(OWNED_HANDLES, handle, 0) > 0, REGISTRY_LOCK)

"""
    artifact_handle_open_count(handle) -> Int

How many times RustCall opened this image and has not yet closed it. `dlopen`
refcounts, so this is how many `dlclose`s the package still owes.
"""
artifact_handle_open_count(handle::Ptr{Cvoid}) =
    lock(() -> get(OWNED_HANDLES, handle, 0), REGISTRY_LOCK)

"""
    DLCLOSE_COUNT

How many `dlclose` calls this session has made, process-wide.

One image can be closed more than once: `dlopen` refcounts, so an image loaded
under two names owes two closes, and this counts each of them.

Closing an image twice is not an error the loader can detect after the fact —
the second `dlclose` decrements a refcount that belongs to someone else, or
unmaps code another name is still pointing at — so the invariant "one open, one
close" is asserted by counting rather than by hoping. `close_artifact_handle!`
is the only place that closes, and `test/test_loadpolicy.jl` reads this
counter to check that unloading a library with an alias closes it once.
"""
const DLCLOSE_COUNT = Threads.Atomic{Int}(0)

"""
    RELOAD_GENERATION

A process-wide, monotonic counter for the paths RustCall opens.

Every freshly built library is copied to `<lib>.<generation>.<ext>` and *that*
copy is opened, so the image already mapped is never the file Cargo is about to
write. The counter is per **process** so a counter restarted with a new
`HotReloadState` cannot collide with a `.1.` file that is still mapped from an
earlier session.
"""
const RELOAD_GENERATION = Threads.Atomic{Int}(0)

"""
    next_reload_generation() -> Int

The next generation. Never repeats within a process.
"""
next_reload_generation() = Threads.atomic_add!(RELOAD_GENERATION, 1) + 1

"""
    generation_path(lib_path, generation) -> String

`libfoo.dylib` → `libfoo.3.dylib`, next to the original.

Living beside the original rather than in a temporary directory matters on
Windows: a DLL resolves its dependencies relative to its own location.
"""
function generation_path(lib_path::AbstractString, generation::Integer)
    dir = dirname(lib_path)
    stem, ext = splitext(basename(lib_path))
    return joinpath(dir, "$(stem).$(generation)$(ext)")
end

"""
    loadable_library_copy(built_path) -> String

A private copy of a freshly built library, for RustCall to open.

**RustCall never maps the file Cargo writes.** Cargo rewrites its output in
place on the next build, and on Windows it cannot: overwriting a mapped DLL
fails with `Access is denied (os error 5)`, so the *build* fails — the whole
crate becomes unbuildable for the rest of the session once anything has loaded
it. Everywhere else the failure is quieter and worse: `dlopen` of a path that is
already mapped hands back the **old** image, so a rebuild silently has no
effect while objects allocated by the old library start being freed by code
from the new one.

Copying to `<lib>.<generation>.<ext>` and opening that leaves Cargo's output
untouched, and makes every load a genuinely distinct file (#255, #277).

Returns the original path when the copy cannot be made, so a platform or a
filesystem that will not take one degrades to the previous behaviour rather
than failing the load.
"""
function loadable_library_copy(built_path::AbstractString)
    built = String(built_path)
    isfile(built) || return built
    copy_path = generation_path(built, next_reload_generation())
    try
        cp(built, copy_path; force = true)
        return copy_path
    catch e
        @debug "Could not copy $(built) for loading; opening it in place" exception = e
        return built
    end
end

"""
    OWNED_HANDLES

The handles RustCall itself opened, and is therefore allowed to close.

`load_artifact!` opens an image and records it here. `adopt_artifact!` does
not: it is handed a handle that somebody else opened — a caller that resolved
one its own way, a test registering a value that was never a real image — and
closing that would be closing something RustCall does not own. On glibc a
`dlclose` of a stale or foreign handle segfaults inside `_dl_close` rather than
returning an error, so "do not close what you did not open" is not a nicety.

It is a **count**, not a set. `dlopen` refcounts: opening the same path twice
returns the same handle and needs two `dlclose`s. A set collapsed those into
one entry, so closing the losing duplicate of an `:insert_only` race deleted
the only record and the winner could then never be closed — the image stayed
mapped forever. One increment per `dlopen` this package performs, one
decrement per close, so the process closes exactly as many times as it opened.

The count is also what makes closing safe under a race: `close_artifact_handle!`
decrements in the same locked step that decides whether to close, so two callers
cannot both decide to perform the last close.

Guarded by `REGISTRY_LOCK`.
"""
const OWNED_HANDLES = Dict{Ptr{Cvoid}, Int}()

"""
    close_artifact_handle!(handle) -> Bool

Close an image RustCall opened, once. The single close point of the package.

Returns whether this call was the one that closed it: `false` for a handle
RustCall does not own (`OWNED_HANDLES`) and for one that has already been
closed.
"""
function close_artifact_handle!(handle::Ptr{Cvoid})
    handle == C_NULL && return false
    # Ownership is checked and *given up* in one locked step, so a handle can
    # be closed at most once however many callers race to close it.
    owned = lock(REGISTRY_LOCK) do
        remaining = get(OWNED_HANDLES, handle, 0)
        remaining == 0 && return false
        remaining == 1 ? delete!(OWNED_HANDLES, handle) :
                         (OWNED_HANDLES[handle] = remaining - 1)
        return true
    end
    owned || return false
    Threads.atomic_add!(DLCLOSE_COUNT, 1)
    Libdl.dlclose(handle)
    return true
end

"""
    library_names_for_handle(handle) -> Vector{String}

Every `RUST_LIBRARIES` name that resolves to `handle`.

One handle legitimately sits under two names (`alias_artifact!`), and both are
the *same* loaded image: unloading either one must therefore remove both and
close once. Removing one and leaving the other behind leaves a name pointing at
code that is about to be unmapped, and closing per name closes an image the
process opened once.

The caller must hold `REGISTRY_LOCK`.
"""
function library_names_for_handle(handle::Ptr{Cvoid})
    names = String[]
    handle == C_NULL && return names
    for (name, (other, _)) in RUST_LIBRARIES
        other == handle && push!(names, name)
    end
    return names
end

"""
    registered_alive_for_handle(handle) -> Union{Base.RefValue{Bool}, Nothing}

The liveness flag already registered for the image `handle` names, under **any**
of its names, or `nothing` when it has none. Caller holds `REGISTRY_LOCK`.

The invariant this serves is *one image, one flag* (#291 item 4). A path can be
loaded under a second name while the first is still live — `dlopen` refcounts
and answers with the same handle — and minting a fresh flag for that second
registration would leave two flags describing one lifetime. `unload_artifact!`
retires the image with **one** of them; the other is dropped from
`ARTIFACT_ALIVE` and never flipped, so every object that captured it believes
itself live after `close = true` has unmapped the code its destructor calls
into. That is a use-after-free reachable without any hot reload: two
`load_artifact!` calls on one path under two names.
"""
function registered_alive_for_handle(handle::Ptr{Cvoid})
    handle == C_NULL && return nothing
    for name in library_names_for_handle(handle)
        ref = get(ARTIFACT_ALIVE, name, nothing)
        ref === nothing || return ref
    end
    return nothing
end

"""
    load_artifact!(policy::LoadPolicy, path;
                   lib_name, symbols = (), return_types = (), eager = (),
                   snapshot_env = nothing,
                   set_current = policy.sets_current_lib) -> LoadedArtifact

Open `path` under `policy` and publish it, as one transaction.

`Libdl.dlopen` runs **outside** `REGISTRY_LOCK` — it executes arbitrary
initialisation code and is slow, and holding the global registry lock across it
would serialise every unrelated `@rust` call.  Everything else happens in a
single locked block, so no task can observe a half-registered library: the
handle, its fresh function-pointer cache (pre-filled from `eager`), the
name-to-symbol mappings (`symbols`, `name => exported symbol`, #279), the
return-type hints (`return_types`, `name => Type`) and `CURRENT_LIB` all become
visible together.  That is what closes the window in which a concurrent
`@rust f(...)` could find the library but not yet know that `f` is exported as
`rustcall_f`.

`policy.registration_mode` decides what happens when the key is taken:

- `:replace` evicts the previous entry.  The evicted image is **retired, not
  closed** (`RETIRED_HANDLES`): a call that started before the swap may still be
  running inside it.  It keeps its own liveness flag, `true`, so objects it
  allocated still free through it — their destructor lives in that image and
  that image is still mapped.  The new generation gets a flag of its own; flags
  are never reused across images.
- `:insert_only` keeps the existing entry, together with its accumulated
  function-pointer cache, and `dlclose`s the duplicate just opened.  Closing
  *that* one is safe because nobody ever saw it: it was opened moments ago by
  this call and lost the race, so no pointer was resolved from it.  Two tasks
  racing on the same path therefore agree on one handle (`src/generics.jl`).

Policies that register nowhere (`:module_local`, `:helper_slot`, `:none`) still
get their `dlopen` from here — that is what makes the flag set one decision —
and come back as a `LoadedArtifact` with a liveness flag of their own.

`snapshot_env` is the environment the artifact was *built* under; it is used
only to resolve `assumed_unwind`.  Pass the captured snapshot for a cached or
reloaded artifact, never the live `ENV` (see `effective_panic_strategy`).

Throws if the load fails, leaving the registry untouched.
"""
function load_artifact!(policy::LoadPolicy, path::AbstractString;
                        lib_name::AbstractString,
                        kwargs...)
    lib_path = String(path)
    handle = Libdl.dlopen(lib_path, dlopen_flags(policy))
    if handle == C_NULL
        throw(RustError("Failed to load $(policy.name) library: $(lib_path)"))
    end
    # This call opened the image, so this package may close it later
    # (`OWNED_HANDLES`). A handle that merely arrives through
    # `adopt_artifact!` is never closed by RustCall.
    lock(REGISTRY_LOCK) do
        OWNED_HANDLES[handle] = get(OWNED_HANDLES, handle, 0) + 1
    end
    # `load_artifact!` opened this handle, so `load_artifact!` owns it: if the
    # registration turns out not to need it (`:insert_only` lost the race), it
    # is this call's job to close it. `adopt_artifact!` never closes a handle
    # it was merely handed.
    return adopt_artifact!(policy, handle; lib_name, path = lib_path,
                           close_duplicate = true, kwargs...)
end

"""
    adopt_artifact!(policy::LoadPolicy, handle::Ptr{Cvoid};
                    lib_name, path = "", symbols = (), return_types = (),
                    eager = (), snapshot_env = nothing, close_duplicate = false,
                    set_current = policy.sets_current_lib) -> LoadedArtifact

The registration half of `load_artifact!`, for a handle that is already open.

`load_artifact!` is `dlopen` (outside the lock) followed by this. Splitting the
two is what lets a caller that obtained a handle some other way — a test
registering a preopened image, a generated `@rust_crate` module that keeps its
own module-local `Ref` — publish it through exactly the same transaction, with
the same eviction, liveness and `CURRENT_LIB` semantics.

**It never closes the handle it was given.** An `:insert_only` policy whose key
is already taken keeps the incumbent and hands the caller's handle back
unused, but *closing* it is only correct for a caller that opened it — which is
`load_artifact!`, and which therefore passes `close_duplicate = true`. Closing
a handle the caller still owns, or one that was never a real `dlopen` result,
is a segfault inside the dynamic loader.
"""
function adopt_artifact!(policy::LoadPolicy, handle::Ptr{Cvoid};
                         lib_name::AbstractString,
                         path::AbstractString = "",
                         symbols = (),
                         return_types = (),
                         eager = (),
                         snapshot_env = nothing,
                         close_duplicate::Bool = false,
                         set_current::Bool = policy.sets_current_lib)
    handle == C_NULL &&
        throw(ArgumentError("refusing to register a NULL handle for $(lib_name)"))
    name = String(lib_name)
    lib_path = String(path)

    assumed = snapshot_env === nothing ? must_assume_unwind(policy) :
              must_assume_unwind(policy, snapshot_env)

    duplicate = C_NULL
    replaced = C_NULL
    artifact = lock(REGISTRY_LOCK) do
        if !registers_in_rust_libraries(policy)
            return LoadedArtifact(name, handle, lib_path, policy, _new_alive!(name),
                                  assumed, 0)
        end
        if policy.registration_mode === :insert_only && haskey(RUST_LIBRARIES, name)
            @debug "load_artifact!: keeping the existing entry" lib_name = name policy = policy.name
            duplicate = handle
            existing, _ = RUST_LIBRARIES[name]
            alive = get!(() -> Ref(true), ARTIFACT_ALIVE, name)
            return LoadedArtifact(name, existing, lib_path, policy, alive, assumed,
                                  get(ARTIFACT_GENERATIONS, name, 0))
        end
        if haskey(RUST_LIBRARIES, name)
            replaced = RUST_LIBRARIES[name][1]
        end
        cache = Dict{String, Ptr{Cvoid}}()
        for symbol in eager
            found = Libdl.dlsym(handle, String(symbol); throw_error = false)
            (found === nothing || found == C_NULL) && continue
            cache[String(symbol)] = found
        end
        install_library_metadata!(name, symbols, return_types)
        # One flag per *image*, not per registration. Re-registering the same
        # handle — the same file opened again, which `dlopen` refcounts and
        # answers with the same image — is the same lifetime, so it keeps the
        # same flag; giving it a new one would orphan the old, and objects
        # holding it would never learn that the image closed. A genuinely
        # different image gets a flag of its own, and the previous flag is left
        # `true` because that image is still mapped and its objects must still
        # free through it (`RETIRED_HANDLES`).
        previous_alive = get(ARTIFACT_ALIVE, name, nothing)
        # ...and that includes an image that was *unloaded* and is being opened
        # again. `unload_library(name)` retires the image without closing it,
        # so it stays mapped and the objects it produced hold its flag. The
        # loader answers the next `dlopen` of that path with the same handle;
        # minting a fresh flag for it would leave those objects watching a flag
        # nobody will ever flip, while the image they point into could later be
        # closed under a different one. The retired record's flag *is* this
        # image's flag, so it is adopted and the record retired no more.
        retired = get(RETIRED_HANDLES, handle, nothing)
        # ...and it includes the same path opened under a *second name* while
        # the first is still live. `dlopen` refcounts and returns the same
        # image, so this is one lifetime with two registry rows; a fresh flag
        # here would be a second flag for one image, and `unload_artifact!`
        # retires with only one of them — the other is dropped and never
        # flipped, leaving objects that captured it live forever over unmapped
        # code (#291 item 4).
        alive = if previous_alive !== nothing && replaced == handle
            previous_alive
        elseif retired !== nothing
            retired.alive
        else
            something(registered_alive_for_handle(handle), Ref(true))
        end
        ARTIFACT_ALIVE[name] = alive
        RUST_LIBRARIES[name] = (handle, cache)
        # This image is live again, so it is no longer retired: a record left
        # behind would let a later `close = true` close an image that is in
        # the registry (and flip a flag that belongs to a live generation).
        # The owned opens it accounted for stay in `OWNED_HANDLES`, which is
        # the single count of what the process still owes.
        delete!(RETIRED_HANDLES, handle)
        # Module-local copies of the handle move in the same critical section,
        # so a generated `@rust_crate` module's fast path can never read a
        # handle that has been replaced out from under it.
        generation = _next_artifact_generation!(name)
        _update_handle_mirrors!(name, handle, alive, generation)
        # After the swap, so `library_names_for_handle` sees the *new* mapping:
        # an old handle still live under an alias has not left the registry.
        if replaced != C_NULL && replaced != handle
            _record_retired!(replaced, String[name], previous_alive, lib_path)
        elseif replaced == handle
            # The same file opened again: `dlopen` refcounts and hands back the
            # image that is already registered. That is not a retirement — but
            # it *is* a second owned open of one image behind a single registry
            # entry, and only one close is ever owed for that entry. Balance it
            # here exactly as the `:insert_only` loser is balanced, or the last
            # loader reference would be unreclaimable and the image would stay
            # mapped for the life of the process.
            duplicate = handle
        end
        set_current && (CURRENT_LIB[] = name)
        return LoadedArtifact(name, handle, lib_path, policy, alive, assumed, generation)
    end

    # dlclose outside the lock: it runs destructors in the image. Only a
    # handle this call is responsible for — see `close_duplicate`. A *duplicate*
    # is safe to close because nobody has seen it: it was opened moments ago by
    # this call and lost the `:insert_only` race, so no pointer was ever
    # resolved from it. A *replaced* image is not safe to close and is never
    # closed here — see `RETIRED_HANDLES`.
    (close_duplicate && duplicate != C_NULL) && close_artifact_handle!(duplicate)
    return artifact
end

"""
    register_artifact_metadata!(policy, lib_name; symbols, return_types,
                                require_loaded = false,
                                set_current = policy.sets_current_lib) -> Bool

Re-publish the volatile metadata of a library that is **already** loaded — the
name-to-symbol mappings and the return-type hints — without opening anything.

`require_loaded` makes the existence check part of the same critical section as
the writes, so an `unload_artifact!` racing between a caller's `haskey` and
this call cannot leave metadata and `CURRENT_LIB[]` pointing at a library that
is gone.  Returns `false` in that case and writes nothing; the caller then
falls through to compiling and loading the library again.
"""
function register_artifact_metadata!(policy::LoadPolicy, lib_name::AbstractString;
                                     symbols = (), return_types = (),
                                     require_loaded::Bool = false,
                                     set_current::Bool = policy.sets_current_lib)
    name = String(lib_name)
    return lock(REGISTRY_LOCK) do
        if require_loaded && !haskey(RUST_LIBRARIES, name)
            return false
        end
        install_library_metadata!(name, symbols, return_types)
        set_current && (CURRENT_LIB[] = name)
        return true
    end
end

"""
    unload_artifact!(artifact::LoadedArtifact; close = false) -> Bool
    unload_artifact!(policy::LoadPolicy, lib_name; close = false) -> Bool

Retire a library: remove everything the registries record about it, in one
locked block — the `RUST_LIBRARIES` entry and its function-pointer cache, the
name-to-symbol mappings and return-type hints, the library-scoped
`FUNCTION_REGISTRY_BY_LIB` rows, the `MONOMORPHIZED_FUNCTIONS` entries that
point into it (stale pointers into an image nothing reaches are a
use-after-free, #73), its `IRUST_FUNCTIONS` rows, its panic channels, the
module mirrors that were reading its handle, and `CURRENT_LIB` if it pointed
here.  Every name of the handle goes, not just the one asked for: an alias is a
second name for the same image.

**The image itself is not closed.**  Unloading is the same act as a hot reload
replacing a library, and it is unsafe for the same reason: a call that started
a moment ago may still be inside, and there is no per-call reader pin that
would make closing safe.  The image is retired instead (`RETIRED_HANDLES`) and
keeps its liveness flag `true`, so an object it allocated still runs its
destructor through it.

`close = true` reclaims it: the liveness flags of the images retired under this
library are flipped and the images are closed.  That is the caller stating that
no call into them is in flight, and it is the only thing that makes objects
from those images inert.

Returns whether a `RUST_LIBRARIES` entry was actually removed.
"""
function unload_artifact!(policy::LoadPolicy, lib_name::AbstractString; close::Bool = false)
    name = String(lib_name)
    to_close = Ptr{Cvoid}[]
    removed = lock(REGISTRY_LOCK) do
        entry = get(RUST_LIBRARIES, name, nothing)
        handle = entry === nothing ? C_NULL : entry[1]
        # Every name of this handle goes: an alias is a second name for the
        # same image, and leaving one behind would leave a live registry entry
        # pointing at an image nothing else reaches.
        names = handle == C_NULL ? [name] : library_names_for_handle(handle)
        name in names || push!(names, name)
        alive = nothing
        for each in names
            alive === nothing && (alive = get(ARTIFACT_ALIVE, each, nothing))
            delete!(ARTIFACT_ALIVE, each)
            delete!(RUST_LIBRARIES, each)
            purge_library_state!(each)
            _retire_handle_mirrors!(each)
            if CURRENT_LIB[] == each
                CURRENT_LIB[] = ""
            end
        end
        # The image joins the retired set, with the flag its objects captured
        # still `true`. Recorded *after* the registry rows are gone, so
        # `library_names_for_handle` agrees that it has left.
        _record_retired!(handle, names, alive)
        if close
            for (h, record) in RETIRED_HANDLES
                any(n -> n in names, record.names) && push!(to_close, h)
            end
        end
        return entry !== nothing
    end
    # Outside the lock: closing runs destructors in the image.
    isempty(to_close) || close_retired_handles!(to_close)
    return removed
end

unload_artifact!(artifact::LoadedArtifact; close::Bool = false) =
    unload_artifact!(artifact.policy, artifact.name; close)

"""
    alias_artifact!(policy::LoadPolicy, from, to) -> Bool

Register the library already loaded as `from` under the second name `to`.

One handle legitimately sits in `RUST_LIBRARIES` under two names: a reload
derives a different identity than the one a precompiled module recorded, and
`_alias_reloaded_library` (#272) makes the stored name resolve to the library
that was actually loaded.  Both registries are per library (#279), so the alias
needs its **own** symbol mappings and return-type hints — without them a lookup
through the stored name resolves `f` to `f`, misses the `rustcall_f` the
library exports and falls into the cross-library search.

The alias shares the aliased artifact's liveness flag, so unloading either name
retires objects produced through both — and unloading *either* name removes
**both**, because they name one image: `unload_artifact!` collects every name
of the handle and closes it once (`library_names_for_handle`). Removing one and
leaving the other would leave a registry entry pointing at unmapped code, and
closing once per name would close an image the process opened once.

Returns `false` when `from` is not loaded.
"""
function alias_artifact!(policy::LoadPolicy, from::AbstractString, to::AbstractString)
    source = String(from)
    target = String(to)
    source == target && return false
    registers_in_rust_libraries(policy) || return false
    return lock(REGISTRY_LOCK) do
        entry = get(RUST_LIBRARIES, source, nothing)
        entry === nothing && return false
        copy_library_metadata!(source, target)
        alive = get!(() -> Ref(true), ARTIFACT_ALIVE, source)
        # Aliasing a name that *already* aliases this same image must not
        # retire it (#291 item 4). `_retire_alive!(target)` exists to kill the
        # flag of whatever different image `target` used to name — but when
        # `target` already shares this image's flag, that flag is this image's,
        # and flipping it declares a live library dead: every object holding it
        # goes inert, its destructor never runs, and a later `alive[] = false`
        # check turns working calls into errors. `_alias_reloaded_library` runs
        # on every `_resolve_lib`, so the second call through one module hit
        # exactly this.
        existing = get(RUST_LIBRARIES, target, nothing)
        already = existing !== nothing && existing[1] == entry[1] &&
                  get(ARTIFACT_ALIVE, target, nothing) === alive
        already || _retire_alive!(target)
        ARTIFACT_ALIVE[target] = alive
        RUST_LIBRARIES[target] = entry
        _update_handle_mirrors!(target, entry[1], alive,
                                get(ARTIFACT_GENERATIONS, target, 0))
        return true
    end
end
