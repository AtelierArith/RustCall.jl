# Hot reload support for Rust source changes
# This module provides automatic detection and rebuild when Rust source files change.

using FileWatching

# ============================================================================
# Hot Reload State
# ============================================================================

"""
    HotReloadState

State for a hot-reloadable Rust crate.

# Fields
- `crate_path::String`: Path to the Rust crate
- `lib_path::String`: Path to the compiled library
- `lib_name::String`: Name used to register the library
- `source_files::Vector{String}`: Tracked .rs source files
- `last_modified::Dict{String, Float64}`: Last modification times
- `watch_task::Union{Task, Nothing}`: File watching task
- `enabled::Bool`: Whether hot reload is enabled
- `rebuild_callback::Union{Function, Nothing}`: Callback after rebuild
"""
mutable struct HotReloadState
    crate_path::String
    lib_path::String
    lib_name::String
    source_files::Vector{String}
    last_modified::Dict{String, Float64}
    watch_task::Union{Task, Nothing}
    enabled::Bool
    rebuild_callback::Union{Function, Nothing}
end

"""
Registry of hot-reloadable crates.
Maps library name to HotReloadState.
"""
const HOT_RELOAD_REGISTRY = Dict{String, HotReloadState}()

"""
Global flag to enable/disable all hot reload functionality.
"""
const HOT_RELOAD_ENABLED = Ref(true)

"""
Per-library locks to serialize reload operations for the same library.
Prevents concurrent hot reloads of the same crate from corrupting state.
"""
const RELOAD_LOCKS = Dict{String, ReentrantLock}()
const RELOAD_LOCKS_LOCK = ReentrantLock()

"""
    _get_reload_lock(lib_name::String) -> ReentrantLock

Get or create a per-library lock for serializing reload operations.
"""
function _get_reload_lock(lib_name::String)
    lock(RELOAD_LOCKS_LOCK) do
        get!(() -> ReentrantLock(), RELOAD_LOCKS, lib_name)
    end
end

# ============================================================================
# File Watching
# ============================================================================

"""
    find_rust_source_files(crate_path::String) -> Vector{String}

Find all .rs files in a crate's src directory.
"""
function find_rust_source_files(crate_path::String)
    src_dir = joinpath(crate_path, "src")
    if !isdir(src_dir)
        return String[]
    end

    sources = String[]
    _find_rs_files!(sources, src_dir)
    return sources
end

function _find_rs_files!(sources::Vector{String}, dir::String)
    for entry in readdir(dir, join=true)
        if isfile(entry) && endswith(entry, ".rs")
            push!(sources, entry)
        elseif isdir(entry)
            _find_rs_files!(sources, entry)
        end
    end
end

"""
    get_file_mtime(path::String) -> Float64

Get the modification time of a file as a Float64 timestamp.
Returns 0.0 if the file doesn't exist.
"""
function get_file_mtime(path::String)
    try
        return stat(path).mtime
    catch
        return 0.0
    end
end

"""
    check_for_changes(state::HotReloadState) -> Bool

Check if any source files have been modified since last check.
Updates the last_modified times if changes are detected.
"""
function check_for_changes(state::HotReloadState)
    changed = false

    for src_file in state.source_files
        current_mtime = get_file_mtime(src_file)
        last_mtime = get(state.last_modified, src_file, 0.0)

        if current_mtime > last_mtime
            state.last_modified[src_file] = current_mtime
            changed = true
        end
    end

    # Also check for new files
    current_files = find_rust_source_files(state.crate_path)
    for src_file in current_files
        if !(src_file in state.source_files)
            push!(state.source_files, src_file)
            state.last_modified[src_file] = get_file_mtime(src_file)
            changed = true
        end
    end

    return changed
end

# ============================================================================
# Library Reload
# ============================================================================

