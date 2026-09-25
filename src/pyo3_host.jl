# ============================================================================
# The PyO3 Python-host path (#424, Phase 1)
# ============================================================================
#
# The existing PyO3 support binds a crate *from outside*: it generates a second
# crate that calls the target's `pub`, interpreter-free items through a C ABI
# and links libpython. That is exactly the subset a PyO3 crate does not use.
# PyO3's own convention is the opposite — `#[pyfunction]` / `#[pyclass]` need no
# `pub`, and real APIs are written in terms of `Python<'_>`, `Py<T>`, numpy
# arrays and Python callables — so the items the wrapper refuses (`not_public`,
# `pyo3_type:<T>`, `unsupported_*`) are the ones a crate actually exposes.
#
# The host path does not lower anything to a C ABI. It builds the crate **as
# the Python extension it already is** — the `extension-module` cdylib the link
# plan calls `:unlinkable`, which is the right build when CPython is the one
# that loads it — and lets a Python implementation `import` it. An item a
# wrapper crate cannot *name* is reachable, because PyO3 registered it from
# inside the crate.
#
# Nothing in this file starts a Python interpreter: the caller names one
# (`python`), and the module that imports the artifact lives in the
# `RustCallPyO3HostExt` package extension, which needs PythonCall. RustCall
# therefore stays interpreter-free, and a session that never loads a PyO3 host
# never pays for one. This is Phase 1 of #424 (build + cache); the typed Julia
# surface is Phase 2 and the `@rust_crate` dispatch is Phase 3.

"""
    PyO3Extension

The artifact of building a PyO3 crate as the Python extension it already is
(#424). Returned by [`build_pyo3_extension`](@ref).

# Fields
- `module_name::String`: the name CPython imports — the `#[pymodule]` initializer's
  name, or its `name = "..."` option.
- `lib_path::String`: the importable file, `<module_name><ext_suffix>`, inside `dir`.
- `dir::String`: the directory to put on `sys.path` before importing.
- `ext_suffix::String`: the interpreter's `EXT_SUFFIX`, which the file name must carry.
- `interpreter::String`: the Python the crate was built against (`PYO3_PYTHON`).
- `fingerprint::String`: what that interpreter reports about itself; part of the cache key.
- `key::String`: the artifact cache key.
"""
struct PyO3Extension
    module_name::String
    lib_path::String
    dir::String
    ext_suffix::String
    interpreter::String
    fingerprint::String
    key::String
end

"""
    pyo3_host_import(crate_path; features, default_features, release, cache_enabled) -> Py

Build `crate_path` as a Python extension and `import` it, returning the Python
module object (as a `PythonCall.Py`).

This is a **hook**: RustCall does not depend on a Python implementation, so
RustCall defines no method here. Load PythonCall and the
`RustCallPyO3HostExt` package extension defines it, using
`PythonCall.python_executable_path()` as the interpreter and PythonCall's own
importer. `RustCall.pyo3_host_available()` says whether it is defined.

The crate is built unmodified. A `#[pyfunction] fn f(...)` that is **not `pub`**,
a signature using `Python<'_>` or `pyo3::Bound`, numpy arrays and Python
callables all become reachable, because the call goes through CPython and the
crate's own `#[pymodule]` registration rather than through a Rust path.

    pyo3_host_import(artifact::PyO3Extension) -> Py

The import alone: the module `build_pyo3_extension` already built (#449). The
one-argument form is `build_pyo3_extension(crate; python = PythonCall.python_executable_path(), ...)`
followed by this, and the build needs no interpreter, so a package can run it
in its `__init__`, keep the artifact, and leave only the import to the first
call. (A `deps/build.jl` is another process: its artifact cannot be kept, but
the cache it fills spares the runtime's `pyo3_host_import(crate)` the build.)
"""
function pyo3_host_import end

"""
    pyo3_host_available() -> Bool

Whether a Python host for PyO3 crates is loaded — i.e. whether
`RustCallPyO3HostExt` has defined [`pyo3_host_import`](@ref). Load PythonCall
(`using PythonCall`) to enable it.
"""
pyo3_host_available() = hasmethod(pyo3_host_import, Tuple{AbstractString})

"""
    pyo3_host_python() -> String

The interpreter the PyO3 host path builds a crate for and imports it into —
`PythonCall.python_executable_path()`, supplied by `RustCallPyO3HostExt`. The
build (`pyo3_host_import`) and the scan the bindings are generated from
(`generate_pyo3_host_bindings`) both ask this, so both configure the crate for
the same Python (#514 review). Without the extension it has no method, and
`_pyo3_host_default_python` answers `""`.
"""
function pyo3_host_python end

_pyo3_host_default_python() =
    hasmethod(pyo3_host_python, Tuple{}) ? String(pyo3_host_python()) : ""

"""
    build_pyo3_extension(crate_path; python, features, default_features, release, cache_enabled) -> PyO3Extension

Build the PyO3 crate at `crate_path` as a Python extension module, without
modifying the crate, and return where the result lives
([`PyO3Extension`](@ref)).

`python` names the interpreter the module is built for; it is passed to pyo3's
build configuration as `PYO3_PYTHON`, and its `sysconfig` `EXT_SUFFIX` names the
output file. Pass the interpreter of the Python implementation that will import
the result — for PythonCall, `PythonCall.python_executable_path()`.

The crate must declare `#[pymodule]` (there is nothing to import otherwise); a
`[lib] crate-type` that does not include `"cdylib"` is not a problem, because
the build selects a cdylib explicitly. Unlike the wrapper path's `rlib`
requirement, an rlib-only crate is fine here.

The build runs `cargo rustc --crate-type cdylib` in the crate's own directory,
so the crate's `.cargo/config.toml`, lockfile and `[patch]` tables apply as they
do to the crate itself. Its output — dependencies included — goes under
`crate_target_directory(crate_path, :pyo3_host)` in RustCall's cache, never the
crate's own `target/` (#486), so a crate in a read-only tree builds; successive
host builds of the crate reuse those dependency outputs, and the user's own
`cargo build` in the crate neither shares them nor is disturbed by them. The platform's extension-module link flags (macOS
`-undefined dynamic_lookup`, which pyo3's build script cannot deliver to the
final cdylib) travel as trailing rustc arguments, not through `RUSTFLAGS`.

The result is cached under `RustCall.get_cache_dir()/pyo3-host/`, keyed by
the crate path, the feature set, the profile, the module name and the
interpreter's fingerprint; `cache_enabled = false` builds every time.

This is the interpreter-free half of `pyo3_host_import` (#449): `python` runs
only as a subprocess, for the module's `EXT_SUFFIX` and the interpreter's
fingerprint, so it may run before any Python is loaded into the process — but
not while a package precompiles, because the interpreter it is keyed by is
not known then.
"""
function build_pyo3_extension(crate_path::AbstractString;
                              python::AbstractString,
                              features::Vector{String} = String[],
                              default_features::Bool = true,
                              release::Bool = true,
                              cache_enabled::Bool = true)
    # ONE snapshot of the environment for the build (#481): the interpreter
    # probe, the key, the Cargo build and the interpreter check after it read
    # it, and nothing below reads `ENV`.
    snapshot = BuildEnvSnapshot()
    path = abspath(String(crate_path))
    isdir(path) || throw(RustError("Crate path does not exist: $(crate_path)"))
    manifest_path = joinpath(path, "Cargo.toml")
    isfile(manifest_path) || throw(RustError("Cargo.toml not found in: $(crate_path)"))
    isempty(python) && throw(RustError(
        "The PyO3 host path needs the Python interpreter to build against — " *
        "one the resulting module can be imported into. With PythonCall loaded, " *
        "that is `PythonCall.python_executable_path()`."))

    cargo_toml = parse_cargo_toml(manifest_path)
    info = scan_crate(path; cargo_env = snapshot_env(snapshot))
    module_name = _pyo3_extension_module_name(info)
    isempty(module_name) && throw(RustError(
        "No `#[pymodule]` initializer was found in `$(crate_path)`. The host path " *
        "builds the crate as a Python extension and imports it, so a crate without " *
        "one has nothing to import."))
    ext_suffix, fingerprint = _pyo3_extension_interpreter_probe(snapshot, python)
    isempty(ext_suffix) && throw(RustError(
        "The interpreter `$(python)` did not report a sysconfig `EXT_SUFFIX`, so " *
        "the extension module cannot be named. Is it a runnable CPython?"))

    # `::String` for the same reason as in `_run_extractor`: the memoized read
    # returns `Any`, and the call below is then dynamic and compiled at the
    # first call (#449).
    artifact = _pyo3_extension_artifact(get_cache_dir()::String, info, module_name, python,
                                        ext_suffix, fingerprint;
                                        features = features,
                                        default_features = default_features,
                                        release = release, snapshot = snapshot)
    # The directory is named by a short name of the key (`short_name_path`), and
    # the file in it is found again by that name alone, so it is owned by the
    # full key before it is looked at: a key whose short id collides is refused
    # rather than handed this key's module. The lock is held from the lookup
    # through the publish, so two builds of one key take turns (#504).
    # `:clear`: an unrecorded directory (a pre-#504 cache entry) may hold a
    # module built for another key that shares the short id, so it is emptied
    # and rebuilt, never adopted (#507 review).
    return with_owned_short_name(artifact.dir, artifact.key; foreign = :clear,
                                 what = "the PyO3 extension of `$(path)`") do
        if cache_enabled && isfile(artifact.lib_path)
            @debug "Using cached PyO3 extension module" key = artifact_short_id(artifact.key, 8) # short-id: label
            return artifact
        end

        built = _build_pyo3_extension_library(snapshot, path, cargo_toml, module_name;
                                              python = python, features = features,
                                              default_features = default_features,
                                              release = release)
        # The key names `python` by what it reported before the build; one
        # replaced in place since then configured this build for another Python,
        # so it is not published under that key (#481).
        _verify_build_interpreter(snapshot, python, fingerprint, module_name)
        # Publish, never overwrite (#394): two sessions may build one key at once.
        published = _publish_cache_file(built, artifact.lib_path)
        return PyO3Extension(module_name, published.path, artifact.dir, ext_suffix,
                             String(python), fingerprint, artifact.key)
    end
