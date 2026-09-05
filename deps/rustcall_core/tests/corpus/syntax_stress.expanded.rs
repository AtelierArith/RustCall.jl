//! A module-level doc comment retained by the syntax round trip.
///An attributed function with nested generic arguments.
#[inline]
pub fn nested<T>(value: Vec<Option<Result<T, String>>>) -> usize
where
    T: Clone + Send,
{
    value.len()
}
#[no_mangle]
pub extern "C" fn const_expression(value: [u8; { if 1 < 2 { 3 } else { 4 } }]) -> u8 {
    value[0]
}
#[no_mangle]
/// The raw string deliberately contains braces that are not Rust blocks.
pub extern "C" fn raw_braces() -> &'static str {
    r##"left { middle } right"##
}
fn marker_in_string_is_not_an_attribute() -> &'static str {
    "#[julia] fn imaginary() -> i32 { 99 }"
}
#[allow(dead_code)]
fn borrow_for<'a>(value: &'a str, fallback: &'a str) -> &'a str {
    if value.is_empty() { fallback } else { value }
}
#[no_mangle]
#[cfg(any())]
pub extern "C" fn cfg_disabled() -> i32 {
    7
}
