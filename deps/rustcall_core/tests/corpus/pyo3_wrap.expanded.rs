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
/// Refused (`symbol_collision:add`): its wrapper symbol would be
/// `rustcall_add_take_panic`, which is the panic reader `add`'s wrapper
/// already exports.
#[pyfunction]
pub fn add_take_panic() -> i32 {
    0
}
/// `&str` in, `&str` out with no string argument to borrow from — a borrowed
/// view.
#[pyfunction]
pub fn tag() -> &'static str {
    "tag"
}
/// `&str` in and `&str` out: the result may point into the owned value the
/// wrapper built from the argument, so it leaves as an owned copy
/// (`echo_RustCallOwnedString`), never as a view.
#[pyfunction]
pub fn echo(s: &str) -> &str {
    s
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
        /// Refused under a lenient scan: the scan cannot decide whether the
        /// field exists in the build the wrapper is compiled against, so no
        /// accessor is emitted for it.
        #[cfg(feature = "extra")]
        #[pyo3(get)]
        pub extra: f64,
        #[pyo3(get)]
        pub name: String,
        /// Not bound: there is no `Vec` ABI on the Julia side yet, so the scan
        /// gives it no accessor rather than one the binding cannot use (#303).
        #[pyo3(get)]
        pub tags: Vec<i32>,
    }
    #[pymethods]
    impl Rect {
        #[new]
        pub fn new(w: f64) -> Self {
            Rect {
                w,
                depth: 0.0,
                #[cfg(feature = "extra")]
                extra: 0.0,
                name: String::new(),
                tags: Vec::new(),
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
        /// Refused under a lenient scan (`cfg_undecided`): a member's own
        /// `#[cfg]` is as undecidable as an item's.
        #[cfg(feature = "extra")]
        pub fn extra_area(&self) -> f64 {
            self.w
        }
    }
    /// A method *named* `new` that is not a constructor: without `#[new]` and
    /// without a `Self` return it is an ordinary static method returning an
    /// `i32`, and the wrapper must not box it as a `*mut Counter`.
    #[pyclass]
    pub struct Counter {}
    #[pymethods]
    impl Counter {
        #[staticmethod]
        pub fn new() -> i32 {
            0
        }
    }
}
