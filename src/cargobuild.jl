# Cargo build integration for external dependencies
# Phase 3: Build Cargo projects and cache results

using SHA
using Dates
using RustToolChain: cargo

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
function build_cargo_project(project::CargoProject; release::Bool = true)
    # Build command
    cargo_cmd = cargo()
    build_args = ["build"]

    if release
        push!(build_args, "--release")
    end

    # Run cargo build
    cd(project.path) do
        try
            stderr_io = IOBuffer()
            stdout_io = IOBuffer()

            cmd = `$cargo_cmd $build_args`
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
    build_cargo_project_cached(
        project::CargoProject,
        code_hash::UInt64;
        release::Bool = true
    ) -> String

Build a Cargo project with caching support.

If a cached library exists with matching code and dependency hashes, returns
the cached library path. Otherwise, builds the project and caches the result.

# Arguments
- `project::CargoProject`: The Cargo project to build
- `code_hash::UInt64`: Hash of the Rust source code

# Keyword Arguments
- `release::Bool`: Build in release mode (default: true)

# Returns
- `String`: Path to the compiled shared library (may be cached)
"""
function build_cargo_project_cached(
    project::CargoProject,
    code_hash::UInt64;
    release::Bool = true
)
    # Generate cache key from code hash, dependency hash, and build mode
    deps_hash = hash_dependencies(project.dependencies)
    mode_str = release ? "release" : "debug"

    # Combine hashes for cache key
    cache_key_data = "$(code_hash)_$(deps_hash)_$(mode_str)"
    cache_key = bytes2hex(sha256(cache_key_data))[1:32]  # Use first 32 chars

    # Check cache
    cached_lib = get_cargo_cached_library(cache_key)
    if !isnothing(cached_lib) && isfile(cached_lib)
        @debug "Using cached Cargo library" cache_key=cache_key[1:8]
        return cached_lib
    end

    # Build the project
    lib_path = build_cargo_project(project, release=release)

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

    @debug "Cached Cargo library" cache_key=cache_key[1:8] path=cached_path
end

"""
    clear_cargo_cache()

Clear all cached Cargo-built libraries.
"""
function clear_cargo_cache()
    cache_dir = get_cargo_cache_dir()
    if isdir(cache_dir)
        rm(cache_dir, recursive=true, force=true)
        mkpath(cache_dir)
    end
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
