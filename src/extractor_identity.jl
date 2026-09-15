# The extractor's build identity (#409).
#
# Which sources an extractor binary was built from decides what it emits, and
# every artifact identity folds that in (`toolchain_fingerprint`, #372). Until
# #409 the binary reported it about itself, from a `build.rs` that walked the
# manifests — and review of #408 kept finding inputs Cargo honours that no
# manifest walk can see (workspace membership, `[patch]`, `paths` overrides in
# configuration discovered from the invocation directory, ...). This file
# computes the identity **from Cargo's own view of the build** instead, at the
# moment `deps/build.jl` builds the binary, and stores it beside the binary
# keyed by the binary's bytes (`EXTRACTOR_IDENTITY_FILENAME`), so a stale or
# foreign record can never be paired with a binary it does not describe.
#
# Included by `src/RustCall.jl` **and** by `deps/build.jl`, which runs before
# the module exists: only `Base`, `SHA` and `TOML` may be used here.
#
# The digest reproduces, byte for byte, what the v0.4.0 `build.rs` embedded for
# this tree's own layout, so the upgrade keeps every cache key; inputs the
# script never saw (configuration files, `RUSTFLAGS`) are appended only when
# present.

using SHA: SHA256_CTX, update!, digest!, sha256
using TOML

"""
    EXTRACTOR_IDENTITY_FILENAME

The record `deps/build.jl` writes beside the extractor it built: the SHA-256
of that binary, whether the build was one this identity can describe, and the
source digest when it was. `extractor_source_digest` trusts it only while the
binary beside it still has that SHA-256.
"""
const EXTRACTOR_IDENTITY_FILENAME = "rustcall-extract.identity.toml"

# The crates versioned as the RustCall release, whose `[package] version` (and
# the lockfile lines recording it) leave the identity. Mirrors
# `RUSTCALL_RELEASE_CRATES` in `src/artifact_id.jl`, which this file cannot
# see from `deps/build.jl`.
const EXTRACTOR_RELEASE_CRATES = ("rustcall_core", "rustcall_extract",
                                  "rustcall_julia_macros", "rustcall_julia_macros_impl")

_ei_canonical(path::AbstractString) = try
    realpath(String(path))
catch
    abspath(String(path))
end

# ---------------------------------------------------------------------------
# Cargo's view of the build
# ---------------------------------------------------------------------------

# Run `cargo <args>` in `dir` and return its stdout lines, or `nothing` when it
# fails. stderr is discarded: a failure here makes the build non-canonical, it
# does not fail the build.
function _ei_cargo_lines(cargo::Cmd, args::Vector{String}, dir::AbstractString, env)
    cmd = setenv(`$cargo $args`, env; dir = String(dir))
    out = try
        read(pipeline(cmd; stderr = devnull), String)
    catch
        return nothing
    end
    return String[String(l) for l in split(out, '\n') if !isempty(strip(l))]
end

"""
    _ei_parse_tree_line(line) -> (; name, version, source) or nothing

One line of `cargo tree --prefix none --format {p}`: `name vX.Y.Z`, with the
directory of a path package or the URL of a git one in trailing parentheses;
the `(*)` de-duplication marker and the `(proc-macro)` kind marker are dropped.
"""
function _ei_parse_tree_line(line::AbstractString)
    s = strip(line)
    # Markers that are not sources: de-duplication `(*)` and the crate kind
    # `(proc-macro)`.
    for marker in (" (*)", " (proc-macro)")
        endswith(s, marker) && (s = strip(SubString(s, 1, lastindex(s) - length(marker))))
    end
    isempty(s) && return nothing
    source = nothing
    if endswith(s, ")")
        open_idx = findlast('(', s)
        open_idx === nothing && return nothing
        source = String(s[nextind(s, open_idx):prevind(s, lastindex(s))])
        s = strip(SubString(s, 1, prevind(s, open_idx)))
    end
    parts = split(s, ' ')
    length(parts) == 2 && startswith(parts[2], "v") || return nothing
    return (; name = String(parts[1]), version = String(SubString(parts[2], 2)), source)
