use rustcall_julia_macros::julia;

// #462: an `extern "C"` entry point needs concrete types; the wrapper of a
// generic `#[julia]` item used to name an unbound `T`.
#[julia]
pub fn identity<T: Copy>(x: T) -> T {
    x
}

#[julia]
pub fn sized<const N: usize>(x: [u8; N]) -> usize {
    x.len()
}

#[julia]
pub fn shown(x: impl std::fmt::Display) -> usize {
    x.to_string().len()
}

// A lifetime parameter is fine: the wrapper names none.
#[julia]
pub fn echo<'a>(s: &'a str) -> &'a str {
    s
}

fn main() {
    let _ = identity(1);
    let _ = sized([0u8; 2]);
    let _ = shown(1);
    let _ = echo("x");
}
