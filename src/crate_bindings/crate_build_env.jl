# ============================================================================
# Julia Module Generation
# ============================================================================

"""
    _crate_precompile_dependencies(crate_path) -> Vector{String}

Every path on disk that the crate's artifact identity is computed from — files
**and the directories that hold them** — as absolute paths.

A module generated in memory by `@rust_crate` may be compiled into a package's
precompile image (#339), and Julia decides that image is stale from what the
module declared with `Base.include_dependency`. Declaring only the built
library is not enough: the library is content-addressed, so editing
`src/lib.rs` produces a *different* cache path and leaves the old file
untouched — the image would still be valid and the package would go on calling
the previous build (#339 review). Declaring the inputs instead makes an edit to
the crate invalidate the image, which is what sends the next `using` back
through `@rust_crate`.

The list is deliberately the same set `compute_crate_hash` reads: the crate
directory's own input files, every local `path` dependency's, the effective
Cargo configuration, the contents of `PYO3_CONFIG_FILE` when one is set (both
the wrapper path and a plain build of a crate that depends on pyo3 read it),
the workspace root's manifest and lockfile when the crate is a
workspace member, and a library root that lives outside the package directory
(`[lib] path = "../shared/lib.rs"`).

**Directories are in the list because files alone cannot see an addition.**
`include_dependency` tracks a directory by `join(readdir(path))`, so declaring
each directory that holds an input catches a *new* file appearing beside the
ones that were there — a source file a build script globs, or a
`.cargo/config.toml` created where none existed — which changes
`crate_content_digest` and therefore the artifact, while touching no file the
image already knew (#339 review). Two gaps remain, both deliberate: a
`.cargo/` created in an *ancestor* of the crate is not seen, and neither is one
appearing in `CARGO_HOME`, because tracking those directories would mean
tracking directories whose contents churn for unrelated reasons and
re-precompiling the package for each.

A path that is not on disk is dropped — `include_dependency` raises on an
unreadable path, and a missing input already changes the digest through
`crate_content_digest`.
"""
_crate_precompile_dependencies(crate_path::AbstractString) =
    _crate_precompile_dependencies(crate_path, BuildEnvSnapshot())

function _crate_precompile_dependencies(crate_path::AbstractString, snapshot::BuildEnvSnapshot)
    root = abspath(String(crate_path))
    isdir(root) || return String[]
    deps = String[]
    dirs = String[root]
    try
        _, found = local_path_dependency_dirs(root; env = snapshot_env(snapshot))
        append!(dirs, found)
    catch e
        # Resolving the graph needs Cargo; without it the crate's own files are
        # still worth declaring.
        @debug "Could not resolve path dependencies for precompile tracking" crate_path exception = e
    end
    # `local_path_dependency_dirs` already unions every local crate any
    # manifest in the graph declares — optional ones included, transitively —
    # so an optional dependency that only `features = [...]` activates is in
    # this list *and* in the artifact key it feeds. The two must agree: a
    # tracked file that changes the image but not the key would rebuild the
    # bindings around the same stale library (#339 review).
    for dir in unique(abspath.(dirs))
        isdir(dir) || continue
        try
            # `crate_input_files` / `crate_input_dirs` report `/`-separated
            # relative names on every platform; `normpath` makes the joined
            # path a native one, so the list has one spelling per file and a
            # caller comparing paths on Windows sees `\` throughout.
            _, files = crate_input_files(dir)
            for rel in files
                f = normpath(joinpath(dir, rel))
                isfile(f) && push!(deps, f)
            end
            # The directories of that same walk, including the ones holding no
            # file: creating the first file in an empty `assets/` changes
            # `crate_content_digest`, moves no file, and does not change its
            # parent's entry list either, because the directory was already
            # there (#339 review).
            for rel in crate_input_dirs(dir)
                d = rel == "." ? dir : normpath(joinpath(dir, rel))
                isdir(d) && push!(deps, d)
            end
        catch e
            @debug "Could not list crate input files for precompile tracking" dir exception = e
        end
    end
    # Cargo's own configuration decides the flags a build runs under, and is
    # in the artifact key through `_cargo_config_digest` — an edit to
    # `.cargo/config.toml` changes the binary without touching a file of the
    # crate, so it belongs here too (#339 review).
    try
        append!(deps, _cargo_config_files(snapshot_env(snapshot); dir = root))
    catch e
        @debug "Could not list Cargo configuration files for precompile tracking" root exception = e
    end
    # A workspace member is decided by files outside its directory, and a
    # library root may live outside it too — both are in the artifact key.
    try
        workspace = _cargo_root_dir(root)
        if abspath(workspace) != root
            for name in ("Cargo.toml", "Cargo.lock")
                f = joinpath(workspace, name)
                isfile(f) && push!(deps, f)
            end
        end
        manifest_path = joinpath(root, "Cargo.toml")
        if isfile(manifest_path)
            lib_root = crate_lib_root(root, parse_cargo_toml(manifest_path))
            if lib_root !== nothing
                lib_dir = dirname(abspath(lib_root))
                if !startswith(lib_dir * "/", root * "/") && isdir(lib_dir)
                    _, files = crate_input_files(lib_dir)
                    for rel in files
                        f = normpath(joinpath(lib_dir, rel))
                        isfile(f) && push!(deps, f)
                    end
                    # And this tree's directories, for the same reason as the
                    # crate's own: `external_lib_tree_digest` hashes the file
                    # list, so a first file appearing in a directory that was
                    # already there moves nothing else (#339 review).
                    for rel in crate_input_dirs(lib_dir)
                        d = rel == "." ? lib_dir : normpath(joinpath(lib_dir, rel))
                        isdir(d) && push!(deps, d)
                    end
                end
            end
        end
    catch e
        @debug "Could not resolve out-of-directory crate inputs" crate_path exception = e
    end
    # The directories that hold those files, so a file *appearing* is seen too:
    # `include_dependency` tracks a directory by its entry list. `CARGO_HOME`
    # is left out on purpose — its top level holds the registry and git caches,
    # and tracking it would re-precompile the package for reasons that have
    # nothing to do with this crate.
    # Only the holders of *files*: a directory in the list is an input in its
    # own right and its parent is not — for the crate root that parent is the
    # checkout, whose unrelated siblings must not invalidate the image (#339
    # review).
    cargo_home = abspath(get(snapshot, "CARGO_HOME", joinpath(homedir(), ".cargo")))
    for dir in unique(dirname.(filter(isfile, deps)))
        isdir(dir) || continue
        abspath(dir) == cargo_home && continue
        push!(deps, dir)
    end
    # `PYO3_CONFIG_FILE` names a file whose *contents* decide the wrapper's
    # Python version, ABI and library directory, and both build paths hash
    # those contents into the artifact. It usually lives outside the crate
    # tree, so nothing above would have caught an edit to it (#339 review).
    # Added *after* the holder loop on purpose: the selected file is the input,
    # not its directory — a sibling appearing next to it changes nothing the
    # build reads, and must not invalidate the image (#339 review).
    # A selected file that does not exist *yet* is tracked through its
    # directory instead: a build script that tolerates the absence is built
    # without it, and the file appearing is then the one event that changes
    # the build — the entry list of the directory is what sees it. Once the
    # file exists, it is the input and the directory is not (#339 review).
    let config = get(snapshot, "PYO3_CONFIG_FILE", "")
        if !isempty(config)
            if isfile(config)
                push!(deps, abspath(config))
            elseif isdir(dirname(abspath(config)))
                push!(deps, dirname(abspath(config)))
            end
        end
    end
    return unique!(map(normpath, deps))
