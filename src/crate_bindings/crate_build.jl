# ============================================================================
# Main API
# ============================================================================

"""
    _uncached_library_home(built) -> String

A copy of `built` in a directory that outlives the process that made it, for
a build that is not entered into the cache (`cache = false`, or a cache write
that failed).

Not `mktempdir()`: that cleans up at process exit, and the process that
generates a module is not always the one that loads it. A package precompiled
with `cache = false` records this path as its `_LIB_PATH`; the precompile
worker then exits, the directory goes with it, and the session that triggered
the precompilation loads an image whose library is already gone (#339
review). The copy lives under the Cargo cache directory instead, under a name
the cache lookup never returns, so `RustCall.clear_cache()` is what removes
it.
"""
function _uncached_library_home(built::AbstractString)
    home = mktempdir(get_cargo_cache_dir(); prefix = "uncached_", cleanup = false)
    kept = joinpath(home, basename(built))
    cp(built, kept; force = true)
    return kept
end

"""
    _cache_built_library(cache_key, built, cache_enabled) -> String

The path a generated module should name for a library that was just built:
the cache copy when caching is on, and `built` itself when it is off or the
cache could not be written.

Caching is what makes the path *durable*. `built` is either Cargo's output
under `crate_target_directory(crate)` — rewritten by the next build of the crate —
or a file inside a wrapper project that is about to be deleted; the cache copy
is neither, which is what a module compiled into a package's precompile image
needs when its `__init__` runs in a later session (#339).

Returning `built` unchanged is the caller's signal that nothing was copied, so
a caller whose `built` is about to disappear can keep a copy of its own.
"""
function _cache_built_library(cache_key::String, built::String, cache_enabled::Bool)
    cache_enabled || return built
    try
        save_cargo_cached_library(cache_key, built)
        cached = get_cargo_cached_library(cache_key)
        cached === nothing || return cached
    catch e
        @debug "Failed to cache library: $e"
    end
    return built
end

"""
    _plain_crate_build_env() -> Vector{Pair{String, String}}

The environment a **plain** `@rust_crate` build (no PyO3 wrapper) is keyed by:
`artifact_build_env()` — the #282 allowlist, `PYO3_*` included by prefix — plus
the *contents* of `PYO3_CONFIG_FILE` when it is set. The allowlist records that
variable's value, which is a path; a crate that depends on pyo3 and takes this
path (a `cdylib` exposing `#[julia]` items, say) reads the file itself at build
time, so an edit to it — another Python version, ABI or library directory — is
a different binary under the same path. The wrapper path already hashes the
contents (`_pyo3_wrapper_build_env`); without this the plain key did not, and
`get_cargo_cached_library` answered the edited configuration with the old
library (#339 review).

**Neither depends on the dependency graph**, deliberately. Cargo hands every
ambient variable to every build script, and a crate's own `build.rs` may read
`PYO3_PYTHON`, or open the file `PYO3_CONFIG_FILE` names, without depending on
pyo3 — which crates are in the graph proves nothing about what a script reads.
So the value is an input of every build (the #282 contract) and so are the
contents of the file it names, as `.cargo/config.toml`'s are: the price is a
spare rebuild when Python is configured for another package while this
variable is set and its file edited, and the alternative — a gate on pyo3
being in the graph — was a stale library for the crate that read the file
anyway (#339 review; an earlier round of this PR tried the gate and reverted
it).
"""
_plain_crate_build_env() = _plain_crate_build_env(BuildEnvSnapshot())

function _plain_crate_build_env(snapshot::BuildEnvSnapshot)
    build_env = artifact_build_env(; env = snapshot_env(snapshot))
    digest = _pyo3_config_file_digest(snapshot)
    isempty(digest) || push!(build_env, "pyo3-config-file-digest" => digest)
    # And the interpreter pyo3's build script would configure the library for
    # — under the names the wrapper's identity uses for its own
    # (`_pyo3_wrapper_build_env`), since it is the same fact about the same
    # Python. Empty, and absent, when pyo3's configuration names the library
    # directory and no interpreter is consulted (#339 review).
    interpreter, fingerprint = _pyo3_build_interpreter(snapshot)
    if !isempty(interpreter)
        push!(build_env, "rustcall-pyo3-python" => interpreter)
        push!(build_env, "rustcall-pyo3-python-config" => fingerprint)
    end
    return build_env
end

