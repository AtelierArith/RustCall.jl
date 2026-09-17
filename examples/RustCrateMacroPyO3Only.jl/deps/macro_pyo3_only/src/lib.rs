//! A small crate written for PyO3, and for PyO3 only.
//!
//! There is no RustCall attribute in this file and no RustCall dependency in
//! `Cargo.toml`, and no `pub` anywhere: PyO3's macros expand the wrappers
//! *inside* the crate, so this is what a real extension module looks like.
//! RustCall binds it as is (#424): it builds the crate as the Python extension
//! it already is, imports it, and calls the imported module. The Julia package
//! around this crate (`RustCrateMacroPyO3Only.jl`) does that with the
//! **`@rust_crate` macro**, at the package's top level: no generated file, no
//! build step. `../../../SampleCratePyO3Only.jl` binds a crate of the same
//! shape differently — same host path, different front door.

use pyo3::prelude::*;

/// A free function: `scale(x, k)` in Julia and Python.
#[pyfunction]
fn scale(x: i32, k: i32) -> i32 {
    x * k
}

#[pyfunction]
fn join_words(a: String, b: String) -> String {
    format!("{} {}", a.trim(), b.trim())
}

/// A `PyResult`. The host path has an interpreter, so the Julia side gets the
/// **real** message from the exception, not the C-ABI path's fixed opaque
/// sentence.
///
/// Both ways an `i32` division can fail are errors, not panics: `b == 0`, and
/// `i32::MIN / -1`, whose quotient does not fit — Rust's `/` panics on that one
/// even in release builds. `checked_div` returns `None` for both.
#[pyfunction]
fn checked_div(a: i32, b: i32) -> PyResult<i32> {
    if b == 0 {
        return Err(pyo3::exceptions::PyZeroDivisionError::new_err(
            "division by zero",
        ));
    }
    a.checked_div(b)
        .ok_or_else(|| pyo3::exceptions::PyOverflowError::new_err("quotient does not fit in i32"))
}

/// A class. `get_all, set_all` expose every field to Python; the Julia side
/// reaches them through the Python object (the same object `&mut self` methods
/// mutate), so they need no `pub`.
#[pyclass(get_all, set_all)]
struct Counter {
    value: i64,
    step: i64,
}

#[pymethods]
impl Counter {
    /// `#[new]` is the Julia constructor: `Counter(0, 2)`.
    #[new]
    fn new(value: i64, step: i64) -> Self {
        Counter { value, step }
    }

    /// `#[staticmethod]`: a Julia function `zeroed()`.
    #[staticmethod]
    fn zeroed() -> Self {
        Counter { value: 0, step: 1 }
    }

    /// A `&mut self` method: `bump(c)` mutates `c` in place and returns the new
    /// value.
    fn bump(&mut self) -> i64 {
        self.value += self.step;
        self.value
    }

    fn current(&self) -> i64 {
        self.value
    }

    fn describe(&self) -> String {
        format!("{} (+{})", self.value, self.step)
    }

    /// A `PyResult` method.
    fn advance(&mut self, times: i64) -> PyResult<i64> {
        if times < 0 {
            return Err(pyo3::exceptions::PyValueError::new_err(
                "times must not be negative",
            ));
        }
        self.value += self.step * times;
        Ok(self.value)
    }
}

/// The module initializer Python's importer calls. The host path imports this
/// module, so anything it does not register does not exist for Julia.
#[pymodule]
fn macro_pyo3_only(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(scale, m)?)?;
    m.add_function(wrap_pyfunction!(join_words, m)?)?;
    m.add_function(wrap_pyfunction!(checked_div, m)?)?;
    m.add_class::<Counter>()?;
    Ok(())
}
