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
    CACHE_FORMAT_VERSION

Version of the on-disk cache *layout*, and only of the layout: it names the
directory every cached artifact lives under (`.../RustCall/v\$(CACHE_FORMAT_VERSION)`).

Bump it whenever the meaning of the files under `get_cache_dir` changes in a way
that makes older entries unreachable — as issue #278 Phase B does by routing
every key through `artifact_key`. Namespacing rather than deleting means old
trees stay on disk for rollback and for bisecting RustCall versions, and no
intermediate state can serve a stale hit from the previous format.

The identity *record* has its own version, `ARTIFACT_ID_SCHEMA_VERSION`, which is
part of every key; this constant covers the directory layout only.

Version history:
- `1` — implicit, pre-#278: cache files directly under `.../RustCall`.
- `2` — every key produced by `artifact_key` (#278 Phase B).
"""
const CACHE_FORMAT_VERSION = 2

"""
    _cache_format_root() -> String

The parent directory holding one subdirectory per cache format version.

!!! danger "This directory is not RustCall's to empty"
    It is `\$(DEPOT_PATH[1])/compiled/vX.Y/RustCall` — **Julia's own package
    precompile directory for RustCall**, where Julia writes `<slug>.ji` and
    `<slug>.dylib`/`.so`/`.dll` native images (and `.dSYM` bundles beside them).
    The root is kept here because `get_cache_dir()` has always been under it and
    moving it would strand every existing cache, but the consequence is that
    RustCall shares a directory with another program's data.

    Nothing here may be deleted unless RustCall demonstrably wrote it: only its
    own version subdirectories, and loose files matching the exact naming the
    pre-#278 layout used (`_LEGACY_CACHE_FILE`). Removing a fresh `.ji` would
    throw away Julia's precompilation output and can race a concurrent Julia
    process writing it.
"""
function _cache_format_root()
    return joinpath(DEPOT_PATH[1], "compiled", "v$(VERSION.major).$(VERSION.minor)", "RustCall")
end

"""
    get_cache_dir() -> String

Get the cache directory for RustCall.jl compiled libraries.
Uses Julia's standard cache directory structure, namespaced by
`CACHE_FORMAT_VERSION`.
"""
function get_cache_dir()
    cache_root = joinpath(_cache_format_root(), "v$(CACHE_FORMAT_VERSION)")
    mkpath(cache_root)
    return cache_root
end

"""
    _LEGACY_CACHE_DIRS

Subdirectories the pre-#278 (unversioned) layout created directly under
`_cache_format_root()`: `save_cached_library` wrote metadata to `metadata/` and
`build_cargo_project_cached` wrote to `cargo/`. Both names are RustCall's own —
Julia creates no directory there — so they are safe to remove.
"""
const _LEGACY_CACHE_DIRS = ("cargo", "metadata")

"""
    _LEGACY_CACHE_FILE

The exact naming the pre-#278 layout used for loose files in
`_cache_format_root()`, taken from the code that wrote them, not guessed:

- `save_cached_library`  → `<cache_key><lib_ext>`
- `_save_checksum`       → `<cache_key><lib_ext>.sha256`
- `save_cached_llvm_ir`  → `<cache_key>.ll`

`cache_key` was always a `stable_content_hash` digest, i.e. lowercase hex (64
characters, or 32 for the Cargo-side keys). That is what makes the pattern safe
to delete by: Julia's precompile images in the same directory are named after a
package slug (`qLtCw_2ChqG.ji`, `qLtCw_2ChqG.dylib`) which contains uppercase
letters and an underscore and therefore can never match, and anything else in
the directory is by definition not ours.

A file that does not match this is never removed, whatever it looks like.
"""
const _LEGACY_CACHE_FILE = r"^[0-9a-f]{32,64}(\.(dylib|so|dll)(\.sha256)?|\.ll)$"

"""
    _stale_cache_format_dirs() -> Vector{String}

Cache *directories* under `_cache_format_root()` that RustCall wrote and can no
longer read: version subdirectories older than `CACHE_FORMAT_VERSION`, plus the
`_LEGACY_CACHE_DIRS` of the unversioned pre-#278 layout.

Newer-versioned siblings are deliberately left alone (a future RustCall sharing
the depot keeps its own cache), and so is every other entry — see the warning on
`_cache_format_root`.
"""
function _stale_cache_format_dirs()
    root = _cache_format_root()
    out = String[]
    isdir(root) || return out
    for entry in readdir(root)
        path = joinpath(root, entry)
        isdir(path) || continue
        m = match(r"^v(\d+)$", entry)
        if m !== nothing
            parse(Int, m.captures[1]) < CACHE_FORMAT_VERSION && push!(out, path)
        elseif entry in _LEGACY_CACHE_DIRS
            push!(out, path)
        end
    end
    return out
end

"""
    _legacy_cache_files() -> Vector{String}

Loose files directly under `_cache_format_root()` that the pre-#278 layout
wrote, identified by `_LEGACY_CACHE_FILE` and nothing else. Everything the
pattern does not match — Julia's `.ji` and native images above all — is not
RustCall's and is never returned.
"""
function _legacy_cache_files()
    root = _cache_format_root()
    out = String[]
    isdir(root) || return out
    for entry in readdir(root)
        path = joinpath(root, entry)
        isfile(path) || continue
        occursin(_LEGACY_CACHE_FILE, entry) && push!(out, path)
    end
    return out
end

"""
    sweep_stale_cache_formats(; legacy_files::Bool = false) -> Int

Best-effort removal of cache trees left behind by older cache formats. Returns
the number of entries removed and never throws: a locked or unreadable entry is
skipped and simply stays on disk.

Directories are always swept — they are unambiguously RustCall's. Loose files
from the unversioned pre-#278 layout are swept **only** when `legacy_files` is
true, because they share a directory with Julia's own precompile output for
RustCall; see the warning on `_cache_format_root`. Even then, only files
matching `_LEGACY_CACHE_FILE` are touched.
"""
function sweep_stale_cache_formats(; legacy_files::Bool = false)
    removed = 0
    for path in _stale_cache_format_dirs()
        try
            rm(path, recursive = true, force = true)
            removed += 1
        catch e
            @debug "Could not remove stale cache format directory" path exception = e
        end
    end
    if legacy_files
        for path in _legacy_cache_files()
            try
                rm(path, force = true)
                removed += 1
            catch e
                @debug "Could not remove legacy cache file" path exception = e
            end
        end
    end
    return removed
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
    RUSTC_BUILD_ENV_NAMES

Environment that changes what a direct `rustc` invocation produces: rustc itself
ignores `RUSTFLAGS`, but rustup's proxy honours `RUSTUP_TOOLCHAIN`, and
`RUSTFLAGS` is tracked so a user who sets it sees the same rebuild behaviour as
with Cargo-backed blocks. An allowlist by name, never a `CARGO_*` sweep, so a
credential can never reach a key (see `artifact_build_env_captured`).
"""
const RUSTC_BUILD_ENV_NAMES = ("RUSTFLAGS", "RUSTUP_TOOLCHAIN")

"""
    generate_cache_key(code::AbstractString, compiler::RustCompiler; kwargs...) -> String

The identity of one direct-`rustc` artifact: `artifact_key` of an `ArtifactId`
describing the source, the compiler snapshot, the `#[cfg]` set it was expanded
under, the tracked rustc environment, the toolchain fingerprint and — since
#252 — the identity of the compiler that actually runs
(`artifact_compiler_identity`, from `RustToolChain`, never a bare `rustc` on
`PATH` that could degrade to `"unknown"`).

This is the **only** key formula of the direct-rustc path: the on-disk cache key
and the in-memory library name (`_rustc_block_identity`) are the same value, so
the two can no longer drift apart (#278).

# Keyword arguments
- `cfg_text`: the `#[cfg]` snapshot the wrappers were generated from;
  `nothing` (the default) means the current strict snapshot, as in
  `expand_inline`.
- `dependencies`, `build_env`: extra identity components for callers that have
  them; both default to empty, and `build_env` is merged with the tracked rustc
  environment.

Throws a `RustError` when the compiler cannot be identified: a request that is
about to compile must not be cached under an unidentifiable toolchain (#252).
"""
function generate_cache_key(code::AbstractString, compiler::RustCompiler;
                            cfg_text::Union{Nothing, AbstractString} = nothing,
                            dependencies = String[],
                            build_env = Pair{String, String}[])
    text = cfg_text === nothing ? _cfg_snapshot(:strict) : String(cfg_text)
    env = vcat(artifact_build_env(RUSTC_BUILD_ENV_NAMES),
               Pair{String, String}[String(first(p)) => String(last(p)) for p in build_env])
    return artifact_key(ArtifactId(
        kind = "rustc",
        source = String(code),
        target_triple = compiler.target_triple,
        codegen = artifact_codegen_options(compiler),
        cfg = String[stable_content_hash(text)],
        dependencies = dependencies,
        build_env = env,
    ))
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
    _compute_file_checksum(path::String) -> String

Compute SHA-256 checksum of a file for integrity verification.
"""
function _compute_file_checksum(path::String)::String
    return bytes2hex(open(sha256, path))
end

"""
    _save_checksum(cache_key::String, lib_path::String)

Save a SHA-256 checksum file alongside a cached library.
"""
function _save_checksum(cache_key::String, lib_path::String)
    checksum = _compute_file_checksum(lib_path)
    checksum_path = lib_path * ".sha256"
    tmp_path = checksum_path * ".tmp"
    open(tmp_path, "w") do io
        println(io, checksum)
    end
    mv(tmp_path, checksum_path, force=true)
end

"""
    _verify_cached_checksum(cache_key::String, lib_path::String)

Verify the SHA-256 checksum of a cached library. Throws an error if the
checksum doesn't match (possible corruption or tampering).
"""
function _verify_cached_checksum(cache_key::String, lib_path::String)
    checksum_path = lib_path * ".sha256"
    if !isfile(checksum_path)
        # No checksum file (legacy cache entry) — allow loading with a warning
        @debug "No checksum file for cached library: $lib_path"
        return
    end

    stored_checksum = strip(read(checksum_path, String))
    actual_checksum = _compute_file_checksum(lib_path)

    if stored_checksum != actual_checksum
        # Remove the corrupted cache entry
        rm(lib_path, force=true)
        rm(checksum_path, force=true)
        error("Cache checksum mismatch for key $cache_key: expected $stored_checksum, got $actual_checksum. Corrupted cache entry removed.")
    end
end

"""
    save_cached_library(cache_key::String, lib_path::String, metadata::CacheMetadata)

Save a compiled library to the cache along with its metadata and checksum.
"""
function save_cached_library(cache_key::String, lib_path::String, metadata::CacheMetadata)
    lock(CACHE_LOCK) do
        cache_dir = get_cache_dir()
        lib_ext = get_library_extension()
        dest_lib_path = joinpath(cache_dir, "$(cache_key)$(lib_ext)")

        # Copy the library file
        cp(lib_path, dest_lib_path, force=true)

        # Save checksum for integrity verification
        _save_checksum(cache_key, dest_lib_path)

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

Load a cached library and return its handle and the cached library path.

The caller is responsible for providing a consistent library name (e.g.,
based on `stable_content_hash` of the wrapped code) to avoid mismatches
between cache lookup keys and in-memory registry names.
"""
function load_cached_library(cache_key::String)
    lock(CACHE_LOCK) do
        cached_lib = get_cached_library(cache_key)
        if cached_lib === nothing
            error("Cached library not found for key: $cache_key")
        end

        # Verify checksum before loading (issue #198)
        _verify_cached_checksum(cache_key, cached_lib)

        # Load the library
        lib_handle = Libdl.dlopen(cached_lib, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
        if lib_handle == C_NULL
            error("Failed to load cached library: $cached_lib")
        end

        return lib_handle, cached_lib
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
    clear_cache(; sweep_legacy::Bool = false)

Clear all cached libraries and metadata: the current format's tree, plus the
directories older formats left behind.

Loose files from the unversioned pre-#278 layout are removed only with
`sweep_legacy = true`. They live in a directory RustCall shares with Julia's own
precompile output (see `_cache_format_root`), so removing them is opt-in even
though the naming pattern used is exact.

On Windows, some files may be locked and cannot be deleted immediately.
"""
function clear_cache(; sweep_legacy::Bool = false)
    lock(CACHE_LOCK) do
        _clear_cache_unlocked(; sweep_legacy = sweep_legacy)
    end
end

function _clear_cache_unlocked(; sweep_legacy::Bool = false)
    # Clearing "the cache" means every format this RustCall is responsible for,
    # not just the current one, or a `clear_cache()` would leave the pre-#278
    # tree on disk forever.
    sweep_stale_cache_formats(; legacy_files = sweep_legacy)
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
    # Directories written under an older cache format are unreachable by
    # construction, whatever their age: sweep them first (best effort). Loose
    # legacy files are never swept from here — an age-based cleanup has no
    # business deleting files in a directory RustCall shares with Julia's
    # precompile output; `clear_cache(sweep_legacy = true)` is the explicit
    # request for that.
    sweep_stale_cache_formats()

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
    is_cache_valid(cache_key::String, code::String, compiler::RustCompiler; cfg_text = nothing) -> Bool

Check if a cached library is still valid for the given code and compiler
settings. `cfg_text` must be the same snapshot the key was generated under (see
`generate_cache_key`), or the recomputed key cannot match by construction.
"""
function is_cache_valid(cache_key::String, code::String, compiler::RustCompiler;
                        cfg_text::Union{Nothing, AbstractString} = nothing)
    # Generate expected cache key
    expected_key = generate_cache_key(code, compiler; cfg_text = cfg_text)

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
