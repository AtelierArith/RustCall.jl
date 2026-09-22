#[test]
fn ui_tests() {
    let t = trybuild::TestCases::new();
    t.compile_fail("tests/ui/non_ffi_result.rs");
    t.compile_fail("tests/ui/non_ffi_option.rs");
    // #462: generic `#[julia]` items are refused at the item, one diagnostic
    // each, not with an unbound `T` inside generated code.
    t.compile_fail("tests/ui/generic_fn.rs");
    t.compile_fail("tests/ui/generic_items.rs");
}
