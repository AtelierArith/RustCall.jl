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
    _ensure_importable(artifact.dir)
    return PythonCall.pyimport(artifact.module_name)
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

end
