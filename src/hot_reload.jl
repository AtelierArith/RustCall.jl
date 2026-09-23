# Hot reload support for Rust source changes
# This module provides automatic detection and rebuild when Rust source files change.

import FileWatching

# ============================================================================
# Hot Reload State
# ============================================================================

"""
    HotReloadState

State for a hot-reloadable Rust crate.

# Fields
- `record::CrateBuildRecord`: every input of the build a reload reproduces —
  crate, registry name, profile, features, kind, build environment, Cargo
  configuration, toolchain. The only source of a rebuild's inputs (#474).
  `state.crate_path`, `state.lib_name` and `state.build_options` read it.
- `lib_path::String`: Path to the compiled library
- `source_files::Vector{String}`: Tracked .rs source files
- `last_modified::Dict{String, Float64}`: Last modification times
- `watch_task::Union{Task, Nothing}`: File watching task
- `enabled::Bool`: Whether hot reload is enabled
- `rebuild_callback::Union{Function, Nothing}`: Callback after rebuild
"""
mutable struct HotReloadState
    # Immutable: nothing a reload does can change what it rebuilds. A module's
    # own `_BUILD_RECORD`, or the one the path form constructed (#474).
    const record::CrateBuildRecord
    lib_path::String
    source_files::Vector{String}
    last_modified::Dict{String, Float64}
    watch_task::Union{Task, Nothing}
    enabled::Bool
    rebuild_callback::Union{Function, Nothing}
    # The generation of the last successful reload, for diagnostics. The value
    # comes from `next_reload_generation()`, a process-wide counter — a
    # per-state integer restarted at 0 when hot reload was disabled and
    # re-enabled, and the reload then tried to write `<lib>.1.<ext>` while the
    # image of that name was still mapped, which fails outright on Windows
    # (#255).
    generation::Int
    # The last rebuild failure that was reported, so the ordinary dev loop —
    # save with a typo, save again — does not print the same error on every
    # watch tick. Cleared by a successful reload.
    last_failure::String
end

# Backwards-compatible positional constructor: the crate path, the registry
# name and `build_options` become the record of a build made now
# (`crate_build_record`), unless `record` is given; the bookkeeping fields are
# never supplied by a caller.
function HotReloadState(crate_path, lib_path, lib_name, source_files, last_modified,
                        watch_task, enabled, rebuild_callback;
                        build_options::NamedTuple = crate_build_options(),
                        record::Union{Nothing, CrateBuildRecord} = nothing)
    record = something(record, crate_build_record(crate_path, lib_name;
                                                  build_options = build_options))
    return HotReloadState(record, lib_path, source_files, last_modified, watch_task,
                          enabled, rebuild_callback, 0, "")
end

# The record's inputs under the names the state always had.
function Base.getproperty(state::HotReloadState, name::Symbol)
    name === :crate_path && return getfield(state, :record).crate_dir
    name === :lib_name && return getfield(state, :record).lib_name
    name === :build_options && return record_build_options(getfield(state, :record))
    return getfield(state, name)
end

Base.propertynames(state::HotReloadState, private::Bool = false) =
    (fieldnames(HotReloadState)..., :crate_path, :lib_name, :build_options)

_build_env_mismatch_message(lib_name, changed) =
    "Hot reload of $(lib_name): the build environment differs from the one its module " *
    "was built under ($(join(changed, ", "))). A rebuild now would publish a library " *
    "with other `#[cfg]`s under the module's registry name, so it is refused. Restore " *
    "the environment, or load the crate again with `@rust_crate` under the new one."

"""
Registry of hot-reloadable crates.
Maps library name to HotReloadState.
"""
const HOT_RELOAD_REGISTRY = _state_view(:hot_reload_registry,
    Dict{String, HotReloadState}())

"""
Global flag to enable/disable all hot reload functionality.
"""
const HOT_RELOAD_ENABLED = _state_view(:hot_reload_enabled, Ref(true))

"""
Per-library locks to serialize reload operations for the same library.
Prevents concurrent hot reloads of the same crate from corrupting state.
"""
const RELOAD_LOCKS = _state_view(:reload_locks, Dict{String, ReentrantLock}())
const RELOAD_LOCKS_LOCK = REGISTRY_LOCK

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
    Threads.atomic_add!(SOURCE_SCANS, 1)
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
    _source_fingerprint(crate_path) -> String

A content digest of exactly what the **scan** reads: the crate's Rust sources
and its `Cargo.toml`.

The question this answers is narrow — "does the manifest I just produced still
describe the files that were compiled?" — so the input set is the scan's input
set, hashed by content (`_file_content_digest`, the same primitive
`src/artifact_id.jl` uses). Content, not `(mtime, size)`: the edit most likely
in that window is one character for another, same length, with the mtime
restored by an editor, a formatter or a version-control checkout.

It is deliberately **not** `crate_content_digest`, which is the *artifact
identity* and therefore hashes everything a build reads — including
`Cargo.lock`. Cargo writes `Cargo.lock` during the very build this check
straddles, so a crate that does not have one yet (it is ignored by version
control here, and in most repositories) changed its identity digest between the
scan and the build every single time. The check then declared the manifest
untrustworthy and registered the rebuilt library with **no symbol mappings** —
precisely the failure this function exists to prevent: `@rust f(...)` hunting
for `f` while the library exports `rustcall_f`.

