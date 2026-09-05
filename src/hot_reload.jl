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
    _source_stamps(crate_path) -> Vector{Tuple{String, Float64, Int}}

`(path, mtime, size)` of every `.rs` file of the crate, sorted.

Used to decide whether the sources a rescan described are still the sources
that were built. It is a *change detector*, not an identity: it never decides
what to compile (that is `src/artifact_id.jl`, which hashes content), only
whether to trust a manifest that was produced a moment ago.
"""
function _source_stamps(crate_path::String)
    stamps = Tuple{String, Float64, Int}[]
    for f in sort(find_rust_source_files(crate_path))
        st = try
            stat(f)
        catch
            continue
        end
        push!(stamps, (f, st.mtime, Int(st.size)))
    end
    return stamps
end

"""
    _scan_crate_signatures(crate_path) -> Union{Vector, Nothing}

The `#[julia]` function signatures of a crate that RustCall has just built
`--release`, scanned under **that crate's own build configuration**.

`_crate_build_cfg_text` probes the crate in place (`cargo rustc --release --lib
-- --print cfg`), so its features and its build script's `cargo:rustc-cfg`
output decide the `#[cfg]` predicates. Two mutually exclusive
`#[cfg(feature = ...)]` variants of one `#[julia] fn` then collapse to the one
that exists, and its return type is registered instead of being suppressed as
ambiguous (#279).

When the probe comes back empty — cargo unavailable, a crate Cargo will not
probe — the scan falls back to the lenient one, which decides only target
predicates. That is the fail-safe: an ambiguous function keeps its symbol
mapping and loses only its return-type hint, so the call falls through to
inference or an explicit `::T` rather than to the wrong ABI.

`nothing` when the scan itself fails; the caller then registers the library
with no mappings rather than losing the rebuilt library.
"""
function _scan_crate_signatures(crate_path::String)
    return try
        cfg_text = _crate_build_cfg_text(crate_path)
        if isempty(cfg_text)
            @debug "Hot reload: no build cfg for $(crate_path); scanning leniently"
            scan_crate(crate_path).julia_functions
        else
            scan_crate(crate_path; cfg = :cargo, cfg_text).julia_functions
        end
    catch error
        @warn "Hot reload: could not rescan $(crate_path) for exported symbols" error
        nothing
    end
end

"""
    _reload_library_locked(state::HotReloadState) -> Bool

Internal implementation of reload_library, called while holding the
per-library lock.

# Rebuild first, swap last (#255)

Everything that can fail — the rescan, `cargo build`, the `dlopen` — completes
**before** the previous library is touched. A failed rebuild therefore leaves
the old library loaded, with its function-pointer cache, its symbol mappings,
its monomorphizations and `CURRENT_LIB` intact, instead of emptying the registry
and leaving the user with no library at all. The swap itself is one
`load_artifact!` under `REGISTRY_LOCK`, which retires the old artifact (so
objects it produced go inert), purges its rows and `dlclose`s the old handle
after the lock.

# Rescan before the build

The scan describes the sources; the build compiles them. Scanning *after* the
build would describe sources that may have changed in between and hand the
freshly built library another build's symbol table. So the source files are
stamped, scanned, built, and stamped again: if a stamp moved, the scan is
discarded rather than trusted, and the library is registered with no symbol
mappings (a `#[julia]` function is then reachable only by its exported symbol
until the next reload).
"""
function _reload_library_locked(state::HotReloadState)
    @info "Hot reload: Rebuilding $(state.lib_name)..."

    try
        # Stamp the sources, then scan them. Scanning runs the extractor and
        # must not hold REGISTRY_LOCK.
        before = _source_stamps(state.crate_path)
        signatures = _scan_crate_signatures(state.crate_path)

        # Rebuild. No registry lock is held here — this takes significant
        # time and must not block other library operations — and the old
        # library stays loaded and usable throughout.
        new_lib_path = rebuild_crate(state.crate_path)

        # Did the sources move under the scan? Then the manifest is not
        # evidence about what was just built.
        after = _source_stamps(state.crate_path)
        if signatures !== nothing && before != after
            @warn "Hot reload: $(state.crate_path) changed while it was being rebuilt; " *
                  "registering the new library without symbol mappings"
            signatures = nothing
        end

        symbols, return_types = signatures === nothing ? ((), ()) :
                                _manifest_registry_entries(signatures)

        # The swap. `on_replace = :dlclose` closes the *previous* handle after
        # the lock is released; a failure anywhere above never reaches here.
        state.lib_path = new_lib_path
        load_artifact!(hot_reload_policy(), new_lib_path;
                       lib_name = state.lib_name, symbols, return_types,
                       on_replace = :dlclose)
        # Monomorphizations resolved against the previous image hold raw
        # pointers into it (#73); they belong to the replaced artifact, not to
        # the new one.
        lock(REGISTRY_LOCK) do
            stale = [k for (k, v) in MONOMORPHIZED_FUNCTIONS if v.lib_name == state.lib_name]
            for k in stale
                delete!(MONOMORPHIZED_FUNCTIONS, k)
            end
            isempty(stale) ||
                @debug "Hot reload: Cleared $(length(stale)) stale monomorphized functions"
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

    task = state.watch_task
    if task !== nothing && !istaskdone(task)
        # Wait for the watch task to finish so any in-progress reload completes
        # before we return. This prevents the caller from observing an
        # inconsistent state where a reload is still running.
        @info "Hot reload: Stopping watch task for $(state.lib_name)..."
        try
            wait(task)
        catch e
            # Task may throw if it was interrupted; ignore
            @debug "Hot reload: Watch task ended with: $e"
        end
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

    # Check if already registered (protect HOT_RELOAD_REGISTRY with REGISTRY_LOCK)
    lock(REGISTRY_LOCK) do
        if haskey(HOT_RELOAD_REGISTRY, lib_name)
            existing = HOT_RELOAD_REGISTRY[lib_name]
            if existing.enabled
                @warn "Hot reload already enabled for $lib_name"
                return existing
            end
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
    lock(REGISTRY_LOCK) do
        if haskey(RUST_LIBRARIES, lib_name)
            # Library is already loaded, we need to find its path
            # For now, we'll rebuild on first change
        end
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

    # Register (protect HOT_RELOAD_REGISTRY with REGISTRY_LOCK)
    lock(REGISTRY_LOCK) do
        HOT_RELOAD_REGISTRY[lib_name] = state
    end

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
    state = lock(REGISTRY_LOCK) do
        if !haskey(HOT_RELOAD_REGISTRY, lib_name)
            @warn "Hot reload not enabled for $lib_name"
            return nothing
        end
        HOT_RELOAD_REGISTRY[lib_name]
    end

    if state === nothing
        return
    end

    stop_watch_task(state)
    state.enabled = false

    @info "Hot reload disabled for $lib_name"
end

"""
    disable_all_hot_reload()

Disable hot reload for all registered crates.
"""
function disable_all_hot_reload()
    lib_names = lock(REGISTRY_LOCK) do
        collect(keys(HOT_RELOAD_REGISTRY))
    end
    for lib_name in lib_names
        disable_hot_reload(lib_name)
    end
end

"""
    is_hot_reload_enabled(lib_name::String) -> Bool

Check if hot reload is enabled for a library.
"""
function is_hot_reload_enabled(lib_name::String)
    lock(REGISTRY_LOCK) do
        if !haskey(HOT_RELOAD_REGISTRY, lib_name)
            return false
        end
        return HOT_RELOAD_REGISTRY[lib_name].enabled
    end
end

"""
    list_hot_reload_crates() -> Vector{String}

List all crates with hot reload enabled.
"""
function list_hot_reload_crates()
    lock(REGISTRY_LOCK) do
        return [name for (name, state) in HOT_RELOAD_REGISTRY if state.enabled]
    end
end

"""
    trigger_reload(lib_name::String) -> Bool

Manually trigger a reload for a library.

Returns true if successful, false otherwise.
"""
function trigger_reload(lib_name::String)
    state = lock(REGISTRY_LOCK) do
        if !haskey(HOT_RELOAD_REGISTRY, lib_name)
            error("Hot reload not enabled for $lib_name. Call enable_hot_reload first.")
        end
        HOT_RELOAD_REGISTRY[lib_name]
    end
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