end

# Every package in the resolved graph, from Cargo, for the host target — the
# one the build was for. Not `--target all`: that asks for every platform's
# packages, which a build never fetched, and `--offline` then fails; the
# digest hashes only local crates and the lockfile, so the platform-specific
# registry packages change nothing in it either way. `--locked --offline` so
# nothing is written and nothing is fetched (the build that just ran has the
# cache warm).
function _ei_packages(cargo::Cmd, crate_dir::AbstractString, env)
    args = String["tree", "--locked", "--offline",
                  "--edges", "normal,build", "--prefix", "none", "--format", "{p}"]
    lines = _ei_cargo_lines(cargo, args, crate_dir, env)
    lines === nothing && return nothing
    packages = NamedTuple{(:name, :version, :source), Tuple{String, String, Union{Nothing, String}}}[]
    seen = Set{Tuple{String, String, Union{Nothing, String}}}()
    for line in lines
        p = _ei_parse_tree_line(line)
        p === nothing && continue
        key = (p.name, p.version, p.source)
        key in seen && continue
        push!(seen, key)
        push!(packages, p)
    end
    return packages
end

# The manifest of the workspace Cargo considers `crate_dir` to be in, from
# Cargo (members, `exclude`, an ancestor `[workspace]` — all decided by it).
function _ei_workspace_manifest(cargo::Cmd, crate_dir::AbstractString, env)
    lines = _ei_cargo_lines(cargo, String["locate-project", "--workspace", "--message-format", "plain"],
                            crate_dir, env)
    (lines === nothing || isempty(lines)) && return nothing
    return String(strip(lines[end]))
end

# ---------------------------------------------------------------------------
# Configuration and environment Cargo honours
# ---------------------------------------------------------------------------

# The configuration files Cargo discovers for a build run *in* `crate_dir`:
# `.cargo/config.toml` / `.cargo/config` in that directory and every ancestor,
# then `$CARGO_HOME`'s (falling back to `~/.cargo`) — and rustup's
# `rust-toolchain(.toml)` override files on the same walk. Each existing file
# is one input, labelled without its absolute path so the label is the same
# on every machine: the bytes are what count.
function _ei_config_files(crate_dir::AbstractString, env)
    files = Pair{String, String}[]
    dir = _ei_canonical(crate_dir)
    depth = 0
    while true
        for name in ("config.toml", "config")
            f = joinpath(dir, ".cargo", name)
            isfile(f) && push!(files, "config:ancestor:$(depth):$(name)" => f)
        end
        # rustup's override files, looked up the same way (the build runs in
        # the crate directory): they select the toolchain that compiled the
        # binary, which the compiler identity taken later from the caller's
        # directory need not see. Hashed like a configuration file, not
        # parsed — the legacy `rust-toolchain` is a bare channel name.
        for name in ("rust-toolchain.toml", "rust-toolchain")
            f = joinpath(dir, name)
            isfile(f) && push!(files, "toolchain:ancestor:$(depth):$(name)" => f)
        end
        parent = dirname(dir)
        (parent == dir || isempty(parent)) && break
        dir = parent
        depth += 1
    end
    home = get(env, "CARGO_HOME", nothing)
    if home === nothing || isempty(home)
        # Cargo's own fallback order: `$CARGO_HOME`, else the account's home —
        # from the environment when it says, else from the operating system
        # (`homedir()` asks it), never "no home".
        # `HOME` everywhere; `USERPROFILE` is consulted on Windows only (Cargo
        # ignores it elsewhere); then the operating system's answer.
        userhome = get(env, "HOME", "")
        isempty(userhome) && Sys.iswindows() && (userhome = get(env, "USERPROFILE", ""))
        isempty(userhome) && (userhome = try homedir() catch; "" end)
        home = isempty(userhome) ? nothing : joinpath(userhome, ".cargo")
    end
    if home !== nothing && !isabspath(home)
        # Cargo resolves a relative home — `CARGO_HOME`, or a relative `HOME`
        # / `USERPROFILE` it fell back to — against its own working
        # directory, which for the build this describes is the crate directory
        # (`deps/build.jl` runs Cargo there), not this process's.
        home = joinpath(_ei_canonical(crate_dir), home)
    end
    if home !== nothing
        for name in ("config.toml", "config")
            f = joinpath(home, name)
            isfile(f) && push!(files, "config:home:$(name)" => f)
        end
    end
    return files