"""
    generate_bindings(crate_path::String; kwargs...) -> Expr

Generate Julia bindings for an external Rust crate.

This is the main entry point for the Maturin-like feature. It scans the crate,
creates a wrapper crate if needed, builds it, and generates Julia bindings.

# Arguments
- `crate_path::String`: Path to the Rust crate root directory

# Keyword Arguments
- `output_module_name::Union{String, Nothing}`: Name for the generated module
- `build_release::Bool`: Build in release mode (default: true)
- `cache_enabled::Bool`: Enable caching (default: true)

# Returns
- `Expr`: A module expression containing all bindings

# Example
```julia
bindings = generate_bindings("/path/to/my_crate")
eval(bindings)
# The generated bindings are now available
MyCrate.add(Int32(1), Int32(2))
```
"""
function generate_bindings(crate_path::String;
    output_module_name::Union{String, Nothing} = nothing,
    build_release::Bool = true,
    cache_enabled::Bool = true,
    features::Vector{String} = String[],
    default_features::Bool = true,
    pyo3_host::Bool = false
)
    # The Python-host path (#424) is a different binding strategy, not a patch to
    # the C-ABI one: build the crate as the extension it is and call the imported
    # module. It needs a Python implementation, which RustCall does not depend
    # on, so it is refused with the fix named rather than a `MethodError` deep in
    # generated code.
    if pyo3_host
        pyo3_host_available() || throw(RustError(
            "`pyo3_host = true` needs a Python implementation to import the crate " *
            "into. Load PythonCall (`using PythonCall`) to enable the " *
            "`RustCallPyO3HostExt` extension, which provides it."))
        return generate_pyo3_host_bindings(crate_path;
                                           module_name = output_module_name,
                                           features = features,
                                           default_features = default_features,
                                           release = build_release)
    end

    # ONE snapshot of the environment for the whole build (#481): the PyO3
    # plan and its probes, the cfg probe, the cache key, the registry name, the
    # Cargo build, the interpreter check and the module's record all read it,
    # and nothing below reads `ENV` again. A task changing `ENV` meanwhile
    # cannot make them describe different builds.
    snapshot = BuildEnvSnapshot()

    opts = CrateBindingOptions(
        output_module_name = output_module_name,
        build_release = build_release,
        cache_enabled = cache_enabled,
        features = features,
        default_features = default_features
    )

    # Scan the crate
    @info "Scanning crate at $crate_path"
    info = scan_crate(crate_path; cargo_env = snapshot_env(snapshot))
    @info "Found $(length(info.julia_functions)) functions and $(length(info.julia_structs)) structs"

    # A crate that carries only PyO3 attributes gets a generated wrapper crate
    # (#275 Phase 2); everything else — including a PyO3 crate whose requested
    # build exposes nothing to Python — takes the pre-#275 path, under the
    # configuration *that* build compiles with (`_plain_scan_info`, which
    # probes with the shape of the build: the crate as its own root when it is
    # built as one, as a wrapper's dependency otherwise; #307 review).
    if crate_needs_pyo3_wrapper(info)
        plan = pyo3_link_plan(crate_path; features = features,
                              default_features = default_features, release = build_release,
                              snapshot = snapshot)
        # The module's record, from the snapshot and this plan — the values
        # the wrapper's key is computed from — taken once, here, never again
        # after the build (#485 review).
        wrapper_record = pyo3_wrapper_build_record(crate_path, plan, snapshot;
                                                   release = build_release, features = features,
                                                   default_features = default_features)
        wrapper = build_pyo3_wrapper(info; features = features,
                                     default_features = default_features,
                                     release = build_release, cache_enabled = cache_enabled,
                                     plan = plan, snapshot = snapshot)
        if wrapper === nothing
            # Under this build's own configuration the crate exposes nothing to
            # PyO3 (every marker is behind a feature that is off), so there is
            # nothing to wrap and the pre-#275 path applies — under that same
            # configuration: the lenient scan lists every feature variant of a
            # `#[julia]` item, the resolved one says which this build compiles
            # (#307 review).
            @info "No PyO3 item is exposed by this build; binding the crate as before"
        else
            @info "Wrapped $(length(wrapper.info.julia_functions)) functions and " *
                  "$(length(wrapper.info.julia_structs)) types ($(wrapper.plan.mode))"
            # `wrapper.lib_path` is the cache copy (or, with caching off, a copy
            # of Cargo's output); the module copies it per process in
            # `__init__`.
            # Python is an input of this module only when the wrapper links
            # libpython. A `:python_free` build has pyo3 out of the graph and
            # consults no interpreter, so recording one would warn on a
            # routine `PATH` change and tracking `python3-config` would
            # rebuild for nothing (#339 review).
            links_python = wrapper.plan.mode === :link_libpython
            python_inputs = if links_python
                String[wrapper.plan.interpreter;
                       _python_resolved(snapshot, wrapper.plan.interpreter);
                       wrapper.plan.runtime_libraries;
                       (_python_config_consulted(snapshot) ?
                        last.(_python_config_selections(snapshot)) : String[])]
            else
                String[]
            end
            return emit_crate_module(wrapper.info, wrapper.lib_path;
                                     module_name = output_module_name,
                                     build_release = build_release,
                                     lib_name = wrapper.lib_name,
                                     preload = wrapper.plan.runtime_libraries,
                                     extra_inputs = unique(vcat(python_inputs,
                                                                 _expand_precompile_inputs(plan.build_inputs),
                                                                 wrapper.source.source_files,
                                                                 dirname.(wrapper.source.source_files))),
                                     python = links_python,
                                     pin_library = any(_python_owned_handle,
                                                       wrapper.info.julia_structs),
                                     build_options = record_build_options(wrapper_record),
                                     build_record = _record_named(wrapper_record,
                                                                  wrapper.lib_name),
                                     snapshot = snapshot)
        end
    end
    # The record of the build, from the snapshot, for everything below — the
    # cfg probe, the cache key, the registry name, the build and the module's
    # record (#474 review, #481). Named once the name, which it decides, is
    # known.
    plain_kind = crate_has_cdylib(crate_path) ? :direct : :wrapper
    record = crate_build_record(crate_path, "";
        build_options = crate_build_options(release = build_release, features = features,
                                            default_features = default_features,
                                            kind = plain_kind),
        snapshot = snapshot)
    build_env = _record_build_subprocess_env(record, snapshot)
    info = _plain_scan_info(crate_path, info, features, default_features, build_release;
                            env = build_env)

    # Check cache. The feature set is part of the identity on this path too:
    # a build the caller asked for with `features` / `default_features` is
    # not the default build, and must neither answer its lookup nor be built
    # as it (#307 review).
    # `artifact_build_env()` is in the key here as it already is for a PyO3
    # wrapper build (`_pyo3_wrapper_build_env`): `RUSTFLAGS`, a build script's
    # `CC`, and the rest of the #282 allowlist decide what `cargo build`
    # produces, so two builds under different values are different binaries and
    # must not share an entry. Without it a changed environment found the
    # previous library in the cache and handed it back — which also made the
    # load-time warning's advice wrong, since re-precompiling the package
    # rebuilt the bindings around the same stale artifact (#339 review).
    build_env_snapshot = _plain_crate_build_env(record)
    cache_key = compute_crate_hash(info; release = build_release,
                                   features = features, default_features = default_features,
                                   build_env = build_env_snapshot, snapshot = snapshot)
    cached_lib = cache_enabled ? get_cargo_cached_library(cache_key) : nothing

    lib_path = if cached_lib !== nothing && isfile(cached_lib)
        @info "Using cached library"
        cached_lib
    else
        # Check if the crate already has cdylib crate-type
        if crate_has_cdylib(crate_path)
            # Build the crate directly
            @info "Building crate directly (already has cdylib crate-type)..."
            built = build_crate_directly(info, build_release;
                                         features = features,
                                         default_features = default_features,
                                         env = build_env)
            # Before anything is cached: the interpreter pyo3 was configured
            # for is still the one the key and the record name (#481).
            _verify_build_interpreter(record, snapshot)
            # Cargo's own output under `crate_target_directory`: durable, but the
            # next `cargo build` of the crate rewrites it, so with caching on
            # the module names the cache copy instead — which is what a module
            # precompiled into a package needs when its `__init__` runs in a
            # later session (#339).
            _cache_built_library(cache_key, built, cache_enabled)
        else
            # Create wrapper crate and build
            @info "Creating wrapper crate..."
            wrapper_path = create_wrapper_crate(info, opts)

            @info "Building wrapper crate..."
            wrapper_project = CargoProject(
                "$(info.name)_julia_wrapper",
                "0.1.0",
                DependencySpec[],  # Dependencies are in Cargo.toml
                "2021",
                wrapper_path
            )

            try
                built = build_cargo_project(wrapper_project, release=build_release,
                                            policy=crate_wrapper_policy(), env=build_env)
                _verify_build_interpreter(record, snapshot)
                # The library must leave the wrapper project *here*: the
                # `finally` below removes the whole project, the build output
                # included, so anything that names a path inside it afterwards
                # — the cache write, the module's `_LIB_PATH`, the per-process
                # copy `__init__` makes — is naming a file that no longer
                # exists. With caching on that is the cache copy; with
                # `cache = false` it is a copy in a directory of its own, as
                # `_build_pyo3_wrapper_project` already does for the PyO3
                # wrapper. Before this, `@rust_crate <crate> cache=false` on a
                # crate that needs a wrapper failed to open its own library.
                kept = _cache_built_library(cache_key, built, cache_enabled)
                if kept == built
                    kept = _uncached_library_home(built)
                end
                kept
            finally
                cleanup_cargo_project(wrapper_project)
            end
        end
    end

    # RustCall never maps the file Cargo writes: a later build of the same
    # crate rewrites its output in place, which on Windows *fails* against a
    # mapped DLL (`Access is denied`) and elsewhere silently hands the old
    # image back to the next `dlopen`. The module's `__init__` opens a private
    # generation copy of `_LIB_PATH` (#255, #277) — in `__init__`, not here,
    # because that copy belongs to the process that loads the module, which
    # after precompilation is not the one that generated it (#339).

    # Generate module. The registry name follows the key, feature set
    # included, so two feature sets of one crate are two entries.
    @info "Generating Julia module..."
    # The **same** snapshot decides the registry name as decides the cache key.
    # Passing it to one and not the other gave two builds under different
    # environments distinct artifacts under one `_LIB_NAME`: loading the second
    # replaced the entry and re-pointed the first module's mirror at it, so its
    # wrappers called the other build — a wrong ABI or a missing symbol where
    # the environment changed the cfg-selected exports (#339 review).
    lib_name = crate_library_name(info; release = build_release, features = features,
                                  default_features = default_features,
                                  build_env = build_env_snapshot, snapshot = snapshot)
    return emit_crate_module(info, lib_path; module_name=output_module_name,
                             build_release=build_release, lib_name=lib_name,
                             build_record = _record_named(record, lib_name),
                             snapshot = snapshot)
