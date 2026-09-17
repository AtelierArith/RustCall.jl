// A crate written for PyO3 only: no RustCall attribute, no `rustcall_julia_macros`
// dependency, no `pub`, `cdylib` + pyo3's `extension-module`. It is bound with
// the `@rust_crate ... pyo3_host=true` macro.
//
// This crate is the *macro-compatible* half of the example: its `#[new]` takes a
// scalar (`i64`), which the host path types as `Integer` in Julia. Compare
// `../direct_crate/src/lib.rs`, whose `#[new]` takes a `Py<PyAny>` and so must
// be bound with `RustCall.pyo3_host_import` instead (RustCall.jl#433).

use pyo3::prelude::*;

/// A free function: `scale(x, k)` in Julia and Python.
#[pyfunction]
fn scale(x: i32, k: i32) -> i32 {
    x * k
}

/// A class whose `#[new]` takes one scalar argument. The generated Julia
/// constructor is `Accumulator(start::Integer)`, which does not collide with
/// anything and precompiles cleanly.
#[pyclass]
struct Accumulator {
    total: i64,
}

#[pymethods]
impl Accumulator {
    #[new]
    fn new(start: i64) -> Self {
        Accumulator { total: start }
    }

    /// A `&mut self` method: `add(a, x)` mutates `a` in place.
    fn add(&mut self, x: i64) -> i64 {
        self.total += x;
        self.total
    }

    fn total(&self) -> i64 {
        self.total
    }
}

/// The module initializer Python's importer calls. The host path imports this
/// module, so anything it does not register does not exist for Julia.
#[pymodule]
fn macro_crate(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(scale, m)?)?;
    m.add_class::<Accumulator>()?;
    Ok(())
}
