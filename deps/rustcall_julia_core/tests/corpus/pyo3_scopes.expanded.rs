use pyo3::prelude::*;
#[pyclass]
pub struct Node {
    pub level: i32,
}
pub mod a {
    use pyo3::prelude::*;
    /// Shadows `std::option::Option` in `a`, and nowhere else.
    pub struct Option<T>(pub T);
    #[pyfunction]
    pub fn in_a(x: Option<i32>) -> i32 {
        x.0
    }
}
pub mod b {
    use numpy as np;
    use pyo3::prelude::*;
    use pyo3::Py as Handle;
    use crate::Node as Knot;
    #[pyfunction]
    pub fn in_b(x: Option<i32>) -> Option<i32> {
        x
    }
    /// An aliased crate root is that crate.
    #[pyfunction]
    pub fn total(values: np::PyReadonlyArray1<'_, f64>) -> f64 {
        values.as_array().sum()
    }
    /// A renamed pyo3 item and a renamed class.
    #[pyfunction]
    pub fn knot(node: Handle<Knot>) -> Handle<Knot> {
        node
    }
    /// An `Option` of an opaque value is still an `Option`.
    #[pyfunction]
    pub fn anything(x: Option<Py<PyAny>>) -> Option<Py<PyAny>> {
        x
    }
}
pub mod c {
    use crate::a::*;
    use pyo3::prelude::*;
    /// The glob brings `a::Option` in.
    #[pyfunction]
    pub fn via_glob(x: Option<i32>) -> i32 {
        x.0
    }
    /// A path through another module names that module's item, never the
    /// prelude.
    #[pyfunction]
    pub fn through(x: super::a::Option<i32>, y: crate::b::Option<i32>) -> i32 {
        x.0 + y.map(|v| v.0).unwrap_or(0)
    }
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
