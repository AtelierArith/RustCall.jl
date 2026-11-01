use rustcall_julia_core::{expand, manifest::ReturnKind};

#[test]
fn fallible_constructor_boxes_only_the_ok_payload() {
    let src = r#"
        #[julia]
        pub struct Item { value: i32 }
        #[julia]
        impl Item {
            pub fn new(value: i32) -> Result<Self, String> {
                if value < 0 { Err("negative".to_string()) } else { Ok(Self { value }) }
            }
        }
    "#;
    let result = expand::expand(src).unwrap();
    let method = &result.manifest.structs[0].methods[0];
    assert_eq!(method.return_kind, ReturnKind::Result);
    assert_eq!(method.ok_abi, "boxed");
    assert!(method.is_constructor);
    assert!(result.source.contains("rustcall_Item_new_boxed_result_v1"));
    assert!(result
        .source
        .contains("Box::into_raw(Box::new(rustcall_ok))"));
}

#[test]
fn generic_inline_constructor_remains_unlowered() {
    let source = r#"
        #[julia]
        pub struct Generic<T> { value: T }
        #[julia]
        impl<T> Generic<T> {
            pub fn new(value: T) -> Result<Self, String> { Ok(Self { value }) }
        }
    "#;
    let result = expand::expand(source).unwrap();
    let method = &result.manifest.structs[0].methods[0];
    assert_eq!(method.return_kind, ReturnKind::Plain);
    assert!(!method.is_constructor);
    assert!(method.ok_abi.is_empty());
}

#[test]
fn boxed_constructor_marker_collisions_are_reported_by_inline_and_crate_scans() {
    let source = r#"
        #[julia] pub struct Item { value: i32 }
        #[julia] impl Item {
            #[julia] pub fn new(value: i32) -> Result<Self, String> { Ok(Self { value }) }
        }
        #[julia] pub fn Item_new_boxed_result_v1() -> u8 { 1 }
    "#;
    let inline = expand::expand(source).unwrap();
    let duplicates = inline.manifest.duplicate_symbols();
    assert!(duplicates
        .iter()
        .any(|(symbol, _, _)| symbol == "rustcall_Item_new_boxed_result_v1"));
    assert!(inline.source.contains("compile_error"));
    let error = rustcall_julia_core::extract::extract_crate(source).unwrap_err();
    assert!(error
        .to_string()
        .contains("rustcall_Item_new_boxed_result_v1"));
}
