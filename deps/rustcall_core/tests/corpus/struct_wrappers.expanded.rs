#[derive(Clone)]
pub struct Greeter {
    pub name: String,
    pub visits: u32,
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
pub extern "C" fn Greeter_get_name(ptr: *const Greeter) -> Greeter_RustCallOwnedString {
    let mut rustcall_bytes = unsafe { (*ptr).name.clone().into_bytes() };
    let rustcall_ret = Greeter_RustCallOwnedString {
        ptr: rustcall_bytes.as_mut_ptr(),
        len: rustcall_bytes.len(),
        cap: rustcall_bytes.capacity(),
    };
    std::mem::forget(rustcall_bytes);
    rustcall_ret
}
#[no_mangle]
pub extern "C" fn Greeter_set_name(ptr: *mut Greeter, value: String) {
    unsafe {
        (*ptr).name = value;
    }
}
#[no_mangle]
pub extern "C" fn Greeter_get_visits(ptr: *const Greeter) -> u32 {
    unsafe { (*ptr).visits }
}
#[no_mangle]
pub extern "C" fn Greeter_set_visits(ptr: *mut Greeter, value: u32) {
    unsafe {
        (*ptr).visits = value;
    }
}
#[no_mangle]
pub extern "C" fn Greeter_clone(ptr: *const Greeter) -> *mut Greeter {
    unsafe { Box::into_raw(Box::new((*ptr).clone())) }
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
pub extern "C" fn rustcall_Greeter_new(
    name_ptr: *const u8,
    name_len: usize,
) -> *mut Greeter {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let name = unsafe {
                let slice = std::slice::from_raw_parts(name_ptr, name_len);
                String::from_utf8_lossy(slice).into_owned()
            };
            let obj = Greeter::new(name);
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
    static __RUSTCALL_PANIC_RUSTCALL_GREETER_RENAME : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_Greeter_rename_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_GREETER_RENAME
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
pub extern "C" fn rustcall_Greeter_rename(
    ptr: *mut Greeter,
    name_ptr: *const u8,
    name_len: usize,
) {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let name = unsafe {
                let slice = std::slice::from_raw_parts(name_ptr, name_len);
                String::from_utf8_lossy(slice).into_owned()
            };
            let self_obj = unsafe { &mut *ptr };
            self_obj.rename(name)
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
                "{} panicked: {}", "Greeter::rename", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_GREETER_RENAME
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
        }
    }
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_GREETER_GREET : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_Greeter_greet_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_GREETER_GREET
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
pub extern "C" fn rustcall_Greeter_greet(
    ptr: *const Greeter,
    prefix_ptr: *const u8,
    prefix_len: usize,
) -> Greeter_RustCallOwnedString {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let prefix_bytes = unsafe {
                std::slice::from_raw_parts(prefix_ptr, prefix_len)
            };
            let prefix_cow = String::from_utf8_lossy(prefix_bytes);
            let prefix: &str = &prefix_cow;
            let self_obj = unsafe { &*ptr };
            let rustcall_value = self_obj.greet(prefix);
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
                "{} panicked: {}", "Greeter::greet", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_GREETER_GREET
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
    static __RUSTCALL_PANIC_RUSTCALL_GREETER_NAME : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_Greeter_name_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_GREETER_NAME
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
pub extern "C" fn rustcall_Greeter_name(
    ptr: *const Greeter,
) -> Greeter_RustCallBorrowedString {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let self_obj = unsafe { &*ptr };
            let rustcall_value = self_obj.name();
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
                "{} panicked: {}", "Greeter::name", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_GREETER_NAME
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
impl Greeter {
    pub fn new(name: String) -> Self {
        Self { name, visits: 0 }
    }
    pub fn rename(&mut self, name: String) {
        self.name = name;
    }
    pub fn greet(&self, prefix: &str) -> String {
        format!("{prefix}, {}", self.name)
    }
    pub fn name(&self) -> &str {
        &self.name
    }
}
pub fn checked_double(value: i32) -> Result<i32, i32> {
    value.checked_mul(2).ok_or(value)
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_CHECKED_DOUBLE : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_checked_double_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_CHECKED_DOUBLE
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
pub struct CResult_checked_double {
    is_ok: u8,
    /// Only initialized when `is_ok == 1`. `MaybeUninit` keeps the
    /// inactive field free of validity invariants (e.g. `NonZeroU32`).
    ok_value: ::std::mem::MaybeUninit<i32>,
    /// Only initialized when `is_ok == 0`.
    err_value: ::std::mem::MaybeUninit<i32>,
}
impl CResult_checked_double {
    /// Wrap a `Result` in the C-compatible representation.
    pub fn new(value: Result<i32, i32>) -> Self {
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
#[no_mangle]
pub extern "C" fn rustcall_checked_double(value: i32) -> CResult_checked_double {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            CResult_checked_double::new(checked_double(value))
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
                "{} panicked: {}", "checked_double", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_CHECKED_DOUBLE
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            CResult_checked_double::panicked()
        }
    }
}
pub fn positive(value: i32) -> Option<i32> {
    (value > 0).then_some(value)
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_POSITIVE : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_positive_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_POSITIVE
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
pub struct COption_positive {
    is_some: u8,
    /// Only initialized when `is_some == 1`.
    value: ::std::mem::MaybeUninit<i32>,
}
impl COption_positive {
    /// Wrap an `Option` in the C-compatible representation.
    pub fn new(value: Option<i32>) -> Self {
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
    pub fn some(&self) -> Option<&i32> {
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
#[no_mangle]
pub extern "C" fn rustcall_positive(value: i32) -> COption_positive {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| { COption_positive::new(positive(value)) }),
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
                "{} panicked: {}", "positive", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_POSITIVE
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            COption_positive::panicked()
        }
    }
}
pub struct Divider {
    pub scale: i32,
}
#[no_mangle]
pub extern "C" fn Divider_free(ptr: *mut Divider) {
    if !ptr.is_null() {
        unsafe {
            drop(Box::from_raw(ptr));
        }
    }
}
#[repr(C)]
pub struct Divider_RustCallOwnedString {
    pub ptr: *mut u8,
    pub len: usize,
    pub cap: usize,
}
#[no_mangle]
pub extern "C" fn Divider_free_rust_string(ptr: *mut u8, len: usize, cap: usize) {
    if !ptr.is_null() {
        unsafe {
            drop(Vec::from_raw_parts(ptr, len, cap));
        }
    }
}
#[no_mangle]
pub extern "C" fn Divider_get_scale(ptr: *const Divider) -> i32 {
    unsafe { (*ptr).scale }
}
#[no_mangle]
pub extern "C" fn Divider_set_scale(ptr: *mut Divider, value: i32) {
    unsafe {
        (*ptr).scale = value;
    }
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_DIVIDER_NEW : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_Divider_new_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_DIVIDER_NEW
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
pub extern "C" fn rustcall_Divider_new(scale: i32) -> *mut Divider {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let obj = Divider::new(scale);
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
                "{} panicked: {}", "Divider::new", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_DIVIDER_NEW
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
    static __RUSTCALL_PANIC_RUSTCALL_DIVIDER_CHECKED_DIV : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_Divider_checked_div_take_panic(
    out: *mut u8,
    cap: usize,
) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_DIVIDER_CHECKED_DIV
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
pub struct CResult_Divider_checked_div {
    is_ok: u8,
    /// Only initialized when `is_ok == 1`. `MaybeUninit` keeps the
    /// inactive field free of validity invariants (e.g. `NonZeroU32`).
    ok_value: ::std::mem::MaybeUninit<i32>,
    /// Only initialized when `is_ok == 0`.
    err_value: ::std::mem::MaybeUninit<Divider_RustCallOwnedString>,
}
impl CResult_Divider_checked_div {
    /// Wrap a `Result` in the C-compatible representation.
    pub fn new(value: Result<i32, Divider_RustCallOwnedString>) -> Self {
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
    pub fn err(&self) -> Option<&Divider_RustCallOwnedString> {
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
pub extern "C" fn rustcall_Divider_checked_div(
    ptr: *const Divider,
    d: i32,
) -> CResult_Divider_checked_div {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let self_obj = unsafe { &*ptr };
            CResult_Divider_checked_div::new(
                match self_obj.checked_div(d) {
                    ::std::result::Result::Ok(rustcall_ok) => {
                        ::std::result::Result::Ok(rustcall_ok)
                    }
                    ::std::result::Result::Err(rustcall_err) => {
                        ::std::result::Result::Err({
                            let mut rustcall_bytes = ToString::to_string(&rustcall_err)
                                .into_bytes();
                            let rustcall_buf = Divider_RustCallOwnedString {
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
                "{} panicked: {}", "Divider::checked_div", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_DIVIDER_CHECKED_DIV
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            CResult_Divider_checked_div::panicked()
        }
    }
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_DIVIDER_RATIO : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_Divider_ratio_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_DIVIDER_RATIO
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
pub struct COption_Divider_ratio {
    is_some: u8,
    /// Only initialized when `is_some == 1`.
    value: ::std::mem::MaybeUninit<f64>,
}
impl COption_Divider_ratio {
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
#[no_mangle]
pub extern "C" fn rustcall_Divider_ratio(
    ptr: *const Divider,
    d: i32,
) -> COption_Divider_ratio {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let self_obj = unsafe { &*ptr };
            COption_Divider_ratio::new(self_obj.ratio(d))
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
                "{} panicked: {}", "Divider::ratio", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_DIVIDER_RATIO
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            COption_Divider_ratio::panicked()
        }
    }
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_DIVIDER_DESCRIBE : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_Divider_describe_take_panic(
    out: *mut u8,
    cap: usize,
) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_DIVIDER_DESCRIBE
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
pub struct CResult_Divider_describe {
    is_ok: u8,
    /// Only initialized when `is_ok == 1`. `MaybeUninit` keeps the
    /// inactive field free of validity invariants (e.g. `NonZeroU32`).
    ok_value: ::std::mem::MaybeUninit<Divider_RustCallOwnedString>,
    /// Only initialized when `is_ok == 0`.
    err_value: ::std::mem::MaybeUninit<Divider_RustCallOwnedString>,
}
impl CResult_Divider_describe {
    /// Wrap a `Result` in the C-compatible representation.
    pub fn new(
        value: Result<Divider_RustCallOwnedString, Divider_RustCallOwnedString>,
    ) -> Self {
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
    pub fn ok(&self) -> Option<&Divider_RustCallOwnedString> {
        if self.is_ok == 1 {
            Some(unsafe { self.ok_value.assume_init_ref() })
        } else {
            None
        }
    }
    /// The `Err` value, if any.
    pub fn err(&self) -> Option<&Divider_RustCallOwnedString> {
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
pub extern "C" fn rustcall_Divider_describe(
    ptr: *const Divider,
    unit_ptr: *const u8,
    unit_len: usize,
) -> CResult_Divider_describe {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let unit = unsafe {
                let slice = std::slice::from_raw_parts(unit_ptr, unit_len);
                String::from_utf8_lossy(slice).into_owned()
            };
            let self_obj = unsafe { &*ptr };
            CResult_Divider_describe::new(
                match self_obj.describe(unit) {
                    ::std::result::Result::Ok(rustcall_ok) => {
                        ::std::result::Result::Ok({
                            let mut rustcall_bytes = ToString::to_string(&rustcall_ok)
                                .into_bytes();
                            let rustcall_buf = Divider_RustCallOwnedString {
                                ptr: rustcall_bytes.as_mut_ptr(),
                                len: rustcall_bytes.len(),
                                cap: rustcall_bytes.capacity(),
                            };
                            ::std::mem::forget(rustcall_bytes);
                            rustcall_buf
                        })
                    }
                    ::std::result::Result::Err(rustcall_err) => {
                        ::std::result::Result::Err({
                            let mut rustcall_bytes = ToString::to_string(&rustcall_err)
                                .into_bytes();
                            let rustcall_buf = Divider_RustCallOwnedString {
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
                "{} panicked: {}", "Divider::describe", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_DIVIDER_DESCRIBE
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            CResult_Divider_describe::panicked()
        }
    }
}
thread_local! {
    static __RUSTCALL_PANIC_RUSTCALL_DIVIDER_LABEL : ::std::cell::RefCell <
    ::std::option::Option < ::std::string::String >> =
    ::std::cell::RefCell::new(::std::option::Option::None);
}
#[no_mangle]
pub extern "C" fn rustcall_Divider_label_take_panic(out: *mut u8, cap: usize) -> usize {
    __RUSTCALL_PANIC_RUSTCALL_DIVIDER_LABEL
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
pub struct COption_Divider_label {
    is_some: u8,
    /// Only initialized when `is_some == 1`.
    value: ::std::mem::MaybeUninit<Divider_RustCallOwnedString>,
}
impl COption_Divider_label {
    /// Wrap an `Option` in the C-compatible representation.
    pub fn new(value: Option<Divider_RustCallOwnedString>) -> Self {
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
    pub fn some(&self) -> Option<&Divider_RustCallOwnedString> {
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
#[no_mangle]
pub extern "C" fn rustcall_Divider_label(ptr: *const Divider) -> COption_Divider_label {
    match ::std::panic::catch_unwind(
        ::std::panic::AssertUnwindSafe(|| {
            let self_obj = unsafe { &*ptr };
            COption_Divider_label::new(
                match self_obj.label() {
                    ::std::option::Option::Some(rustcall_some) => {
                        ::std::option::Option::Some({
                            let mut rustcall_bytes = ToString::to_string(&rustcall_some)
                                .into_bytes();
                            let rustcall_buf = Divider_RustCallOwnedString {
                                ptr: rustcall_bytes.as_mut_ptr(),
                                len: rustcall_bytes.len(),
                                cap: rustcall_bytes.capacity(),
                            };
                            ::std::mem::forget(rustcall_bytes);
                            rustcall_buf
                        })
                    }
                    ::std::option::Option::None => ::std::option::Option::None,
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
                "{} panicked: {}", "Divider::label", rustcall_message
            );
            __RUSTCALL_PANIC_RUSTCALL_DIVIDER_LABEL
                .with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() = ::std::option::Option::Some(
                        rustcall_message,
                    );
                });
            COption_Divider_label::panicked()
        }
    }
}
impl Divider {
    pub fn new(scale: i32) -> Self {
        Self { scale }
    }
    pub fn checked_div(&self, d: i32) -> Result<i32, String> {
        if d == 0 { Err("division by zero".to_string()) } else { Ok(self.scale / d) }
    }
    pub fn ratio(&self, d: i32) -> Option<f64> {
        (d != 0).then(|| self.scale as f64 / d as f64)
    }
    pub fn describe(&self, unit: String) -> Result<String, String> {
        if unit.is_empty() {
            Err("empty unit".to_string())
        } else {
            Ok(format!("{} {}", self.scale, unit))
        }
    }
    pub fn label(&self) -> Option<&'static str> {
        (self.scale > 0).then_some("positive")
    }
}
