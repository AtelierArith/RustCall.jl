//! `#[julia]` is additive (#279): the annotated item survives unchanged and
//! the C entry point is emitted next to it under `rustcall_<fn>` /
//! `rustcall_<Struct>_<method>`.
//!
//! The `#[pyfunction]` composition counterpart is `examples/pyo3_compose.rs`.

#![allow(dead_code)]
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use juliacall_macros::julia;

#[julia]
fn checked_halve(x: i32) -> Result<i32, i32> {
    if x % 2 == 0 {
        Ok(x / 2)
    } else {
        Err(x)
    }
}

#[julia]
fn maybe_pred(x: i32) -> Option<i32> {
    x.checked_sub(1)
}

#[julia]
fn shout(s: String) -> String {
    s.to_uppercase()
}

#[julia]
fn byte_len(s: &str) -> usize {
    s.len()
}

#[julia]
fn plain_add(a: i32, b: i32) -> i32 {
    a + b
}

pub struct Counter {
    value: i32,
}

#[julia]
impl Counter {
    #[julia]
    pub fn new(value: i32) -> Self {
        Self { value }
    }

    #[julia]
    pub fn bump(&mut self, by: i32) -> i32 {
        self.value += by;
        self.value
    }
}

/// An ordinary in-crate caller sees the signature that was written.
fn in_crate_caller() -> String {
    format!(
        "{:?}|{}|{}",
        checked_halve(4),
        shout("hi".into()),
        byte_len("abc")
    )
}

#[test]
fn annotated_items_keep_their_rust_signature() {
    assert_eq!(checked_halve(4), Ok(2));
    assert_eq!(checked_halve(5), Err(5));
    assert_eq!(maybe_pred(i32::MIN), None);
    assert_eq!(shout("hi".to_string()), "HI");
    assert_eq!(byte_len("abc"), 3);
    assert_eq!(plain_add(2, 3), 5);
    assert_eq!(in_crate_caller(), "Ok(2)|HI|3");

    let mut counter = Counter::new(1);
    assert_eq!(counter.bump(2), 3);
}

#[test]
fn the_c_entry_point_is_the_rustcall_symbol() {
    let ok = rustcall_checked_halve(4);
    assert!(ok.is_ok());
    assert_eq!(*ok.ok().unwrap(), 2);
    let err = rustcall_checked_halve(5);
    assert!(!err.is_ok());
    assert_eq!(*err.err().unwrap(), 5);

    let some = rustcall_maybe_pred(3);
    assert!(some.is_some());
    assert_eq!(*some.some().unwrap(), 2);

    assert_eq!(rustcall_plain_add(2, 3), 5);

    // `String` / `&str` arguments and returns travel as the byte-pair ABI (#242).
    let input = "hi";
    assert_eq!(rustcall_byte_len(input.as_ptr(), input.len()), 2);
    let out = rustcall_shout(input.as_ptr(), input.len());
    let bytes = unsafe { std::slice::from_raw_parts(out.ptr, out.len) };
    assert_eq!(std::str::from_utf8(bytes).unwrap(), "HI");
    shout_free_rust_string(out.ptr, out.len, out.cap);
}

#[test]
fn method_wrappers_are_prefixed_too() {
    let ptr = rustcall_Counter_new(10);
    assert_eq!(rustcall_Counter_bump(ptr, 5), 15);
    unsafe { drop(Box::from_raw(ptr)) };
}
