//! `#[julia]` on an inline module folds the module path into every generated
//! symbol (RustCall.jl #300), so two `run`s or two `struct C` in different
//! modules of one crate coexist in one `cdylib`.

#![allow(dead_code)]
#![allow(clippy::not_unsafe_ptr_arg_deref)]
#![allow(non_snake_case)]

use rustcall_julia_macros::julia;

#[julia]
pub mod a {
    #[julia]
    pub fn run() -> i32 {
        1
    }

    #[julia]
    pub struct C {
        pub v: i32,
    }

    #[julia]
    impl C {
        #[julia]
        pub fn new(v: i32) -> Self {
            Self { v }
        }

        #[julia]
        pub fn get(&self) -> i32 {
            self.v
        }

        #[julia]
        pub fn describe(&self) -> String {
            format!("a::C({})", self.v)
        }
    }

    // A nested marked module accumulates the path; underscores in names are
    // escaped so `a::deep_er::run` cannot collide with anything else.
    #[julia]
    pub mod deep_er {
        #[julia]
        pub fn run() -> i32 {
            3
        }
    }

    // An item without `#[julia]` is left exactly as written.
    pub fn helper() -> i32 {
        run() + 10
    }

    // A gated struct and impl: the module macro expands them before rustc
    // evaluates the predicate, so their generated helpers must be gated too
    // or the crate would not compile with the gate off.
    #[cfg(any())]
    #[julia]
    pub struct Gated {
        pub v: i32,
        pub label: String,
    }

    #[cfg(any())]
    #[julia]
    impl Gated {
        #[julia]
        pub fn new(v: i32) -> Self {
            Self {
                v,
                label: String::new(),
            }
        }

        #[julia]
        pub fn describe(&self) -> String {
            self.label.clone()
        }
    }
}

#[julia]
pub mod b {
    #[julia]
    pub fn run() -> i32 {
        2
    }

    #[julia]
    pub struct C {
        pub v: i32,
    }

    #[julia]
    impl C {
        #[julia]
        pub fn new(v: i32) -> Self {
            Self { v: v * 2 }
        }

        #[julia]
        pub fn get(&self) -> i32 {
            self.v
        }
    }
}

// The crate root keeps the bare symbol.
#[julia]
pub fn run() -> i32 {
    0
}

#[test]
fn the_rust_items_are_untouched() {
    assert_eq!(a::run(), 1);
    assert_eq!(b::run(), 2);
    assert_eq!(run(), 0);
    assert_eq!(a::helper(), 11);
    assert_eq!(a::deep_er::run(), 3);
    assert_eq!(a::C::new(4).get(), 4);
    assert_eq!(b::C::new(4).get(), 8);
}

#[test]
fn free_functions_are_qualified_by_their_module() {
    assert_eq!(rustcall_run(), 0);
    assert_eq!(a::rustcall_a__run(), 1);
    assert_eq!(b::rustcall_b__run(), 2);
    assert_eq!(a::deep_er::rustcall_a__deep_0er__run(), 3);
}

#[test]
fn struct_symbols_are_qualified_by_their_module() {
    let pa = a::rustcall_a__C_new(4);
    let pb = b::rustcall_b__C_new(4);
    assert_eq!(a::rustcall_a__C_get(pa), 4);
    assert_eq!(b::rustcall_b__C_get(pb), 8);
    assert_eq!(a::a__C_get_v(pa), 4);
    a::a__C_set_v(pa, 7);
    assert_eq!(a::a__C_get_v(pa), 7);
    assert_eq!(b::b__C_get_v(pb), 8);

    // The per-method string buffer hangs off the qualified owner too.
    let out = a::rustcall_a__C_describe(pa);
    let bytes = unsafe { std::slice::from_raw_parts(out.ptr, out.len) };
    assert_eq!(std::str::from_utf8(bytes).unwrap(), "a::C(7)");
    a::a__C_describe_free_rust_string(out.ptr, out.len, out.cap);

    a::a__C_free(pa);
    b::b__C_free(pb);
}
