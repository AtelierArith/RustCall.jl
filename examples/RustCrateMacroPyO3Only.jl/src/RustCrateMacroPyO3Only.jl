"""
    RustCrateMacroPyO3Only

A Julia package with the Rust crate `deps/macro_pyo3_only` embedded in it: a
crate **written for PyO3 only**. It carries no RustCall attribute — no
`#[julia]` anywhere — and does not depend on `juliacall_macros`; it is a PyO3
extension crate as its author wrote it for Python. RustCall binds it anyway
(#275 Phase 2): it scans the `pub` items PyO3 exposes, generates a **wrapper
crate** that depends on the crate, and builds it.

What this example shows is the **front door**: `@rust_crate`, at the package's
top level, with `submodule="Bindings"`. There is no generated file and no build
step — the crate is built and the bindings module is generated while this
package is *precompiled*, and the module is compiled into the package's
precompile image like any other submodule (#339). `../SampleCratePyO3Only.jl`
binds a crate of the same shape the other way, with `write_bindings_to_file`
in a `deps/build.jl`; compare the two `src/` files.

The two halves live in separate files:

- **Rust**: `deps/macro_pyo3_only/src/lib.rs` — `#[pyfunction]`, `#[pyclass]`,
  `#[pymethods]` and nothing else. No Julia file contains Rust source, and no
  Rust file mentions Julia.
- **Julia**: this file. Everything under `Bindings` is generated in memory.

The wrapper links libpython (pyo3 is a mandatory dependency of the crate, link
plan `:link_libpython`), so *precompiling* this package needs a Python
interpreter and a Rust toolchain; see `README.md`.

Every exported name here is the Julia binding of the same-named PyO3 item,
except `safe_div`, which is a Julia-side convenience.
"""
module RustCrateMacroPyO3Only

using RustCall
using RustCall: is_ok, unwrap

# The one line this example is about.
#
# `@rust_crate` scans the crate, builds it (through the generated PyO3 wrapper
# crate) and defines the generated module here, as
# `RustCrateMacroPyO3Only.Bindings` — `submodule=` is what defines it in this
# module under a name of our choosing, and therefore what makes the
# `using .Bindings` below possible. It runs when this package is precompiled,
# so the Rust build is paid once, not on every `using`; the library itself is
# opened by the generated module's `__init__`, in the session that loads the
# package (#339).
#
# Without `submodule=` the module would still be generated — hidden inside
# this one — and reachable only through the value the macro returns
# (`const B = @rust_crate ...; B.scale(...)`), which is the shape to use at
# the REPL or inside a function. `name=` is a different option: it renames
# that hidden module and defines nothing here.
@rust_crate joinpath(@__DIR__, "..", "deps", "macro_pyo3_only") submodule="Bindings"

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
returning `PyResult<i32>`. The wrapper cannot render a `PyErr` without a Python
interpreter, so the generated binding returns `RustResult{Int32, String}` whose
`Err` payload is always the fixed sentence `RustCall.PYO3_OPAQUE_ERROR`; this
wrapper turns that into a `DivideError` instead.
"""
function safe_div(a::Integer, b::Integer)::Int32
    r = checked_div(Int32(a), Int32(b))
    is_ok(r) || throw(DivideError())
    return unwrap(r)
end

end # module RustCrateMacroPyO3Only