end

function _expand_precompile_inputs(paths::Vector{String})
    expanded = String[]
    for path in unique(abspath.(paths))
        if isfile(path)
            push!(expanded, path)
        elseif isdir(path)
            for (root, dirs, files) in walkdir(path)
                push!(expanded, root)
                append!(expanded, joinpath.(Ref(root), dirs))
                append!(expanded, joinpath.(Ref(root), files))
            end
        end
    end
    unique!(map(normpath, expanded))
end

"""
    _recorded_build_env(snapshot; python = false, link_source = nothing) -> Vector{Pair{String, String}}

The environment a generated module records and compares at load time: the
`artifact_build_env` allowlist, plus RustCall's own selectors that decide the
artifact without being in that allowlist — `RUSTCALL_PYTHON_LIBDIR`, which
`python_link_source()` gives precedence and `pyo3_link_rustflags()` folds into
a wrapper's identity and rpath (#339 review). One function for both sides, so
what is recorded and what is compared cannot drift.

Read from `snapshot` — variables, `PATH` lookups and every interpreter it runs —
so a record and the build it describes see one environment (#481). The form
without it takes a snapshot of `ENV` now.

`link_source`, when given, is the `(libdir, interpreter, fingerprint)` a PyO3
wrapper's plan was made with — the values its artifact key was computed from —
and the record takes the link directory, the selection and the fingerprint
from it rather than asking the interpreter again. A second answer is a second
moment: an interpreter replaced in place between the two recorded a Python the
library was not built for, and the load-time check then accepted the wrong
wrapper (#485 review). Comparing (`_build_env_changes`) passes none, so the
current interpreter is asked, which is the point of the check.
"""
_recorded_build_env(; python::Bool = false) =
    _recorded_build_env(BuildEnvSnapshot(); python = python)