end

"""
    _pyo3_extension_artifact(cache_dir, info, module_name, python, ext_suffix, fingerprint;
                             features, default_features, release) -> PyO3Extension

Where the extension module of `info` built for `python` lives under `cache_dir`:
the cache key and the paths it decides, computed without touching the
interpreter, Cargo or the cache directory. `build_pyo3_extension` is this plus
the interpreter probe and the build; the precompile workload of #449 runs this
on its own, because a Python interpreter may not be started while precompiling
and the key must not depend on one.
"""
function _pyo3_extension_artifact(cache_dir::AbstractString, info::CrateInfo,
                                  module_name::AbstractString, python::AbstractString,
                                  ext_suffix::AbstractString, fingerprint::AbstractString;
                                  features::Vector{String} = String[],
                                  default_features::Bool = true,
                                  release::Bool = true,
                                  snapshot::BuildEnvSnapshot = BuildEnvSnapshot())
    # The crate's own content is in the key (`compute_crate_hash` digests the
    # source, the path dependency graph and the Cargo configuration), so an
    # edited crate rebuilds instead of reusing an artifact of its old self; the
    # interpreter's path *and* fingerprint are added, as the `.link_libpython`
    # wrapper keys them.
    key = compute_crate_hash(info; release = release, kind = "pyo3-host",
                             features = features, default_features = default_features,
                             build_env = _pyo3_host_build_env(snapshot, python, fingerprint,
                                                              module_name),
                             snapshot = snapshot)
    # Its own tree, not the Cargo cache: an extension module is not a cached
    # cdylib, and `test_cargo` asserts the Cargo cache holds exactly one entry
    # (#287). Both `clear_cache()` and this directory's owner are one place.
    # Named by a short name, not the whole key; `build_pyo3_extension` claims it
    # for the full key before it looks inside (#504).
    dir = short_name_path(joinpath(String(cache_dir), "pyo3-host"), key)
    lib_path = joinpath(dir, String(module_name) * String(ext_suffix))
    return PyO3Extension(String(module_name), lib_path, dir, String(ext_suffix),
                         String(python), String(fingerprint), key)
end

"""
    _pyo3_host_build_env(python, fingerprint, module_name) -> Vector{Pair{String, String}}

The build environment the host-path extension is keyed by: `artifact_build_env()`
— `RUSTFLAGS`, a build script's `CC` and the rest of the #282 allowlist, which
decide what `cargo rustc` produces exactly as they do for the plain crate path
and the PyO3 wrapper — plus the contents of `PYO3_CONFIG_FILE` when it is set,
then the interpreter the build is configured for and the module name. Without the
allowlist a changed `RUSTFLAGS` found the previous extension in the cache (#461).

The ambient `PYO3_PYTHON` is left out of the allowlist half: the build sets it
to `python` itself, which the key records under the same name. Reading only the
environment and a file, this starts no process, so the precompile workload can
compute it (#449).
"""
_pyo3_host_build_env(python::AbstractString, fingerprint::AbstractString,
                     module_name::AbstractString) =
    _pyo3_host_build_env(BuildEnvSnapshot(), python, fingerprint, module_name)

function _pyo3_host_build_env(snapshot::BuildEnvSnapshot, python::AbstractString,
                              fingerprint::AbstractString, module_name::AbstractString)
    build_env = filter(p -> first(p) != "PYO3_PYTHON",
                       artifact_build_env(; env = snapshot_env(snapshot)))
    digest = _pyo3_config_file_digest(snapshot)
    isempty(digest) || push!(build_env, "pyo3-config-file-digest" => digest)
    append!(build_env, Pair{String, String}[
        "PYO3_PYTHON" => String(python),
        "interpreter-fingerprint" => String(fingerprint),
        "module" => String(module_name)])
    return build_env
end

# The `#[pymodule]` initializer's Python name: `name = "..."` when given,
# otherwise the function's own name. A lenient scan, deliberately: the marker is
# what is wanted, and deciding it under a feature set would mean the plan
# machinery this path exists to avoid.
_pyo3_extension_module_name(crate_path::AbstractString) =
    _pyo3_extension_module_name(scan_crate(String(crate_path)))

function _pyo3_extension_module_name(info::CrateInfo)
    for f in info.pyo3_functions
        f.attribute === :py_module || continue
        return isempty(f.python_name) ? String(f.name) : String(f.python_name)
    end
    return ""
end

# `sysconfig.get_config_var('EXT_SUFFIX')` of `python`; "" when it cannot run.
# Unlike `_python_interpreter_fingerprint` this value names the artifact, so the
# caller must treat "" as a refusal rather than guess a suffix.
function _pyo3_extension_ext_suffix(python::AbstractString)
    code = "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX') or '')"
    try
        return String(strip(read(`$python -c $code`, String)))
    catch
        return ""
    end
end

