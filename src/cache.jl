# Compilation caching for RustCall.jl
# Phase 2: Persistent cache system

using SHA
using Dates

"""
    CacheMetadata

Metadata stored with cached libraries.
"""
struct CacheMetadata
    cache_key::String
    code_hash::UInt64
    compiler_config::String  # Serialized compiler config
    target_triple::String
    created_at::DateTime
    functions::Vector{String}  # List of exported functions
end

"""
    get_cache_dir() -> String

Get the cache directory for RustCall.jl compiled libraries.
Uses Julia's standard cache directory structure.
"""
function get_cache_dir()
    cache_root = joinpath(DEPOT_PATH[1], "compiled", "v$(VERSION.major).$(VERSION.minor)", "RustCall")
    mkpath(cache_root)
    return cache_root
end

"""
    get_metadata_dir() -> String

Get the directory for cache metadata files.
"""
function get_metadata_dir()
    cache_dir = get_cache_dir()
    metadata_dir = joinpath(cache_dir, "metadata")
    mkpath(metadata_dir)
    return metadata_dir
end

"""
    generate_cache_key(code::String, compiler::RustCompiler) -> String

Generate a cache key based on code hash, compiler settings, and target triple.
Uses SHA256 for collision resistance.
"""
function generate_cache_key(code::String, compiler::RustCompiler)
    # Create a unique key from code hash and compiler settings
    code_hash = hash(code)
    config_str = "$(compiler.optimization_level)_$(compiler.emit_debug_info)_$(compiler.target_triple)"
    key_data = "$(code_hash)_$(config_str)"

    # Use SHA256 for the final key
    hash_bytes = sha256(key_data)
    return bytes2hex(hash_bytes)
end

"""
    get_cached_library(cache_key::String) -> Union{String, Nothing}

Check if a cached library exists for the given cache key.
Returns the path to the cached library if it exists, nothing otherwise.
"""
function get_cached_library(cache_key::String)
    cache_dir = get_cache_dir()
    lib_ext = get_library_extension()
    lib_path = joinpath(cache_dir, "$(cache_key)$(lib_ext)")

    if isfile(lib_path)
        return lib_path
    end

    return nothing
end

"""
    get_cached_llvm_ir(cache_key::String) -> Union{String, Nothing}

Check if a cached LLVM IR file exists for the given cache key.
Returns the path to the cached IR file if it exists, nothing otherwise.
"""
function get_cached_llvm_ir(cache_key::String)
    cache_dir = get_cache_dir()
    ir_path = joinpath(cache_dir, "$(cache_key).ll")

    if isfile(ir_path)
        return ir_path
    end

    return nothing
end

"""
    save_cached_library(cache_key::String, lib_path::String, metadata::CacheMetadata)

Save a compiled library to the cache along with its metadata.
"""
function save_cached_library(cache_key::String, lib_path::String, metadata::CacheMetadata)
    cache_dir = get_cache_dir()
    lib_ext = get_library_extension()
    dest_lib_path = joinpath(cache_dir, "$(cache_key)$(lib_ext)")

    # Copy the library file
    cp(lib_path, dest_lib_path, force=true)

    # Save metadata
    save_cache_metadata(cache_key, metadata)

    return dest_lib_path
end

"""
    save_cached_llvm_ir(cache_key::String, ir_path::String)

Save a compiled LLVM IR file to the cache.
"""
function save_cached_llvm_ir(cache_key::String, ir_path::String)
    cache_dir = get_cache_dir()
    dest_ir_path = joinpath(cache_dir, "$(cache_key).ll")

    # Copy the IR file
    cp(ir_path, dest_ir_path, force=true)

    return dest_ir_path
end

