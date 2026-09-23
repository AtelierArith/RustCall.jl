use rustcall_julia_macros::julia;

// #491: an `unsafe fn` method is refused at the method, not with E0133 in a
// generated wrapper that calls it from a safe `extern "C"` body.
#[julia]
pub struct Cell {
    pub v: i32,
}

#[julia]
impl Cell {
    #[julia]
    pub unsafe fn read(&self, p: *const i32) -> i32 {
        *p + self.v
    }

    #[julia]
    pub fn get(&self) -> i32 {
        self.v
    }
}

fn main() {
    let c = Cell { v: 1 };
    let _ = c.get();
    let _ = unsafe { c.read(&2) };
}
