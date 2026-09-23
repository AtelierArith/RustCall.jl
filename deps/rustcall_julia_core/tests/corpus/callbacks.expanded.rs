pub fn apply(f: extern "C" fn(i64) -> i64, x: i64) -> i64 {
    f(x)
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_APPLY : ::std::cell::RefCell < ::std::option::Option
    < ::std::string::String >> = ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_apply_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_APPLY
        .with(|rustcall_slot| {
            let mut rustcall_slot = rustcall_slot.borrow_mut();
            if out.is_null() && cap == usize::MAX {
                return rustcall_slot.take().map_or(0, |message| message.len());
            }
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
pub extern "C" fn rustcall_apply(
    f: extern "C" fn(i64) -> i64,
    x: i64,
) -> ::std::mem::MaybeUninit<i64> {
    let _rustcall_boundary = crate::__RustCallBoundary::enter();
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| { ::std::mem::MaybeUninit::new(apply(f, x)) }),
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
                "{} panicked: {}", "apply", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_APPLY
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            ::std::mem::MaybeUninit::zeroed()
        }
    }
}
pub fn each(n: u32, visit: unsafe extern "C" fn(u32, f64)) {
    for i in 0..n {
        unsafe { visit(i, i as f64) }
    }
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_EACH : ::std::cell::RefCell < ::std::option::Option
    < ::std::string::String >> = ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_each_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_EACH
        .with(|rustcall_slot| {
            let mut rustcall_slot = rustcall_slot.borrow_mut();
            if out.is_null() && cap == usize::MAX {
                return rustcall_slot.take().map_or(0, |message| message.len());
            }
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
pub extern "C" fn rustcall_each(n: u32, visit: unsafe extern "C" fn(u32, f64)) {
    let _rustcall_boundary = crate::__RustCallBoundary::enter();
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| { each(n, visit) }),
    ) {
        ::std::result::Result::Ok(_) => {}
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
                "{} panicked: {}", "each", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_EACH
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
        }
    }
}
pub fn probe(cb: extern "C" fn(*const u8) -> bool) -> bool {
    cb(std::ptr::null())
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_PROBE : ::std::cell::RefCell < ::std::option::Option
    < ::std::string::String >> = ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_probe_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_PROBE
        .with(|rustcall_slot| {
            let mut rustcall_slot = rustcall_slot.borrow_mut();
            if out.is_null() && cap == usize::MAX {
                return rustcall_slot.take().map_or(0, |message| message.len());
            }
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
pub extern "C" fn rustcall_probe(
    cb: extern "C" fn(*const u8) -> bool,
) -> ::std::mem::MaybeUninit<bool> {
    let _rustcall_boundary = crate::__RustCallBoundary::enter();
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| { ::std::mem::MaybeUninit::new(probe(cb)) }),
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
                "{} panicked: {}", "probe", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_PROBE
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            ::std::mem::MaybeUninit::zeroed()
        }
    }
}
pub fn rust_abi(f: fn(i64) -> i64) -> i64 {
    f(1)
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_RUST_ABI : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_rust_abi_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_RUST_ABI
        .with(|rustcall_slot| {
            let mut rustcall_slot = rustcall_slot.borrow_mut();
            if out.is_null() && cap == usize::MAX {
                return rustcall_slot.take().map_or(0, |message| message.len());
            }
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
pub extern "C" fn rustcall_rust_abi(f: fn(i64) -> i64) -> ::std::mem::MaybeUninit<i64> {
    let _rustcall_boundary = crate::__RustCallBoundary::enter();
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| { ::std::mem::MaybeUninit::new(rust_abi(f)) }),
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
                "{} panicked: {}", "rust_abi", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_RUST_ABI
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            ::std::mem::MaybeUninit::zeroed()
        }
    }
}
pub struct Acc {
    pub total: i64,
}
thread_local! {
    static __RUSTCALL_DROP_PANIC_4163635F66726565 : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn Acc_free_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_DROP_PANIC_4163635F66726565
        .with(|rustcall_slot| {
            let mut rustcall_slot = rustcall_slot.borrow_mut();
            if out.is_null() && cap == usize::MAX {
                return rustcall_slot.take().map_or(0, |message| message.len());
            }
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
pub extern "C" fn Acc_free(ptr: *mut Acc) {
    let _rustcall_boundary = crate::__RustCallBoundary::enter();
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            if !ptr.is_null() {
                unsafe {
                    drop(Box::from_raw(ptr));
                }
            }
        }),
    ) {
        ::std::result::Result::Ok(_) => {}
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
                "{} panicked: {}", "Acc::drop", rustcall_message
            );
            __RUSTCALL_DROP_PANIC_4163635F66726565
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
        }
    }
}
thread_local! {
    static __RUSTCALL_HELPER_PANIC_4163635F6765745F746F74616C : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn Acc_get_total_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_HELPER_PANIC_4163635F6765745F746F74616C
        .with(|rustcall_slot| {
            let mut rustcall_slot = rustcall_slot.borrow_mut();
            if out.is_null() && cap == usize::MAX {
                return rustcall_slot.take().map_or(0, |message| message.len());
            }
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
pub extern "C" fn Acc_get_total(ptr: *const Acc) -> ::std::mem::MaybeUninit<i64> {
    let _rustcall_boundary = crate::__RustCallBoundary::enter();
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            ::std::mem::MaybeUninit::new({ unsafe { (*ptr).total } })
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
                "{} panicked: {}", "Acc_get_total", rustcall_message
            );
            __RUSTCALL_HELPER_PANIC_4163635F6765745F746F74616C
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            ::std::mem::MaybeUninit::zeroed()
        }
    }
}
thread_local! {
    static __RUSTCALL_HELPER_PANIC_4163635F7365745F746F74616C : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn Acc_set_total_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_HELPER_PANIC_4163635F7365745F746F74616C
        .with(|rustcall_slot| {
            let mut rustcall_slot = rustcall_slot.borrow_mut();
            if out.is_null() && cap == usize::MAX {
                return rustcall_slot.take().map_or(0, |message| message.len());
            }
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
pub extern "C" fn Acc_set_total(ptr: *mut Acc, value: i64) {
    let _rustcall_boundary = crate::__RustCallBoundary::enter();
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            {
                unsafe {
                    (*ptr).total = value;
                }
            }
        }),
    ) {
        ::std::result::Result::Ok(_) => {}
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
                "{} panicked: {}", "Acc_set_total", rustcall_message
            );
            __RUSTCALL_HELPER_PANIC_4163635F7365745F746F74616C
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
        }
    }
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_ACC_NEW : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_Acc_new_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_ACC_NEW
        .with(|rustcall_slot| {
            let mut rustcall_slot = rustcall_slot.borrow_mut();
            if out.is_null() && cap == usize::MAX {
                return rustcall_slot.take().map_or(0, |message| message.len());
            }
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
pub extern "C" fn rustcall_Acc_new(total: i64) -> *mut Acc {
    let _rustcall_boundary = crate::__RustCallBoundary::enter();
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let obj = Acc::new(total);
            Box::into_raw(Box::new(obj))
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
                "{} panicked: {}", "Acc::new", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_ACC_NEW
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            ::std::ptr::null_mut()
        }
    }
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_ACC_FOLD : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_Acc_fold_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_ACC_FOLD
        .with(|rustcall_slot| {
            let mut rustcall_slot = rustcall_slot.borrow_mut();
            if out.is_null() && cap == usize::MAX {
                return rustcall_slot.take().map_or(0, |message| message.len());
            }
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
pub extern "C" fn rustcall_Acc_fold(
    ptr: *const Acc,
    f: extern "C" fn(i64) -> i64,
) -> ::std::mem::MaybeUninit<i64> {
    let _rustcall_boundary = crate::__RustCallBoundary::enter();
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let self_obj = unsafe { &*ptr };
            ::std::mem::MaybeUninit::new(self_obj.fold(f))
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
                "{} panicked: {}", "Acc::fold", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_ACC_FOLD
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            ::std::mem::MaybeUninit::zeroed()
        }
    }
}
impl Acc {
    pub fn new(total: i64) -> Self {
        Acc { total }
    }
    pub fn fold(&self, f: extern "C" fn(i64) -> i64) -> i64 {
        f(self.total)
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
