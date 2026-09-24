//! Typed receivers through the real `#[julia]` attribute (RustCall.jl #509).
//!
//! One receiver model decides the wrapper's pointer, its `self_obj` binding
//! and the first argument of its path call, for an inherent method and a
//! trait impl's alike. `self: &mut Self` used to be bound as `&Buf` (only the
//! `&mut self` shorthand was read as mutable), so the wrapper did not compile;
//! it now takes `*mut Buf` and the mutation is observed through the symbol.

#![allow(dead_code)]
#![allow(clippy::not_unsafe_ptr_arg_deref)]
#![allow(clippy::needless_arbitrary_self_type)]
#![allow(clippy::mut_mut)]
#![allow(non_snake_case)]

use rustcall_julia_macros::julia;

#[julia]
pub struct Buf {
    pub n: i32,
}

#[julia]
impl Buf {
    #[julia]
    pub fn typed_mut(self: &mut Self, by: i32) -> i32 {
        self.n += by;
        self.n
    }

    #[julia]
    pub fn own_mut(self: &mut Buf, by: i32) -> i32 {
        self.n += by;
        self.n
    }

    #[julia]
    pub fn own_ref(self: &Buf) -> i32 {
        self.n
    }

    #[julia]
    pub fn mut_mut(self: &mut &mut Self, by: i32) -> i32 {
        self.n += by;
        self.n
    }

    #[julia]
    pub fn shared_over_mut(self: &&mut Self) -> i32 {
        self.n
    }
}

pub mod tr {
    pub trait Grow {
        fn grow(self: &mut Self, by: i32) -> i32;
        fn peek(self: &Self) -> i32;
    }
}

#[julia]
impl tr::Grow for Buf {
    #[julia]
    fn grow(self: &mut Self, by: i32) -> i32 {
        self.n += by * 100;
        self.n
    }

    #[julia]
    fn peek(self: &Buf) -> i32 {
        self.n
    }
}

#[test]
fn a_typed_mutable_receiver_mutates_through_its_symbol() {
    let mut b = Buf { n: 1 };
    unsafe {
        // The wrappers take `*mut Buf` exactly where the receiver's innermost
        // borrow is `&mut`, and `*const Buf` otherwise.
        let typed_mut: extern "C" fn(*mut Buf, i32) -> std::mem::MaybeUninit<i32> =
            rustcall_Buf_typed_mut;
        let own_ref: extern "C" fn(*const Buf) -> std::mem::MaybeUninit<i32> = rustcall_Buf_own_ref;
        let shared_over_mut: extern "C" fn(*mut Buf) -> std::mem::MaybeUninit<i32> =
            rustcall_Buf_shared_over_mut;

        assert_eq!(typed_mut(&mut b, 2).assume_init(), 3);
        assert_eq!(b.n, 3);
        assert_eq!(rustcall_Buf_own_mut(&mut b, 4).assume_init(), 7);
        assert_eq!(b.n, 7);
        assert_eq!(own_ref(&b).assume_init(), 7);
        assert_eq!(rustcall_Buf_mut_mut(&mut b, 1).assume_init(), 8);
        assert_eq!(b.n, 8);
        assert_eq!(shared_over_mut(&mut b).assume_init(), 8);

        // The trait impl's, called through the trait.
        assert_eq!(rustcall_Buf_4Grow_grow(&mut b, 1).assume_init(), 108);
        assert_eq!(b.n, 108);
        assert_eq!(rustcall_Buf_4Grow_peek(&b).assume_init(), 108);
    }
}
