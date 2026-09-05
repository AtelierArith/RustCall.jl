# Artifact identity — one record, one hash function.
#
# Background: issue #278. "Which compiled artifact corresponds to this request?"
# is currently answered independently at eight call sites, each with its own
# component list, its own concatenation format and its own truncation. That is
# the structural cause of #247 (lossy monomorphization key), #252 (the `rustc`
# in the key is not the `rustc` that compiles) and of the repeated Cargo cache
# patches (dependency set, then build environment).
#
# This file is Phase A of the fix and is deliberately ADDITIVE: it introduces
# the record and the hash function, but no call site has been migrated yet.
# Phase B replaces the eight ad-hoc formulas with `artifact_key`.
#
# Design rules encoded here:
#
# 1. Exhaustive record. `ArtifactId` names every input that can change the
#    produced binary. Adding an input means adding a field, once.
# 2. Order preserving. Type parameters are a `Vector{Pair}` in declaration
#    order, never a sorted set of values, so `pair<i32,i64>` and
#    `pair<i64,i32>` can never share a key (#247).
# 3. The compiler in the key is the compiler that runs. Versions come from
#    `RustToolChain.rustc()` / `RustToolChain.cargo()`, not from a bare `rustc`
#    on `PATH`, and a version that cannot be determined is an error rather than
#    the string `"unknown"` (#252).
# 4. Injective encoding. Every field is netstring-encoded (`<byte length>:<bytes>,`)
#    so no two distinct records can produce the same byte stream. Naive
#    concatenation ("a" * "bc" == "ab" * "c") is impossible by construction.
# 5. One truncation rule, in one place. `artifact_key` is never truncated;
#    `artifact_short_id` is the only truncation in the design, and it exists
#    solely for human-readable names (library names, temp project directories).

using SHA: sha256
using TOML
using RustToolChain: rustc, cargo

"""
    ARTIFACT_ID_SCHEMA_VERSION

Version of the `ArtifactId` encoding itself. Bumping it invalidates every key
produced by `artifact_key`, which is what you want whenever a field is added,
removed or re-ordered.
"""
const ARTIFACT_ID_SCHEMA_VERSION = 1

"""
    ARTIFACT_SHORT_ID_LEN

The single truncation rule of the artifact-identity design: `artifact_short_id`
keeps this many leading hex characters (64 bits of the SHA-256 digest).

Truncation is for human-readable names only — library names, temporary Cargo
project directories, debug output. Lookup keys (`artifact_key`) are never
truncated.
"""
const ARTIFACT_SHORT_ID_LEN = 16

"""
    ArtifactId

Exhaustive record of everything that can change the binary produced for one
compilation request. Construct it with keyword arguments; every field has a
neutral default so a caller only names what applies to it.

# Fields
- `kind::String`: which pipeline produced the artifact (`"rustc"`, `"cargo"`,
  `"crate"`, `"monomorphization"`, …). Keeps otherwise-identical inputs from
  different pipelines apart.
- `source::String`: the Rust source *after* `#[julia]` expansion and wrapping —
  the text actually handed to the compiler.
- `type_params::Vector{Pair{String, String}}`: generic parameter bindings in
  **declaration order**, e.g. `["T" => "i32", "U" => "i64"]`. Order is part of
  the identity (#247).
- `target_triple::String`: target triple.
- `codegen::Vector{Pair{String, String}}`: codegen options (optimization level,
  debug info, release/debug profile, LTO, …), in a caller-fixed order.
- `cfg::Vector{String}`: `--cfg` snapshot / feature-gate state.
- `dependencies::Vector{String}`: canonical, sorted description of the
  dependency set (see `artifact_dependency_strings`).
- `features::Vector{String}`: crate features enabled for the build.
- `build_env::Vector{Pair{String, String}}`: build environment that reaches the
  compiler (`RUSTFLAGS`, `CARGO_*`, …), sorted by name.
- `toolchain::String`: `toolchain_fingerprint` — extractor digest,
  manifest schema, `rustcall_core` / `juliacall_macros` sources.
- `compiler::String`: identity of the compiler that actually runs, from
  `RustToolChain` (see `artifact_compiler_identity`).
- `extra::Vector{Pair{String, String}}`: escape hatch for pipeline-specific
  inputs that do not yet deserve a field of their own.

Two `ArtifactId`s are `==` exactly when they encode identically, which is
exactly when `artifact_key` agrees.
"""
struct ArtifactId
    kind::String
    source::String
    type_params::Vector{Pair{String, String}}
    target_triple::String
    codegen::Vector{Pair{String, String}}
    cfg::Vector{String}
    dependencies::Vector{String}
    features::Vector{String}
    build_env::Vector{Pair{String, String}}
    toolchain::String
    compiler::String
    extra::Vector{Pair{String, String}}
