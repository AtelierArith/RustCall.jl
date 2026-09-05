# Explicit load/compile policy object (issue #277, Phase A).
#
# Today every compile/load front door carries its own copy of four decisions:
#
#   1. the `dlopen` flag set (`RTLD_LOCAL` vs `RTLD_GLOBAL`)          — 12 sites
#   2. the panic strategy of the produced artifact (`abort` vs `unwind`)
#      and what the generated `extern "C"` boundary does about it
#   3. whether the loaded handle is registered in `RUST_LIBRARIES`, under what
#      kind of key, whether an existing entry is replaced or kept, and whether
#      `CURRENT_LIB` moves                                            — 7 sites
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
# Phase A is strictly additive: nothing in this file is called from the rest of
# `src/` yet, and no existing behaviour changes.  Each constructor below
# reproduces *what its call sites do today*, divergences included; the
# divergences are pinned down by `test/test_loadpolicy.jl` so that Phase B
# migrations are visible as test changes.
#
# Related issues: #244 (panic containment), #249 (finalizers), #250 (symbol
# visibility / unload), #252, #255 (failed hot reload empties the registry),
# #269 (follow-up), #251 (registry consolidation).

"""
    SYMBOL_VISIBILITY_RULE

Prose statement of the rule Phase B should apply when choosing `RTLD_GLOBAL`
over `RTLD_LOCAL`.  Kept as data so the tests and the docs quote one text.

The rule: a library is loaded `RTLD_GLOBAL` **only** when other libraries
loaded later must resolve undefined symbols against it — in practice only the
ownership helper library (`deps/rust_helpers`, `src/memory.jl`) and, in the
future, any explicitly declared "provides symbols to other artifacts" library.
Everything else — inline `rust\"\"\"` blocks, Cargo-backed blocks, `@rust_crate`
libraries, monomorphized generics, `@irust` snippets — is a leaf artifact whose
symbols are reached through its own handle via `dlsym`, and must therefore be
`RTLD_LOCAL` so that two blocks defining the same `#[no_mangle]` name cannot
shadow one another in the process-global namespace.

Note that the helper library is one of the few loaded `RTLD_LOCAL` today, and
the leaf artifacts are mostly loaded `RTLD_GLOBAL` — i.e. current `main` has
the rule exactly inverted.  The split among inline blocks runs along the
dependency axis and is stable across cache states: no `// cargo-deps:` means
`RTLD_LOCAL` on both a cache hit and a miss, `// cargo-deps:` means
`RTLD_GLOBAL` on both.  Phase A only records this; it changes nothing.
"""
const SYMBOL_VISIBILITY_RULE = """
RTLD_GLOBAL is for libraries whose symbols other libraries resolve against \
(the ownership helper library); every leaf artifact reached through its own \
handle via dlsym is RTLD_LOCAL.\
"""

"""
    LoadPolicy

One explicit record of the load/compile policy for a single compiled artifact.

Construct one through a named constructor (see `inline_rustc_policy`,
`inline_cargo_policy`, `crate_policy`, `helper_library_policy`, and the rest of
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
    * `:unwind` — RustCall controls the build and does not set a panic mode, so
      Cargo's `unwind` default applies (the generated `[profile.release]` at
      `src/cargoproject.jl:126-128` writes only `opt-level`/`lto`);
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
  `:lib_basename` (generics), `:irust_hash` (`irust_<hash>`),
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

const _VALID_PANIC_STRATEGIES = (:abort, :unwind, :crate_profile)
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
                      panic_strategy, boundary_catches_panics,
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
    panic_strategy = :abort,
    boundary_catches_panics = false,
    registry = :rust_libraries,
    registry_key_kind = :content_hash,
    registration_mode = :replace,
    sets_current_lib = true,
    finalizer_frees = false,
    call_sites = ["src/cache.jl:270", "src/ruststr.jl:251",
                  "src/ruststr.jl:284", "src/ruststr.jl:291",
                  "src/compiler.jl:381", "src/structs.jl:282-285"],
    issues = [244, 249, 250],
    notes = "RTLD_LOCAL on both cache states, while the same construct with " *
            "// cargo-deps: is RTLD_GLOBAL on both of its; inline #[julia] " *
            "struct finalizers do not free.")

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
(`src/cargoproject.jl:126-128`), so the artifact **unwinds** while the direct
`rustc` path aborts — and no boundary catches the unwind (#244).
"""
inline_cargo_policy() = LoadPolicy("inline-cargo";
    dlopen_flags = Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW,
    panic_strategy = :unwind,
    boundary_catches_panics = false,
    registry = :rust_libraries,
    registry_key_kind = :content_hash,
    sets_current_lib = true,
    finalizer_frees = false,
    call_sites = ["src/ruststr.jl:386", "src/ruststr.jl:389",
                  "src/ruststr.jl:419", "src/ruststr.jl:426",
                  "src/cargoproject.jl:126-128"],
    issues = [244, 250],
    notes = "Cargo path unwinds while the rustc path aborts, and loads " *
            "RTLD_GLOBAL where the rustc path loads RTLD_LOCAL.")

