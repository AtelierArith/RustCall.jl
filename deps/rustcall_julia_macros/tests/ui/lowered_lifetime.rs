use rustcall_julia_macros::julia;

pub trait Any2<T> {}
impl<A: ?Sized, B> Any2<B> for A {}

macro_rules! same {
    ($t:ty) => {
        $t
    };
}

pub struct Buf {
    pub n: i32,
}

// #482: a `&str` argument arrives as a pointer and a length and is rebuilt
// into a string that lives only for the call. A method that needs its
// lifetime to outlive the call is refused at that lifetime, not with a
// borrow-checker error inside the generated wrapper.
#[julia]
impl Buf {
    #[julia]
    pub fn forever(&self, s: &'static str) -> i32 {
        s.len() as i32
    }

    #[julia]
    pub fn returned<'a>(&'a self, s: &'a str) -> &'a i32 {
        let _ = s;
        &self.n
    }

    #[julia]
    pub fn invariant<'a>(&self, o: &'a mut &'a Buf, s: &'a str) -> i32 {
        o.n + s.len() as i32
    }

    #[julia]
    pub fn through_a_bound<'a, 'c: 'a>(&self, o: &'a mut &'a Buf, s: &'c str) -> i32 {
        o.n + s.len() as i32
    }

    #[julia]
    pub fn predicated<'c>(&self, s: &'c str) -> i32
    where
        &'c str: Any2<i32>,
    {
        s.len() as i32
    }

    // A `Self` inside a macro invocation is not a type until the macro runs.
    #[julia]
    pub fn in_macro(&self) -> i32
    where
        same!(Self): Sized,
    {
        self.n
    }

    // A lifetime a lowered string may shrink is fine.
    #[julia]
    pub fn shrinks<'a, 'c>(&self, o: &'a Buf, s: &'c str) -> i32
    where
        'c: 'a,
    {
        o.n + s.len() as i32
    }
}

#[julia]
pub fn free_forever(s: &'static str) -> usize {
    s.len()
}

fn main() {}
