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
    ptr: *mut u8,
    len: usize,
    cap: usize,
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
    ptr: *const u8,
    len: usize,
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
#[no_mangle]
pub extern "C" fn Greeter_new(name_ptr: *const u8, name_len: usize) -> *mut Greeter {
    let name = unsafe {
        let slice = std::slice::from_raw_parts(name_ptr, name_len);
        String::from_utf8_lossy(slice).into_owned()
    };
    let obj = Greeter::new(name);
    Box::into_raw(Box::new(obj))
}
#[no_mangle]
pub extern "C" fn Greeter_rename(
    ptr: *mut Greeter,
    name_ptr: *const u8,
    name_len: usize,
) {
    let name = unsafe {
        let slice = std::slice::from_raw_parts(name_ptr, name_len);
        String::from_utf8_lossy(slice).into_owned()
    };
    let self_obj = unsafe { &mut *ptr };
    self_obj.rename(name)
}
#[no_mangle]
pub extern "C" fn Greeter_greet(
    ptr: *const Greeter,
    prefix_ptr: *const u8,
    prefix_len: usize,
) -> Greeter_RustCallOwnedString {
    let prefix_bytes = unsafe { std::slice::from_raw_parts(prefix_ptr, prefix_len) };
    let prefix = unsafe { std::str::from_utf8_unchecked(prefix_bytes) };
    let self_obj = unsafe { &*ptr };
    let rustcall_value = self_obj.greet(prefix);
    let mut rustcall_bytes = rustcall_value.into_bytes();
    let rustcall_ret = Greeter_RustCallOwnedString {
        ptr: rustcall_bytes.as_mut_ptr(),
        len: rustcall_bytes.len(),
        cap: rustcall_bytes.capacity(),
    };
    std::mem::forget(rustcall_bytes);
    rustcall_ret
}
#[no_mangle]
pub extern "C" fn Greeter_name(ptr: *const Greeter) -> Greeter_RustCallBorrowedString {
    let self_obj = unsafe { &*ptr };
    let rustcall_value = self_obj.name();
    Greeter_RustCallBorrowedString {
        ptr: rustcall_value.as_ptr(),
        len: rustcall_value.len(),
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
#[repr(C)]
pub struct CResult_checked_double {
    pub is_ok: u8,
    /// Only initialized when `is_ok == 1`. `MaybeUninit` keeps the
    /// inactive field free of validity invariants (e.g. `NonZeroU32`).
    pub ok_value: ::std::mem::MaybeUninit<i32>,
    /// Only initialized when `is_ok == 0`.
    pub err_value: ::std::mem::MaybeUninit<i32>,
}
impl CResult_checked_double {
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
}
fn checked_double_inner(value: i32) -> Result<i32, i32> {
    value.checked_mul(2).ok_or(value)
}
#[no_mangle]
pub extern "C" fn checked_double(value: i32) -> CResult_checked_double {
    match checked_double_inner(value) {
        Ok(value) => {
            CResult_checked_double {
                is_ok: 1,
                ok_value: ::std::mem::MaybeUninit::new(value),
                err_value: ::std::mem::MaybeUninit::zeroed(),
            }
        }
        Err(err) => {
            CResult_checked_double {
                is_ok: 0,
                ok_value: ::std::mem::MaybeUninit::zeroed(),
                err_value: ::std::mem::MaybeUninit::new(err),
            }
        }
    }
}
#[repr(C)]
pub struct COption_positive {
    pub is_some: u8,
    /// Only initialized when `is_some == 1`.
    pub value: ::std::mem::MaybeUninit<i32>,
}
impl COption_positive {
    /// The `Some` value, if any.
    pub fn some(&self) -> Option<&i32> {
        if self.is_some == 1 {
            Some(unsafe { self.value.assume_init_ref() })
        } else {
            None
        }
    }
}
fn positive_inner(value: i32) -> Option<i32> {
    (value > 0).then_some(value)
}
#[no_mangle]
pub extern "C" fn positive(value: i32) -> COption_positive {
    match positive_inner(value) {
        Some(value) => {
            COption_positive {
                is_some: 1,
                value: ::std::mem::MaybeUninit::new(value),
            }
        }
        None => {
            COption_positive {
                is_some: 0,
                value: ::std::mem::MaybeUninit::zeroed(),
            }
        }
    }
}