"""
    crate_policy() -> LoadPolicy

`@rust_crate` bindings, both the in-memory module (`src/crate_bindings.jl:344`)
and the emitted bindings file template (`src/crate_bindings.jl:1360`).

The handle lives in a module-local `_LIB_HANDLE` `Ref`, not in `RUST_LIBRARIES`,
so `RustCall`-level unload never sees it.  Crate structs *do* free in their
finalizer (`src/crate_bindings.jl:550`), the opposite of inline structs (#249).

Panic strategy is `:crate_profile`, not `:unwind`: `build_crate_directly`
(`src/crate_bindings.jl:914-925`) points a `CargoProject` at the user's own
crate directory and runs Cargo there, so the effective profile is the user's —
a `[profile.release] panic = "abort"` in their `Cargo.toml`, a workspace
profile, `.cargo/config.toml`, or `CARGO_PROFILE_RELEASE_PANIC` are all
honoured, and RustCall neither sets nor reads it.  Phase B must either read the
effective profile (`cargo metadata` / `cargo config get`) or force the strategy
explicitly on the command line before it can promise one panic policy across
doors (#244).
"""
crate_policy() = LoadPolicy("rust-crate";
    dlopen_flags = Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW,
    panic_strategy = :crate_profile,
    boundary_catches_panics = false,
    registry = :module_local,
    registry_key_kind = :none,
    sets_current_lib = false,
    finalizer_frees = true,
    call_sites = ["src/crate_bindings.jl:344", "src/crate_bindings.jl:550",
                  "src/crate_bindings.jl:914-925", "src/crate_bindings.jl:1360"],
    issues = [244, 249, 250],
    notes = "Only front door whose struct finalizers free; handle is not in " *
            "RUST_LIBRARIES so it cannot be unloaded through the registry; " *
            "and Cargo runs in the user's crate, so the panic strategy is " *
            "whatever their effective profile says.")

"""
    helper_library_policy() -> LoadPolicy

The ownership helper library `deps/rust_helpers`, loaded by
`src/memory.jl:215` and `:321` into `RUST_HELPERS_LIB`.

This is the one library other artifacts could legitimately need to resolve
symbols against (`SYMBOL_VISIBILITY_RULE`), yet it is the one loaded
`RTLD_LOCAL` today.  Recorded as-is; Phase A changes nothing.

Panic strategy is `:unwind`, not `:abort`: the helper library is built by
`deps/build.jl:97-98` with a plain `cargo build --release --manifest-path ...`,
and `deps/rust_helpers/Cargo.toml` (9 lines, `[package]`/`[lib]`/`[dependencies]`
only) declares no `[profile.release]` and therefore no `panic` key, so Cargo's
`unwind` default applies.  Together with the two Cargo-backed inline paths and
`@rust_crate`, that makes the helper library a fourth unwinding artifact with no
`catch_unwind` boundary (#244).
"""
helper_library_policy() = LoadPolicy("helper-library";
    dlopen_flags = Libdl.RTLD_LOCAL | Libdl.RTLD_NOW,
    panic_strategy = :unwind,
    boundary_catches_panics = false,
    registry = :helper_slot,
    registry_key_kind = :none,
    sets_current_lib = false,
    finalizer_frees = true,
    call_sites = ["src/memory.jl:215", "src/memory.jl:321",
                  "deps/build.jl:97-98", "deps/rust_helpers/Cargo.toml"],
    issues = [244, 250],
    notes = "RTLD_LOCAL despite being the only library whose symbols other " *
            "artifacts might resolve against — the visibility rule is " *
            "inverted; and built by plain `cargo build --release`, so it " *
            "unwinds like the other Cargo-backed artifacts.")

