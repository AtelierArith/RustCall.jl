//! A method's `where` predicates on its `#[julia]` wrapper (RustCall.jl #482):
//! the proc-macro flavour of `rustcall_julia_core/tests/predicate_transfer.rs`.
//!
//! The wrapper declares the item's whole environment — the impl block's
//! lifetime parameters and `where` clause, then the method's — with `Self`
//! spelled as the impl header's type. Every shape compiles and is called
//! through its wrapper under the symbol the scheme gives it; the refused
//! shapes are `tests/ui/lowered_lifetime.rs`.

#![allow(dead_code)]
#![allow(clippy::not_unsafe_ptr_arg_deref)]
#![allow(clippy::needless_lifetimes)]
#![allow(clippy::extra_unused_lifetimes)]
#![allow(clippy::trivially_copy_pass_by_ref)]
#![allow(non_snake_case)]
#![allow(unexpected_cfgs)]

use rustcall_julia_macros::julia;

pub trait Tagged {
    type Tag;
    fn tag() -> i32;
}

impl Tagged for Buf {
    type Tag = i32;
    fn tag() -> i32 {
        3
    }
}

pub trait Rel<T> {
    type Out;
    fn rel(&self, other: T) -> i32;
}

// Only for a `'static` argument: a predicate naming it is the only proof a
// call with a shorter `'a` is valid (PR #480 review).
impl<'x> Rel<&'static Buf> for &'x Buf {
    type Out = i32;
    fn rel(&self, other: &'static Buf) -> i32 {
        self.n - other.n
    }
}

pub trait Any2<T> {}
impl<A: ?Sized, B> Any2<B> for A {}

pub trait Counted {
    const M: usize;
}

impl Counted for Buf {
    const M: usize = 3;
}

pub struct Holder<const K: usize>;

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

    // Lifetime-only predicates.
    #[julia]
    pub fn outlives<'a, 'b: 'a>(&self, x: &'a Buf, y: &'b Buf) -> i32 {
        x.n + y.n
    }

    #[julia]
    pub fn outlives_where<'a, 'b>(&self, x: &'a Buf, y: &'b Buf) -> i32
    where
        'b: 'a,
    {
        x.n - y.n
    }

    // Higher-ranked: on the predicate, nested in a bound, a fn pointer, a
    // trait object.
    #[julia]
    pub fn hrtb<'a>(&self, o: &'a Buf) -> i32
    where
        for<'b> &'b Buf: Rel<&'a Buf>,
    {
        let _ = o;
        self.n
    }

    #[julia]
    pub fn hrtb_nested<'a>(&self, o: &'a Buf) -> i32
    where
        &'a Buf: for<'b> Any2<&'b Buf>,
    {
        o.n
    }

    #[julia]
    pub fn hrtb_fn_ptr<'a>(&self, o: &'a Buf) -> i32
    where
        for<'b> fn(&'b Buf) -> &'a Buf: Copy,
    {
        o.n
    }

    #[julia]
    pub fn hrtb_dyn<'a>(&self, o: &'a Buf) -> i32
    where
        &'a (dyn for<'b> Fn(&'b Buf) -> i32 + 'a): Copy,
    {
        o.n
    }

    // `Self`.
    #[julia]
    pub fn self_bound(&self) -> i32
    where
        Self: Tagged,
    {
        <Self as Tagged>::tag() + self.n
    }

    #[julia]
    pub fn self_assoc<'a>(&self, o: &'a Buf) -> i32
    where
        Self: Tagged,
        <Self as Tagged>::Tag: Copy + 'a,
    {
        o.n + self.n
    }

    #[julia]
    pub fn self_proof<'a>(&self, o: &'a Buf) -> i32
    where
        for<'b> &'b Self: Rel<&'a Buf>,
        for<'b> <&'b Self as Rel<&'a Buf>>::Out: Copy,
    {
        self.rel(o)
    }

    #[julia]
    pub fn self_arg<'a>(&self, o: &'a Self) -> i32
    where
        Self: Tagged,
    {
        o.n * self.n
    }

    // `Self` in expression position: an associated const in an array length,
    // qualified through a trait, and as a const generic argument (PR #483
    // review).
    pub const N: usize = 2;

    #[julia]
    pub fn self_const(&self) -> i32
    where
        [(); Self::N]: Sized,
    {
        self.n + Self::N as i32
    }

    #[julia]
    pub fn self_trait_const(&self) -> i32
    where
        [(); <Self as Counted>::M]: Sized,
    {
        self.n + <Self as Counted>::M as i32
    }

    #[julia]
    pub fn self_const_arg(&self) -> i32
    where
        Holder<{ Self::N }>: Sized,
    {
        self.n * Self::N as i32
    }

    // No lifetimes.
    #[julia]
    pub fn no_lifetimes(&self) -> i32
    where
        Buf: Tagged,
        i32: Copy,
    {
        self.n
    }

    // Declared and undeclared lifetimes mixed.
    #[julia]
    pub fn mixed<'a, 'c>(&self, o: &'a Buf) -> i32
    where
        &'c Buf: Any2<&'a Buf>,
    {
        o.n
    }

    #[julia]
    pub fn mixed_string<'a, 'c>(&self, o: &'a Buf, s: &'c str) -> i32
    where
        'c: 'a,
    {
        o.n + s.len() as i32
    }

    // Gated away: the predicate names a trait that does not exist, and a
    // gated refusal does not fire.
    #[cfg(rustcall_never)]
    #[julia]
    pub fn gated<'a>(&self, o: &'a Buf) -> i32
    where
        Self: Missing,
    {
        o.n
    }

    #[cfg(rustcall_never)]
    #[julia]
    pub fn gated_refusal(&self, s: &'static str) -> i32 {
        s.len() as i32
    }
}

