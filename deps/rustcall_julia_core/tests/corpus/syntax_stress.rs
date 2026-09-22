//! A module-level doc comment retained by the syntax round trip.

/* outer comment /* nested comment */ still in the outer comment */

#[doc = "An attributed function with nested generic arguments."]
#[inline]
#[julia]
pub fn nested<T>(value: Vec<Option<Result<T, String>>>) -> usize
where
    T: Clone + Send,
{
    value.len()
}

#[julia]
fn const_expression(value: [u8; { if 1 < 2 { 3 } else { 4 } }]) -> u8 {
    value[0]
}

/// The raw string deliberately contains braces that are not Rust blocks.
#[julia]
fn raw_braces() -> &'static str {
    r##"left { middle } right"##
}

fn marker_in_string_is_not_an_attribute() -> &'static str {
    "#[julia] fn imaginary() -> i32 { 99 }"
}

#[allow(dead_code)]
fn borrow_for<'a>(value: &'a str, fallback: &'a str) -> &'a str {
    if value.is_empty() { fallback } else { value }
}

#[cfg(any())]
#[julia]
fn cfg_disabled() -> i32 {
    7
}
