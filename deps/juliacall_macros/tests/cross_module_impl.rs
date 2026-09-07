//! A `#[julia] impl` block in another module than its struct (RustCall.jl
//! #315): the method symbols follow the struct the header names —
//! `rustcall_Gauge_read` for `impl super::Gauge` inside `#[julia] mod ops` —
//! and the wrapper spells the struct the way the header does, so nothing needs
//! to be in scope next to the block.

#![allow(dead_code)]
#![allow(clippy::not_unsafe_ptr_arg_deref)]
#![allow(non_snake_case)]

use juliacall_macros::julia;

#[julia]
pub struct Gauge {
    pub value: i32,
}

#[julia]
impl Gauge {
    #[julia]
    pub fn new(value: i32) -> Self {
        Self { value }
    }
}

// A marked child module: `super::Gauge` is the root struct.
#[julia]
pub mod ops {
    #[julia]
    impl super::Gauge {
        #[julia]
        pub fn read(&self) -> i32 {
            self.value
        }

        #[julia]
        pub fn bump(&mut self) {
            self.value += 1;
        }
    }
}

// Through `crate::`, with a static constructor and a `String` return whose
// buffer hangs off the struct's FFI name.
#[julia]
pub mod more {
    #[julia]
    impl crate::Gauge {
        #[julia]
        pub fn scaled(value: i32, factor: i32) -> Self {
            Self {
                value: value * factor,
            }
        }

        #[julia]
        pub fn label(&self) -> String {
            format!("Gauge({})", self.value)
        }
    }
}

// An unmarked module: item-level expansion, a bare name brought in by `use`.
pub mod plain {
    use super::Gauge;
    use juliacall_macros::julia;

    #[julia]
    impl Gauge {
        #[julia]
        pub fn halved(&self) -> Result<i32, String> {
            if self.value % 2 == 0 {
                Ok(self.value / 2)
            } else {
                Err(format!("{} is odd", self.value))
            }
        }
    }
}

// A struct in a marked module, its block in a sibling marked module.
#[julia]
pub mod a {
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
    }
}

#[julia]
pub mod b {
    #[julia]
    impl crate::a::C {
        #[julia]
        pub fn get(&self) -> i32 {
            self.v
        }
    }
}

#[test]
fn the_rust_items_are_untouched() {
    let mut g = Gauge::new(4);
    assert_eq!(g.read(), 4);
    g.bump();
    assert_eq!(g.label(), "Gauge(5)");
    assert_eq!(Gauge::scaled(2, 3).read(), 6);
    assert_eq!(a::C::new(7).get(), 7);
}

#[test]
fn method_symbols_follow_the_struct_not_the_block() {
    let p = rustcall_Gauge_new(4);
    assert_eq!(ops::rustcall_Gauge_read(p), 4);
    ops::rustcall_Gauge_bump(p);
    assert_eq!(ops::rustcall_Gauge_read(p), 5);

    let out = more::rustcall_Gauge_label(p);
    let bytes = unsafe { std::slice::from_raw_parts(out.ptr, out.len) };
    assert_eq!(std::str::from_utf8(bytes).unwrap(), "Gauge(5)");
    more::Gauge_label_free_rust_string(out.ptr, out.len, out.cap);

    let q = more::rustcall_Gauge_scaled(2, 3);
    assert_eq!(ops::rustcall_Gauge_read(q), 6);
    assert_eq!(Gauge_get_value(q), 6);

    // The `Result` lowering is the free-function one (#268); its aggregate is
    // read by Julia, so only that the wrapper exists and runs is checked here.
    let _lowered = plain::rustcall_Gauge_halved(q);

    Gauge_free(p);
    Gauge_free(q);

    let c = a::rustcall_a__C_new(7);
    assert_eq!(b::rustcall_a__C_get(c), 7);
    a::a__C_free(c);
}
