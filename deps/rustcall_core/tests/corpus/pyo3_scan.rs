// PyO3 crate scan (#275 Phase 1): a crate that carries only PyO3 attributes.
// Nothing here is a RustCall item except the one function that deliberately
// stacks `#[julia]` on top of `#[pyfunction]`.

use pyo3::prelude::*;

// --- plain wrappable functions ---------------------------------------------

#[pyfunction]
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

/// `pyo3::`-qualified spelling of the same attribute.
#[pyo3::pyfunction]
pub fn shout(s: String) -> String {
    format!("{}!", s.to_uppercase())
}

/// Renamed on the Python side; the Rust name is what a wrapper crate calls.
#[pyfunction]
#[pyo3(name = "double_it")]
pub fn double(x: f64) -> f64 {
    x * 2.0
}

// --- skipped: not reachable from a wrapper crate ---------------------------

#[pyfunction]
fn private_add(a: i32, b: i32) -> i32 {
    a + b
}

#[pyfunction]
pub(crate) fn crate_add(a: i32, b: i32) -> i32 {
    a + b
}

// --- skipped: the signature needs a live interpreter -----------------------

#[pyfunction]
pub fn with_python(py: Python<'_>) -> i32 {
    let _ = py;
    0
}

#[pyfunction]
pub fn takes_any(obj: &PyAny) -> usize {
    let _ = obj;
    0
}

#[pyfunction]
pub fn takes_bound(obj: Bound<'_, PyList>) -> usize {
    let _ = obj;
    0
}

#[pyfunction]
pub fn returns_object() -> PyObject {
    unimplemented!()
}

#[pyfunction]
pub fn returns_py_of() -> Py<PyList> {
    unimplemented!()
}

// --- PyResult: wrappable, with an opaque error -----------------------------

#[pyfunction]
pub fn parse(s: &str) -> PyResult<i32> {
    s.trim()
        .parse::<i32>()
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))
}

/// The `Ok` type is still checked: this one is not wrappable.
#[pyfunction]
pub fn parse_object(s: &str) -> PyResult<PyObject> {
    let _ = s;
    unimplemented!()
}

// --- skipped: generic ------------------------------------------------------

#[pyfunction]
pub fn identity<T>(x: T) -> T {
    x
}

// --- a #[pyclass] with several #[pymethods] blocks -------------------------

#[pyclass]
pub struct Point {
    #[pyo3(get, set)]
    pub x: f64,
    #[pyo3(get)]
    pub y: f64,
    #[pyo3(get, name = "label")]
    pub tag: String,
    /// No `#[pyo3(get)]`: pyo3 does not expose it, so neither does the scan.
    pub hidden: f64,
}

#[pymethods]
impl Point {
    #[new]
    pub fn new(x: f64, y: f64, tag: String) -> Self {
        Point {
            x,
            y,
            tag,
            hidden: 0.0,
        }
    }

    pub fn norm(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }

    pub fn scale(&mut self, factor: f64) {
        self.x *= factor;
        self.y *= factor;
    }
}

/// A second `#[pymethods]` block for the same class: its methods join the
/// first block's, in source order.
#[pymethods]
impl Point {
    #[staticmethod]
    pub fn origin() -> Self {
        Point {
            x: 0.0,
            y: 0.0,
            tag: String::new(),
            hidden: 0.0,
        }
    }

    #[classmethod]
    pub fn from_class(cls: &Bound<'_, pyo3::types::PyType>) -> Self {
        let _ = cls;
        Point::origin()
    }

    #[getter]
    pub fn sum(&self) -> f64 {
        self.x + self.y
    }

    #[setter(x)]
    pub fn set_x(&mut self, value: f64) {
        self.x = value;
    }

    pub fn as_object(&self) -> PyObject {
        unimplemented!()
    }
}

/// A non-`pub` class: neither it nor its methods can be reached.
#[pyclass]
struct Secret {
    #[pyo3(get)]
    value: i32,
}

#[pymethods]
impl Secret {
    #[new]
    fn new(value: i32) -> Self {
        Secret { value }
    }
}

// --- an item owned by #[julia] ---------------------------------------------

/// Stacking is possible since #279 (`#[julia]` is additive). `#[julia]` already
/// exports `rustcall_dual`, so the PyO3 scan must not report a second wrapper
/// for it; the entry in the manifest is the `#[julia]` one.
#[julia]
#[pyfunction]
pub fn dual(a: i32, b: i32) -> i32 {
    a + b
}

// --- a module initialiser --------------------------------------------------

#[pymodule]
fn demo(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(add, m)?)?;
    Ok(())
}

// --- inside modules --------------------------------------------------------

pub mod nested {
    use pyo3::prelude::*;

    #[pyfunction]
    pub fn deep(a: i32) -> i32 {
        a
    }
}

mod private_mod {
    use pyo3::prelude::*;

    /// `pub` but inside a private module: still unreachable from outside.
    #[pyfunction]
    pub fn unreachable_add(a: i32) -> i32 {
        a
    }
}

// An out-of-line module: its body is in another file, so a single-file scan
// only records the declaration. `rustcall-extract --crate-root` follows it.
pub mod out_of_line;

// --- optional pyo3, written with cfg_attr ----------------------------------

/// The `:python_free` shape: the marker is behind a feature gate. The crate
/// scan evaluates `#[cfg]` leniently, so the `cfg_attr` is still there when the
/// scan looks and the marker has to be read through it.
#[cfg_attr(feature = "python", pyfunction)]
pub fn gated_add(a: i32, b: i32) -> i32 {
    a + b
}

#[cfg_attr(feature = "python", pyclass)]
pub struct GatedPoint {
    #[cfg_attr(feature = "python", pyo3(get, set))]
    pub x: f64,
    /// Private, so pyo3 exposes it to Python but a wrapper crate cannot read it.
    #[pyo3(get)]
    hidden_but_gettable: f64,
}

#[cfg_attr(feature = "python", pymethods)]
impl GatedPoint {
    #[cfg_attr(feature = "python", new)]
    pub fn new(x: f64) -> Self {
        GatedPoint {
            x,
            hidden_but_gettable: 0.0,
        }
    }

    /// A `PyResult` method: wrappable, and the manifest records the Ok type so
    /// Phase 2 need not re-read the Rust type.
    pub fn checked(&self) -> PyResult<f64> {
        Ok(self.x)
    }
}
