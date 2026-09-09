use rustcall_core::{extract::extract, manifest::Mode, wrap::wrapper_crate};

#[test]
fn string_setters_use_the_shared_byte_pair_abi() {
    for access in ["set", "get, set"] {
        let scan = extract(
            &format!("#[pyclass] pub struct Text {{ #[pyo3({access})] pub value: String }}"),
            Mode::Crate,
        )
        .unwrap();
        let wrapped = wrapper_crate(&scan, "user_crate", true);
        let class = &wrapped.manifest.structs[0];
        assert!(class.fields[0].ffi_compatible);
        assert_eq!(class.fields[0].setter, "rustcall_Text_set_value");
        assert_eq!(class.fields[0].getter.is_empty(), access == "set");
        assert_eq!(class.has_owned_string_helper, access != "set");
        assert!(wrapped.lib_rs.contains("value_ptr: *const u8"));
        assert!(wrapped.lib_rs.contains("value_len: usize"));
        assert!(wrapped.lib_rs.contains("String::from_utf8_lossy"));
        assert!(wrapped
            .lib_rs
            .contains(&rustcall_core::codegen::panic_symbol(
                "rustcall_Text_set_value"
            )));
    }
}

#[test]
fn string_setters_keep_frozen_and_private_field_restrictions() {
    for source in [
        "#[pyclass(frozen, get_all)] pub struct Text { #[pyo3(set)] pub value: String }",
        "#[pyclass] pub struct Text { #[pyo3(get, set)] value: String }",
    ] {
        let scan = extract(source, Mode::Crate).unwrap();
        let wrapped = wrapper_crate(&scan, "user_crate", true);
        assert!(wrapped.manifest.structs[0].fields[0].setter.is_empty());
        assert!(!wrapped.lib_rs.contains("fn rustcall_Text_set_value("));
    }
}

#[test]
fn vec_fields_export_owned_buffers_and_slice_setters() {
    let scan = extract(
        "#[pyclass] pub struct Values { #[pyo3(get, set)] pub data: Vec<i32> }",
        Mode::Crate,
    )
    .unwrap();
    let wrapped = wrapper_crate(&scan, "user_crate", true);
    let field = &wrapped.manifest.structs[0].fields[0];
    assert_eq!(field.abi, "vec");
    assert_eq!(field.vec_element, "i32");
    assert_eq!(field.free_symbol, "rustcall_Values_get_data_free_rust_vec");
    assert!(wrapped
        .lib_rs
        .contains("struct rustcall_Values_get_data_RustCallOwnedVec"));
    assert!(wrapped
        .lib_rs
        .contains("fn rustcall_Values_get_data_free_rust_vec"));
    assert!(wrapped
        .lib_rs
        .contains("drop(Vec::from_raw_parts(value.ptr, value.len, value.cap))"));
    assert!(wrapped.lib_rs.contains("value: *const i32"));
    assert!(wrapped
        .lib_rs
        .contains("from_raw_parts(value, len).to_vec()"));
}

#[test]
fn set_only_vec_fields_need_no_return_helper() {
    let scan = extract(
        "#[pyclass] pub struct Values { #[pyo3(set)] pub data: Vec<f64> }",
        Mode::Crate,
    )
    .unwrap();
    let wrapped = wrapper_crate(&scan, "user_crate", true);
    let field = &wrapped.manifest.structs[0].fields[0];
    assert!(field.getter.is_empty());
    assert!(field.free_symbol.is_empty());
    assert!(wrapped.lib_rs.contains("fn rustcall_Values_set_data"));
    assert!(!wrapped.lib_rs.contains("RustCallOwnedVec"));
}