"""
    load_cached_library(cache_key::String) -> Tuple{Ptr{Cvoid}, String}

Load a cached library and return its handle and library name.
"""
function load_cached_library(cache_key::String)
    cached_lib = get_cached_library(cache_key)
    if cached_lib === nothing
        error("Cached library not found for key: $cache_key")
    end

    # Load the library
    lib_handle = Libdl.dlopen(cached_lib, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
    if lib_handle == C_NULL
        error("Failed to load cached library: $cached_lib")
    end

    # Generate library name from cache key
    lib_name = "rust_cache_$(cache_key[1:16])"  # Use first 16 chars for readability

    return lib_handle, lib_name
end

"""
    save_cache_metadata(cache_key::String, metadata::CacheMetadata)

Save cache metadata to a JSON file.

# Arguments
- `cache_key::String`: The cache key identifying the cached library
- `metadata::CacheMetadata`: Metadata to save

# Example
```julia
metadata = CacheMetadata(
    cache_key="abc123...",
    code_hash=0x1234...,
    compiler_config="2_false_x86_64-unknown-linux-gnu",
    target_triple="x86_64-unknown-linux-gnu",
    created_at=now(),
    functions=["add", "multiply"]
)
save_cache_metadata("abc123...", metadata)
```
"""
function save_cache_metadata(cache_key::String, metadata::CacheMetadata)
    metadata_dir = get_metadata_dir()
    metadata_path = joinpath(metadata_dir, "$(cache_key).json")

    # Simple JSON-like serialization (we'll use a simple format)
    metadata_dict = Dict(
        "cache_key" => metadata.cache_key,
        "code_hash" => string(metadata.code_hash),
        "compiler_config" => metadata.compiler_config,
        "target_triple" => metadata.target_triple,
        "created_at" => string(metadata.created_at),
        "functions" => metadata.functions
    )

    # Write as JSON (simple format for now)
    open(metadata_path, "w") do io
        println(io, "{")
        println(io, "  \"cache_key\": \"$(metadata.cache_key)\",")
        println(io, "  \"code_hash\": \"$(metadata.code_hash)\",")
        println(io, "  \"compiler_config\": \"$(metadata.compiler_config)\",")
        println(io, "  \"target_triple\": \"$(metadata.target_triple)\",")
        println(io, "  \"created_at\": \"$(metadata.created_at)\",")
        println(io, "  \"functions\": [$(join(map(f -> "\"$f\"", metadata.functions), ", "))]")
        println(io, "}")
    end
end

"""
    load_cache_metadata(cache_key::String) -> Union{CacheMetadata, Nothing}

Load cache metadata from a JSON file.

# Arguments
- `cache_key::String`: The cache key identifying the cached library

# Returns
- `Union{CacheMetadata, Nothing}`: The loaded metadata, or `nothing` if not found

# Note
This function currently returns `nothing` as a placeholder. Full JSON parsing
will be implemented in a future version.

# Example
```julia
meta = load_cache_metadata("abc123...")
if meta !== nothing
    println("Cache created at: \$(meta.created_at)")
end
```
"""
function load_cache_metadata(cache_key::String)
    metadata_dir = get_metadata_dir()
    metadata_path = joinpath(metadata_dir, "$(cache_key).json")

    if !isfile(metadata_path)
        return nothing
    end

    # Simple JSON parsing (for now, we'll use a basic approach)
    # In production, consider using JSON.jl
    try
        content = read(metadata_path, String)
        # Simple parsing - extract key fields
        # For now, return a basic structure
        # Full JSON parsing can be added later if needed
        return nothing  # Placeholder - implement full parsing if needed
    catch e
        @warn "Failed to load cache metadata: $e"
        return nothing
    end
end

