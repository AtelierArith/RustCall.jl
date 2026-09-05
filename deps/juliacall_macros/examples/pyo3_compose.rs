//! `#[julia]` composes with other proc-macro attributes (#279).
//!
//! Before #279 `#[julia]` *replaced* the annotated item, so PyO3's generated
//! wrapper called the transformed signature and stacking the two attributes
//! failed to compile for every `Result` / `Option` / `String` signature
//! (see #275). `#[julia]` is now additive: the item stays exactly as written
//! and the C entry point is emitted next to it as `rustcall_<fn>`.
//!
//! This is a **compile** test in both attribute orders. It lives in
//! `examples/` rather than `tests/` on purpose: `cargo test` and
//! `cargo clippy --all-targets` build it, but nothing runs it, so the suite
//! never has to load libpython on a machine that only has the headers.
//! The runnable assertions live in `tests/additive.rs`, which needs no PyO3.

#![allow(dead_code)]
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use juliacall_macros::julia;
use pyo3::prelude::*;

/// The error type is a plain FFI-compatible newtype: RustCall needs a payload
/// that survives the C ABI, PyO3 needs `Into<PyErr>`.
#[repr(transparent)]
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub struct Odd(pub i32);

impl From<Odd> for PyErr {
    fn from(value: Odd) -> PyErr {
        pyo3::exceptions::PyValueError::new_err(value.0)
    }
}

// `Result`, `#[julia]` outermost.
#[julia]
#[pyfunction]
fn checked_halve(x: i32) -> Result<i32, Odd> {
    if x % 2 == 0 {
        Ok(x / 2)
    } else {
        Err(Odd(x))
    }
}

// `Result`, `#[pyfunction]` outermost.
#[pyfunction]
#[julia]
fn checked_halve_flipped(x: i32) -> Result<i32, Odd> {
    if x % 2 == 0 {
        Ok(x / 2)
    } else {
        Err(Odd(x))
    }
}

// `String` in and out, both orders.
#[julia]
#[pyfunction]
fn shout(s: String) -> String {
    s.to_uppercase()
}

#[pyfunction]
#[julia]
fn shout_flipped(s: String) -> String {
    s.to_uppercase()
}

// `Option`, and a signature with nothing to transform.
#[julia]
#[pyfunction]
fn maybe_pred(x: i32) -> Option<i32> {
    x.checked_sub(1)
}

#[pyfunction]
#[julia]
fn plain_add(a: i32, b: i32) -> i32 {
    a + b
}

/// An ordinary in-crate caller still sees the signature that was written.
fn in_crate_caller() -> String {
    format!(
        "{:?}|{:?}|{}|{}|{:?}|{}",
        checked_halve(4),
        checked_halve_flipped(8),
        shout("hi".to_string()),
        shout_flipped("hi".to_string()),
        maybe_pred(3),
        plain_add(1, 2),
    )
}

fn main() {
    println!("{}", in_crate_caller());
    // The C entry points live next to the originals.
    assert!(rustcall_checked_halve(4).is_ok());
    assert_eq!(rustcall_plain_add(2, 3), 5);
}