function _recorded_build_env(snapshot::BuildEnvSnapshot; python::Bool = false,
                             link_source::Union{Nothing, NTuple{3, String}} = nothing)
    env = Pair{String, String}[String(k) => String(v)
                               for (k, v) in artifact_build_env(; env = snapshot_env(snapshot))]
    # The *contents* of `PYO3_CONFIG_FILE`, not only its path: the file is
    # tracked when it exists, but one selected before it exists cannot be —
    # its directory is — and a load after it appeared must still be told.
    # "" when unset, `_file_content_digest`'s marker when absent (#339 review).
    push!(env, "<PYO3_CONFIG_FILE digest>" => _pyo3_config_file_digest(snapshot))
    if !python
        # A plain build's pyo3 — a `cdylib` with `#[julia]` items that also
        # depends on pyo3 — runs pyo3's build script, which selects an
        # interpreter (`PYO3_PYTHON`, else `python3` on `PATH`) and configures
        # the library for *that* Python's ABI. The `PYO3_*` values above see a
        # changed `PYO3_PYTHON`, not a `PATH` that now finds another Python or
        # a shim retargeted under the same name; what the interpreter *is* does
        # (#339 review). Recorded the way `_plain_crate_build_env` keys it.
        interpreter, fingerprint = _pyo3_build_interpreter(snapshot)
        push!(env, "<pyo3 build interpreter>" => interpreter)
        push!(env, "<pyo3 build fingerprint>" => fingerprint)
    end
    # Only for a module that binds a PyO3 wrapper: a plain crate's build never
    # consults `python_link_source()`, so for it this selector is not an input
    # and comparing it would warn about a library nothing changed (#339
    # review).
    if python
        for name in ("RUSTCALL_PYTHON_LIBDIR",)
            value = get(snapshot, name, nothing)
            value === nothing || push!(env, name => String(value))
        end
        # The plan itself, computed once: `(libdir, interpreter, fingerprint)`
        # exactly as `python_link_source()` decides it for a build — the
        # build's own plan when the caller has one. Its interpreter *is* the
        # selection: `_python_selection` follows `python_link_source()` step
        # for step.
        source = something(link_source, _python_link_source_or_empty(snapshot))
        selection = link_source === nothing ? _python_selection(snapshot) : source[2]
        push!(env, "<python selection>" => selection)
        # When pyo3's own configuration (`PYO3_CROSS_LIB_DIR`, the `lib_dir`
        # of a `PYO3_CONFIG_FILE`) decides, pyo3 consults no interpreter: the
        # plan's fingerprint is "" and `_pyo3_wrapper_build_env` keys nothing
        # by what `PYO3_PYTHON` resolves to. Recording it anyway warned about
        # a `PYTHONHOME` or shim change that selects the same artifact (#339
        # review). So the two interpreter records below are empty on that
        # branch, the way the plan's are.
        configured = !isempty(_pyo3_configured_lib_dir(snapshot))
        # What that selection *is*: `PYO3_PYTHON` may be a bare `python3` or a
        # pyenv/asdf shim whose target moves under the same name, and
        # `python_link_source()` runs the command and hashes what it reports.
        # The resolved `sys.executable` is recorded beside the raw selection
        # (one short subprocess, only for a PyO3 wrapper module; #339 review).
        push!(env, "<python resolved>" =>
                   (configured ? "" : _python_resolved(snapshot, selection)))
        # And what it *reports*: the same executable can describe a different
        # Python after `PYTHONHOME` or its sysconfig metadata changes, and
        # `_pyo3_wrapper_build_env` hashes exactly that description
        # (`plan.interpreter_config`). Recorded as the plan records it — the
        # plan's own value, "" on the configured branch (#339 review).
        push!(env, "<python fingerprint>" => source[3])
        # The link directory is not the interpreter's alone: for the implicit
        # case `python_link_source()` asks a bare `python3-config --ldflags`,
        # falling back to `python-config`, and `PATH` may resolve either to
        # another installation than the interpreter's. Both commands'
        # identities are recorded, and their content tracked as files — but
        # only on that implicit branch: with `PYO3_PYTHON`, a configured
        # library directory, `RUSTCALL_PYTHON_LIBDIR` or CondaPkg deciding,
        # neither command is consulted and neither is an input (#339 review).
        # Nor on macOS when the implicit interpreter is a framework build:
        # `python_link_source()` takes the framework prefix and never asks
        # either command (`_python_config_consulted`).
        if _python_config_consulted(snapshot)
            for (name, path) in _python_config_selections(snapshot)
                push!(env, "<$name selection>" => path)
            end
        end
        # And the directory all of that *resolves to*: `pyo3_link_rustflags`
        # builds the wrapper's `-L` and rpath from `python_link_source()[1]`,
        # and `_pyo3_wrapper_build_env` keys the artifact by those flags. The
        # selections above name the commands; an unchanged `python3-config`
        # that is a shim can still answer with another directory once the
        # environment or metadata it reads moves, and only the answer itself
        # says so. Recorded the way the flags are computed (#339 review).
        push!(env, "<python link dir>" => source[1])
    end
    return env
end

"""
    _pyo3_build_interpreter() -> (interpreter::String, fingerprint::String)

The interpreter pyo3's **build script** selects when a crate that depends on
pyo3 is built as it stands (the plain path, no wrapper), and what that
interpreter reports about itself (`_python_interpreter_fingerprint`): `("", "")`
when pyo3's own configuration (`PYO3_CROSS_LIB_DIR`, the `lib_dir` of a
`PYO3_CONFIG_FILE`) decides and no interpreter is consulted; else `PYO3_PYTHON`
as given; else the `sys.executable` of the first `python3` / `python` on
`PATH`. The same order pyo3 uses — RustCall's own selectors
(`RUSTCALL_PYTHON_LIBDIR`, CondaPkg) play no part in a build RustCall does not
wrap. Part of a plain build's key and of its module's load-time record, so a
`PATH` that finds another Python, or a shim retargeted under one name, is a
different artifact and a reported change rather than a library configured for
the previous ABI (#339 review). One short subprocess; "" for both when no
interpreter can be run.
"""
_pyo3_build_interpreter() = _pyo3_build_interpreter(BuildEnvSnapshot())

function _pyo3_build_interpreter(snapshot::BuildEnvSnapshot)
    isempty(_pyo3_configured_lib_dir(snapshot)) || return ("", "")
    pinned = get(snapshot, "PYO3_PYTHON", "")
    interpreter = isempty(pinned) ? _python_executable_on_path(snapshot) : String(pinned)
    isempty(interpreter) && return ("", "")
    fingerprint = try
        String(_python_interpreter_fingerprint(snapshot, interpreter))
    catch
        ""
    end
    return (interpreter, fingerprint)
end

