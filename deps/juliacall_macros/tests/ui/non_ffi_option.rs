use juliacall_macros::julia;

// Issue #159: Non-FFI-compatible types in Option should produce compile_error
#[julia]
fn bad_option(a: i32) -> Option<Vec<i32>> {
    if a > 0 { Some(vec![a]) } else { None }
}

fn main() {}
