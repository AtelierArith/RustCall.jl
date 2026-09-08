//! A small crate written for PyO3, and for PyO3 only.
//!
//! There is no RustCall attribute in this file and no RustCall dependency in
//! `Cargo.toml`: this is what a PyO3 extension crate looks like before anyone
//! thinks of Julia. RustCall binds it as is (#275 Phase 2): it scans the `pub`
//! items PyO3 exposes, generates a wrapper crate that depends on this one and
//! exports one `extern "C"` entry point per item (`rustcall_<name>`,
//! `rustcall_Counter_<method>`, `Counter_free`, ...), builds it, and binds the
//! result.
//!
//! The Julia package around this crate (`RustCrateMacroPyO3Only.jl`) does that
//! with the **`@rust_crate` macro**, at the package's top level: no generated
//! file, no build step. `../../../SampleCratePyO3Only.jl` binds a crate of the
//! same shape the other way, with `write_bindings_to_file` in a
//! `deps/build.jl`.
//!
//! Two rules to keep a crate wrappable: every item Julia should see must be
//! `pub` (pyo3 does not need that, a wrapper crate compiled outside does), and
//! a class has **one** `#[pymethods]` block unless the crate enables pyo3's
//! `multiple-pymethods` feature.

use pyo3::prelude::*;

/// A free function: `rustcall_scale` in the wrapper, `scale(x, k)` in Julia.
#[pyfunction]
pub fn scale(x: i32, k: i32) -> i32 {
    x * k
}

/// Strings cross as `(ptr, len)` pairs; the returned `String` is released
/// through a generated `..._free_rust_string`.
#[pyfunction]
pub fn join_words(a: String, b: String) -> String {
    format!("{} {}", a.trim(), b.trim())
}

/// `PyResult<T>` becomes `RustResult{T, String}` in Julia, with an *opaque*
/// error: creating and dropping a `PyErr` needs no interpreter, but rendering
/// one does, so the generated code never looks at it and Julia reports
/// `RustCall.PYO3_OPAQUE_ERROR` instead of this message.
#[pyfunction]
pub fn checked_div(a: i32, b: i32) -> PyResult<i32> {
    if b == 0 {
        Err(pyo3::exceptions::PyZeroDivisionError::new_err(
            "division by zero",
        ))
    } else {
        Ok(a / b)
    }
}

/// A class: an opaque handle in Julia, freed by the generated `Counter_free`,
/// which runs this type's destructor. `get_all, set_all` exposes every `pub`
/// field, so `c.value` and `c.value = 1` work in Julia as they do in Python.
#[pyclass(get_all, set_all)]
pub struct Counter {
    pub value: i64,
    pub step: i64,
}

#[pymethods]
impl Counter {
    /// `#[new]` is the Julia constructor: `Counter(0, 2)`.
    #[new]
    pub fn new(value: i64, step: i64) -> Self {
        Counter { value, step }
    }

    /// `#[staticmethod]`: a module-level Julia function, `zeroed()`.
    #[staticmethod]
    pub fn zeroed() -> Self {
        Counter { value: 0, step: 1 }
    }

    /// `&mut self` method: `bump(c)` mutates `c` in place and returns the new
    /// value.
    pub fn bump(&mut self) -> i64 {
        self.value += self.step;
        self.value
    }

    /// `&self` method: `current(c)`.
    pub fn current(&self) -> i64 {
        self.value
    }

    /// A `String`-returning method: an owned buffer, released by the wrapper.
    pub fn describe(&self) -> String {
        format!("{} (+{})", self.value, self.step)
    }

    /// A `PyResult` method: `RustResult{Int64, String}` on the Julia side,
    /// with the same opaque error as `checked_div`.
    pub fn advance(&mut self, times: i64) -> PyResult<i64> {
        if times < 0 {
            return Err(pyo3::exceptions::PyValueError::new_err(
                "times must not be negative",
            ));
        }
        self.value += self.step * times;
        Ok(self.value)
    }
}

/// The module initializer Python's importer calls. RustCall skips it: it means
/// nothing outside an interpreter, and the scan says so.
#[pymodule]
fn macro_pyo3_only(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(scale, m)?)?;
    m.add_function(wrap_pyfunction!(join_words, m)?)?;
    m.add_function(wrap_pyfunction!(checked_div, m)?)?;
    m.add_class::<Counter>()?;
    Ok(())
}
