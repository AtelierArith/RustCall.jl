# Artifact identity — one record, one hash function.
#
# Background: issue #278. "Which compiled artifact corresponds to this request?"
# used to be answered independently at twelve call sites, each with its own
# component list, its own concatenation format and its own truncation. That was
# the structural cause of #247 (lossy monomorphization key), #252 (the `rustc`
# in the key is not the `rustc` that compiles) and of the repeated Cargo cache
# patches (dependency set, then build environment).
#
# Since Phase B this file is the only place identity is computed. Every key,
# library name and temporary project name in the package comes from
# `artifact_key` / `artifact_short_id`:
#
#   direct rustc    `generate_cache_key`, `_rustc_block_identity` (src/cache.jl,
#                   src/ruststr.jl) — one value for the disk key and the name
#   Cargo           `_cargo_block_id`, `_cargo_block_identity`,
#                   `build_cargo_project_cached`
#   generics        `_monomorphization_id` (src/generics.jl)
#   crate bindings  `compute_crate_hash` (src/crate_bindings.jl)
#   @irust          `_compile_and_call_irust` (src/ruststr.jl)
#
# `scripts/lint_artifact_identity.sh` keeps it that way: no other file in src/
# may concatenate key material, truncate a digest, or name an artifact with
# Julia's session-randomized `hash()`.
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
`src/compiler.jl` and `src/cargobuild.jl` invoke — together with any
`RUSTC_WRAPPER` / `RUSTC_WORKSPACE_WRAPPER` standing between Cargo and rustc,
since a wrapper changes what is produced.