"""
    generics_policy() -> LoadPolicy

Monomorphized generic instantiation (`src/generics.jl:243`, registered at
`:252` under the library *basename* rather than a content hash, and never
touching `CURRENT_LIB`).

Registration mode is `:insert_only`: `src/generics.jl:250-253` writes the entry
only `if !haskey(RUST_LIBRARIES, lib_name)`, and that guard is load-bearing.
`_unique_source_name` (`src/compiler.jl:68-72`) returns the fixed base name
`rust_code` whenever debug mode is off, so every instantiation compiled into
its own temp directory yields the same `librust_code` basename — the registry
key collides across instantiations.  Replacing the entry would swap the live
handle and throw away the accumulated function-pointer cache that
`src/generics.jl:267` fills, so Phase B must preserve the insert-only
behaviour (or key these libraries by content, which is a behaviour change and
therefore not Phase A).
"""
generics_policy() = LoadPolicy("generics-monomorphization";
    dlopen_flags = Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW,
    panic_strategy = :abort,
    boundary_catches_panics = false,
    registry = :rust_libraries,
    registry_key_kind = :lib_basename,
    registration_mode = :insert_only,
    sets_current_lib = false,
    finalizer_frees = false,
    call_sites = ["src/compiler.jl:68-72", "src/generics.jl:243",
                  "src/generics.jl:250-253", "src/generics.jl:267"],
    issues = [250],
    notes = "Registers under a colliding basename key and only when absent, " *
            "unlike every other RUST_LIBRARIES writer.")

"""
    irust_policy() -> LoadPolicy

`@irust` snippet compilation (`src/ruststr.jl:822`, registered at `:837` under
an `irust_<hash>` key together with the `IRUST_FUNCTIONS` entry).
"""
irust_policy() = LoadPolicy("irust";
    dlopen_flags = Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW,
    panic_strategy = :abort,
    boundary_catches_panics = false,
    registry = :rust_libraries,
    registry_key_kind = :irust_hash,
    sets_current_lib = false,
    finalizer_frees = false,
    call_sites = ["src/ruststr.jl:822", "src/ruststr.jl:837"],
    issues = [250],
    notes = "RTLD_GLOBAL for a leaf artifact; IRUST_FUNCTIONS is updated in " *
            "the same locked block but is not part of any unload path.")