end

"""
    _plain_scan_info(crate_path, info, features, default_features, release) -> CrateInfo

The scan the plain (`#[julia]`) path emits bindings from: `info` rescanned under
the configuration the crate is **built** with — `rustc --print cfg` of the crate
as its own Cargo root, under the requested profile and feature flags
(`_crate_build_cfg_text`) — so every `#[cfg]` is decided the way the build
decides it.

The lenient scan lists every feature variant of an item; the build has exactly
one of them. Emitting the lenient list produced a module that named symbols the
library does not export (a `#[cfg(feature = "x")] #[julia] fn` with `x` off),
or the wrong one of two mutually exclusive signatures, and the mismatch
surfaced as a `dlsym` failure on the first call. Hot reload has always
rescanned this way after a rebuild (`_scan_crate_signatures`); the first load now
does too, and the feature set a caller asks for (`features`,
`default_features`) is what the probe runs under, as it is what the build
runs under (#307 review; #277 Phase B).

The probe has the shape of the build. A crate with a `cdylib` target is built
**as the Cargo root** (`build_crate_directly`), so it is probed as one and its
own `[profile.*]` applies. Any other crate is built as the dependency of a
generated `_julia_wrapper` root, whose profile — RustCall's, `panic = "unwind"`
pinned — replaces the crate's own; such a crate is probed as a wrapper's
dependency (`_wrapper_probe_cfg_text`), so a `#[cfg(debug_assertions)]` item
under a crate-level `debug-assertions = true` is scanned the way the build
compiles it: out (#307 review).

`info` is returned unchanged when Cargo will not answer (no cargo, an
unresolvable crate); the build then fails on its own terms.
"""
function _plain_scan_info(crate_path::AbstractString, info::CrateInfo,
                          features::Vector{String}, default_features::Bool, release::Bool;
                          env::Union{Nothing, AbstractDict} = nothing)
    path = String(crate_path)
    cfg_text = if crate_has_cdylib(path)
        # Under the environment the build runs under, when the caller has one
        # (`_record_build_subprocess_env`).
        _crate_build_cfg_text(path; profile = release ? "release" : "debug",
                              features = _cargo_feature_args(features, default_features),
                              env = env)
    else
        # Under the build's environment too: the wrapper root is probed as it
        # is built (#481).
        env === nothing ?
            _wrapper_probe_cfg_text(path; features = features,
                                    default_features = default_features, release = release) :
            _wrapper_probe_cfg_text(path, env; features = features,
                                    default_features = default_features, release = release)
    end
    isempty(cfg_text) && return info
    return scan_crate(path; cfg = :cargo, cfg_text = cfg_text, cargo_env = env)
