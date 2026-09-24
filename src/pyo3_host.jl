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
    package = String(get(get(cargo_toml, "package", Dict{String, Any}()), "name", ""))
    isempty(package) && throw(RustError(
        "`$(crate_path)` has no `[package] name`, so Cargo cannot select it."))

    args = String["rustc"]
    release && push!(args, "--release")
    push!(args, "-p", package, "--crate-type", "cdylib")
    default_features || push!(args, "--no-default-features")
    isempty(features) || push!(args, "--features", join(features, ","))
    link_args = _pyo3_extension_link_args()

    # Under RustCall's cache, never the crate's own `target/`: an installed
    # package is read-only, and every `@rust_crate` flavour builds where
    # `crate_target_directory` says (#486). An ambient `CARGO_TARGET_DIR`
    # would send the library somewhere this function never looks, so it is
    # pinned as `build_cargo_project` does.
    target_dir = _crate_target!(crate_path, :pyo3_host)
    env = snapshot_env(snapshot)
    env["PYO3_PYTHON"] = String(python)
    env["CARGO_TARGET_DIR"] = target_dir

    # `--offline` under `RUSTCALL_OFFLINE`, as every other build (#461).
    append!(args, _cargo_network_args(env))
    # In the crate's directory through the command's `dir`, never a
    # process-wide `cd`, which would move every other task's relative paths
    # for the length of the build (#461).
    cmd = setenv(isempty(link_args) ? `$(cargo()) $args` : `$(cargo()) $args -- $link_args`,
                 env; dir = String(crate_path))
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
# the manifest's `getter`/`setter` symbols are blank for. The manifest still
# lists the struct's fields with their Rust types, which is what types the
# getter; a field PyO3 does not expose raises at access, as it would in Python.

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

# The Julia type a Python value is converted into, or `nothing` for "leave it as
# a Python object" (a `Py<T>`, `Bound<...>`, `PyObject`, or a type this path has
# no mapping for).
function _pyo3_host_value_type(rust_type::AbstractString)
    t = strip(rust_type)
    t == "()" && return :Nothing
    scalar = _pyo3_host_scalar_type(t)
    scalar === nothing || return scalar
    t == "String" && return :String
    (startswith(t, "&") && endswith(t, "str")) && return :String
    if startswith(t, "Vec<") && endswith(t, ">")
        elem = _pyo3_host_value_type(strip(t[nextind(t, 5):prevind(t, lastindex(t))]))
        elem === nothing && return nothing
        return :(Vector{$elem})
    end
    numpy = _pyo3_host_numpy_value_type(t)
    numpy === nothing || return numpy
    return nothing
end

# ============================================================================
# pyo3-numpy arrays (#424)
# ============================================================================
#
# `PyReadonlyArray*` / `PyArray*` parameters are what pyo3-numpy extracts from a
# **real** `numpy.ndarray`. A Julia `AbstractArray` reaches Python as a
# `juliacall.VectorValue`, which that extractor rejects (`not an instance of
# 'ndarray'`), so the binding converts it with `numpy.asarray` before the call.
# Python already hands Julia a numpy array back for the reverse direction, so
# only the argument side needs a conversion; a numpy *return* is typed from its
# element so a caller gets a Julia array rather than a `Py`.

# The pyo3-numpy array type in a Rust spelling: `(rank, element)`, or `nothing`
# when the spelling names no such array. `rank` is `0`–`6`, or `-1` for
# `PyReadonlyArrayDyn` / `PyArrayDyn`. The stem may sit bare
# (`PyReadonlyArray1<f64>`), behind `Py<...>` (`Py<PyArray1<f64>>`) or behind
# `Bound<'_, ...>`; a `numpy::` path is irrelevant because only the tail is
# read.
function _pyo3_host_numpy_parts(t::AbstractString)
    chars = collect(t)
    for stem in ("PyReadonlyArray", "PyArray")
        start = _pyo3_host_find(chars, collect(stem))
        start == 0 && continue
        p = start + length(stem)
        p > length(chars) && continue
        rank = -2
        if p + 2 <= length(chars) && chars[p] == 'D' && chars[p + 1] == 'y' &&
           chars[p + 2] == 'n'
            rank = -1
            p += 3
        elseif isdigit(chars[p])
            rank = Int(chars[p]) - Int('0')
            p += 1
        end
        rank == -2 && continue
        (p <= length(chars) && chars[p] == '<') || continue
        inner = _pyo3_host_generic_body(chars, p)
        inner === nothing && continue
        element = _pyo3_host_last_generic_arg(inner)
        isempty(element) && continue
        return (rank, element)
    end
    return nothing
