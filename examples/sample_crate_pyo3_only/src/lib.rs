//! A small PyO3 crate with no RustCall attribute anywhere.
//!
//! `RustCall.scan_report(...)` says what a wrapper crate could export from it
//! (#275 Phase 1); `@rust_crate` generates and builds that wrapper crate and
//! binds the result (#275 Phase 2). The `pub` items with interpreter-free
//! signatures are exported as `rustcall_<name>` / `rustcall_<Struct>_<method>`;
//! everything else is reported with a reason.
//!
//! The crate is built by `test/test_pyo3_wrapper.jl`, so everything here must
//! compile: only **one** `#[pymethods]` block per class, because more than one
//! needs pyo3's `multiple-pymethods` feature.

use std::sync::atomic::{AtomicI64, Ordering};

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

/// Wrappable, and deliberately explosive: the generated wrapper catches the
/// panic and Julia raises `RustCall.RustPanicError` instead of the process
/// aborting (#244).
#[pyfunction]
pub fn boom(n: i32) -> i32 {
    if n < 0 {
        panic!("boom: n must not be negative");
    }
    n * 2
}

/// How many `Point`s have been dropped, so a test can prove the generated
/// `Point_free` really runs the Rust destructor.
#[pyfunction]
pub fn dropped_points() -> i64 {
    DROPPED.load(Ordering::SeqCst)
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

static DROPPED: AtomicI64 = AtomicI64::new(0);

#[pyclass]
pub struct Point {
    #[pyo3(get, set)]
    pub x: f64,
    #[pyo3(get)]
    pub y: f64,
}

impl Drop for Point {
    fn drop(&mut self) {
        DROPPED.fetch_add(1, Ordering::SeqCst);
    }
}

#[pymethods]
impl Point {
    #[new]
    pub fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }

    #[staticmethod]
    pub fn origin() -> Self {
        Point { x: 0.0, y: 0.0 }
    }

    pub fn norm(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }

    /// A `#[getter]`: an ordinary method from the C side.
    #[getter]
    pub fn sum(&self) -> f64 {
        self.x + self.y
    }

    /// A `#[setter]`: `&mut self`, so the wrapper takes `*mut Point`.
    #[setter]
    pub fn set_both(&mut self, value: f64) {
        self.x = value;
        self.y = value;
    }

    /// A `PyResult` method: the error is opaque on the Julia side.
    pub fn scaled(&self, factor: f64) -> PyResult<f64> {
        if factor.is_finite() {
            Ok(self.norm() * factor)
        } else {
            Err(pyo3::exceptions::PyValueError::new_err("factor must be finite"))
        }
    }

    /// A `String`-returning method: an owned buffer released through
    /// `Point_label_free_rust_string`.
    pub fn label(&self) -> String {
        format!("({}, {})", self.x, self.y)
    }
}

/// Skipped: a module initializer only means something to Python's importer.
#[pymodule]
fn sample_crate_pyo3_only(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(add, m)?)?;
    m.add_class::<Point>()?;
    Ok(())
}
