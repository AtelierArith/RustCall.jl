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
#[no_mangle]
pub extern "C" fn rustcall_const_expression(
    value: [u8; { if 1 < 2 { 3 } else { 4 } }],
) -> u8 {
    const_expression(value)
}
/// The raw string deliberately contains braces that are not Rust blocks.
fn raw_braces() -> &'static str {
    r##"left { middle } right"##
}
#[repr(C)]
pub struct raw_braces_RustCallBorrowedString {
    pub ptr: *const u8,
    pub len: usize,
}
#[no_mangle]
pub extern "C" fn rustcall_raw_braces() -> raw_braces_RustCallBorrowedString {
    let rustcall_value = raw_braces();
    raw_braces_RustCallBorrowedString {
        ptr: rustcall_value.as_ptr(),
        len: rustcall_value.len(),
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
#[no_mangle]
pub extern "C" fn rustcall_cfg_disabled() -> i32 {
    cfg_disabled()
}