end

"""
    crate_has_cdylib(crate_path::String) -> Bool

Check if the crate has cdylib in its crate-type.
"""
function crate_has_cdylib(crate_path::String)
    cargo_toml_path = joinpath(crate_path, "Cargo.toml")
    if !isfile(cargo_toml_path)
        return false
    end

    cargo_toml = parse_cargo_toml(cargo_toml_path)
    lib_section = get(cargo_toml, "lib", Dict())
    crate_types = get(lib_section, "crate-type", String[])

    return "cdylib" in crate_types
end

"""
    build_crate_directly(info::CrateInfo, release::Bool) -> String

Build the crate directly using cargo and return the path to the library.
"""
function build_crate_directly(info::CrateInfo, release::Bool;
                              features::Vector{String} = String[],
                              default_features::Bool = true,
                              env::Union{Nothing, AbstractDict} = nothing)
    # Create a CargoProject that points to the original crate
    project = CargoProject(
        info.name,
        info.version,
        info.dependencies,
        "2021",
        info.path
    )

    # The Cargo root here is the *user's* manifest, so the policy pins nothing
    # and their profile decides (`crate_direct_policy`, #244). The feature set
    # is the caller's, exactly as a wrapper build's is (#307 review).
    # Built from the crate's directory against its own `Cargo.lock`, but with
    # the output under RustCall's cache, never the crate's `target/` (#445).
    build_cargo_project(project, release=release, policy=crate_direct_policy(),
                        features=features, default_features=default_features, env=env,
                        target_directory=_crate_target!(info.path))
