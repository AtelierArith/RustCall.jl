//! A `#[julia]` method or function taking a struct reference with a named
//! lifetime (RustCall.jl #477): the wrapper passes `other: &'a Buf` through as
//! written, so it declares `'a` — with the bounds the item gives it — or it
//! would not compile. The proc macro shares this lowering with `rust"""`.

#![allow(dead_code)]
#![allow(clippy::not_unsafe_ptr_arg_deref)]
#![allow(clippy::needless_lifetimes)]
#![allow(non_snake_case)]

use rustcall_julia_macros::julia;

#[julia]
pub struct Buf {
    pub n: i32,
}

#[julia]
impl Buf {
    #[julia]
    pub fn new(n: i32) -> Self {
        Self { n }
    }

    #[julia]
    pub fn sum<'a>(&self, other: &'a Buf) -> i32 {
        self.n + other.n
    }

    #[julia]
    pub fn nested<'a, 'b: 'a>(&'a self, x: &'a Buf, y: &'b Buf) -> i32 {
        self.n + x.n - y.n
    }

    #[julia]
    pub fn bounded<'a, 'b>(&self, x: &'a Buf, y: &'b Buf) -> i32
    where
        'b: 'a,
    {
        x.n * y.n
    }
}

#[julia]
pub fn buf_total<'a>(a: &'a Buf, b: &'a Buf) -> i32 {
    a.n + b.n
}

#[test]
fn wrappers_with_named_lifetimes_compile_and_call_through() {
    let a = rustcall_Buf_new(2);
    let b = Buf { n: 5 };
    let c = Buf { n: 1 };
    unsafe {
        assert_eq!(rustcall_Buf_sum(a, &b).assume_init(), 7);
        assert_eq!(rustcall_Buf_nested(a, &b, &c).assume_init(), 6);
        assert_eq!(rustcall_Buf_bounded(a, &b, &c).assume_init(), 5);
        assert_eq!(rustcall_buf_total(&*a, &b).assume_init(), 7);
    }
    Buf_free(a);
}
