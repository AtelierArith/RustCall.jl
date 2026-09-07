//! Every shape `#[julia_pyo3]` accepts — a function, a struct and an impl
//! block — so the deprecation warning is checked on each of them.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use juliacall_macros::julia_pyo3;

#[julia_pyo3]
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[julia_pyo3]
pub struct Counter {
    pub value: i32,
}

#[julia_pyo3]
impl Counter {
    pub fn new(value: i32) -> Self {
        Self { value }
    }

    pub fn bump(&mut self, by: i32) -> i32 {
        self.value += by;
        self.value
    }
}