# `EXT_SUFFIX` and `_python_interpreter_fingerprint` of `python` from **one**
# interpreter start rather than two: on the host path both are needed on every
# call, cached artifact or not, and a CPython start is 20–40 ms of the first
# call's time once nothing is left to compile (#449). `("", "")` when the
# interpreter cannot run; the fingerprint line uses the same expression as
# `_python_interpreter_fingerprint`, so the two spellings of one interpreter
# are equal and the cache key does not depend on which probe filled it.
_pyo3_extension_interpreter_probe(python::AbstractString) =
    _pyo3_extension_interpreter_probe(BuildEnvSnapshot(), python)

function _pyo3_extension_interpreter_probe(snapshot::BuildEnvSnapshot, python::AbstractString)
    isempty(python) && return ("", "")
    code = "import platform, sys, sysconfig; " *
           "print(sysconfig.get_config_var('EXT_SUFFIX') or ''); " *
           "print($(_PYTHON_FINGERPRINT_EXPR))"
    out = try
        read(snapshot_cmd(snapshot, `$python -c $code`), String)
    catch
        return ("", "")
    end
    lines = split(out, '\n')
    length(lines) >= 2 || return ("", "")
    return (String(strip(lines[1])), String(strip(lines[2])))
end

# `[lib] name` when set, otherwise Cargo's default: the package name with `-`
# replaced by `_`. This is the stem Cargo puts in the file name.
function _crate_lib_name(cargo_toml::AbstractDict)
    lib = get(cargo_toml, "lib", nothing)
    if lib isa AbstractDict
        name = get(lib, "name", nothing)
        name === nothing || return String(name)
    end
    package = get(cargo_toml, "package", Dict{String, Any}())
    return replace(String(get(package, "name", "")), "-" => "_")
end

# What Cargo names a cdylib on this platform.
function _pyo3_extension_filename(lib_name::AbstractString)
    Sys.iswindows() && return "$(lib_name).dll"
    Sys.isapple() && return "lib$(lib_name).dylib"
    return "lib$(lib_name).so"
end

# The extension-module link flags the *final* cdylib needs. pyo3's build script
# emits `cargo:rustc-cdylib-link-arg`, which applies to pyo3's own build and not
# to a crate that merely depends on it — nor to the target crate's own cdylib
# link, since the directive belongs to the package that emitted it. maturin
# passes these itself for exactly this reason. On macOS the undefined Python
# data symbols (`_PyBaseObject_Type`, `PyExc_*`) bind eagerly, so the dynamic
# lookup is required; ELF and PE need nothing here.
function _pyo3_extension_link_args()
    Sys.isapple() || return String[]
    return String["-C", "link-arg=-undefined", "-C", "link-arg=dynamic_lookup"]
end

"""
    _pyo3_host_cargo_cmd(snapshot, crate_path, cargo_toml; python, features,
                         default_features, release, rustc_args) -> (Cmd, target_dir, package)

The one Cargo invocation of the PyO3 host path: `cargo rustc --crate-type
cdylib` of the crate as its own root, under the requested profile and features,
in RustCall's target directory for it, under `snapshot` with `PYO3_PYTHON` set
to the interpreter the module is built for. `rustc_args` follow `--`. The build
(`_build_pyo3_extension_library`, with the link arguments) and the cfg probe
the bindings are scanned under (`_pyo3_host_cfg_text`, with `--print cfg`) are
both this command, so the scan sees the `#[cfg]`s the build compiles — the
profile's `debug_assertions`, the interpreter's Python-version cfgs — and the
two cannot drift (#514 review). An empty `python` leaves `PYO3_PYTHON` as the
snapshot has it (a scan outside the host extension).
"""
function _pyo3_host_cargo_cmd(snapshot::BuildEnvSnapshot, crate_path::AbstractString,
                              cargo_toml::AbstractDict; python::AbstractString,
                              features::Vector{String} = String[],
                              default_features::Bool = true, release::Bool = true,
                              rustc_args::Vector{String} = String[])
    package = String(get(get(cargo_toml, "package", Dict{String, Any}()), "name", ""))
    isempty(package) && throw(RustError(
        "`$(crate_path)` has no `[package] name`, so Cargo cannot select it."))

    args = String["rustc"]
    release && push!(args, "--release")
    push!(args, "-p", package, "--crate-type", "cdylib")
    default_features || push!(args, "--no-default-features")
    isempty(features) || push!(args, "--features", join(features, ","))

    # Under RustCall's cache, never the crate's own `target/`: an installed
    # package is read-only, and every `@rust_crate` flavour builds where
    # `crate_target_directory` says (#486). An ambient `CARGO_TARGET_DIR`
    # would send the library somewhere this function never looks, so it is
    # pinned as `build_cargo_project` does.
    target_dir = _crate_target!(crate_path, :pyo3_host)
    env = snapshot_env(snapshot)
    isempty(python) || (env["PYO3_PYTHON"] = String(python))
    env["CARGO_TARGET_DIR"] = target_dir

    # `--offline` under `RUSTCALL_OFFLINE`, as every other build (#461).
    append!(args, _cargo_network_args(env))
    # In the crate's directory through the command's `dir`, never a
    # process-wide `cd`, which would move every other task's relative paths
    # for the length of the build (#461).
    cmd = setenv(isempty(rustc_args) ? `$(cargo()) $args` : `$(cargo()) $args -- $rustc_args`,
                 env; dir = String(crate_path))
    return cmd, target_dir, package
end

"""
    _pyo3_host_cfg_text(snapshot, crate_path, cargo_toml; python, features,
                        default_features, release) -> String

`rustc --print cfg` of the host build (`_pyo3_host_cargo_cmd`), for the scan the
host bindings are generated from; `""` when Cargo does not answer, and the
lenient scan is used instead.
"""
function _pyo3_host_cfg_text(snapshot::BuildEnvSnapshot, crate_path::AbstractString,
                             cargo_toml::AbstractDict; python::AbstractString,
                             features::Vector{String} = String[],
                             default_features::Bool = true, release::Bool = true)
    try
        cmd, _, _ = _pyo3_host_cargo_cmd(snapshot, crate_path, cargo_toml; python = python,
                                         features = features,
                                         default_features = default_features,
                                         release = release,
                                         rustc_args = ["--print", "cfg"])
        return _printed_cfg_lines(read(pipeline(cmd; stderr = devnull), String))
    catch e
        @debug "Could not probe the host build cfg of $(crate_path)" exception = e
        return ""
    end
end

"""
    _build_pyo3_extension_library([snapshot,] crate_path, cargo_toml, module_name; kwargs...) -> String

Run `cargo rustc --crate-type cdylib` in the crate's own directory, with the
output under `crate_target_directory(crate_path, :pyo3_host)` (#486), and return
the built extension file, which is a temporary Cargo output — copy it out
before the next build replaces it. It runs under `snapshot` (the build's, from
`build_pyo3_extension`); the form without one takes a snapshot of `ENV` now.
"""
_build_pyo3_extension_library(crate_path::AbstractString, cargo_toml::AbstractDict,
                              module_name::AbstractString; kwargs...) =
    _build_pyo3_extension_library(BuildEnvSnapshot(), crate_path, cargo_toml, module_name;
                                  kwargs...)

