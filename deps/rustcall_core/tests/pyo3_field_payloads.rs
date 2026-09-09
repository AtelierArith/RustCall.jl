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
