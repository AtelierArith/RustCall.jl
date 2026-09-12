//! A `#[julia] impl` block in another module than its struct (#315).
//!
//! The struct sits at the crate root; its methods come from a marked child
//! module through `super::`, from another through `crate::`, and from an
//! unmarked module through a `use`. Every method symbol follows the *struct*
//! (`rustcall_Gauge_read`), not the module the block was written in, in both
//! flavours: the crate flavour reads the header (`impl_target_module_path`),
//! the inline flavour resolves it against the whole block (`ModelTree`).
//! A second struct lives in a marked module and gets a method from a sibling
//! marked module by its full path.
//!
//! A cross-module method's wrapper is emitted **inside the impl's module**
//! (#342), so a signature may name a type only that module can see
//! (`ops::Count`); its string buffers are the wrapper's own
//! (`Gauge_label_RustCallOwnedString`), not the struct's.
pub struct Gauge {
    pub value: i32,
}
thread_local! {
    static __RUSTCALL_DROP_PANIC_47617567655F66726565 : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn Gauge_free_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_DROP_PANIC_47617567655F66726565
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
pub extern "C" fn Gauge_free(ptr: *mut Gauge) {
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
                "{} panicked: {}", "Gauge::drop", rustcall_message
            );
            __RUSTCALL_DROP_PANIC_47617567655F66726565
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
        }
    }
}
thread_local! {
    static __RUSTCALL_HELPER_PANIC_47617567655F6765745F76616C7565 : ::std::cell::RefCell
    < ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn Gauge_get_value_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_HELPER_PANIC_47617567655F6765745F76616C7565
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
pub extern "C" fn Gauge_get_value(ptr: *const Gauge) -> i32 {
    let _rustcall_boundary = crate::__RustCallBoundary::enter();
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| { { unsafe { (*ptr).value } } }),
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
                "{} panicked: {}", "Gauge_get_value", rustcall_message
            );
            __RUSTCALL_HELPER_PANIC_47617567655F6765745F76616C7565
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
    static __RUSTCALL_HELPER_PANIC_47617567655F7365745F76616C7565 : ::std::cell::RefCell
    < ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn Gauge_set_value_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_HELPER_PANIC_47617567655F7365745F76616C7565
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
pub extern "C" fn Gauge_set_value(ptr: *mut Gauge, value: i32) {
    let _rustcall_boundary = crate::__RustCallBoundary::enter();
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            {
                unsafe {
                    (*ptr).value = value;
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
                "{} panicked: {}", "Gauge_set_value", rustcall_message
            );
            __RUSTCALL_HELPER_PANIC_47617567655F7365745F76616C7565
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
        }
    }
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_GAUGE_NEW : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_Gauge_new_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_GAUGE_NEW
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
pub extern "C" fn rustcall_Gauge_new(value: i32) -> *mut Gauge {
    let _rustcall_boundary = crate::__RustCallBoundary::enter();
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let obj = Gauge::new(value);
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
                "{} panicked: {}", "Gauge::new", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_GAUGE_NEW
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            ::std::ptr::null_mut()
        }
    }
}
impl Gauge {
    pub fn new(value: i32) -> Self {
        Self { value }
    }
}
pub mod ops {
    type Count = i32;
    impl super::Gauge {
        pub fn read(&self) -> Count {
            self.value
        }
        pub fn bump(&mut self) {
            self.value += 1;
        }
    }
    thread_local! {
        static __RUSTCALL_PANIC_RUSTCALL_GAUGE_READ : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn rustcall_Gauge_read_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_PANIC_RUSTCALL_GAUGE_READ
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
    pub extern "C" fn rustcall_Gauge_read(ptr: *const super::Gauge) -> Count {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| {
                let self_obj = unsafe { &*ptr };
                self_obj.read()
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
                    "{} panicked: {}", "Gauge::read", rustcall_message
                );
                __RUSTCALL_PANIC_RUSTCALL_GAUGE_READ
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
                unsafe { ::std::mem::zeroed::<Count>() }
            }
        }
    }
    thread_local! {
        static __RUSTCALL_PANIC_RUSTCALL_GAUGE_BUMP : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn rustcall_Gauge_bump_take_panic(out: *mut u8, cap: usize) -> usize {
        __RUSTCALL_PANIC_RUSTCALL_GAUGE_BUMP
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
    pub extern "C" fn rustcall_Gauge_bump(ptr: *mut super::Gauge) {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| {
                let self_obj = unsafe { &mut *ptr };
                self_obj.bump()
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
                    "{} panicked: {}", "Gauge::bump", rustcall_message
                );
                __RUSTCALL_PANIC_RUSTCALL_GAUGE_BUMP
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
            }
        }
    }
}
pub mod more {
    impl crate::Gauge {
        pub fn label(&self) -> String {
            format!("Gauge({})", self.value)
        }
        pub fn scaled(value: i32, factor: i32) -> Self {
            Self { value: value * factor }
        }
    }
    thread_local! {
        static __RUSTCALL_PANIC_RUSTCALL_GAUGE_LABEL : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn rustcall_Gauge_label_take_panic(
        out: *mut u8,
        cap: usize,
    ) -> usize {
        __RUSTCALL_PANIC_RUSTCALL_GAUGE_LABEL
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
    pub struct Gauge_label_RustCallOwnedString {
        pub ptr: *mut u8,
        pub len: usize,
        pub cap: usize,
    }
    #[no_mangle]
    pub extern "C" fn Gauge_label_free_rust_string(
        ptr: *mut u8,
        len: usize,
        cap: usize,
    ) {
        if !ptr.is_null() {
            unsafe {
                drop(Vec::from_raw_parts(ptr, len, cap));
            }
        }
    }
    #[no_mangle]
    pub extern "C" fn rustcall_Gauge_label(
        ptr: *const crate::Gauge,
    ) -> Gauge_label_RustCallOwnedString {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| {
                let self_obj = unsafe { &*ptr };
                let rustcall_value = self_obj.label();
                let mut rustcall_bytes = ToString::to_string(&rustcall_value)
                    .into_bytes();
                let rustcall_ret = Gauge_label_RustCallOwnedString {
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
                    "{} panicked: {}", "Gauge::label", rustcall_message
                );
                __RUSTCALL_PANIC_RUSTCALL_GAUGE_LABEL
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
                Gauge_label_RustCallOwnedString {
                    ptr: ::std::ptr::null_mut(),
                    len: 0,
                    cap: 0,
                }
            }
        }
    }
    thread_local! {
        static __RUSTCALL_PANIC_RUSTCALL_GAUGE_SCALED : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn rustcall_Gauge_scaled_take_panic(
        out: *mut u8,
        cap: usize,
    ) -> usize {
        __RUSTCALL_PANIC_RUSTCALL_GAUGE_SCALED
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
    pub extern "C" fn rustcall_Gauge_scaled(
        value: i32,
        factor: i32,
    ) -> *mut crate::Gauge {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| {
                let obj = crate::Gauge::scaled(value, factor);
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
                    "{} panicked: {}", "Gauge::scaled", rustcall_message
                );
                __RUSTCALL_PANIC_RUSTCALL_GAUGE_SCALED
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
                ::std::ptr::null_mut()
            }
        }
    }
}
pub mod plain {
    use super::Gauge;
    impl Gauge {
        pub fn halved(&self) -> Result<i32, String> {
            if self.value % 2 == 0 {
                Ok(self.value / 2)
            } else {
                Err(format!("{} is odd", self.value))
            }
        }
    }
    thread_local! {
        static __RUSTCALL_PANIC_RUSTCALL_GAUGE_HALVED : ::std::cell::RefCell <
        ::std::option::Option < ::std::string::String >> =
        ::std::cell::RefCell::new(::std::option::Option::None);
    }
    #[no_mangle]
    pub extern "C" fn rustcall_Gauge_halved_take_panic(
        out: *mut u8,
        cap: usize,
    ) -> usize {
        __RUSTCALL_PANIC_RUSTCALL_GAUGE_HALVED
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
    pub struct Gauge_halved_RustCallOwnedString {
        pub ptr: *mut u8,
        pub len: usize,
        pub cap: usize,
    }
    #[no_mangle]
    pub extern "C" fn Gauge_halved_free_rust_string(
        ptr: *mut u8,
        len: usize,
        cap: usize,
    ) {
        if !ptr.is_null() {
            unsafe {
                drop(Vec::from_raw_parts(ptr, len, cap));
            }
        }
    }
    #[repr(C)]
    pub struct CResult_Gauge_halved {
        is_ok: u8,
        /// Only initialized when `is_ok == 1`. `MaybeUninit` keeps the
        /// inactive field free of validity invariants (e.g. `NonZeroU32`).
        ok_value: ::std::mem::MaybeUninit<i32>,
        /// Only initialized when `is_ok == 0`.
        err_value: ::std::mem::MaybeUninit<Gauge_halved_RustCallOwnedString>,
    }
    impl CResult_Gauge_halved {
        /// Wrap a `Result` in the C-compatible representation.
        pub fn new(value: Result<i32, Gauge_halved_RustCallOwnedString>) -> Self {
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
        pub fn err(&self) -> Option<&Gauge_halved_RustCallOwnedString> {
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
    pub extern "C" fn rustcall_Gauge_halved(ptr: *const Gauge) -> CResult_Gauge_halved {
        let _rustcall_boundary = crate::__RustCallBoundary::enter();
        match ::std::panic::catch_unwind(
            ::std::panic::AssertUnwindSafe(|| {
                let self_obj = unsafe { &*ptr };
                CResult_Gauge_halved::new(
                    match self_obj.halved() {
                        ::std::result::Result::Ok(rustcall_ok) => {
                            ::std::result::Result::Ok(rustcall_ok)
                        }
                        ::std::result::Result::Err(rustcall_err) => {
                            ::std::result::Result::Err({
                                let mut rustcall_bytes = ToString::to_string(&rustcall_err)
                                    .into_bytes();
                                let rustcall_buf = Gauge_halved_RustCallOwnedString {
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
                    "{} panicked: {}", "Gauge::halved", rustcall_message
                );
                __RUSTCALL_PANIC_RUSTCALL_GAUGE_HALVED
                    .with(|rustcall_slot| {
                        *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                            rustcall_message,
                        );
                    });
                CResult_Gauge_halved::panicked()
            }
        }
    }
}
pub mod a {
    pub struct C {
        pub v: i32,
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
    impl C {
        pub fn new(v: i32) -> Self {
            Self { v }
        }
    }
}
pub mod b {
    impl crate::a::C {
        pub fn get(&self) -> i32 {
            self.v
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
    pub extern "C" fn rustcall_a__C_get(ptr: *const crate::a::C) -> i32 {
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