end

function _pyo3_host_find(chars::Vector{Char}, needle::Vector{Char})
    n = length(needle)
    for i in 1:(length(chars) - n + 1)
        chars[i:(i + n - 1)] == needle && return i
    end
    return 0
end

# The body of the `<...>` at `chars[pos]`, by depth; `nothing` if unbalanced.
function _pyo3_host_generic_body(chars::Vector{Char}, pos::Int)
    (pos <= length(chars) && chars[pos] == '<') || return nothing
    depth = 0
    for i in pos:length(chars)
        chars[i] == '<' && (depth += 1)
        if chars[i] == '>'
            depth -= 1
            depth == 0 && return String(chars[(pos + 1):(i - 1)])
        end
    end
    return nothing
end

# The last top-level comma-separated argument of a generic body, trimmed: the
# element type of `PyArray1<'py, f64>` is `f64`.
function _pyo3_host_last_generic_arg(inner::AbstractString)
    depth = 0
    last = firstindex(inner)
    for (i, c) in pairs(inner)
        if c == '<'
            depth += 1
        elseif c == '>'
            depth -= 1
        elseif c == ',' && depth == 0
            last = nextind(inner, i)
        end
    end
    return strip(inner[last:end])
end

_pyo3_host_numpy_arg(t::AbstractString) = _pyo3_host_numpy_parts(t) !== nothing

# The Julia array type a numpy return is converted into, or `nothing`.
function _pyo3_host_numpy_value_type(t::AbstractString)
    parts = _pyo3_host_numpy_parts(t)
    parts === nothing && return nothing
    rank, element = parts
    el = _pyo3_host_value_type(element)
    el === nothing && return nothing
    rank == 0 && return el
    rank == 1 && return :(Vector{$el})
    rank == 2 && return :(Matrix{$el})
    return :(Array{$el})
end

# The Julia type a binding accepts for an argument. Abstract on purpose: a
# Python host is duck-typed, and `Integer` lets both `Int32(2)` and `2` reach
# `add`, as they would in Python.
function _pyo3_host_arg_type(rust_type::AbstractString)
    t = strip(rust_type)
    if _pyo3_host_scalar_type(t) !== nothing
        t == "bool" && return :Bool
        (t == "f32" || t == "f64") && return :Real
        return :Integer
    end
    t == "String" && return :AbstractString
    (startswith(t, "&") && endswith(t, "str")) && return :AbstractString
    startswith(t, "Vec<") && return :AbstractVector
    parts = _pyo3_host_numpy_parts(t)
    if parts !== nothing
        # A 0-d numpy array is a scalar in disguise (pyo3-numpy's `PyArray0`);
        # anything with a rank is reached as an array.
        return parts[1] == 0 ? :Any : :AbstractArray
    end
    return :Any
end

# The interpreter supplies these to the callee; they are not part of the Python
# call and are dropped from the Julia signature.
_pyo3_host_injected_arg(rust_type::AbstractString) =
    occursin("Python<", rust_type) || occursin("PyModule", rust_type)

_pyo3_host_attr(base, name::AbstractString) = Expr(:., base, QuoteNode(Symbol(name)))

# The Python attribute of an item: the manifest's `python_name` — which the
# extractor also fills for a raw Rust name, `r#for` being exposed as `for`
# (#514) — or the Rust name, never with a raw identifier's `r#`.
_pyo3_host_python_name(name, python_name) =
    isempty(python_name) ? _pyo3_host_attr_name(name) : String(python_name)

# The Python attribute of a Rust field: its name without a raw identifier's
# `r#`, which PyO3 drops as well.
_pyo3_host_attr_name(field::AbstractString) =
    startswith(field, "r#") ? String(SubString(field, 3)) : String(field)

# The last identifier of a type spelling: `Py` in `Py<T>`, `T` in
# `Bound<'_, T>`, `PyIndex` in `PyRef<'_, PyIndex>`.
function _pyo3_host_last_ident(text::AbstractString)
    found = match(r"([A-Za-z_][A-Za-z0-9_]*)\s*>?\s*$", strip(text))
    return found === nothing ? nothing : String(found.captures[1])
end

