# Explicit load/compile policy object (issue #277).
#
# Before #277 every compile/load front door carried its own copy of four
# decisions:
#
#   1. the `dlopen` flag set (`RTLD_LOCAL` vs `RTLD_GLOBAL`)
#   2. the panic strategy of the produced artifact (`abort` vs `unwind`)
#      and what the generated `extern "C"` boundary does about it
#   3. whether the loaded handle is registered in `RUST_LIBRARIES`, under what
#      kind of key, whether an existing entry is replaced or kept, and whether
#      `CURRENT_LIB` moves
#   4. the finalizer / ownership policy of the types the artifact produces
#
# so the same user-visible construct behaved differently depending on which
# door it came through — an inline `rust"""` block was RTLD_LOCAL without
# `// cargo-deps:` and RTLD_GLOBAL with it (#250).  This file names those four
# decisions in one record, with one named constructor per front door.  Since
# Phase B2 every policy is `RTLD_LOCAL | RTLD_NOW`, and every door RustCall
# builds itself is pinned to `panic = "unwind"` behind a `catch_unwind`
# boundary (#244); only the user's own crate (`:crate_profile`) keeps its
# profile's strategy.
#
# Phase A was strictly additive.  Phase B (#277) makes this file the *only*
# place that opens, registers and unloads a compiled artifact: `load_artifact!`
# / `unload_artifact!` / `alias_artifact!` below own the `dlopen`, the
# `RUST_LIBRARIES` entry, the per-library symbol and return-type tables, the
# function-pointer cache and `CURRENT_LIB`, as one transaction under
# `REGISTRY_LOCK`.  Each named constructor records the policy of its own front
# door, so a change of policy is one edit in one place.
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
* The ownership helper library (`deps/rustcall_helpers`) looked like the one
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

