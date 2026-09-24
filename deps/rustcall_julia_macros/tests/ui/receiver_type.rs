use rustcall_julia_macros::julia;
use std::pin::Pin;
use std::rc::Rc;

// RustCall.jl #509: a method is called by path, `<Buf>::m(..)` or
// `<Buf as tr::Tr>::m(..)`, which applies no receiver adjustment, so its first
// argument is built from the receiver's written shape. Only literal reference
// layers over `Self` or the header's own spelling of the type have a certain
// shape; every other typed receiver (an alias, a smart pointer) is refused at
// the receiver, for an inherent method and a trait impl's alike, instead of
// generating a call that may not compile.
pub type Ref<'a, T> = &'a T;

#[julia]
pub struct Buf {
    pub n: i32,
}

#[julia]
impl Buf {
    #[julia]
    pub fn aliased(self: Ref<'_, Self>) -> i32 {
        self.n
    }

    #[julia]
    pub fn boxed(self: Box<Self>) -> i32 {
        self.n
    }

    // Accepted: the header's own spelling and literal layers over `Self`.
    #[julia]
    pub fn named(self: &Buf) -> i32 {
        self.n
    }

    #[julia]
    pub fn typed_mut(self: &mut Self) -> i32 {
        self.n
    }
}

pub mod tr {
    pub type Ref<'a, T> = &'a T;
    pub trait Tr {
        fn t_aliased(self: Ref<'_, Self>) -> i32;
        fn t_rc(self: std::rc::Rc<Self>) -> i32;
        fn t_pinned(self: std::pin::Pin<&mut Self>) -> i32;
        fn t_named(&self) -> i32;
        fn t_fine(self: &&Self) -> i32;
        fn t_typed_mut(&mut self) -> i32;
    }
}

#[julia]
impl tr::Tr for Buf {
    #[julia]
    fn t_aliased(self: Ref<'_, Self>) -> i32 {
        self.n
    }

    #[julia]
    fn t_rc(self: Rc<Self>) -> i32 {
        self.n
    }

    #[julia]
    fn t_pinned(self: Pin<&mut Self>) -> i32 {
        self.n
    }

    #[julia]
    fn t_named(self: &Buf) -> i32 {
        self.n
    }

    #[julia]
    fn t_fine(self: &&Self) -> i32 {
        self.n
    }

    #[julia]
    fn t_typed_mut(self: &mut Self) -> i32 {
        self.n
    }
}

fn main() {}
