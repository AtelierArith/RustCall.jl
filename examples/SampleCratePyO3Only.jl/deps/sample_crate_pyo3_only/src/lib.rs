//! A small crate written for PyO3, and for PyO3 only.
//!
//! There is no RustCall attribute in this file and no RustCall dependency in
//! `Cargo.toml`: this is what a real PyO3 extension crate looks like — no `pub`
//! anywhere, because PyO3's macros expand the wrappers *inside* the crate.
//! RustCall binds it as is (#424): it builds the crate **as the Python
//! extension it already is** and calls the imported module, so every item
//! `#[pymodule]` registers is reachable, including the ones no outside Rust
//! code could name (E0603) and the ones whose signatures need a live
//! interpreter (`Python<'_>`, `Py<T>`, numpy, callables). The Julia package
//! around this crate (`SampleCratePyO3Only.jl`) is that binding.

use pyo3::prelude::*;

/// A free function: `add(a, b)` in Julia and Python.
#[pyfunction]
fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[pyfunction]
fn shout(s: String) -> String {
    format!("{}!", s.to_uppercase())
}

/// A `PyResult`. The host path has an interpreter, so the Julia side gets the
/// **real** message: `RustResult{Int32, String}` with this `PyValueError` text,
/// not the C-ABI path's fixed opaque sentence.
#[pyfunction]
fn parse(s: &str) -> PyResult<i32> {
    s.trim()
        .parse::<i32>()
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))
}

/// A class. `get_all, set_all` expose every field to Python; the Julia side
/// reaches them through the Python object, so they need no `pub` and no wrapper
/// accessor.
#[pyclass(get_all, set_all)]
struct Point {
    x: f64,
    y: f64,
}

#[pymethods]
impl Point {
    /// `#[new]` is the Julia constructor: `Point(3.0, 4.0)`.
    #[new]
    fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }

    /// `#[staticmethod]`: a Julia function `origin()`.
    #[staticmethod]
    fn origin() -> Self {
        Point { x: 0.0, y: 0.0 }
    }

    fn norm(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }

    /// A `&mut self` method: `translate(p, dx, dy)` mutates `p` in place, and
    /// the Julia handle holds the same Python object, so the change is visible.
    fn translate(&mut self, dx: f64, dy: f64) {
        self.x += dx;
        self.y += dy;
    }

    fn label(&self) -> String {
        format!("({}, {})", self.x, self.y)
    }

    /// A `PyResult` method.
    fn scaled(&self, factor: f64) -> PyResult<f64> {
        if factor.is_finite() {
            Ok(self.norm() * factor)
        } else {
            Err(pyo3::exceptions::PyValueError::new_err("factor must be finite"))
        }
    }
}

/// The module initializer Python's importer calls. It is what makes the items
/// above reachable: the host path imports this module, so anything it does not
/// register does not exist as far as Julia is concerned.
#[pymodule]
fn sample_crate_pyo3_only(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(add, m)?)?;
    m.add_function(wrap_pyfunction!(shout, m)?)?;
    m.add_function(wrap_pyfunction!(parse, m)?)?;
    m.add_class::<Point>()?;
    Ok(())
}
