use juliacall_macros::julia;

// Issue #159: Non-FFI-compatible types in Result should produce compile_error.
// `String` / `&str` were in that set until #268, which lowers them to the
// owned-string buffer the wrapper already uses for a `String` return; a `Vec`
// still has no representation the aggregate can carry.
#[julia]
fn bad_result(a: i32) -> Result<Vec<i32>, i32> {
    if a > 0 { Ok(vec![a]) } else { Err(-1) }
}

fn main() {}