end

"""
    BINDINGS_FORMAT_VERSION

Format marker carried by every file `write_bindings_to_file` emits
(`# Bindings format: <MAJOR.MINOR>`), and the value the file's
`const _BINDINGS_FORMAT = RustCall.check_bindings_format("<MAJOR.MINOR>")`
hands back to the RustCall that loads it.

Since v0.7 (#489) it is **the `MAJOR.MINOR` of this release**, read from
`Project.toml` when the package is loaded — `RELEASE_FORMAT_IDENTIFIER`, the
same value as `MANIFEST_SCHEMA_VERSION` — never a number of its own. A file is
compatible with the RustCall that loads it when the two name the same
`MAJOR.MINOR`: a patch release never changes the format, so a file written by
v0.7.0 loads under v0.7.3; a different minor or major is refused, at `include`
and again in `__init__`, with a message saying to regenerate the file with
`RustCall.write_bindings_to_file` (`check_bindings_format`). A bindings-format
change may therefore ship only in a minor or major release.

Through v0.6.x the format was an integer bumped on every incompatible edit, and
those files are **not** readable any more: they define no `_BINDINGS_FORMAT`, and
`register_handle_mirror!`, which every such `__init__` calls, refuses the module
with the same message. What each integer introduced:

- `2` (#277 Phase B5): the file loads its library through
  `RustCall.load_artifact!` rather than `Libdl.dlopen`, so the handle is
  registered and `unload_library` can see it, and its struct finalizers capture
  a destructor pointer and the library's liveness flag instead of resolving the
  destructor when they run.
- `3` (#246): string arguments are built with `RustCall.ffi_string_argument`,
  which the file imports, so invalid UTF-8 raises instead of being substituted.
  That name does not exist in an older RustCall, so a file emitted here does
  not load against one — the direction the marker is really for.
- `4` (#245): the emitted `CResult_<fn>` / `COption_<fn>` mirrors subtype
  `RustCall.FFIByValue`, which the file imports. That name does not exist in an
  older RustCall, so a file emitted here does not load against one — the
  direction the marker is really for.

- `5` (#268): a method returning `Result<T, E>` / `Option<T>` emits a
  `CResult_<Struct>_<method>` / `COption_<Struct>_<method>` mirror and decodes
  it with `RustCall._result_payload`, which the file imports and which does not
  exist in an older RustCall. The same import carries the release of an owned
  `String` payload, so a file emitted here must not be loaded against a
  RustCall that would leak it.
- `6` (#309): `__init__` opens a private generation copy of the library
  (`RustCall.loadable_library_copy`, #289) rather than mapping `_LIB_PATH` —
  Cargo's output, or the copy `write_bindings_to_file` made — in place. A
  mapped image cannot be overwritten on Windows, so a module emitted before
  this made the crate unbuildable (and the file unregenerable) for the rest
  of the session. The name does not exist in a RustCall older than #289.
- `7` (#300): every symbol the file names is module-qualified (`a__C_free`,
  `rustcall_a__run`), and items inside Rust modules live in Julia submodules
  (`bindings.a.run`). A file emitted before this names symbols a library
  built with the current proc-macro no longer exports for any item inside a
  module.
- `8` (#303): generated calls support defaulted PyO3 arities and Python-owned
  class handles.
- `9` (#303): generated modules pin wrapper images containing Python-owned
  handles and give those objects a process-lifetime finalizer flag.
- `10` (#371): the pin/finalizer decision comes from the wrapper manifest's
  authoritative `python_owned_handle` field, so filtering the method that
  selected that handle cannot silently remove the lifetime policy.
- `11` (#253): every call site keeps the snapshot it resolved in a
  `RustCall.CrateTargetCache` of its own, declared beside the wrapper, and the
  target helpers take that cache as their first argument. The name does not
  exist in an older RustCall, so a file emitted here does not load against one
  — the direction the marker is really for.
- `12` (#460): a callback argument's pointer is
  `@cfunction(RustCall.CallbackSlot{k, R}(), ...)`, a slot that knows its
  return type and so hands Rust a zero of it — never raises through Rust —
  when invoked with no call in progress. The name does not exist in an older
  RustCall. Owned-buffer returns are guarded with the four-argument
  `_guard_panic(value, channel, name, free_ptr)`, which calls a
  `RustCall.guard_rust_panic_ptr` method an older RustCall does not have, so a
  buffer returned by a call whose callback threw is released instead of leaked.
- `13` (#474): the file records every input of its build — crate, registry
  name, profile, features, kind, build environment, Cargo configuration,
  toolchain — as one `RustCall.CrateBuildRecord` (`_BUILD_RECORD`), which is
  what a hot reload rebuilds from, and reads `_LIB_NAME` from it. The name does
  not exist in an older RustCall. Its `__init__` also checks the recorded
  build environment before loading, as the in-memory module does.
"""
const BINDINGS_FORMAT_VERSION = RELEASE_FORMAT_IDENTIFIER