function _build_pyo3_extension_library(snapshot::BuildEnvSnapshot,
                                       crate_path::AbstractString, cargo_toml::AbstractDict,
                                       module_name::AbstractString;
                                       python::AbstractString,
                                       features::Vector{String} = String[],
                                       default_features::Bool = true,
                                       release::Bool = true)
    cmd, target_dir, package = _pyo3_host_cargo_cmd(
        snapshot, crate_path, cargo_toml; python = python, features = features,
        default_features = default_features, release = release,
        rustc_args = _pyo3_extension_link_args())
    stderr_io = IOBuffer()
    stdout_io = IOBuffer()
    proc = run(pipeline(cmd, stdout = stdout_io, stderr = stderr_io), wait = false)
    wait(proc)
    ok = success(proc)
    if !ok
        stderr_str = String(take!(stderr_io))
        close(stderr_io); close(stdout_io)
        throw(CargoBuildError(
            "Building `$(package)` as a Python extension module failed", stderr_str, crate_path))
    end
    close(stderr_io); close(stdout_io)

    lib_name = _crate_lib_name(cargo_toml)
    profile_dir = release ? "release" : "debug"
    built = joinpath(target_dir, profile_dir, _pyo3_extension_filename(lib_name))
    isfile(built) || throw(RustError(
        "Cargo reported success but `$(built)` is missing. The crate's `[lib] name` " *
        "(`$(lib_name)`) or its `crate-type` may differ from what the host path expects."))
    return built
end

# ============================================================================
# Phase 2: typed Julia bindings over the imported module (#424)
# ============================================================================
#
# The surface is generated from the same manifest the scan already produces, but
# nothing is lowered to a C ABI: every binding calls the Python module. A
# `PyResult` becomes `RustResult{T, String}` carrying the **interpreter's own**
# message — the C-ABI path's opaque `PYO3_OPAQUE_ERROR` exists only because that
# path has no interpreter to render a `PyErr` with.
#
# Field access goes through the Python object, not the manifest's wrapper
# symbols. `#[pyo3(get)]` / `#[pyo3(set)]` install a descriptor inside the crate,
# so it works for a private field and for a private struct — exactly the cases
# the manifest's `getter`/`setter` symbols are blank for. A field PyO3 does not
# expose raises at access, as it would in Python.

# Every value crosses the boundary by what it **is** at run time, never by the
# Rust spelling of its position (PR #525 review): the generated module's
# `_pyo3_to_python` hands Python a class handle's Python object, a Julia array
# of numbers as a numpy array (when numpy is importable) and anything else as it
# is; `_pyo3_from_python` reads Python `None` back as `nothing` and an object of
# one of the module's classes as that class's Julia handle. The extractor's
# `PyO3Shape` (manifest `py_shape` / `py_return`) is a hint and nothing more: it
# chooses the Julia type an otherwise unconverted value is read back as, and a
# value that does not fit it stays the Python object it is. The one thing the
# host takes from it is which arguments the interpreter supplies (`:injected`).

# A function, not a `const Dict`: a module-level mutable registry is what
# `test_state.jl`'s guard forbids (#251), and this table never changes.
function _pyo3_host_scalar_type(t::AbstractString)
    t == "i8" && return :Int8
    t == "i16" && return :Int16
    t == "i32" && return :Int32
    t == "i64" && return :Int64
    t == "isize" && return :Int
    t == "u8" && return :UInt8
    t == "u16" && return :UInt16
    t == "u32" && return :UInt32
    t == "u64" && return :UInt64
    t == "usize" && return :UInt
    t == "f32" && return :Float32
    t == "f64" && return :Float64
    t == "bool" && return :Bool
    return nothing
end

"""
    _pyo3_host_required_shape(shape, what) -> PyO3Shape

The hint of a PyO3 position, or a `RustError` when the manifest carries none:
every position of a scanned PyO3 item has one, and without it the host cannot
tell an argument the interpreter supplies from one the caller passes, so a
missing one means the extractor predates it.
"""
function _pyo3_host_required_shape(shape::Union{Nothing, PyO3Shape}, what::AbstractString)
    shape === nothing || return shape
    throw(RustError("the manifest describes no PyO3-host shape for $what; the rustcall-extract " *
                    "binary predates it. Rebuild it with `Pkg.build(\"RustCall\")` " *
                    "(or `julia --project deps/build.jl` in a checkout)."))
end

"""
    _pyo3_host_read_type(shape) -> Union{Symbol, Expr}

The Julia type the hint says a value is read back as, `:Any` for "whatever it
is": a scalar's Julia type, `String`, a `Vector` of the element's hint, a numpy
array by its element and rank. An `Option` is its payload's hint: `None` is
`nothing` whatever the hint (`_pyo3_from_python`).
"""
function _pyo3_host_read_type(shape::PyO3Shape)
    kind = shape.kind
    kind === :unit && return :Nothing
    kind === :scalar && return something(_pyo3_host_scalar_type(shape.name), :Any)
    kind === :string && return :String
    kind === :vec && return :(Vector{$(_pyo3_host_read_type(shape.inner))})
    kind === :option && return _pyo3_host_read_type(shape.inner)
    if kind === :array
        element = _pyo3_host_scalar_type(shape.name)
        element === nothing && return :Any
        shape.rank == 0 && return element
        shape.rank == 1 && return :(Vector{$element})
        shape.rank == 2 && return :(Matrix{$element})
        return :(Array{$element})
    end
    return :Any
end

# The `T` of the `RustResult{T, String}` a `PyResult` return is reported as:
# the hint, with `Nothing` admitted for an `Option`. A value outside it is
# reported under `Any` (`_pyo3_ok`), so the hint never fails a call.
function _pyo3_host_result_type(shape::PyO3Shape)
    jt = _pyo3_host_read_type(shape)
    jt === :Any && return :Any
    shape.kind === :option && return :(Union{Nothing, $jt})
    return jt
end

"""
    _pyo3_host_value_expr(call, shape) -> Expr

The call's result read back — the one decision for every value the host reads:
a function's or a method's return and a property's read (`getproperty`).
`_pyo3_from_python` decides by the value (`None`, an object of a bound class);
the hint only types what is left.
"""
function _pyo3_host_value_expr(call, shape::PyO3Shape)
    jt = _pyo3_host_read_type(shape)
    jt === :Any && return :(_pyo3_from_python($call))
    return :(_pyo3_from_python($call, $jt))
end

_pyo3_host_attr(base, name::AbstractString) = Expr(:., base, QuoteNode(Symbol(name)))

# The Python attribute of an item: the manifest's `python_name` — which the
# extractor also fills for a raw Rust name, `r#for` being exposed as `for`
# (#514) — or the Rust name (`rust_name`: PyO3 drops a raw identifier's `r#`).
_pyo3_host_python_name(name, python_name) =
    isempty(python_name) ? rust_name(name) : String(python_name)

# `(arg symbols, signature entries, call expressions, has-default flags)` for
# the positional prefix, with the arguments the interpreter supplies
# (`:injected`) dropped and the list stopped at the first keyword-only
# parameter (a keyword-only argument cannot be forwarded positionally, which is
# all this emitter does). Every argument is untyped and handed over by
# `_pyo3_to_python`: Python checks it, as it would a Python caller's.
function _pyo3_host_args(arg_names, shapes, python_defaults, python_kinds;
                         drop_leading::Bool = false, what = "")
    syms = Symbol[]
    sig = Any[]
    conv = Any[]
    defaults = Bool[]
    for (i, name) in enumerate(arg_names)
        # A `#[classmethod]`'s first argument is the class Python passes; it is
        # not part of the Julia signature (#424).
        drop_leading && i == 1 && continue
        shape = _pyo3_host_required_shape(shapes[i], "argument `$name` of $what")
        shape.kind === :injected && continue
        kind = i <= length(python_kinds) ? String(python_kinds[i]) : ""
        kind == "keyword_only" && break
        sym = Symbol(name)
        push!(sig, sym)
        push!(conv, :(_pyo3_to_python($sym)))
        push!(defaults, i <= length(python_defaults) && !isempty(python_defaults[i]))
        push!(syms, sym)
    end
    return syms, sig, conv, defaults
