# Cargo build integration for external dependencies
# Phase 3: Build Cargo projects and cache results

using SHA
using Dates
using RustToolChain: cargo

"""
    _cargo_panic_env(policy, env, release) -> Union{Nothing, Dict{String, String}}

The environment to run Cargo under: `env` (a captured build-time snapshot, or
the inherited environment when it is `nothing`) with
`CARGO_PROFILE_<PROFILE>_PANIC` pinned to the policy's strategy.

`nothing` when the policy pins nothing (`:crate_profile`: the manifest is the
user's, and forcing their profile from the outside would silently change how
their crate is built) and there is no snapshot to replay.

The profile name follows `release`, not `policy.cargo_profile` alone: a debug
build reads `CARGO_PROFILE_DEV_PANIC`.
"""
function _cargo_panic_env(policy::LoadPolicy, env::Union{Nothing, AbstractDict},
                          release::Bool)
    strategy = policy.panic_strategy
    if strategy in (:crate_profile, :cargo_default)
        return env
    end
    variable = "CARGO_PROFILE_$(uppercase(release ? "release" : "dev"))_PANIC"
    out = Dict{String, String}(env === nothing ? ENV : env)
    out[variable] = String(strategy)
    return out
end

"""
    _cargo_feature_args(features, default_features) -> Vector{String}

The Cargo flags naming a feature set, in the spelling `cargo build` takes:
`--no-default-features` when `default_features` is off, then `--features a,b`
when `features` is non-empty. Empty for the default build.
"""
function _cargo_feature_args(features::Vector{String}, default_features::Bool)
    args = String[]
    default_features || push!(args, "--no-default-features")
    isempty(features) || append!(args, ["--features", join(features, ",")])
    return args
end

"""
    _cargo_build_args(release, features, default_features) -> Vector{String}

The argument vector of the `cargo build` a project is built with: the profile,
then the feature set (`_cargo_feature_args`). A plain `@rust_crate` build made
with `features = ...` / `default_features = false` passes them here, so the
crate is built with the configuration that was asked for and not its default
one (#307 review).
"""
function _cargo_build_args(release::Bool, features::Vector{String}, default_features::Bool)
    args = ["build"]
    release && push!(args, "--release")
    append!(args, _cargo_feature_args(features, default_features))
    return args
end

"""
    build_cargo_project(project::CargoProject; release::Bool = true) -> String

Build a Cargo project and return the path to the compiled library.

# Arguments
- `project::CargoProject`: The Cargo project to build

# Keyword Arguments
- `release::Bool`: Build in release mode (default: true for better performance)

# Returns
- `String`: Path to the compiled shared library

# Throws
- `CargoBuildError` if the build fails
"""
function build_cargo_project(project::CargoProject; release::Bool = true,
                             env::Union{Nothing, AbstractDict} = nothing,
                             policy::LoadPolicy = inline_cargo_policy(),
                             features::Vector{String} = String[],
                             default_features::Bool = true)
    # Build command
    cargo_cmd = cargo()
    build_args = _cargo_build_args(release, features, default_features)

    # The panic strategy is pinned twice: in the generated manifest and here,
    # in the environment Cargo runs under (#244). The manifest key already
    # beats an inherited `CARGO_PROFILE_RELEASE_PANIC`, but a *dependency*
    # resolved from a workspace, or a future Cargo that reads the variable
    # differently, should not be able to turn unwinding off — the generated
    # `catch_unwind` boundary can only catch a panic that unwinds. Setting it
    # explicitly makes the intent part of the invocation rather than a property
    # of whatever the Julia process inherited.
    build_env = _cargo_panic_env(policy, env, release)

    # Run cargo build
    cd(project.path) do
        try
            stderr_io = IOBuffer()
            stdout_io = IOBuffer()

            cmd = `$cargo_cmd $build_args`
            # A recorded Cargo environment (precompiled block reload) replaces
            # the inherited one so profile overrides and RUSTFLAGS match; the
            # pinned panic strategy is applied on top of either.
            build_env === nothing || (cmd = setenv(cmd, build_env))
            proc = run(pipeline(cmd, stdout=stdout_io, stderr=stderr_io), wait=false)
            wait(proc)

            if !success(proc)
                stderr_str = String(take!(stderr_io))
                close(stderr_io)
                close(stdout_io)

                throw(CargoBuildError(
                    "Cargo build failed",
                    stderr_str,
                    project.path
                ))
            end

            close(stderr_io)
            close(stdout_io)
        catch e
            if e isa CargoBuildError
                rethrow(e)
            end
            throw(CargoBuildError(
                "Unexpected error during Cargo build: $e",
                "",
                project.path
            ))
        end
    end

    # Get the built library path
    lib_path = get_built_library_path(project, release)

    if !isfile(lib_path)
        # On Windows, Cargo may generate library files without the "lib" prefix
        # Try alternative path without "lib" prefix
        if Sys.iswindows()
            lib_name = get_project_lib_name(project)
            # Remove "lib" prefix if present
            if startswith(lib_name, "lib")
                alt_lib_name = lib_name[4:end]  # Remove "lib" prefix
                target_dir = release ? "release" : "debug"
                alt_lib_path = joinpath(project.path, "target", target_dir, alt_lib_name)
                if isfile(alt_lib_path)
                    return alt_lib_path
                end
            end
        end

        throw(CargoBuildError(
            "Library not found after build",
            "Expected library at: $lib_path",
            project.path
        ))
    end

    lib_path
