//! A `#[julia]` method of a trait impl is called through its fully qualified
//! path, `<Buf as tr::Far>::m(self_obj, ..)` (RustCall.jl #497).
//!
//! Method-call syntax (`self_obj.m()`) needs the trait in scope where the
//! wrapper is emitted — E0599 inside generated code when the header names the
//! trait by a path — and reaches an inherent method of the same name before
//! the trait's, silently. Every wrapper below sits beside an inherent method of
//! its name (or a trait not in scope under a bare name), is called through its
//! exported symbol, and must reach the trait method.

#![allow(dead_code)]
#![allow(clippy::not_unsafe_ptr_arg_deref)]
#![allow(clippy::new_ret_no_self)]
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
}

// Inherent methods of the trait methods' names, not wrapped: a wrapper that
// reaches one of these returns a negative number.
impl Buf {
    pub fn m(&self) -> i32 {
        -1
    }

    pub fn bump(&mut self, _by: i32) -> i32 {
        -1
    }

    pub fn make() -> i32 {
        -1
    }

    pub fn build(_n: i32) -> Self {
        Buf { n: -1 }
    }

    pub fn label(&self) -> String {
        "inherent".to_string()
    }
}

pub mod tr {
    pub trait Far {
        fn m(&self) -> i32;
        fn bump(&mut self, by: i32) -> i32;
        fn make() -> i32;
        fn build(n: i32) -> Self;
        fn label(&self) -> String;
    }

    pub trait Near {
        fn only_near(&self) -> i32;
    }
}

// The trait is named by a path and is not in scope under a bare name.
#[julia]
impl tr::Far for Buf {
    #[julia]
    fn m(&self) -> i32 {
        self.n * 10
    }

    #[julia]
    fn bump(&mut self, by: i32) -> i32 {
        self.n += by;
        self.n
    }

    #[julia]
    fn make() -> i32 {
        42
    }

    #[julia]
    fn build(n: i32) -> Self {
        Buf { n: n + 100 }
    }

    #[julia]
    fn label(&self) -> String {
        format!("far {}", self.n)
    }
}

// A block in another module: the header's paths are relative to *that*
// module, and so is the wrapper emitted beside it. `only_near` has no inherent
// namesake, so method-call syntax failed to compile here (E0599).
pub mod ops {
    use rustcall_julia_macros::julia;

    #[julia]
    impl super::tr::Near for super::Buf {
        #[julia]
        fn only_near(&self) -> i32 {
            self.n + 7
        }
    }
}

#[test]
fn trait_impl_wrappers_reach_the_trait_method() {
    // The exported symbols are the ones the scheme gives the methods: the
    // calls below name them (#497: "exported symbol names unchanged").
    let p = rustcall_Buf_new(3);
    unsafe {
        assert_eq!(rustcall_Buf_m(p).assume_init(), 30);
        assert_eq!(rustcall_Buf_bump(p, 4).assume_init(), 7);
        assert_eq!((*p).n, 7);
        assert_eq!(rustcall_Buf_make().assume_init(), 42);
        assert_eq!(ops::rustcall_Buf_only_near(p).assume_init(), 14);

        let built = rustcall_Buf_build(1);
        assert_eq!((*built).n, 101);
        Buf_free(built);

        let s = rustcall_Buf_label(p);
        let text = std::str::from_utf8(std::slice::from_raw_parts(s.ptr, s.len)).unwrap();
        assert_eq!(text, "far 7");
        Buf_label_free_rust_string(s.ptr, s.len, s.cap);

        Buf_free(p);
    }
}
