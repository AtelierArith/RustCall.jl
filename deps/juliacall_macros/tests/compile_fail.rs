#[test]
fn ui_tests() {
    let t = trybuild::TestCases::new();
    t.compile_fail("tests/ui/non_ffi_result.rs");
    t.compile_fail("tests/ui/non_ffi_option.rs");
}