# The Julia class a value of this Rust type corresponds to, or `nothing`:
# `Self` (the enclosing class), the class's Rust name, or `Py<T>` /
# `Bound<'_, T>` / `PyRef<T>` around it. A `Vec`/`Option` is not a single
# class and is left alone.
function _pyo3_host_struct_target(rust_type::AbstractString, classes::AbstractDict,
                                  jstruct::Union{Symbol, Nothing} = nothing)
    t = strip(rust_type)
    t == "Self" && return jstruct
    haskey(classes, t) && return classes[t]
    (startswith(t, "Vec<") || startswith(t, "Option<")) && return nothing
    name = _pyo3_host_last_ident(t)
    name === nothing && return nothing
    return get(classes, name, nothing)
end

# For an argument: `(class, is_vector)` when it names a scanned `#[pyclass]` (a
# direct reference or a `Vec` of them), otherwise `nothing`. A class argument is
# passed as the Python object the Julia handle holds, not as the handle.
function _pyo3_host_struct_arg(rust_type::AbstractString, classes::AbstractDict)
    t = strip(rust_type)
    if startswith(t, "Vec<") && endswith(t, ">")
        inner = strip(t[nextind(t, 5):prevind(t, lastindex(t))])
        name = _pyo3_host_last_ident(inner)
        name !== nothing && haskey(classes, name) && return (classes[name], true)
        return nothing
    end
    haskey(classes, t) && return (classes[t], false)
    name = _pyo3_host_last_ident(t)
    name !== nothing && haskey(classes, name) && return (classes[name], false)
    return nothing
end

# `(arg symbols, typed signature entries, call expressions, has-default flags)`
# for the positional prefix, with injected parameters dropped and the list
# stopped at the first keyword-only parameter (a keyword-only argument cannot be
# forwarded positionally, which is all this emitter does).
function _pyo3_host_args(arg_names, arg_types, python_defaults, python_kinds,
                         classes::AbstractDict; drop_leading::Bool = false)
    syms = Symbol[]
    sig = Any[]
    conv = Any[]
    defaults = Bool[]
    for (i, (name, type)) in enumerate(zip(arg_names, arg_types))
        # A `#[classmethod]`'s first argument is the class Python passes; it is
        # not part of the Julia signature (#424).
        drop_leading && i == 1 && continue
        _pyo3_host_injected_arg(type) && continue
        kind = i <= length(python_kinds) ? String(python_kinds[i]) : ""
        kind == "keyword_only" && break
        sym = Symbol(name)
        target = _pyo3_host_struct_arg(type, classes)
        if _pyo3_host_numpy_arg(type)
            # pyo3-numpy extracts from a real `numpy.ndarray`, not the
            # `juliacall.VectorValue` a Julia array becomes by default (#424).
            push!(sig, :($sym::$(_pyo3_host_arg_type(type))))
            push!(conv, :(_pyo3_asarray($sym)))
        elseif target === nothing
            push!(sig, :($sym::$(_pyo3_host_arg_type(type))))
            push!(conv, sym)
        else
            jname, isvector = target
            if isvector
                push!(sig, :($sym::AbstractVector))
                push!(conv,
                      :([x isa PythonCall.Py ? x : getfield(x, :_rustcall_py) for x in $sym]))
            else
                push!(sig, :($sym))
                push!(conv,
                      :($sym isa PythonCall.Py ? $sym : getfield($sym, :_rustcall_py)))
            end
        end
        push!(defaults, i <= length(python_defaults) && !isempty(python_defaults[i]))
        push!(syms, sym)
    end
    return syms, sig, conv, defaults
end

# The call's result, converted, or wrapped into the class it belongs to.
function _pyo3_host_value_expr(call::Expr, rust_type::AbstractString,
                               jstruct::Union{Symbol, Nothing}, classes::AbstractDict)
    target = _pyo3_host_struct_target(rust_type, classes, jstruct)
    target !== nothing && return :($target($call))
    jt = _pyo3_host_value_type(rust_type)
    jt === nothing && return call
    return :(PythonCall.pyconvert($jt, $call))
end

