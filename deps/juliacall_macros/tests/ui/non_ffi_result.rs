use juliacall_macros::julia;

// Issue #159: Non-FFI-compatible types in Result should produce compile_error
#[julia]
fn bad_result(a: i32) -> Result<String, i32> {
    if a > 0 { Ok("yes".to_string()) } else { Err(-1) }
}

fn main() {}