"""
    _python_link_is_implicit() -> Bool

Whether `python_link_source()` would reach its last step — the interpreter and
`python3-config` / `python-config` found on `PATH` — rather than be decided by
pyo3's own configuration, `PYO3_PYTHON`, `RUSTCALL_PYTHON_LIBDIR` or CondaPkg.
Only then are the config commands inputs of the wrapper (#339 review).
"""
_python_link_is_implicit() = _python_link_is_implicit(BuildEnvSnapshot())

function _python_link_is_implicit(snapshot::BuildEnvSnapshot)
    isempty(_pyo3_configured_lib_dir(snapshot)) || return false
    isempty(get(snapshot, "PYO3_PYTHON", "")) || return false
    isempty(get(snapshot, "RUSTCALL_PYTHON_LIBDIR", "")) || return false
    return _condapkg_link_source(snapshot) === nothing
end

"""
    _python_config_consulted() -> Bool

Whether `python_link_source()` actually asks `python3-config` / `python-config`
for the link directory: the implicit case (`_python_link_is_implicit`), minus
the one step it takes before either command — on macOS a framework build of
the interpreter answers with its framework prefix, and neither command is run.
For such a Python the commands are not inputs: recording them warned about a
changed `python3-config` on `PATH`, and tracking its file rebuilt the package,
while the wrapper's link directory and identity had not moved (#339 review).
Mirrors the `python3` / `python` loop of `python_link_source()` step for step,
and is `false` when no interpreter is found at all — then nothing is consulted.
"""
_python_config_consulted() = _python_config_consulted(BuildEnvSnapshot())

function _python_config_consulted(snapshot::BuildEnvSnapshot)
    _python_link_is_implicit(snapshot) || return false
    for exe in ("python3", "python")
        isempty(_python_executable(snapshot, exe)) && continue
        return !(Sys.isapple() && !isempty(_python_framework_prefix(snapshot, exe)))
    end
    return false
end

"""
    _python_config_selections() -> Vector{Pair{String, String}}

The `python3-config` and `python-config` that `python_link_source()` would run
for the implicit link directory — the first of each on `PATH`, "" when there is
none — in the order `_python_config_libdir()` tries them. Both are recorded and
compared for a PyO3 wrapper module, and both files tracked, because `PATH`
resolving either to another installation changes the rpath the wrapper is
linked with while the interpreter, and everything else recorded, stays the
same. Recording the fallback even when the first command answers is
deliberate: which one *answers* is only known by running them, and a load
must not (#339 review).
"""
_python_config_selections() = _python_config_selections(BuildEnvSnapshot())

function _python_config_selections(snapshot::BuildEnvSnapshot)
    # A `Vector`, not a tuple: the wrapper path splices `last.(...)` of this
    # into a `String[...]`, and a tuple there is one element that cannot be
    # converted, not two strings. Looked up on the snapshot's `PATH` (#481).
    map(["python3-config", "python-config"]) do name
        name => snapshot_which(snapshot, name)
    end
end

"""
    _python_resolved(command) -> String

The `sys.executable` that `command` reports, or `command` itself when it cannot
be run; "" for "". A bare `python3` or a shim is one path on `PATH` and another
underneath, and only the interpreter can say which (#339 review).
"""
_python_resolved(command::AbstractString) = _python_resolved(BuildEnvSnapshot(), command)

function _python_resolved(snapshot::BuildEnvSnapshot, command::AbstractString)
    isempty(command) && return ""
    resolved = _python_executable(snapshot, command)
    return isempty(resolved) ? String(command) : resolved
end

"""
    _python_selection() -> String

Which interpreter `python_link_source()` would pin, decided the way it decides
it: `PYO3_PYTHON` when set, else CondaPkg's when that package is loaded, else
the `sys.executable` the first `python3` / `python` on `PATH` reports
(`_python_executable_on_path`). "" when there is none.

Recorded for a PyO3 wrapper module so `__init__` can tell that the *selection*
moved — `PYO3_PYTHON` unset and `PATH` now finding a different interpreter —
which tracking the selected interpreter's files cannot see, because the old
one is still there, unchanged (#339 review). The implicit case asks the
interpreter rather than trusting `Sys.which`: a pyenv or asdf shim keeps one
path on `PATH` while its project selection moves the real interpreter, and
only `sys.executable` says which one that is. One short subprocess per load of
a PyO3 wrapper module; a plain module never runs it.
"""
_python_selection() = _python_selection(BuildEnvSnapshot())

function _python_selection(snapshot::BuildEnvSnapshot)
    # The same order as `python_link_source()`, step for step — a selector that
    # disagrees with it records the wrong interpreter and then never notices
    # the real one moving (#339 review). The contract test asserts the two
    # agree in the running environment.
    #
    # 1. pyo3's own configuration (`PYO3_CROSS_LIB_DIR`, `PYO3_CONFIG_FILE`):
    #    the interpreter is `PYO3_PYTHON` if set, else none.
    isempty(_pyo3_configured_lib_dir(snapshot)) || return String(get(snapshot, "PYO3_PYTHON", ""))
    # 2. an explicit `PYO3_PYTHON`.
    pinned = get(snapshot, "PYO3_PYTHON", "")
    isempty(pinned) || return String(pinned)
    # 3. `RUSTCALL_PYTHON_LIBDIR` alone leaves the interpreter to `PATH`, and
    #    that comes *before* CondaPkg.
    isempty(get(snapshot, "RUSTCALL_PYTHON_LIBDIR", "")) ||
        return _python_executable_on_path(snapshot)
    # 4. CondaPkg's environment, when the package is loaded and has one.
    conda = _condapkg_link_source(snapshot)
    conda === nothing || return String(conda[2])
    # 5. the first `python3` / `python` on `PATH`, as it reports itself.
    return _python_executable_on_path(snapshot)
