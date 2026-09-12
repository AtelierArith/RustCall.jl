//! Module-qualified symbols (#300): the same item names in two modules, a
//! nested module, and underscores in both module and item names.
//!
//! In a crate the `#[julia]` on each inline `mod` is what tells the proc-macro
//! its path; inline expansion strips the marker and walks the modules itself.
pub mod a {
    pub fn run() -> i32 {
        1
    }
    thread_local! {
        static __RUSTCALL_PANIC_RUSTCALL_A__RUN : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn rustcall_a__run_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_PANIC_RUSTCALL_A__RUN
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
    pub extern "C" fn rustcall_a__run() -> i32 {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| { run() })) {
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
                    "{} panicked: {}", "run", rustcall_message
                );
                __RUSTCALL_PANIC_RUSTCALL_A__RUN
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
                unsafe { ::std::mem::zeroed::<i32>() }
            }
        }
    }
    pub struct C {
        pub v: i32,
        pub label: String,
    }
    thread_local! {
        static __RUSTCALL_DROP_PANIC_615F5F435F66726565 : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn a__C_free_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_DROP_PANIC_615F5F435F66726565
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
    pub extern "C" fn a__C_free(ptr: *mut C) {
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
                    "{} panicked: {}", "C::drop", rustcall_message
                );
                __RUSTCALL_DROP_PANIC_615F5F435F66726565
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
            }
        }
    }
    #[repr(C)]
    pub struct a__C_RustCallOwnedString {
        pub ptr: *mut u8,
        pub len: usize,
        pub cap: usize,
    }
    #[no_mangle]
    pub extern "C" fn a__C_free_rust_string(ptr: *mut u8, len: usize, cap: usize) {
        if !ptr.is_null() {
            unsafe {
                drop(Vec::from_raw_parts(ptr, len, cap));
            }
        }
    }
    thread_local! {
        static __RUSTCALL_HELPER_PANIC_615F5F435F6765745F76 : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn a__C_get_v_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_HELPER_PANIC_615F5F435F6765745F76
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
    pub extern "C" fn a__C_get_v(ptr: *const C) -> i32 {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| { { unsafe { (*ptr).v } } }),
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
                    "{} panicked: {}", "a__C_get_v", rustcall_message
                );
                __RUSTCALL_HELPER_PANIC_615F5F435F6765745F76
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
                unsafe { ::std::mem::zeroed::<i32>() }
            }
        }
    }
    thread_local! {
        static __RUSTCALL_HELPER_PANIC_615F5F435F7365745F76 : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn a__C_set_v_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_HELPER_PANIC_615F5F435F7365745F76
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
    pub extern "C" fn a__C_set_v(ptr: *mut C, value: i32) {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| {
                {
                    unsafe {
                        (*ptr).v = value;
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
                    "{} panicked: {}", "a__C_set_v", rustcall_message
                );
                __RUSTCALL_HELPER_PANIC_615F5F435F7365745F76
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
            }
        }
    }
    thread_local! {
        static __RUSTCALL_HELPER_PANIC_615F5F435F6765745F6C6162656C :
        ::std::cell::RefCell < ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn a__C_get_label_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_HELPER_PANIC_615F5F435F6765745F6C6162656C
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
    pub extern "C" fn a__C_get_label(ptr: *const C) -> a__C_RustCallOwnedString {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| {
                {
                    let mut rustcall_bytes = unsafe {
                        (*ptr).label.clone().into_bytes()
                    };
                    let rustcall_ret = a__C_RustCallOwnedString {
                        ptr: rustcall_bytes.as_mut_ptr(),
                        len: rustcall_bytes.len(),
                        cap: rustcall_bytes.capacity(),
                    };
                    std::mem::forget(rustcall_bytes);
                    rustcall_ret
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
                    "{} panicked: {}", "a__C_get_label", rustcall_message
                );
                __RUSTCALL_HELPER_PANIC_615F5F435F6765745F6C6162656C
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
                unsafe { ::std::mem::zeroed::<a__C_RustCallOwnedString>() }
            }
        }
    }
    thread_local! {
        static __RUSTCALL_HELPER_PANIC_615F5F435F7365745F6C6162656C :
        ::std::cell::RefCell < ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn a__C_set_label_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_HELPER_PANIC_615F5F435F7365745F6C6162656C
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
    pub extern "C" fn a__C_set_label(
        ptr: *mut C,
        value_ptr: *const u8,
        value_len: usize,
    ) {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| {
                {
                    let value = unsafe {
                        let slice = std::slice::from_raw_parts(value_ptr, value_len);
                        String::from_utf8_lossy(slice).into_owned()
                    };
                    unsafe {
                        (*ptr).label = value;
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
                    "{} panicked: {}", "a__C_set_label", rustcall_message
                );
                __RUSTCALL_HELPER_PANIC_615F5F435F7365745F6C6162656C
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
            }
        }
    }
    thread_local! {
        static __RUSTCALL_PANIC_RUSTCALL_A__C_NEW : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn rustcall_a__C_new_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_PANIC_RUSTCALL_A__C_NEW
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
    pub extern "C" fn rustcall_a__C_new(v: i32) -> *mut C {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| {
                let obj = C::new(v);
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
                    "{} panicked: {}", "C::new", rustcall_message
                );
                __RUSTCALL_PANIC_RUSTCALL_A__C_NEW
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
        static __RUSTCALL_PANIC_RUSTCALL_A__C_GET : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn rustcall_a__C_get_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_PANIC_RUSTCALL_A__C_GET
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
    pub extern "C" fn rustcall_a__C_get(ptr: *const C) -> i32 {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| {
                let self_obj = unsafe { &*ptr };
                self_obj.get()
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
                    "{} panicked: {}", "C::get", rustcall_message
                );
                __RUSTCALL_PANIC_RUSTCALL_A__C_GET
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
                unsafe { ::std::mem::zeroed::<i32>() }
            }
        }
    }
    thread_local! {
        static __RUSTCALL_PANIC_RUSTCALL_A__C_DESCRIBE : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn rustcall_a__C_describe_take_panic(
        out: *mut u8,
        cap: usize,
    ) -> usize {
        __RUSTCALL_PANIC_RUSTCALL_A__C_DESCRIBE
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
    pub extern "C" fn rustcall_a__C_describe(ptr: *const C) -> a__C_RustCallOwnedString {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| {
                let self_obj = unsafe { &*ptr };
                let rustcall_value = self_obj.describe();
                let mut rustcall_bytes = ToString::to_string(&rustcall_value)
                    .into_bytes();
                let rustcall_ret = a__C_RustCallOwnedString {
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
                    "{} panicked: {}", "C::describe", rustcall_message
                );
                __RUSTCALL_PANIC_RUSTCALL_A__C_DESCRIBE
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
                a__C_RustCallOwnedString {
                    ptr: ::std::ptr::null_mut(),
                    len: 0,
                    cap: 0,
                }
            }
        }
    }
    thread_local! {
        static __RUSTCALL_PANIC_RUSTCALL_A__C_CHECKED : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn rustcall_a__C_checked_take_panic(
        out: *mut u8,
        cap: usize,
    ) -> usize {
        __RUSTCALL_PANIC_RUSTCALL_A__C_CHECKED
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
    #[repr(C)]
    pub struct CResult_a__C_checked {
        is_ok: u8,
        /// Only initialized when `is_ok == 1`. `MaybeUninit` keeps the
        /// inactive field free of validity invariants (e.g. `NonZeroU32`).
        ok_value: ::std::mem::MaybeUninit<i32>,
        /// Only initialized when `is_ok == 0`.
        err_value: ::std::mem::MaybeUninit<a__C_RustCallOwnedString>,
    }
    impl CResult_a__C_checked {
        /// Wrap a `Result` in the C-compatible representation.
        pub fn new(value: Result<i32, a__C_RustCallOwnedString>) -> Self {
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
        pub fn ok(&self) -> Option<&i32> {
            if self.is_ok == 1 {
                Some(unsafe { self.ok_value.assume_init_ref() })
            } else {
                None
            }
        }
        /// The `Err` value, if any.
        pub fn err(&self) -> Option<&a__C_RustCallOwnedString> {
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
    #[no_mangle]
    pub extern "C" fn rustcall_a__C_checked(ptr: *const C) -> CResult_a__C_checked {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| {
                let self_obj = unsafe { &*ptr };
                CResult_a__C_checked::new(
                    match self_obj.checked() {
                        ::std::result::Result::Ok(rustcall_ok) => {
                            ::std::result::Result::Ok(rustcall_ok)
                        }
                        ::std::result::Result::Err(rustcall_err) => {
                            ::std::result::Result::Err({
                                let mut rustcall_bytes = ToString::to_string(&rustcall_err)
                                    .into_bytes();
                                let rustcall_buf = a__C_RustCallOwnedString {
                                    ptr: rustcall_bytes.as_mut_ptr(),
                                    len: rustcall_bytes.len(),
                                    cap: rustcall_bytes.capacity(),
                                };
                                ::std::mem::forget(rustcall_bytes);
                                rustcall_buf
                            })
                        }
                    },
                )
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
                    "{} panicked: {}", "C::checked", rustcall_message
                );
                __RUSTCALL_PANIC_RUSTCALL_A__C_CHECKED
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
                CResult_a__C_checked::panicked()
            }
        }
    }
    impl C {
        pub fn new(v: i32) -> Self {
            Self { v, label: String::new() }
        }
        pub fn get(&self) -> i32 {
            self.v
        }
        pub fn describe(&self) -> String {
            format!("a::C({})", self.v)
        }
        pub fn checked(&self) -> Result<i32, String> {
            Ok(self.v)
        }
    }
    pub mod deep_er {
        pub fn run() -> i32 {
            3
        }
        thread_local! {
            static __RUSTCALL_PANIC_RUSTCALL_A__DEEP_0ER__RUN : ::std::cell::RefCell <
            ::std::option::Option < ::std::string::String >> =
            ::std::cell::RefCell::new(::std::option::Option::None);
        }
        #[no_mangle]
        pub extern "C" fn rustcall_a__deep_0er__run_take_panic(
            out: *mut u8,
            cap: usize,
        ) -> usize {
            __RUSTCALL_PANIC_RUSTCALL_A__DEEP_0ER__RUN
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
        pub extern "C" fn rustcall_a__deep_0er__run() -> i32 {
            let _rustcall_boundary = crate::__RustCallBoundary::enter();
            match ::std::panic::catch_unwind(
                ::std::panic::AssertUnwindSafe(|| { run() }),
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
                        "{} panicked: {}", "run", rustcall_message
                    );
                    __RUSTCALL_PANIC_RUSTCALL_A__DEEP_0ER__RUN
                        .with(|rustcall_slot| {
                            *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                                rustcall_message,
                            );
                        });
                    unsafe { ::std::mem::zeroed::<i32>() }
                }
            }
        }
        pub fn snake_case_fn(x_1: i32) -> i32 {
            x_1
        }
        thread_local! {
            static __RUSTCALL_PANIC_RUSTCALL_A__DEEP_0ER__SNAKE_0CASE_0FN :
            ::std::cell::RefCell < ::std::option::Option < ::std::string::String >> =
            ::std::cell::RefCell::new(::std::option::Option::None);
        }
        #[no_mangle]
        pub extern "C" fn rustcall_a__deep_0er__snake_0case_0fn_take_panic(
            out: *mut u8,
            cap: usize,
        ) -> usize {
            __RUSTCALL_PANIC_RUSTCALL_A__DEEP_0ER__SNAKE_0CASE_0FN
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
        pub extern "C" fn rustcall_a__deep_0er__snake_0case_0fn(x_1: i32) -> i32 {
            let _rustcall_boundary = crate::__RustCallBoundary::enter();
            match ::std::panic::catch_unwind(
                ::std::panic::AssertUnwindSafe(|| { snake_case_fn(x_1) }),
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
                        "{} panicked: {}", "snake_case_fn", rustcall_message
                    );
                    __RUSTCALL_PANIC_RUSTCALL_A__DEEP_0ER__SNAKE_0CASE_0FN
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
}
pub mod b {
    pub fn run() -> i32 {
        2
    }
    thread_local! {
        static __RUSTCALL_PANIC_RUSTCALL_B__RUN : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn rustcall_b__run_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_PANIC_RUSTCALL_B__RUN
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
    pub extern "C" fn rustcall_b__run() -> i32 {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| { run() })) {
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
                    "{} panicked: {}", "run", rustcall_message
                );
                __RUSTCALL_PANIC_RUSTCALL_B__RUN
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
                unsafe { ::std::mem::zeroed::<i32>() }
            }
        }
    }
    pub struct C {
        pub v: i32,
    }
    thread_local! {
        static __RUSTCALL_DROP_PANIC_625F5F435F66726565 : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn b__C_free_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_DROP_PANIC_625F5F435F66726565
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
    pub extern "C" fn b__C_free(ptr: *mut C) {
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
                    "{} panicked: {}", "C::drop", rustcall_message
                );
                __RUSTCALL_DROP_PANIC_625F5F435F66726565
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
            }
        }
    }
    thread_local! {
        static __RUSTCALL_HELPER_PANIC_625F5F435F6765745F76 : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn b__C_get_v_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_HELPER_PANIC_625F5F435F6765745F76
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
    pub extern "C" fn b__C_get_v(ptr: *const C) -> i32 {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| { { unsafe { (*ptr).v } } }),
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
                    "{} panicked: {}", "b__C_get_v", rustcall_message
                );
                __RUSTCALL_HELPER_PANIC_625F5F435F6765745F76
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
                unsafe { ::std::mem::zeroed::<i32>() }
            }
        }
    }
    thread_local! {
        static __RUSTCALL_HELPER_PANIC_625F5F435F7365745F76 : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn b__C_set_v_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_HELPER_PANIC_625F5F435F7365745F76
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
    pub extern "C" fn b__C_set_v(ptr: *mut C, value: i32) {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| {
                {
                    unsafe {
                        (*ptr).v = value;
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
                    "{} panicked: {}", "b__C_set_v", rustcall_message
                );
                __RUSTCALL_HELPER_PANIC_625F5F435F7365745F76
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
            }
        }
    }
    thread_local! {
        static __RUSTCALL_PANIC_RUSTCALL_B__C_NEW : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn rustcall_b__C_new_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_PANIC_RUSTCALL_B__C_NEW
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
    pub extern "C" fn rustcall_b__C_new(v: i32) -> *mut C {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| {
                let obj = C::new(v);
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
                    "{} panicked: {}", "C::new", rustcall_message
                );
                __RUSTCALL_PANIC_RUSTCALL_B__C_NEW
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
        static __RUSTCALL_PANIC_RUSTCALL_B__C_GET : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn rustcall_b__C_get_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_PANIC_RUSTCALL_B__C_GET
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
    pub extern "C" fn rustcall_b__C_get(ptr: *const C) -> i32 {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| {
                let self_obj = unsafe { &*ptr };
                self_obj.get()
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
                    "{} panicked: {}", "C::get", rustcall_message
                );
                __RUSTCALL_PANIC_RUSTCALL_B__C_GET
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
                unsafe { ::std::mem::zeroed::<i32>() }
            }
        }
    }
    impl C {
        pub fn new(v: i32) -> Self {
            Self { v }
        }
        pub fn get(&self) -> i32 {
            self.v
        }
    }
}
pub fn run() -> i32 {
    0
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_RUN : ::std::cell::RefCell < ::std::option::Option <
    ::std::string::String >> = ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_run_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_RUN
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
pub extern "C" fn rustcall_run() -> i32 {
    let _rustcall_boundary = crate::__RustCallBoundary::enter();
    match ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| { run() })) {
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
                "{} panicked: {}", "run", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_RUN
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            unsafe { ::std::mem::zeroed::<i32>() }
        }
    }
}
pub mod a_b {
    pub fn c() -> i32 {
        4
    }
    thread_local! {
        static __RUSTCALL_PANIC_RUSTCALL_A_0B__C : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn rustcall_a_0b__c_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_PANIC_RUSTCALL_A_0B__C
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
    pub extern "C" fn rustcall_a_0b__c() -> i32 {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| { c() })) {
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
                    "{} panicked: {}", "c", rustcall_message
                );
                __RUSTCALL_PANIC_RUSTCALL_A_0B__C
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
pub mod a {
    pub fn b_c() -> i32 {
        5
    }
    thread_local! {
        static __RUSTCALL_PANIC_RUSTCALL_A__B_0C : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn rustcall_a__b_0c_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_PANIC_RUSTCALL_A__B_0C
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
    pub extern "C" fn rustcall_a__b_0c() -> i32 {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| { b_c() })) {
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
                    "{} panicked: {}", "b_c", rustcall_message
                );
                __RUSTCALL_PANIC_RUSTCALL_A__B_0C
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
thread_local! {
    static __RUSTCALL_QUIET_DEPTH : ::std::cell::Cell < usize > =
    ::std::cell::Cell::new(0);
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