end

# ---------------------------------------------------------------------------
# The build-environment policy, shared with every artifact key (#278, #409)
# ---------------------------------------------------------------------------

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
const ARTIFACT_BUILD_ENV_PREFIXES = (
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
)

"See `ARTIFACT_BUILD_ENV_PREFIXES`."
const ARTIFACT_BUILD_ENV_NAMES = (
    "RUSTC",
    "RUSTC_WORKSPACE_WRAPPER",
    "RUSTC_WRAPPER",
    "RUSTDOCFLAGS",
    "RUSTFLAGS",
    "RUSTUP_TOOLCHAIN",
)

"See `ARTIFACT_BUILD_ENV_PREFIXES`."
const ARTIFACT_BUILD_ENV_DENY_SUBSTRINGS = (
    "AUTH",
    "CREDENTIAL",
    "KEY",
    "PASSWORD",
    "SECRET",
    "TOKEN",
)

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
const ARTIFACT_BUILD_SCRIPT_ENV_NAMES = (
    "AR", "ASFLAGS", "CC", "CFLAGS", "CPPFLAGS", "CXX", "CXXFLAGS",
    "LD", "LDFLAGS", "NM", "RANLIB", "STRIP",
)

"See `ARTIFACT_BUILD_SCRIPT_ENV_NAMES`."
const ARTIFACT_BUILD_SCRIPT_ENV_PREFIXES = (
    "AR_", "BINDGEN_", "CARGO_FEATURE_", "CC_", "CFLAGS_", "CLANG_", "CMAKE_",
    "CXXFLAGS_", "CXX_", "HOST_", "LDFLAGS_", "LIBCLANG_", "LINKER_",
    "PKG_CONFIG", "TARGET_",
)

"See `ARTIFACT_BUILD_SCRIPT_ENV_NAMES`."
const ARTIFACT_BUILD_SCRIPT_ENV_SUFFIXES = (
    "_AR", "_CC", "_CFLAGS", "_CXX", "_CXXFLAGS", "_LDFLAGS", "_LINKER",
)

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

# The environment variables that change what Cargo compiles without touching
# a file — the same policy every artifact key applies
# (`artifact_build_env_captured`: `CARGO_PROFILE_*`, `RUSTC` and its wrappers,
# the `RUSTFLAGS` family, build-script inputs; never a secret). The ones
# *present*, empty or not: `RUSTFLAGS=""` overrides a configuration file's
# flags where an unset variable would let them apply, so presence is part of
# the identity.
function _ei_env_inputs(env)
    captured = String[String(k) for k in keys(env)
                      if artifact_build_env_captured(String(k)) && !_ei_is_baseline(String(k), String(env[k]))]
    sort!(captured)
    return Pair{String, String}[k => String(env[k]) for k in captured]
end

# Settings `deps/build.jl` pins for every build and the manifests pin too:
# they are the baseline the digest already describes, not an input on top of
# it. `panic = "unwind"` is in `deps/rustcall_extract/Cargo.toml` (#244); the
# environment override only forbids an inherited value from deciding
# otherwise. Any *other* value of the same variable is an input.
const _EI_BASELINE_ENV = ("CARGO_PROFILE_RELEASE_PANIC" => "unwind",)
_ei_is_baseline(key::String, value::String) = any(b -> first(b) == key && last(b) == value, _EI_BASELINE_ENV)