end

# Where a generated crate module came from: the two emitters (#531).
const _BUILD_ENV_ORIGINS = (:rust_crate, :bindings_file)

_check_build_env_origin(origin::Symbol) =
    origin in _BUILD_ENV_ORIGINS ||
        throw(ArgumentError("unknown module origin $(repr(origin)); expected one of $(_BUILD_ENV_ORIGINS)"))

"""
    _build_env_changed_message(lib_name, crate_path, changed, origin) -> String

The one diagnostic for a generated crate module whose recorded build environment
no longer matches (#531). What went wrong is the same for both origins; the
remedy is not. A `@rust_crate` module is rebuilt when its package is precompiled
again. A file written by `write_bindings_to_file` records the environment in its
own source (`_BUILD_RECORD`), so re-precompiling reads the same record and fails
the same way: the file must be written again, after which a package that
includes it re-precompiles on its own.
"""
function _build_env_changed_message(lib_name::AbstractString, crate_path::AbstractString,
                                    changed, origin::Symbol)
    _check_build_env_origin(origin)
    what = "Variables: $(join(changed, ", "))."
    if origin === :bindings_file
        return """
        RustCall: the build environment changed since `$(lib_name)` was built for this bindings
        file, written by `write_bindings_to_file`. The file records the environment it was
        written under, and the library it names was built under those values. $(what)

        Re-precompiling cannot help: the record is part of the file. Regenerate the file under
        the current environment and RustCall:

            RustCall.write_bindings_to_file($(repr(String(crate_path))), "<this file>")

        A package that includes the file is precompiled again on its own once the file changes.
        """
    end
    return """
    RustCall: the build environment changed since `$(lib_name)` was compiled into this package's
    precompile image, and Julia cannot see that — it invalidates an image from files, and these
    are not files. The library that is about to load was built under the previous values.

    $(what) Force a rebuild with `Pkg.precompile(; force = true)`, or
    touch a source file of the crate.
    """
end

"""
    _warn_if_build_env_changed(recorded, crate_path, lib_name; strict = false,
                               origin = :rust_crate)

Check whether the environment that decides this crate's artifact is the one it
was built under. The generated `@rust_crate` module uses `strict = true` and
refuses to load a precompiled image whose non-file inputs changed; the default
is retained for diagnostic callers and emits the historical warning.

`origin` says where the module came from, and so which remedy the message names
(`_build_env_changed_message`, #531): `:rust_crate` for the module `@rust_crate`
builds, `:bindings_file` for a file `write_bindings_to_file` wrote. The
in-memory module's `__init__` names its origin; a written file makes the
origin-less record call, which is read as `:bindings_file`
(`_crate_init_prologue`).

Julia invalidates a precompile image from *files*, and
`Base.include_dependency` is the only lever a generated module has. Part of the
artifact identity is not a file: `RUSTFLAGS`, `PYO3_PYTHON`, a
`PYO3_CONFIG_FILE` **pointing somewhere else**, and the rest of the allowlist
`artifact_build_env` captures. Change one of those and every file the image
tracks is still byte-for-byte what it was, so Julia keeps the image and the
module loads a library built for the other environment — silently, and with a
Python preload plan to match (#339 review).

Nothing here can invalidate the image; what it can do is refuse to be silent.
The module records the values it was generated under and compares them at load
time, which is cheap — the allowlist is read from one snapshot of `ENV` taken
here, no probe, no build. The fix it names is the one that works for the
module's origin: re-precompiling a package rebuilds a `@rust_crate` module under
the current environment, but a written file carries its record in its own
source, so it must be written again.
"""
function _warn_if_build_env_changed(recorded, crate_path::AbstractString, lib_name::AbstractString,
                                    recorded_cargo_config::AbstractString = "",
                                    recorded_toolchain::AbstractString = "";
                                    python::Bool = false,
                                    strict::Bool = false,
                                    origin::Symbol = :rust_crate)
    _check_build_env_origin(origin)
    # A load, not a build: the check takes its own one snapshot (#481).
    changed = _build_env_changes(recorded, crate_path, recorded_cargo_config,
                                 recorded_toolchain; python = python,
                                 snapshot = BuildEnvSnapshot())
    (changed === nothing || isempty(changed)) && return nothing
    message = _build_env_changed_message(lib_name, crate_path, changed, origin)
    if strict
        throw(RustError(String(strip(message))))
    end
    @warn message crate = crate_path variables = changed
    return nothing
end