# One `function` definition, shaped by the return kind. `:py_result` catches the
# interpreter's exception and reports it as the `Err` payload.
function _pyo3_host_single_def(name::Symbol, sig::Vector{Any}, call::Expr, return_kind::Symbol,
                               rust_type::AbstractString, jstruct::Union{Symbol, Nothing},
                               classes::AbstractDict)
    if return_kind === :py_result
        target = _pyo3_host_struct_target(rust_type, classes, jstruct)
        valued = _pyo3_host_value_expr(call, rust_type, jstruct, classes)
        jt = target !== nothing ? target : _pyo3_host_value_type(rust_type)
        jt === nothing && (jt = :Any)
        body = quote
            try
                return RustCall.RustResult{$jt, String}(true, $valued)
            catch err
                err isa PythonCall.PyException || rethrow()
                return RustCall.RustResult{$jt, String}(false, sprint(showerror, err))
            end
        end
        return Expr(:function, Expr(:call, name, sig...), body)
    elseif return_kind === :unit || strip(rust_type) == "()"
        body = quote
            $call
            return nothing
        end
        return Expr(:function, Expr(:call, name, sig...), body)
    else
        return Expr(:function, Expr(:call, name, sig...),
                    Expr(:block, _pyo3_host_value_expr(call, rust_type, jstruct, classes)))
    end
end

# One definition per *arity* the call accepts: PyO3's trailing defaults are
# supplied by its own dispatcher, so a call passes only the arguments the caller
# gave and the generated method for that arity forwards exactly those. Without
# this `Index(2)` matched only the struct's inner constructor and failed
# (`#[pyo3(signature = (dim, tags = None, plev = 0))]`).
function _pyo3_host_defs(name::Symbol, fixed_sig::Vector{Any}, var_sig::Vector{Any},
                         var_conv::Vector{Any}, defaults::Vector{Bool}, callof,
                         return_kind::Symbol, rust_type::AbstractString,
                         jstruct::Union{Symbol, Nothing}, classes::AbstractDict)
    count = length(var_sig)
    first_default = findfirst(identity, defaults)
    minarity = first_default === nothing ? count : first_default - 1
    out = Any[]
    for arity in minarity:count
        call = callof(var_conv[1:arity])
        push!(out, _pyo3_host_single_def(name, vcat(copy(fixed_sig), var_sig[1:arity]), call,
                                         return_kind, rust_type, jstruct, classes))
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

function _pyo3_host_function_expr(f::RustFunctionSignature, classes::AbstractDict)
    _, sig, conv, defaults = _pyo3_host_args(f.arg_names, f.arg_types,
                                             f.python_defaults, f.python_kinds, classes)
    python = _pyo3_host_python_name(f.name, f.python_name)
    base = _pyo3_host_python_attr(:(_pyo3_module()), f.python_path, python)
    callof = convs -> Expr(:call, base, convs...)
    rust_type = f.return_kind === :py_result ? f.ok_type : f.return_type
    return _pyo3_host_defs(Symbol(julia_function_name(f)), Any[], sig, conv, defaults, callof,
                           f.return_kind, rust_type, nothing, classes)
end

# `class_base` is the expression for the class object itself (with the
# declarative module path, when any); a constructor calls it, a static or class
# method calls an attribute of it, and an instance method calls an attribute of
# the Python object the Julia handle holds.
function _pyo3_host_method_expr(jname::Symbol, class_base::Expr, m::RustMethod,
                                classes::AbstractDict)
    _, sig, conv, defaults = _pyo3_host_args(m.arg_names, m.arg_types,
                                             m.python_defaults, m.python_kinds, classes;
                                             drop_leading = m.is_classmethod)
    python = _pyo3_host_python_name(m.name, m.python_name)
    rust_type = m.return_kind === :py_result ? m.ok_type : m.return_type
    if m.is_constructor
        callof = convs -> Expr(:call, class_base, convs...)
        return _pyo3_host_defs(jname, Any[], sig, conv, defaults, callof,
                               m.return_kind, rust_type, jname, classes)
    elseif m.is_static || m.is_classmethod
        # `#[classmethod]`'s class argument is dropped above: Python's bound
        # descriptor supplies it (#424).
        base = _pyo3_host_attr(class_base, python)
        callof = convs -> Expr(:call, base, convs...)
        return _pyo3_host_defs(Symbol(julia_method_name(m)), Any[], sig, conv, defaults, callof,
                               m.return_kind, rust_type, jname, classes)
    else
        # An instance method: the object is the first Julia argument, and the
        # Python object it holds is the receiver. A `&mut self` method mutates
        # that same object, so no extra step is needed.
        receiver = _pyo3_host_attr(:(getfield(obj, :_rustcall_py)), python)
        callof = convs -> Expr(:call, receiver, convs...)
        return _pyo3_host_defs(Symbol(julia_method_name(m)), Any[:(obj::$jname)], sig, conv, defaults,
                               callof, m.return_kind, rust_type, jname, classes)
    end
end