end

"""
    ArtifactId(; kind, source, ...) -> ArtifactId

Keyword constructor. `toolchain` defaults to `toolchain_fingerprint` and
`compiler` to `artifact_compiler_identity`; pass them explicitly only in
tests that need to vary them.
"""
function ArtifactId(;
    kind::AbstractString,
    source::AbstractString = "",
    type_params = Pair{String, String}[],
    target_triple::AbstractString = "",
    codegen = Pair{String, String}[],
    cfg = String[],
    dependencies = String[],
    features = String[],
    build_env = Pair{String, String}[],
    toolchain::AbstractString = toolchain_fingerprint(),
    compiler::AbstractString = artifact_compiler_identity(),
    extra = Pair{String, String}[],
)
    return ArtifactId(
        String(kind),
        String(source),
        _pairs(type_params),
        String(target_triple),
        _pairs(codegen),
        _strings(cfg),
        _strings(dependencies),
        _strings(features),
        _pairs(build_env),
        String(toolchain),
        String(compiler),
        _pairs(extra),
    )
end

_strings(xs) = String[string(x) for x in xs]

function _pairs(xs)
    out = Pair{String, String}[]
    for x in xs
        if x isa Pair
            push!(out, string(first(x)) => string(last(x)))
        else
            throw(ArgumentError("expected a Pair, got $(typeof(x))"))
        end
    end
    return out
end

function Base.:(==)(a::ArtifactId, b::ArtifactId)
    return artifact_encoding(a) == artifact_encoding(b)
end

Base.hash(id::ArtifactId, h::UInt) = hash(artifact_encoding(id), h)

function Base.show(io::IO, id::ArtifactId)
    print(io, "ArtifactId(", id.kind, ", ", artifact_short_id(id), ")")
end

# ----------------------------------------------------------------------------
# Compiler identity (#252)
# ----------------------------------------------------------------------------

const _ARTIFACT_COMPILER_IDENTITY = Ref{String}("")
const _ARTIFACT_COMPILER_LOCK = ReentrantLock()

"""
    artifact_compiler_identity() -> String

Identity of the toolchain that actually compiles: the `--version` strings of
`RustToolChain.rustc()` and `RustToolChain.cargo()` — the very commands
`src/compiler.jl` and `src/cargobuild.jl` invoke.

This is deliberately *not* `_get_rustc_version()` in `src/cache.jl`, which
shells out to a bare `rustc` from `PATH` and degrades to `"unknown"`; upgrading
the real toolchain then need not invalidate anything (#252). Here a version that
cannot be determined throws a `RustError` instead, because an
unidentifiable compiler cannot produce a trustworthy cache key.

The result is memoized for the session.
"""
function artifact_compiler_identity()::String
    lock(_ARTIFACT_COMPILER_LOCK) do
        if isempty(_ARTIFACT_COMPILER_IDENTITY[])
            rustc_ver = _tool_version(rustc, "rustc")
            cargo_ver = _tool_version(cargo, "cargo")
            _ARTIFACT_COMPILER_IDENTITY[] = string("rustc=", rustc_ver, "\ncargo=", cargo_ver)
        end
        return _ARTIFACT_COMPILER_IDENTITY[]
    end
end

function _tool_version(getcmd, name::AbstractString)::String
    local out
    try
        out = strip(read(`$(getcmd()) --version`, String))
    catch e
        throw(RustError(
            "Cannot determine the version of `$(name)` via RustToolChain; " *
            "an unidentifiable compiler cannot be part of an artifact key (#252).",
            Int32(0), e))
    end
    if isempty(out)
        throw(RustError(
            "`$(name) --version` produced no output; an unidentifiable compiler " *
            "cannot be part of an artifact key (#252)."))
    end
    return String(out)
end

# ----------------------------------------------------------------------------
# Injective encoding
# ----------------------------------------------------------------------------

