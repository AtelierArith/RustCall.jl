# Compilation caching for RustCall.jl
# Phase 2: Persistent cache system
#
# IMPORTANT — Hashing rule for persistent keys
# =============================================
# Julia's built-in `hash()` is randomized per session (hash flooding protection).
# NEVER use `hash()` for values that are persisted to disk or must be stable across
# Julia processes (cache keys, library names, file names).
#
# Use `stable_content_hash()` (defined below) for all persistent identifiers.
# In-memory-only Dict keys (e.g., RUST_MODULE_REGISTRY, IRUST_FUNCTIONS) may
# still use `hash()` since they are never written to disk.

using SHA
using Dates

"""
    CACHE_LOCK

ReentrantLock guarding concurrent access to the cache directory.
Prevents corruption when multiple tasks/threads save or load cached
artifacts simultaneously.
"""
const CACHE_LOCK = ReentrantLock()

"""
    stable_content_hash(data::String) -> String

Compute a deterministic, session-stable hex digest of `data` using SHA-256.

This function MUST be used instead of Julia's `hash()` whenever the result is
persisted to disk or must be reproducible across Julia processes.  Julia's
built-in `hash()` is intentionally randomized per session for hash-flooding
protection and therefore unsuitable for persistent cache keys, library names,
or file names.

# Returns
- A 64-character lowercase hex string (SHA-256 digest).

# Examples
```julia
h = stable_content_hash("fn add(a: i32, b: i32) -> i32 { a + b }")
@assert length(h) == 64
@assert h == stable_content_hash("fn add(a: i32, b: i32) -> i32 { a + b }")
```
"""
function stable_content_hash(data::String)::String
    return bytes2hex(sha256(data))
end

"""
    CacheMetadata

Metadata stored with cached libraries.
"""
struct CacheMetadata
    cache_key::String
    code_hash::String  # SHA256 hex digest (session-stable)
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
    config_str = "$(compiler.optimization_level)_$(compiler.emit_debug_info)_$(compiler.target_triple)"
    key_data = "$(code)\n---\n$(config_str)"
    return stable_content_hash(key_data)
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
    lock(CACHE_LOCK) do
        cache_dir = get_cache_dir()
        lib_ext = get_library_extension()
        dest_lib_path = joinpath(cache_dir, "$(cache_key)$(lib_ext)")

        # Copy the library file
        cp(lib_path, dest_lib_path, force=true)

        # Save metadata (called under the same lock)
        _save_cache_metadata_unlocked(cache_key, metadata)

        return dest_lib_path
    end
end

"""
    save_cached_llvm_ir(cache_key::String, ir_path::String)

Save a compiled LLVM IR file to the cache.
"""
function save_cached_llvm_ir(cache_key::String, ir_path::String)
    lock(CACHE_LOCK) do
        cache_dir = get_cache_dir()
        dest_ir_path = joinpath(cache_dir, "$(cache_key).ll")

        # Copy the IR file
        cp(ir_path, dest_ir_path, force=true)

        return dest_ir_path
    end
end

"""
    load_cached_library(cache_key::String) -> Tuple{Ptr{Cvoid}, String}

Load a cached library and return its handle and library name.
"""
function load_cached_library(cache_key::String)
    lock(CACHE_LOCK) do
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
    lock(CACHE_LOCK) do
        _save_cache_metadata_unlocked(cache_key, metadata)
    end
end

# Internal helper called when CACHE_LOCK is already held.
function _save_cache_metadata_unlocked(cache_key::String, metadata::CacheMetadata)
    metadata_dir = get_metadata_dir()
    metadata_path = joinpath(metadata_dir, "$(cache_key).json")

    # Write to a temp file first, then atomically rename to prevent partial reads
    tmp_path = metadata_path * ".tmp"
    open(tmp_path, "w") do io
        println(io, "{")
        println(io, "  \"cache_key\": \"$(metadata.cache_key)\",")
        println(io, "  \"code_hash\": \"$(metadata.code_hash)\",")
        println(io, "  \"compiler_config\": \"$(metadata.compiler_config)\",")
        println(io, "  \"target_triple\": \"$(metadata.target_triple)\",")
        println(io, "  \"created_at\": \"$(metadata.created_at)\",")
        println(io, "  \"functions\": [$(join(map(f -> "\"$f\"", metadata.functions), ", "))]")
        println(io, "}")
    end
    mv(tmp_path, metadata_path, force=true)
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
    lock(CACHE_LOCK) do
        _load_cache_metadata_unlocked(cache_key)
    end
end

function _load_cache_metadata_unlocked(cache_key::String)
    metadata_dir = get_metadata_dir()
    metadata_path = joinpath(metadata_dir, "$(cache_key).json")

    if !isfile(metadata_path)
        return nothing
    end

    try
        content = read(metadata_path, String)

        # Parse simple JSON fields written by save_cache_metadata.
        # The format is a flat object with string values and one string-array value.
        function _extract_string_field(text, key)
            m = match(Regex("\"$(key)\"\\s*:\\s*\"([^\"]*)\""), text)
            return m === nothing ? "" : String(m.captures[1])
        end

        ck = _extract_string_field(content, "cache_key")
        ch = _extract_string_field(content, "code_hash")
        cc = _extract_string_field(content, "compiler_config")
        tt = _extract_string_field(content, "target_triple")
        ca_str = _extract_string_field(content, "created_at")

        # Parse the functions array: "functions": ["f1", "f2"]
        funcs = String[]
        m_funcs = match(r"\"functions\"\s*:\s*\[([^\]]*)\]", content)
        if m_funcs !== nothing
            arr_content = m_funcs.captures[1]
            for m_item in eachmatch(r"\"([^\"]+)\"", arr_content)
                push!(funcs, String(m_item.captures[1]))
            end
        end

        # Parse created_at datetime
        created_at = isempty(ca_str) ? Dates.now() : DateTime(ca_str)

        return CacheMetadata(ck, ch, cc, tt, created_at, funcs)
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
    lock(CACHE_LOCK) do
        _clear_cache_unlocked()
    end
end

function _clear_cache_unlocked()
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