end

# One `function` definition, shaped by the return kind. `:py_result` catches the
# interpreter's exception and reports it as the `Err` payload. A constructor
# (`construct`, the class's Julia type) wraps what `#[new]` returns: an object
# of that class, by what a constructor is.
function _pyo3_host_single_def(name::Symbol, sig::Vector{Any}, call::Expr, return_kind::Symbol,
                               shape::PyO3Shape, construct::Union{Nothing, Symbol})
    if return_kind === :py_result
        valued = construct === nothing ? _pyo3_host_value_expr(call, shape) : :($construct($call))
        jt = construct === nothing ? _pyo3_host_result_type(shape) : construct
        body = quote
            try
                return _pyo3_ok($valued, $jt)
            catch rustcall′err
                rustcall′err isa PythonCall.PyException || rethrow()
                return RustCall.RustResult{$jt, String}(false, sprint(showerror, rustcall′err))
            end
        end
        return Expr(:function, Expr(:call, name, sig...), body)
    elseif return_kind === :unit || shape.kind === :unit
        body = quote
            $call
            return nothing
        end
        return Expr(:function, Expr(:call, name, sig...), body)
    else
        valued = construct === nothing ? _pyo3_host_value_expr(call, shape) : :($construct($call))
        return Expr(:function, Expr(:call, name, sig...), Expr(:block, valued))
    end
end

# One definition per *arity* the call accepts: PyO3's trailing defaults are
# supplied by its own dispatcher, so a call passes only the arguments the caller
# gave and the generated method for that arity forwards exactly those. Without
# this `Index(2)` matched only the struct's inner constructor and failed
# (`#[pyo3(signature = (dim, tags = None, plev = 0))]`).
function _pyo3_host_defs(name::Symbol, fixed_sig::Vector{Any}, var_sig::Vector{Any},
                         var_conv::Vector{Any}, defaults::Vector{Bool}, callof,
                         return_kind::Symbol, shape::PyO3Shape;
                         construct::Union{Nothing, Symbol} = nothing)
    count = length(var_sig)
    first_default = findfirst(identity, defaults)
    minarity = first_default === nothing ? count : first_default - 1
    out = Any[]
    for arity in minarity:count
        call = callof(var_conv[1:arity])
        push!(out, _pyo3_host_single_def(name, vcat(copy(fixed_sig), var_sig[1:arity]), call,
                                         return_kind, shape, construct))
    end
    return out
end

# The Python attribute expression of an item reached under a declarative
# module path: `module.inner.g`; a function-form or direct item is `module.g`
# (#424).
function _pyo3_host_python_attr(base, python_path, python_name::AbstractString)
    for segment in python_path
        base = _pyo3_host_attr(base, segment)
    end
    return _pyo3_host_attr(base, python_name)
end

function _pyo3_host_function_expr(f::RustFunctionSignature)
    what = "the function `$(qualified_name(f.module_path, f.name))`"
    _, sig, conv, defaults = _pyo3_host_args(f.arg_names, f.py_arg_shapes,
                                             f.python_defaults, f.python_kinds; what)
    python = _pyo3_host_python_name(f.name, f.python_name)
    base = _pyo3_host_python_attr(:(_pyo3_module()), f.python_path, python)
    callof = convs -> Expr(:call, base, convs...)
    shape = _pyo3_host_required_shape(f.py_return_shape, "the return of $what")
    return _pyo3_host_defs(Symbol(julia_function_name(f)), Any[], sig, conv, defaults, callof,
                           f.return_kind, shape)
end

# The Python class object of a scanned class: an attribute of the imported
# module, under its declarative module path when it has one.
_pyo3_host_class_base(s::RustStructInfo) =
    _pyo3_host_python_attr(:(_pyo3_module()), s.python_path,
                           _pyo3_host_python_name(s.name, s.python_name))

# `class_base` is the expression for the class object itself (with the
# declarative module path, when any); a constructor calls it, a static or class
# method calls an attribute of it, and an instance method calls an attribute of
# the Python object the Julia handle holds.
function _pyo3_host_method_expr(jname::Symbol, class_base::Expr, m::RustMethod)
    what = "the method `$(m.name)` of `$jname`"
    _, sig, conv, defaults = _pyo3_host_args(m.arg_names, m.py_arg_shapes,
                                             m.python_defaults, m.python_kinds;
                                             drop_leading = m.is_classmethod, what)
    python = _pyo3_host_python_name(m.name, m.python_name)
    shape = _pyo3_host_required_shape(m.py_return_shape, "the return of $what")
    if m.is_constructor
        callof = convs -> Expr(:call, class_base, convs...)
        return _pyo3_host_defs(jname, Any[], sig, conv, defaults, callof,
                               m.return_kind, shape; construct = jname)
    elseif m.is_static || m.is_classmethod
        # `#[classmethod]`'s class argument is dropped above: Python's bound
        # descriptor supplies it (#424).
        base = _pyo3_host_attr(class_base, python)
        callof = convs -> Expr(:call, base, convs...)
        return _pyo3_host_defs(Symbol(julia_method_name(m)), Any[], sig, conv, defaults, callof,
                               m.return_kind, shape)
    else
        # An instance method: the object is the first Julia argument, and the
        # Python object it holds is the receiver. A `&mut self` method mutates
        # that same object, so no extra step is needed.
        receiver = _pyo3_host_attr(:(getfield(rustcall′obj, $(QuoteNode(_PYO3_HOST_HANDLE_FIELD)))), python)
        callof = convs -> Expr(:call, receiver, convs...)
        return _pyo3_host_defs(Symbol(julia_method_name(m)), Any[:(rustcall′obj::$jname)], sig, conv, defaults,
                               callof, m.return_kind, shape)
    end
end

# Whether PyO3 exposes a getter / setter for the field, per the manifest. A
# manifest from before `Field.pyo3_get` (schema 0.6 additive, #424) records
# neither, so an absent column keeps the previous "every listed field is
# readable and writable" behaviour.
_pyo3_host_field_readable(s::RustStructInfo, field::AbstractString) =
    isempty(s.field_pyo3_get) || get(s.field_pyo3_get, String(field), false)

_pyo3_host_field_writable(s::RustStructInfo, field::AbstractString) =
    isempty(s.field_pyo3_set) || get(s.field_pyo3_set, String(field), false)

"""
    PyO3HostProperty

One property the PyO3 host binds on a class (#524): a `#[pyo3(get)]` /
`#[pyo3(set)]` field, or the `#[getter]` / `#[setter]` methods of one Python
attribute, merged by that attribute. `python` is the attribute PyO3 exposes (the
manifest's `python_name`: `#[getter(end)]`, `#[pyo3(get, name = "x")]`, a
`get_` / `set_` prefix dropped, a raw `r#for` unrawed); `julia` is the name
Julia reads it under, `julia_binding_name` of that attribute (`for` → `for_`).
`read_shape` is the hint of the value a read returns (`nothing` when nothing
reads it); a read is converted as a method's return is
(`_pyo3_host_value_expr`), a write as a method's argument is
(`_pyo3_to_python`), by the value (PR #525 review). `what` names the Rust item
in a message.
"""
struct PyO3HostProperty
    python::String
    julia::String
    readable::Bool
    writable::Bool
    read_shape::Union{Nothing, PyO3Shape}
    what::String
end

# The Julia name of a property. A Python attribute that is no Julia identifier
# at all (`#[getter(name = "a-b")]`) is kept as it is — reachable as
# `getproperty(obj, Symbol("a-b"))`, as the attribute itself was before #524 —
# rather than refusing the crate over a name Julia never has to spell.
function _pyo3_host_property_julia_name(python::AbstractString)
    return try
        julia_binding_name(python)
    catch err
        err isa ErrorException || rethrow()
        String(python)
    end
