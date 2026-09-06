//! `#[cfg]` predicates are recorded in the manifest. Without a configuration
//! (as here, in the golden run) every item is reported; the CLI with
//! `--cfg-file` drops the inactive ones.
#[cfg(unix)]
pub fn unix_only(x: i32) -> i32 {
    x + 1
}
#[cfg(unix)]
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_UNIX_ONLY : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[cfg(unix)]
#[no_mangle]
pub extern "C" fn rustcall_unix_only_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_UNIX_ONLY
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
#[cfg(unix)]
#[no_mangle]
pub extern "C" fn rustcall_unix_only(x: i32) -> i32 {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| { unix_only(x) }),
    ) {
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
                "{} panicked: {}", "unix_only", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_UNIX_ONLY
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            unsafe { ::std::mem::zeroed::<i32>() }
        }
    }
}
#[cfg(all(windows, feature = "wide"))]
pub fn windows_wide() -> Result<u32, i32> {
    Ok(1)
}
#[cfg(all(windows, feature = "wide"))]
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_WINDOWS_WIDE : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[cfg(all(windows, feature = "wide"))]
#[no_mangle]
pub extern "C" fn rustcall_windows_wide_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_WINDOWS_WIDE
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
#[cfg(all(windows, feature = "wide"))]
#[repr(C)]
pub struct CResult_windows_wide {
    is_ok: u8,
    /// Only initialized when `is_ok == 1`. `MaybeUninit` keeps the
    /// inactive field free of validity invariants (e.g. `NonZeroU32`).
    ok_value: ::std::mem::MaybeUninit<u32>,
    /// Only initialized when `is_ok == 0`.
    err_value: ::std::mem::MaybeUninit<i32>,
}
#[cfg(all(windows, feature = "wide"))]
impl CResult_windows_wide {
    /// Wrap a `Result` in the C-compatible representation.
    pub fn new(value: Result<u32, i32>) -> Self {
        match value {
            Ok(v) => {
                Self {
                    is_ok: 1,
                    ok_value: ::std::mem::MaybeUninit::new(v),
                    err_value: ::std::mem::MaybeUninit::zeroed(),
                }
            }
            Err(e) => {
                Self {
                    is_ok: 0,
                    ok_value: ::std::mem::MaybeUninit::zeroed(),
                    err_value: ::std::mem::MaybeUninit::new(e),
                }
            }
        }
    }
    /// Whether the call succeeded.
    pub fn is_ok(&self) -> bool {
        self.is_ok == 1
    }
    /// The `Ok` value, if any.
    pub fn ok(&self) -> Option<&u32> {
        if self.is_ok == 1 {
            Some(unsafe { self.ok_value.assume_init_ref() })
        } else {
            None
        }
    }
    /// The `Err` value, if any.
    pub fn err(&self) -> Option<&i32> {
        if self.is_ok == 0 {
            Some(unsafe { self.err_value.assume_init_ref() })
        } else {
            None
        }
    }
    /// The value returned after a caught panic (#244): the `Err`
    /// discriminant with **no** payload initialized.
    ///
    /// Julia reads this wrapper's panic channel before it decodes
    /// anything, and raises `RustPanicError`, so neither payload is
    /// ever observed. Both stay `MaybeUninit::zeroed()`, which is what
    /// `new` already writes for the inactive side.
    pub fn panicked() -> Self {
        Self {
            is_ok: 0,
            ok_value: ::std::mem::MaybeUninit::zeroed(),
            err_value: ::std::mem::MaybeUninit::zeroed(),
        }
    }
}
#[cfg(all(windows, feature = "wide"))]
#[no_mangle]
pub extern "C" fn rustcall_windows_wide() -> CResult_windows_wide {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| { CResult_windows_wide::new(windows_wide()) }),
    ) {
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
                "{} panicked: {}", "windows_wide", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_WINDOWS_WIDE
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            CResult_windows_wide::panicked()
        }
    }
}
#[cfg(not(target_os = "freebsd"))]
pub fn maybe(x: f64) -> Option<f64> {
    if x > 0.0 { Some(x) } else { None }
}
#[cfg(not(target_os = "freebsd"))]
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_MAYBE : ::std::cell::RefCell < ::std::option::Option
    < ::std::string::String >> = ::std::cell::RefCell::new(::std::option::Option::None);
}
#[cfg(not(target_os = "freebsd"))]
#[no_mangle]
pub extern "C" fn rustcall_maybe_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_MAYBE
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
#[cfg(not(target_os = "freebsd"))]
#[repr(C)]
pub struct COption_maybe {
    is_some: u8,
    /// Only initialized when `is_some == 1`.
    value: ::std::mem::MaybeUninit<f64>,
}
#[cfg(not(target_os = "freebsd"))]
impl COption_maybe {
    /// Wrap an `Option` in the C-compatible representation.
    pub fn new(value: Option<f64>) -> Self {
        match value {
            Some(v) => {
                Self {
                    is_some: 1,
                    value: ::std::mem::MaybeUninit::new(v),
                }
            }
            None => {
                Self {
                    is_some: 0,
                    value: ::std::mem::MaybeUninit::zeroed(),
                }
            }
        }
    }
    /// Whether a value is present.
    pub fn is_some(&self) -> bool {
        self.is_some == 1
    }
    /// The `Some` value, if any.
    pub fn some(&self) -> Option<&f64> {
        if self.is_some == 1 {
            Some(unsafe { self.value.assume_init_ref() })
        } else {
            None
        }
    }
    /// The value returned after a caught panic (#244): the `None`
    /// discriminant with an uninitialized payload. Julia raises
    /// `RustPanicError` before it looks at either field.
    pub fn panicked() -> Self {
        Self {
            is_some: 0,
            value: ::std::mem::MaybeUninit::zeroed(),
        }
    }
}
#[cfg(not(target_os = "freebsd"))]
#[no_mangle]
pub extern "C" fn rustcall_maybe(x: f64) -> COption_maybe {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| { COption_maybe::new(maybe(x)) }),
    ) {
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
                "{} panicked: {}", "maybe", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_MAYBE
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            COption_maybe::panicked()
        }
    }
}
#[cfg(unix)]
pub struct Handle {
    pub fd: i32,
    #[cfg(target_os = "linux")]
    pub epoll: i32,
}
#[no_mangle]
pub extern "C" fn Handle_free(ptr: *mut Handle) {
    if !ptr.is_null() {
        unsafe {
            drop(Box::from_raw(ptr));
        }
    }
}
#[no_mangle]
pub extern "C" fn Handle_get_fd(ptr: *const Handle) -> i32 {
    unsafe { (*ptr).fd }
}
#[no_mangle]
pub extern "C" fn Handle_set_fd(ptr: *mut Handle, value: i32) {
    unsafe {
        (*ptr).fd = value;
    }
}
#[no_mangle]
pub extern "C" fn Handle_get_epoll(ptr: *const Handle) -> i32 {
    unsafe { (*ptr).epoll }
}
#[no_mangle]
pub extern "C" fn Handle_set_epoll(ptr: *mut Handle, value: i32) {
    unsafe {
        (*ptr).epoll = value;
    }
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_HANDLE_FD : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_Handle_fd_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_HANDLE_FD
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
pub extern "C" fn rustcall_Handle_fd(ptr: *const Handle) -> i32 {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let self_obj = unsafe { &*ptr };
            self_obj.fd()
        }),
    ) {
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
                "{} panicked: {}", "Handle::fd", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_HANDLE_FD
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            unsafe { ::std::mem::zeroed::<i32>() }
        }
    }
}
#[cfg(target_os = "linux")]
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_HANDLE_EPOLL : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[cfg(target_os = "linux")]
#[no_mangle]
pub extern "C" fn rustcall_Handle_epoll_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_HANDLE_EPOLL
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
#[cfg(target_os = "linux")]
#[no_mangle]
pub extern "C" fn rustcall_Handle_epoll(ptr: *const Handle) -> i32 {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let self_obj = unsafe { &*ptr };
            self_obj.epoll()
        }),
    ) {
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
                "{} panicked: {}", "Handle::epoll", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_HANDLE_EPOLL
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            unsafe { ::std::mem::zeroed::<i32>() }
        }
    }
}
impl Handle {
    pub fn fd(&self) -> i32 {
        self.fd
    }
    #[cfg(target_os = "linux")]
    pub fn epoll(&self) -> i32 {
        self.epoll
    }
}
#[cfg(feature = "extra")]
mod extra {
    pub fn bonus() -> i32 {
        42
    }
    thread_local! {
        static __RUSTCALL_PANIC_RUSTCALL_BONUS : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn rustcall_bonus_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_PANIC_RUSTCALL_BONUS
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
    pub extern "C" fn rustcall_bonus() -> i32 {
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| { bonus() }),
        ) {
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
                    "{} panicked: {}", "bonus", rustcall_message
                );
                __RUSTCALL_PANIC_RUSTCALL_BONUS
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
                unsafe { ::std::mem::zeroed::<i32>() }
            }
        }
    }
}
