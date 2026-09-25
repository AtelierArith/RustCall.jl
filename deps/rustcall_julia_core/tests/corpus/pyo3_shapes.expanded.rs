use numpy::PyReadonlyArray1;
use pyo3::prelude::*;
/// Shadows `std::option::Option` for the bare name, crate-wide.
pub struct Option<T>(pub T);
#[pyclass]
pub struct Node {
    #[pyo3(get, set)]
    pub level: i32,
    #[pyo3(get)]
    pub label: String,
}
#[pymethods]
impl Node {
    #[new]
    pub fn new(level: i32) -> Self {
        Node {
            level,
            label: String::new(),
        }
    }
    pub fn twin(&self, py: Python<'_>) -> PyResult<Py<Self>> {
        Py::new(
            py,
            Node {
                level: self.level,
                label: String::new(),
            },
        )
    }
    pub fn adopt(&mut self, other: PyRef<'_, Self>) {
        self.level = other.level;
    }
    pub fn maybe(&self, other: std::option::Option<PyRef<'_, Node>>) -> i32 {
        other.map(|o| o.level).unwrap_or(0)
    }
    pub fn own(&self, other: crate::Option<i32>) -> i32 {
        other.0
    }
    pub fn shadowed(&self, other: Option<i32>) -> i32 {
        other.0
    }
    pub fn many(&self, others: Vec<Bound<'_, Node>>) -> usize {
        others.len()
    }
    pub fn sum(&self, values: PyReadonlyArray1<'_, f64>) -> f64 {
        values.as_array().sum()
    }
}
#[pyfunction]
pub fn make(level: i32) -> Node {
    Node {
        level,
        label: String::new(),
    }
}
#[pyfunction]
pub fn find(
    nodes: std::vec::Vec<pyo3::Py<Node>>,
    name: &str,
) -> core::option::Option<Py<Node>> {
    let _ = name;
    nodes.into_iter().next()
}
#[pyfunction]
pub fn anything(x: Py<PyAny>) -> Py<PyAny> {
    x
}
#[pyfunction]
#[pyo3(pass_module)]
pub fn module_name(module: &Bound<'_, PyModule>) -> String {
    let _ = module;
    String::new()
}
thread_local! {
    static __RUSTCALL_QUIET_DEPTH : ::std::cell::Cell < usize > = const {
    ::std::cell::Cell::new(0) };
}
/// `true` while this image's hook is the one std will call. A mutex, not a
/// `Once`: installing again after an uninstall has to work.
static __RUSTCALL_QUIET_HOOK_LIVE: ::std::sync::Mutex<bool> = ::std::sync::Mutex::new(
    false,
);
/// Raises the boundary depth for as long as a wrapper body runs, so the
/// hook above knows the panic it is about to print is one Julia will
/// raise as `RustCall.RustPanicError` instead.
pub struct __RustCallBoundary;
impl __RustCallBoundary {
    pub fn enter() -> Self {
        let _ = __RUSTCALL_QUIET_DEPTH.try_with(|depth| depth.set(depth.get() + 1));
        Self
    }
}
impl ::std::ops::Drop for __RustCallBoundary {
    fn drop(&mut self) {
        let _ = __RUSTCALL_QUIET_DEPTH
            .try_with(|depth| depth.set(depth.get().saturating_sub(1)));
    }
}
#[no_mangle]
pub extern "C" fn __rustcall_install_panic_hook() {
    if let ::std::result::Result::Ok(mut rustcall_live) = __RUSTCALL_QUIET_HOOK_LIVE
        .lock()
    {
        if !*rustcall_live {
            let rustcall_previous = ::std::panic::take_hook();
            ::std::panic::set_hook(
                ::std::boxed::Box::new(move |rustcall_info| {
                    if __RUSTCALL_QUIET_DEPTH.try_with(|depth| depth.get()).unwrap_or(0)
                        == 0
                    {
                        rustcall_previous(rustcall_info);
                    }
                }),
            );
            *rustcall_live = true;
        }
    }
}
#[no_mangle]
pub extern "C" fn __rustcall_uninstall_panic_hook() {
    if let ::std::result::Result::Ok(mut rustcall_live) = __RUSTCALL_QUIET_HOOK_LIVE
        .lock()
    {
        if *rustcall_live {
            let _ = ::std::panic::take_hook();
            *rustcall_live = false;
        }
    }
}
