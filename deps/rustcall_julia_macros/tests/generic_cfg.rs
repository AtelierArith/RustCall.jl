//! A generic `#[julia]` item is refused (#462) only where it exists: the
//! refusal carries the item's effective `#[cfg]`, so an item gated off for
//! this build breaks nothing (PR #470 review).
//!
//! Inside a `#[julia] mod` the module macro expands the nested items before
//! rustc evaluates their `#[cfg]`, and at the top level a `#[cfg]` written
//! *after* `#[julia]` reaches the macro too. `any()` is never true. This file
//! compiling is the test.
#![allow(dead_code)]
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use rustcall_julia_macros::julia;

#[julia]
#[cfg(any())]
pub fn top_fn<T: Copy>(x: T) -> T {
    x
}

#[julia]
#[cfg(any())]
pub struct TopStruct<T> {
    pub value: T,
}

#[julia]
pub struct Concrete {
    pub x: f64,
}

#[julia]
#[cfg(any())]
impl<T: Copy> TopStruct<T> {
    #[julia]
    pub fn get(&self) -> T {
        self.value
    }
}

#[julia]
impl Concrete {
    #[julia]
    #[cfg(any())]
    pub fn scaled<U: Into<f64>>(&self, by: U) -> f64 {
        self.x * by.into()
    }

    #[julia]
    pub fn norm(&self) -> f64 {
        self.x.abs()
    }
}

#[cfg(any())]
#[julia]
impl Concrete {
    #[julia]
    pub fn gated_block<U: Into<f64>>(&self, by: U) -> f64 {
        self.x * by.into()
    }
}

#[julia]
pub mod nested {
    #[cfg(any())]
    #[julia]
    pub fn inner_fn<T: Copy>(x: T) -> T {
        x
    }

    #[cfg(any())]
    #[julia]
    pub struct InnerStruct<T> {
        pub value: T,
    }

    #[julia]
    pub struct InnerConcrete {
        pub x: f64,
    }

    #[cfg(any())]
    #[julia]
    impl<T: Copy> InnerStruct<T> {
        #[julia]
        pub fn get(&self) -> T {
            self.value
        }
    }

    #[julia]
    impl InnerConcrete {
        #[cfg(any())]
        #[julia]
        pub fn scaled<U: Into<f64>>(&self, by: U) -> f64 {
            self.x * by.into()
        }
    }

    #[cfg(any())]
    #[julia]
    impl InnerConcrete {
        #[julia]
        pub fn gated_block<U: Into<f64>>(&self, by: U) -> f64 {
            self.x * by.into()
        }
    }

    #[cfg(any())]
    #[julia]
    pub fn unsafe_gated() -> Option<Vec<i32>> {
        None
    }
}

#[test]
fn inactive_generic_items_are_not_refused() {
    let c = Concrete { x: -2.0 };
    assert_eq!(c.norm(), 2.0);
}
