// A crate written for PyO3 only, exactly like `../macro_crate`, with one
// difference that decides the front door: its `#[new]` takes a **single
// `Py<PyAny>` argument**.
//
// In RustCall's Python-host path a `Py<PyAny>` argument maps to the untyped
// Julia argument `Any`, so the generated public constructor would be
// `function Sized(obj::Any)`. Julia also generates an untyped single-field
// constructor for the host handle struct itself, so the two occupy the same
// method slot and precompilation rejects the overwrite (RustCall.jl#433).
// `RustCall.pyo3_host_import` — the build/import the macro is built on — does
// not generate that constructor, so this crate is bound with it instead.

use pyo3::prelude::*;

/// A class that measures the length of any Python object it is constructed
/// from. The one-argument `#[new]` is what the macro cannot bind today.
#[pyclass]
struct Sized {
    count: usize,
}

#[pymethods]
impl Sized {
    /// `#[new]`: `Sized(obj)` in Julia and Python. A `Py<PyAny>` argument
    /// accepts a Python dict/list; the host path has an interpreter, so the
    /// ordinary pyo3 API is available.
    #[new]
    fn new(obj: Py<PyAny>) -> PyResult<Self> {
        Python::attach(|py| {
            let count = obj.bind(py).len()?;
            Ok(Sized { count })
        })
    }

    fn item_count(&self) -> usize {
        self.count
    }
}

/// The module initializer Python's importer calls.
#[pymodule]
fn direct_crate(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<Sized>()?;
    Ok(())
}
