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

fn private_default() -> i32 {
    37
}

/// Wrappable: `pub`, scalars only.
#[pyfunction]
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

/// The generated wrapper must call PyO3's original dispatcher: this default
/// helper is private and cannot be named from the external wrapper crate.
#[pyfunction(signature = (value = private_default()))]
pub fn defaulted(value: i32) -> i32 {
    value
}

/// A defaulted Python-dispatched function with an aggregate/string return.
#[pyfunction(signature = (value = private_default()))]
pub fn defaulted_result(value: i32) -> PyResult<String> {
    Ok(format!("defaulted:{value}"))
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

/// An owned string nested in `PyResult`; the wrapper must release only the
/// active success payload and must never inspect the error slot on failure.
#[pyfunction]
pub fn render(ok: bool) -> PyResult<String> {
    ok.then(|| "rendered".repeat(1024))
        .ok_or_else(|| pyo3::exceptions::PyValueError::new_err("render failed"))
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

#[pyfunction]
pub fn dropped_fallible() -> i64 {
    FALLIBLE_DROPPED.load(Ordering::SeqCst)
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
static FALLIBLE_DROPPED: AtomicI64 = AtomicI64::new(0);
static INHERITED_DROPPED: AtomicI64 = AtomicI64::new(0);

#[pyfunction]
pub fn dropped_inherited() -> i64 {
    INHERITED_DROPPED.load(Ordering::SeqCst)
}

// Python-side layout/typing options do not change the native Rust Point value
// that the wrapper owns. `generic` here enables Python generic aliases; this
// is not a Rust struct with unbound type parameters (#303).
#[pyclass(subclass, dict, weakref, generic)]
pub struct Point {
    #[pyo3(get, set)]
    pub x: f64,
    #[pyo3(get)]
    pub y: f64,
    /// `#[pyo3(set)]` alone: write-only from Python, so the wrapper exports
    /// the setter and no getter; `scaled_norm` is how a test observes the
    /// write.
    #[pyo3(set)]
    pub scale: f64,
}

impl Drop for Point {
    fn drop(&mut self) {
        DROPPED.fetch_add(1, Ordering::SeqCst);
    }
}

trait Norm {
    fn norm_value(&self) -> f64;
}

impl Norm for Point {
    fn norm_value(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
}

#[pymethods]
impl Point {
    #[new]
    pub fn new(x: f64, y: f64) -> Self {
        Point { x, y, scale: 1.0 }
    }

    #[staticmethod]
    pub fn origin() -> Self {
        Point {
            x: 0.0,
            y: 0.0,
            scale: 1.0,
        }
    }

    pub fn norm(&self) -> f64 {
        // PyO3 exposes an inherent bridge, not a #[pymethods] trait impl.
        Norm::norm_value(self)
    }

    /// Reads the write-only `scale` field, so a test can prove its setter ran.
    pub fn scaled_norm(&self) -> f64 {
        self.norm() * self.scale
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

    /// An owned-string success payload nested in the aggregate.
    pub fn try_label(&self, ok: bool) -> PyResult<String> {
        ok.then(|| format!("({}, {})", self.x, self.y).repeat(512))
            .ok_or_else(|| pyo3::exceptions::PyValueError::new_err("label failed"))
    }

    /// A class value nested in the aggregate. The generated wrapper boxes it,
    /// and Julia binds that box to the same library generation's destructor.
    pub fn shifted(&self, by: f64) -> PyResult<Self> {
        if by.is_finite() {
            Ok(Point {
                x: self.x + by,
                y: self.y + by,
                scale: self.scale,
            })
        } else {
            Err(pyo3::exceptions::PyValueError::new_err("shift must be finite"))
        }
    }

    /// A `String`-returning method: an owned buffer released through
    /// `Point_label_free_rust_string`.
    pub fn label(&self) -> String {
        format!("({}, {})", self.x, self.y)
    }
}

/// A separate class whose Python constructor itself can fail. This pins the
/// `#[new] -> PyResult<Self>` wrapper shape without changing `Point`'s API.
#[pyclass]
pub struct Fallible {
    value: i32,
}

impl Drop for Fallible {
    fn drop(&mut self) {
        FALLIBLE_DROPPED.fetch_add(1, Ordering::SeqCst);
    }
}

#[pymethods]
impl Fallible {
    #[new]
    pub fn new(value: i32) -> PyResult<Self> {
        if value >= 0 {
            Ok(Self { value })
        } else {
            Err(pyo3::exceptions::PyValueError::new_err(
                "value must be non-negative",
            ))
        }
    }

    pub fn fallible_value(&self) -> i32 {
        self.value
    }
}

#[pyclass(subclass)]
pub struct BaseCounter {
    #[pyo3(get)]
    pub base: i32,
}

#[pyclass(extends = BaseCounter)]
pub struct InheritedCounter {
    #[pyo3(get, set)]
    pub value: i32,
    #[pyo3(get, set)]
    pub samples: Vec<i32>,
}

impl Drop for InheritedCounter {
    fn drop(&mut self) {
        INHERITED_DROPPED.fetch_add(1, Ordering::SeqCst);
    }
}

#[pymethods]
impl InheritedCounter {
    #[new]
    #[pyo3(signature = (value = private_default()))]
    pub fn new(value: i32) -> PyResult<(Self, BaseCounter)> {
        Ok((
            Self {
                value,
                samples: vec![value, 11],
            },
            BaseCounter { base: 11 },
        ))
    }

    #[pyo3(signature = (amount = private_default()))]
    pub fn increment(&mut self, amount: i32) -> i32 {
        self.value += amount;
        self.value
    }

    #[pyo3(signature = (suffix = private_default()))]
    pub fn defaulted_label(&self, suffix: i32) -> PyResult<String> {
        Ok(format!("{}:{suffix}", self.value))
    }

    #[getter]
    pub fn doubled(&self) -> i32 {
        self.value * 2
    }

    #[setter(doubled)]
    pub fn set_doubled(&mut self, value: i32) {
        self.value = value / 2;
    }
}

/// Skipped: a module initializer only means something to Python's importer.
#[pymodule]
fn sample_crate_pyo3_only(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(add, m)?)?;
    m.add_class::<Point>()?;
    Ok(())
}