"""
    bindings_format_compatible(marker) -> Bool

Whether a bindings file marked `marker` is readable by this RustCall: the marker
parses as a `VersionNumber` whose `MAJOR.MINOR` equals `BINDINGS_FORMAT_VERSION`'s
(a patch component, if any, may differ). An integer — the scheme of v0.6.x and
earlier — `nothing` (no marker) or anything that is not a version is not.
"""
function bindings_format_compatible(marker)
    v = _bindings_format_version(marker)
    v === nothing && return false
    current = VersionNumber(BINDINGS_FORMAT_VERSION)
    return v.major == current.major && v.minor == current.minor
end

# The marker as a version, or `nothing` when it is not one of the semver form:
# an `Integer`, or a string of digits alone, is the retired integer scheme.
function _bindings_format_version(marker)
    marker isa AbstractString || return nothing
    text = strip(marker)
    occursin(r"^\d+\.\d+(\.\d+)?$", text) || return nothing
    return tryparse(VersionNumber, text)
end

function _bindings_format_message(marker)
    origin = if marker === nothing
        "carries no bindings-format marker: it was written by RustCall v0.6.x or " *
        "earlier, whose integer format (13 and below) is no longer readable"
    elseif marker isa Integer || (marker isa AbstractString && occursin(r"^\s*\d+\s*$", marker))
        "is bindings format $(strip(string(marker))), the integer scheme of " *
        "RustCall v0.6.x and earlier, which is no longer readable"
    else
        "is bindings format $(repr(marker))"
    end
    return "This bindings module $(origin). This RustCall.jl " *
           "(v$(pkgversion(@__MODULE__))) reads bindings format " *
           "$(BINDINGS_FORMAT_VERSION) — the MAJOR.MINOR of its release; a file is " *
           "readable only by a RustCall of the same MAJOR.MINOR. Regenerate the file " *
           "with `RustCall.write_bindings_to_file(crate_dir, output_path)` (its " *
           "header names the crate)."
