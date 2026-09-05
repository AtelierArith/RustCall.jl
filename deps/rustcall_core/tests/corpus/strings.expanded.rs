//! `String` / `&str` arguments and returns on `#[julia]` free functions (#242).
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
#[allow(clippy::ptr_arg)]
fn shout_inner(input: String) -> String {
    input.to_uppercase()
}
#[no_mangle]
pub extern "C" fn shout(
    input_ptr: *const u8,
    input_len: usize,
) -> shout_RustCallOwnedString {
    let input = unsafe {
        let slice = std::slice::from_raw_parts(input_ptr, input_len);
        String::from_utf8_lossy(slice).into_owned()
    };
    let rustcall_value = shout_inner(input);
    let mut rustcall_bytes = ToString::to_string(&rustcall_value).into_bytes();
    let rustcall_ret = shout_RustCallOwnedString {
        ptr: rustcall_bytes.as_mut_ptr(),
        len: rustcall_bytes.len(),
        cap: rustcall_bytes.capacity(),
    };
    std::mem::forget(rustcall_bytes);
    rustcall_ret
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
#[allow(clippy::ptr_arg)]
fn concat_inner(a: &str, b: &str, times: u32) -> String {
    let mut out = String::new();
    for _ in 0..times {
        out.push_str(a);
        out.push_str(b);
    }
    out
}
#[no_mangle]
pub extern "C" fn concat(
    a_ptr: *const u8,
    a_len: usize,
    b_ptr: *const u8,
    b_len: usize,
    times: u32,
) -> concat_RustCallOwnedString {
    let a_bytes = unsafe { std::slice::from_raw_parts(a_ptr, a_len) };
    let a_cow = String::from_utf8_lossy(a_bytes);
    let a: &str = &a_cow;
    let b_bytes = unsafe { std::slice::from_raw_parts(b_ptr, b_len) };
    let b_cow = String::from_utf8_lossy(b_bytes);
    let b: &str = &b_cow;
    let rustcall_value = concat_inner(a, b, times);
    let mut rustcall_bytes = ToString::to_string(&rustcall_value).into_bytes();
    let rustcall_ret = concat_RustCallOwnedString {
        ptr: rustcall_bytes.as_mut_ptr(),
        len: rustcall_bytes.len(),
        cap: rustcall_bytes.capacity(),
    };
    std::mem::forget(rustcall_bytes);
    rustcall_ret
}
#[allow(clippy::ptr_arg)]
fn byte_len_inner(s: &str) -> usize {
    s.len()
}
#[no_mangle]
pub extern "C" fn byte_len(s_ptr: *const u8, s_len: usize) -> usize {
    let s_bytes = unsafe { std::slice::from_raw_parts(s_ptr, s_len) };
    let s_cow = String::from_utf8_lossy(s_bytes);
    let s: &str = &s_cow;
    byte_len_inner(s)
}
#[repr(C)]
pub struct greeting_RustCallBorrowedString {
    pub ptr: *const u8,
    pub len: usize,
}
#[allow(clippy::ptr_arg)]
fn greeting_inner() -> &'static str {
    "hello"
}
#[no_mangle]
pub extern "C" fn greeting() -> greeting_RustCallBorrowedString {
    let rustcall_value = greeting_inner();
    greeting_RustCallBorrowedString {
        ptr: rustcall_value.as_ptr(),
        len: rustcall_value.len(),
    }
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
#[allow(clippy::ptr_arg)]
fn unix_name_inner(s: String) -> String {
    s
}
#[cfg(unix)]
#[no_mangle]
pub extern "C" fn unix_name(
    s_ptr: *const u8,
    s_len: usize,
) -> unix_name_RustCallOwnedString {
    let s = unsafe {
        let slice = std::slice::from_raw_parts(s_ptr, s_len);
        String::from_utf8_lossy(slice).into_owned()
    };
    let rustcall_value = unix_name_inner(s);
    let mut rustcall_bytes = ToString::to_string(&rustcall_value).into_bytes();
    let rustcall_ret = unix_name_RustCallOwnedString {
        ptr: rustcall_bytes.as_mut_ptr(),
        len: rustcall_bytes.len(),
        cap: rustcall_bytes.capacity(),
    };
    std::mem::forget(rustcall_bytes);
    rustcall_ret
}
#[allow(clippy::ptr_arg)]
fn consume_inner(s: (String)) -> usize {
    s.len()
}
#[no_mangle]
pub extern "C" fn consume(s_ptr: *const u8, s_len: usize) -> usize {
    let s = unsafe {
        let slice = std::slice::from_raw_parts(s_ptr, s_len);
        String::from_utf8_lossy(slice).into_owned()
    };
    consume_inner(s)
}
#[allow(clippy::ptr_arg)]
fn paren_ref_inner(s: &(str)) -> (usize) {
    s.len()
}
#[no_mangle]
pub extern "C" fn paren_ref(s_ptr: *const u8, s_len: usize) -> (usize) {
    let s_bytes = unsafe { std::slice::from_raw_parts(s_ptr, s_len) };
    let s_cow = String::from_utf8_lossy(s_bytes);
    let s: &str = &s_cow;
    paren_ref_inner(s)
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
pub extern "C" fn Greeter_get_count(ptr: *const Greeter) -> u32 {
    unsafe { (*ptr).count }
}
#[no_mangle]
pub extern "C" fn Greeter_set_count(ptr: *mut Greeter, value: u32) {
    unsafe {
        (*ptr).count = value;
    }
}
#[no_mangle]
pub extern "C" fn Greeter_new(count: u32) -> *mut Greeter {
    let obj = Greeter::new(count);
    Box::into_raw(Box::new(obj))
}
#[no_mangle]
pub extern "C" fn Greeter_shout(
    ptr: *const Greeter,
    suffix_ptr: *const u8,
    suffix_len: usize,
) -> Greeter_RustCallOwnedString {
    let suffix_bytes = unsafe { std::slice::from_raw_parts(suffix_ptr, suffix_len) };
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
}
#[no_mangle]
pub extern "C" fn Greeter_label(ptr: *const Greeter) -> Greeter_RustCallBorrowedString {
    let self_obj = unsafe { &*ptr };
    let rustcall_value = self_obj.label();
    Greeter_RustCallBorrowedString {
        ptr: rustcall_value.as_ptr(),
        len: rustcall_value.len(),
    }
}
#[no_mangle]
pub extern "C" fn Greeter_take(
    ptr: *mut Greeter,
    s_ptr: *const u8,
    s_len: usize,
) -> usize {
    let s = unsafe {
        let slice = std::slice::from_raw_parts(s_ptr, s_len);
        String::from_utf8_lossy(slice).into_owned()
    };
    let self_obj = unsafe { &mut *ptr };
    self_obj.take(s)
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