# Whether a discovered configuration file is one this identity cannot
# describe: it redirects a source — `paths = [...]`, or a `[source.<name>]`
# table with `replace-with`, `directory` or `local-registry`, the `cargo
# vendor` form (`cargo tree` prints a package from a replaced registry exactly
# like one from crates.io, so this is decided from the configuration) — or it
# pulls in files this scan does not see (`include = [...]`, Cargo's
# `-Zconfig-include`), or it does not parse.
function _ei_config_replaces_sources(file::AbstractString)
    doc = try
        TOML.parsefile(String(file))
    catch
        return true   # unreadable configuration: not a build this identity can describe
    end
    (haskey(doc, "paths") || haskey(doc, "include")) && return true
    sources = get(doc, "source", nothing)
    sources isa AbstractDict || return false
    return any(v -> v isa AbstractDict && any(k -> haskey(v, k), ("replace-with", "directory", "local-registry")),
               values(sources))
end

# The executables the environment puts in front of `rustc` — `RUSTC`,
# `RUSTC_WRAPPER`, `RUSTC_WORKSPACE_WRAPPER` — resolved to files, as `key =>
# path`: Cargo runs them, and what they do to the compilation is decided by
# their bytes, not by their names. A name that resolves to nothing is
# reported as `key => nothing` and makes the build non-canonical.
const _EI_RUSTC_EXECUTABLE_KEYS = ("RUSTC", "RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER")

function _ei_rustc_executables(env, crate_dir::AbstractString)
    out = Pair{String, Union{Nothing, String}}[]
    for key in _EI_RUSTC_EXECUTABLE_KEYS
        value = String(get(env, key, ""))
        isempty(value) && continue
        push!(out, key => _ei_resolve_executable(value, env, crate_dir))
    end
    return out
end

function _ei_resolve_executable(name::AbstractString, env, crate_dir::AbstractString)
    candidates = String[]
    if isabspath(name) || occursin('/', name) || occursin('\\', name)
        push!(candidates, isabspath(name) ? String(name) : joinpath(_ei_canonical(crate_dir), name))
    else
        sep = Sys.iswindows() ? ';' : ':'
        for dir in split(String(get(env, "PATH", "")), sep)
            isempty(dir) && continue
            push!(candidates, joinpath(dir, String(name)))
            Sys.iswindows() && push!(candidates, joinpath(dir, String(name) * ".exe"))
        end
    end
    for c in candidates
        isfile(c) && return _ei_canonical(c)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# What a manifest declares about its own targets
# ---------------------------------------------------------------------------

# Whether a manifest points a target outside what the digest walks: a build
# script other than `build.rs`, or a `[lib]`/`[[bin]]` root that does not
# resolve under `src`.
function _ei_nondefault_targets(dir::AbstractString)
    doc = try
        TOML.parsefile(joinpath(dir, "Cargo.toml"))
    catch
        return false
    end
    build = get(get(doc, "package", Dict{String, Any}()), "build", nothing)
    build isa AbstractString && build != "build.rs" && return true
    # Containment by path component: `src_extra/main.rs` and `../src-extra`
    # share the prefix and are not under `src`.
    src = splitpath(_ei_canonical(joinpath(dir, "src")))
    outside(rel) = begin
        root = joinpath(dir, rel)
        isfile(root) || return true
        parts = splitpath(_ei_canonical(root))
        !(length(parts) > length(src) && parts[1:length(src)] == src)
    end
    lib = get(doc, "lib", nothing)
    lib isa AbstractDict && get(lib, "path", nothing) isa AbstractString && outside(lib["path"]) && return true
    bins = get(doc, "bin", nothing)
    bins isa AbstractVector && any(b -> b isa AbstractDict && get(b, "path", nothing) isa AbstractString &&
                                        outside(b["path"]), bins) && return true
    return false
end

_ei_package_field(dir::AbstractString, key::String) = try
    v = get(get(TOML.parsefile(joinpath(dir, "Cargo.toml")), "package", Dict{String, Any}()), key, nothing)
    v isa AbstractString ? String(v) : nothing
catch
    nothing
end

# ---------------------------------------------------------------------------
# The digest — byte-compatible with the v0.4.0 build.rs for this tree's layout
# ---------------------------------------------------------------------------

# `text` as the pieces `split_inclusive('\n')` would give: each line with its
# own ending, no empty final piece.
function _ei_lines_inclusive(text::AbstractString)
    parts = split(text, '\n'; keepempty = true)
    out = String[]
    for (i, p) in enumerate(parts)
        if i < length(parts)
            push!(out, String(p) * "\n")
        elseif !isempty(p)
            push!(out, String(p))
        end
    end
    return out
