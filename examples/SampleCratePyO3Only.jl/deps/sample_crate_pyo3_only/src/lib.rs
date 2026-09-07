//! A small crate written for PyO3, and for PyO3 only.
//!
//! There is no RustCall attribute in this file and no RustCall dependency in
//! `Cargo.toml`: this is what a PyO3 extension crate looks like before anyone
//! thinks of Julia. RustCall binds it as is (#275 Phase 2): it scans the
//! `pub` items PyO3 exposes, generates a wrapper crate that depends on this
//! one and exports one `extern "C"` entry point per item
//! (`rustcall_<name>`, `rustcall_Point_<method>`, `Point_free`, ...), builds
//! it, and binds the result. The Julia package around this crate
//! (`SampleCratePyO3Only.jl`) is that binding.
//!
//! Two rules to keep a crate wrappable: every item Julia should see must be
//! `pub` (pyo3 does not need that, a wrapper crate compiled outside does), and
//! a class has **one** `#[pymethods]` block unless the crate enables pyo3's
//! `multiple-pymethods` feature.

use pyo3::prelude::*;

/// A free function: `rustcall_add` in the wrapper, `add(a, b)` in Julia.
#[pyfunction]
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

/// Strings cross as `(ptr, len)` pairs; the returned `String` is released
/// through a generated `..._free_rust_string`.
#[pyfunction]
pub fn shout(s: String) -> String {
    format!("{}!", s.to_uppercase())
}

/// `PyResult<T>` becomes `RustResult{T, String}` in Julia, with an *opaque*
/// error: creating and dropping a `PyErr` needs no interpreter, but rendering
/// one does, so the generated code never looks at it and Julia reports
/// `RustCall.PYO3_OPAQUE_ERROR` instead of this message.
#[pyfunction]
pub fn parse(s: &str) -> PyResult<i32> {
    s.trim()
        .parse::<i32>()
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))
}

/// A class: an opaque handle in Julia, freed by the generated `Point_free`,
/// which runs this type's destructor. `get_all, set_all` exposes every `pub`
/// field, so `p.x` and `p.x = 1.0` work in Julia as they do in Python.
#[pyclass(get_all, set_all)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[pymethods]
impl Point {
    /// `#[new]` is the Julia constructor: `Point(3.0, 4.0)`.
    #[new]
    pub fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }

    /// `#[staticmethod]`: a module-level Julia function, `origin()`.
    #[staticmethod]
    pub fn origin() -> Self {
        Point { x: 0.0, y: 0.0 }
    }

    /// `&self` method: `norm(p)`.
    pub fn norm(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }

    /// `&mut self` method: `translate(p, dx, dy)` mutates `p` in place.
    pub fn translate(&mut self, dx: f64, dy: f64) {
        self.x += dx;
        self.y += dy;
    }

    /// A `String`-returning method: an owned buffer, released by the wrapper.
    pub fn label(&self) -> String {
        format!("({}, {})", self.x, self.y)
    }

    /// A `PyResult` method: `RustResult{Float64, String}` on the Julia side,
    /// with the same opaque error as `parse`.
    pub fn scaled(&self, factor: f64) -> PyResult<f64> {
        if factor.is_finite() {
            Ok(self.norm() * factor)
        } else {
            Err(pyo3::exceptions::PyValueError::new_err("factor must be finite"))
        }
    }
}

/// The module initializer Python's importer calls. RustCall skips it: it means
/// nothing outside an interpreter, and the scan says so.
#[pymodule]
fn sample_crate_pyo3_only(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(add, m)?)?;
    m.add_function(wrap_pyfunction!(shout, m)?)?;
    m.add_function(wrap_pyfunction!(parse, m)?)?;
    m.add_class::<Point>()?;
    Ok(())
}
