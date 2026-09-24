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
#![allow(clippy::needless_arbitrary_self_type)]
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

// Every receiver form a wrapper accepts, through a path-named trait and beside
// an inherent namesake (PR #505 review). A path call applies no autoref, so the
// receiver argument follows the declared type: `self: &&Self` is passed
// `&self_obj`, where method-call syntax borrowed once more on its own.
#[julia]
#[derive(Clone, Copy)]
pub struct Pt {
    pub n: i32,
}

#[julia]
impl Pt {
    #[julia]
    pub fn new(n: i32) -> Self {
        Self { n }
    }
}

impl Pt {
    pub fn by_ref(&self) -> i32 {
        -1
    }
    pub fn by_mut(&mut self) -> i32 {
        -1
    }
    pub fn typed_ref(&self) -> i32 {
        -1
    }
    pub fn ref_ref(&self) -> i32 {
        -1
    }
    pub fn ref_ref_ref(&self) -> i32 {
        -1
    }
    pub fn by_value(self) -> i32 {
        -1
    }
    pub fn mut_value(self) -> i32 {
        -1
    }
}

pub mod recv {
    pub trait Forms {
        fn by_ref(&self) -> i32;
        fn by_mut(&mut self) -> i32;
        fn typed_ref(self: &Self) -> i32;
        fn ref_ref(self: &&Self) -> i32;
        fn ref_ref_ref(self: &&&Self) -> i32;
        fn by_value(self) -> i32;
        fn mut_value(self) -> i32;
    }
}

#[julia]
impl recv::Forms for Pt {
    #[julia]
    fn by_ref(&self) -> i32 {
        self.n + 1
    }
    #[julia]
    fn by_mut(&mut self) -> i32 {
        self.n += 10;
        self.n
    }
    #[julia]
    fn typed_ref(self: &Self) -> i32 {
        self.n + 2
    }
    #[julia]
    fn ref_ref(self: &&Self) -> i32 {
        self.n + 3
    }
    #[julia]
    fn ref_ref_ref(self: &&&Self) -> i32 {
        self.n + 4
    }
    #[julia]
    fn by_value(self) -> i32 {
        self.n + 5
    }
    #[julia]
    fn mut_value(mut self) -> i32 {
        self.n += 6;
        self.n
    }
}

#[test]
fn every_receiver_form_reaches_the_trait_method() {
    let p = rustcall_Pt_new(0);
    unsafe {
        assert_eq!(rustcall_Pt_5Forms_by_ref(p).assume_init(), 1);
        assert_eq!(rustcall_Pt_5Forms_by_mut(p).assume_init(), 10);
        assert_eq!(rustcall_Pt_5Forms_typed_ref(p).assume_init(), 12);
        assert_eq!(rustcall_Pt_5Forms_ref_ref(p).assume_init(), 13);
        assert_eq!(rustcall_Pt_5Forms_ref_ref_ref(p).assume_init(), 14);
        assert_eq!(rustcall_Pt_5Forms_by_value(p).assume_init(), 15);
        assert_eq!(rustcall_Pt_5Forms_mut_value(p).assume_init(), 16);
        // By value is a copy: the object behind the pointer is unchanged.
        assert_eq!((*p).n, 10);
        Pt_free(p);
    }
}

#[test]
fn trait_impl_wrappers_reach_the_trait_method() {
    // The exported symbols are the ones the scheme gives the methods: the
    // calls below name them. A trait method's carries its trait (`3Far_`),
    // so the inherent `m` beside it exports its own (#506).
    let p = rustcall_Buf_new(3);
    unsafe {
        assert_eq!(rustcall_Buf_3Far_m(p).assume_init(), 30);
        assert_eq!(rustcall_Buf_3Far_bump(p, 4).assume_init(), 7);
        assert_eq!((*p).n, 7);
        assert_eq!(rustcall_Buf_3Far_make().assume_init(), 42);
        assert_eq!(ops::rustcall_Buf_4Near_only_near(p).assume_init(), 14);

        let built = rustcall_Buf_3Far_build(1);
        assert_eq!((*built).n, 101);
        Buf_free(built);

        let s = rustcall_Buf_3Far_label(p);
        let text = std::str::from_utf8(std::slice::from_raw_parts(s.ptr, s.len)).unwrap();
        assert_eq!(text, "far 7");
        Buf_3Far_label_free_rust_string(s.ptr, s.len, s.cap);

        Buf_free(p);
    }
}