This deliberately replaced `_get_rustc_version()` (deleted from `src/cache.jl`
in #278 Phase B), which shelled out to a bare `rustc` from `PATH` and degraded
to the string `"unknown"`, so upgrading the real toolchain need not invalidate
anything (#252). Here a version that cannot be determined throws a `RustError`
instead, because an unidentifiable compiler cannot produce a trustworthy cache
key. `toolchain_fingerprint` catches that and stays total; the paths about to
compile do not.

The result is memoized for the session.
"""
function artifact_compiler_identity()::String
    lock(_ARTIFACT_COMPILER_LOCK) do
        if isempty(_ARTIFACT_COMPILER_IDENTITY[])
            rustc_ver = _tool_version(rustc, "rustc")
            cargo_ver = _tool_version(cargo, "cargo")
            # A wrapper stands between Cargo and rustc and can change what is
            # produced (sccache, clippy-driver, a custom shim), so it is part
            # of the identity of the compiler that actually runs.
            wrapper = get(ENV, "RUSTC_WRAPPER", "")
            ws_wrapper = get(ENV, "RUSTC_WORKSPACE_WRAPPER", "")
            _ARTIFACT_COMPILER_IDENTITY[] = string(
                "rustc=", rustc_ver,
                "\ncargo=", cargo_ver,
                "\nrustc_wrapper=", wrapper,
                "\nrustc_workspace_wrapper=", ws_wrapper)
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

- **Registry** dependencies: name, version requirement and feature set — the
  *requested* range. The *resolved* version is not in the string on purpose:
  the strings name a dependency set, and `cargo_lockfile_id` uses exactly them
  to name the `Cargo.lock` persisted for that set, which must be the same file
  on every machine. The resolution reaches a **build's** key as the content
  digest of that lockfile (`_cargo_block_id`'s `cargo_lock`, #256).
- **Git** dependencies: name and the git URL (plus rev/branch/tag when the spec
  carries them). A floating branch is resolved to a commit in the same
  lockfile.
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
    cargo_lockfile_id(deps) -> ArtifactId

The identity of the **resolution** of a dependency set: what names the
`Cargo.lock` RustCall persists for a `// cargo-deps:` block (`lockfile_path`,
#256). Deliberately narrower than a build's identity — the dependency strings
of `artifact_dependency_strings` and nothing else, with the toolchain and
compiler fields empty — because the point of the persisted lockfile is to be
the same file on every machine that declares the same dependencies, whatever
`rustc` each of them runs; the *build* key then folds the lockfile's content
in (`_cargo_block_id`'s `cargo_lock`), so the resolved versions, not the
requested ranges, decide a cache hit.

A `path =` dependency contributes its content digest, as in every dependency
string, so editing a local crate re-resolves rather than replaying a lockfile
that pins the old graph.
"""
function cargo_lockfile_id(deps)::ArtifactId
    return ArtifactId(
        kind = "cargo-lockfile",
        dependencies = artifact_dependency_strings(deps),
        toolchain = "",
        compiler = "",
    )
end

# ----------------------------------------------------------------------------
# Memoization (issue #278 §8)
#
# `artifact_path_dependency_digest` is on the hot path of every Cargo-backed
# `rust"""` evaluation, and it spawns `cargo tree`. A warm no-op re-evaluation
# must not pay for that.
#
# Exactly one thing is cached, and it is the process spawn: the resolved
# dependency *graph*. File contents are **never** cached — every call reads and
# hashes every input byte.
#
# That asymmetry is deliberate. A `(mtime, size)` stamp is a fine invalidation
# hint and a terrible identity: a coarse-timestamp filesystem, a tool that
# preserves metadata, or a same-length edit inside one timestamp tick all alias
# distinct contents, and the consequence here is not a slow rebuild but running
# machine code compiled from source that no longer exists. Measured on the
# largest real crate tree to hand (142 files, 6 MB), reading and hashing every
# byte costs ~13 ms against ~0.3 ms to stat them — nothing next to the hundreds
# of milliseconds a `cargo tree` spawn costs, which is what §8 of #278 was
# actually about.
#
# The graph cache is validated against every manifest that can *decide* the
# graph, and by content rather than by stat:
#
#   * every crate in the cached graph, not only the root's — a transitive local
#     crate that grows a path dependency changes its own manifest while the
#     root's files stay untouched, and missing that drops a crate from the key
#     permanently;
#   * the **workspace root** each of those crates belongs to — a member inherits
#     `dep = { workspace = true }` from `[workspace.dependencies]` in a manifest
#     that is not in the package list at all, and for a *virtual* workspace that
#     manifest is not a package to begin with;
#   * hashed, not stat'd. A `(mtime, size)` pair aliases a same-length
#     `Cargo.toml` edit under a preserved timestamp — exactly the failure this
#     file refuses to accept for sources, and a manifest is a few hundred bytes,
#     so there is nothing to trade.
#
# A stamp is only ever a *rebuild trigger* here: re-resolving a graph that had
# not really changed costs one process spawn.
#
# The whole computation is skipped when a block declares no `path =` dependency:
# `artifact_dependency_strings` only asks for a digest when a spec carries one.
# ----------------------------------------------------------------------------

const _ARTIFACT_DIGEST_LOCK = ReentrantLock()

# canonical crate dir => (manifest stamps of every crate in the graph,
#                          (strategy, dirs))
const _PATH_DEP_GRAPH_CACHE = Dict{String, Tuple{Any, Tuple{String, Vector{String}}}}()

"""
    CARGO_TREE_INVOCATIONS

How many times `cargo tree` has been spawned this session. A test hook for the
performance requirement of #278.
"""
const CARGO_TREE_INVOCATIONS = Ref(0)

"""
    _artifact_reset_digest_caches!()

Forget the memoized dependency graphs. Nothing else is memoized, so this only
ever forces a re-resolution.
"""
function _artifact_reset_digest_caches!()
    lock(_ARTIFACT_DIGEST_LOCK) do
        empty!(_PATH_DEP_GRAPH_CACHE)
    end
    return nothing
end

# Content digest of one manifest, or a marker when it is not there. Hashed
# rather than stat'd: see the note above on same-length edits.
_manifest_digest(path::AbstractString) =
    isfile(path) ? _file_content_digest(path) : "absent"

# What decides one crate's contribution to a resolved local-dependency graph.
_graph_stamp(dir::AbstractString) =
    (_manifest_digest(joinpath(String(dir), "Cargo.toml")),
     _manifest_digest(joinpath(String(dir), "Cargo.lock")))

"""
    _workspace_root_dir(dir) -> Union{String, Nothing}

The directory of the workspace `dir` belongs to, or `nothing` when it belongs to
none.

That manifest decides the graph without appearing in it: a member writing
`dep = { workspace = true }` takes the path from `[workspace.dependencies]`
there, and a *virtual* workspace root is not a package at all, so it can never
show up in the package list `cargo tree` reports.

Cargo resolves the root two ways, and so does this:

1. an explicit `[package] workspace = "../elsewhere"` in the crate's own
   manifest, relative to that manifest's directory. It need not be an ancestor —
   a sibling is legal — so an ancestor-only search misses it entirely;
2. otherwise, the nearest manifest at or above `dir` declaring a `[workspace]`
   table.

The explicit key is only consulted on the crate's own manifest, which is where
Cargo reads it; an ancestor's `package.workspace` describes that ancestor, not
this crate.
"""
function _workspace_root_dir(dir::AbstractString)
    start = try
        abspath(String(dir))
    catch
        String(dir)
    end

    explicit = _explicit_workspace_root(start)
    explicit === nothing || return explicit

    current = start
    while true
        manifest = joinpath(current, "Cargo.toml")
        if isfile(manifest)
            parsed = _parse_manifest_or_nothing(manifest)
            if parsed isa AbstractDict && get(parsed, "workspace", nothing) isa AbstractDict
                # The nearest `[workspace]` is Cargo's one candidate. A package
                # it lists in `exclude` is not a member and is its own root —
                # Cargo does not keep searching upwards, and gives it none of
                # the root's inputs (#307 review).
                _workspace_excludes(parsed["workspace"], current, start) && return nothing
                return current
            end
        end
        parent = dirname(current)
        (isempty(parent) || parent == current) && return nothing
        current = parent
    end
end

# Whether the `[workspace]` table at `root` excludes `dir`, with Cargo's own
# rule (`WorkspaceRootConfig::is_excluded`): an `exclude` entry naming `dir`
# itself or a directory it lies under excludes it — *unless* a `members` entry
# names `dir` or a directory it lies under, in which case the explicit listing
# wins and the package stays a member (`members = ["crates/foo/bar"]` next to
# `exclude = ["crates/foo"]`, #307 review). Only a literal `members` entry
# counts: Cargo compares the raw list, so a glob (`crates/*`) rescues nothing.
function _workspace_excludes(workspace::AbstractDict, root::AbstractString, dir::AbstractString)
    target = abspath(String(dir))
    _workspace_lists(get(workspace, "exclude", nothing), root, target) || return false
    return !_workspace_lists(get(workspace, "members", nothing), root, target)
end

# Whether one of `entries` (paths relative to `root`) is `target` or a
# directory `target` lies under. Entries that are not strings, or that do not
# resolve, are skipped.
function _workspace_lists(entries, root::AbstractString, target::AbstractString)
    entries isa AbstractVector || return false
    for entry in entries
        entry isa AbstractString || continue
        path = try
            abspath(joinpath(String(root), String(entry)))
        catch
            continue
        end
        (target == path || startswith(target, joinpath(path, ""))) && return true
    end
    return false
end

# `[package] workspace = "../ws"` in this crate's own manifest, resolved against
# the manifest's directory. Cargo allows any path, ancestor or not.
function _explicit_workspace_root(dir::AbstractString)
    manifest = joinpath(String(dir), "Cargo.toml")
    isfile(manifest) || return nothing
    parsed = _parse_manifest_or_nothing(manifest)
    parsed isa AbstractDict || return nothing
    package = get(parsed, "package", nothing)
    package isa AbstractDict || return nothing
    declared = get(package, "workspace", nothing)
    declared isa AbstractString || return nothing
    root = try
        abspath(joinpath(String(dir), String(declared)))
    catch
        return nothing
    end
    return isdir(root) ? root : nothing
end

function _parse_manifest_or_nothing(manifest::AbstractString)
    return try
        TOML.parsefile(String(manifest))
    catch
        nothing
    end
end

# The manifest stamps of every crate in a resolved graph *and* of the workspace
# root each one belongs to, canonical-keyed and sorted so the comparison ignores
# the order Cargo reported them in. See the note at the top of this section for
# why both halves are needed.
function _graph_stamps(dirs)
    out = Pair{String, Any}[]
    seen = Set{String}()
    for d in dirs
        for candidate in (String(d), _workspace_root_dir(d))
            candidate === nothing && continue
            canonical = _canonical_dir(candidate)
            canonical in seen && continue
            push!(seen, canonical)
            push!(out, canonical => _graph_stamp(candidate))
        end
    end
    sort!(out; by = first)
    return out
end

# SHA-256 of one file's contents: streamed, so hashing a large crate builds no
# large intermediate buffer, and never memoized (see the section note above on
# why a `(mtime, size)` stamp must not stand in for content). An unreadable file
# gets a marker digest rather than an exception, so a crate whose permissions
# changed still produces a different key.
function _file_content_digest(path::AbstractString)::String
    return try
        bytes2hex(open(sha256, String(path)))
    catch
        "unreadable"
    end
end

"""
    _hashed_relative_path(rel::AbstractString) -> String

A crate-relative path in the form that goes into a digest: forward slashes
always, case-folded on Windows. Used only for hashed bytes;
`crate_input_files` still reports the real relative names.
"""
function _hashed_relative_path(rel::AbstractString)::String
    normalized = replace(String(rel), '\\' => '/')
    return Sys.iswindows() ? lowercase(normalized) : normalized
end

"""
    artifact_path_dependency_digest(path::AbstractString) -> String

Deterministic SHA-256 digest of the *inputs* of a local path dependency: the
contents of the crate directory, plus the contents of every other local crate
reachable from it through Cargo's resolved dependency graph.

Only content is hashed — never the absolute location — so an identical crate in
a differently named directory yields the same digest and a checkout move does
not invalidate the cache. Crates are folded in as a sorted set of per-crate
digests for the same reason: the order Cargo happens to report them in, and the
directory names they happen to live under, must not reach the key.

The file set of each crate comes from `crate_input_files` (a directory walk),
and the set of local crates from `local_path_dependency_dirs` (Cargo's resolved
graph). Both name the strategy they used, and both strategy names are hashed, so
results obtained different ways can never collide.

!!! warning "The remaining gap is unfixable here by construction"
    Only inputs that live *inside* a package directory are captured. A
    `#[path = "../../elsewhere/mod.rs"]` module, an `include_str!("../data")` or
    an `include_bytes!` of a file above the package root is compiled into the
    binary and will **not** change this digest. The only complete answer is
    Cargo's own fingerprint, which this cannot reimplement. This digest is
    therefore a *rebuild* trigger and never a proof of freshness: a change means
    stale, but no change does not by itself license reuse.

A path that does not exist is recorded as such rather than silently ignored, and
the function never throws.
"""
function artifact_path_dependency_digest(path::AbstractString)::String
    io = IOBuffer()
    root = try
        abspath(String(path))
    catch
        String(path)
    end

    if !isdir(root)
        _netstring!(io, "missing-crate")
        _netstring!(io, String(path))
        return bytes2hex(sha256(take!(io)))
    end

    graph_strategy, dirs = local_path_dependency_dirs(root)
    _netstring!(io, "graph-strategy")
    _netstring!(io, graph_strategy)

    root_canonical = _canonical_dir(root)
    _netstring!(io, "root")
    _netstring!(io, crate_content_digest(root))

    # Every other local crate contributes its content digest. Sorting the
    # digests keeps the result independent of both report order and location.
    others = String[]
    for d in dirs
        _canonical_dir(d) == root_canonical && continue
        push!(others, crate_content_digest(d))
    end
    unique!(others)
    sort!(others)
    _netstring!(io, "local-deps")
    _netstrings!(io, others)

    return bytes2hex(sha256(take!(io)))
end

function _canonical_dir(dir::AbstractString)::String
    try
        return realpath(String(dir))
    catch
        return String(dir)
    end
end

"""
    crate_content_digest(dir::AbstractString) -> String

SHA-256 over one crate directory: the sorted relative path and a content digest
of every file `crate_input_files` reports, netstring-framed. Location
independent; see `artifact_path_dependency_digest`.

Per-file *digests* rather than raw bytes, netstring-framed exactly as the
contents were, so the encoding stays injective and the intermediate buffer stays
small. Every byte is read on every call; file contents are never memoized.
"""
function crate_content_digest(dir::AbstractString)::String
    io = IOBuffer()
    dir = String(dir)
    if !isdir(dir)
        _netstring!(io, "missing-crate")
        return bytes2hex(sha256(take!(io)))
    end
    strategy, files = crate_input_files(dir)
    _netstring!(io, "file-strategy")
    _netstring!(io, strategy)
    _netstring!(io, string(length(files)))
    for rel in files
        # Normalized only *inside the digest*: `crate_input_files` keeps
        # returning the real relative names, which is what callers read.
        _netstring!(io, _hashed_relative_path(rel))
        f = joinpath(dir, rel)
        if isfile(f)
            _netstring!(io, "content")
            _netstring!(io, _file_content_digest(f))
        else
            _netstring!(io, "not-on-disk")
        end
    end
    return bytes2hex(sha256(take!(io)))
end

"""
    external_lib_tree_digest(crate_dir, lib_root) -> Union{String, Nothing}

The digest of a library root that lives **outside** its package directory —
`[lib] path = "../shared/lib.rs"`, a layout Cargo allows and the crate scan
follows (`crate_lib_root`) — and of everything beside it: every file under the
root's directory that `crate_input_files` reports (the same walk and the same
exclusions as the package directory), by sorted relative path and content
digest, netstring-framed like `crate_content_digest`. `nothing` when `lib_root`
is `nothing` or lies inside `crate_dir`, where `crate_content_digest` already
covers it.

`crate_content_digest` hashes the package directory, so an edit to such an
external root — or to a `mod foo;` file next to it — left the artifact key
unchanged and the cache answered with the previous wrapper while the fresh
manifest described the new source (#307 review). Every file counts, not only
`.rs`: an `include_str!` / `include_bytes!` of a data file beside the root
compiles different bytes when that file changes, exactly as inside the package
directory.
"""
function external_lib_tree_digest(crate_dir::AbstractString, lib_root)
    lib_root === nothing && return nothing
    root = normpath(abspath(String(lib_root)))
    inside = normpath(abspath(String(crate_dir)))
    (root == inside || startswith(root, joinpath(inside, ""))) && return nothing
    tree = dirname(root)
    strategy, files = crate_input_files(tree)
    io = IOBuffer()
    _netstring!(io, "external-lib-root")
    _netstring!(io, _hashed_relative_path(relpath(root, tree)))
    _netstring!(io, "file-strategy")
    _netstring!(io, strategy)
    _netstring!(io, string(length(files)))
    for rel in files
        _netstring!(io, _hashed_relative_path(rel))
        f = joinpath(tree, rel)
        if isfile(f)
            _netstring!(io, "content")
            _netstring!(io, _file_content_digest(f))
        else
            _netstring!(io, "not-on-disk")
        end
    end
    return bytes2hex(sha256(take!(io)))
end

"""
    CRATE_INPUT_VCS_DIRS_ANY_LEVEL

Version-control metadata directories, never a crate input at any depth.
"""
const CRATE_INPUT_VCS_DIRS_ANY_LEVEL = String[
    ".bzr", ".git", ".hg", ".jj", ".pijul", ".svn",
]

"""
    CRATE_INPUT_VCS_DIRS

Directories not treated as crate inputs: version-control metadata, plus
Cargo's build output. `target` is excluded **only at the package root** —
`src/target/mod.rs` is ordinary source, not build output — while the VCS
directories are excluded at any depth. Everything else under a package
directory is an input.
"""
const CRATE_INPUT_VCS_DIRS = String[CRATE_INPUT_VCS_DIRS_ANY_LEVEL..., "target"]

"""
    crate_input_files(dir::AbstractString) -> (strategy::String, files::Vector{String})

Every regular file under the package directory, as relative `/`-separated
paths, sorted, excluding `CRATE_INPUT_VCS_DIRS`.

The walk is deliberately the only strategy. `cargo package --list` was tried
here first and is *weaker*: it enumerates the **distributable** package, not
what a local build reads, so a `#[path = "../ignored/mod.rs"]` module, an
`include_str!` of a gitignored file, or anything removed by an `exclude` key is
compiled but never listed — and a successful listing would suppress a walk that
would have caught them. A walk of the package directory is a superset of the
package list for everything inside that directory, and costs no process spawn.
`Cargo.lock` is therefore included whenever it exists, like any other file.

The strategy name is returned so callers can fold it into a digest.
"""
function crate_input_files(dir::AbstractString)
    dir = String(dir)
    files = String[]
    for (root, dirs, names) in walkdir(dir)
        # `target/` is Cargo's build output only at the package root: a module
        # directory named `src/target/` is ordinary source and must be hashed.
        # VCS metadata, by contrast, is never an input at any depth.
        at_root = _canonical_dir(root) == _canonical_dir(dir)
        filter!(dirs) do d
            d in CRATE_INPUT_VCS_DIRS_ANY_LEVEL && return false
            at_root && d == "target" && return false
            return true
        end
        for n in names
            push!(files, relpath(joinpath(root, n), dir))
        end
    end
    files = String[replace(f, '\\' => '/') for f in files]
    unique!(files)
    sort!(files)
    return "walk", files
end

"""
    local_path_dependency_dirs(root::AbstractString) -> (strategy::String, dirs::Vector{String})

Directories of every local (path) crate reachable from the crate at `root`,
including `root` itself.

Cargo's **resolved graph** is the source of truth, so the answer covers path
dependencies declared anywhere — `[dependencies]`, `[dev-dependencies]`,
`[build-dependencies]`, target-specific `[target.'cfg(unix)'.dependencies]`, and
workspace-inherited `{ workspace = true }` entries — at any depth:

1. `cargo tree --offline --target all --edges normal,build,dev --prefix none
   --format {p}` names every package in the resolved graph and prints the
   directory of the local ones in parentheses. (`cargo metadata` reports the
   same graph, but only as JSON, and RustCall.jl has no JSON dependency; the
   tree output is line-oriented and needs no parser. Registry packages print
   without a directory and git ones print a URL, so both are filtered out by the
   `isdir` test.)
2. If that fails — no network and nothing resolvable offline, a bare workspace
   manifest, cargo unavailable — fall back to reading the manifests directly,
   traversing every dependency table including target-specific ones and
   resolving `workspace = true` against the nearest `[workspace.dependencies]`.

The strategy name is returned and hashed by callers, so a set found one way can
never collide with one found the other.
"""
function local_path_dependency_dirs(root::AbstractString)
    root = String(root)
    # Memoized so a warm re-evaluation spawns no `cargo tree` (#278 §8), and
    # validated against the manifests of *every* crate in the cached graph, not
    # only the root's — see `_graph_stamps`.
    canonical = _canonical_dir(root)
    hit = lock(_ARTIFACT_DIGEST_LOCK) do
        entry = get(_PATH_DEP_GRAPH_CACHE, canonical, nothing)
        entry === nothing && return nothing
        stamps, result = entry
        stamps == _graph_stamps(result[2]) ? result : nothing
    end
    hit === nothing || return hit
    result = _local_path_dependency_dirs_uncached(root)
    # Stamped *after* resolution on purpose: resolving may itself write
    # `Cargo.lock` (that is what `cargo tree` without `--locked` does, exactly
    # as the build that follows would), and stamping before would invalidate the
    # entry we just filled on every single call.
    lock(_ARTIFACT_DIGEST_LOCK) do
        _PATH_DEP_GRAPH_CACHE[canonical] = (_graph_stamps(result[2]), result)
    end
    return result
end

function _local_path_dependency_dirs_uncached(root::String)
    manifest = joinpath(root, "Cargo.toml")
    dirs = String[root]

    if isfile(manifest)
        # `--locked` first: that variant never writes to the crate directory.
        # Only if the crate has no usable lockfile do we let Cargo resolve (and
        # therefore write `Cargo.lock`, exactly as any cargo command — including
        # the build that follows — would).
        listed = _cargo_tree(manifest, true)
        isempty(listed) && (listed = _cargo_tree(manifest, false))
        found = String[]
        for line in split(listed, '\n')
            d = _crate_dir_from_tree_line(line)
            d === nothing || push!(found, d)
        end
        if !isempty(found)
            append!(dirs, found)
            unique!(dirs)
            return "cargo-tree", dirs
        end
    end

    _collect_manifest_path_deps!(dirs, root, Set{String}())
    unique!(dirs)
    return "manifest-toml", dirs
end

function _cargo_tree(manifest::AbstractString, locked::Bool)::String
    fmt = "{p}"   # a Cmd literal cannot carry braces unquoted
    args = String["tree", "--offline", "--target", "all",
                  "--edges", "normal,build,dev", "--prefix", "none",
                  "--format", fmt, "--manifest-path", String(manifest)]
    locked && push!(args, "--locked")
    CARGO_TREE_INVOCATIONS[] += 1
    return try
        read(pipeline(`$(cargo()) $(args)`; stderr = devnull), String)
    catch
        ""
    end
end

# `cargo tree --prefix none --format {p}` prints e.g.
#   parent v0.1.0 (/abs/path/parent)
#   serde v1.0.100
#   thing v0.1.0 (https://github.com/x/y#abcdef)
# Only an existing directory in the trailing parentheses is a local crate.
function _crate_dir_from_tree_line(line::AbstractString)
    s = strip(line)
    (endswith(s, ")") && occursin('(', s)) || return nothing
    open_idx = findlast('(', s)
    open_idx === nothing && return nothing
    inner = String(s[nextind(s, open_idx):prevind(s, lastindex(s))])
    isempty(inner) && return nothing
    return isdir(inner) ? inner : nothing
end

function _collect_manifest_path_deps!(dirs::Vector{String}, dir::AbstractString, seen::Set{String})
    canonical = _canonical_dir(dir)
    canonical in seen && return nothing
    push!(seen, canonical)
    manifest = joinpath(String(dir), "Cargo.toml")
    for child in _declared_path_dependencies(manifest)
        child_dir = joinpath(String(dir), child)
        isdir(child_dir) || continue
        push!(dirs, child_dir)
        _collect_manifest_path_deps!(dirs, child_dir, seen)
    end
    return nothing
end

"""
    _declared_path_dependencies(manifest::AbstractString) -> Vector{String}

Fallback manifest traversal: the `path = "..."` values of every dependency
table in `manifest`, including target-specific tables
(`[target.<key>.dependencies]` and its `dev-`/`build-` variants) and
`{ workspace = true }` entries resolved against the nearest
`[workspace.dependencies]`, searched in this manifest and then upwards.

Returned paths are what the caller should join to the manifest's own directory.
An inherited path is relative to the *workspace root manifest*, not to the
member, so it is returned already resolved as an absolute path (`joinpath`
against the member directory then leaves it unchanged).

Used only when `cargo tree` cannot answer; see `local_path_dependency_dirs`.
"""
function _declared_path_dependencies(manifest::AbstractString)::Vector{String}
    isfile(manifest) || return String[]
    parsed = try
        TOML.parsefile(String(manifest))
    catch
        return String["unparsable-manifest"]
    end
    out = String[]
    dir = dirname(abspath(String(manifest)))
    workspace_deps, workspace_dir = _workspace_dependency_table(parsed, dir)

    function harvest!(table)
        table isa AbstractDict || return
        for (name, spec) in table
            spec isa AbstractDict || continue
            p = get(spec, "path", nothing)
            if p isa AbstractString
                push!(out, String(p))
                continue
            end
            # `dep = { workspace = true }`: the path lives in the workspace table.
            if get(spec, "workspace", false) === true
                inherited = get(workspace_deps, String(name), nothing)
                if inherited isa AbstractDict
                    ip = get(inherited, "path", nothing)
                    # Relative to the manifest that declares the workspace
                    # table, which is usually a directory above this member.
                    ip isa AbstractString &&
                        push!(out, abspath(joinpath(workspace_dir, String(ip))))
                end
            end
        end
    end

    for section in ("dependencies", "dev-dependencies", "build-dependencies")
        harvest!(get(parsed, section, nothing))
    end
    # [target.<key>.dependencies] and friends, for every target key.
    targets = get(parsed, "target", nothing)
    if targets isa AbstractDict
        for (_, per_target) in targets
            per_target isa AbstractDict || continue
            for section in ("dependencies", "dev-dependencies", "build-dependencies")
                harvest!(get(per_target, section, nothing))
            end
        end
    end
    return sort!(unique!(out))
end

# `[workspace.dependencies]` of this manifest, of the workspace its
# `[package] workspace = "..."` names, else of the nearest ancestor manifest
# that declares a workspace. Returns the table together with the directory of
# the manifest that declared it, because the `path` values inside it are
# relative to *that* manifest, not to the member using them.
#
# The explicit key is checked before the ancestor walk for the same reason
# `_workspace_root_dir` checks it: the named workspace need not be an ancestor,
# so walking up cannot find it — and here the consequence is that an inherited
# `dep = { workspace = true }` is never discovered, i.e. a *missing input*
# rather than a missed invalidation (#287).
function _workspace_dependency_table(parsed::AbstractDict, dir::AbstractString)
    dir = String(dir)
    ws = get(parsed, "workspace", nothing)
    if ws isa AbstractDict
        deps = get(ws, "dependencies", nothing)
        deps isa AbstractDict && return deps, dir
    end

    explicit = _explicit_workspace_root(dir)
    if explicit !== nothing
        other = _parse_manifest_or_nothing(joinpath(explicit, "Cargo.toml"))
        if other isa AbstractDict
            ws2 = get(other, "workspace", nothing)
            if ws2 isa AbstractDict
                deps2 = get(ws2, "dependencies", nothing)
                deps2 isa AbstractDict && return deps2, explicit
            end
        end
    end

    parent = dirname(dir)
    while !isempty(parent) && parent != dirname(parent)
        candidate = joinpath(parent, "Cargo.toml")
        if isfile(candidate)
            other = try
                TOML.parsefile(candidate)
            catch
                nothing
            end
            if other isa AbstractDict
                ws2 = get(other, "workspace", nothing)
                if ws2 isa AbstractDict
                    deps2 = get(ws2, "dependencies", nothing)
                    deps2 isa AbstractDict && return deps2, parent
                end
            end
        end
        parent = dirname(parent)
    end
    return Dict{String, Any}(), dir
end

"""
    artifact_type_params(names, types) -> Vector{Pair{String, String}}

Build the `type_params` field from the **declared** parameter names and the
concrete types bound to them, preserving declaration order.

This is the ordered replacement for the sorted-values key `src/generics.jl` used
before #278 Phase B: sorting the values discards which parameter got which type,
so `Dict(:T => Int32, :U => Int64)` and `Dict(:T => Int64, :U => Int32)` produced
the same monomorphization key (#247).
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

`src/manifest.jl` keeps its own, narrower `_is_cargo_env_key` allowlist for the
*cfg probe* snapshot that is embedded in generated code and replayed for a
rebuild; this list is the one that reaches artifact keys. Extend this one.
"""
const ARTIFACT_BUILD_ENV_PREFIXES = String[
    "CARGO_BUILD_",
    "CARGO_CFG_",
    "CARGO_ENCODED_RUSTFLAGS",
    "CARGO_PROFILE_",
    # pyo3's build-script namespace (`PYO3_PYTHON`, `PYO3_CONFIG_FILE`,
    # `PYO3_CROSS_LIB_DIR`, `PYO3_NO_PYTHON`, …): every one of them changes
    # which Python a wrapper cdylib is configured for and links against
    # (#307 review). The *contents* of `PYO3_CONFIG_FILE` are hashed by the
    # wrapper build on top of this (`_pyo3_wrapper_build_env`).
    "PYO3_",
]

"See `ARTIFACT_BUILD_ENV_PREFIXES`."
const ARTIFACT_BUILD_ENV_NAMES = String[
    "RUSTC",
    "RUSTC_WORKSPACE_WRAPPER",
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
    is therefore a safety net, not a proof: a change in the captured set means
    **rebuild**, while an unchanged captured set does not by itself prove
    "fresh".
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