end

"""
    check_bindings_format(marker) -> String

Return `marker` when a bindings file carrying it is readable by this RustCall
(`bindings_format_compatible`), and otherwise raise a `RustError` saying to
regenerate the file with `write_bindings_to_file`. Every generated crate module
calls it at its top level (`const _BINDINGS_FORMAT = ...`), so an incompatible
file is refused when it is included, before anything else in it runs (#489).
"""
function check_bindings_format(marker)
    bindings_format_compatible(marker) || throw(RustError(_bindings_format_message(marker)))
    return String(strip(marker))
end

# The format a generated module declared, checked again when its `__init__`
# registers its generation mirror — the one call every crate module since #402
# makes, so an older file, which declares none, is refused here (#489).
function _check_module_bindings_format(mod::Module)
    marker = Base.invokelatest(isdefined, mod, :_BINDINGS_FORMAT) ?
        Base.invokelatest(getglobal, mod, :_BINDINGS_FORMAT) : nothing
    check_bindings_format(marker)
    return nothing
end

"""
    crate_library_name(info::CrateInfo; release = true) -> String

The `RUST_LIBRARIES` key a `@rust_crate` library is registered under:
`rust_crate_<crate name>_<short id of the crate identity for that profile>`.

The **profile is part of the name**, exactly as it is part of the cache key
(`compute_crate_hash(info; release)`). A debug and a release build of one crate
are two different binaries, and giving them one registry name made them clobber
each other: the second `@rust_crate` replaced the first\'s entry, retired its
liveness flag out from under objects that were still alive, and pointed its
module mirror at the other profile\'s image.

`@rust_crate` used to keep its handle only in a module-local `Ref`, so
`unload_library`, `unload_all_libraries` and every registry the rest of
RustCall keeps were blind to it (#250). Registering it means the same
transaction that publishes the handle also publishes the liveness flag its
objects capture, and unloading it retires them (#277 Phase B5).

Keyed by the crate identity so two crates — or one crate rebuilt under a
different toolchain — do not collide on one entry.
"""
crate_library_name(info::CrateInfo; release::Bool = true, kind::AbstractString = "crate",
                   features::Vector{String} = String[], default_features::Bool = true,
                   build_env::Vector{Pair{String, String}} = Pair{String, String}[],
                   snapshot::BuildEnvSnapshot = BuildEnvSnapshot()) =
    _crate_library_label(info, compute_crate_hash(info; release = release, kind = kind,
                                                  features = features,
                                                  default_features = default_features,
                                                  build_env = build_env, snapshot = snapshot))

# A registry name, never a location: the library itself is cached under the
# full key (#278, #504).
_crate_library_label(info::CrateInfo, key::AbstractString) =
    "rust_crate_$(info.name)_$(artifact_short_id(key))" # short-id: label

