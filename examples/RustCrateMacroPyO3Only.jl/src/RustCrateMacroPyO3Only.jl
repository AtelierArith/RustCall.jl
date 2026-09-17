"""
    RustCrateMacroPyO3Only

A Julia package with the Rust crate `deps/macro_pyo3_only` embedded in it: a
crate **written for PyO3 only**, with no `pub` anywhere and nothing
RustCall-specific. It is a real extension module (`crate-type = ["cdylib"]`,
pyo3's `extension-module`). RustCall binds it as is (#424): it builds the crate
**as the Python extension it already is** and calls the imported module, so the
private `#[pyfunction]`s and the `Python<'_>`/numpy/callable signatures the
C-ABI wrapper path cannot bind are all reachable.

What this example shows is the **front door**: `@rust_crate`, at the package's
top level, with `submodule="Bindings"` and `pyo3_host=true`. There is no
generated file and no build step — the bindings module is compiled into the
package's precompile image like any other submodule (#339), and the crate's
build and import happen lazily, on the first call, because a Python interpreter
may not be started while the package is precompiled.
`../SampleCratePyO3Only.jl` binds a crate of the same shape through the same
host path with a different front door; compare the two `src/` files.

The two halves live in separate files:

- **Rust**: `deps/macro_pyo3_only/src/lib.rs` — `#[pyfunction]`, `#[pyclass]`,
  `#[pymethods]` and nothing else. No Julia file contains Rust source, and no
  Rust file mentions Julia.
- **Julia**: this file. Everything under `Bindings` is generated in memory.

The host path needs PythonCall and a Rust toolchain; the build is paid on the
first call, not on every `using`. See `README.md`.

Every exported name here is the Julia binding of the same-named PyO3 item,
except `safe_div`, which is a Julia-side convenience.
"""
module RustCrateMacroPyO3Only

using RustCall
using RustCall: is_ok, unwrap
# Loads PythonCall, and with it the `RustCallPyO3HostExt` extension that gives
# RustCall's host path its interpreter.
import PythonCall

# The one line this example is about.
#
# `@rust_crate` builds the crate as the Python extension it already is and
# defines the typed bindings here, as `RustCrateMacroPyO3Only.Bindings` —
# `submodule=` is what defines it in this module under a name of our choosing,
# and therefore what makes the `using .Bindings` below possible. `pyo3_host`
# selects the host path (#424).
#
# The module is defined when this package is precompiled, but the build and the
# import happen lazily, on the first call: a Python interpreter may not be
# started during precompilation. Without `submodule=` the module would still be
# generated — hidden inside this one — and reachable only through the value the
# macro returns (`const B = @rust_crate ...; B.scale(...)`). `name=` is a
# different option: it renames that hidden module and defines nothing here.
@rust_crate joinpath(@__DIR__, "..", "deps", "macro_pyo3_only") submodule="Bindings" pyo3_host=true

# Explicit list: exactly the names this module re-exports unchanged. Every one
# of them is checked against `Base` first — a PyO3 item called `peek` or
# `parse` must *not* be re-exported, because `using` this package would then
# make the name ambiguous with the `Base` export at every call site; reach such
# a name as `Bindings.<name>` instead (`../SampleCratePyO3Only.jl` does that
# for `parse`).
using .Bindings: scale, join_words, checked_div,
                 Counter, zeroed, bump, current, describe, advance

# Names the PyO3 crate exposes, re-exported unchanged: `#[pyfunction]`s ...
export scale, join_words, checked_div
# ... and the `#[pyclass]` with its `#[new]`, `#[staticmethod]` and methods.
# The generated field accessors (`get_value` / `set_value!`, `get_step` /
# `set_step!`) are left in `Bindings`: `c.value` and `c.value = 1` go through
# them anyway.
export Counter, zeroed, bump, current, describe, advance

# The Julia-side convenience defined below.
export safe_div

"""
    safe_div(a::Integer, b::Integer) -> Int32

Integer division in Rust through the crate's `checked_div`, a `#[pyfunction]`
returning `PyResult<i32>`. The host path has an interpreter, so the binding
returns `RustResult{Int32, String}` with the real exception message; this
wrapper turns any `Err` into a `DivideError` — for a zero divisor and for
`typemin(Int32) ÷ -1`, whose quotient does not fit, exactly the two cases in
which Julia's own `div` throws it.
"""
function safe_div(a::Integer, b::Integer)::Int32
    r = checked_div(Int32(a), Int32(b))
    is_ok(r) || throw(DivideError())
    return unwrap(r)
end

end # module RustCrateMacroPyO3Only
