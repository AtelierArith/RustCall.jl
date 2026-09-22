# The Python host for PyO3 crates (#424 Phase 1).
#
# RustCall's core is interpreter-free, so this — the only part that needs a
# live CPython — lives in a package extension triggered by PythonCall. It builds
# a PyO3 crate as the Python extension it already is and imports it; the value
# bridge, the GIL and object lifetime are PythonCall's. See
# `RustCall.build_pyo3_extension` for the build and `RustCall.pyo3_host_import`
# for the hook this defines.
module RustCallPyO3HostExt

using RustCall
using PythonCall

"""
    RustCall.pyo3_host_import(crate_path; features, default_features, release, cache_enabled)

Build `crate_path` as a Python extension module with PythonCall's interpreter,
import it, and return the Python module object. See the hook's documentation in
RustCall for the contract.
"""
function RustCall.pyo3_host_import(crate_path::AbstractString;
                                   features::Vector{String} = String[],
                                   default_features::Bool = true,
                                   release::Bool = true,
                                   cache_enabled::Bool = true)
    artifact = RustCall.build_pyo3_extension(String(crate_path);
                                             python = PythonCall.python_executable_path(),
                                             features = features,
                                             default_features = default_features,
                                             release = release,
                                             cache_enabled = cache_enabled)
    # Built for `python_executable_path()` a moment ago, so the interpreter
    # check of the artifact overload would only repeat the probe that just ran.
    return _import_artifact(artifact)
end

"""
    RustCall.pyo3_host_import(artifact::RustCall.PyO3Extension) -> Py

Import an extension module `RustCall.build_pyo3_extension` already built, and
return the Python module object. This is the half of `pyo3_host_import(crate)`
that needs the interpreter; the build is interpreter-free, so a package can run
it ahead of time — in its `__init__`, or in a `deps/build.jl` with an
interpreter of its choosing — and keep only this import lazy (#449).
"""
function RustCall.pyo3_host_import(artifact::RustCall.PyO3Extension)
    _check_interpreter(artifact)
    return _import_artifact(artifact)
end

function _import_artifact(artifact::RustCall.PyO3Extension)
    _ensure_importable(artifact.dir)
    return PythonCall.pyimport(artifact.module_name)
end

# An artifact is built for one interpreter — pyo3 links against it, and CPython
# ignores an extension whose file tag is another version's — and the split API
# lets a package build ahead of time, possibly in an earlier session. So an
# artifact handed in is checked against the interpreter this process runs
# before it is imported, by **fingerprint** (implementation, version, SOABI,
# library, machine) and by the `EXT_SUFFIX` the file is named with — the suffix is what
# the import resolves by, and a build with the same fingerprint can still tag
# its extensions differently — never by path alone: an interpreter upgraded in
# place keeps its path and changes its ABI, and a virtual environment's
# launcher and its base are one interpreter under two paths. Both come from
# the one-start probe; the one-argument hook does not pay it, having just
# built for this interpreter (#449 review).
function _check_interpreter(artifact::RustCall.PyO3Extension)
    runtime = PythonCall.python_executable_path()
    ext_suffix, fingerprint = RustCall._pyo3_extension_interpreter_probe(runtime)
    artifact.fingerprint == fingerprint && artifact.ext_suffix == ext_suffix && return nothing
    throw(RustCall.RustError(
        "The PyO3 extension module `$(artifact.module_name)` was built for the " *
        "interpreter `$(artifact.interpreter)` ($(artifact.fingerprint), " *
        "$(artifact.ext_suffix)), but the Python this process runs is `$(runtime)` " *
        "($(fingerprint), $(ext_suffix)). Build it for that interpreter: " *
        "`RustCall.build_pyo3_extension(crate; python = " *
        "PythonCall.python_executable_path())`."))
end

# Put the artifact's directory on `sys.path` once. The module is imported by
# name — that is what PythonCall's `pyimport` does — so the file has to be found
# there; the directory is RustCall's cache, one per artifact key, and repeated
# host imports of the same crate must not keep prepending it.
function _ensure_importable(dir::AbstractString)
    sys = PythonCall.pyimport("sys")
    path = sys.path
    pyconvert(Bool, pycontains(path, dir)) && return nothing
    path.insert(0, dir)
    return nothing
end

# The hook and the import are what a downstream package's first host call runs
# after RustCall's own image has done the scan and the cache lookup (#449);
# `precompile` compiles them without starting an interpreter, which a
# workload here could not do.
if ccall(:jl_generating_output, Cint, ()) == 1
    precompile(RustCall.pyo3_host_import, (String,))
    # A generated `@rust_crate ... pyo3_host=true` module calls the hook with
    # `features`, `default_features` and `release` (`_pyo3_module` in
    # `src/pyo3_host.jl`), which is a different entry point from the plain
    # call (#449 review).
    precompile(Core.kwcall, (NamedTuple{(:features, :default_features, :release),
                                        Tuple{Vector{String}, Bool, Bool}},
                             typeof(RustCall.pyo3_host_import), String))
    precompile(RustCall.pyo3_host_import, (RustCall.PyO3Extension,))
    precompile(_ensure_importable, (String,))
end

end