end

_ei_is_version_line(trimmed::AbstractString) =
    startswith(trimmed, "version") && startswith(lstrip(SubString(trimmed, ncodeunits("version") + 1)), "=")

# `Cargo.toml` without the `version = ...` line of its `[package]` table.
function _ei_manifest_without_version(text::AbstractString)
    in_package = false
    io = IOBuffer()
    for line in _ei_lines_inclusive(text)
        trimmed = strip(line)
        if startswith(trimmed, '[')
            in_package = trimmed == "[package]"
        elseif in_package && _ei_is_version_line(trimmed)
            continue
        end
        write(io, line)
    end
    return take!(io)
end

# `"name version",` → `"name",` when `versions[name] == version`.
function _ei_unqualified_reference(line::AbstractString, versions::AbstractDict)
    trimmed = strip(line)
    startswith(trimmed, '"') || return line
    rest = SubString(trimmed, 2)
    endswith(rest, ',') && (rest = SubString(rest, 1, lastindex(rest) - 1))
    endswith(rest, '"') || return line
    quoted = SubString(rest, 1, lastindex(rest) - 1)
    parts = split(quoted, ' ')
    length(parts) == 2 && get(versions, String(parts[1]), nothing) == parts[2] || return line
    return replace(line, "\"$(quoted)\"" => "\"$(parts[1])\""; count = 1)
end

# `Cargo.lock` without the `version = ...` line of the source-less entries
# named in `release`, and with references to them at their current version
# unqualified; every other byte kept.
function _ei_lockfile_without_release_versions(text::AbstractString, release, versions)
    io = IOBuffer()
    blocks = split(text, "\n[[package]]"; keepempty = true)
    for (i, block) in enumerate(blocks)
        i > 1 && write(io, "\n[[package]]")
        blines = _ei_lines_inclusive(block)
        has_source = any(l -> startswith(lstrip(l), "source"), blines)
        name = nothing
        for l in blines
            t = strip(l)
            if startswith(t, "name = \"") && endswith(t, "\"")
                name = String(SubString(t, ncodeunits("name = \"") + 1, lastindex(t) - 1))
                break
            end
        end
        strip_version = !has_source && name !== nothing && name in release
        for line in blines
            trimmed = strip(line)
            strip_version && _ei_is_version_line(trimmed) && continue
            body = rstrip(line, ['\r', '\n'])
            ending = SubString(line, ncodeunits(body) + 1)
            write(io, _ei_unqualified_reference(body, versions))
            write(io, ending)
        end
    end
    return take!(io)
end

# Every regular file under `dir`, sorted the way Rust sorts `PathBuf`s: by
# path component, so `a/b.rs` comes before `a.rs`. Symlinked directories are
# followed, as rustc follows them for `mod` files and as the v0.4.0 `build.rs`
# traversal did.
function _ei_files_under(dir::AbstractString)
    files = String[]
    isdir(dir) || return files
    for (root, _, names) in walkdir(dir; follow_symlinks = true)
        for n in names
            f = joinpath(root, n)
            isfile(f) && push!(files, f)
        end
    end
    sort!(files; by = f -> splitpath(f))
    return files
end

_ei_relpath_forward(path::AbstractString, base::AbstractString) =
    replace(relpath(String(path), String(base)), '\\' => '/')