# Netstring: `<byte length>:<bytes>,`. Self-delimiting, so a stream of them is
# uniquely decodable and the encoding is injective. This is what makes
# `"a" * "bc"` and `"ab" * "c"` distinguishable ("1:a,2:bc," vs "2:ab,1:c,").
function _netstring!(io::IO, s::AbstractString)
    bytes = codeunits(String(s))
    print(io, length(bytes))
    write(io, UInt8(':'))
    write(io, bytes)
    write(io, UInt8(','))
    return nothing
end

# Same framing for raw bytes (file contents), which need not be valid UTF-8.
function _netstring_bytes!(io::IO, bytes::AbstractVector{UInt8})
    print(io, length(bytes))
    write(io, UInt8(':'))
    write(io, bytes)
    write(io, UInt8(','))
    return nothing
end

function _netstrings!(io::IO, xs::Vector{String})
    _netstring!(io, string(length(xs)))
    for x in xs
        _netstring!(io, x)
    end
    return nothing
end

function _netpairs!(io::IO, xs::Vector{Pair{String, String}})
    _netstring!(io, string(length(xs)))
    for (k, v) in xs
        _netstring!(io, k)
        _netstring!(io, v)
    end
    return nothing
end

"""
    artifact_encoding(id::ArtifactId) -> Vector{UInt8}

Canonical, injective byte encoding of `id`: a fixed field order, every field
netstring-framed, prefixed by `ARTIFACT_ID_SCHEMA_VERSION`. Distinct
records always encode to distinct bytes.

Exposed mainly so tests can assert injectivity directly; production code wants
`artifact_key`.
"""
function artifact_encoding(id::ArtifactId)::Vector{UInt8}
    io = IOBuffer()
    _netstring!(io, "rustcall.artifact_id/v$(ARTIFACT_ID_SCHEMA_VERSION)")
    _netstring!(io, id.kind)
    _netstring!(io, id.source)
    _netpairs!(io, id.type_params)
    _netstring!(io, id.target_triple)
    _netpairs!(io, id.codegen)
    _netstrings!(io, id.cfg)
    _netstrings!(io, id.dependencies)
    _netstrings!(io, id.features)
    _netpairs!(io, id.build_env)
    _netstring!(io, id.toolchain)
    _netstring!(io, id.compiler)
    _netpairs!(io, id.extra)
    return take!(io)
end

"""
    artifact_key(id::ArtifactId) -> String

**The** artifact-identity function: the SHA-256 of the canonical encoding of
`id`, as 64 lowercase hex characters.

Never truncated — the lookup key carries the full digest. Use
`artifact_short_id` when you need a name a human will read.

```julia
id = RustCall.ArtifactId(kind = "rustc", source = code, target_triple = triple)
key = RustCall.artifact_key(id)
```
"""
artifact_key(id::ArtifactId)::String = bytes2hex(sha256(artifact_encoding(id)))

"""
    artifact_key(; kwargs...) -> String

Convenience form: build an `ArtifactId` from the keyword arguments and
hash it.
"""
artifact_key(; kwargs...) = artifact_key(ArtifactId(; kwargs...))

"""
    artifact_short_id(id::ArtifactId, n::Int = ARTIFACT_SHORT_ID_LEN) -> String
    artifact_short_id(key::AbstractString, n::Int = ARTIFACT_SHORT_ID_LEN) -> String

The one place in the design where a key is truncated: the first `n` hex
characters of `artifact_key`, for human-readable names only (library
names, temporary Cargo project directories, log lines).

Never use the result as a cache lookup key: correctness must depend on the full
digest.
"""
artifact_short_id(id::ArtifactId, n::Int = ARTIFACT_SHORT_ID_LEN) =
    artifact_short_id(artifact_key(id), n)

function artifact_short_id(key::AbstractString, n::Int = ARTIFACT_SHORT_ID_LEN)
    n > 0 || throw(ArgumentError("short id length must be positive, got $(n)"))
    n <= length(key) || throw(ArgumentError(
        "short id length $(n) exceeds key length $(length(key))"))
    return String(first(key, n))
end

# ----------------------------------------------------------------------------
# Canonicalization helpers for the record's collection fields
# ----------------------------------------------------------------------------