"""
    reload_library(state::HotReloadState) -> Bool

Rebuild and reload a Rust library.

Returns true if successful, false otherwise.
"""
function reload_library(state::HotReloadState)
    # Acquire per-library lock to serialize reload operations for the same
    # library.  This prevents concurrent hot reloads from corrupting state (#80).
    lib_lock = _get_reload_lock(state.lib_name)
    lock(lib_lock) do
        _reload_library_locked(state)
    end
end

"""
    _reload_library_locked(state::HotReloadState) -> Bool

Internal implementation of reload_library, called while holding the
per-library lock.
"""
function _reload_library_locked(state::HotReloadState)
    @info "Hot reload: Rebuilding $(state.lib_name)..."

    try
        # Unload the old library and clear stale monomorphized functions
        # atomically under REGISTRY_LOCK to prevent other threads from
        # observing an inconsistent state between check and unload.
        lock(REGISTRY_LOCK) do
            if haskey(RUST_LIBRARIES, state.lib_name)
                lib_handle, _ = RUST_LIBRARIES[state.lib_name]
                delete!(RUST_LIBRARIES, state.lib_name)
                if CURRENT_LIB[] == state.lib_name
                    CURRENT_LIB[] = ""
                end
                Libdl.dlclose(lib_handle)
            end

            # Clear stale monomorphized function pointers that belonged to the
            # unloaded library to prevent use-after-free (#73)
            stale_keys = [k for (k, v) in MONOMORPHIZED_FUNCTIONS
                          if v.lib_name == state.lib_name]
            for k in stale_keys
                delete!(MONOMORPHIZED_FUNCTIONS, k)
            end
            if !isempty(stale_keys)
                @debug "Hot reload: Cleared $(length(stale_keys)) stale monomorphized functions"
            end
        end

        # Rebuild the library (outside REGISTRY_LOCK — this takes significant
        # time and must not block other library operations).
        new_lib_path = rebuild_crate(state.crate_path)

        # Update state
        state.lib_path = new_lib_path

        # Re-register the library.  Check that nothing else has registered the
        # same name during the rebuild window.
        lib_handle = Libdl.dlopen(new_lib_path, Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW)
        lock(REGISTRY_LOCK) do
            if haskey(RUST_LIBRARIES, state.lib_name)
                @warn "Hot reload: Library $(state.lib_name) was re-registered during rebuild; overwriting"
            end
            RUST_LIBRARIES[state.lib_name] = (lib_handle, Dict{String, Ptr{Cvoid}}())
        end

        @info "Hot reload: Successfully reloaded $(state.lib_name)"

        # Call the callback if provided
        if state.rebuild_callback !== nothing
            try
                state.rebuild_callback(state.lib_name, true, nothing)
            catch e
                @warn "Hot reload callback error: $e"
            end
        end

        return true

    catch e
        @error "Hot reload: Failed to rebuild $(state.lib_name)" exception=e

        # Call the callback with failure
        if state.rebuild_callback !== nothing
            try
                state.rebuild_callback(state.lib_name, false, e)
            catch callback_e
                @warn "Hot reload callback error: $callback_e"
            end
        end

        return false
    end
end

"""
    rebuild_crate(crate_path::String) -> String

Rebuild a Rust crate and return the path to the compiled library.
"""
function rebuild_crate(crate_path::String)
    # Check if it has cdylib crate-type
    cargo_toml_path = joinpath(crate_path, "Cargo.toml")
    if !isfile(cargo_toml_path)
        error("Cargo.toml not found in: $crate_path")
    end

    cargo_toml = TOML.parsefile(cargo_toml_path)
    crate_name = cargo_toml["package"]["name"]
    lib_section = get(cargo_toml, "lib", Dict())
    crate_types = get(lib_section, "crate-type", String[])

    if !("cdylib" in crate_types)
        error("Crate must have crate-type = [\"cdylib\"] for hot reload")
    end

    # Build in release mode
    cmd = `cargo build --release --manifest-path $cargo_toml_path`
    run(cmd)

    # Find the compiled library
    target_dir = joinpath(crate_path, "target", "release")
    lib_name = _get_library_filename(crate_name)
    lib_path = joinpath(target_dir, lib_name)

    if !isfile(lib_path)
        error("Compiled library not found: $lib_path")
    end

    return lib_path