# Whether any generated call takes a pyo3-numpy array, which is what decides
# whether the module carries the `_pyo3_asarray` helper (#424).
function _pyo3_host_needs_numpy(info::CrateInfo)
    for f in info.pyo3_functions
        any(_pyo3_host_numpy_arg, f.arg_types) && return true
    end
    for s in info.pyo3_structs
        for m in s.methods
            any(_pyo3_host_numpy_arg, m.arg_types) && return true
        end
    end
    return false
end

# Whether PyO3 exposes a getter / setter for the field, per the manifest. A
# manifest from before `Field.pyo3_get` (schema 0.6 additive, #424) records
# neither, so an absent column keeps the previous "every listed field is
# readable and writable" behaviour.
_pyo3_host_field_readable(s::RustStructInfo, field::AbstractString) =
    isempty(s.field_pyo3_get) || get(s.field_pyo3_get, String(field), false)

_pyo3_host_field_writable(s::RustStructInfo, field::AbstractString) =
    isempty(s.field_pyo3_set) || get(s.field_pyo3_set, String(field), false)

# `#[pyo3(get)]` / `#[pyo3(set)]` install the descriptor inside the crate, so
# the object answers; the manifest types the value and says which directions
# PyO3 exposed (#424).
function _pyo3_host_property_expr(jname::Symbol, s::RustStructInfo)
    conversions = Any[]
    for (field, rust_type) in s.fields
        _pyo3_host_field_readable(s, field) || continue
        jt = _pyo3_host_value_type(rust_type)
        jt === nothing && continue
        push!(conversions,
              :(s === $(QuoteNode(Symbol(_pyo3_host_attr_name(field)))) &&
                return PythonCall.pyconvert($jt, v)))
    end
    # A field is a property under its Julia name (`julia_field_name`, #514);
    # the Python attribute keeps the Rust spelling, so a renamed one is mapped
    # back before the lookup.
    names = [Symbol(julia_field_name(field)) for (field, _) in s.fields
             if _pyo3_host_field_readable(s, field)]
    renamed = Any[]
    for (field, _) in s.fields
        jfield = julia_field_name(field)
        jfield == _pyo3_host_attr_name(field) && continue
        push!(renamed, :(s === $(QuoteNode(Symbol(jfield))) &&
                         (s = $(QuoteNode(Symbol(_pyo3_host_attr_name(field)))))))
    end
    # A read-only field raises a Julia error naming it instead of the raw
    # Python `AttributeError` a descriptor would.
    read_only = Any[]
    for (field, _) in s.fields
        _pyo3_host_field_writable(s, field) && continue
        push!(read_only,
              :(s === $(QuoteNode(Symbol(_pyo3_host_attr_name(field)))) &&
                throw(ArgumentError($(string("field `", julia_field_name(field), "` is read-only"))))))
    end
    getbody = quote
        s === :_rustcall_py && return getfield(p, :_rustcall_py)
        $(renamed...)
        v = PythonCall.pygetattr(getfield(p, :_rustcall_py), String(s))
        $(conversions...)
        return v
    end
    setbody = quote
        s === :_rustcall_py && throw(ArgumentError("_rustcall_py is not assignable"))
        $(renamed...)
        $(read_only...)
        PythonCall.pysetattr(getfield(p, :_rustcall_py), String(s), v)
        return v
    end
    return quote
        function Base.getproperty(p::$jname, s::Symbol)
            $getbody
        end
        function Base.setproperty!(p::$jname, s::Symbol, v)
            $setbody
        end
        Base.propertynames(::$jname) = $(Tuple(names))
    end
end

# The host path cannot await. An `async fn` binding would hand Julia the
# interpreter's coroutine object, which never runs unless an event loop drives
# it; the extractor already refuses the item (`async_fn`), and the generator
# honours that rather than emitting a silently-unawaited binding (#424).
_pyo3_host_async(f::RustFunctionSignature) =
    partition_skip_reason(f.skip_reason)[1] == "async_fn"
_pyo3_host_async(m::RustMethod) = partition_skip_reason(m.skip_reason)[1] == "async_fn"

