use rustcall_julia_macros::julia;
use std::pin::Pin;
use std::rc::Rc;

// PR #505 review: a trait method is called through the trait,
// `<Buf as tr::Tr>::m(..)`, which applies no receiver adjustment, so its first
// argument is built from the receiver's written shape. Only literal reference
// layers over exactly `Self` have a certain shape; every other typed receiver
// (an alias, a smart pointer) is refused at the receiver instead of generating
// a call that may not compile.
pub type Ref<'a, T> = &'a T;

#[julia]
pub struct Buf {
    pub n: i32,
}

pub mod tr {
    pub type Ref<'a, T> = &'a T;
    pub trait Tr {
        fn aliased(self: Ref<'_, Self>) -> i32;
        fn boxed(self: Box<Self>) -> i32;
        fn rc(self: std::rc::Rc<Self>) -> i32;
        fn pinned(self: std::pin::Pin<&mut Self>) -> i32;
        fn named(&self) -> i32;
        fn fine(self: &&Self) -> i32;
        fn typed_mut(&mut self) -> i32;
    }
}

#[julia]
impl tr::Tr for Buf {
    #[julia]
    fn aliased(self: Ref<'_, Self>) -> i32 {
        self.n
    }

    #[julia]
    fn boxed(self: Box<Self>) -> i32 {
        self.n
    }

    #[julia]
    fn rc(self: Rc<Self>) -> i32 {
        self.n
    }

    #[julia]
    fn pinned(self: Pin<&mut Self>) -> i32 {
        self.n
    }

    #[julia]
    fn named(self: &Buf) -> i32 {
        self.n
    }

    #[julia]
    fn fine(self: &&Self) -> i32 {
        self.n
    }

    #[julia]
    fn typed_mut(self: &mut Self) -> i32 {
        self.n
    }
}

fn main() {}