end

"""
    _get_library_filename(crate_name::String) -> String

Get the platform-specific library filename for a crate.
"""
function _get_library_filename(crate_name::String)
    # Replace hyphens with underscores (Rust convention)
    lib_base = replace(crate_name, "-" => "_")

    if Sys.iswindows()
        return "$lib_base.dll"
    elseif Sys.isapple()
        return "lib$lib_base.dylib"
    else
        return "lib$lib_base.so"
    end
end

# ============================================================================
# Watch Task
# ============================================================================

"""
    start_watch_task(state::HotReloadState; interval::Float64=1.0)

Start a background task that watches for file changes.
"""
function start_watch_task(state::HotReloadState; interval::Float64=1.0)
    if state.watch_task !== nothing && !istaskdone(state.watch_task)
        @warn "Watch task already running for $(state.lib_name)"
        return
    end

    state.watch_task = @async begin
        @info "Hot reload: Watching $(state.crate_path) for changes..."

        while state.enabled && HOT_RELOAD_ENABLED[]
            try
                if check_for_changes(state)
                    reload_library(state)
                end
            catch e
                @error "Hot reload watch error: $e"
            end

            sleep(interval)
        end

        @info "Hot reload: Stopped watching $(state.lib_name)"
    end
end

"""
    stop_watch_task(state::HotReloadState)

Stop the file watching task for a crate.
"""
function stop_watch_task(state::HotReloadState)
    state.enabled = false

    if state.watch_task !== nothing && !istaskdone(state.watch_task)
        # The task will stop on its own when state.enabled becomes false
        @info "Hot reload: Stopping watch task for $(state.lib_name)..."
    end

    state.watch_task = nothing
end

# ============================================================================
# Public API
# ============================================================================

"""
    enable_hot_reload(lib_name::String, crate_path::String; kwargs...) -> HotReloadState

Enable hot reload for a Rust crate.

# Arguments
- `lib_name::String`: Name of the loaded library
- `crate_path::String`: Path to the Rust crate root

# Keyword Arguments
- `interval::Float64`: Check interval in seconds (default: 1.0)
- `callback::Union{Function, Nothing}`: Callback after rebuild (receives lib_name, success, error)

# Returns
- `HotReloadState`: The hot reload state for the crate

# Example
```julia
# Load a Rust crate
rust\"\"\"
// cargo-deps: my_crate = { path = "./my_rust_crate" }
use my_crate::*;
\"\"\"

# Enable hot reload
state = enable_hot_reload("my_crate", "./my_rust_crate")

# Now modify Rust code and it will automatically reload!

# When done, disable hot reload
disable_hot_reload("my_crate")
```
"""
function enable_hot_reload(lib_name::String, crate_path::String;
    interval::Float64 = 1.0,
    callback::Union{Function, Nothing} = nothing
)
    # Validate inputs
    if !isdir(crate_path)
        error("Crate path does not exist: $crate_path")
    end

    # Check if already registered
    if haskey(HOT_RELOAD_REGISTRY, lib_name)
        existing = HOT_RELOAD_REGISTRY[lib_name]
        if existing.enabled
            @warn "Hot reload already enabled for $lib_name"
            return existing
        end
    end

    # Find source files
    source_files = find_rust_source_files(crate_path)
    if isempty(source_files)
        @warn "No .rs files found in $crate_path"
    end

    # Get initial modification times
    last_modified = Dict{String, Float64}()
    for src_file in source_files
        last_modified[src_file] = get_file_mtime(src_file)
    end

    # Get current library path
    lib_path = ""
    if lock(REGISTRY_LOCK) do
        haskey(RUST_LIBRARIES, lib_name)
    end
        # Library is already loaded, we need to find its path
        # For now, we'll rebuild on first change
    end

    # Create state
    state = HotReloadState(
        abspath(crate_path),
        lib_path,
        lib_name,
        source_files,
        last_modified,
        nothing,
        true,
        callback
    )

    # Register
    HOT_RELOAD_REGISTRY[lib_name] = state

    # Start watching
    start_watch_task(state, interval=interval)

    return state
