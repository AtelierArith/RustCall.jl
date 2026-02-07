//! Dual-binding crate: Julia + Python (with feature flags)
//!
//! - Build for Julia only: `cargo build --release`
//! - Build for Python: `maturin build` or `cargo build --features python`
//!
//! This example demonstrates the unified `#[julia_pyo3]` macro that generates
//! both Julia FFI bindings and Python/PyO3 bindings from a single definition.

use rustcall_macros::julia_pyo3;

#[cfg(feature = "python")]
use pyo3::prelude::*;

// ============================================================================
// Unified function bindings (#[julia_pyo3])
// - Julia build: generates #[no_mangle] pub extern "C" fn
// - Python build: generates #[pyfunction]
// ============================================================================

#[julia_pyo3]
fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[julia_pyo3]
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

// ============================================================================
// Unified Point struct with both Julia and Python bindings
// ============================================================================

/// Point struct with dual Julia/Python bindings
///
/// This single definition generates:
/// - Julia: `#[repr(C)]` + FFI functions (Point_free, Point_get_x, Point_set_x, etc.)
/// - Python: `#[pyclass(get_all, set_all)]` when feature="python"
#[julia_pyo3]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// Methods for Point with dual bindings
///
/// This single impl block generates:
/// - Julia: FFI wrappers (Point_new, Point_distance_from_origin)
/// - Python: `#[pymethods]` impl with `#[new]` for constructor
#[julia_pyo3]
impl Point {
    pub fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }

    pub fn distance_from_origin(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }

    pub fn translate(&mut self, dx: f64, dy: f64) {
        self.x += dx;
        self.y += dy;
    }

    pub fn scaled(&self, factor: f64) -> Self {
        Point {
            x: self.x * factor,
            y: self.y * factor,
        }
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
    m.add_class::<Point>()?;
    Ok(())
}