end

"""
    _pyo3_host_bound_properties(s::RustStructInfo) -> Vector{PyO3HostProperty}

The properties the host binds on `s`, the one list its property emitter
(`getproperty`, `setproperty!`, `propertynames`) and its definitions
(`_pyo3_host_definitions`) are read from (#524): every field PyO3 exposes, then
every `#[getter]` / `#[setter]` method, merged by the Python attribute they
expose — a getter and a setter of one attribute are one property, readable and
writable. `async` accessors are refused by the extractor and bound nowhere.
"""
function _pyo3_host_bound_properties(s::RustStructInfo)
    order = String[]
    found = Dict{String, PyO3HostProperty}()
    add!(python, read_shape, readable, writable, what) = begin
        prior = get(found, python, nothing)
        if prior === nothing
            push!(order, python)
            found[python] = PyO3HostProperty(python, _pyo3_host_property_julia_name(python),
                                             readable, writable, read_shape, what)
        else
            found[python] = PyO3HostProperty(
                python, prior.julia, prior.readable || readable, prior.writable || writable,
                something(prior.read_shape, read_shape, Some(nothing)), prior.what)
        end
    end
    owner = qualified_name(s.module_path, s.name)
    for (field, _) in s.fields
        readable = _pyo3_host_field_readable(s, field)
        writable = _pyo3_host_field_writable(s, field)
        (readable || writable) || continue
        python = _pyo3_host_python_name(field, get(s.field_python_names, field, ""))
        what = "the field `$owner.$field`"
        shape = _pyo3_host_required_shape(get(s.field_py_shapes, field, nothing), what)
        add!(python, readable ? shape : nothing, readable, writable, what)
    end
    for m in s.methods
        (isempty(m.accessor) || _pyo3_host_async(m)) && continue
        getter = m.accessor == "getter"
        # A getter's value is its return (a `PyResult`'s `Ok` type), as for any
        # method.
        what = "the $(m.accessor) `$(_boundary_label(s, m))`"
        read_shape = getter ? _pyo3_host_required_shape(m.py_return_shape, what) : nothing
        add!(_pyo3_host_python_name(m.name, m.python_name), read_shape, getter, !getter, what)
    end
    return PyO3HostProperty[found[p] for p in order]
end

# `#[pyo3(get)]` / `#[pyo3(set)]` and `#[getter]` / `#[setter]` install a
# descriptor inside the crate, so the object answers; the manifest says which
# directions PyO3 exposed (#424). Every branch comes from
# `_pyo3_host_bound_properties` (#524), and every value crosses as a method's
# would (PR #525 review): a read through `_pyo3_host_value_expr`, a write
# through `_pyo3_to_python`.
function _pyo3_host_property_expr(jname::Symbol, s::RustStructInfo)
    properties = _pyo3_host_bound_properties(s)
    attr(p) = QuoteNode(Symbol(p.python))
    # After the remapping below `s` is the Python attribute. Only a typed hint
    # needs a branch of its own; any other value is read back by what it is.
    conversions = Any[]
    for p in properties
        p.readable || continue
        p.read_shape === nothing && continue
        valued = _pyo3_host_value_expr(:rustcall′v, p.read_shape)
        valued == :(_pyo3_from_python(rustcall′v)) && continue
        push!(conversions, :(rustcall′s === $(attr(p)) && return $valued))
    end
    # A property is read under its Julia name (`for_`); the Python attribute
    # (`for`) is looked up. Only a property the host binds is remapped: an
    # unexposed raw `r#for` beside an exposed `for_` must leave `obj.for_`
    # alone (PR #515 review).
    names = Tuple(Symbol(p.julia) for p in properties if p.readable)
    renamed = Any[]
    for p in properties
        p.julia == p.python && continue
        push!(renamed, :(rustcall′s === $(QuoteNode(Symbol(p.julia))) && (rustcall′s = $(attr(p)))))
    end
    # A read-only property raises a Julia error naming it instead of the raw
    # Python `AttributeError` a descriptor would.
    read_only = Any[]
    for p in properties
        p.writable && continue
        push!(read_only,
              :(rustcall′s === $(attr(p)) &&
                throw(ArgumentError($(string("property `", p.julia, "` is read-only"))))))
    end
    handle = QuoteNode(_PYO3_HOST_HANDLE_FIELD)
    # The generated locals are the emitter's own (`rustcall′...`, PR #527
    # review), which no property or crate item can spell.
    getbody = quote
        rustcall′s === $handle && return getfield(rustcall′p, $handle)
        $(renamed...)
        rustcall′v = PythonCall.pygetattr(getfield(rustcall′p, $handle), String(rustcall′s))
        $(conversions...)
        return _pyo3_from_python(rustcall′v)
    end
    setbody = quote
        rustcall′s === $handle && throw(ArgumentError($(string(_PYO3_HOST_HANDLE_FIELD, " is not assignable"))))
        $(renamed...)
        $(read_only...)
        PythonCall.pysetattr(getfield(rustcall′p, $handle), String(rustcall′s), _pyo3_to_python(rustcall′v))
        return rustcall′v
    end
    return quote
        function Base.getproperty(rustcall′p::$jname, rustcall′s::Symbol)
            $getbody
        end
        function Base.setproperty!(rustcall′p::$jname, rustcall′s::Symbol, rustcall′v)
            $setbody
        end
        Base.propertynames(::$jname) = $names
    end
end

# The host path cannot await. An `async fn` binding would hand Julia the
# interpreter's coroutine object, which never runs unless an event loop drives
# it; the extractor already refuses the item (`async_fn`), and the generator
# honours that rather than emitting a silently-unawaited binding (#424).
_pyo3_host_async(f::RustFunctionSignature) =
    partition_skip_reason(f.skip_reason)[1] == "async_fn"
_pyo3_host_async(m::RustMethod) = partition_skip_reason(m.skip_reason)[1] == "async_fn"

function _pyo3_host_struct_exprs(s::RustStructInfo)
    jname = Symbol(julia_struct_name(s))
    class_base = _pyo3_host_class_base(s)
    # An explicit inner constructor suppresses the constructors Julia would
    # otherwise synthesize for this one-field struct — including the untyped
    # `Class(x)` a one-argument `#[new]` mapping to `Any` (`Py<PyAny>`, a
    # class-typed argument) would overwrite, which is a hard error during
    # module precompilation (#433). The wrapping path still needs
    # `Class(::PythonCall.Py)`, which the field type gives it, and defining an
    # inner constructor also means any outer constructor the emitter adds is a
    # new method rather than a redefinition. Every class type is a
    # `_PyO3Object`, which is how `_pyo3_to_python` knows a handle by its value.
    field = Expr(:(::), _PYO3_HOST_HANDLE_FIELD, :(PythonCall.Py))
    # The constructor's parameter is a local of the emitter's own (PR #527
    # review); the field keeps its name.
    handle = _emitter_local("py")
    inner = Expr(:(=), Expr(:call, jname, Expr(:(::), handle, :(PythonCall.Py))),
                 Expr(:call, :new, handle))
    out = Any[Expr(:struct, false, :($jname <: _PyO3Object), Expr(:block, field, inner))]
    # The methods the host binds (`_pyo3_host_bound_methods`, the list its
    # definitions are read from): constructors first. `#[getter]`/`#[setter]`
    # methods are Python properties (`_pyo3_host_bound_properties`), so they
    # are not bound as functions.
    methods = _pyo3_host_bound_methods(s)
    for m in methods
        m.is_constructor || continue
        append!(out, _pyo3_host_method_expr(jname, class_base, m))
    end
    push!(out, _pyo3_host_property_expr(jname, s))
    for m in methods
        m.is_constructor && continue
        append!(out, _pyo3_host_method_expr(jname, class_base, m))
    end
    return out