Returns `""` when the digest cannot be taken, which the caller treats as "no
evidence" and therefore as "unchanged": failing to hash a crate that just built
successfully should not throw the rebuilt library away.
"""
function _source_fingerprint(crate_path::String)
    return try
        io = IOBuffer()
        inputs = String[find_rust_sources(crate_path)...]
        manifest = joinpath(crate_path, "Cargo.toml")
        isfile(manifest) && push!(inputs, manifest)
        for file in sort(unique(inputs))
            print(io, relpath(file, crate_path), "\0")
            print(io, isfile(file) ? _file_content_digest(file) : "missing", "\0")
        end
        bytes2hex(sha256(take!(io)))
    catch e
        @debug "Hot reload: could not fingerprint $(crate_path)" exception = e
        ""
    end
end

"""
    _scan_crate_signatures(record::CrateBuildRecord) -> Vector
    _scan_crate_signatures(crate_path; build_options = crate_build_options()) -> Vector

The `#[julia]` function signatures of the crate `record` names, scanned under
**that build's own configuration**: its profile and features, read from the
record and nothing else (#474).

`_crate_build_cfg_text` probes the crate in place (`cargo rustc --lib -- --print
cfg`), so its features and its build script's `cargo:rustc-cfg` output decide
the `#[cfg]` predicates. Two mutually exclusive `#[cfg(feature = ...)]`
variants of one `#[julia] fn` then collapse to the one that exists, and its
return type is registered instead of being suppressed as ambiguous (#279).

When the probe comes back empty — cargo unavailable, a crate Cargo will not
probe — the scan falls back to the lenient one, which decides only target
predicates. That is the fail-safe: an ambiguous function keeps its symbol
mapping and loses only its return-type hint, so the call falls through to
inference or an explicit `::T` rather than to the wrong ABI.

A failed scan **throws**. It is the first step of a reload, and a reload that
cannot describe what it is about to publish fails like one whose build fails:
the previous library stays current (#473). It used to return `nothing`, and the
rebuilt library was then published with no symbol mappings and reported as a
success.

The path method is a thin constructor of a record with no environment, for
callers that only want the scan.
"""
function _scan_crate_signatures(record::CrateBuildRecord;
                                env::Union{Nothing, AbstractDict} = nothing)
    crate_path = record.crate_dir
    # A reload re-probes rather than trusting the memo: a `build.rs` can
    # change its `cargo::rustc-cfg` output without any input RustCall is
    # able to enumerate (#255).
    # Probed where `rebuild_crate` builds — `crate_target_directory`, the
    # probe's own default — so the probe shares that build and its OUT_DIR
    # (#447 review, #461).
    # Under the record's profile and features, so the scan describes the
    # build that is about to be published (#461 review).
    cfg_text = _crate_build_cfg_text(crate_path; memo = false,
        profile = record.release ? "release" : "debug",
        features = _cargo_feature_args(collect(String, record.features),
                                       record.default_features),
        env = env)
    if isempty(cfg_text)
        @debug "Hot reload: no build cfg for $(crate_path); scanning leniently"
        return scan_crate(crate_path).julia_functions
    end
    return scan_crate(crate_path; cfg = :cargo, cfg_text).julia_functions
end

_scan_crate_signatures(crate_path::AbstractString;
                       build_options::NamedTuple = crate_build_options()) =
    _scan_crate_signatures(_bare_build_record(crate_path, build_options))

# A record of `build_options` for `crate_path` with no registry name and no
# environment: what the path methods of `rebuild_crate` and
# `_scan_crate_signatures` build from. Neither compares the environment — the
# reload does, before calling them, from its own record.
_bare_build_record(crate_path::AbstractString, options::NamedTuple) =
    CrateBuildRecord(abspath(String(crate_path)), "", options.release, options.features,
                     options.default_features, options.kind, (), "", "", false)

"""
    _reload_library_locked(state::HotReloadState) -> Bool

Internal implementation of reload_library, called while holding the
per-library lock.

# Rebuild first, swap last (#255)

Everything that can fail — the environment check against the record, the
rescan, `cargo build`, the copy, the `dlopen` — completes **before** the
previous library is touched, and a failure in any of them fails the reload the
same way: `false`, `last_failure` set, the callback told, and the old library
still loaded, with its function-pointer cache, its symbol mappings, its
monomorphizations and `CURRENT_LIB` intact, instead of emptying the registry
and leaving the user with no library at all (#473). The swap itself is one
`load_artifact!` under `REGISTRY_LOCK` that replaces the registry entry and
**retires** the previous image — it is not closed. A call already running
inside it finishes there, and objects it allocated keep its destructor and its
still-true liveness flag, so they are freed by their own allocator whenever
they are collected (`RETIRED_HANDLES`, #277). Retired images are closed only by
an explicit `unload_library(name; close = true)`.

# Rescan before the build

The scan describes the sources; the build compiles them. Scanning *after* the
build would describe sources that may have changed in between and hand the
freshly built library another build's symbol table. So the sources are
fingerprinted by **content** — the scan's own inputs, the Rust sources and the
manifest — scanned, built, and fingerprinted again: if the digest
moved, the scan is discarded rather than trusted, and the library is registered
with no symbol mappings (a `#[julia]` function is then reachable only by its
exported symbol until the next reload). A `(mtime, size)` stamp would miss a
same-size edit with a restored mtime, which is exactly what an editor or a
`git checkout` produces.
"""
function _reload_library_locked(state::HotReloadState)
    # A save that lands *during* the build is not lost. Nothing is subscribed
    # while `reload_library` runs — the watch task is inside this call, and a
    # manual `trigger_reload` has no subscription at all — so the event that
    # would have woken the watcher never arrives, and the library would keep
    # serving the previous edit until something else happened to change. The
    # fingerprint taken before the build and compared after it already detects
    # exactly that; now it also causes another pass rather than only
    # invalidating the scan.
    #
    # Bounded, because "someone is typing" would otherwise be an unbounded
    # loop: after `MAX_RELOAD_CHASES` the last build stands and the watcher —
    # subscribed again by then — picks up whatever is still newer.
    for attempt in 1:MAX_RELOAD_CHASES
        ok, chase = _reload_library_once(state)
        ok || return false
        chase || return true
        @info "Hot reload: $(state.crate_path) changed during the rebuild; " *
              "reloading again ($(attempt)/$(MAX_RELOAD_CHASES))"
    end
    return true
end

"""
    _reload_failure_fingerprint(e) -> String

What decides whether a failed reload is "the same failure as last time": the
rendered error, minus Cargo's transient status lines. A `CargoBuildError` carries
Cargo's stderr, and a line such as `Blocking waiting for file lock on package
cache` or `Compiling dep v1.0` depends on what else was building at that moment,
not on the failure — keeping it would report one compile error again on every
attempt (#461).
"""
function _reload_failure_fingerprint(e)
    e isa CargoBuildError || return sprint(showerror, e)
    kept = filter(split(e.stderr, '\n')) do line
        # Matched without Cargo's colour codes: under `CARGO_TERM_COLOR` (CI)
        # a status line starts with an escape sequence, not the word, and a
        # colourless pattern let one run's lock waits through (Windows CI).
        plain = replace(line, r"\e\[[0-9;]*m" => "")
        !occursin(r"^\s*(Blocking|Compiling|Checking|Updating|Downloading|Downloaded|Locking|Adding|Fresh|Finished|Building|Running)\s", plain)
    end
    return sprint(showerror, CargoBuildError(e.message, join(kept, '\n'), e.project_path))
end

"""
    MAX_RELOAD_CHASES

How many times a reload may immediately follow itself because the sources
changed while it was building.

Three is enough for "save, notice a typo, save again" and small enough that a
file being written continuously costs three builds, not a livelock.
"""
const MAX_RELOAD_CHASES = 3

# One reload transaction. Returns `(succeeded, sources_changed_during_build)`.
function _reload_library_once(state::HotReloadState)
    @info "Hot reload: Rebuilding $(state.lib_name)..."

    try
        # Every input comes from the state's record, and nothing else (#474).
        # The environment first: a rebuild under another one is refused and the
        # previous library stays loaded, reported like any failed rebuild
        # (#461 review).
        record = state.record
        changed = _build_record_mismatch(record)
        isempty(changed) ||
            throw(ArgumentError(_build_env_mismatch_message(record.lib_name, changed)))
        # ONE subprocess environment, from the record, for the probe and the
        # build alike: the check above reads `ENV` once, and another task may
        # change `ENV` while Cargo runs; neither subprocess reads it (#474
        # review).
        env = _record_build_subprocess_env(record)

        # Fingerprint the sources by content, then scan them. Scanning runs
        # the extractor and must not hold REGISTRY_LOCK. A failed scan throws
        # and fails the reload, like a failed build (#473).
        before = _source_fingerprint(record.crate_dir)
        signatures = _scan_crate_signatures(record; env = env)

        # Rebuild. No registry lock is held here — this takes significant
        # time and must not block other library operations — and the old
        # library stays loaded and usable throughout.
        built = rebuild_crate(record; env = env)

        # Open a *copy* under a fresh name, never the file Cargo just wrote
        # (`loadable_library_copy`).
        new_lib_path = loadable_library_copy(built)

        # Did the sources change under the scan? Then the manifest is not
        # evidence about what was just built — and the build is not evidence
        # about what is on disk, which is what `chase` says.
        after = _source_fingerprint(record.crate_dir)
        chase = !isempty(before) && before != after
        if chase
            # Published without mappings for the moment only: `chase` makes
            # the caller rebuild at once, scanning the sources now on disk.
            @warn "Hot reload: $(record.crate_dir) changed while it was being rebuilt; " *
                  "registering the new library without symbol mappings"
        end

        symbols, return_types = chase ? ((), ()) : _manifest_registry_entries(signatures)

        # The swap. The previous image is retired, not closed: a call that
        # started before the reload may still be running inside it, and there
        # is no per-call reader pin that would make closing safe
        # (`RETIRED_HANDLES`). A failure anywhere above never reaches here.
        load_artifact!(hot_reload_policy(), new_lib_path;
                       lib_name = record.lib_name, symbols, return_types)
        # Recorded once the new image is current, so a failed load leaves the
        # state describing the library that is still in use.
        state.lib_path = new_lib_path
        state.generation = RELOAD_GENERATION[]
        # Monomorphizations resolved against the previous image hold raw
        # pointers into it (#73); they belong to the replaced artifact, not to
        # the new one.
        cleared = lock(REGISTRY_LOCK) do
            stale = [k for (k, v) in MONOMORPHIZED_FUNCTIONS if v.lib_name == state.lib_name]
            for k in stale
                delete!(MONOMORPHIZED_FUNCTIONS, k)
                # The owner goes with the row: an owner without a row is a
                # tombstone no purge can reach (#397).
                delete!(MONOMORPHIZATION_OWNERS, k)
            end
            length(stale)
        end
        cleared == 0 || @debug "Hot reload: Cleared $cleared stale monomorphized functions"

        state.last_failure = ""
        @info "Hot reload: Successfully reloaded $(state.lib_name)"

        # Call the callback if provided
        if state.rebuild_callback !== nothing
            try
                state.rebuild_callback(state.lib_name, true, nothing)
            catch e
                @warn "Hot reload callback error: $e"
            end
        end

        return (true, chase)

    catch e
        # Report each distinct failure once. The dev loop is "save, see the
        # error, fix it, save again"; a watcher that reprints the same compile
        # error on every tick buries the one that matters. The previous library
        # is still loaded and still works — that is the point of the ordering
        # above — so this is informational, not fatal (#255).
        fingerprint = _reload_failure_fingerprint(e)
        if fingerprint != state.last_failure
            state.last_failure = fingerprint
            @error "Hot reload: Failed to rebuild $(state.lib_name); " *
                   "the previously loaded library is still in use" exception=e
        else
            @debug "Hot reload: same failure as last time" lib_name=state.lib_name
        end

        # Call the callback with failure
        if state.rebuild_callback !== nothing
            try
                state.rebuild_callback(state.lib_name, false, e)
            catch callback_e
                @warn "Hot reload callback error: $callback_e"
            end
        end

        return (false, false)
    end
end

"""
    rebuild_crate(record::CrateBuildRecord) -> String
    rebuild_crate(crate_path::String; build_options = crate_build_options()) -> String

Rebuild a Rust crate and return the path to the compiled library.

The build is the one `@rust_crate` runs for a crate that is its own `cdylib`
(`build_crate_directly`): `build_cargo_project` with RustToolChain's `cargo`,
`--offline` under `RUSTCALL_OFFLINE`, and the output under RustCall's
`crate_target_directory` — never the crate's own `target/`, and never wherever
an ambient `CARGO_TARGET_DIR` points — found again under the library's `[lib]
name`. A bare `cargo build --manifest-path` into `target/` ignored all four
(#461).

The crate, the profile and the feature selection are the record's and nothing
else's (#474): a reload rebuilds the build the replaced library was, never a
default one, and only a `:direct` build — the crate as its own `cdylib` — can
be rebuilt here. The path method is a thin constructor of such a record.
"""
function rebuild_crate(record::CrateBuildRecord; env::Union{Nothing, AbstractDict} = nothing)
    record.kind === :direct || throw(ArgumentError(
        "Hot reload rebuilds a crate as its own `cdylib`; this library was built " *
        "as `$(record.kind)`, which a reload cannot reproduce."))
    crate_path = record.crate_dir
    # Check if it has cdylib crate-type
    cargo_toml_path = joinpath(crate_path, "Cargo.toml")
    if !isfile(cargo_toml_path)
        error("Cargo.toml not found in: $crate_path")
    end

    cargo_toml = TOML.parsefile(cargo_toml_path)
    crate_name = String(cargo_toml["package"]["name"])
    lib_section = get(cargo_toml, "lib", Dict())
    crate_types = get(lib_section, "crate-type", String[])

    if !("cdylib" in crate_types)
        error("Crate must have crate-type = [\"cdylib\"] for hot reload")
    end

    # The user's manifest is the Cargo root, so the policy pins nothing and
    # their profile decides, exactly as for `@rust_crate` (`crate_direct_policy`).
    project = CargoProject(crate_name, "0.0.0", DependencySpec[], "2021", crate_path)
    return build_cargo_project(project; release = record.release, env = env,
                               policy = crate_direct_policy(),
                               features = collect(String, record.features),
                               default_features = record.default_features,
                               target_directory = _mark_target_used!(crate_target_directory(crate_path)))
end

rebuild_crate(crate_path::AbstractString; build_options::NamedTuple = crate_build_options()) =
    rebuild_crate(_bare_build_record(crate_path, build_options))

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
function start_watch_task(state::HotReloadState; interval::Float64=1.0,
                          poll::Bool=false)
    task = Task() do
        @info "Hot reload: Watching $(state.crate_path) for changes..."

        while _watch_is_enabled(state)
            try
                changed = if poll
                    sleep(interval)
                    check_for_changes(state)
                else
                    _await_source_change(state, interval)
                end
                changed || continue
                # Debounce. An editor save is rarely one event — write to a
                # temporary file, rename, touch — and a formatter or a
                # multi-file refactor produces a burst. Waiting out the burst
                # turns "two saves within 200 ms" into one rebuild instead of
                # two, the second of which would race the first (#255).
                _drain_source_changes(state, HOT_RELOAD_DEBOUNCE_SECONDS[])
                reload_library(state)
            catch e
                e isa InterruptException && rethrow()
                @error "Hot reload watch error: $e"
            end
        end

        @info "Hot reload: Stopped watching $(state.lib_name)"
    end
    published = lock(REGISTRY_LOCK) do
        state.enabled || return false
        running = state.watch_task
        running !== nothing && !istaskdone(running) && return false
        state.watch_task = task
        true
    end
    published || return nothing
    # Scheduling and waiting are outside STATE. A concurrent stop may already
    # be waiting on this task; its first enabled check then exits immediately.
    schedule(task)
    return task
end

_watch_is_enabled(state::HotReloadState) = lock(REGISTRY_LOCK) do
    state.enabled && HOT_RELOAD_ENABLED[]
end

"""
    SOURCE_SCANS

How many times a watcher has scanned a crate's sources (`check_for_changes`),
process-wide.

Diagnostic, and the way the "no polling loop when idle" criterion of #255 is
actually *checked*: an idle watcher must leave this number alone, however long
it waits. Before the timeout check in `_await_source_change`, `watch_folder`
returning "nothing happened" was treated as an event and every interval cost a
`stat` of every source file.
"""
const SOURCE_SCANS = Threads.Atomic{Int}(0)

"""
    source_scan_count() -> Int

The value of `SOURCE_SCANS`.
"""
source_scan_count() = SOURCE_SCANS[]

"""
    HOT_RELOAD_DEBOUNCE_SECONDS

How long to keep coalescing file events after the first one before rebuilding.

100 ms is long enough to swallow an editor's write-rename-touch sequence and a
multi-file save, and short enough to be invisible in a dev loop. The issue asks
for two saves within 200 ms to produce one reload, which this satisfies with
room to spare.
"""
const HOT_RELOAD_DEBOUNCE_SECONDS = _state_view(:hot_reload_debounce_seconds, Ref(0.1))

"""
    _await_source_change(state, timeout) -> Bool

Block until a `.rs` file under the crate changes, or `timeout` elapses.

This is the difference between an idle watcher costing nothing and one waking
up every second to `stat` every source file (#255). `FileWatching.watch_folder`
blocks in the kernel — inotify on Linux, kqueue on the BSDs, ReadDirectoryChanges
on Windows — so an idle watch task consumes no CPU at all.

The timeout is what lets the task notice `state.enabled` going false, and is
also the polling interval of the fallback: on a filesystem where the kernel
notification does not work (NFS, some container mounts), `poll = true` on
`start_watch_task` restores the old `stat`-based loop.

Returns whether something actually changed — a rename into place and a
temporary file both produce events, and only the mtime check decides.

# Every directory, not just `src/`

`watch_folder` is **not recursive** — inotify watches one directory — while
`find_rust_source_files` tracks the whole tree, `src/foo/mod.rs` included. When
a timeout still triggered a scan the difference was invisible: the poll caught
what the watch missed. Now that a timeout does nothing, watching only `src/`
would mean an edit to a nested module never reloads on Linux at all. So every
directory that contains a tracked source is watched, and the set is recomputed
each time — a reload can add files, and new files can be in new directories.
"""
function _await_source_change(state::HotReloadState, timeout::Real)
    dirs = _watched_directories(state)
    isempty(dirs) && return (sleep(timeout); check_for_changes(state))
    fired = _wait_for_file_event(dirs, timeout)
    # A timeout is **not** an event, and must not be answered with a scan.
    # Returning here is the difference between an event-driven watch and a
    # `stat` of every source file every `interval` — which is the polling loop
    # #255 exists to remove, and which an idle project would run forever.
    fired === false && return false
    return check_for_changes(state)
end

"""
    _watched_directories(state) -> Vector{String}

Every directory below `src/`, including empty nested directories, plus the
parents of tracked sources elsewhere. Recomputed per wait: directory creation
may precede the first source write and must establish that directory's watch.
"""
function _watched_directories(state::HotReloadState)
    dirs = Set{String}()
    src_dir = joinpath(state.crate_path, "src")
    if isdir(src_dir)
        for (directory, _, _) in walkdir(src_dir)
            push!(dirs, directory)
        end
    end
    for file in state.source_files
        parent = dirname(file)
        isdir(parent) && push!(dirs, parent)
    end
    return sort!(collect(dirs))
end

"""
    _wait_for_file_event(dirs, timeout) -> Union{Bool, Nothing}

Wait for a filesystem event in **any** of `dirs`. `true` when one fired,
`false` when the wait expired everywhere, `nothing` when the directories cannot
be watched at all (the caller then treats it as a poll and scans).

One task per directory, first one wins. The losers are released with
`unwatch_folder` rather than left holding a kernel watch until their own
timeout: a watch task that reloads every few seconds would otherwise
accumulate them.
"""
function _wait_for_file_event(dirs::Vector{String}, timeout::Real)
    if length(dirs) == 1
        event = try
            FileWatching.watch_folder(dirs[1], timeout)
        catch e
            e isa InterruptException && rethrow()
            # A filesystem the kernel will not watch: fall back to a poll
            # rather than spinning on the error.
            @debug "Hot reload: cannot watch $(dirs[1]); polling instead" exception = e
            sleep(timeout)
            return nothing
        end
        return !_watch_timed_out(event)
    end

    results = Channel{Union{Bool, Nothing}}(length(dirs))
    tasks = map(dirs) do dir
        Threads.@spawn begin
            answer = try
                event = FileWatching.watch_folder(dir, timeout)
                !_watch_timed_out(event)
            catch e
                e isa InterruptException && rethrow()
                @debug "Hot reload: cannot watch $(dir)" exception = e
                nothing
            end
            put!(results, answer)
        end
    end

    fired = false
    unwatchable = 0
    for _ in eachindex(dirs)
        answer = take!(results)
        answer === nothing && (unwatchable += 1; continue)
        if answer
            fired = true
            break
        end
    end
    # Release the rest; each `watch_folder` returns as its watch is dropped.
    for dir in dirs
        try
            FileWatching.unwatch_folder(dir)
        catch e
            @debug "Hot reload: could not unwatch $(dir)" exception = e
        end
    end
    for task in tasks
        try
            wait(task)
        catch e
            @debug "Hot reload: watch task failed" exception = e
        end
    end
    close(results)
    fired && return true
    # Nothing could be watched at all: the caller should poll instead of
    # believing that nothing changed.
    unwatchable == length(dirs) && return nothing
    return false
end

# `watch_folder` answers with `path => FileEvent`; the event says whether it
# fired or the wait expired. `nothing` is the poll fallback above, which does
# want a scan.
function _watch_timed_out(event)
    event === nothing && return false
    return try
        fired = last(event)
        hasproperty(fired, :timedout) ? fired.timedout : false
    catch
        false
    end
end

"""
    _drain_source_changes(state, window)

Keep absorbing file events for `window` seconds, so one burst of saves becomes
one rebuild.

An event seen inside the window restarts it, which is what makes a "save every
file in the project" refactor rebuild once at the end rather than once per
file — but only up to `MAX_DEBOUNCE_WINDOWS` extensions. Without that cap a
directory that produces events continuously (a build writing into it, a watch
API that hands back an already-queued event immediately) would keep the
debounce open forever and the reload would never happen.

Whatever arrives is folded into the mtime table, so the wait that follows
starts from a clean slate.
"""
function _drain_source_changes(state::HotReloadState, window::Real)
    window <= 0 && return nothing
    hard_deadline = time() + window * MAX_DEBOUNCE_WINDOWS
    deadline = time() + window
    while time() < deadline && time() < hard_deadline
        remaining = min(deadline, hard_deadline) - time()
        remaining <= 0 && break
        dirs = _watched_directories(state)
        # The wait expiring is the *end* of the burst, not another event:
        # treating it as one restarted the window every time, so a single save
        # waited out `MAX_DEBOUNCE_WINDOWS` instead of one window (#255).
        saw_event = false
        if isempty(dirs)
            sleep(min(remaining, 0.01))
        else
            answer = _wait_for_file_event(dirs, remaining)
            answer === nothing && sleep(min(remaining, 0.01))
            saw_event = answer === true
        end
        check_for_changes(state)
        saw_event && (deadline = time() + window)
    end
    return nothing
end

"""
    MAX_DEBOUNCE_WINDOWS

How many times a burst of file events may extend the debounce window before
the rebuild happens anyway.

The cap is what keeps "coalesce a burst" from becoming "never rebuild": some
platforms hand back an already-queued directory event immediately, so an
uncapped extension would spin. Ten windows is a tenth of a second times ten —
long enough for any editor's save sequence, short enough that a pathological
event source costs one second, not the session.
"""
const MAX_DEBOUNCE_WINDOWS = 10

"""
    stop_watch_task(state::HotReloadState)

Stop the file watching task for a crate.
"""
function stop_watch_task(state::HotReloadState)
    task = lock(REGISTRY_LOCK) do
        state.enabled = false
        state.watch_task
    end
    if task !== nothing && task !== current_task() && !istaskdone(task)
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

    lock(REGISTRY_LOCK) do
        state.watch_task === task && (state.watch_task = nothing)
    end
    return nothing
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
- `interval::Float64`: seconds; the timeout of each wait for a file event, or
  the polling period with `poll = true` (default: 1.0)
- `poll::Bool`: check modification times every `interval` instead of waiting on
  filesystem events, for filesystems that do not deliver them (default: false)
- `callback::Union{Function, Nothing}`: called after each rebuild attempt as
  `callback(lib_name, success, error)`
- `build_options`: the build a reload makes (`crate_build_options`; default:
  release, default features)

# Returns
- `HotReloadState`: The hot reload state for the crate

A reload rebuilds the crate (a `cdylib`) with `build_options` and swaps it in
under `lib_name`. The build environment, Cargo configuration and toolchain are
recorded when hot reload is enabled, and a reload under different ones is
refused. For an `@rust_crate` module, prefer
`enable_hot_reload_for_crate(module)`, which takes all of it from the module.

# Example
```julia
crate_path = "path/to/my_crate"         # a #[julia] crate with crate-type = ["cdylib"]
MyCrate = @rust_crate crate_path
lib_name = MyCrate._LIB_NAME             # the name @rust_crate loaded the library as

state = RustCall.enable_hot_reload(lib_name, crate_path; interval = 0.5)
# Edit the sources and the watcher rebuilds; or rebuild now:
RustCall.trigger_reload(lib_name)        # true once the new library is loaded

RustCall.disable_hot_reload(lib_name)
```
"""
function enable_hot_reload(lib_name::String, crate_path::String;
    interval::Float64 = 1.0,
    callback::Union{Function, Nothing} = nothing,
    poll::Bool = false,
    build_options::NamedTuple = crate_build_options()
)
    # Validate inputs
    if !isdir(crate_path)
        error("Crate path does not exist: $crate_path")
    end
    record = crate_build_record(crate_path, lib_name; build_options = build_options)
    return _enable_hot_reload(record; interval, callback, poll)
end

# Registers and starts watching the one state `record` describes. Every door
# ends here with a record; none of them passes a rebuild input any other way.
function _enable_hot_reload(record::CrateBuildRecord; interval::Float64 = 1.0,
                            callback::Union{Function, Nothing} = nothing,
                            poll::Bool = false)
    lib_name = record.lib_name
    crate_path = record.crate_dir

    # Check if already registered (protect HOT_RELOAD_REGISTRY with REGISTRY_LOCK)
    existing = lock(REGISTRY_LOCK) do
        entry = get(HOT_RELOAD_REGISTRY, lib_name, nothing)
        entry !== nothing && entry.enabled ? entry : nothing
    end
    if existing !== nothing
        @warn "Hot reload already enabled for $lib_name"
        return existing
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

    state = HotReloadState(record, "", source_files, last_modified, nothing, true,
                           callback, 0, "")

    # Register (protect HOT_RELOAD_REGISTRY with REGISTRY_LOCK)
    selected = lock(REGISTRY_LOCK) do
        entry = get(HOT_RELOAD_REGISTRY, lib_name, nothing)
        if entry !== nothing && entry.enabled
            entry
        else
            HOT_RELOAD_REGISTRY[lib_name] = state
            state
        end
    end
    selected === state || return selected

    # Start watching
    start_watch_task(state, interval=interval, poll=poll)

    return state
end

"""
    disable_hot_reload(lib_name::String)

Disable hot reload for a Rust crate.

# Arguments
- `lib_name::String`: Name of the library to disable hot reload for
"""
function disable_hot_reload(lib_name::String)
    state = get(HOT_RELOAD_REGISTRY, lib_name, nothing)

    if state === nothing
        @warn "Hot reload not enabled for $lib_name"
        return
    end

    stop_watch_task(state)

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
    enable_hot_reload_for_crate(mod::Module, crate_path = nothing; kwargs...) -> HotReloadState
    enable_hot_reload_for_crate(bindings::CrateBindings, crate_path = nothing; kwargs...) -> HotReloadState
    enable_hot_reload_for_crate(crate_path::String; release = true, features = String[],
                                default_features = true, lib_name = nothing, kwargs...) -> HotReloadState

Enable hot reload for a crate loaded via @rust_crate.

A reload publishes a new image under the module's registry name, so it has to
rebuild exactly the build the module was generated for. Every generated module
records that build as one immutable `CrateBuildRecord`, `_BUILD_RECORD`: the
crate directory, the registry name, the profile, the features, the kind of
build, the build environment (the allowlisted variables such as `RUSTFLAGS`),
the effective Cargo configuration and the toolchain. The module form — the value
`@rust_crate` returns, or the generated module itself, including one written by
`write_bindings_to_file` — reads that record once and rebuilds from it alone
(#474).

Arguments never supplement the record; they are compared with it. `crate_path`
may be omitted, and when given must name the recorded crate (compared by
`realpath`); `lib_name`, `release`, `features` and `default_features` may be
given and must equal the recorded ones. A mismatch is an `ArgumentError`, and so
is a current build environment, Cargo configuration or toolchain that differs
from the recorded one — at enable time, and again at every reload, where the
rebuild fails and the previous library stays loaded. A module without a record
(a file written by an older RustCall) is refused: regenerate it.

The path form is a thin constructor of the same record: it takes the build as
keywords — `release`, `features`, `default_features`, the `@rust_crate` options
of the same names — records the current environment, and computes the registry
name `@rust_crate` gives that build of the crate as it is now, so call it
before editing the sources; `lib_name` names the entry instead of computing it.
It does not guess: a crate loaded with other options is reached only when they
are passed.

Only a crate that is its own `cdylib` can be reloaded, and both forms check it
when hot reload is enabled: a module built through a generated wrapper crate,
or a crate whose `[lib]` has no `crate-type = ["cdylib"]`, is refused with an
`ArgumentError` rather than replaced by a build of the bare crate. Registering
under the module name, as before, reached nothing (#461).

# Keyword Arguments
- `release`, `features`, `default_features`, `lib_name`: the build (path form);
  compared with the record (module form)
- `interval`, `poll`, `callback`: as for `enable_hot_reload`

# Example
```julia
crate_path = "path/to/my_crate"         # a #[julia] crate with crate-type = ["cdylib"]
MyCrate = @rust_crate crate_path features=["simd"]

state = RustCall.enable_hot_reload_for_crate(MyCrate;   # crate_path and features=["simd"] kept
    callback = (lib_name, success, error) -> @info "reloaded" lib_name success)
# Edit the sources and the watcher rebuilds; or rebuild now:
RustCall.trigger_reload(state.lib_name)  # true once the new library is loaded

RustCall.disable_hot_reload(state.lib_name)
```
"""
function enable_hot_reload_for_crate(crate_path::String;
                                     release::Bool = true,
                                     features::Vector{String} = String[],
                                     default_features::Bool = true,
                                     lib_name::Union{Nothing, AbstractString} = nothing,
                                     interval::Float64 = 1.0,
                                     callback::Union{Function, Nothing} = nothing,
                                     poll::Bool = false)
    # The crate must be its own `cdylib` before anything else is computed:
    # the name below scans the crate, and a crate a reload cannot rebuild is
    # refused now rather than at the first save (#474).
    _check_reloadable_crate(crate_path, :direct)
    options = crate_build_options(release = release, features = features,
                                  default_features = default_features, kind = :direct)
    name = lib_name === nothing ? _crate_hot_reload_name(crate_path, options) : String(lib_name)
    record = crate_build_record(crate_path, name; build_options = options)
    return _enable_crate_hot_reload(record; interval, callback, poll)
end

enable_hot_reload_for_crate(bindings::CrateBindings,
                            crate_path::Union{Nothing, AbstractString} = nothing; kwargs...) =
    enable_hot_reload_for_crate(getfield(bindings, :module_ref), crate_path; kwargs...)

function enable_hot_reload_for_crate(mod::Module,
                                     crate_path::Union{Nothing, AbstractString} = nothing;
                                     lib_name::Union{Nothing, AbstractString} = nothing,
                                     release::Union{Nothing, Bool} = nothing,
                                     features::Union{Nothing, AbstractVector{<:AbstractString}} = nothing,
                                     default_features::Union{Nothing, Bool} = nothing,
                                     interval::Float64 = 1.0,
                                     callback::Union{Function, Nothing} = nothing,
                                     poll::Bool = false)
    record = module_build_record(mod)
    _check_record_arguments(record, mod; crate_path, lib_name, release, features,
                            default_features)
    return _enable_crate_hot_reload(record; interval, callback, poll)
end

"""
    module_build_record(mod::Module) -> CrateBuildRecord

The `_BUILD_RECORD` a generated `@rust_crate` module holds: every input of the
build its library is. An `ArgumentError` for a module that is not generated by
`@rust_crate`, or that predates the record (a file written by an older
RustCall, which records no build).
"""
function module_build_record(mod::Module)
    # The module may have been defined in a newer world than this call.
    has(name) = Base.invokelatest(isdefined, mod, name)
    if has(:_BUILD_RECORD)
        record = Base.invokelatest(getglobal, mod, :_BUILD_RECORD)
        record isa CrateBuildRecord && return record
    end
    has(:_LIB_NAME) || throw(ArgumentError(
        "$(mod) is not a module generated by `@rust_crate`: it has no `_BUILD_RECORD`."))
    throw(ArgumentError(
        "$(mod) does not record the build it was made from (`_BUILD_RECORD`): it was " *
        "generated by an older RustCall. Regenerate it, or use " *
        "`enable_hot_reload_for_crate(crate_path; lib_name, release, features, " *
        "default_features)` with the options it was built with."))
end

# Every argument the caller gave, compared with the record; none of them is
# used. A reload publishes under the record's registry name, so a different
# crate, name or build would put another library behind the module's wrappers
# (#461 review, #474).
function _check_record_arguments(record::CrateBuildRecord, mod;
                                 crate_path = nothing, lib_name = nothing,
                                 release = nothing, features = nothing,
                                 default_features = nothing)
    if crate_path !== nothing
        # Compared by `realpath`, so a relative or symlinked spelling of the
        # same directory is the same crate.
        canonical(p) = ispath(p) ? realpath(p) : abspath(p)
        canonical(String(crate_path)) == canonical(record.crate_dir) || throw(ArgumentError(
            "$(mod) was generated from the crate at $(record.crate_dir), not " *
            "$(abspath(String(crate_path))). A reload publishes under the module's registry " *
            "name, so it must rebuild that crate; omit `crate_path`, or load the other " *
            "crate with `@rust_crate`."))
    end
    mismatch(what, given, recorded) = throw(ArgumentError(
        "$(mod) was built with $(what) = $(repr(recorded)), not $(repr(given)). A reload " *
        "rebuilds the module's own build; omit `$(what)`, or load the crate again with " *
        "`@rust_crate` under the build you want."))
    lib_name === nothing || String(lib_name) == record.lib_name ||
        mismatch("lib_name", String(lib_name), record.lib_name)
    release === nothing || release == record.release ||
        mismatch("release", release, record.release)
    features === nothing || sort!(collect(String, features)) == sort!(collect(record.features)) ||
        mismatch("features", collect(String, features), collect(record.features))
    default_features === nothing || default_features == record.default_features ||
        mismatch("default_features", default_features, record.default_features)
    return nothing
end

# Whether a reload can rebuild the crate at `crate_path` as a build of `kind`:
# it has a manifest, the build is `:direct` and the manifest still declares a
# `cdylib`. Checked when hot reload is enabled, by both forms (#474).
function _check_reloadable_crate(crate_path::AbstractString, kind::Symbol)
    path = String(crate_path)
    isfile(joinpath(path, "Cargo.toml")) || error("Cargo.toml not found in: $path")
    kind === :direct || throw(ArgumentError(
        "Hot reload rebuilds a crate as its own `cdylib`; $(path) was bound " *
        "through a generated `$(kind)` crate, which a reload cannot reproduce. " *
        "Add `crate-type = [\"cdylib\"]` to its `[lib]` section and load it again."))
    crate_has_cdylib(path) || throw(ArgumentError(
        "Hot reload rebuilds a crate as its own `cdylib`, and $(path) is not one: add " *
        "`crate-type = [\"cdylib\"]` to its `[lib]` section. A crate without it is bound " *
        "through a generated wrapper crate, which a reload cannot reproduce."))
    return nothing
end

function _enable_crate_hot_reload(record::CrateBuildRecord; kwargs...)
    _check_reloadable_crate(record.crate_dir, record.kind)
    changed = _build_record_mismatch(record)
    isempty(changed) ||
        throw(ArgumentError(_build_env_mismatch_message(record.lib_name, changed)))
    haskey(RUST_LIBRARIES, record.lib_name) ||
        @warn "Hot reload: no library is loaded as $(record.lib_name) yet. `@rust_crate` " *
              "registers a crate under a name keyed by its content and build options; if " *
              "it was loaded with other options, or its sources changed since, pass the " *
              "module (`enable_hot_reload_for_crate(mod)`) or `lib_name`."
    return _enable_hot_reload(record; kwargs...)
end

# The registry name `@rust_crate` gives a plain build of `crate_path` with
# `options`: the name `generate_bindings` computes, from the same scan and the
# same environment snapshot.
function _crate_hot_reload_name(crate_path::AbstractString,
                                options::NamedTuple = crate_build_options())
    path = abspath(String(crate_path))
    features = collect(String, options.features)
    info = _plain_scan_info(path, scan_crate(path), features, options.default_features,
                            options.release)
    return crate_library_name(info; release = options.release, features = features,
                              default_features = options.default_features,
                              build_env = _plain_crate_build_env())
end