end

"""
    get_built_library_path(project::CargoProject, release::Bool) -> String

Get the path to the built library for a Cargo project.

# Arguments
- `project::CargoProject`: The Cargo project
- `release::Bool`: Whether release mode was used

# Returns
- `String`: Path to the shared library

# Note
The path follows Cargo's target directory structure:
- Release: target/release/libname.dylib (or .so, .dll)
- Debug: target/debug/libname.dylib
"""
function get_built_library_path(project::CargoProject, release::Bool)
    target_dir = release ? "release" : "debug"
    lib_name = get_project_lib_name(project)

    joinpath(project.path, "target", target_dir, lib_name)
end

"""
    hash_dependencies(deps::Vector{DependencySpec}) -> String

Generate a hash of the dependency specifications for cache keying.

# Arguments
- `deps::Vector{DependencySpec}`: Dependencies to hash

# Returns
- `String`: Hex-encoded hash of the dependencies
"""
function hash_dependencies(deps::Vector{DependencySpec})
    # Sort dependencies by name for consistent hashing
    sorted_deps = sort(deps, by = d -> d.name)

    # Build a canonical string representation
    parts = String[]
    for dep in sorted_deps
        dep_str = dep.name
        if !isnothing(dep.version)
            dep_str *= ":$(dep.version)"
        end
        if !isempty(dep.features)
            dep_str *= ":[$(join(sort(dep.features), ","))]"
        end
        if !isnothing(dep.git)
            dep_str *= ":git=$(dep.git)"
        end
        if !isnothing(dep.path)
            dep_str *= ":path=$(dep.path)"
        end
        push!(parts, dep_str)
    end

    canonical = join(parts, ";")
    bytes2hex(sha256(canonical))
end

"""
    _check_cargo_profile(id::ArtifactId, release::Bool)

Refuse to build when the profile recorded in `id` is not the one being built.

The two must agree because `artifact_key(id)` is the *only* key of the build:
if they could disagree, the caller's lookup key and the artifact actually
produced would describe different things — the shape of #287. Better a loud
error than a cache that quietly holds the wrong binary.
"""
function _check_cargo_profile(id::ArtifactId, release::Bool)
    want = release ? "release" : "debug"
    recorded = nothing
    for (k, v) in id.codegen
        k == "profile" && (recorded = v)
    end
    recorded == want && return nothing
    throw(ArgumentError(
        "the ArtifactId records profile $(repr(recorded)) but the build was asked for " *
        "$(repr(want)). A Cargo block must have exactly one key for its lookup, its " *
        "build and its save (#278, #287); pass `release` to `_cargo_block_id` instead."))
end

