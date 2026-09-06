use pyo3::prelude::*;
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
#[pyfunction]
fn private_add(a: i32, b: i32) -> i32 {
    a + b
}
#[pyfunction]
pub(crate) fn crate_add(a: i32, b: i32) -> i32 {
    a + b
}
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
#[pyfunction]
pub fn identity<T>(x: T) -> T {
    x
}
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
        Point { x, y, tag, hidden: 0.0 }
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
/// Stacking is possible since #279 (`#[julia]` is additive). `#[julia]` already
/// exports `rustcall_dual`, so the PyO3 scan must not report a second wrapper
/// for it; the entry in the manifest is the `#[julia]` one.
#[pyfunction]
pub fn dual(a: i32, b: i32) -> i32 {
    a + b
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_DUAL : ::std::cell::RefCell < ::std::option::Option
    < ::std::string::String >> = ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_dual_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_DUAL
        .with(|rustcall_slot| {
            let mut rustcall_slot = rustcall_slot.borrow_mut();
            let rustcall_len = match rustcall_slot.as_ref() {
                ::std::option::Option::Some(message) => {
                    let bytes = message.as_bytes();
                    if bytes.len() <= cap && !out.is_null() {
                        unsafe {
                            ::std::ptr::copy_nonoverlapping(
                                bytes.as_ptr(),
                                out,
                                bytes.len(),
                            );
                        }
                        Some(bytes.len())
                    } else {
                        return bytes.len();
                    }
                }
                ::std::option::Option::None => ::std::option::Option::None,
            };
            match rustcall_len {
                ::std::option::Option::Some(n) => {
                    *rustcall_slot = ::std::option::Option::None;
                    n
                }
                ::std::option::Option::None => 0,
            }
        })
}
#[no_mangle]
pub extern "C" fn rustcall_dual(a: i32, b: i32) -> i32 {
    match ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| { dual(a, b) })) {
        ::std::result::Result::Ok(rustcall_value) => rustcall_value,
        ::std::result::Result::Err(rustcall_payload) => {
            let rustcall_message: ::std::string::String = if let ::std::option::Option::Some(
                s,
            ) = rustcall_payload.downcast_ref::<&'static str>()
            {
                ::std::string::ToString::to_string(s)
            } else if let ::std::option::Option::Some(s) = rustcall_payload
                .downcast_ref::<::std::string::String>()
            {
                s.clone()
            } else {
                ::std::string::ToString::to_string("Box<dyn Any>")
            };
            let rustcall_message = ::std::format!(
                "{} panicked: {}", "dual", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_DUAL
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            unsafe { ::std::mem::zeroed::<i32>() }
        }
    }
}
#[pymodule]
fn demo(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(add, m)?)?;
    Ok(())
}
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
pub mod out_of_line;
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
