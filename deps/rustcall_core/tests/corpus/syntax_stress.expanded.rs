//! A module-level doc comment retained by the syntax round trip.
///An attributed function with nested generic arguments.
#[inline]
pub fn nested<T>(value: Vec<Option<Result<T, String>>>) -> usize
where
    T: Clone + Send,
{
    value.len()
}
fn const_expression(value: [u8; { if 1 < 2 { 3 } else { 4 } }]) -> u8 {
    value[0]
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_CONST_EXPRESSION : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_const_expression_take_panic(
    out: *mut u8,
    cap: usize,
) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_CONST_EXPRESSION
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
pub extern "C" fn rustcall_const_expression(
    value: [u8; { if 1 < 2 { 3 } else { 4 } }],
) -> u8 {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| { const_expression(value) }),
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
                "{} panicked: {}", "const_expression", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_CONST_EXPRESSION
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            unsafe { ::std::mem::zeroed::<u8>() }
        }
    }
}
/// The raw string deliberately contains braces that are not Rust blocks.
fn raw_braces() -> &'static str {
    r##"left { middle } right"##
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_RAW_BRACES : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_raw_braces_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_RAW_BRACES
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
#[repr(C)]
pub struct raw_braces_RustCallBorrowedString {
    pub ptr: *const u8,
    pub len: usize,
}
#[no_mangle]
pub extern "C" fn rustcall_raw_braces() -> raw_braces_RustCallBorrowedString {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let rustcall_value = raw_braces();
            raw_braces_RustCallBorrowedString {
                ptr: rustcall_value.as_ptr(),
                len: rustcall_value.len(),
            }
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
                "{} panicked: {}", "raw_braces", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_RAW_BRACES
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            raw_braces_RustCallBorrowedString {
                ptr: ::std::ptr::null(),
                len: 0,
            }
        }
    }
}
fn marker_in_string_is_not_an_attribute() -> &'static str {
    "#[julia] fn imaginary() -> i32 { 99 }"
}
#[allow(dead_code)]
fn borrow_for<'a>(value: &'a str, fallback: &'a str) -> &'a str {
    if value.is_empty() { fallback } else { value }
}
#[cfg(any())]
fn cfg_disabled() -> i32 {
    7
}
#[cfg(any())]
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_CFG_DISABLED : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[cfg(any())]
#[no_mangle]
pub extern "C" fn rustcall_cfg_disabled_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_CFG_DISABLED
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
#[cfg(any())]
#[no_mangle]
pub extern "C" fn rustcall_cfg_disabled() -> i32 {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| { cfg_disabled() }),
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
                "{} panicked: {}", "cfg_disabled", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_CFG_DISABLED
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            unsafe { ::std::mem::zeroed::<i32>() }
        }
    }
}
