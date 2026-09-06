//! A small PyO3 crate with no RustCall attribute anywhere.
//!
//! RustCall scans it with `RustCall.scan_report(...)`: the `pub` items with
//! interpreter-free signatures are what a Phase-2 wrapper crate will be able to
//! export as `rustcall_<name>` / `rustcall_<Struct>_<method>`; everything else
//! is reported with a reason.

use pyo3::prelude::*;

/// Wrappable: `pub`, scalars only.
#[pyfunction]
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

/// Wrappable: strings travel as `(ptr, len)` pairs.
#[pyfunction]
pub fn shout(s: String) -> String {
    format!("{}!", s.to_uppercase())
}

/// Wrappable: `PyResult` is lowered to an opaque error. Creating and dropping a
/// `PyErr` needs no interpreter — only rendering one does, which the generated
/// code must never do.
#[pyfunction]
pub fn parse(s: &str) -> PyResult<i32> {
    s.trim()
        .parse::<i32>()
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))
}

/// Skipped: not `pub`, so a wrapper crate cannot name it (rustc E0603).
#[pyfunction]
fn private_add(a: i32, b: i32) -> i32 {
    a + b
}

/// Skipped: the signature needs a live interpreter.
#[pyfunction]
pub fn describe(py: Python<'_>) -> i32 {
    let _ = py;
    0
}

#[pyclass]
pub struct Point {
    #[pyo3(get, set)]
    pub x: f64,
    #[pyo3(get)]
    pub y: f64,
}

#[pymethods]
impl Point {
    #[new]
    pub fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }

    pub fn norm(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
}

/// A second `#[pymethods]` block for the same class: its methods join the
/// first block's.
#[pymethods]
impl Point {
    #[staticmethod]
    pub fn origin() -> Self {
        Point { x: 0.0, y: 0.0 }
    }

    #[getter]
    pub fn sum(&self) -> f64 {
        self.x + self.y
    }
}

/// Skipped: a module initializer only means something to Python's importer.
#[pymodule]
fn sample_crate_pyo3_only(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(add, m)?)?;
    m.add_class::<Point>()?;
    Ok(())
}
