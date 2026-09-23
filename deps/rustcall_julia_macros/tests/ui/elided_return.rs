use rustcall_julia_macros::julia;

pub struct Buf {
    pub n: i32,
}

static N: i32 = 3;

// #484: with no receiver, an elided return lifetime is the one lifetime of the
// arguments. When that is a `&str` argument's, the returned value borrows the
// string the wrapper rebuilds from a pointer and a length, which is gone when
// the wrapper returns: refused at the argument, not E0106 inside the wrapper.
#[julia]
impl Buf {
    #[julia]
    pub fn from_str(s: &str) -> &i32 {
        let _ = s;
        &N
    }

    // Named, the same borrow is refused by the rule of #482.
    #[julia]
    pub fn from_named<'a>(s: &'a str) -> &i32 {
        let _ = s;
        &N
    }

    // With a receiver the return borrows from `self`: accepted.
    #[julia]
    pub fn from_self(&self, s: &str) -> &i32 {
        let _ = s;
        &self.n
    }
}

#[julia]
pub fn free_from_str(s: &str) -> &i32 {
    let _ = s;
    &N
}

fn main() {}
