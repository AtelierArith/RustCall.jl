//! An elided lifetime in a wrapper's plain return (RustCall.jl #484): the
//! proc-macro flavour of `rustcall_julia_core/tests/elided_returns.rs`.
//!
//! The wrapper's receiver is a raw pointer and a lowered string a pointer and
//! a length, so elision on the wrapper finds no lifetime to give the return
//! (E0106 inside generated code). The lifetime Rust's elision rules pick on
//! the *item* is spelled out instead: the receiver's, or the one lifetime of a
//! passed-through argument. Every shape below compiles and is called through
//! its wrapper under the symbol the scheme gives it; the refused shape — the
//! only input lifetime is a lowered string's — is `tests/ui/elided_return.rs`.

#![allow(dead_code)]
#![allow(clippy::not_unsafe_ptr_arg_deref)]
#![allow(clippy::needless_lifetimes)]
#![allow(clippy::trivially_copy_pass_by_ref)]
#![allow(non_snake_case)]
// `named` and `free_named` elide a lifetime named elsewhere on purpose.
#![allow(unknown_lints, mismatched_lifetime_syntaxes)]

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

    // From the receiver: `&self`, `&mut self`, `'_`, a named receiver
    // lifetime, `Self`, inside an `Option`.
    #[julia]
    pub fn get(&self) -> &i32 {
        &self.n
    }

    #[julia]
    pub fn get_mut(&mut self) -> &mut i32 {
        &mut self.n
    }

    #[julia]
    pub fn anon(&self) -> &'_ i32 {
        &self.n
    }

    #[julia]
    pub fn named<'a>(&'a self) -> &i32 {
        &self.n
    }

    #[julia]
    pub fn me(&self) -> &Self {
        self
    }

    #[julia]
    pub fn maybe(&self, some: bool) -> Option<&i32> {
        some.then_some(&self.n)
    }

    // The receiver wins over any other input, a lowered string included.
    #[julia]
    pub fn with_str(&self, s: &str) -> &i32 {
        let _ = s;
        &self.n
    }

    #[julia]
    pub fn with_other(&self, o: &Buf) -> &i32 {
        let _ = o;
        &self.n
    }

    // No receiver: the one lifetime of a passed-through argument.
    #[julia]
    pub fn pick(o: &Buf) -> &i32 {
        &o.n
    }
}

#[julia]
pub fn free_pick(b: &Buf) -> &i32 {
    &b.n
}

#[julia]
pub fn free_named<'a>(b: &'a Buf, flag: bool) -> &i32 {
    let _ = flag;
    &b.n
}

static SEVEN: i32 = 7;

#[julia]
pub fn free_static(x: &'static i32, s: String) -> &i32 {
    let _ = s;
    x
}

static OTHER: Buf = Buf { n: 1 };

#[test]
fn every_elided_return_is_named_and_called_through_its_wrapper() {
    let o = Buf { n: 2 };
    let s = "four";
    let p = rustcall_Buf_new(5);
    unsafe {
        let n: *const i32 = &(*p).n;
        let got: &i32 = rustcall_Buf_get(p).assume_init();
        assert!(std::ptr::eq(got, n));
        assert_eq!(*got, 5);
        *rustcall_Buf_get_mut(p).assume_init() = 6;
        assert_eq!((*p).n, 6);
        assert!(std::ptr::eq(rustcall_Buf_anon(p).assume_init(), n));
        assert!(std::ptr::eq(rustcall_Buf_named(p).assume_init(), n));
        assert!(std::ptr::eq(rustcall_Buf_me(p).assume_init(), p));
        assert_eq!(rustcall_Buf_maybe(p, true).assume_init(), Some(&6));
        assert_eq!(rustcall_Buf_maybe(p, false).assume_init(), None);
        assert!(std::ptr::eq(
            rustcall_Buf_with_str(p, s.as_ptr(), s.len()).assume_init(),
            n
        ));
        assert!(std::ptr::eq(
            rustcall_Buf_with_other(p, &o).assume_init(),
            n
        ));
        assert!(std::ptr::eq(rustcall_Buf_pick(&o).assume_init(), &o.n));
        assert!(std::ptr::eq(
            rustcall_free_pick(&OTHER).assume_init(),
            &OTHER.n
        ));
        assert!(std::ptr::eq(
            rustcall_free_named(&o, true).assume_init(),
            &o.n
        ));
        assert!(std::ptr::eq(
            rustcall_free_static(&SEVEN, s.as_ptr(), s.len()).assume_init(),
            &SEVEN
        ));
    }
    Buf_free(p);
}