"""
    _build_env_changes(recorded, crate_path, recorded_cargo_config = "",
                       recorded_toolchain = ""; python = false,
                       snapshot) -> Union{Nothing, Vector{String}}

What differs between the build environment a generated module recorded
(the `build_env`, `cargo_config` and `toolchain` of its `CrateBuildRecord`) and
the one `snapshot` holds — every value, the Cargo configuration and every
interpreter read from it, never from `ENV` (#481): the names of
the changed allowlisted variables, plus `<effective Cargo configuration>` and
`<Rust toolchain>` when those moved. `nothing` when the current environment
cannot be read. The one comparison both a module's `__init__`
(`_warn_if_build_env_changed`) and a hot reload of that module
(`_build_record_mismatch`) make.
"""
function _build_env_changes(recorded, crate_path::AbstractString,
                            recorded_cargo_config::AbstractString = "",
                            recorded_toolchain::AbstractString = "";
                            python::Bool = false,
                            snapshot::BuildEnvSnapshot)
    current = try
        _recorded_build_env(snapshot; python = python)
    catch e
        @debug "Could not read the build environment" exception = e
        return nothing
    end
    was = Dict{String, String}(String(k) => String(v) for (k, v) in recorded)
    now = Dict{String, String}(String(k) => String(v) for (k, v) in current)
    changed = sort!(collect(union(keys(was), keys(now))))
    filter!(k -> get(was, k, nothing) != get(now, k, nothing), changed)
    # The *effective* Cargo configuration is selected by `CARGO_HOME`, which
    # the allowlist deliberately does not capture — the file's contents go into
    # the artifact identity instead of its path. So pointing `CARGO_HOME`
    # somewhere else changes the flags a build runs under while every variable
    # above, and every file `_CRATE_INPUTS` names, stays exactly as it was
    # (#339 review). Comparing the digest catches that, and any other way the
    # effective configuration differs.
    if !isempty(recorded_cargo_config)
        now_config = try
            _cargo_config_digest(snapshot_env(snapshot); dir = crate_path)
        catch e
            @debug "Could not read the Cargo configuration" exception = e
            recorded_cargo_config
        end
        now_config == recorded_cargo_config || push!(changed, "<effective Cargo configuration>")
    end
    # The toolchain is in the artifact identity too (`toolchain_fingerprint`:
    # compiler identity, extractor, core sources) and is not a file the image
    # tracks — `rustup update stable` replaces the binaries behind a proxy
    # whose path and content do not move (#339 review). Memoized per session,
    # so this is one `rustc -vV` per process at most.
    if !isempty(recorded_toolchain)
        now_toolchain = try
            toolchain_fingerprint()
        catch e
            @debug "Could not fingerprint the toolchain" exception = e
            recorded_toolchain
        end
        if now_toolchain != recorded_toolchain
            @debug "Generated crate toolchain mismatch" crate_path recorded_toolchain now_toolchain
            push!(changed, "<Rust toolchain>")
        end
    end
    return changed
end

"""
    crate_build_options(; release, features, default_features, kind) -> NamedTuple

The build a generated `@rust_crate` module was made from, as the module records
it in its `CrateBuildRecord` (`_BUILD_RECORD`): the profile, the feature selection, and `kind` — how the
library was produced (`:direct`, the crate built as its own `cdylib`;
`:wrapper`, a generated wrapper crate around an rlib; `:pyo3_wrapper`, the PyO3
wrapper of #275). Hot reload rebuilds from it (`enable_hot_reload_for_crate`),
so a reload publishes a build with the same `#[cfg]`s under the module's
registry name rather than a release build with default features (#461 review).
"""
crate_build_options(; release::Bool = true, features::Vector{String} = String[],
                    default_features::Bool = true, kind::Symbol = :direct) =
    (release = release, features = Tuple(features), default_features = default_features,
     kind = kind)

"""
    CrateBuildRecord

Everything a build of a `@rust_crate` library was made from — and therefore
everything a hot reload must reproduce before it may publish another image under
that library's registry name (#474):

- `crate_dir` — the crate the module was generated from (absolute);
- `lib_name` — the registry name the library is loaded as (`_LIB_NAME`);
- `release`, `features`, `default_features` — the profile and the feature
  selection (`crate_build_options`);
- `kind` — how the library was produced: `:direct` (the crate is its own
  `cdylib`), `:wrapper` (a generated wrapper crate around an rlib) or
  `:pyo3_wrapper` (#275);
- `build_env`, `cargo_config`, `toolchain` — the part of the artifact identity
  that is not a file: the allowlisted variables, the effective Cargo
  configuration's digest and the toolchain fingerprint (`""` when it could not
  be read, which then is not compared);
- `python` — whether `build_env` carries the Python selection of a module that
  links libpython (`_recorded_build_env(; python)`).

A generated module holds exactly one, as `_BUILD_RECORD`, emitted by both crate
emitters from one call (`crate_build_record`); `_LIB_NAME` is read from it.
Hot reload takes every rebuild input from it and nothing else: the module form
of `enable_hot_reload_for_crate` reads it once and compares caller arguments
against it (`_check_record_arguments`), and every reload compares the current
environment with it (`_build_record_mismatch`) before building. Immutable, so a
reload cannot drift from what the module was generated for.
"""
struct CrateBuildRecord
    crate_dir::String
    lib_name::String
    release::Bool
    features::Tuple{Vararg{String}}
    default_features::Bool
    kind::Symbol
    build_env::Tuple{Vararg{Pair{String, String}}}
    cargo_config::String
    toolchain::String
    python::Bool
end

CrateBuildRecord(crate_dir::AbstractString, lib_name::AbstractString, release::Bool,
                 features, default_features::Bool, kind::Symbol, build_env,
                 cargo_config::AbstractString, toolchain::AbstractString, python::Bool) =
    CrateBuildRecord(String(crate_dir), String(lib_name), release,
                     Tuple(String(f) for f in features), default_features, kind,
                     Tuple(String(k) => String(v) for (k, v) in build_env),
                     String(cargo_config), String(toolchain), python)

