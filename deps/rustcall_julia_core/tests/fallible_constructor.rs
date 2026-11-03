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

#[test]
fn receiver_method_result_self_boxes_the_ok_payload() {
    // #564: a receiver method returning `Result<Self, E>` is not a
    // constructor, but its `Ok` value crosses the boundary like one.
    let src = r#"
        #[julia]
        pub struct Value { n: i32 }
        #[julia]
        impl Value {
            #[julia]
            pub fn new(n: i32) -> Self { Self { n } }
            #[julia]
            pub fn duplicate(&self) -> Result<Self, String> { Ok(Self { n: self.n }) }
            #[julia]
            pub fn split(&mut self) -> Result<Value, String> { Ok(Value { n: self.n }) }
        }
    "#;
    let result = expand::expand(src).unwrap();
    let methods = &result.manifest.structs[0].methods;
    for name in ["duplicate", "split"] {
        let method = methods.iter().find(|m| m.name == name).unwrap();
        assert_eq!(method.return_kind, ReturnKind::Result, "{name}");
        assert_eq!(method.ok_abi, "boxed", "{name}");
        assert_eq!(method.err_abi, "string", "{name}");
        assert!(!method.is_static, "{name}");
        assert!(!method.is_constructor, "{name}");
        let marker = format!("rustcall_Value_{name}_boxed_result_v1");
        assert!(result.source.contains(&marker), "{name}");
    }
    assert!(
        methods
            .iter()
            .find(|m| m.name == "split")
            .unwrap()
            .is_mutable
    );
    assert_eq!(
        result
            .source
            .matches("Box::into_raw(Box::new(rustcall_ok))")
            .count(),
        2
    );

    let crate_manifest = rustcall_julia_core::extract::extract_crate(src).unwrap();
    let method = crate_manifest.structs[0]
        .methods
        .iter()
        .find(|m| m.name == "duplicate")
        .unwrap();
    assert_eq!(method.ok_abi, "boxed");
    assert!(!method.is_constructor);
}

#[test]
fn proc_macro_boxes_receiver_result_self() {
    let item: syn::ItemImpl = syn::parse_quote! {
        impl Value {
            #[julia]
            pub fn duplicate(&self) -> Result<Self, String> { Ok(Self { n: self.n }) }
        }
    };
    let tokens = rustcall_julia_core::codegen::transform_impl_crate(item, &[]).to_string();
    assert!(tokens.contains("rustcall_Value_duplicate_boxed_result_v1"));
    assert!(tokens.contains("Box :: into_raw"));
}
