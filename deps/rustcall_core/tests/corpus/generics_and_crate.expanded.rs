pub struct Pair<T>
where
    T: Clone,
{
    pub left: T,
    pub right: T,
}
pub fn Pair_new<T>(left: T, right: T) -> *mut Pair<T>
where
    T: Clone,
{
    let obj = Pair::new(left, right);
    Box::into_raw(Box::new(obj))
}
pub fn Pair_first<T>(ptr: *const Pair<T>) -> T
where
    T: Clone,
{
    let self_obj = unsafe { &*ptr };
    self_obj.first()
}
pub fn Pair_inline_only<T>(ptr: *const Pair<T>) -> T
where
    T: Clone,
{
    let self_obj = unsafe { &*ptr };
    self_obj.inline_only()
}
pub fn Pair_get_left<T>(ptr: *const Pair<T>) -> T
where
    T: Clone,
    T: Copy,
{
    unsafe { (*ptr).left }
}
pub fn Pair_set_left<T>(ptr: *mut Pair<T>, value: T)
where
    T: Clone,
{
    unsafe {
        (*ptr).left = value;
    }
}
pub fn Pair_get_right<T>(ptr: *const Pair<T>) -> T
where
    T: Clone,
    T: Copy,
{
    unsafe { (*ptr).right }
}
pub fn Pair_set_right<T>(ptr: *mut Pair<T>, value: T)
where
    T: Clone,
{
    unsafe {
        (*ptr).right = value;
    }
}
pub fn Pair_free<T>(ptr: *mut Pair<T>)
where
    T: Clone,
{
    if !ptr.is_null() {
        unsafe {
            drop(Box::from_raw(ptr));
        }
    }
}
impl<T> Pair<T>
where
    T: Clone,
{
    pub fn new(left: T, right: T) -> Self {
        Self { left, right }
    }
    pub fn first(&self) -> T {
        self.left.clone()
    }
    pub fn inline_only(&self) -> T {
        self.right.clone()
    }
}
pub fn generic_identity<T>(value: T) -> T
where
    T: Clone,
{
    value
}
#[no_mangle]
pub extern "C" fn raw_increment(value: u32) -> u32 {
    value + 1
}
thread_local! {
    static __RUSTCALL_QUIET_DEPTH : ::std::cell::Cell < usize > =
    ::std::cell::Cell::new(0);
}
static __RUSTCALL_QUIET_HOOK_ONCE: ::std::sync::Once = ::std::sync::Once::new();
static __RUSTCALL_QUIET_HOOK_LIVE: ::std::sync::atomic::AtomicBool = ::std::sync::atomic::AtomicBool::new(
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
pub extern "C" fn rustcall_install_panic_hook() {
    __RUSTCALL_QUIET_HOOK_ONCE
        .call_once(|| {
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
            __RUSTCALL_QUIET_HOOK_LIVE
                .store(true, ::std::sync::atomic::Ordering::Release);
        });
}
#[no_mangle]
pub extern "C" fn rustcall_uninstall_panic_hook() {
    if __RUSTCALL_QUIET_HOOK_LIVE.swap(false, ::std::sync::atomic::Ordering::AcqRel) {
        let _ = ::std::panic::take_hook();
    }
}