"""
    artifact_dependency_strings(deps) -> Vector{String}

Canonical, sorted string form of a dependency set, suitable for the
`dependencies` field of `ArtifactId`.

Accepts anything with the `DependencySpec` shape (`name`, `version`, `features`,
`git`, `path`) as well as plain strings, so it can be used before
`dependencies.jl` types are in scope. Every component is netstring-framed, so
distinct specs can never collapse onto the same string.

# How each kind of dependency is identified

- **Registry** dependencies: name, version requirement and feature set. The
  *resolved* version from `Cargo.lock` is deliberately out of scope for Phase A
  (see #256); folding lockfile resolution into the key is a Phase B item.
- **Git** dependencies: name and the git URL (plus rev/branch/tag when the spec
  carries them). Resolving a floating branch to a commit is likewise Phase B.
- **Local path** dependencies: a content digest of the crate's inputs (see
  `artifact_path_dependency_digest`), **not** the path text. Editing a
  local dependency's sources therefore changes the key, while moving the
  checkout to a different directory does not — cache hits survive a move,
  which is the point of hashing content rather than location.
"""
function artifact_dependency_strings(deps)::Vector{String}
    out = String[]
    for d in deps
        io = IOBuffer()
        if d isa AbstractString
            _netstring!(io, "raw")
            _netstring!(io, String(d))
        elseif hasproperty(d, :name)
            version = hasproperty(d, :version) ? getproperty(d, :version) : nothing
            git = hasproperty(d, :git) ? getproperty(d, :git) : nothing
            path = hasproperty(d, :path) ? getproperty(d, :path) : nothing
            feats = hasproperty(d, :features) ? collect(String.(getproperty(d, :features))) : String[]
            _netstring!(io, "dep")
            _netstring!(io, string(getproperty(d, :name)))
            _netstring!(io, version === nothing ? "" : string(version))
            _netstrings!(io, sort(feats))
            _netstring!(io, git === nothing ? "" : string(git))
            # Local paths contribute their content, never their location.
            _netstring!(io, path === nothing ? "" : artifact_path_dependency_digest(string(path)))
        else
            _netstring!(io, "other")
            _netstring!(io, string(d))
        end
        push!(out, String(take!(io)))
    end
    return sort!(out)
end

"""
    artifact_path_dependency_digest(path::AbstractString) -> String

Deterministic SHA-256 digest of the *inputs* of a local path dependency: every
file Cargo considers part of the package, by sorted relative path with
contents, recursing into the path dependencies that `Cargo.toml` itself
declares.

The file set comes from `crate_input_files`, which asks Cargo
(`cargo package --list`) rather than assuming a layout, so a `build.rs`, a
`[lib] path` or `[[bin]] path` outside `src/`, a `#[path = "..."]` module and
`Cargo.lock` all reach the digest; the strategy that produced the set is hashed
alongside it.

Only content is hashed — never the absolute location — so an identical crate in
a differently named directory yields the same digest and a checkout move does
not invalidate the cache. `target/` is skipped. A path that does not exist, or a
`Cargo.toml` that cannot be parsed, is recorded as such rather than silently
ignored, and dependency cycles terminate at the first repeat.

Without this, a `path = "..."` dependency is identified by its path text alone
and editing its sources leaves the artifact key unchanged.
"""
function artifact_path_dependency_digest(path::AbstractString)::String
    io = IOBuffer()
    _hash_path_crate!(io, String(path), Set{String}())
    return bytes2hex(sha256(take!(io)))
end

function _hash_path_crate!(io::IO, path::AbstractString, seen::Set{String})
    dir = try
        abspath(String(path))
    catch
        String(path)
    end
    if !isdir(dir)
        _netstring!(io, "missing-crate")
        return nothing
    end
    canonical = try
        realpath(dir)
    catch
        dir
    end
    if canonical in seen
        _netstring!(io, "cycle")
        return nothing
    end
    push!(seen, canonical)

    _netstring!(io, "crate")
    strategy, files = crate_input_files(dir)
    # The strategy is part of the digest: a file set found by asking Cargo and
    # one found by walking the directory must never be able to collide.
    _netstring!(io, "strategy")
    _netstring!(io, strategy)
    _netstring!(io, string(length(files)))
    for rel in files
        _netstring!(io, rel)
        f = joinpath(dir, rel)
        if isfile(f)
            try
                _netstring_bytes!(io, read(f))
            catch
                _netstring!(io, "unreadable")
            end
        else
            # `cargo package --list` also names files it would synthesize
            # (Cargo.toml.orig, .cargo_vcs_info.json); record their absence.
            _netstring!(io, "not-on-disk")
        end
    end

    # Recurse into the path dependencies this crate declares itself.
    for child in _declared_path_dependencies(joinpath(dir, "Cargo.toml"))
        _netstring!(io, "path-dep")
        _netstring!(io, child)
        _hash_path_crate!(io, joinpath(dir, child), seen)
    end
    return nothing