function _pyo3_host_struct_exprs(s::RustStructInfo, classes::AbstractDict)
    jname = Symbol(julia_struct_name(s))
    pyclass = _pyo3_host_python_name(s.name, s.python_name)
    class_base = _pyo3_host_python_attr(:(_pyo3_module()), s.python_path, pyclass)
    # An explicit inner constructor suppresses the constructors Julia would
    # otherwise synthesize for this one-field struct — including the untyped
    # `Class(x)` a one-argument `#[new]` mapping to `Any` (`Py<PyAny>`, a
    # class-typed argument) would overwrite, which is a hard error during
    # module precompilation (#433). The wrapping path still needs
    # `Class(::PythonCall.Py)`, which the field type gives it, and defining an
    # inner constructor also means any outer constructor the emitter adds is a
    # new method rather than a redefinition.
    field = Expr(:(::), :_rustcall_py, :(PythonCall.Py))
    inner = Expr(:(=), Expr(:call, jname, field),
                 Expr(:call, :new, :_rustcall_py))
    out = Any[Expr(:struct, false, jname, Expr(:block, field, inner))]
    for m in s.methods
        m.is_constructor || continue
        _pyo3_host_async(m) && continue
        append!(out, _pyo3_host_method_expr(jname, class_base, m, classes))
    end
    # `#[getter]`/`#[setter]` methods are Python properties; `getproperty`
    # above already reaches them, so they are not bound as functions.
    push!(out, _pyo3_host_property_expr(jname, s))
    for m in s.methods
        (m.is_constructor || !isempty(m.accessor)) && continue
        _pyo3_host_async(m) && continue
        append!(out, _pyo3_host_method_expr(jname, class_base, m, classes))
    end
    return out
end

"""
    _pyo3_host_check_names(info::CrateInfo)

`_check_julia_name_clashes` over what `generate_pyo3_host_bindings` binds: the
`#[pyfunction]`s and `#[pyclass]`es that are not `async`, every method of a
class (constructors are the type itself, getters and setters properties), and
the readable and writable fields.
"""
function _pyo3_host_check_names(info::CrateInfo)
    functions = [f for f in info.pyo3_functions
                 if f.attribute === :py_function && !_pyo3_host_async(f)]
    structs = [s for s in info.pyo3_structs if s.attribute === :py_class]
    _check_julia_name_clashes(functions, structs, "the PyO3 host bindings of `$(info.name)`";
                              binds_function = _ -> true, binds_struct = _ -> true,
                              binds_method = m -> !m.is_constructor && isempty(m.accessor) &&
                                                  !_pyo3_host_async(m),
                              binds_field = (s, f) -> _pyo3_host_field_readable(s, f) ||
                                                      _pyo3_host_field_writable(s, f))
    return nothing
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
                                     release::Bool = true)
    path = abspath(String(crate_path))
    info = scan_crate(path)
    mod_name = Symbol(module_name === nothing ? snake_to_pascal(info.name) : module_name)
    body = Expr(:block)
    push!(body.args, :(import RustCall))
    push!(body.args, :(import PythonCall))
    push!(body.args, :(const _PYO3_CRATE_PATH = $path))
    push!(body.args, :(const _PYO3_FEATURES = $(collect(String, features))))
    push!(body.args, :(const _PYO3_DEFAULT_FEATURES = $default_features))
    push!(body.args, :(const _PYO3_RELEASE = $release))
    push!(body.args, :(const _PYO3_MODULE = Base.RefValue{Any}(nothing)))
    push!(body.args, quote
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
    # pyo3-numpy extracts from a **real** `numpy.ndarray`, and a Julia array
    # becomes a `juliacall.VectorValue`; the bindings that take one convert it
    # here (lazily — a module with no numpy parameter never imports numpy).
    if _pyo3_host_needs_numpy(info)
        push!(body.args, quote
            function _pyo3_asarray(x)
                return PythonCall.pyimport("numpy").asarray(x)
            end
        end)
    end
    # The scanned classes, by their Rust name: a return or argument spelling them
    # (or `Py<T>` / `Bound<'_, T>` around one) is that Julia struct, not a
    # `Py`. Local, not module-level: `test_state.jl`'s guard forbids a mutable
    # registry in `RustCall` (#251).
    classes = Dict{String, Symbol}(s.name => Symbol(julia_struct_name(s))
                                   for s in info.pyo3_structs if s.attribute === :py_class)
    # Two items one Julia name would bind (`fn r#for` beside `fn for_`) are
    # refused before anything is emitted, by the check every emitter runs,
    # over what this one binds (#514).
    _pyo3_host_check_names(info)
    for f in info.pyo3_functions
        f.attribute === :py_function || continue
        _pyo3_host_async(f) && continue
        append!(body.args, _pyo3_host_function_expr(f, classes))
    end
    for s in info.pyo3_structs
        s.attribute === :py_class || continue
        append!(body.args, _pyo3_host_struct_exprs(s, classes))
    end
    return Expr(:module, true, mod_name, body)
end