end

# The module's `_pyo3_class_pairs()`: each bound class's Julia type beside its
# Python class object, the table `_pyo3_from_python` recognises a returned
# object's type in (read once, at the first conversion that needs it).
function _pyo3_host_class_table_expr(info::CrateInfo)
    pairs = Any[Expr(:tuple, Symbol(julia_struct_name(s)), _pyo3_host_class_base(s))
                for s in _pyo3_host_bound_classes(info)]
    return :(function _pyo3_class_pairs()
                 return $(Expr(:tuple, pairs...))
             end)
end

"""
    _pyo3_host_definitions(info::CrateInfo) -> Vector{JuliaDefinition}

What `generate_pyo3_host_bindings` defines at the top level of its module,
item by item as its emitters define it (#514): a `#[pyfunction]` and a static
or class method are free functions of untyped arguments (the host passes no
type), a class is a type whose `#[new]` is its constructor, an instance method
dispatches on its class, and each of `_pyo3_host_bound_properties` — an exposed
field or the `#[getter]` / `#[setter]` methods of one attribute — is a property
under its Julia name (#524). `async` items define nothing.
"""
function _pyo3_host_definitions(info::CrateInfo)
    defs = JuliaDefinition[]
    add!(name, scope, owner; what = owner, parent = "") =
        push!(defs, JuliaDefinition(name, scope, owner, what, parent))
    # What the emitter defines for itself comes first and is taken whole: every
    # module-level name of its prelude, read off the prelude (with the numpy
    # helper, so the set does not depend on the crate), and each class type's
    # handle field (PR #525 review).
    prelude = _pyo3_host_prelude_exprs("", String[], true, true)
    for name in _pyo3_host_defined_names(prelude)
        add!(name, :binding, "the generated module's own `$name`")
    end
    for f in _pyo3_host_bound_functions(info)
        add!(julia_function_name(f), :free,
             "the function `$(qualified_name(f.module_path, f.name))`")
    end
    for s in _pyo3_host_bound_classes(info)
        T = julia_struct_name(s)
        owner = "the struct `$(qualified_name(s.module_path, s.name))`"
        add!(T, :binding, owner)
        handle = String(_PYO3_HOST_HANDLE_FIELD)
        add!(handle, (:prop, T), "the generated type's handle field `$T.$handle`"; parent = T)
        for m in _pyo3_host_bound_methods(s)
            what = "the method `$(_boundary_label(s, m))`"
            if m.is_constructor
                add!(T, :free, owner; what, parent = T)
            elseif m.is_static || m.is_classmethod
                add!(julia_method_name(m), :free, what; parent = T)
            else
                add!(julia_method_name(m), (:self, T), what; parent = T)
            end
        end
        # One definition per property, whatever items make it up: a getter and
        # a setter of one attribute are one owner; two attributes one Julia
        # name would read (`for` and `for_`) are refused (#524).
        for p in _pyo3_host_bound_properties(s)
            add!(p.julia, (:prop, T), p.what; parent = T)
        end
    end
    return defs
end

# What the host binds, item by item: the one list its emitters iterate and its
# definitions (`_pyo3_host_definitions`) are read from (#514). `async` items
# are refused by the extractor (`async_fn`) and bound nowhere; `#[getter]` /
# `#[setter]` methods are Python properties, bound with the fields in
# `_pyo3_host_bound_properties`.
_pyo3_host_bound_functions(info::CrateInfo) =
    [f for f in info.pyo3_functions if f.attribute === :py_function && !_pyo3_host_async(f)]
_pyo3_host_bound_classes(info::CrateInfo) =
    [s for s in info.pyo3_structs if s.attribute === :py_class]
_pyo3_host_bound_methods(s::RustStructInfo) =
    [m for m in s.methods if !_pyo3_host_async(m) && (m.is_constructor || isempty(m.accessor))]

"""
    _pyo3_host_check_names(info::CrateInfo)

`_check_julia_definitions` over `_pyo3_host_definitions`: the check every
emitter runs, over what this one defines.
"""
function _pyo3_host_check_names(info::CrateInfo)
    _check_julia_definitions(_pyo3_host_definitions(info),
                             "the PyO3 host bindings of `$(info.name)`")
    return nothing
end

# The name of the one field of every generated class type: the Python object
# the Julia handle holds. `getproperty` answers it before any property, so it
# is a property of the type the emitter defines for itself, and a Rust item
# bound under it is refused (`_pyo3_host_definitions`, PR #525 review).
const _PYO3_HOST_HANDLE_FIELD = :_rustcall_py