end

"""
    CRATE_INPUT_VCS_DIRS

Directories never treated as crate inputs by the directory-walk fallback of
`crate_input_files`: build output and version-control metadata.
"""
const CRATE_INPUT_VCS_DIRS = String[
    ".bzr", ".git", ".hg", ".jj", ".pijul", ".svn", "target",
]

"""
    crate_input_files(dir::AbstractString) -> (strategy::String, files::Vector{String})

The set of files that make up a crate, as relative `/`-separated paths, sorted,
together with the name of the strategy that produced it.

Cargo already knows exactly which files are package inputs — it honours
`include`/`exclude`, `build = "..."`, `[lib] path`, `[[bin]] path`, modules
pulled in by `#[path = "..."]` and everything else outside `src/` — so ask it:

1. `cargo package --list --offline --allow-dirty` (no build, no network).
2. If that fails (manifest is a bare workspace, no lockfile resolvable offline,
   Cargo unavailable), fall back to walking the package directory for every
   regular file, skipping `CRATE_INPUT_VCS_DIRS`.

`Cargo.lock` is added whenever it exists, since `cargo package --list` omits it
for a library crate while it still pins what gets built.

The strategy name is returned, and hashed, so a file set obtained one way can
never collide with one obtained the other way.
"""
function crate_input_files(dir::AbstractString)
    dir = String(dir)
    manifest = joinpath(dir, "Cargo.toml")
    files = String[]
    strategy = "walk"

    if isfile(manifest)
        listed = try
            cmd = `$(cargo()) package --list --offline --allow-dirty --manifest-path $(manifest)`
            read(pipeline(cmd; stderr = devnull), String)
        catch
            ""
        end
        entries = String[strip(l) for l in split(listed, '\n') if !isempty(strip(l))]
        if !isempty(entries)
            files = entries
            strategy = "cargo-package-list"
        end
    end

    if strategy == "walk"
        for (root, dirs, names) in walkdir(dir)
            filter!(d -> !(d in CRATE_INPUT_VCS_DIRS), dirs)
            for n in names
                push!(files, relpath(joinpath(root, n), dir))
            end
        end
    end

    isfile(joinpath(dir, "Cargo.lock")) && push!(files, "Cargo.lock")

    files = String[replace(f, '\\' => '/') for f in files]
    unique!(files)
    sort!(files)
    return strategy, files
end

function _declared_path_dependencies(manifest::AbstractString)::Vector{String}
    isfile(manifest) || return String[]
    parsed = try
        TOML.parsefile(manifest)
    catch
        return String["unparsable-manifest"]
    end
    out = String[]
    for section in ("dependencies", "dev-dependencies", "build-dependencies")
        table = get(parsed, section, nothing)
        table isa AbstractDict || continue
        for (_, spec) in table
            spec isa AbstractDict || continue
            p = get(spec, "path", nothing)
            p isa AbstractString && push!(out, String(p))
        end
    end
    return sort!(unique!(out))
end

"""
    artifact_type_params(names, types) -> Vector{Pair{String, String}}

Build the `type_params` field from the **declared** parameter names and the
concrete types bound to them, preserving declaration order.

This is the ordered replacement for the sorted-values key at
`src/generics.jl:191-193`: sorting the values discards which parameter got which
type, so `Dict(:T => Int32, :U => Int64)` and `Dict(:T => Int64, :U => Int32)`
produce the same monomorphization key today (#247).
"""
function artifact_type_params(names, types)::Vector{Pair{String, String}}
    names_v = collect(names)
    types_v = collect(types)
    length(names_v) == length(types_v) || throw(ArgumentError(
        "got $(length(names_v)) parameter names but $(length(types_v)) types"))
    return Pair{String, String}[string(n) => string(t) for (n, t) in zip(names_v, types_v)]
end

"""
    artifact_type_params(param_order, bindings::AbstractDict) -> Vector{Pair{String, String}}

As above, but looking each parameter of `param_order` up in `bindings`
(a `Symbol`-keyed mapping such as the `type_params` argument of
`monomorphize_function`). The declared order wins; the dictionary's iteration
order is irrelevant.
"""
function artifact_type_params(param_order, bindings::AbstractDict)::Vector{Pair{String, String}}
    out = Pair{String, String}[]
    for p in param_order
        key = p isa Symbol ? p : Symbol(string(p))
        haskey(bindings, key) || throw(ArgumentError(
            "no binding for type parameter $(key)"))
        push!(out, string(key) => string(bindings[key]))
    end
    return out
