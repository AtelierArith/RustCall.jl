"""
    Pyo3HostImport

Two front doors to RustCall's Python-host path (#424) for a **PyO3-only** crate,
side by side in one package:

- `MacroBindings` is bound with the **`@rust_crate` macro**
  (`@rust_crate ... submodule="MacroBindings" pyo3_host=true`), the shape
  `../RustCrateMacroPyO3Only.jl` documents. Its crate's `#[new]` takes a scalar.
- `Sized` is bound with **`RustCall.pyo3_host_import`** — the build/import the
  macro is built on — because the macro's generated bindings cannot bind this
  crate: its `#[new]` takes a single `Py<PyAny>`, which the host path types as
  Julia's untyped `Any`, and the generated `Sized(obj::Any)` collides with
  Julia's default single-field constructor
  (RustCall.jl#433, https://github.com/AtelierArith/RustCall.jl/issues/433).

Both crates are written for PyO3 only: no RustCall attribute, no
`rustcall_julia_macros` dependency, no `pub`. They are real extension modules
(`cdylib` + pyo3's `extension-module`), and RustCall builds each **as the
Python extension it already is** and imports it through PythonCall.

The two halves live in separate files:

- **Rust**: `deps/macro_crate/src/lib.rs` and `deps/direct_crate/src/lib.rs`.
- **Julia**: this file.

The host path needs PythonCall and a Rust toolchain; each crate's build is paid
on its first call, never while this package is precompiled. See `README.md`.
"""
module Pyo3HostImport

using RustCall
import PythonCall

# ============================================================================
# Front door 1: the macro
# ============================================================================

# The one line this half is about. `@rust_crate` builds `deps/macro_crate` as
# the Python extension it already is and defines the typed bindings here, as
# `Pyo3HostImport.MacroBindings`; `submodule=` is what defines that module under
# a name of our choosing, so `using .MacroBindings` below works. The build and
# import happen lazily, on the first call: a Python interpreter may not be
# started while the package is precompiled.
@rust_crate joinpath(@__DIR__, "..", "deps", "macro_crate") submodule="MacroBindings" pyo3_host=true

using .MacroBindings: scale, Accumulator, add, total

export scale, Accumulator, add, total

# ============================================================================
# Front door 2: RustCall.pyo3_host_import
# ============================================================================

# The same build/import the macro performs, called directly:
#
#   RustCall.build_pyo3_extension(crate; python = PythonCall.python_executable_path(), ...)
#   then import it
#
# It returns the imported Python module, and generates nothing. The crate's
# classes and functions are reached through PythonCall. This is the front door
# to use when the macro's generated bindings cannot be used — here because
# `direct_crate`'s `#[new]` is a single `Py<PyAny>` (RustCall.jl#433).
const _DIRECT_CRATE = joinpath(@__DIR__, "..", "deps", "direct_crate")

# The imported `direct_crate` module, built and imported lazily on the first
# call, for the same reason as above.
const _DIRECT_MODULE = Base.RefValue{Any}(nothing)

function _direct_module()
    m = _DIRECT_MODULE[]
    m === nothing || return m
    m = RustCall.pyo3_host_import(_DIRECT_CRATE)
    _DIRECT_MODULE[] = m
    return m
end

"""
    Sized(obj)

The `direct_crate` crate's `Sized` class: a handle over an object measured once,
at construction.

`obj` is any Python object, or a Julia value PythonCall converts to one — a
`Dict` or `Vector` works, and `item_count` is its length.
"""
struct Sized
    py::PythonCall.Py

    # An explicit inner constructor suppresses Julia's default single-field
    # constructors (`Sized(::Py)` and the untyped `Sized(x)`). The untyped one is
    # what a generated `Sized(obj::Any)` would overwrite — the collision in
    # RustCall.jl#433. With it suppressed, the data-taking constructor below can
    # be an ordinary `::Any` method without colliding, and the raw-handle path
    # stays distinct under `Val{:host}`.
    Sized(py::PythonCall.Py, ::Val{:host}) = new(py)
end

function Sized(obj)
    cls = PythonCall.pygetattr(_direct_module(), "Sized")
    return Sized(PythonCall.pycall(cls, obj), Val(:host))
end

"""
    item_count(s::Sized) -> Int

The length the crate measured when `s` was constructed.
"""
function item_count(s::Sized)::Int
    fn = PythonCall.pygetattr(s.py, "item_count")
    return PythonCall.pyconvert(Int, PythonCall.pycall(fn))
end

export Sized, item_count

end # module Pyo3HostImport