(`RUSTCALL_DLOPEN_GLOBAL=1` restored the old process-global behaviour through
v0.4.x and is ignored since v0.5, #417.)
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

- `dlopen_flags::UInt32` — the exact flag set handed to `Libdl.dlopen`:
  `RTLD_LOCAL | RTLD_NOW` for every named policy.

- `global_symbols::Bool` — whether the flag set includes `RTLD_GLOBAL`, i.e.
  whether this artifact publishes its symbols into the process-global
  namespace.  See `SYMBOL_VISIBILITY_RULE` for when that is legitimate.

- `panic_strategy::Symbol` — the panic strategy the artifact is *compiled*
  with, one of:
    * `:unwind` — RustCall pins unwinding: `-C panic=unwind` on the `rustc`
      command line (`rustc_panic_flags`), `panic = "unwind"` in a generated
      `[profile.release]` (`cargo_profile_panic_line`) and
      `CARGO_PROFILE_<PROFILE>_PANIC=unwind` in Cargo's environment, so an
      inherited `CARGO_PROFILE_RELEASE_PANIC=abort` cannot turn it into an
      aborting build.  Every door RustCall builds itself carries this value;
    * `:crate_profile` — RustCall does **not** control the build: Cargo runs in
      the *user's* crate, so the effective profile (the crate's own
      `[profile.release]`, a workspace profile, `.cargo/config.toml`, or
      `CARGO_PROFILE_RELEASE_PANIC`) decides, and `panic = "abort"` there is
      honoured, hence a separate value rather than a guess;
    * `:abort` — `-C panic=abort`; the keyword constructor's default, which no
      named policy uses any more (the direct-`rustc` path aborted until #244);
    * `:cargo_default` — Cargo drives the build and RustCall pins nothing, so
      Cargo's default for the profile applies, subject to
      `CARGO_PROFILE_<PROFILE>_PANIC` from the environment.  No named policy
      uses it any more; `effective_panic_strategy` resolves it.

- `boundary_catches_panics::Bool` — whether the generated `extern "C"` wrapper
  wraps the user body in `std::panic::catch_unwind` and reports the panic
  through the thread-local panic channel.  `true` for every named policy
  (#244, #346).

- `registry::Symbol` — where the loaded handle is recorded:
  `:rust_libraries` (the `RUST_LIBRARIES` dict), `:module_local` (a `Ref` in
  the generated `@rust_crate` module), `:helper_slot` (`RUST_HELPERS_LIB`), or
  `:none`.

- `registry_key_kind::Symbol` — the shape of the key used with
  `:rust_libraries`: `:content_hash` (`rust_<hash>` from the inline paths),
  `:lib_basename` (unused since #278), `:irust_hash` (`irust_<short id>`),
  `:crate_lib_name` (hot reload), or `:none`.

- `registration_mode::Symbol` — what `load_artifact!` does when the name is
  already registered: `:replace` (install the new image and retire the old
  one) or `:insert_only` (keep the existing entry and its function-pointer
  cache, and hand the loser the incumbent image; `generics_policy`).

- `sets_current_lib::Bool` — whether the site also moves `CURRENT_LIB[]`.

- `finalizer_frees::Bool` — whether objects produced by this artifact free
  their Rust allocation in their finalizer.  `true` for inline `#[julia]`
  structs (since #277 Phase B4) and `@rust_crate` structs alike (#249);
  `false` for the generics and `@irust` policies.

- `call_sites::Vector{String}` — the sites this policy was written to subsume
  (#277).  Kept as a record of that inventory; its `file:line` references
  date from it and are not maintained.

- `issues::Vector{Int}` — the issues behind this policy's decisions.

- `notes::String` — free-form description of the policy.
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

Keyword constructor. The defaults are `RTLD_LOCAL | RTLD_NOW`, `panic=abort`
with no `catch_unwind` boundary, registration in `RUST_LIBRARIES` under a
content hash replacing any previous entry, `CURRENT_LIB` untouched, and
finalizers that free.

Every named constructor below states its own values; none keeps the `:abort`
default (every door RustCall builds is pinned to `:unwind`, #244).
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
# Named constructors: one per front door.
# ---------------------------------------------------------------------------

"""
    inline_rustc_policy() -> LoadPolicy

Inline `rust\"\"\"...\"\"\"` block with **no** `// cargo-deps:`, compiled straight by
`rustc`, on both cache states (a disk-cache hit and a fresh compile).  Compiled
with `-C panic=unwind` (`rustc_panic_flags`, `src/compiler.jl`) behind the
generated `catch_unwind` boundary, and loaded `RTLD_LOCAL | RTLD_NOW`.

Until #277 Phase B2 this door was `RTLD_LOCAL` while `inline_cargo_policy` —
the same `rust\"\"\"` construct declaring `// cargo-deps:` — was `RTLD_GLOBAL`
(#250); until #244 this one aborted on a panic and that one did not.  The two
doors now agree on every decision.
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

Covers both cache states (a Cargo cache hit and a fresh build), both loaded
`RTLD_LOCAL | RTLD_NOW` like `inline_rustc_policy`.

The strategy is pinned to `:unwind`: the generated `Cargo.toml` writes
`panic = "unwind"` into `[profile.release]` (`cargo_profile_panic_line`,
`src/cargoproject.jl`) and `build_cargo_project` passes
`CARGO_PROFILE_<PROFILE>_PANIC=unwind` to Cargo (`src/cargobuild.jl`), so an
inherited `CARGO_PROFILE_RELEASE_PANIC=abort` cannot produce an artifact whose
`catch_unwind` boundary never fires (#244).
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
    notes = "Pinned to unwind in the generated manifest and in Cargo's " *
            "environment, like the direct rustc path; RTLD_LOCAL since B2.")

"""
    crate_direct_policy() -> LoadPolicy

`@rust_crate` for a crate that already declares `crate-type = ["cdylib"]`, so
RustCall builds it in place: `build_crate_directly` points a `CargoProject` at
`info.path` and runs Cargo there.  The Cargo root is then the **user's**
manifest, so their `[profile.release] panic = "abort"`, a workspace profile,
`.cargo/config.toml` or `CARGO_PROFILE_RELEASE_PANIC` all decide — hence
`:crate_profile`, which `effective_panic_strategy` deliberately leaves
unresolved.  The generated `#[julia]` boundary catches an unwinding panic; a
crate that pins `panic = "abort"` itself aborts on one, which is the user's
decision (`docs/src/panics.md`).

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
crate around it and builds *that*.  The Cargo root is then RustCall's own
generated manifest, whose `[profile.release]` pins `panic = "unwind"`
(`cargo_profile_panic_line`, in `src/crate_bindings.jl` and for the PyO3
wrapper in `src/pyo3.jl`), and Cargo's environment pins it too — so this door
is `:unwind`, like `inline_cargo_policy`.

The two `@rust_crate` build paths therefore differ only in who decides the
panic strategy, chosen by `crate_has_cdylib` (#244).  Everything else —
`RTLD_LOCAL | RTLD_NOW`, registration under `crate_library_name`, freeing
finalizers — matches `crate_direct_policy`.
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
            "panic = \"unwind\", while the direct-cdylib path takes the " *
            "user's profile.")

"""
    helper_library_policy() -> LoadPolicy

The ownership helper library `deps/rustcall_helpers` — `deps/rust_helpers`
through v0.3.x (#387) — loaded by `load_rust_helpers_lib` and
`try_load_rust_helpers` (`src/memory.jl`) into `RUST_HELPERS_LIB`, and
registered under the name `rustcall_helpers`.

It looked like the one library other artifacts could legitimately need to
resolve symbols against, and is not: every user goes through
`RUST_HELPERS_LIB[]` plus `dlsym` (`src/memory.jl`), and no artifact links
against it, so nothing would resolve anything against it even if it were
`RTLD_GLOBAL`.  `SYMBOL_VISIBILITY_RULE`'s "provides symbols to other
artifacts" category is therefore empty, and this policy stays `RTLD_LOCAL`
(#277 Phase B2).

Panic strategy is `:unwind`, and pinned twice over: `deps/rustcall_helpers/Cargo.toml`
declares `[profile.release] panic = "unwind"`, and `build_native_product`
(`deps/build.jl`) passes `CARGO_PROFILE_RELEASE_PANIC=unwind` to Cargo, so an
inherited `CARGO_PROFILE_RELEASE_PANIC=abort` cannot decide it either (#244).
No `catch_unwind` boundary contains this library, so an aborting build would
take the Julia process with it; `effective_panic_strategy` resolves the value.
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
    call_sites = ["src/memory.jl (load_rust_helpers_lib)",
                  "src/memory.jl (try_load_rust_helpers)",
                  "deps/build.jl (build_native_product)",
                  "deps/rustcall_helpers/Cargo.toml"],
    issues = [244, 250],
    notes = "Every user reaches it through RUST_HELPERS_LIB[] and dlsym and " *
            "nothing links against it, so RTLD_LOCAL is right after all " *
            "(B2); its panic strategy is pinned by both its own manifest and " *
            "the environment deps/build.jl passes to Cargo, so no inherited " *
            "CARGO_PROFILE_RELEASE_PANIC can turn it into an aborting build.")

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

`boundary_catches_panics` is `true` since #346: the snippet is compiled as a
`#[julia]` item and expanded by `rustcall-extract`, so it gets the same
generated wrapper as every other RustCall-owned door — `catch_unwind` plus the
thread-local panic channel. Until then `@irust` hand-wrote a bare
`#[no_mangle] pub extern "C"` entry point, and this field said so: an unwinding
artifact with no boundary, which is exactly the undefined behaviour #244 is
about (it aborted the process).
"""
irust_policy() = LoadPolicy("irust";
    dlopen_flags = Libdl.RTLD_LOCAL | Libdl.RTLD_NOW,
    panic_strategy = :unwind,
    boundary_catches_panics = true,
    registry = :rust_libraries,
    registry_key_kind = :irust_hash,
    sets_current_lib = false,
    finalizer_frees = false,
    call_sites = ["src/ruststr.jl (_compile_and_call_irust)"],
    issues = [250, 278, 346],
    notes = "IRUST_FUNCTIONS is dropped with the library by " *
            "unload_artifact! since B1, so an unloaded snippet leaves no memo " *
            "behind. The snippet is a #[julia] item since #346, so the boundary " *
            "catches.")

"""
    hot_reload_policy() -> LoadPolicy

Hot reload of a `@rust_crate` crate (`src/hot_reload.jl:205`, re-registered at
`:210`).  The rebuild happens outside `REGISTRY_LOCK`, and a failed rebuild
currently leaves the registry without the previous entry (#255).

Like `crate_direct_policy`, the panic strategy is `:crate_profile`: `rebuild_crate`
builds the user's crate as its own Cargo root, exactly as `build_crate_directly`
does, so their profile decides.
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
    ALL_LOAD_POLICIES

Every named policy, in the order the inventory in the #277 PR body lists them
(the `llvm-ir` policy that inventory also listed went with the LLVM IR path,
#265). Used by `test/test_loadpolicy.jl` to pin down the current divergences.
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
)

# ---------------------------------------------------------------------------
# Accessors — what the call sites ask instead of open-coding a decision.
# ---------------------------------------------------------------------------

"""
    dlopen_flags(policy::LoadPolicy) -> UInt32

The flag set to hand to `Libdl.dlopen`: `policy.dlopen_flags`, which is
`RTLD_LOCAL | RTLD_NOW` for every policy since #277 Phase B2
(`SYMBOL_VISIBILITY_RULE`). Nothing overrides it: the `RUSTCALL_DLOPEN_GLOBAL`
escape hatch of #250 lasted one minor release and was removed in v0.5 (#417).
On Windows `LoadLibrary` has no LOCAL/GLOBAL distinction, so the flag changes
nothing there.
"""
dlopen_flags(policy::LoadPolicy) = policy.dlopen_flags

"""
    uses_global_symbols(policy::LoadPolicy) -> Bool

Whether this policy publishes the artifact's symbols process-globally:
`false` for every policy since #277 Phase B2 (`SYMBOL_VISIBILITY_RULE`).
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
panic strategy, or `nothing` when the Cargo default already matches.  The
generated inline-block and `@rust_crate` wrapper manifests write this line.

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
  for the `release` profile.  No named policy carries it any more.
- `:crate_profile` is returned unchanged: the environment is only one of the
  inputs there, and the user's manifest — which RustCall does not read for
  this — can pin `panic`.

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

The related cache-*identity* problem — two artifacts built under different
`CARGO_PROFILE_*` values sharing a key — is closed by the artifact identity
(`src/artifact_id.jl`, #272, #278); this function models only the resolution,
not the key.
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
already catch — which no named policy does any more, since every one has
`boundary_catches_panics` (#244).

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

Whether `load_artifact!` / `adopt_artifact!` register the image in
`RUST_LIBRARIES`.
"""
registers_in_rust_libraries(policy::LoadPolicy) = policy.registry === :rust_libraries

"""
    finalizer_frees(policy::LoadPolicy) -> Bool

Whether objects produced by this artifact free their allocation on finalization
(#249).
"""
finalizer_frees(policy::LoadPolicy) = policy.finalizer_frees

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
- `installed::Bool` — whether *this* call put the handle in the registry.
  `false` for an `:insert_only` policy that lost the race and was handed the
  existing image, and for a helper/module-local policy that found its image
  already registered; a caller that must undo only what it itself installed
  (`release_generics`' revived-batch case, #397) reads this rather than
  guessing from the handle, which the loser shares with the winner.
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
    installed::Bool
    # Which generation of `name` this is. Anything resolved against `handle`
    # belongs to this generation and may be cached with it (#277).
    generation::Int
end

LoadedArtifact(name, handle, path, policy, alive, assumed_unwind) =
    LoadedArtifact(name, handle, path, policy, alive, assumed_unwind, true, 0)
LoadedArtifact(name, handle, path, policy, alive, assumed_unwind, generation::Int) =
    LoadedArtifact(name, handle, path, policy, alive, assumed_unwind, true, generation)

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
const ARTIFACT_ALIVE = _state_view(:artifact_alive, Dict{String, Ref{Bool}}())

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
const ARTIFACT_GENERATIONS = _state_view(:artifact_generations, Dict{String, Int}())

"""
    ARTIFACT_IMAGE_PATHS

`lib_name` → the path the image registered under that name was opened from.

An `:insert_only` loser is handed the incumbent image without learning where it
came from, and for one caller that matters: a generic batch member must be
opened from the one copy the batch memo names (`_batch_copy_is_current`), and
the incumbent it lost to may be a retired image a stale reader revived from an
*older* copy and has not yet retired again (#397). The memo is current and so
is the image, yet it is not the fresh copy the memo names; this table is how
the publication can tell. Written with the registry row, dropped with it, and
shared by an alias. A name registered without a path (`adopt_artifact!`) has
no entry. Guarded by `REGISTRY_LOCK`.
"""
const ARTIFACT_IMAGE_PATHS = _state_view(:artifact_image_paths, Dict{String, String}())

# The path `name`'s registered image was opened from, or `nothing` when it was
# registered without one. Caller holds REGISTRY_LOCK.
registered_image_path(name::AbstractString) = get(ARTIFACT_IMAGE_PATHS, String(name), nothing)

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
function artifact_generation(lib_name::AbstractString)
    name = String(lib_name)
    lock(() -> get(ARTIFACT_GENERATIONS, name, 0), REGISTRY_LOCK)
end

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

One immutable record removes the question — but only if publishing it is **one
store**, which is what `CrateGenerationCell` is for. A plain
`Base.RefValue{CrateGeneration}` is not: see that type's docstring for the
measurement (#402).
"""
struct CrateGeneration
    handle::Ptr{Cvoid}
    alive::Base.RefValue{Bool}
    generation::Int
end

CrateGeneration() = CrateGeneration(C_NULL, Ref(false), 0)

"""
    CrateGenerationCell([record])

The cell a generated `@rust_crate` module reads its generation record from, and
that `_update_handle_mirrors!` publishes into. Behaves as a `Ref` — `cell[]` and
`cell[] = record` — so every call site reads the same as before.

# Why not a `Base.RefValue{CrateGeneration}` (#402)

Because that tears. `CrateGeneration` holds a `Ref{Bool}`, so it is not
`isbits`, and this file used to reason from that: "the `Ref` holds a pointer to
it and publishing a new generation is a single pointer store". That is wrong.
Julia stores an immutable struct **inline** in a `RefValue` whenever it can, and
it can here — `sizeof(Base.RefValue{CrateGeneration})` is **24**, the struct
itself, not 8. So `gen_ref[] = published` is a 24-byte write and a reader's
deref is a 24-byte read, with nothing keeping them apart.

A reader therefore observed records that were never published: one generation's
handle with another's number and flag. Measured directly — one writer
alternating two records, one reader checking that the three fields came from the
same one — **137129 torn reads out of 13211045**. It surfaced as the reload
stress test pairing one generation number with two different returned values
(#402).

# How exposed this was, exactly

A generated module reaches its cell through a `StateView`, and `StateView`
reads take `STATE.lock` — which **is** `REGISTRY_LOCK` (`src/RustCall.jl`), the
lock `_update_handle_mirrors!` writes under. So no generated wrapper has ever
read a torn record: the two sides exclude each other by accident of the
container, not by the store being atomic.

What was exposed is everything this type says a caller may do. The paragraph
above promised a lock-free read, `register_handle_mirror!` takes a bare cell so
that a caller can have one, and `test/test_hot_reload_transaction.jl` reads
exactly that way — which is how #402 was found. Had a lock-free read been added
later, as #253 did for the *target* cache, it would have been the #291 hazard
with no test to catch it: a wrapper pairing a new handle with the previous
image's liveness flag, or an object capturing a destructor from one image and a
flag from another. The store is atomic now, so the promise is true rather than
true-by-coincidence.

`@atomic` on the field is the fix, and the `Union{Nothing, …}` is what makes it
cheap: an atomic field wider than a pointer falls back to a lock (measured:
`sizeof` 40 for a bare `@atomic record::CrateGeneration`), while a union with a
reference is stored as one pointer — `sizeof` **8**, one store, one load, no
lock and no allocation on the read path. `CrateTargetCache` above is the same
shape for the same reason.

`test/test_hot_reload_transaction.jl` asserts both halves: that the cell does not
tear under a writer, and that it is still pointer-sized, so that a later
simplification back to a `Ref` fails instead of silently reintroducing this.
"""
mutable struct CrateGenerationCell <: Ref{CrateGeneration}
    @atomic record::Union{Nothing, CrateGeneration}
    CrateGenerationCell(record::CrateGeneration = CrateGeneration()) = new(record)
end

@inline function Base.getindex(cell::CrateGenerationCell)
    record = @atomic :acquire cell.record
    # `nothing` is never stored — the constructor always writes a record — so
    # this branch exists only to give the field a reference type, which is what
    # makes it one pointer. A `const` empty record would be tidier and is not
    # used: `test/test_state.jl` rejects a module binding that reaches a `Ref`,
    # and `CrateGeneration` holds the liveness flag.
    return record === nothing ? CrateGeneration() : record
end

@inline function Base.setindex!(cell::CrateGenerationCell, record::CrateGeneration)
    @atomic :release cell.record = record
    return record
end

"""
    CachedCrateTarget

One `@rust_crate` call site's remembered snapshot, with the two things that say
whether it may still be used: the process that resolved it and the artifact
epoch it was resolved at.

`target` is whatever tuple the arm that produced it returns — a pointer and a
channel, those plus a release function, plus a liveness flag, and so on. It is
stored and handed back **whole**, never rebuilt from parts, so the generation
rule of #277 is untouched: what is cached is one snapshot of one image.
"""
struct CachedCrateTarget
    """The process that resolved this. See `SESSION_TOKEN`."""
    token::SessionToken
    """The artifact epoch it was resolved at."""
    epoch::Int
    """The arm's whole tuple, exactly as the call site will use it."""
    target::Any
end

"""
    CrateTargetCache()

One call site's memory of the snapshot it last took out of a generated
`@rust_crate` module (#253).

# Why a named binding and not a spliced object

The inline `rust\"\"\"` path (`CallTargetCache`, `src/ruststr.jl`) splices its
cache straight into the expansion, so it needs no name. A `@rust_crate` module
cannot do that: `write_bindings_to_file` emits the same module as **source
text**, and an object has no source spelling. So each call site of a generated
module declares its cache as a `const` of that module, which both flavours can
write, and which `test/test_state.jl` accepts because a target cache is not a
registry — it holds one immutable snapshot and is invalidated wholesale.

# What makes an entry usable

Exactly what makes a `CachedTarget` usable, and for exactly the same reasons:

  * `ARTIFACT_EPOCH` must not have moved. Every write to the state container
    bumps it (`_state_mutate_storage!`), and so does every publication to a
    module's generation mirror, so a hot reload, an unload, an alias or a newly
    memoized symbol all invalidate every kept snapshot.
  * `SESSION_TOKEN` must be this process's. A generated module is routinely
    precompiled into a package, and a wrapper called from a precompile workload
    would otherwise serialise a populated cache — raw pointers included — into
    the `.ji`, where a matching epoch in the next process would hand a dead
    pointer to `ccall`.
"""
mutable struct CrateTargetCache
    # One atomic field holding an immutable record: a reader sees either the
    # whole previous answer or the whole new one, in one pointer load.
    @atomic entry::Union{Nothing, CachedCrateTarget}
    CrateTargetCache() = new(nothing)
end

"""
    crate_target_hit(cache, T) -> Union{T, Nothing}

`cache`'s snapshot if it is still current, `nothing` otherwise. The whole fast
path of a generated `@rust_crate` call: one atomic load, an identity comparison
and an integer comparison — no lock, and no symbol lookup.

`T` is the tuple type the arm that owns this cache stores, asserted on the way
out so the wrapper's `ccall` stays statically typed.
"""
@inline function crate_target_hit(cache::CrateTargetCache, ::Type{T}) where {T}
    entry = @atomic :acquire cache.entry
    entry === nothing && return nothing
    # This process first: an entry deserialised from a precompiled module holds
    # pointers of the process that wrote them, and the epoch alone would let one
    # through whenever the two counters happened to agree.
    entry.token === session_token() || return nothing
    entry.epoch === artifact_epoch() || return nothing
    return entry.target::T
end

"""
    publish_crate_target!(cache, epoch, target) -> target

Record `target` as `cache`'s answer for `epoch`.

`epoch` must have been sampled **before** the snapshot was taken. A write
landing in between then leaves the entry stamped with the older epoch and it is
resolved again; sampling afterwards could stamp a pre-write snapshot as current
and keep it for the life of the process.
"""
@inline function publish_crate_target!(cache::CrateTargetCache, epoch::Int, target::T) where {T}
    @atomic :release cache.entry = CachedCrateTarget(session_token(), epoch, target)
    return target
end

"""
    HANDLE_MIRRORS

`lib_name` → the module-local copies of that library's handle and liveness flag
that the loader keeps in sync.

A generated `@rust_crate` module resolves its symbols through its own
generation record. The module exposes an owner-qualified StateView and the
underlying cell is owned by STATE. A raw copy of a handle goes **stale**
the moment the library is replaced or unloaded: a hot reload closes the previous
image, and `unload_library` drops it, after which a raw copy of the handle
would be read against an image nothing points at any more. Registering the
module's owned cell here lets the transaction that swaps the handle swap the mirror
in the same critical section, so a single record read can never
point at a closed image (#277 Phase B).

The mirrors survive an unload rather than being dropped with it: a hot reload is
"unload then load under the same name", and the module that registered them is
still there waiting for the new handle.

Guarded by `REGISTRY_LOCK`.
"""
const HANDLE_MIRRORS = _state_view(:handle_mirrors,
    Dict{String, Vector{CrateGenerationCell}}())

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
                                 gen_ref::CrateGenerationCell)
    name = String(lib_name)
    lock(REGISTRY_LOCK) do
        mirrors = get!(() -> CrateGenerationCell[], HANDLE_MIRRORS, name)
        any(m -> m === gen_ref, mirrors) || push!(mirrors, gen_ref)
        entry = get(RUST_LIBRARIES, name, nothing)
        if entry !== nothing
            gen_ref[] = CrateGeneration(entry[1],
                                        get!(() -> Ref(true), ARTIFACT_ALIVE, name),
                                        get(ARTIFACT_GENERATIONS, name, 0))
            _invalidate_kept_snapshots!()
        end
    end
    return nothing
end

# The container this used to accept, refused with the reason rather than a
# `MethodError`. A `Base.RefValue{CrateGeneration}` stores the 24-byte record
# inline, so publishing into one is not a single store and a reader can see a
# mixture of two generations (#402) — which is the whole reason the cell exists.
# Adapting the call by wrapping the caller's `Ref` in a cell would be worse than
# refusing it: publications would go to the cell and the caller's `Ref` would
# silently stop tracking the library.
#
# Nothing generated needs this. A `@rust_crate` module registers its
# `StateView`, and the cell behind that view is created by RustCall
# (`src/module_state.jl`), so even a file emitted before this change keeps
# working unchanged.
function register_handle_mirror!(lib_name::AbstractString,
                                 ::Base.RefValue{CrateGeneration})
    throw(ArgumentError(
        "A generation mirror must be a `RustCall.CrateGenerationCell`, not a " *
        "`Ref{CrateGeneration}`: a `Ref` stores the record inline, so publishing " *
        "into it is not one store and a reader can observe one generation's " *
        "handle with another's liveness flag (#402). Construct the mirror with " *
        "`RustCall.CrateGenerationCell()`; it reads and writes as a `Ref`."))
end

# Generated modules expose only an immutable owner-qualified view. The cell
# itself lives in STATE; the loader's mirror list aliases that same owned cell.
function register_handle_mirror!(lib_name::AbstractString, view::StateView)
    view.owner !== nothing && view.name === :crate_generation ||
        throw(ArgumentError("A crate generation mirror requires a module-owned generation view"))
    gen_ref = _state_read(view, identity)
    return register_handle_mirror!(lib_name, gen_ref)
end

# Publish one generation to every mirror of `name`: one atomic pointer store
# each, so a reader's single load can never pair one generation's handle with
# another's flag (`CrateGenerationCell`, #402). Caller holds REGISTRY_LOCK.
function _update_handle_mirrors!(name::String, handle::Ptr{Cvoid},
                                 alive::Base.RefValue{Bool}, generation::Int)
    published = CrateGeneration(handle, alive, generation)
    for gen_ref in get(HANDLE_MIRRORS, name, ())
        gen_ref[] = published
    end
    _invalidate_kept_snapshots!()
    return nothing
end

# A mirror cell is state that a `CrateTargetCache` caches a read of, but it is
# written by storing into the cell rather than through `_state_mutate_storage!`,
# so it is the one such write that does not bump the epoch on its own (#253).
# Today every caller changes a registry row in the same transaction and the
# epoch moves for that reason; saying it here as well means a kept snapshot
# stays correct even if that stops being true. Bumped **after** the store, and
# under `REGISTRY_LOCK` — a reader samples the epoch before it derefs the
# mirror, which it can only do once this transaction has released the lock.
@inline _invalidate_kept_snapshots!() = (Threads.atomic_add!(ARTIFACT_EPOCH, 1); nothing)

# The library is gone: a mirror must say so rather than keep a handle that is
# about to be closed. The *mirror* stays registered — a reload under the same
# name fills it in again. Caller holds REGISTRY_LOCK.
function _retire_handle_mirrors!(name::String)
    retired = CrateGeneration(C_NULL, Ref(false), get(ARTIFACT_GENERATIONS, name, 0))
    for gen_ref in get(HANDLE_MIRRORS, name, ())
        gen_ref[] = retired
    end
    _invalidate_kept_snapshots!()
    return nothing
end

"""
    RetiredImage

An image that has left the registry but is **still mapped**.

Carries what closing it later needs: the liveness flag its objects captured,
the names it was known by (for diagnostics and for
`unload_library(name; close = true)`) and how many owned opens it had.
"""
struct RetiredImage
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
    local_alive = get(HANDLE_ONLY_ALIVE, handle, nothing)
    local_alive === nothing || return local_alive
    return _state_read(DEAD_ARTIFACT, identity)
end

# Images loaded by helper/module-local policies still need a handle-owned
# flag, even though they have no RUST_LIBRARIES row.
const HANDLE_ONLY_ALIVE = _state_view(:handle_only_alive,
    Dict{Ptr{Cvoid}, Base.RefValue{Bool}}())

"""
    DEAD_ARTIFACT

A liveness flag that is `false` and stays `false`: the answer for a pointer
whose image is neither registered nor retired. Shared, because it is immutable
in practice — nothing ever flips it.
"""
const DEAD_ARTIFACT = _state_view(:dead_artifact, Ref(false))

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
const RETIRED_HANDLES = _state_view(:retired_handles, Dict{Ptr{Cvoid}, RetiredImage}())

"""
    retired_handles() -> Vector{Ptr{Cvoid}}
    retired_handles(lib_name) -> Vector{Ptr{Cvoid}}

The images that have left the registry and are still mapped: all of them, or
those that were known by `lib_name`.
"""
retired_handles() = lock(() -> collect(keys(RETIRED_HANDLES)), REGISTRY_LOCK)

function retired_handles(lib_name::AbstractString)
    name = String(lib_name)
    lock(REGISTRY_LOCK) do
        [h for (h, r) in RETIRED_HANDLES if name in r.names]
    end
end

# Record an image that has left the registry. Its liveness flag stays as it is
# — `true` — because the image is still mapped and its objects must still be
# able to free through it. Caller holds REGISTRY_LOCK.
function _record_retired!(handle::Ptr{Cvoid}, names::Vector{String},
                          alive::Union{Nothing, Base.RefValue{Bool}})
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
        RetiredImage(alive === nothing ?
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
    return _close_retired_images!(Pair{Ptr{Cvoid}, Any}[handle => nothing for handle in handles])
end

"""
    close_retired_images!(images) -> Int

Close retired images **by identity**: `handle => alive` pairs, each closed only
while the retired record under `handle` still carries that liveness flag. A
handle is a pointer value the loader can hand out again once the image is
unmapped, so a caller that decided *which* image may go — and asserted
quiescence for that one — must not close whatever retirement the value names
by the time it acts; the flag is one per mapped image and names it exactly
(#397 review). Returns how many were closed.
"""
close_retired_images!(images) =
    _close_retired_images!(Pair{Ptr{Cvoid}, Any}[handle => alive for (handle, alive) in images])

# `expected === nothing` closes whatever retirement the handle names; a flag
# closes only the image carrying it.
function _close_retired_images!(selected::Vector{Pair{Ptr{Cvoid}, Any}})
    records = lock(REGISTRY_LOCK) do
        found = Pair{Ptr{Cvoid}, RetiredImage}[]
        for (handle, expected) in selected
            record = get(RETIRED_HANDLES, handle, nothing)
            record === nothing && continue
            expected === nothing || record.alive === expected || continue
            # Flip under the lock, before the close: an object finalized in
            # between must see `false`, not a handle that is about to go.
            record.alive[] = false
            _forget_generic_image!(record.alive)
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

`generation` is an integer or a ready-made tag such as
`"rustcall.<host>.<pid>.<n>"` (`process_generation_path`).
"""
function generation_path(lib_path::AbstractString,
                         generation::Union{Integer, AbstractString})
    dir = dirname(lib_path)
    stem, ext = splitext(basename(lib_path))
    return joinpath(dir, "$(stem).$(generation)$(ext)")
end

"""
    GENERATION_COPY_MARKER

The word in a generation copy's name that says RustCall made it:
`libfoo.rustcall.<host>.<pid>.<generation>.dylib`.

The stale-copy sweep deletes files, so the shape it matches must be one
nothing else produces. `<stem>.<number>.<number><ext>` is not that — a
versioned or application-managed `libfoo.12345.2.dylib` beside `libfoo.dylib`
would be deleted the moment pid 12345 is absent. With the marker, only a file
RustCall itself named is ever a candidate.
"""
const GENERATION_COPY_MARKER = "rustcall"

"""
    GENERATION_COPY_HOST_LEN

Length of the host tag in a generation copy's name: hex characters of
`stable_content_hash(gethostname())`, truncated by `artifact_short_id`.
"""
const GENERATION_COPY_HOST_LEN = 12

"""
    _generation_copy_host() -> String

The host tag of this process's generation copies: a fixed-length hex prefix of
the digest of the host name.

A pid names a process only on the host that runs it. When the library sits on
a volume several hosts share — NFS, a bind mount into a container with its own
pid namespace — host B's process table says nothing about host A's pids, so
without this tag B could take A's still-running process for dead and delete
the copy A is between `cp` and `dlopen` of, and two hosts with the same pid
and counter could even pick one path. The sweep only ever considers copies
carrying this host's own tag. Computed per call rather than at precompile
time, so an image built on one machine does not carry that machine's name.
"""
function _generation_copy_host()
    name = try
        gethostname()
    catch
        ""
    end
    return artifact_short_id(stable_content_hash(name), GENERATION_COPY_HOST_LEN)
end

"""
    GENERATION_COPY_INSTANCE_LEN

Length of the per-process instance token in a generation copy's name
(`_generation_copy_instance`): hex characters.
"""
const GENERATION_COPY_INSTANCE_LEN = 8

const _GENERATION_COPY_INSTANCE = _state_view(:generation_copy_instance, Ref(""))

"""
    _generation_copy_instance() -> String

A token that tells this process apart from every other process that may share
the library's volume — including one in **another pid namespace with the same
pid** (#321): a bind mount into two containers that also share the UTS
hostname gives both the same host tag and can give both the same pid and the
same `RELOAD_GENERATION`, so without it they would pick one copy path.

Drawn once per process at first use, from `/dev/urandom` where there is one
and otherwise from the clock, the pid and the host, and folded through
`stable_content_hash`; never computed at precompile time, so an image does
not carry the token of the process that built it.
"""
function _generation_copy_instance()
    token = _GENERATION_COPY_INSTANCE[]
    isempty(token) || return token
    entropy = try
        isfile("/dev/urandom") ? bytes2hex(read("/dev/urandom", 16)) : ""
    catch
        ""
    end
    seed = string(entropy, ':', time_ns(), ':', getpid(), ':', _generation_copy_host(),
                  ':', objectid(Ref(0)))
    fresh = artifact_short_id(stable_content_hash(seed), GENERATION_COPY_INSTANCE_LEN)
    # Another task may have drawn one first; one token per process, so the
    # first published wins and this task adopts it.
    current = _GENERATION_COPY_INSTANCE[]
    isempty(current) || return current
    _GENERATION_COPY_INSTANCE[] = fresh
    return _GENERATION_COPY_INSTANCE[]
end

"""
    _generation_copy_name(stem, ext, host, pid, instance, generation) -> String

`<stem>.rustcall.<host>.<pid>.<instance>.<generation><ext>`: the one spelling
of a generation copy's file name, used by `process_generation_path` to make
one and by `_sweep_stale_generation_copies` to recognise one.
"""
_generation_copy_name(stem::AbstractString, ext::AbstractString, host::AbstractString,
                      pid::Integer, instance::AbstractString, generation::Integer) =
    "$(stem).$(GENERATION_COPY_MARKER).$(host).$(pid).$(instance).$(generation)$(ext)"

"""
    process_generation_path(lib_path, generation) -> String

`libfoo.dylib` → `libfoo.rustcall.<host>.<pid>.<instance>.<generation>.dylib`:
the copy name `loadable_library_copy` uses; `<host>` is
`_generation_copy_host()`, `<instance>` is `_generation_copy_instance()`.

`RELOAD_GENERATION` is per process, so two Julia processes that load the same
built library — two workers of a test run, two sessions using one crate — would
both pick `libfoo.1.dylib`. On Windows the second cannot overwrite the copy the
first has mapped, and a copy that fails would fall back to mapping Cargo's
output in place, which is the very failure the copy exists to prevent (#309).
With the process id in the name, the copies of two live processes on one host
never share a path; with the instance token, neither do two processes that
share the volume and the pid from different pid namespaces (#321). The
`rustcall` marker is what lets the stale-copy sweep recognise its own files
(`GENERATION_COPY_MARKER`).
"""
function process_generation_path(lib_path::AbstractString, generation::Integer)
    dir = dirname(lib_path)
    stem, ext = splitext(basename(lib_path))
    return joinpath(dir, _generation_copy_name(stem, ext, _generation_copy_host(), getpid(),
                                               _generation_copy_instance(), generation))
end

# ---------------------------------------------------------------------------
# Leases: who owns a generation copy, decided by the file system (#321)
# ---------------------------------------------------------------------------

"""
    GENERATION_LEASE_SUFFIX

Beside every generation copy `loadable_library_copy` makes sits
`<copy>.lease`, a file the owning process keeps **open and locked** for its
whole life. A pid proves nothing across pid namespaces — container B's
`kill(pid, 0)` says nothing about container A's process — but an advisory
lock on a shared volume is held by whichever process holds it, whatever
namespace it runs in, and is released by the kernel when that process ends,
cleanly or not. So the stale-copy sweep asks the lease, not the process
table: a copy whose lease it can lock has no owner and goes; one whose lease
is held stays. This is the shape of the lockfile claim of #256 / PR #313.
"""
const GENERATION_LEASE_SUFFIX = ".lease"

generation_lease_path(copy_path::AbstractString) = String(copy_path) * GENERATION_LEASE_SUFFIX

# The leases this process holds, kept open for its whole life: closing the
# stream would release the lock and let another process's sweep take the copy
# for abandoned while it is mapped here.
const _GENERATION_LEASES = _state_view(:generation_leases, IOStream[])

"""
    _try_lock_lease(io::IOStream) -> Union{Bool, Nothing}

Take an exclusive, non-blocking lock on the open lease `io`: `true` when
acquired, `false` when another open description holds it (`flock` reports
`EWOULDBLOCK`; `LockFileEx` reports `ERROR_LOCK_VIOLATION`), `nothing` when
the file system offers no locking at all — the sweep then falls back to the
process table, and the owner proceeds without a lease.

`flock` locks belong to the open file description, so a second `open` of the
same lease in the *same* process conflicts too, which is what lets a test
observe the lock; on Windows `LockFileEx` over the first byte does the same.
Both are released when the description is closed or the process ends.
"""
function _try_lock_lease(io::IOStream)
    if Sys.iswindows()
        LOCKFILE_EXCLUSIVE_LOCK = UInt32(0x2)
        LOCKFILE_FAIL_IMMEDIATELY = UInt32(0x1)
        ERROR_LOCK_VIOLATION = UInt32(33)
        ERROR_IO_PENDING = UInt32(997)
        # `_get_osfhandle` returns a `WindowsRawSocket`, a primitive type that
        # *is* the HANDLE; `cconvert` bitcasts it to `Ptr{Cvoid}`. (It has no
        # `.handle` field — that spelling never worked, and a project lease is
        # taken on every shaped project since #425, so it stopped being latent.)
        raw = Base.Libc._get_osfhandle(fd(io))
        handle = raw isa Ptr{Cvoid} ? raw : Base.cconvert(Ptr{Cvoid}, raw)::Ptr{Cvoid}
        overlapped = zeros(UInt8, 32)
        ok = ccall((:LockFileEx, "kernel32"), stdcall, Cint,
                   (Ptr{Cvoid}, UInt32, UInt32, UInt32, UInt32, Ptr{UInt8}),
                   handle, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, overlapped)
        ok != 0 && return true
        err = Libc.GetLastError()
        return (err == ERROR_LOCK_VIOLATION || err == ERROR_IO_PENDING) ? false : nothing
    end
    LOCK_EX = Cint(2)
    LOCK_NB = Cint(4)
    r = ccall(:flock, Cint, (Cint, Cint), fd(io), LOCK_EX | LOCK_NB)
    r == 0 && return true
    err = Libc.errno()
    return err == Libc.EAGAIN ? false : nothing   # EWOULDBLOCK == EAGAIN on every Unix Julia runs on
end

"""
    _acquire_generation_lease(copy_path) -> Union{Bool, Nothing}

Create `<copy>.lease` and take its lock for the rest of this process's life
(`_GENERATION_LEASES`). `true`: held. `false`: another process holds a lease
of that name — the copy path is taken (a collision of host, pid, instance and
generation, which the instance token makes all but impossible) and the caller
picks another generation. `nothing`: no lease could be made or locked here;
the caller proceeds without one, as before #321.

Windows is always `nothing`: it has no pid namespaces, so `_process_alive` sees
every process on the machine and the sweep's pid fallback is exact there. A
lease held for the life of the process is also a file an active lock keeps
`DeleteFile` from unlinking, which would refuse the test or rebuild that removes
a temp tree holding a live copy (EBUSY). The instance token already makes the
copy name unique, so nothing is lost.
"""
function _acquire_generation_lease(copy_path::AbstractString)
    Sys.iswindows() && return nothing
    io = try
        open(generation_lease_path(copy_path), "w")
    catch e
        @debug "No lease for $(copy_path): $(sprint(showerror, e))"
        return nothing
    end
    state = try
        _try_lock_lease(io)
    catch e
        @debug "Could not lock the lease of $(copy_path): $(sprint(showerror, e))"
        nothing
    end
    if state === true
        push!(_GENERATION_LEASES, io)
        return true
    end
    close(io)
    return state
end

"""
    _lease_state(copy_path) -> Symbol

What the lease beside `copy_path` says about its owner, for the sweep:
`:held` (a process holds it — alive, wherever it runs), `:free` (the lease
exists and nobody holds it — the owner is gone), `:none` (no lease, or a file
system without locking — decide from the process table instead).
"""
function _lease_state(copy_path::AbstractString)
    lease = generation_lease_path(copy_path)
    isfile(lease) || return :none
    io = try
        # Read/write but non-creating: `flock(LOCK_EX)` is emulated with
        # byte-range locks on some network file systems and then needs a
        # writable descriptor, while `"r+"` still fails rather than recreates a
        # lease that just vanished (#437 review).
        open(lease, "r+")
    catch
        return :none
    end
    state = try
        _try_lock_lease(io)
    catch
        nothing
    end
    close(io)   # releases the probe lock at once, if it was taken
    state === true && return :free
    state === false && return :held
    return :none
end

"""
    _process_alive(pid) -> Bool

Whether a process with this id exists, for the stale-copy sweep.

On Unix `kill(pid, 0)` delivers nothing and reports `ESRCH` for a pid nobody
holds; any other answer (0, or `EPERM` for another user's process) counts as
alive. On Windows `OpenProcess` with `PROCESS_QUERY_LIMITED_INFORMATION`
fails with `ERROR_INVALID_PARAMETER` for a pid nobody holds, and an open
handle whose `GetExitCodeProcess` is `STILL_ACTIVE` is a running process;
anything else — access denied, a query that fails — counts as alive.

The answer matters on Windows too, not only the file system's refusal to
delete a mapped DLL: between a process's `cp` and its `dlopen` the copy is not
mapped yet, so a sweep in another process that treated every pid as dead
could delete it in that window. Errs on the side of "alive".
"""
function _process_alive(pid::Integer)
    if Sys.iswindows()
        PROCESS_QUERY_LIMITED_INFORMATION = UInt32(0x1000)
        ERROR_INVALID_PARAMETER = UInt32(87)
        STILL_ACTIVE = UInt32(259)
        h = ccall((:OpenProcess, "kernel32"), stdcall, Ptr{Cvoid},
                  (UInt32, Cint, UInt32), PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
        h == C_NULL && return Libc.GetLastError() != ERROR_INVALID_PARAMETER
        code = Ref{UInt32}(0)
        ok = ccall((:GetExitCodeProcess, "kernel32"), stdcall, Cint,
                   (Ptr{Cvoid}, Ref{UInt32}), h, code)
        ccall((:CloseHandle, "kernel32"), stdcall, Cint, (Ptr{Cvoid},), h)
        return ok == 0 || code[] == STILL_ACTIVE
    end
    r = ccall(:kill, Cint, (Cint, Cint), pid, 0)
    r == 0 && return true
    return Libc.errno() != Libc.ESRCH
end

"""
    _sweep_stale_generation_copies(built_path)

Remove the `<lib>.rustcall.<host>.<pid>.<instance>.<generation>.<ext>` copies
beside `built_path` that this host made and whose owner is gone, and their
leases.

A written bindings module makes one copy per process start, and nothing
removes it when that process exits — an image is retired, not closed, and on
Windows a mapped DLL cannot be deleted anyway — so an application that keeps
launching Julia would accumulate copies without bound (#309). The next process
to copy the same library sweeps first. Who is "gone" is decided by the copy's
**lease** (`GENERATION_LEASE_SUFFIX`, #321): a lease this sweep can lock has
no owner anywhere on the volume, in this pid namespace or another, and the
copy goes; a lease somebody holds means a live owner, whatever its pid looks
like from here, and the copy stays. Only when there is no lease to ask — a
copy made without one, or a file system without locking — does the process
table decide, as it did before #321. This process's own copies are never
candidates; a copy Windows still has mapped refuses the delete and is kept
for a later sweep. Only names carrying `GENERATION_COPY_MARKER` **and this
host's tag** are candidates: the pre-#309 `<lib>.<generation>.<ext>` shape
and anything else beside the library are not RustCall's to delete. The
v0.4.x shape without an instance token is still recognised, by pid, for one
release. Best effort: nothing here can fail the load.
"""
function _sweep_stale_generation_copies(built_path::AbstractString)
    dir = dirname(built_path)
    stem, ext = splitext(basename(built_path))
    prefix = stem * "." * GENERATION_COPY_MARKER * "." * _generation_copy_host() * "."
    me = getpid()
    mine = _generation_copy_instance()
    names = try
        readdir(dir)
    catch
        return nothing
    end
    isnum(p) = !isempty(p) && all(isdigit, p)
    ishex(p) = ncodeunits(p) == GENERATION_COPY_INSTANCE_LEN && all(c -> c in '0':'9' || c in 'a':'f', p)
    for name in names
        startswith(name, prefix) && endswith(name, ext) || continue
        ncodeunits(name) > ncodeunits(prefix) + ncodeunits(ext) || continue
        # Byte indices are safe here: `prefix` ends and `ext` begins with an
        # ASCII '.', so both cuts fall on character boundaries.
        tag = SubString(name, ncodeunits(prefix) + 1, ncodeunits(name) - ncodeunits(ext))
        parts = split(tag, '.')
        path = joinpath(dir, name)
        if length(parts) == 3 && isnum(parts[1]) && ishex(parts[2]) && isnum(parts[3])
            pid = tryparse(Int, parts[1])
            pid === nothing && continue
            pid == me && parts[2] == mine && continue
            state = _lease_state(path)
            if state === :held
                continue
            elseif state === :none
                # No lease to ask: the process table, as before #321. A pid
                # equal to this process's from another namespace stays, err on
                # the side of alive.
                (pid == me || _process_alive(pid)) && continue
            end
            _remove_generation_copy(path)
        elseif length(parts) == 2 && isnum(parts[1]) && isnum(parts[2])
            # The v0.4.x shape (no instance token, no lease): by pid, for one
            # release.
            pid = tryparse(Int, parts[1])
            pid === nothing && continue
            pid == me && continue
            _process_alive(pid) && continue
            _remove_generation_copy(path)
        end
    end
    return nothing
end

# Remove a copy and its lease; either may be refused (a mapped DLL on Windows)
# and is then left for a later sweep.
function _remove_generation_copy(path::AbstractString)
    try
        rm(path)
    catch e
        @debug "Kept generation copy $(basename(path)): $(sprint(showerror, e))"
        return nothing
    end
    lease = generation_lease_path(path)
    isfile(lease) || return nothing
    try
        rm(lease)
    catch e
        @debug "Kept lease $(basename(lease)): $(sprint(showerror, e))"
    end
    return nothing
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

Copying to `<lib>.rustcall.<host>.<pid>.<instance>.<generation>.<ext>` and
opening that leaves Cargo's output untouched, and makes every load a
genuinely distinct file — across processes, pid namespaces and hosts too,
since the counter alone is per process (#255, #277, #309, #321).
Before copying, the copies whose owners no longer exist are swept
(`_sweep_stale_generation_copies`), so a library that is loaded by one
process after another keeps only the live processes' copies beside it; and
before copying, this process takes the copy's **lease** — `<copy>.lease`,
held open and locked until the process ends — so that no other process's
sweep, in this pid namespace or another, can take the copy for abandoned in
the window between the copy and its `dlopen`, or ever after (#321). The lease
is taken first: a sweep that sees the copy sees a held lease.

Returns the original path when the copy cannot be made, so a platform or a
filesystem that will not take one degrades to the previous behaviour rather
than failing the load.
"""
function loadable_library_copy(built_path::AbstractString)
    built = String(built_path)
    isfile(built) || return built
    _sweep_stale_generation_copies(built)
    copy_path = process_generation_path(built, next_reload_generation())
    # A lease of that name held elsewhere means the path is taken by a live
    # process this table cannot see; the counter moves on. Bounded: the
    # instance token makes even one collision improbable.
    for _ in 1:8
        _acquire_generation_lease(copy_path) === false || break
        copy_path = process_generation_path(built, next_reload_generation())
    end
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
const OWNED_HANDLES = _state_view(:owned_handles, Dict{Ptr{Cvoid}, Int}())

"""
    QUIET_PANIC_INSTALL_SYMBOL
    QUIET_PANIC_UNINSTALL_SYMBOL

The two symbols an artifact whose source RustCall generated in full exports for
its quiet panic hook (#304). They are spelled in
`rustcall_julia_core::codegen::{INSTALL,UNINSTALL}_PANIC_HOOK_SYMBOL`; a mismatch
would show up as the hook never being installed, which
`test/test_panic_hook.jl` asserts against.
"""
const QUIET_PANIC_INSTALL_SYMBOL = :__rustcall_install_panic_hook
const QUIET_PANIC_UNINSTALL_SYMBOL = :__rustcall_uninstall_panic_hook

"""
    QUIET_HOOK_LOCK

Serialises the quiet panic hook's lifecycle for one process (#304).

Two transitions must not interleave: *record a loader reference, then install*
(`load_artifact!`) and *confirm no reference is left, then uninstall*
(`close_artifact_handle!`). Without this lock a `dlopen` of a still-mapped path
could record its reference and call the installer — a no-op, because the hook is
still marked live — in the window between the other task's zero-count check and
its uninstall, leaving a live image with no hook and nothing to restore it
(#388 review).

**Lock ordering: this lock is taken *before* `REGISTRY_LOCK`, never after.**
Only the two paths above take it, and the only foreign code called under it is
the artifact's own installer/uninstaller — a thread-local read and a
`set_hook`/`take_hook`, with no allocation of ours and no call back into Julia.
`REGISTRY_LOCK` is never held across that call.
"""
const QUIET_HOOK_LOCK = ReentrantLock()

"""
    prefer_dynamic_flag(flags) -> Bool

Whether one `rustc` flag string asks for a shared `std`.

Tokenised rather than searched for a substring, so `-C prefer-dynamic`,
`-Cprefer-dynamic`, `--codegen prefer-dynamic` and the `\x1f`-separated
`CARGO_ENCODED_RUSTFLAGS` form all count, and `-C prefer-dynamic=no` — which
asks for the opposite — does not.
"""
function prefer_dynamic_flag(flags::AbstractString)
    for raw in eachsplit(flags, r"[\s\x1f]+")
        token = String(raw)
        for prefix in ("--codegen=", "--codegen", "-C=", "-C")
            if startswith(token, prefix) && length(token) > length(prefix)
                token = token[(length(prefix) + 1):end]
                break
            end
        end
        startswith(token, "prefer-dynamic") || continue
        value = token[(length("prefer-dynamic") + 1):end]
        isempty(value) && return true
        startswith(value, "=") || continue
        # `-C prefer-dynamic=no` is the default spelled out.
        lowercase(value[2:end]) in ("no", "n", "off", "false", "0") || return true
    end
    return false
end

"""
    effective_rustflags(env) -> Vector{String}

The flag strings Cargo would actually hand `rustc`, given `env`.

Cargo takes rustflags from **one** source, not their union, in this order:
`CARGO_ENCODED_RUSTFLAGS`, `RUSTFLAGS`, the per-target
`CARGO_TARGET_<TRIPLE>_RUSTFLAGS` (`target.<triple>.rustflags`), and
`CARGO_BUILD_RUSTFLAGS` (`build.rustflags`). *Set* is what counts, not
non-empty: an empty `RUSTFLAGS` deliberately suppresses what a Cargo
configuration would otherwise contribute, which is why
`ARTIFACT_ENV_ABSENT` keeps "absent" and "set to empty" apart at all
(`src/artifact_id.jl`).

Every per-target variable at that level is returned rather than the one for the
triple being built, which is not known here: erring towards finding a flag errs
towards *not* installing a hook (#388 review).
"""
function effective_rustflags(env)
    for name in ("CARGO_ENCODED_RUSTFLAGS", "RUSTFLAGS")
        haskey(env, name) && return String[String(env[name])]
    end
    per_target = String[String(value) for (name, value) in env
                        if startswith(uppercase(String(name)), "CARGO_TARGET_") &&
                           endswith(uppercase(String(name)), "_RUSTFLAGS")]
    isempty(per_target) || return per_target
    haskey(env, "CARGO_BUILD_RUSTFLAGS") &&
        return String[String(env["CARGO_BUILD_RUSTFLAGS"])]
    return String[]
end

"""
    prefer_dynamic_build(; env = ENV) -> Bool
    prefer_dynamic_build(snapshot_env) -> Bool

Whether the build `env` asks `rustc` for a **shared** `std`
(`-C prefer-dynamic`).

It decides whether the quiet hook may be installed at all. With the default
static `std` every image owns its own hook registry, so one image's hook is
another image's business only if the registry is shared — and with
`prefer-dynamic` it is: the hook installed from a `cdylib` is reachable, and
droppable, from any other image in the process (#302 review, #304).

`snapshot_env` is the environment the artifact was **built** under, recorded at
macro-expansion time and replayed by the Cargo build (#272); it is what
`load_artifact!` passes, exactly as `effective_panic_strategy` takes it. Falling
back to the live `ENV` is right for the direct-`rustc` doors, which build in this
process.

Which variable decides is `effective_rustflags`, following Cargo's own
precedence. A `prefer-dynamic` that reaches `rustc` from a place no environment
variable mirrors — `build.rustflags` written in a Cargo configuration *file*,
which RustCall reads nowhere — is invisible here; what that costs is described in
`docs/src/panics.md`, and it is not memory safety: `close_artifact_handle!`
removes the hook before the image is unmapped either way.
"""
function prefer_dynamic_build(; env = ENV)
    return any(prefer_dynamic_flag, effective_rustflags(env))
end

prefer_dynamic_build(snapshot_env::Union{AbstractDict, AbstractString}) =
    prefer_dynamic_build(; env = _as_env(snapshot_env))

"""
    quiet_panic_hooks_enabled() -> Bool

Whether RustCall may install quiet panic hooks in this process.

`RUSTCALL_PANIC_HOOK=default` turns them off — the escape hatch for the one
thing the hook costs: a panic *inside* a generated artifact but *outside* any
wrapper boundary, on a thread the artifact's own code spawned, is printed by the
hook RustCall replaced, and if that hook is gone so is the message. It is also
off under `prefer_dynamic_build`.
"""
function quiet_panic_hooks_enabled(; env = ENV)
    setting = lowercase(strip(get(ENV, "RUSTCALL_PANIC_HOOK", "")))
    setting in ("default", "off", "0", "false") && return false
    return !prefer_dynamic_build(; env = env)
end

quiet_panic_hooks_enabled(snapshot_env::Union{AbstractDict, AbstractString}) =
    quiet_panic_hooks_enabled(; env = _as_env(snapshot_env))

"""
    install_quiet_panic_hook!(handle; snapshot_env = nothing) -> Bool

Install the artifact's quiet panic hook, and say whether it was installed.

Called by `load_artifact!` right after `dlopen` and after the loader reference is
recorded, before any wrapper of the image can run. That timing is the design: the
installer is called by the loader rather than lazily by the first wrapper call, so
two first calls to two wrappers cannot race to install it — the defect that sank
the per-wrapper attempt in #302.

**The image decides, not the policy.** `__rustcall_install_panic_hook` is
exported exactly when the image carries the quiet-panic state: a file RustCall
writes whole (inline blocks, `@irust`, generics) defines it at its root, and a
`#[julia]` crate — hand-written, or the generated `@rust_crate` wrapper crate —
gets it from the `rustcall_julia_macros` rlib it links, as long as some
generated wrapper references that crate. Asking the image therefore cannot be
wrong, and no door can forget to opt in. A `LoadPolicy` flag was tried first and
was exactly that mistake: every `@rust_crate` module loads with
`crate_direct_policy()`, the generated PyO3 wrapper crate included, so the flag
silently excluded wrapper flavours that do carry a hook (#388 review). The doors
are listed in `docs/src/panics.md` for readers; nothing branches on the list.

Returns `false` — silently, it is not an error — when hooks are disabled for this
process, or when the image exports no installer (a crate with no `#[julia]`
wrapper, the hand-written helper library, or an artifact built by RustCall
≤ v0.3.4).
"""
function install_quiet_panic_hook!(handle::Ptr{Cvoid}; snapshot_env = nothing)
    handle == C_NULL && return false
    enabled = snapshot_env === nothing ? quiet_panic_hooks_enabled() :
              quiet_panic_hooks_enabled(snapshot_env)
    enabled || return false
    install = Libdl.dlsym(handle, QUIET_PANIC_INSTALL_SYMBOL; throw_error = false)
    (install === nothing || install == C_NULL) && return false
    ccall(install, Cvoid, ())
    Threads.atomic_add!(QUIET_PANIC_HOOK_INSTALLS, 1)
    return true
end

"""
    uninstall_quiet_panic_hook!(handle) -> Bool

Remove the artifact's quiet panic hook before its code is unmapped, and say
whether it was removed.

Called by `close_artifact_handle!`, the one place an image is closed, so the
closure leaves std's registry before the memory it lives in does. Asking the
image rather than the policy is deliberate: closing goes through one handle-only
path, and the exported symbol is a more reliable question than a policy the
caller would have to carry along. The generated uninstaller is a no-op when that
image never installed anything.
"""
function uninstall_quiet_panic_hook!(handle::Ptr{Cvoid})
    handle == C_NULL && return false
    uninstall = Libdl.dlsym(handle, QUIET_PANIC_UNINSTALL_SYMBOL; throw_error = false)
    (uninstall === nothing || uninstall == C_NULL) && return false
    ccall(uninstall, Cvoid, ())
    Threads.atomic_add!(QUIET_PANIC_HOOK_REMOVALS, 1)
    return true
end

"""
    QUIET_PANIC_HOOK_INSTALLS
    QUIET_PANIC_HOOK_REMOVALS

How many times this process called an artifact's quiet-hook installer and
uninstaller (#304). Counters, not registries: a test asserts that closing an
artifact removed its hook without having to reach into the image.

`INSTALLS` counts *calls*, and the generated installer is guarded by a mutex
over an "installed" flag (not a `Once`, so it can install again after an
uninstall), so loading one image twice calls it twice and installs once. Calling it on every
load rather than only on the reference that opened the image is deliberate: two
tasks racing on one path would otherwise let the loser call a wrapper before the
winner had installed anything. `REMOVALS` counts only the last reference, because
that is the close that unmaps.
"""
const QUIET_PANIC_HOOK_INSTALLS = Threads.Atomic{Int}(0)
const QUIET_PANIC_HOOK_REMOVALS = Threads.Atomic{Int}(0)

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
    # `owned` says this call may close; `final` says it is releasing the last
    # reference RustCall holds, which is the only close that unmaps the image.
    owned, final = lock(REGISTRY_LOCK) do
        remaining = get(OWNED_HANDLES, handle, 0)
        remaining == 0 && return (false, false)
        remaining == 1 ? delete!(OWNED_HANDLES, handle) :
                         (OWNED_HANDLES[handle] = remaining - 1)
        if remaining == 1
            alive = get(HANDLE_ONLY_ALIVE, handle, nothing)
            delete!(HANDLE_ONLY_ALIVE, handle)
            if alive !== nothing
                alive[] = false
                _forget_generic_image!(alive)
            end
        end
        return (true, remaining == 1)
    end
    owned || return false
    # Only on the last reference, and only if it is *still* the last: the panic
    # hook is a closure living in the image, and std's registry must not keep
    # pointing at it once the code is unmapped (#304), but an image that keeps a
    # reference stays mapped and in use. The count is re-read here because a
    # `dlopen` of the same path can land between the decision above and this
    # point, receive this same still-mapped handle and record a reference of its
    # own. The check runs under `QUIET_HOOK_LOCK`, which `load_artifact!` holds
    # across *its* record-then-install, so such a reopen either records before
    # this check — and keeps its hook, because the check then sees it — or
    # installs after the uninstall, which works because install and uninstall are
    # repeatable on the Rust side. What the lock rules out is the reopen
    # finishing a no-op install in between (#388 review).
    if final
        lock(QUIET_HOOK_LOCK) do
            lock(() -> get(OWNED_HANDLES, handle, 0) == 0, REGISTRY_LOCK) &&
                uninstall_quiet_panic_hook!(handle)
        end
    end
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
    return get(HANDLE_ONLY_ALIVE, handle, nothing)
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

`preload` names shared libraries the image imports **by name** that the
platform's loader would not find on its own, each as a full path; they are
opened first (`preload_dependency!`), under the same flag set, and stay open for
the life of the process. This is how a PyO3 wrapper finds its `python3xy.dll`
on Windows, where there is no rpath and the interpreter's directory need not be
on `PATH` (`PyO3LinkPlan.runtime_libraries`, #307 review).

Throws if the load fails, leaving the registry untouched.
"""
function load_artifact!(policy::LoadPolicy, path::AbstractString;
                        lib_name::AbstractString,
                        preload = (),
                        symbols = (), return_types = (), eager = (),
                        kwargs...)
    lib_path = String(path)
    name = String(lib_name)
    # Reject caller metadata before acquiring a loader reference. Otherwise
    # a throwing iterator or conversion in adopt_artifact! leaks this open.
    metadata = registers_in_rust_libraries(policy) ?
               prepare_library_metadata(symbols, return_types) :
               prepare_library_metadata((), ())
    prepared_eager = registers_in_rust_libraries(policy) ?
                     String[String(symbol) for symbol in eager] : String[]
    for dependency in preload
        preload_dependency!(policy, dependency)
    end
    handle = Libdl.dlopen(lib_path, dlopen_flags(policy))
    if handle == C_NULL
        throw(RustError("Failed to load $(policy.name) library: $(lib_path)"))
    end

    # This call opened the image, so this package may close it later
    # (`OWNED_HANDLES`). A handle that merely arrives through
    # `adopt_artifact!` is never closed by RustCall.
    # Recording the reference and installing the quiet panic hook (#304) are one
    # transition: a concurrent last close confirms the count is still zero under
    # the same lock before it uninstalls, so the two can only happen in one order
    # or the other, never interleaved. The install happens before any wrapper of
    # this image can be called, and the eligibility question is asked of the
    # environment the artifact was *built* under when the caller recorded one.
    lock(QUIET_HOOK_LOCK) do
        lock(REGISTRY_LOCK) do
            OWNED_HANDLES[handle] = get(OWNED_HANDLES, handle, 0) + 1
        end
        install_quiet_panic_hook!(handle;
                                  snapshot_env = get(kwargs, :snapshot_env, nothing))
    end
    # `load_artifact!` opened this handle, so `load_artifact!` owns it: if the
    # registration turns out not to need it (`:insert_only` lost the race), it
    # is this call's job to close it. `adopt_artifact!` never closes a handle
    # it was merely handed.
    return adopt_artifact!(policy, handle; lib_name = name, path = lib_path,
                           symbols = metadata.symbols, return_types = metadata.return_types,
                           eager = prepared_eager,
                           close_duplicate = true, kwargs...)
end

"""
    PRELOADED_LIBRARIES

The libraries `preload_dependency!` has opened, by path, with their handles.

An entry is a dependency some artifact imports by name — a Python runtime DLL —
that RustCall opened so the loader could resolve that import. It is never
closed: the artifacts that import it may outlive any one of them being
retired, and a runtime like Python cannot be unloaded and reloaded within one
process anyway. Guarded by `REGISTRY_LOCK`.
"""
const PRELOADED_LIBRARIES = _state_view(:preloaded_libraries,
    Dict{String, Ptr{Cvoid}}())

"""
    preload_dependency!(policy::LoadPolicy, path) -> Ptr{Cvoid}

Open `path` — a library some artifact of `policy` imports by name — under the
policy's flag set, once per path, and keep it open for the life of the process
(`PRELOADED_LIBRARIES`). The `dlopen` runs outside `REGISTRY_LOCK`, like every
other; two tasks racing on one path both open it (the loader refcounts, so the
duplicate open is harmless) and the table keeps the first handle.

Throws a `RustError` naming the path when it cannot be opened, so a wrapper
that would fail with a bare "module not found" fails with the dependency that
is missing instead.
"""
function preload_dependency!(policy::LoadPolicy, path::AbstractString)
    dependency = String(path)
    known = lock(() -> get(PRELOADED_LIBRARIES, dependency, C_NULL), REGISTRY_LOCK)
    known == C_NULL || return known
    handle = Libdl.dlopen(dependency, dlopen_flags(policy); throw_error = false)
    handle === nothing &&
        throw(RustError("Failed to load a library the $(policy.name) library depends on: " *
                        "$(dependency)"))
    return lock(REGISTRY_LOCK) do
        get!(PRELOADED_LIBRARIES, dependency, handle)
    end
end

"""
    preloaded_libraries() -> Vector{String}

The paths `preload_dependency!` has opened in this process, sorted.
"""
preloaded_libraries() = lock(() -> sort!(collect(keys(PRELOADED_LIBRARIES))), REGISTRY_LOCK)

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

    # Resolve on the supplied image before entering STATE. Registration still
    # publishes the complete cache and metadata together; dynamic symbol
    # resolution can execute loader code and must not hold the registry lock.
    cache = Dict{String, Ptr{Cvoid}}()
    if registers_in_rust_libraries(policy)
        for symbol in eager
            name_ = String(symbol)
            found = Libdl.dlsym(handle, name_; throw_error = false)
            (found === nothing || found == C_NULL) && continue
            cache[name_] = found
        end
    end

    duplicate = C_NULL
    replaced = C_NULL
    metadata = registers_in_rust_libraries(policy) ?
               prepare_library_metadata(symbols, return_types) : nothing
    artifact = lock(REGISTRY_LOCK) do
        if !registers_in_rust_libraries(policy)
            retired = get(RETIRED_HANDLES, handle, nothing)
            alive = something(registered_alive_for_handle(handle),
                              retired === nothing ? nothing : retired.alive, Ref(true))
            HANDLE_ONLY_ALIVE[handle] = alive
            ARTIFACT_ALIVE[name] = alive
            # A live helper/module-local owner revives the image just like a
            # registry owner. Its old retirement must no longer flip the
            # shared flag or reclaim the opens this owner now relies on.
            delete!(RETIRED_HANDLES, handle)
            return LoadedArtifact(name, handle, lib_path, policy, alive,
                                  assumed, 0)
        end
        if policy.registration_mode === :insert_only && haskey(RUST_LIBRARIES, name)
            duplicate = handle
            existing, _ = RUST_LIBRARIES[name]
            alive = get!(() -> Ref(true), ARTIFACT_ALIVE, name)
            return LoadedArtifact(name, existing, lib_path, policy, alive, assumed, false,
                                  get(ARTIFACT_GENERATIONS, name, 0))
        end
        if haskey(RUST_LIBRARIES, name)
            replaced = RUST_LIBRARIES[name][1]
        end
        install_library_metadata!(name, metadata)
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
        ARTIFACT_IMAGE_PATHS[name] = lib_path
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
            _record_retired!(replaced, String[name], previous_alive)
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
    metadata = prepare_library_metadata(symbols, return_types)
    return lock(REGISTRY_LOCK) do
        if require_loaded && !haskey(RUST_LIBRARIES, name)
            return false
        end
        install_library_metadata!(name, metadata)
        set_current && (CURRENT_LIB[] = name)
        return true
    end
end

"""
    unload_artifact!(artifact::LoadedArtifact; close = false) -> Bool
    unload_artifact!(policy::LoadPolicy, lib_name; close = false, expect_generation = nothing) -> Bool

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
function unload_artifact!(policy::LoadPolicy, lib_name::AbstractString; close::Bool = false,
                          expect_generation::Union{Nothing, Int} = nothing)
    name = String(lib_name)
    to_close = Ptr{Cvoid}[]
    removed = lock(REGISTRY_LOCK) do
        entry = get(RUST_LIBRARIES, name, nothing)
        # `expect_generation` makes the retirement conditional on the image
        # being the one the caller decided to retire: a caller that captured
        # `(handle, generation)` earlier, did its own bookkeeping against it,
        # and must neither retire a *newer* image registered under the name in
        # the meantime nor report a retirement another caller already did.
        # Checked here, in the same transaction, because a check outside it
        # is exactly the race it exists to close (#397 review).
        if expect_generation !== nothing &&
           (entry === nothing || get(ARTIFACT_GENERATIONS, name, 0) != expect_generation)
            return false
        end
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
            delete!(ARTIFACT_IMAGE_PATHS, each)
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

An alias over a name that pointed at a *different* image **retires** that image
rather than killing it: it is still mapped, so it keeps its liveness flag `true`
and its objects still free through it, exactly as a replaced image does
(`load_artifact!`). It becomes inert only when `close_retired_handles!` actually
closes it. Aliasing over one of several names of a live image does nothing to
that image at all.

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
        # The image `target` named before this call, and the flag it carried.
        # Captured now, because both rows are about to be overwritten.
        existing = get(RUST_LIBRARIES, target, nothing)
        displaced = existing === nothing ? C_NULL : existing[1]
        displaced_alive = get(ARTIFACT_ALIVE, target, nothing)
        # No flag is flipped here, and that is the whole of it (#291 item 4 and
        # its review). This used to `_retire_alive!(target)` unconditionally,
        # which was wrong three ways:
        #
        #   * when `target` already named *this* image, the flag being flipped
        #     was this image's own — a live library declared dead, every object
        #     holding the flag inert and its destructor never run.
        #     `_alias_reloaded_library` runs on every `_resolve_lib`, so the
        #     second call through one precompiled module hit exactly that;
        #   * when `target` named a different image that this alias displaces,
        #     the image is *retired*, not closed. It is still mapped, so it
        #     keeps its flag `true` and its objects still free through it —
        #     `close_retired_handles!` is what makes them inert, and it flips
        #     the flag itself. Flipping here left a mapped image whose objects
        #     all skipped their destructors;
        #   * when that image still had another live name, `_record_retired!`
        #     rightly declines to retire it — but the flag was already false,
        #     so a perfectly live library was marked dead.
        #
        # Displacement therefore goes through the same path as an unload:
        # record retired, keep the flag, close later.
        ARTIFACT_ALIVE[target] = alive
        RUST_LIBRARIES[target] = entry
        # One image, one path: the alias was opened from wherever its source was.
        source_path = get(ARTIFACT_IMAGE_PATHS, source, nothing)
        source_path === nothing ? delete!(ARTIFACT_IMAGE_PATHS, target) :
                                  (ARTIFACT_IMAGE_PATHS[target] = source_path)
        # Generation numbers belong to the destination name. Rebinding it to
        # another image must advance its stamp; an idempotent alias must not.
        generation = displaced == entry[1] ? get(ARTIFACT_GENERATIONS, target, 0) :
                     _next_artifact_generation!(target)
        _update_handle_mirrors!(target, entry[1], alive, generation)
        # An alias that displaces a *different* image takes a name away from it
        # — and an image with no name left is unreachable: nothing can unload
        # it and `close_retired_handles!` cannot see it, so its owned `dlopen`
        # reference is never given back and it stays mapped for the life of the
        # process. `load_artifact!` records exactly this on a replace; the alias
        # path did not (#291 review). Recorded *after* the swap, so
        # `library_names_for_handle` sees the new mapping — and an image still
        # live under another name is left alone by `_record_retired!` itself,
        # which is why nothing above may touch its flag.
        if displaced != C_NULL && displaced != entry[1]
            _record_retired!(displaced, String[target], displaced_alive)
        end
        return true
    end
end