end

"""
    disable_hot_reload(lib_name::String)

Disable hot reload for a Rust crate.

# Arguments
- `lib_name::String`: Name of the library to disable hot reload for
"""
function disable_hot_reload(lib_name::String)
    if !haskey(HOT_RELOAD_REGISTRY, lib_name)
        @warn "Hot reload not enabled for $lib_name"
        return
    end

    state = HOT_RELOAD_REGISTRY[lib_name]
    stop_watch_task(state)
    state.enabled = false

    @info "Hot reload disabled for $lib_name"
end

"""
    disable_all_hot_reload()

Disable hot reload for all registered crates.
"""
function disable_all_hot_reload()
    for lib_name in keys(HOT_RELOAD_REGISTRY)
        disable_hot_reload(lib_name)
    end
end

"""
    is_hot_reload_enabled(lib_name::String) -> Bool

Check if hot reload is enabled for a library.
"""
function is_hot_reload_enabled(lib_name::String)
    if !haskey(HOT_RELOAD_REGISTRY, lib_name)
        return false
    end
    return HOT_RELOAD_REGISTRY[lib_name].enabled
end

"""
    list_hot_reload_crates() -> Vector{String}

List all crates with hot reload enabled.
"""
function list_hot_reload_crates()
    return [name for (name, state) in HOT_RELOAD_REGISTRY if state.enabled]
end

"""
    trigger_reload(lib_name::String) -> Bool

Manually trigger a reload for a library.

Returns true if successful, false otherwise.
"""
function trigger_reload(lib_name::String)
    if !haskey(HOT_RELOAD_REGISTRY, lib_name)
        error("Hot reload not enabled for $lib_name. Call enable_hot_reload first.")
    end

    state = HOT_RELOAD_REGISTRY[lib_name]
    return reload_library(state)
end

"""
    set_hot_reload_global(enabled::Bool)

Enable or disable hot reload functionality globally.

When disabled, all watch tasks will stop.
"""
function set_hot_reload_global(enabled::Bool)
    HOT_RELOAD_ENABLED[] = enabled

    if !enabled
        @info "Hot reload globally disabled"
    else
        @info "Hot reload globally enabled"
    end
end

# ============================================================================
# Integration with @rust_crate
# ============================================================================

"""
    enable_hot_reload_for_crate(crate_path::String; kwargs...) -> HotReloadState

Enable hot reload for a crate loaded via @rust_crate.

This is a convenience function that determines the library name from the crate.

# Arguments
- `crate_path::String`: Path to the Rust crate

# Keyword Arguments
- Same as `enable_hot_reload`

# Example
```julia
@rust_crate "/path/to/my_crate"

# Enable hot reload
enable_hot_reload_for_crate("/path/to/my_crate")
```
"""
function enable_hot_reload_for_crate(crate_path::String; kwargs...)
    # Get crate name from Cargo.toml
    cargo_toml_path = joinpath(crate_path, "Cargo.toml")
    if !isfile(cargo_toml_path)
        error("Cargo.toml not found in: $crate_path")
    end

    cargo_toml = TOML.parsefile(cargo_toml_path)
    crate_name = cargo_toml["package"]["name"]

    # The module name is the crate name converted to PascalCase
    lib_name = snake_to_pascal(crate_name)

    return enable_hot_reload(lib_name, crate_path; kwargs...)
end