end

"""
    ARTIFACT_BUILD_ENV_PREFIXES
    ARTIFACT_BUILD_ENV_NAMES
    ARTIFACT_BUILD_ENV_DENY_SUBSTRINGS

Which environment variables can change the binary a build produces, tracked by
**prefix and allowlist** rather than by enumerating individual keys: every
`CARGO_PROFILE_*` override (`_OPT_LEVEL`, `_CODEGEN_UNITS`, `_PANIC`, `_DEBUG`,
`_STRIP`, `_LTO`, …) changes generated code, and listing them one by one is the
same "remember to patch every formula" mistake #278 is about.

`ARTIFACT_BUILD_ENV_DENY_SUBSTRINGS` is applied **first** and unconditionally: a
name containing any of those substrings (case-insensitively) is never captured,
so registry credentials such as `CARGO_REGISTRY_TOKEN` or
`CARGO_REGISTRIES_<NAME>_TOKEN` can never enter an artifact key, be written to a
cache directory name, or be logged.

Build-script inputs (`CC`, `CFLAGS`, `PKG_CONFIG_PATH`, …) are a second,
separately documented allowlist: see `ARTIFACT_BUILD_SCRIPT_ENV_NAMES`.

This mirrors the environment-capture design PR #272 introduces in
`src/manifest.jl`. That PR is not on `main` yet, so the rule is implemented here
independently; Phase B of #278 unifies the two into this one place.
"""
const ARTIFACT_BUILD_ENV_PREFIXES = String[
    "CARGO_BUILD_",
    "CARGO_CFG_",
    "CARGO_ENCODED_RUSTFLAGS",
    "CARGO_PROFILE_",
]

"See `ARTIFACT_BUILD_ENV_PREFIXES`."
const ARTIFACT_BUILD_ENV_NAMES = String[
    "RUSTC",
    "RUSTC_WRAPPER",
    "RUSTDOCFLAGS",
    "RUSTFLAGS",
    "RUSTUP_TOOLCHAIN",
]

"See `ARTIFACT_BUILD_ENV_PREFIXES`."
const ARTIFACT_BUILD_ENV_DENY_SUBSTRINGS = String[
    "AUTH",
    "CREDENTIAL",
    "KEY",
    "PASSWORD",
    "SECRET",
    "TOKEN",
]

"""
    ARTIFACT_BUILD_SCRIPT_ENV_NAMES
    ARTIFACT_BUILD_SCRIPT_ENV_PREFIXES
    ARTIFACT_BUILD_SCRIPT_ENV_SUFFIXES

The second allowlist: variables that reach the **build scripts** of
dependencies. `cc-rs`, `pkg-config`, `cmake-rs` and `bindgen` all read the
ambient environment of this process, so `CC`, `CFLAGS`, `PKG_CONFIG_PATH`,
`LIBCLANG_PATH` and friends change the native objects that end up in the
artifact while nothing about the Rust source changes.

`ARTIFACT_BUILD_SCRIPT_ENV_SUFFIXES` covers the per-target convention
(`x86_64_unknown_linux_gnu_CC`); the equivalent `CC_x86_64-unknown-linux-gnu`
spelling, which `cc-rs` also accepts, is covered by the prefixes.

!!! note "Best effort by construction"
    No allowlist can be complete: a build script may read any variable it
    likes, and the only exhaustive answer is Cargo's own fingerprint. This set
    is therefore a safety net, not a proof. Phase B of #278 must treat a change
    in the captured set as **rebuild**, never as grounds to reuse an artifact —
    a captured variable that changed means "stale", while an unchanged captured
    set does not by itself prove "fresh".
"""
const ARTIFACT_BUILD_SCRIPT_ENV_NAMES = String[
    "AR", "ASFLAGS", "CC", "CFLAGS", "CPPFLAGS", "CXX", "CXXFLAGS",
    "LD", "LDFLAGS", "NM", "RANLIB", "STRIP",
]