"""
    hot_reload_policy() -> LoadPolicy

Hot reload of a `@rust_crate` crate (`src/hot_reload.jl:205`, re-registered at
`:210`).  The rebuild happens outside `REGISTRY_LOCK`, and a failed rebuild
currently leaves the registry without the previous entry (#255).

Like `crate_policy`, the panic strategy is `:crate_profile`: `rebuild_crate`
runs `cargo build --release --manifest-path <user crate>` against their crate
(`src/hot_reload.jl:264`), so their profile decides.
"""
hot_reload_policy() = LoadPolicy("hot-reload";
    dlopen_flags = Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW,
    panic_strategy = :crate_profile,
    boundary_catches_panics = false,
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
    dlopen_flags = Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW,
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
    crate_policy,
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
    dlopen_flags(policy::LoadPolicy) -> UInt32

The flag set to hand to `Libdl.dlopen`.
"""
dlopen_flags(policy::LoadPolicy) = policy.dlopen_flags

"""
    uses_global_symbols(policy::LoadPolicy) -> Bool

Whether this policy publishes the artifact's symbols process-globally.
"""
uses_global_symbols(policy::LoadPolicy) = policy.global_symbols

"""
    rustc_panic_flags(policy::LoadPolicy) -> Vector{String}

The `rustc` arguments implied by the policy's panic strategy — `["-C",
"panic=abort"]` for `:abort`, empty for `:unwind` (rustc's default), and
`missing` for `:crate_profile`, where the build is Cargo's inside the user's
crate and RustCall does not drive `rustc` at all.
Mirrors `src/compiler.jl:219`, `:381`.
"""
function rustc_panic_flags(policy::LoadPolicy)
    policy.panic_strategy === :crate_profile && return missing
    return policy.panic_strategy === :abort ? ["-C", "panic=abort"] : String[]
end

"""
    cargo_profile_panic_line(policy::LoadPolicy) -> Union{String, Nothing}

The line the generated `[profile.release]` section needs to honour the policy's
panic strategy, or `nothing` when the Cargo default already matches.
`src/cargoproject.jl` emits no such line today, which is why the Cargo path
unwinds (#244).

Returns `missing` for `:crate_profile`: RustCall generates no `Cargo.toml` for
those doors — the manifest is the user's — so there is no line for it to write,
and Phase B has to read the effective profile (`cargo metadata` /
`cargo config get`) or force the strategy on the command line instead.
"""
function cargo_profile_panic_line(policy::LoadPolicy)
    policy.panic_strategy === :crate_profile && return missing
    return policy.panic_strategy === :abort ? "panic = \"abort\"" : nothing
end

"""
    requires_catch_unwind_boundary(policy::LoadPolicy) -> Bool

Whether a generated `extern "C"` wrapper for this artifact must wrap the user
body in `std::panic::catch_unwind` to keep a panic from crossing the FFI
boundary.  `true` exactly when the artifact unwinds and the boundary does not
already catch — i.e. on every path RustCall builds with Cargo today (#244).

Returns **`missing`** for `:crate_profile`: whether those artifacts unwind is
decided by the user's Cargo profile, which Phase A does not read.  Callers that
need a decision rather than a fact should use `must_assume_unwind`, which
resolves the unknown conservatively.
"""
function requires_catch_unwind_boundary(policy::LoadPolicy)
    policy.boundary_catches_panics && return false
    policy.panic_strategy === :crate_profile && return missing
    return policy.panic_strategy === :unwind
end

"""
    must_assume_unwind(policy::LoadPolicy) -> Bool

The conservative resolution of `requires_catch_unwind_boundary`: `true` unless
the artifact is known to abort or the boundary already catches.  An unknown
(`:crate_profile`) strategy resolves to `true`, because a boundary that catches
a panic that cannot happen is merely redundant, while a missing boundary on an
unwinding artifact is undefined behaviour (#244).
"""
function must_assume_unwind(policy::LoadPolicy)
    policy.boundary_catches_panics && return false
    return policy.panic_strategy !== :abort
end

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

Subsumes the seven open-coded `RUST_LIBRARIES[...] = (handle, Dict())` sites:
`src/ruststr.jl:251`, `:291`, `:389`, `:426`, `:837`, `src/generics.jl:252`,
`src/hot_reload.jl:210`.  Not called from `src/` yet (Phase A is additive).
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

Remove the `RUST_LIBRARIES` entry and its function-pointer cache under
`REGISTRY_LOCK`, clearing `CURRENT_LIB[]` if it pointed at `lib_name`.
Returns whether an entry was removed.  Does not `dlclose`: Phase B decides that
together with the unload purge described in #250.
"""
function unregister_library!(policy::LoadPolicy, lib_name::AbstractString)
    name = String(lib_name)
    registers_in_rust_libraries(policy) || return false
    return lock(REGISTRY_LOCK) do
        removed = haskey(RUST_LIBRARIES, name)
        if removed
            delete!(RUST_LIBRARIES, name)
        end
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