# The source digest of a set of local crates: `crates` as `name => dir`,
# `crate_dir` the extractor's, `release` the names among them that are release
# crates, `lockfile` the lockfile Cargo used, plus the configuration files and
# environment values Cargo honoured.
function _ei_source_digest(crate_dir::AbstractString, crates::Vector{Pair{String, String}},
                           release, lockfile::AbstractString,
                           config_files::Vector{Pair{String, String}},
                           env_inputs::Vector{Pair{String, String}},
                           executables::Vector{Pair{String, String}} = Pair{String, String}[])
    base = _ei_canonical(crate_dir)
    ordered = sort(crates; by = c -> _ei_relpath_forward(_ei_canonical(last(c)), base))
    versions = Dict{String, String}()
    for (name, dir) in ordered
        name in release || continue
        v = _ei_package_field(dir, "version")
        v === nothing || (versions[name] = v)
    end
    ctx = SHA256_CTX()
    upd(x) = update!(ctx, codeunits(x))
    updb(x::Vector{UInt8}) = update!(ctx, x)
    upd("Cargo.lock\0")
    updb(isfile(lockfile) ? _ei_lockfile_without_release_versions(read(lockfile, String), release, versions) :
                            UInt8[])
    upd("\0")
    for (name, dir) in ordered
        manifest = joinpath(dir, "Cargo.toml")
        upd(name); upd("\0Cargo.toml\0")
        if name in release
            updb(isfile(manifest) ? _ei_manifest_without_version(read(manifest, String)) : UInt8[])
        else
            updb(isfile(manifest) ? read(manifest) : UInt8[])
        end
        upd("\0")
        script = joinpath(dir, "build.rs")
        if isfile(script)
            upd(name); upd("\0"); upd("build-script"); upd("\0"); updb(read(script)); upd("\0")
        end
        for f in _ei_files_under(joinpath(dir, "src"))
            upd(name); upd("\0"); upd(_ei_relpath_forward(f, dir)); upd("\0"); updb(read(f)); upd("\0")
        end
    end
    # Inputs the v0.4.0 script never saw, appended only when present so the
    # common case — no configuration, no flags — keeps the digest it had.
    for (label, f) in config_files
        upd("config\0"); upd(label); upd("\0"); updb(read(f)); upd("\0")
    end
    for (k, v) in env_inputs
        upd("env\0"); upd(k); upd("\0"); upd(v); upd("\0")
    end
    for (k, file) in executables
        upd("executable\0"); upd(k); upd("\0"); updb(read(file)); upd("\0")
    end
    return bytes2hex(digest!(ctx))
end

# ---------------------------------------------------------------------------
# The decision
# ---------------------------------------------------------------------------

"""
    extractor_build_identity(crate_dir; cargo, env = ENV)

The identity of a build of the extractor at `crate_dir`, from Cargo's view of
it: `(; canonical, digest, reason, inputs)`. `canonical` says whether the
build is one this identity describes — the workspace root is the crate itself
(Cargo decides membership), every local package is one of this tree's release
crates in its place with default target roots, every other package comes from
crates.io — and `digest` is then the source digest; otherwise `digest` is
`nothing` and `reason` says why, and RustCall identifies the binary by its
bytes. `inputs` lists what the digest covered, for diagnostics.
"""
function extractor_build_identity(crate_dir::AbstractString; cargo::Cmd, env = ENV)
    crate_dir = String(crate_dir)
    packages = _ei_packages(cargo, crate_dir, env)
    workspace = _ei_workspace_manifest(cargo, crate_dir, env)
    config_files = _ei_config_files(crate_dir, env)
    env_inputs = _ei_env_inputs(env)
    executables = _ei_rustc_executables(env, crate_dir)
    return _extractor_identity_decide(crate_dir, packages, workspace, config_files, env_inputs, executables)
end