"""
    clear_cache()

Clear all cached libraries and metadata.
On Windows, some files may be locked and cannot be deleted immediately.
"""
function clear_cache()
    cache_dir = get_cache_dir()
    if isdir(cache_dir)
        try
            # Try to remove the directory recursively
            rm(cache_dir, recursive=true, force=true)
        catch e
            # On Windows, files may be locked (e.g., by Julia's compiled modules)
            # Check if it's a directory not empty or busy error
            if isa(e, Base.IOError)
                error_msg = string(e)
                if occursin("not empty", error_msg) || occursin("ENOTEMPTY", error_msg) ||
                   occursin("busy", error_msg) || occursin("EBUSY", error_msg)
                    # Try to remove files individually, ignoring errors for locked files
                    for file in readdir(cache_dir)
                        file_path = joinpath(cache_dir, file)
                        try
                            if isfile(file_path)
                                rm(file_path, force=true)
                            elseif isdir(file_path)
                                rm(file_path, recursive=true, force=true)
                            end
                        catch
                            # Ignore errors for individual files (may be locked)
                        end
                    end
                else
                    # Re-throw if it's a different error
                    rethrow(e)
                end
            else
                # Re-throw if it's not an IOError
                rethrow(e)
            end
        end
    end
    return nothing
end

"""
    get_cache_size() -> Int64

Get the total size of the cache directory in bytes.
"""
function get_cache_size()
    cache_dir = get_cache_dir()
    if !isdir(cache_dir)
        return Int64(0)
    end

    total_size = Int64(0)
    for (root, dirs, files) in walkdir(cache_dir)
        for file in files
            file_path = joinpath(root, file)
            if isfile(file_path)
                total_size += filesize(file_path)
            end
        end
    end

    return total_size
end

"""
    list_cached_libraries() -> Vector{String}

List all cache keys for cached libraries.
"""
function list_cached_libraries()
    cache_dir = get_cache_dir()
    if !isdir(cache_dir)
        return String[]
    end

    lib_ext = get_library_extension()
    cached_keys = String[]

    for file in readdir(cache_dir)
        if endswith(file, lib_ext)
            # Extract cache key from filename
            key = replace(file, lib_ext => "")
            push!(cached_keys, key)
        end
    end

    return cached_keys
end

"""
    cleanup_old_cache(max_age_days::Int = 30)

Remove cache entries older than max_age_days.

# Arguments
- `max_age_days::Int`: Maximum age in days (default: 30)

# Returns
- `Int`: Number of removed cache entries

# Example
```julia
# Remove cache entries older than 7 days
count = cleanup_old_cache(7)
println("Removed \$count old cache entries")
```
"""
function cleanup_old_cache(max_age_days::Int = 30)
    cache_dir = get_cache_dir()
    if !isdir(cache_dir)
        return nothing
    end

    cutoff_time = now() - Day(max_age_days)
    removed_count = 0

    for file in readdir(cache_dir)
        file_path = joinpath(cache_dir, file)
        if isfile(file_path)
            file_mtime = Dates.unix2datetime(Base.Filesystem.mtime(file_path))
            if file_mtime < cutoff_time
                rm(file_path, force=true)
                removed_count += 1
            end
        end
    end

    # Also clean metadata directory
    metadata_dir = get_metadata_dir()
    if isdir(metadata_dir)
        for file in readdir(metadata_dir)
            file_path = joinpath(metadata_dir, file)
            if isfile(file_path)
                file_mtime = Dates.unix2datetime(Base.Filesystem.mtime(file_path))
                if file_mtime < cutoff_time
                    rm(file_path, force=true)
                end
            end
        end
    end

    return removed_count
end

"""
    is_cache_valid(cache_key::String, code::String, compiler::RustCompiler) -> Bool

Check if a cached library is still valid for the given code and compiler settings.
"""
function is_cache_valid(cache_key::String, code::String, compiler::RustCompiler)
    # Generate expected cache key
    expected_key = generate_cache_key(code, compiler)

    # Check if keys match
    if cache_key != expected_key
        return false
    end

    # Check if file exists
    cached_lib = get_cached_library(cache_key)
    if cached_lib === nothing
        return false
    end

    # Check if file is readable
    if !isfile(cached_lib) || !isreadable(cached_lib)
        return false
    end

    return true
end
