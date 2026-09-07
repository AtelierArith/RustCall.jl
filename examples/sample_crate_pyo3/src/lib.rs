//! Dual-binding crate: Julia + Python (with feature flags)
//!
//! - Build for Julia only: `cargo build --release`
//! - Build for Python: `maturin build --features python` (or
//!   `cargo build --features python`)
//!
//! One definition serves both languages. The Julia half is `#[julia]`, which
//! is **additive** (#279): it keeps the annotated item exactly as written and
//! emits the `extern "C"` entry point next to it (`rustcall_add`,
//! `rustcall_Point_new`, `Point_get_x`, …). The Python half is PyO3's own
//! attributes, which likewise keep the item — so the two stack on the same
//! `fn` / `struct`, and pyo3 stays an *optional* dependency behind the
//! `python` feature. This is the shape `#[julia_pyo3]` is deprecated in favour
//! of (#275 Phase 3); see `docs/src/pyo3.md`, "Migrating from `#[julia_pyo3]`".

// The generated `extern "C"` wrappers take the raw `*const Struct` / `*mut
// Struct` pointers Julia hands back; that is the FFI contract, not an oversight.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use juliacall_macros::julia;

#[cfg(feature = "python")]
use pyo3::prelude::*;

// ============================================================================
// Functions: `#[julia]` for Julia, `#[pyfunction]` for Python — on one item.
//
// `cfg_attr` gates the *item* attribute, so with the `python` feature off the
// crate does not mention pyo3 at all; the Julia entry point is there in both
// builds.
// ============================================================================

#[julia]
#[cfg_attr(feature = "python", pyo3::pyfunction)]
fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[julia]
#[cfg_attr(feature = "python", pyo3::pyfunction)]
fn fibonacci(n: u32) -> u64 {
    match n {
        0 => 0,
        1 => 1,
        _ => {
            let mut a = 0u64;
            let mut b = 1u64;
            for _ in 2..=n {
                let c = a + b;
                a = b;
                b = c;
            }
            b
        }
    }
}

/// A `String` signature: `#[julia]` lowers it to the `(ptr, len)` / owned
/// buffer ABI for Julia, while PyO3's wrapper — and the in-crate caller below —
/// still see `fn shout(String) -> String` (#279).
#[julia]
#[cfg_attr(feature = "python", pyo3::pyfunction)]
pub fn shout(s: String) -> String {
    s.to_uppercase()
}

/// A plain in-crate caller of the annotated function.
#[julia]
pub fn shout_twice(s: String) -> String {
    format!("{} {}", shout(s.clone()), shout(s))
}

// ============================================================================
// A struct with both bindings.
//
// `#[julia]` adds `#[repr(C)]` and emits `Point_free` and the field accessors;
// `#[pyclass(get_all, set_all)]` exposes the same fields to Python. Neither
// attribute rewrites the struct, so they compose.
// ============================================================================

/// A point in the plane, usable from Julia (`Point(x, y)`, `p.x`, …) and, with
/// the `python` feature, from Python (`Point(x, y)`, `p.x`, …).
#[julia]
#[cfg_attr(feature = "python", pyo3::pyclass(get_all, set_all))]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// The Rust methods, and the Julia bindings: each `#[julia]` method gets a
/// wrapper (`rustcall_Point_new`, `rustcall_Point_distance_from_origin`, …)
/// emitted next to this block; the block itself is left as written.
#[julia]
impl Point {
    #[julia]
    pub fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }

    #[julia]
    pub fn distance_from_origin(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }

    #[julia]
    pub fn translate(&mut self, dx: f64, dy: f64) {
        self.x += dx;
        self.y += dy;
    }

    #[julia]
    pub fn scaled(&self, factor: f64) -> Self {
        Point {
            x: self.x * factor,
            y: self.y * factor,
        }
    }
}

/// The Python bindings of the same methods, written as PyO3 code.
///
/// pyo3's *inner* attributes (`#[new]`, `#[getter]`, …) cannot be gated with
/// `cfg_attr` — the outer macro runs before `cfg_attr` expands — so a crate
/// that keeps pyo3 optional writes the `#[pymethods]` block separately under
/// `#[cfg(feature = "python")]`. A type has one inherent method of a given
/// name, hence the `py_` Rust names; `#[pyo3(name = "...")]` restores the
/// Python names, and each body is a one-line delegation to the Rust method.
/// (A crate whose pyo3 dependency is mandatory can put `#[julia]` and
/// `#[pymethods]` on one impl block instead, with `#[julia]` next to `#[new]`.)
#[cfg(feature = "python")]
#[pyo3::pymethods]
impl Point {
    #[new]
    fn py_new(x: f64, y: f64) -> Self {
        Point::new(x, y)
    }

    #[pyo3(name = "distance_from_origin")]
    fn py_distance_from_origin(&self) -> f64 {
        self.distance_from_origin()
    }

    #[pyo3(name = "translate")]
    fn py_translate(&mut self, dx: f64, dy: f64) {
        self.translate(dx, dy)
    }

    #[pyo3(name = "scaled")]
    fn py_scaled(&self, factor: f64) -> Self {
        self.scaled(factor)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The annotated items keep their Rust signature for `#[test]` too (#279).
    #[test]
    fn annotated_functions_are_callable_from_rust() {
        assert_eq!(shout("hi".to_string()), "HI");
        assert_eq!(shout_twice("hi".to_string()), "HI HI");
        assert_eq!(add(2, 3), 5);
        assert_eq!(fibonacci(10), 55);
    }

    #[test]
    fn annotated_methods_are_callable_from_rust() {
        let mut p = Point::new(3.0, 4.0);
        assert_eq!(p.distance_from_origin(), 5.0);
        p.translate(1.0, 2.0);
        assert_eq!((p.x, p.y), (4.0, 6.0));
        let q = p.scaled(2.0);
        assert_eq!((q.x, q.y), (8.0, 12.0));
    }
}

// ============================================================================
// Python module definition (only when feature="python")
// ============================================================================

#[cfg(feature = "python")]
#[pymodule]
fn sample_crate_pyo3(_py: Python, m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(add, m)?)?;
    m.add_function(wrap_pyfunction!(fibonacci, m)?)?;
    m.add_function(wrap_pyfunction!(shout, m)?)?;
    m.add_class::<Point>()?;
    Ok(())
}
