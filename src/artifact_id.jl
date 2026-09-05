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
  dependency set (see [`artifact_dependency_strings`](@ref)).
- `features::Vector{String}`: crate features enabled for the build.
- `build_env::Vector{Pair{String, String}}`: build environment that reaches the
  compiler (`RUSTFLAGS`, `CARGO_*`, …), sorted by name.
- `toolchain::String`: [`toolchain_fingerprint`](@ref) — extractor digest,
  manifest schema, `rustcall_core` / `juliacall_macros` sources.
- `compiler::String`: identity of the compiler that actually runs, from
  `RustToolChain` (see [`artifact_compiler_identity`](@ref)).
- `extra::Vector{Pair{String, String}}`: escape hatch for pipeline-specific
  inputs that do not yet deserve a field of their own.

Two `ArtifactId`s are `==` exactly when they encode identically, which is
exactly when [`artifact_key`](@ref) agrees.
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

Keyword constructor. `toolchain` defaults to [`toolchain_fingerprint`](@ref) and
`compiler` to [`artifact_compiler_identity`](@ref); pass them explicitly only in
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
cannot be determined throws a [`RustError`](@ref) instead, because an
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
netstring-framed, prefixed by [`ARTIFACT_ID_SCHEMA_VERSION`](@ref). Distinct
records always encode to distinct bytes.

Exposed mainly so tests can assert injectivity directly; production code wants
[`artifact_key`](@ref).
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
[`artifact_short_id`](@ref) when you need a name a human will read.

```julia
id = RustCall.ArtifactId(kind = "rustc", source = code, target_triple = triple)
key = RustCall.artifact_key(id)
```
"""
artifact_key(id::ArtifactId)::String = bytes2hex(sha256(artifact_encoding(id)))

"""
    artifact_key(; kwargs...) -> String

Convenience form: build an [`ArtifactId`](@ref) from the keyword arguments and
hash it.
"""
artifact_key(; kwargs...) = artifact_key(ArtifactId(; kwargs...))

"""
    artifact_short_id(id::ArtifactId, n::Int = ARTIFACT_SHORT_ID_LEN) -> String
    artifact_short_id(key::AbstractString, n::Int = ARTIFACT_SHORT_ID_LEN) -> String

The one place in the design where a key is truncated: the first `n` hex
characters of [`artifact_key`](@ref), for human-readable names only (library
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
`dependencies` field of [`ArtifactId`](@ref).

Accepts anything with the `DependencySpec` shape (`name`, `version`, `features`,
`git`, `path`) as well as plain strings, so it can be used before
`dependencies.jl` types are in scope. Every component is named in the output, so
distinct specs never collapse onto the same string.
"""
function artifact_dependency_strings(deps)::Vector{String}
    out = String[]
    for d in deps
        if d isa AbstractString
            push!(out, String(d))
        elseif hasproperty(d, :name)
            version = hasproperty(d, :version) ? getproperty(d, :version) : nothing
            git = hasproperty(d, :git) ? getproperty(d, :git) : nothing
            path = hasproperty(d, :path) ? getproperty(d, :path) : nothing
            feats = hasproperty(d, :features) ? collect(String.(getproperty(d, :features))) : String[]
            push!(out, string(
                "name=", getproperty(d, :name),
                " version=", version === nothing ? "" : version,
                " features=[", join(sort(feats), ","), "]",
                " git=", git === nothing ? "" : git,
                " path=", path === nothing ? "" : path,
            ))
        else
            push!(out, string(d))
        end
    end
    return sort!(out)
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
    ARTIFACT_BUILD_ENV_VARS

Environment variables known to change the binary a build produces. Anything
added here is folded into every key computed with [`artifact_build_env`](@ref),
once, instead of being patched into individual formulas.
"""
const ARTIFACT_BUILD_ENV_VARS = String[
    "CARGO_BUILD_RUSTFLAGS",
    "CARGO_BUILD_TARGET",
    "CARGO_ENCODED_RUSTFLAGS",
    "CARGO_PROFILE_RELEASE_LTO",
    "CARGO_TARGET_DIR",
    "RUSTC_WRAPPER",
    "RUSTDOCFLAGS",
    "RUSTFLAGS",
]

"""
    artifact_build_env(names = ARTIFACT_BUILD_ENV_VARS; env = ENV) -> Vector{Pair{String, String}}

Snapshot of the build environment variables that reach the compiler, sorted by
name and with absent variables recorded as absent (rather than silently
dropped). Suitable for the `build_env` field of [`ArtifactId`](@ref).
"""
function artifact_build_env(names = ARTIFACT_BUILD_ENV_VARS; env = ENV)
    out = Pair{String, String}[]
    for n in sort(collect(String.(names)))
        push!(out, n => get(env, n, ""))
    end
    return out
end

"""
    artifact_codegen_options(compiler) -> Vector{Pair{String, String}}

Codegen options of a `RustCompiler` in a fixed order, for the `codegen` field of
[`ArtifactId`](@ref).
"""
function artifact_codegen_options(compiler)
    return Pair{String, String}[
        "opt_level" => string(compiler.optimization_level),
        "debug_info" => string(compiler.emit_debug_info),
    ]
end