# The decision proper, on already-gathered facts, so it can be tested without
# a toolchain.
function _extractor_identity_decide(crate_dir::String, packages, workspace_manifest,
                                    config_files::Vector{Pair{String, String}},
                                    env_inputs::Vector{Pair{String, String}},
                                    executables = Pair{String, Union{Nothing, String}}[])
    inputs = String[]
    fail(reason) = (; canonical = false, digest = nothing, reason = String(reason), inputs)
    # A `rustc` or wrapper the environment names is run by Cargo: its bytes
    # are an input, and one that cannot be found is a build this identity
    # cannot describe.
    resolved = Pair{String, String}[]
    for (key, file) in executables
        file === nothing && return fail("$(key) names an executable that could not be resolved")
        push!(resolved, key => file)
    end
    packages === nothing && return fail("cargo tree did not resolve the graph offline and locked")
    workspace_manifest === nothing && return fail("cargo locate-project did not answer")
    if _ei_canonical(workspace_manifest) != _ei_canonical(joinpath(crate_dir, "Cargo.toml"))
        return fail("the crate is a member of the workspace at $(workspace_manifest); its lockfile decides the build")
    end
    for (label, file) in config_files
        startswith(label, "config:") || continue   # a toolchain override is hashed, not read
        _ei_config_replaces_sources(file) &&
            return fail("the configuration file $(label) replaces a source or includes other files")
    end
    deps_root = dirname(_ei_canonical(crate_dir))
    crates = Pair{String, String}[]
    for p in packages
        if p.source === nothing
            continue   # crates.io: pinned by the lockfile
        elseif isdir(p.source)
            dir = _ei_canonical(p.source)
            p.name in EXTRACTOR_RELEASE_CRATES ||
                return fail("local package $(p.name) at $(dir) is not one of this tree's release crates")
            dir == _ei_canonical(joinpath(deps_root, p.name)) ||
                return fail("local package $(p.name) at $(dir) is not this tree's deps/$(p.name)")
            _ei_nondefault_targets(dir) &&
                return fail("$(p.name) selects a build script or target root this identity does not walk")
            any(c -> last(c) == dir, crates) || push!(crates, p.name => dir)
        else
            return fail("package $(p.name) comes from $(p.source), not crates.io")
        end
    end
    any(c -> last(c) == _ei_canonical(crate_dir), crates) ||
        return fail("the extractor itself is not among the local packages")
    release = String[first(c) for c in crates]
    lockfile = joinpath(crate_dir, "Cargo.lock")
    isfile(lockfile) || return fail("no Cargo.lock beside the extractor")
    for (name, dir) in crates
        push!(inputs, "crate:$(name)")
    end
    push!(inputs, "lockfile")
    append!(inputs, first.(config_files))
    append!(inputs, ("env:" * first(e) for e in env_inputs))
    append!(inputs, ("executable:" * first(e) for e in resolved))
    digest = _ei_source_digest(crate_dir, crates, release, lockfile, config_files, env_inputs, resolved)
    return (; canonical = true, digest, reason = "", inputs)
end

# ---------------------------------------------------------------------------
# The record beside the binary
# ---------------------------------------------------------------------------

"""
    write_extractor_identity!(crate_dir, binary; cargo, env = ENV) -> NamedTuple

Compute `extractor_build_identity` for the build that produced `binary` and
write it beside the binary as `EXTRACTOR_IDENTITY_FILENAME`, keyed by the
binary's SHA-256. Called by `deps/build.jl` right after the build.
"""
function write_extractor_identity!(crate_dir::AbstractString, binary::AbstractString;
                                   cargo::Cmd, env = ENV)
    identity = extractor_build_identity(crate_dir; cargo, env)
    record = Dict{String, Any}(
        "format" => 1,
        "binary_sha256" => bytes2hex(open(sha256, String(binary))),
        "canonical" => identity.canonical,
        "source_digest" => something(identity.digest, ""),
        "reason" => identity.reason,
        "inputs" => identity.inputs,
    )
    path = joinpath(dirname(String(binary)), EXTRACTOR_IDENTITY_FILENAME)
    tmp = path * ".tmp-$(getpid())"
    open(tmp, "w") do io
        TOML.print(io, record; sorted = true)
    end
    mv(tmp, path; force = true)
    return identity
end

"""
    read_extractor_identity(binary) -> Union{Nothing, Dict}

The record beside `binary`, or `nothing` when there is none, it does not
parse, or it describes another binary (its `binary_sha256` differs).
"""
function read_extractor_identity(binary::AbstractString)
    path = joinpath(dirname(String(binary)), EXTRACTOR_IDENTITY_FILENAME)
    isfile(path) || return nothing
    record = try
        TOML.parsefile(path)
    catch
        return nothing
    end
    get(record, "format", nothing) == 1 || return nothing
    get(record, "binary_sha256", nothing) == bytes2hex(open(sha256, String(binary))) || return nothing
    return record
end
