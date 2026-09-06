//! `String` / `&str` arguments and returns on `#[julia]` free functions (#242).
pub fn shout(input: String) -> String {
    input.to_uppercase()
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_SHOUT : ::std::cell::RefCell < ::std::option::Option
    < ::std::string::String >> = ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_shout_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_SHOUT
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
pub struct shout_RustCallOwnedString {
    pub ptr: *mut u8,
    pub len: usize,
    pub cap: usize,
}
#[no_mangle]
pub extern "C" fn shout_free_rust_string(ptr: *mut u8, len: usize, cap: usize) {
    if !ptr.is_null() {
        unsafe {
            drop(Vec::from_raw_parts(ptr, len, cap));
        }
    }
}
#[no_mangle]
pub extern "C" fn rustcall_shout(
    input_ptr: *const u8,
    input_len: usize,
) -> shout_RustCallOwnedString {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let input = unsafe {
                let slice = std::slice::from_raw_parts(input_ptr, input_len);
                String::from_utf8_lossy(slice).into_owned()
            };
            let rustcall_value = shout(input);
            let mut rustcall_bytes = ToString::to_string(&rustcall_value).into_bytes();
            let rustcall_ret = shout_RustCallOwnedString {
                ptr: rustcall_bytes.as_mut_ptr(),
                len: rustcall_bytes.len(),
                cap: rustcall_bytes.capacity(),
            };
            std::mem::forget(rustcall_bytes);
            rustcall_ret
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
                "{} panicked: {}", "shout", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_SHOUT
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            shout_RustCallOwnedString {
                ptr: ::std::ptr::null_mut(),
                len: 0,
                cap: 0,
            }
        }
    }
}
pub fn concat(a: &str, b: &str, times: u32) -> String {
    let mut out = String::new();
    for _ in 0..times {
        out.push_str(a);
        out.push_str(b);
    }
    out
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_CONCAT : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_concat_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_CONCAT
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
pub struct concat_RustCallOwnedString {
    pub ptr: *mut u8,
    pub len: usize,
    pub cap: usize,
}
#[no_mangle]
pub extern "C" fn concat_free_rust_string(ptr: *mut u8, len: usize, cap: usize) {
    if !ptr.is_null() {
        unsafe {
            drop(Vec::from_raw_parts(ptr, len, cap));
        }
    }
}
#[no_mangle]
pub extern "C" fn rustcall_concat(
    a_ptr: *const u8,
    a_len: usize,
    b_ptr: *const u8,
    b_len: usize,
    times: u32,
) -> concat_RustCallOwnedString {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let a_bytes = unsafe { std::slice::from_raw_parts(a_ptr, a_len) };
            let a_cow = String::from_utf8_lossy(a_bytes);
            let a: &str = &a_cow;
            let b_bytes = unsafe { std::slice::from_raw_parts(b_ptr, b_len) };
            let b_cow = String::from_utf8_lossy(b_bytes);
            let b: &str = &b_cow;
            let rustcall_value = concat(a, b, times);
            let mut rustcall_bytes = ToString::to_string(&rustcall_value).into_bytes();
            let rustcall_ret = concat_RustCallOwnedString {
                ptr: rustcall_bytes.as_mut_ptr(),
                len: rustcall_bytes.len(),
                cap: rustcall_bytes.capacity(),
            };
            std::mem::forget(rustcall_bytes);
            rustcall_ret
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
                "{} panicked: {}", "concat", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_CONCAT
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            concat_RustCallOwnedString {
                ptr: ::std::ptr::null_mut(),
                len: 0,
                cap: 0,
            }
        }
    }
}
pub fn byte_len(s: &str) -> usize {
    s.len()
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_BYTE_LEN : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_byte_len_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_BYTE_LEN
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
pub extern "C" fn rustcall_byte_len(s_ptr: *const u8, s_len: usize) -> usize {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let s_bytes = unsafe { std::slice::from_raw_parts(s_ptr, s_len) };
            let s_cow = String::from_utf8_lossy(s_bytes);
            let s: &str = &s_cow;
            byte_len(s)
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
                "{} panicked: {}", "byte_len", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_BYTE_LEN
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            unsafe { ::std::mem::zeroed::<usize>() }
        }
    }
}
pub fn greeting() -> &'static str {
    "hello"
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_GREETING : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_greeting_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_GREETING
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
pub struct greeting_RustCallBorrowedString {
    pub ptr: *const u8,
    pub len: usize,
}
#[no_mangle]
pub extern "C" fn rustcall_greeting() -> greeting_RustCallBorrowedString {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let rustcall_value = greeting();
            greeting_RustCallBorrowedString {
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
                "{} panicked: {}", "greeting", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_GREETING
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            greeting_RustCallBorrowedString {
                ptr: ::std::ptr::null(),
                len: 0,
            }
        }
    }
}
#[cfg(unix)]
pub fn unix_name(s: String) -> String {
    s
}
#[cfg(unix)]
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_UNIX_NAME : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[cfg(unix)]
#[no_mangle]
pub extern "C" fn rustcall_unix_name_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_UNIX_NAME
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
#[repr(C)]
pub struct unix_name_RustCallOwnedString {
    pub ptr: *mut u8,
    pub len: usize,
    pub cap: usize,
}
#[cfg(unix)]
#[no_mangle]
pub extern "C" fn unix_name_free_rust_string(ptr: *mut u8, len: usize, cap: usize) {
    if !ptr.is_null() {
        unsafe {
            drop(Vec::from_raw_parts(ptr, len, cap));
        }
    }
}
#[cfg(unix)]
#[no_mangle]
pub extern "C" fn rustcall_unix_name(
    s_ptr: *const u8,
    s_len: usize,
) -> unix_name_RustCallOwnedString {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let s = unsafe {
                let slice = std::slice::from_raw_parts(s_ptr, s_len);
                String::from_utf8_lossy(slice).into_owned()
            };
            let rustcall_value = unix_name(s);
            let mut rustcall_bytes = ToString::to_string(&rustcall_value).into_bytes();
            let rustcall_ret = unix_name_RustCallOwnedString {
                ptr: rustcall_bytes.as_mut_ptr(),
                len: rustcall_bytes.len(),
                cap: rustcall_bytes.capacity(),
            };
            std::mem::forget(rustcall_bytes);
            rustcall_ret
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
                "{} panicked: {}", "unix_name", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_UNIX_NAME
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            unix_name_RustCallOwnedString {
                ptr: ::std::ptr::null_mut(),
                len: 0,
                cap: 0,
            }
        }
    }
}
pub fn consume(s: (String)) -> usize {
    s.len()
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_CONSUME : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_consume_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_CONSUME
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
pub extern "C" fn rustcall_consume(s_ptr: *const u8, s_len: usize) -> usize {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let s = unsafe {
                let slice = std::slice::from_raw_parts(s_ptr, s_len);
                String::from_utf8_lossy(slice).into_owned()
            };
            consume(s)
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
                "{} panicked: {}", "consume", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_CONSUME
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            unsafe { ::std::mem::zeroed::<usize>() }
        }
    }
}
pub fn paren_ref(s: &(str)) -> (usize) {
    s.len()
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_PAREN_REF : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_paren_ref_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_PAREN_REF
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
pub extern "C" fn rustcall_paren_ref(s_ptr: *const u8, s_len: usize) -> (usize) {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let s_bytes = unsafe { std::slice::from_raw_parts(s_ptr, s_len) };
            let s_cow = String::from_utf8_lossy(s_bytes);
            let s: &str = &s_cow;
            paren_ref(s)
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
                "{} panicked: {}", "paren_ref", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_PAREN_REF
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            unsafe { ::std::mem::zeroed::<(usize)>() }
        }
    }
}
pub fn collide(s: String, s_ptr: usize) -> usize {
    s.len() + s_ptr
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_COLLIDE : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_collide_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_COLLIDE
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
pub extern "C" fn rustcall_collide(
    s_ptr_: *const u8,
    s_len: usize,
    s_ptr: usize,
) -> usize {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let s = unsafe {
                let slice = std::slice::from_raw_parts(s_ptr_, s_len);
                String::from_utf8_lossy(slice).into_owned()
            };
            collide(s, s_ptr)
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
                "{} panicked: {}", "collide", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_COLLIDE
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            unsafe { ::std::mem::zeroed::<usize>() }
        }
    }
}
pub struct Greeter {
    pub count: u32,
}
#[no_mangle]
pub extern "C" fn Greeter_free(ptr: *mut Greeter) {
    if !ptr.is_null() {
        unsafe {
            drop(Box::from_raw(ptr));
        }
    }
}
#[repr(C)]
pub struct Greeter_RustCallOwnedString {
    pub ptr: *mut u8,
    pub len: usize,
    pub cap: usize,
}
#[no_mangle]
pub extern "C" fn Greeter_free_rust_string(ptr: *mut u8, len: usize, cap: usize) {
    if !ptr.is_null() {
        unsafe {
            drop(Vec::from_raw_parts(ptr, len, cap));
        }
    }
}
#[repr(C)]
pub struct Greeter_RustCallBorrowedString {
    pub ptr: *const u8,
    pub len: usize,
}
#[no_mangle]
pub extern "C" fn Greeter_get_count(ptr: *const Greeter) -> u32 {
    unsafe { (*ptr).count }
}
#[no_mangle]
pub extern "C" fn Greeter_set_count(ptr: *mut Greeter, value: u32) {
    unsafe {
        (*ptr).count = value;
    }
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_GREETER_NEW : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_Greeter_new_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_GREETER_NEW
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
pub extern "C" fn rustcall_Greeter_new(count: u32) -> *mut Greeter {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let obj = Greeter::new(count);
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
                "{} panicked: {}", "Greeter::new", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_GREETER_NEW
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
    static __RUSTCALL_PANIC_RUSTCALL_GREETER_SHOUT : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_Greeter_shout_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_GREETER_SHOUT
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
pub extern "C" fn rustcall_Greeter_shout(
    ptr: *const Greeter,
    suffix_ptr: *const u8,
    suffix_len: usize,
) -> Greeter_RustCallOwnedString {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let suffix_bytes = unsafe {
                std::slice::from_raw_parts(suffix_ptr, suffix_len)
            };
            let suffix_cow = String::from_utf8_lossy(suffix_bytes);
            let suffix: &str = &suffix_cow;
            let self_obj = unsafe { &*ptr };
            let rustcall_value = self_obj.shout(suffix);
            let mut rustcall_bytes = ToString::to_string(&rustcall_value).into_bytes();
            let rustcall_ret = Greeter_RustCallOwnedString {
                ptr: rustcall_bytes.as_mut_ptr(),
                len: rustcall_bytes.len(),
                cap: rustcall_bytes.capacity(),
            };
            std::mem::forget(rustcall_bytes);
            rustcall_ret
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
                "{} panicked: {}", "Greeter::shout", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_GREETER_SHOUT
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            Greeter_RustCallOwnedString {
                ptr: ::std::ptr::null_mut(),
                len: 0,
                cap: 0,
            }
        }
    }
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_GREETER_LABEL : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_Greeter_label_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_GREETER_LABEL
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
pub extern "C" fn rustcall_Greeter_label(
    ptr: *const Greeter,
) -> Greeter_RustCallBorrowedString {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let self_obj = unsafe { &*ptr };
            let rustcall_value = self_obj.label();
            Greeter_RustCallBorrowedString {
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
                "{} panicked: {}", "Greeter::label", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_GREETER_LABEL
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            Greeter_RustCallBorrowedString {
                ptr: ::std::ptr::null(),
                len: 0,
            }
        }
    }
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_GREETER_TAKE : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_Greeter_take_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_GREETER_TAKE
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
pub extern "C" fn rustcall_Greeter_take(
    ptr: *mut Greeter,
    s_ptr: *const u8,
    s_len: usize,
) -> usize {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let s = unsafe {
                let slice = std::slice::from_raw_parts(s_ptr, s_len);
                String::from_utf8_lossy(slice).into_owned()
            };
            let self_obj = unsafe { &mut *ptr };
            self_obj.take(s)
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
                "{} panicked: {}", "Greeter::take", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_GREETER_TAKE
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            unsafe { ::std::mem::zeroed::<usize>() }
        }
    }
}
impl Greeter {
    pub fn new(count: u32) -> Self {
        Self { count }
    }
    pub fn shout(&self, suffix: &str) -> String {
        format!("{}{}", self.count, suffix)
    }
    pub fn label(&self) -> &str {
        "greeter"
    }
    pub fn take(&mut self, s: String) -> usize {
        self.count += 1;
        s.len()
    }
}