"See `ARTIFACT_BUILD_SCRIPT_ENV_NAMES`."
const ARTIFACT_BUILD_SCRIPT_ENV_PREFIXES = String[
    "AR_", "BINDGEN_", "CARGO_FEATURE_", "CC_", "CFLAGS_", "CLANG_", "CMAKE_",
    "CXXFLAGS_", "CXX_", "HOST_", "LDFLAGS_", "LIBCLANG_", "LINKER_",
    "PKG_CONFIG", "TARGET_",
]

"See `ARTIFACT_BUILD_SCRIPT_ENV_NAMES`."
const ARTIFACT_BUILD_SCRIPT_ENV_SUFFIXES = String[
    "_AR", "_CC", "_CFLAGS", "_CXX", "_CXXFLAGS", "_LDFLAGS", "_LINKER",
]

"""
    artifact_build_env_captured(name::AbstractString) -> Bool

Whether `name` is a build variable that belongs in an artifact key. Secrets are
rejected before the allowlist is consulted; see
`ARTIFACT_BUILD_ENV_PREFIXES`.
"""
function artifact_build_env_captured(name::AbstractString)::Bool
    upper = uppercase(String(name))
    # Secrets are rejected first, over both allowlists, unconditionally.
    for bad in ARTIFACT_BUILD_ENV_DENY_SUBSTRINGS
        occursin(bad, upper) && return false
    end
    # Allowlist 1: Cargo/rustc inputs.
    upper in ARTIFACT_BUILD_ENV_NAMES && return true
    for prefix in ARTIFACT_BUILD_ENV_PREFIXES
        startswith(upper, prefix) && return true
    end
    # CARGO_TARGET_<TRIPLE>_RUSTFLAGS / _LINKER, per-target overrides.
    if startswith(upper, "CARGO_TARGET_") &&
       (endswith(upper, "_RUSTFLAGS") || endswith(upper, "_LINKER"))
        return true
    end
    # Allowlist 2: build-script inputs (cc-rs, pkg-config, cmake, bindgen).
    upper in ARTIFACT_BUILD_SCRIPT_ENV_NAMES && return true
    for prefix in ARTIFACT_BUILD_SCRIPT_ENV_PREFIXES
        startswith(upper, prefix) && return true
    end
    for suffix in ARTIFACT_BUILD_SCRIPT_ENV_SUFFIXES
        endswith(upper, suffix) && return true
    end
    return false
end

"""
    ARTIFACT_ENV_ABSENT

Marker recorded for a build variable that is **not set**, as opposed to one set
to the empty string. The two are different to Cargo — an empty `RUSTFLAGS`
suppresses the rustflags a Cargo config would otherwise contribute — so they
must never share a key. A variable that is set is recorded as
`"present:" * value`, which can never equal this marker.
"""
const ARTIFACT_ENV_ABSENT = "absent"

_artifact_env_value(env, name) =
    haskey(env, name) ? string("present:", env[name]) : ARTIFACT_ENV_ABSENT

"""
    artifact_build_env(; env = ENV) -> Vector{Pair{String, String}}

Snapshot of every build variable in `env` that
`artifact_build_env_captured` accepts, sorted by name so the encoding is
deterministic. Values carry their presence explicitly (see
`ARTIFACT_ENV_ABSENT`). Suitable for the `build_env` field of
`ArtifactId`.
"""
function artifact_build_env(; env = ENV)
    names = String[String(k) for k in keys(env) if artifact_build_env_captured(String(k))]
    sort!(names)
    return Pair{String, String}[n => _artifact_env_value(env, n) for n in names]
end

"""
    artifact_build_env(names; env = ENV) -> Vector{Pair{String, String}}

As above but for an explicit list of variable names, sorted, with absent
variables recorded as `ARTIFACT_ENV_ABSENT` rather than dropped (so
"unset" and "set to the empty string" produce different keys). Names that
`artifact_build_env_captured` rejects — anything that looks like a
credential — are skipped even when named explicitly.
"""
function artifact_build_env(names; env = ENV)
    wanted = String[n for n in sort(collect(String.(names))) if artifact_build_env_captured(n)]
    return Pair{String, String}[n => _artifact_env_value(env, n) for n in wanted]
end

"""
    artifact_codegen_options(compiler) -> Vector{Pair{String, String}}

Codegen options of a `RustCompiler` in a fixed order, for the `codegen` field of
`ArtifactId`.
"""
function artifact_codegen_options(compiler)
    return Pair{String, String}[
        "opt_level" => string(compiler.optimization_level),
        "debug_info" => string(compiler.emit_debug_info),
    ]
end