# The written-bindings spelling: `repr(record)` is source that evaluates to an
# equal record, so the source-text emitter can emit the very value the
# expression emitter splices (asserted by `test/test_hot_reload_record.jl`).
function Base.show(io::IO, r::CrateBuildRecord)
    print(io, "RustCall.CrateBuildRecord(")
    fields = fieldnames(CrateBuildRecord)
    for (i, f) in enumerate(fields)
        show(io, getfield(r, f))
        i < length(fields) && print(io, ", ")
    end
    print(io, ")")
end

"""
    record_build_options(record::CrateBuildRecord) -> NamedTuple

The record's build in `crate_build_options` shape.
"""
record_build_options(r::CrateBuildRecord) =
    crate_build_options(release = r.release, features = collect(String, r.features),
                        default_features = r.default_features, kind = r.kind)

"""
    crate_build_record(crate_path, lib_name; build_options, python = false,
                       snapshot, link_source = nothing) -> CrateBuildRecord

The record of a build of `crate_path` made under `snapshot`: the given build
options, plus the build environment, Cargo configuration and toolchain as the
snapshot has them. What both crate emitters record (one call, one value), and
what the path form of `enable_hot_reload_for_crate` constructs for a library it
has no module of. `snapshot` is required: a record read from `ENV` at its own
moment described a build made under another one (#481). `link_source` is a
PyO3 wrapper plan's link source (`_recorded_build_env`); the wrapper path
records through `pyo3_wrapper_build_record`.
"""
function crate_build_record(crate_path::AbstractString, lib_name::AbstractString;
                            build_options::NamedTuple = crate_build_options(),
                            python::Bool = false,
                            snapshot::BuildEnvSnapshot,
                            link_source::Union{Nothing, NTuple{3, String}} = nothing)
    crate_dir = abspath(String(crate_path))
    # The part of the artifact identity that is *not* a file, recorded so the
    # module can say so at load time (`_warn_if_build_env_changed`).
    build_env = try
        _recorded_build_env(snapshot; python = python, link_source = link_source)
    catch e
        @debug "Could not record the build environment" exception = e
        Pair{String, String}[]
    end
    toolchain = try
        toolchain_fingerprint()
    catch e
        @debug "Could not record the toolchain fingerprint" exception = e
        ""
    end
    # The effective Cargo configuration is chosen by `CARGO_HOME`, which is not
    # an allowlisted variable: its digest is what says whether the same build
    # would run under the same flags (#339 review).
    cargo_config = try
        _cargo_config_digest(snapshot_env(snapshot); dir = crate_dir)
    catch e
        @debug "Could not record the Cargo configuration" exception = e
        ""
    end
    return CrateBuildRecord(crate_dir, lib_name, build_options.release,
                            build_options.features, build_options.default_features,
                            build_options.kind, build_env, cargo_config, toolchain, python)
end

"""
    _build_record_mismatch(record::CrateBuildRecord, snapshot) -> Vector{String}

What differs between the environment `record` was built under and the one
`snapshot` holds (`_build_env_changes`): the changed variables, `<effective
Cargo configuration>`, `<Rust toolchain>`. Empty when nothing does, or when the
environment cannot be read. A rebuild passes the snapshot its subprocesses are
then derived from (`_record_build_subprocess_env`), so the check and the build
see one environment (#481).
"""
function _build_record_mismatch(r::CrateBuildRecord, snapshot::BuildEnvSnapshot)
    changed = _build_env_changes(r.build_env, r.crate_dir, r.cargo_config, r.toolchain;
                                 python = r.python, snapshot = snapshot)
    return changed === nothing ? String[] : changed
end

# The module's `__init__` check (`_warn_if_build_env_changed`), from its record.
# The call that names no `origin` is a written file's, from any 0.7.x
# (`_crate_init_prologue` keeps writing it, so the file loads under every
# RustCall of its format line, #531 review). An in-memory `@rust_crate` module
# names `:rust_crate`: it is always emitted by the RustCall that loads it (Julia
# re-precompiles a package whose RustCall changed).
_warn_if_build_env_changed(r::CrateBuildRecord; strict::Bool = false,
                           origin::Symbol = :bindings_file) =
    _warn_if_build_env_changed(r.build_env, r.crate_dir, r.lib_name, r.cargo_config,
                               r.toolchain; python = r.python, strict = strict,
                               origin = origin)