"""
    _pyo3_host_prelude_exprs(path, features, default_features, release) -> Vector{Any}

What `generate_pyo3_host_bindings` defines at the top of its module before any
binding: the imports, the build constants, the lazy import `_pyo3_module`, and
the value conversions every binding goes through (PR #525 review):

* `_pyo3_to_python(x)` — a class handle (`_PyO3Object`) is the Python object it
  holds; a Julia array of numbers is a `numpy.ndarray` when numpy imports
  (pyo3-numpy extracts from nothing else, #424, and PyO3 reads a `Vec` from one
  as from any sequence); another array or a tuple is converted element by
  element; anything else is passed as it is (`nothing` is `None`).
* `_pyo3_from_python(v[, T])` — `None` is `nothing`; an object is the Julia
  handle of the most derived of the module's classes (`_pyo3_class_pairs`,
  emitted after them) in its type's MRO — its own class first, so a
  `#[pyclass(extends = ...)]` object stays itself and an instance of a
  Python-defined subclass is its nearest bound base. The walk is not cached:
  a cache keyed by the type object would keep every type it saw alive, and
  the walk is a few identity comparisons; anything else is `pyconvert`ed to the hint `T` when it
  fits and stays the Python object when it does not. A list read as
  `Vector{T}` is read element by element, so a list of class objects is a
  vector of handles.
* `_pyo3_ok(v, T)` — the `Ok` of a `PyResult`, typed `T` when the value is one.

The names it defines are reserved (`_pyo3_host_defined_names`, read by
`_pyo3_host_definitions`), so a crate item bound under one is refused rather
than redefining it.
"""
function _pyo3_host_prelude_exprs(path::AbstractString, features::Vector{String},
                                  default_features::Bool, release::Bool)
    out = Any[]
    push!(out, :(import RustCall))
    push!(out, :(import PythonCall))
    push!(out, :(const _PYO3_CRATE_PATH = $(String(path))))
    push!(out, :(const _PYO3_FEATURES = $features))
    push!(out, :(const _PYO3_DEFAULT_FEATURES = $default_features))
    push!(out, :(const _PYO3_RELEASE = $release))
    push!(out, :(const _PYO3_MODULE = Base.RefValue{Any}(nothing)))
    push!(out, quote
        function _pyo3_module()
            m = _PYO3_MODULE[]
            m === nothing || return m
            m = RustCall.pyo3_host_import(_PYO3_CRATE_PATH; features = _PYO3_FEATURES,
                                          default_features = _PYO3_DEFAULT_FEATURES,
                                          release = _PYO3_RELEASE)
            _PYO3_MODULE[] = m
            return m
        end
    end)
    handle = QuoteNode(_PYO3_HOST_HANDLE_FIELD)
    push!(out, :(abstract type _PyO3Object end))
    # numpy is imported the first time a numeric array is passed, never
    # otherwise; `false` records that it is not importable.
    push!(out, :(const _PYO3_NUMPY = Base.RefValue{Any}(nothing)))
    push!(out, quote
        function _pyo3_numpy()
            np = _PYO3_NUMPY[]
            np === nothing || return np
            np = try
                PythonCall.pyimport("numpy")
            catch err
                err isa PythonCall.PyException || rethrow()
                false
            end
            _PYO3_NUMPY[] = np
            return np
        end
    end)
    push!(out, quote
        function _pyo3_to_python(x)
            x isa _PyO3Object && return getfield(x, $handle)
            if x isa AbstractArray
                if eltype(x) <: Number
                    np = _pyo3_numpy()
                    return np === false ? x : np.asarray(x)
                end
                return map(_pyo3_to_python, x)
            end
            x isa Tuple && return map(_pyo3_to_python, x)
            return x
        end
    end)
    push!(out, :(const _PYO3_CLASSES = Base.RefValue{Any}(nothing)))
    push!(out, :(function _pyo3_class_pairs end))
    push!(out, quote
        function _pyo3_classes()
            c = _PYO3_CLASSES[]
            c === nothing || return c
            c = _pyo3_class_pairs()
            _PYO3_CLASSES[] = c
            return c
        end
    end)
    push!(out, quote
        function _pyo3_from_python(v)
            v isa PythonCall.Py || return v
            PythonCall.pyis(v, PythonCall.pybuiltins.None) && return nothing
            # The most derived bound class in the type's MRO: the type itself
            # first, then its bases in order, so a Rust subclass stays itself
            # and a subclass defined in Python is its nearest bound base.
            classes = _pyo3_classes()
            isempty(classes) && return v
            for t in PythonCall.pytype(v).__mro__
                for (T, cls) in classes
                    PythonCall.pyis(t, cls) && return T(v)
                end
            end
            return v
        end
    end)
    push!(out, quote
        function _pyo3_from_python(v, ::Type{T}) where {T}
            x = _pyo3_from_python(v)
            x isa PythonCall.Py || return x
            return PythonCall.pyconvert(T, x, x)
        end
    end)
    push!(out, quote
        function _pyo3_from_python(v, ::Type{Any})
            return _pyo3_from_python(v)
        end
    end)
    push!(out, quote
        function _pyo3_from_python(v, ::Type{Vector{T}}) where {T}
            x = _pyo3_from_python(v)
            x isa PythonCall.Py || return x
            if PythonCall.pyisinstance(x, PythonCall.pybuiltins.list) ||
               PythonCall.pyisinstance(x, PythonCall.pybuiltins.tuple)
                items = Any[_pyo3_from_python(e, T) for e in x]
                return isempty(items) ? T[] : map(identity, items)
            end
            return PythonCall.pyconvert(Vector{T}, x, x)
        end
    end)
    push!(out, quote
        function _pyo3_ok(v, ::Type{T}) where {T}
            v isa T && return RustCall.RustResult{T, String}(true, v)
            return RustCall.RustResult{Any, String}(true, v)
        end
    end)
    return out
end

"""
    _pyo3_host_defined_names(exprs) -> Vector{String}

The module-level names these expressions define — `import M`, `const X = ...`,
`function f(...)`, `function f end`, `abstract type T end` — read off the
expressions themselves, so the reserved set is
whatever the prelude emits and never a list kept beside it.
"""
function _pyo3_host_defined_names(exprs)
    names = String[]
    visit(x) = nothing
    function visit(x::Expr)
        if x.head === :block
            foreach(visit, x.args)
        elseif x.head === :import || x.head === :using
            for path in x.args
                path isa Expr && path.head === :. && push!(names, String(last(path.args)))
            end
        elseif x.head === :const && x.args[1] isa Expr && x.args[1].head === :(=)
            push!(names, String(x.args[1].args[1]))
        elseif x.head === :function
            sig = x.args[1]
            while sig isa Expr && sig.head === :where
                sig = sig.args[1]
            end
            sig isa Symbol && push!(names, String(sig))
            sig isa Expr && sig.head === :call && push!(names, String(sig.args[1]))
        elseif x.head === :abstract
            T = x.args[1]
            T isa Expr && T.head === :(<:) && (T = T.args[1])
            push!(names, String(T))
        end
        return nothing
    end
    foreach(visit, exprs)
    return unique(names)
end

"""
    _pyo3_host_item_exprs(info) -> Vector{Any}

The definitions of the host's functions and classes, every parameter named
against the definitions it lands in (`_rename_parameters`, #526).
"""
function _pyo3_host_item_exprs(info::CrateInfo)
    emit(fs, ss) = Expr(:block, _pyo3_host_item_exprs(fs, ss)...)
    functions, structs = _rename_parameters(_pyo3_host_bound_functions(info),
                                            _pyo3_host_bound_classes(info), emit)
    return _pyo3_host_item_exprs(functions, structs)
end

function _pyo3_host_item_exprs(functions, structs)
    out = Any[]
    for f in functions
        append!(out, _pyo3_host_function_expr(f))
    end
    for s in structs
        append!(out, _pyo3_host_struct_exprs(s))
    end
    return out
end

"""
    generate_pyo3_host_bindings(crate_path; module_name, features, default_features, release) -> Expr

The module expression `@rust_crate ... pyo3_host=true` evaluates: a typed Julia
surface over the crate's imported Python module. Core and interpreter-free to
build — the import itself is lazy and lives in `pyo3_host_import`.
"""
function generate_pyo3_host_bindings(crate_path::AbstractString;
                                     module_name::Union{String, Nothing} = nothing,
                                     features::Vector{String} = String[],
                                     default_features::Bool = true,
                                     release::Bool = true,
                                     python::AbstractString = _pyo3_host_default_python())
    path = abspath(String(crate_path))
    # The items of the build this module imports, not every feature variant:
    # the lenient scan keeps both of `#[cfg(feature = "x")] fn r#for` and
    # `#[cfg(not(feature = "x"))] fn for_`, which no one build has, and the
    # bindings — and the name-clash check over them — would describe a crate
    # that does not exist (PR #515 review). The crate is rescanned under the
    # `--print cfg` of the very command `build_pyo3_extension` builds it with
    # (`_pyo3_host_cargo_cmd`: the crate as its own cdylib root, this profile
    # and these features, `PYO3_PYTHON` the importing interpreter), so a
    # `#[cfg(debug_assertions)]` or Python-version item is scanned as it is
    # built. When Cargo does not answer, the lenient scan stands.
    snapshot = BuildEnvSnapshot()
    lenient = scan_crate(path; cargo_env = snapshot_env(snapshot))
    cfg_text = _pyo3_host_cfg_text(snapshot, path, parse_cargo_toml(joinpath(path, "Cargo.toml"));
                                   python = python, features = features,
                                   default_features = default_features, release = release)
    info = isempty(cfg_text) ? lenient :
           scan_crate(path; cfg = :cargo, cfg_text = cfg_text,
                      cargo_env = snapshot_env(snapshot))
    mod_name = Symbol(module_name === nothing ? snake_to_pascal(info.name) : module_name)
    body = Expr(:block)
    append!(body.args, _pyo3_host_prelude_exprs(path, collect(String, features),
                                                default_features, release))
    # Two items one Julia name would bind (`fn r#for` beside `fn for_`) are
    # refused before anything is emitted, by the check every emitter runs,
    # over what this one binds (#514).
    _pyo3_host_check_names(info)
    append!(body.args, _pyo3_host_item_exprs(info))
    push!(body.args, _pyo3_host_class_table_expr(info))
    return Expr(:module, true, mod_name, body)
end
