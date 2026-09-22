use rustcall_julia_macros::julia;

// #462: a generic struct, a generic impl block and a generic method have no
// concrete type an `extern "C"` wrapper could name.
#[julia]
pub struct Wrapper<T> {
    pub value: T,
}

#[julia]
pub struct Point {
    pub x: f64,
}

#[julia]
impl<T: Copy> Wrapper<T> {
    #[julia]
    pub fn get(&self) -> T {
        self.value
    }
}

#[julia]
impl Point {
    #[julia]
    pub fn scaled<U: Into<f64>>(&self, by: U) -> f64 {
        self.x * by.into()
    }

    #[julia]
    pub fn norm(&self) -> f64 {
        self.x.abs()
    }
}

// The refusal carries the item's `#[cfg]` (PR #470 review), so where that
// predicate holds it still fires — here inside a `#[julia] mod`, where the
// module macro expands the item before rustc evaluates it.
#[julia]
pub mod nested {
    #[cfg(all())]
    #[julia]
    pub fn active<T: Copy>(x: T) -> T {
        x
    }
}

fn main() {
    let _ = nested::active(1);
    let w = Wrapper { value: 1 };
    let _ = w.get();
    let p = Point { x: 1.0 };
    let _ = p.scaled(2.0f32);
    let _ = p.norm();
}