"""
    _record_build_subprocess_env(record::CrateBuildRecord, snapshot) -> Dict{String, String}

The environment every Cargo subprocess of a build described by `record` runs
under — the cfg probe and the build of `@rust_crate`, `write_bindings_to_file`
and a hot reload — derived from the record over `snapshot`, the build's one
snapshot of `ENV`, so the build is the one the record describes even if another
task changes `ENV` meanwhile (#474 review, #481):

- every variable `artifact_build_env_captured` accepts is removed from the
  snapshot and the record's own values are put back (`RUSTFLAGS`,
  `CARGO_PROFILE_*`, `RUSTUP_TOOLCHAIN`, `PYO3_*`, a build script's `CC`, ...);
- the interpreter pyo3's build script would pick — recorded as `<pyo3 build
  interpreter>`, found on `PATH` when `PYO3_PYTHON` is unset — is pinned in
  `PYO3_PYTHON`, so a `PATH` changed after the record was taken cannot select
  another Python for the build;
- the Cargo configuration `CARGO_HOME` selects is checked against the record's
  digest *on this environment*, and a different one is refused.

The rest of the snapshot (`PATH`, `CARGO_HOME`, ...) is what the build needs to
run. Other `<...>` entries of `record.build_env` are digests, not variables.
"""
function _record_build_subprocess_env(record::CrateBuildRecord, snapshot::BuildEnvSnapshot)
    env = Dict{String, String}(k => v for (k, v) in snapshot_env(snapshot)
                               if !artifact_build_env_captured(k))
    interpreter = ""
    for (k, v) in record.build_env
        if k == "<pyo3 build interpreter>"
            interpreter = v
            continue
        end
        startswith(k, "<") && continue
        # Allowlisted values are recorded in `_artifact_env_value`'s encoding
        # (`present:<value>`, or `ARTIFACT_ENV_ABSENT`); the others as is.
        if v == ARTIFACT_ENV_ABSENT
            delete!(env, k)
        else
            env[k] = startswith(v, "present:") && artifact_build_env_captured(k) ?
                     chopprefix(v, "present:") : v
        end
    end
    # Only when the record's own `PYO3_PYTHON` did not already decide it: then
    # the recorded interpreter is the one `PATH` selected when it was taken.
    isempty(interpreter) || haskey(env, "PYO3_PYTHON") || (env["PYO3_PYTHON"] = interpreter)
    if !isempty(record.cargo_config)
        now_config = try
            _cargo_config_digest(env; dir = record.crate_dir)
        catch e
            @debug "Could not read the Cargo configuration" exception = e
            record.cargo_config
        end
        now_config == record.cargo_config || throw(ArgumentError(
            "The build environment of $(isempty(record.lib_name) ? record.crate_dir : record.lib_name) " *
            "changed while it was being built (<effective Cargo configuration>): the Cargo " *
            "configuration `CARGO_HOME` selects is not the recorded one, so the build is " *
            "refused rather than made under it. Restore the environment and try again."))
    end
    return env
end

"""
    _plain_crate_build_env(record::CrateBuildRecord) -> Vector{Pair{String, String}}

The environment part of a plain crate's artifact identity (`compute_crate_hash`,
`crate_library_name`), read from `record` rather than from `ENV`: the same
values `_plain_crate_build_env()` reads, under the same names and in the same
order, so the cache key, the registry name and the build all come from one
snapshot (#474 review).
"""
function _plain_crate_build_env(record::CrateBuildRecord)
    out = Pair{String, String}[]
    interpreter = fingerprint = ""
    for (k, v) in record.build_env
        if k == "<PYO3_CONFIG_FILE digest>"
            isempty(v) || push!(out, "pyo3-config-file-digest" => v)
        elseif k == "<pyo3 build interpreter>"
            interpreter = v
        elseif k == "<pyo3 build fingerprint>"
            fingerprint = v
        elseif !startswith(k, "<")
            push!(out, k => v)
        end
    end
    if !isempty(interpreter)
        push!(out, "rustcall-pyo3-python" => interpreter)
        push!(out, "rustcall-pyo3-python-config" => fingerprint)
    end
    return out
end

"""
    _verify_build_interpreter(snapshot, interpreter, fingerprint, what)
    _verify_build_interpreter(record::CrateBuildRecord, snapshot)

Refuse a build whose Python interpreter was **replaced in place** while it ran
(#481). A build that configures pyo3 for an interpreter is keyed and recorded
by that interpreter's path *and* by what it reported about itself
(`_python_interpreter_fingerprint`), asked before the build. The path is pinned
in `PYO3_PYTHON`, so `PATH` cannot select another one — but the file behind the
path can change (an upgrade, a retargeted shim), and the build would then be
configured for a Python its key and record do not name. So the interpreter is
asked again, under the same snapshot, once the build is done and before the
library is cached or published, and a different answer is a `RustError`.

Nothing is checked when `interpreter` or `fingerprint` is `""` — no interpreter
was consulted, or it could not be run when the build was planned. The record
form reads `<pyo3 build interpreter>` / `<pyo3 build fingerprint>`: the
interpreter a plain build's pyo3 configures itself for.
"""
function _verify_build_interpreter(snapshot::BuildEnvSnapshot, interpreter::AbstractString,
                                   fingerprint::AbstractString, what::AbstractString)
    (isempty(interpreter) || isempty(fingerprint)) && return nothing
    now = _python_interpreter_fingerprint(snapshot, interpreter)
    if now == fingerprint
        _build_env_seam(:verified)
        return nothing
    end
    answer = isempty(now) ? "<no answer>" : now
    throw(RustError(
        "The Python interpreter `$(interpreter)` changed while `$(what)` was being built: " *
        "it reported `$(fingerprint)` when the build was planned and `$(answer)` " *
        "afterwards. The library was configured for a Python its identity does not " *
        "name, so it is neither cached nor loaded. Build again."))
end

function _verify_build_interpreter(record::CrateBuildRecord, snapshot::BuildEnvSnapshot)
    interpreter = fingerprint = ""
    for (k, v) in record.build_env
        k == "<pyo3 build interpreter>" && (interpreter = v)
        k == "<pyo3 build fingerprint>" && (fingerprint = v)
    end
    what = isempty(record.lib_name) ? record.crate_dir : record.lib_name
    return _verify_build_interpreter(snapshot, interpreter, fingerprint, what)
end

# `record` under another registry name: the name of a plain build is computed
# from the record's own environment, so the record is taken first and named
# after.
_record_named(r::CrateBuildRecord, lib_name::AbstractString) =
    CrateBuildRecord(r.crate_dir, lib_name, r.release, r.features, r.default_features, r.kind,
                     r.build_env, r.cargo_config, r.toolchain, r.python)