"""
    compute_crate_hash(info::CrateInfo) -> String

Identity of an external crate build: `artifact_key` of an `ArtifactId`, so the
`@rust_crate` path answers "which artifact is this?" with the same function as
every other path (#278).

What it covers, and what the previous formula missed:

- **the whole crate directory**, through `crate_content_digest`, not only the
  `.rs` files the scan happened to list — so `Cargo.toml`, `Cargo.lock`,
  `build.rs` and any `include_str!`ed data are inputs;
- **local path dependencies**, by content, through
  `artifact_path_dependency_digest`, so editing a sibling crate rebuilds;
- **the effective Cargo configuration** of the crate directory
  (`.cargo/config.toml` and the chain above it, plus the Cargo home file);
- **the toolchain and the compiler that runs**, defaulted by `ArtifactId`;
- the release profile, and the crate's name and version as before.

Absolute paths are deliberately absent: an identical crate checked out
elsewhere keys the same, so a cache hit survives a move.

The name, the signature and the return type (a hex `String`) are unchanged, and
so is the format of the file `write_bindings_to_file` emits; only the *value*
changes, which means the first build after upgrading rebuilds.
"""
function compute_crate_hash(info::CrateInfo; release::Bool = true,
                            kind::AbstractString = "crate",
                            features::Vector{String} = String[],
                            default_features::Bool = true,
                            build_env::Vector{Pair{String, String}} = Pair{String, String}[],
                            snapshot::BuildEnvSnapshot = BuildEnvSnapshot())
    # The dependency digest first, and deliberately so: resolving the graph
    # lets Cargo write `Cargo.lock` into the crate directory (exactly as the
    # build that follows would), and `Cargo.lock` is one of the files
    # `crate_content_digest` hashes. Computing the content digest first would
    # make the very first call disagree with every later one.
    deps_digest = artifact_path_dependency_digest(info.path; env = snapshot_env(snapshot))
    # `kind` and the feature set are what separates a #275 Phase-2 wrapper
    # build from a plain `@rust_crate` build of the same crate, and one feature
    # set from another: the wrapper's `lib.rs`, its dependency's resolved
    # features and the RUSTFLAGS it links with are all decided by them, and two
    # such builds are different binaries under one crate directory. The
    # feature set is in the key for *every* kind: a plain build made with
    # `features = ...` / `default_features = false` is a different binary
    # from the default build too (#307 review).
    codegen = Pair{String, String}["profile" => (release ? "release" : "debug"),
                                   "features" => join(features, ","),
                                   "default-features" => string(default_features)]
    # `build_env` is the caller's, appended to the Cargo-config digest every
    # crate build already carries. A #275 wrapper build passes
    # `artifact_build_env()` plus its own link flags, because it inherits the
    # ambient `RUSTFLAGS` and the rest of the #282 allowlist — two builds under
    # different ambient flags are different binaries and must not share a key.
    # The Cargo configuration `snapshot`'s `CARGO_HOME` selects: a build passes
    # its own, so the key and the build read one environment (#481).
    env = Pair{String, String}["cargo-config" =>
                               _cargo_config_digest(snapshot_env(snapshot); dir = info.path)]
    append!(env, build_env)
    extra = Pair{String, String}["name" => info.name, "version" => info.version]
    # A workspace member's build is decided by files outside its directory:
    # the workspace root's manifest (`[workspace.dependencies]`, `[patch]`)
    # and lockfile, which a wrapper build now carries over
    # (`_wrapper_shaped_project`). Hashed by content, so a change there that
    # touches no file of the member still rebuilds (#307 review, #278).
    root = _cargo_root_dir(info.path)
    if root != abspath(info.path)
        # The root's lockfile records what the *member* resolves: the release
        # crates whose version lines leave the identity are found from the
        # member's manifest and the root's `[workspace.dependencies]` together
        # (#372 review) — a virtual root declares no `[dependencies]` of its own.
        release_names = union(_rustcall_release_names_in(info.path), _rustcall_release_names_in(root))
        push!(extra, "workspace-root-manifest" => _identity_file_digest(joinpath(root, "Cargo.toml")))
        push!(extra, "workspace-root-lock" =>
              _identity_file_digest(joinpath(root, "Cargo.lock"); release_names))
    end
    # So is a library root outside the package directory (`[lib] path =
    # "../shared/lib.rs"`), which the scan follows and `source` — the package
    # directory's content — does not see (#307 review).
    manifest_path = joinpath(info.path, "Cargo.toml")
    lib_root = isfile(manifest_path) ? crate_lib_root(info.path, parse_cargo_toml(manifest_path)) :
                                       nothing
    external = external_lib_tree_digest(info.path, lib_root)
    external === nothing || push!(extra, "external-lib-tree" => external)
    return artifact_key(ArtifactId(
        kind = String(kind),
        source = crate_content_digest(info.path),
        codegen = codegen,
        dependencies = String[deps_digest],
        build_env = env,
        extra = extra,
    ))
end

"""
    get_function_pointer_from_lib(lib_handle::Ptr{Cvoid}, func_name::String) -> Ptr{Cvoid}

Get a function pointer from a loaded library.

No generated wrapper calls it — they resolve through their module's generation
snapshot. It stays because the `import RustCall: ...` prelude of every file an
older RustCall wrote with `write_bindings_to_file` names it, and such a file of
this `MAJOR.MINOR` must keep loading (`BINDINGS_FORMAT_VERSION`).
"""
function get_function_pointer_from_lib(lib_handle::Ptr{Cvoid}, func_name::String)
    Libdl.dlsym(lib_handle, func_name)
end
