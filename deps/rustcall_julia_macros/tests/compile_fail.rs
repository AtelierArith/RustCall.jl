#[test]
fn ui_tests() {
    let t = trybuild::TestCases::new();
    t.compile_fail("tests/ui/non_ffi_result.rs");
    t.compile_fail("tests/ui/non_ffi_option.rs");
    // #462: generic `#[julia]` items are refused at the item, one diagnostic
    // each, not with an unbound `T` inside generated code.
    t.compile_fail("tests/ui/generic_fn.rs");
    t.compile_fail("tests/ui/generic_items.rs");
    // #482: a lowered string whose lifetime must outlive the call, and a
    // `Self` the wrapper cannot spell, are refused at the method.
    t.compile_fail("tests/ui/lowered_lifetime.rs");
    // #484: an elided return lifetime that would borrow a lowered string is
    // refused at that argument, not with E0106 inside the wrapper.
    t.compile_fail("tests/ui/elided_return.rs");
    // #491: an `unsafe fn` method is refused at the method.
    t.compile_fail("tests/ui/unsafe_method.rs");
    // PR #505 review: a trait method's typed receiver whose shape is not
    // literal reference layers over `Self` is refused at the receiver.
    t.compile_fail("tests/ui/trait_receiver.rs");
}
