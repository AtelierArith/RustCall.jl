//! Corpus for the #275 Phase-2 wrapper generator: every lowering it has to
//! get right, and every shape it has to refuse.
//!
//! The `.wrap.rs` golden is the `lib.rs` the wrapper crate gets, and
//! `.wrap.toml` is the manifest that describes it — `exported = true` and a
//! filled-in `return_abi` for what was emitted, a `skip_reason` for what was
//! not. Nothing here is compiled: `test/test_pyo3_wrapper.jl` builds a real
//! wrapper crate against `examples/sample_crate_pyo3_only`.
use pyo3::prelude::*;
/// Scalars: passed through as written.
#[pyfunction]
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}
/// `String` in and out: a `(ptr, len)` pair in, an owned buffer out.
#[pyfunction]
pub fn shout(s: String) -> String {
    s
}
/// `&str` in, `&str` out with no string argument to borrow from — a borrowed
/// view.
#[pyfunction]
pub fn tag() -> &'static str {
    "tag"
}
/// `PyResult<T>` with a scalar payload: a `CResult` whose error is the opaque
/// code, produced by dropping the `PyErr`.
#[pyfunction]
pub fn parse(s: &str) -> PyResult<i32> {
    let _ = s;
    Ok(0)
}
/// `PyResult<()>`: success or failure only, so the `Ok` slot is a `u8`.
#[pyfunction]
pub fn check(flag: bool) -> PyResult<()> {
    let _ = flag;
    Ok(())
}
/// Refused: a `PyResult` payload that cannot sit inside the `CResult`
/// aggregate.
#[pyfunction]
pub fn render() -> PyResult<String> {
    Ok(String::new())
}
/// Refused: the return type does not cross the C ABI.
#[pyfunction]
pub fn numbers() -> Vec<i32> {
    Vec::new()
}
/// Refused: an argument type that is neither FFI-compatible nor a string.
#[pyfunction]
pub fn total(values: Vec<i32>) -> i32 {
    values.iter().sum()
}
/// A plain `Result` on a `#[pyfunction]`: both payloads are FFI-compatible, so
/// it is the same `CResult` the `#[julia]` path produces.
#[pyfunction]
pub fn divide(a: i32, b: i32) -> Result<i32, i32> {
    if b == 0 { Err(0) } else { Ok(a / b) }
}
/// An `Option` return, likewise.
#[pyfunction]
pub fn maybe(x: f64) -> Option<f64> {
    Some(x)
}
/// A unit return.
#[pyfunction]
pub fn note(x: i32) {
    let _ = x;
}
pub mod geometry {
    use pyo3::prelude::*;
    /// The wrapper calls `user_crate::geometry::area`.
    #[pyfunction]
    pub fn area(w: f64, h: f64) -> f64 {
        w * h
    }
    #[pyclass]
    pub struct Rect {
        #[pyo3(get, set)]
        pub w: f64,
        /// `#[pyo3(set)]` alone: a setter with no getter, so the wrapper
        /// emits `rustcall_Rect_set_depth` and nothing reads the field.
        #[pyo3(set)]
        pub depth: f64,
        #[pyo3(get)]
        pub name: String,
    }
    #[pymethods]
    impl Rect {
        #[new]
        pub fn new(w: f64) -> Self {
            Rect {
                w,
                depth: 0.0,
                name: String::new(),
            }
        }
        #[staticmethod]
        pub fn unit() -> Self {
            Rect::new(1.0)
        }
        pub fn area(&self) -> f64 {
            self.w * self.w
        }
        pub fn scale(&mut self, factor: f64) {
            self.w *= factor;
        }
        pub fn label(&self) -> String {
            self.name.clone()
        }
        pub fn scaled(&self, factor: f64) -> PyResult<f64> {
            Ok(self.w * factor)
        }
        /// Refused: the wrapper cannot return the class by value from a
        /// non-`Self` type.
        pub fn parts(&self) -> Vec<f64> {
            vec![self.w]
        }
        /// Refused: a plain `Result` on a *method*. The `#[julia]` method
        /// wrappers have never lowered one, so Julia's method emitters cannot
        /// decode a `CResult` (#303).
        pub fn checked(&self) -> Result<f64, i32> {
            Ok(self.w)
        }
        /// Refused for the same reason.
        pub fn maybe_w(&self) -> Option<f64> {
            Some(self.w)
        }
    }
}