"""
    build_cargo_project_cached(project::CargoProject, id::ArtifactId;
                               release = true, env = nothing) -> String

Build a Cargo project with caching support.

If a cached library exists for this artifact, returns its path. Otherwise builds
the project and caches the result.

# Arguments
- `project::CargoProject`: The Cargo project to build
- `id::ArtifactId`: the complete identity of what is being built — source,
  dependency set, build environment (including the effective Cargo
  configuration), build profile and toolchain. The cache key is `artifact_key`
  of exactly that record: this function never extends or re-derives it, so a
  Cargo block has one key for its lookup, its build and its save (#278, #287).

# Keyword Arguments
- `release::Bool`: Build in release mode (default: true)
- `env`: environment override for the `cargo` invocation

# Returns
- `String`: Path to the compiled shared library (may be cached)
"""
function build_cargo_project_cached(
    project::CargoProject,
    id::ArtifactId;
    release::Bool = true,
    env::Union{Nothing, AbstractDict} = nothing
)
    # `id` is already the complete identity of this build — the caller computed
    # it once and looked the artifact up under it. Deriving a *richer* key here
    # is what #287 caught: the outer lookup then hit the pre-change binary while
    # the build cached under a key nothing would ever ask for again. So the key
    # is `artifact_key(id)` and nothing else, and a mismatched profile is an
    # error rather than a second key.
    _check_cargo_profile(id, release)
    cache_key = artifact_key(id)

    # Check cache
    cached_lib = get_cargo_cached_library(cache_key)
    if !isnothing(cached_lib) && isfile(cached_lib)
        @debug "Using cached Cargo library" cache_key=artifact_short_id(cache_key, 8)
        return cached_lib
    end

    # Build the project
    lib_path = build_cargo_project(project, release=release, env=env)

    # Cache the result
    try
        save_cargo_cached_library(cache_key, lib_path)
    catch e
        @warn "Failed to cache Cargo library: $e"
    end

    lib_path
end

"""
    get_cargo_cache_dir() -> String

Get the cache directory for Cargo-built libraries.
"""
function get_cargo_cache_dir()
    cache_base = get_cache_dir()  # Uses existing cache infrastructure
    cargo_cache = joinpath(cache_base, "cargo")
    mkpath(cargo_cache)
    cargo_cache
end

"""
    get_cargo_cached_library(cache_key::String) -> Union{String, Nothing}

Get a cached Cargo library by cache key.

# Returns
- Path to cached library, or `nothing` if not found
"""
function get_cargo_cached_library(cache_key::String)
    cache_dir = get_cargo_cache_dir()
    lib_ext = get_library_extension()
    cached_path = joinpath(cache_dir, "$(cache_key)$(lib_ext)")

    if isfile(cached_path)
        return cached_path
    end

    nothing
end

"""
    save_cargo_cached_library(cache_key::String, lib_path::String)

Save a compiled library to the Cargo cache.

# Arguments
- `cache_key::String`: Cache key
- `lib_path::String`: Path to the compiled library
"""
function save_cargo_cached_library(cache_key::String, lib_path::String)
    cache_dir = get_cargo_cache_dir()
    lib_ext = get_library_extension()
    cached_path = joinpath(cache_dir, "$(cache_key)$(lib_ext)")

    # Copy library to cache
    cp(lib_path, cached_path, force=true)

    @debug "Cached Cargo library" cache_key=artifact_short_id(cache_key, 8) path=cached_path
end

"""
    clear_cargo_cache()

Clear all cached Cargo-built libraries.
"""
function clear_cargo_cache()
    cache_dir = get_cargo_cache_dir()
    isdir(cache_dir) || return nothing
    # A cached cdylib that this session has loaded is mapped into the process,
    # and Windows will not delete a mapped file — `force = true` forgives a
    # missing file, not a locked one. Clearing the cache must not throw because
    # of that, exactly as `_clear_cache_unlocked` already tolerates it for the
    # rustc cache; whatever is still in use is simply left behind.
    try
        rm(cache_dir, recursive = true, force = true)
    catch e
        @debug "Could not fully clear the Cargo cache (files may be in use)" cache_dir exception = e
        for entry in readdir(cache_dir; join = true)
            try
                rm(entry, recursive = true, force = true)
            catch
            end
        end
    end
    mkpath(cache_dir)
    return nothing
end

"""
    get_cargo_cache_size() -> Int64

Get the total size of the Cargo cache in bytes.
"""
function get_cargo_cache_size()
    cache_dir = get_cargo_cache_dir()
    if !isdir(cache_dir)
        return Int64(0)
    end

    total_size = Int64(0)
    for file in readdir(cache_dir)
        filepath = joinpath(cache_dir, file)
        if isfile(filepath)
            total_size += filesize(filepath)
        end
    end

    total_size
end