// The block's own lifetime parameter and `where` clause.
#[julia]
impl<'x> Buf {
    #[julia]
    pub fn block_lifetime(&self, o: &'x Buf) -> i32 {
        o.n + 100
    }
}

#[julia]
impl Buf
where
    Buf: Tagged,
{
    #[julia]
    pub fn block_where(&self) -> i32 {
        self.n + 200
    }
}

// A trait impl: `Self::Unit` names the trait's item.
pub trait Scaled {
    type Unit;
    fn scaled(&self, by: i32) -> Self::Unit;
}

#[julia]
impl Scaled for Buf {
    type Unit = i32;

    #[julia]
    fn scaled(&self, by: i32) -> Self::Unit {
        self.n * by
    }
}

// A trait impl whose trait is in scope by its bare name: an unqualified
// `Self::N` in expression position resolves as rustc resolves it in the impl,
// inherent constant first (`Buf::N == 2`, not the trait's 5), then the traits
// in scope (`K`, which only the trait has). PR #492 review.
pub trait Limits {
    const N: usize;
    const K: usize;
    fn limit(&self, a: &[u8; 2]) -> i32;
    fn only(&self, a: &[u8; 7]) -> i32;
}

#[julia]
impl Limits for Buf {
    const N: usize = 5;
    const K: usize = 7;

    #[julia]
    fn limit(&self, a: &[u8; Self::N]) -> i32 {
        a.len() as i32 + self.n
    }

    #[julia]
    fn only(&self, a: &[u8; Self::K]) -> i32 {
        a.len() as i32 + self.n
    }
}

// A block in another module, spelling the struct `super::Buf`.
pub mod ops {
    use super::{Rel, Tagged};
    use rustcall_julia_macros::julia;

    #[julia]
    impl super::Buf {
        #[julia]
        pub fn foreign<'a>(&self, o: &'a super::Buf) -> i32
        where
            Self: Tagged,
            for<'b> &'b Self: Rel<&'a super::Buf>,
        {
            self.rel(o) + <Self as Tagged>::tag()
        }
    }

    #[julia]
    impl<'x> super::Buf {
        #[julia]
        pub fn foreign_block_lifetime(&self, o: &'x Self) -> i32 {
            o.n - self.n
        }
    }
}

#[julia]
pub fn free_where<'a, 'b>(x: &'a Buf, y: &'b Buf) -> i32
where
    'b: 'a,
{
    x.n * y.n
}

#[julia]
pub fn free_hrtb<'a>(x: &'a Buf) -> i32
where
    for<'b> &'b Buf: Rel<&'a Buf>,
{
    x.n
}

static OTHER: Buf = Buf { n: 1 };

/// Every wrapper is called under the symbol the scheme gives it
/// (`rustcall_<Struct>_<method>`, `rustcall_<fn>`): `#[no_mangle]` exports
/// each under its Rust name.
#[test]
fn every_predicate_shape_is_called_through_its_wrapper() {
    let o = Buf { n: 2 };
    let s = "four";
    let p = rustcall_Buf_new(5);
    unsafe {
        assert_eq!(rustcall_Buf_outlives(p, &o, &OTHER).assume_init(), 3);
        assert_eq!(rustcall_Buf_outlives_where(p, &o, &OTHER).assume_init(), 1);
        assert_eq!(rustcall_Buf_hrtb(p, &OTHER).assume_init(), 5);
        assert_eq!(rustcall_Buf_hrtb_nested(p, &o).assume_init(), 2);
        assert_eq!(rustcall_Buf_hrtb_fn_ptr(p, &o).assume_init(), 2);
        assert_eq!(rustcall_Buf_hrtb_dyn(p, &o).assume_init(), 2);
        assert_eq!(rustcall_Buf_self_bound(p).assume_init(), 8);
        assert_eq!(rustcall_Buf_self_assoc(p, &o).assume_init(), 7);
        assert_eq!(rustcall_Buf_self_proof(p, &OTHER).assume_init(), 4);
        assert_eq!(rustcall_Buf_self_arg(p, &o).assume_init(), 10);
        assert_eq!(rustcall_Buf_self_const(p).assume_init(), 7);
        assert_eq!(rustcall_Buf_self_trait_const(p).assume_init(), 8);
        assert_eq!(rustcall_Buf_self_const_arg(p).assume_init(), 10);
        assert_eq!(rustcall_Buf_no_lifetimes(p).assume_init(), 5);
        assert_eq!(rustcall_Buf_mixed(p, &o).assume_init(), 2);
        assert_eq!(
            rustcall_Buf_mixed_string(p, &o, s.as_ptr(), s.len()).assume_init(),
            6
        );
        assert_eq!(rustcall_Buf_block_lifetime(p, &o).assume_init(), 102);
        assert_eq!(rustcall_Buf_block_where(p).assume_init(), 205);
        assert_eq!(rustcall_Buf_6Scaled_scaled(p, 3).assume_init(), 15);
        // The inherent `N` (2), as in the impl.
        assert_eq!(rustcall_Buf_6Limits_limit(p, &[0u8; 2]).assume_init(), 7);
        assert_eq!(rustcall_Buf_6Limits_only(p, &[0u8; 7]).assume_init(), 12);
        assert_eq!(ops::rustcall_Buf_foreign(p, &OTHER).assume_init(), 7);
        assert_eq!(
            ops::rustcall_Buf_foreign_block_lifetime(p, &o).assume_init(),
            -3
        );
        assert_eq!(rustcall_free_where(&o, &OTHER).assume_init(), 2);
        assert_eq!(rustcall_free_hrtb(&OTHER).assume_init(), 1);
    }
    Buf_free(p);
}
