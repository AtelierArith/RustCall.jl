use rustcall_core::{extract::extract, manifest::Mode, wrap::wrapper_crate};

#[test]
fn private_defaults_use_the_original_pyo3_dispatcher_at_each_arity() {
    let scan = extract(
        r#"
        fn private_default() -> i32 { 37 }
        #[pyfunction(signature = (value = private_default()))]
        pub fn calculate(value: i32) -> i32 { value }
        #[pyfunction(signature = (value = private_default()))]
        pub fn render_default(value: i32) -> PyResult<String> { Ok(value.to_string()) }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let wrapped = wrapper_crate(&scan, "user_crate", true);
    let entries: Vec<_> = wrapped
        .manifest
        .functions
        .iter()
        .filter(|function| function.name == "calculate")
        .collect();
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].args.len(), 1);
    assert_eq!(entries[1].args.len(), 0);
    assert_eq!(entries[1].symbol, "rustcall_calculate__default_1");
    assert!(wrapped.lib_rs.contains("rustcall_pyo3::wrap_pyfunction!"));
    assert!(wrapped.lib_rs.contains("user_crate::calculate, py"));
    assert!(!wrapped.lib_rs.contains("private_default()"));
    assert!(wrapped.lib_rs.contains("pub struct CResult_render_default"));
    assert!(wrapped
        .lib_rs
        .contains("pub struct CResult_render_default__default_1"));
}

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

#[test]
fn py_result_strings_use_owned_payload_buffers() {
    let scan = extract(
        r#"
        #[pyfunction]
        pub fn render(ok: bool) -> PyResult<String> {
            if ok { Ok("ready".to_string()) } else { todo!() }
        }
        #[pyclass]
        pub struct Label;
        #[pymethods]
        impl Label {
            #[new] pub fn new() -> Self { Self }
            pub fn render(&self, ok: bool) -> PyResult<String> {
                if ok { Ok("label".to_string()) } else { todo!() }
            }
        }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let wrapped = wrapper_crate(&scan, "user_crate", true);
    let function = wrapped
        .manifest
        .functions
        .iter()
        .find(|f| f.name == "render")
        .unwrap();
    assert!(function.exported);
    assert_eq!(function.ok_abi, "string");
    assert!(function.has_owned_string_helper);
    let method = wrapped.manifest.structs[0]
        .methods
        .iter()
        .find(|m| m.name == "render")
        .unwrap();
    assert_eq!(method.ok_abi, "string");
    assert_eq!(method.string_owner, "Label_render");
    for item in [
        "render_RustCallOwnedString",
        "render_free_rust_string",
        "Label_render_RustCallOwnedString",
        "Label_render_free_rust_string",
    ] {
        assert!(wrapped.lib_rs.contains(item), "missing {item}");
    }
}

#[test]
fn py_result_self_is_an_owned_pointer_payload() {
    let scan = extract(
        r#"
        #[pyclass]
        pub struct Counter { value: i32 }
        #[pymethods]
        impl Counter {
            #[new]
            pub fn new(value: i32) -> PyResult<Self> { Ok(Self { value }) }
            pub fn shifted(&self, by: i32) -> PyResult<Self> {
                Ok(Self { value: self.value + by })
            }
        }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let wrapped = wrapper_crate(&scan, "user_crate", true);
    let class = &wrapped.manifest.structs[0];
    for method in &class.methods {
        assert!(method.returns_boxed_struct, "{}", method.name);
        assert!(method.skip_reason.is_empty(), "{}", method.skip_reason);
    }
    assert!(wrapped
        .lib_rs
        .contains("ok_value: ::std::mem::MaybeUninit<*mut user_crate::Counter>"));
    assert!(wrapped
        .lib_rs
        .contains("Box::into_raw(Box::new(rustcall_ok))"));
}

#[test]
fn inheritance_constructor_tuple_becomes_a_python_owned_handle() {
    let scan = extract(
        r#"
        #[pyclass]
        pub struct Base;
        #[pyclass(extends = Base)]
        pub struct Child;
        #[pymethods]
        impl Child {
            #[new]
            pub fn new() -> PyResult<(Self, Base)> { Ok((Self, Base)) }
            #[pyo3(signature = (value = 1))]
            pub fn replacement(&self, value: i32) -> PyResult<Self> { let _ = value; Ok(Self) }
        }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let wrapped = wrapper_crate(&scan, "user_crate", true);
    let method = wrapped
        .manifest
        .structs
        .iter()
        .find(|class| class.name == "Child")
        .unwrap()
        .methods
        .iter()
        .find(|method| method.name == "new")
        .unwrap();
    assert!(method.is_constructor);
    assert!(method.returns_boxed_struct);
    assert!(method.skip_reason.is_empty());
    assert_eq!(method.err_type, "i32");
    assert!(wrapped.lib_rs.contains("struct Child_RustCallPythonHandle"));
    assert!(wrapped.lib_rs.contains("fn rustcall_Child_new"));
    assert!(wrapped.lib_rs.contains("pub struct CResult_Child_new"));
    assert!(wrapped
        .lib_rs
        .contains("py.get_type::<user_crate::Child>()"));
    assert!(!wrapped.lib_rs.contains("Box::new((Self, Base))"));
    let replacement = wrapped
        .manifest
        .structs
        .iter()
        .find(|class| class.name == "Child")
        .unwrap()
        .methods
        .iter()
        .find(|method| method.name == "replacement")
        .unwrap();
    assert!(replacement.returns_boxed_struct);
    assert!(replacement.skip_reason.is_empty());
    assert!(wrapped
        .lib_rs
        .contains("object: Some(rustcall_object.unbind())"));
    assert!(wrapped
        .lib_rs
        .contains("ok_value: ::std::mem::MaybeUninit<*mut Child_RustCallPythonHandle>"));
    assert!(wrapped
        .lib_rs
        .contains("pub struct CResult_Child_replacement__default_1"));
}

#[test]
fn python_owned_classes_keep_descriptor_and_vec_field_abis() {
    let scan = extract(
        r#"
        #[pyclass]
        pub struct Base;
        #[pyclass(extends = Base)]
        pub struct Child { #[pyo3(get, set)] pub values: Vec<i32>, value: i32 }
        #[pymethods]
        impl Child {
            #[new]
            pub fn new() -> (Self, Base) {
                (Self { values: vec![1], value: 2 }, Base)
            }
            #[getter]
            pub fn doubled(&self) -> i32 { self.value * 2 }
            #[setter(doubled)]
            pub fn set_doubled(&mut self, value: i32) { self.value = value / 2; }
        }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let wrapped = wrapper_crate(&scan, "user_crate", true);
    let class = wrapped
        .manifest
        .structs
        .iter()
        .find(|class| class.name == "Child")
        .unwrap();
    let values = class
        .fields
        .iter()
        .find(|field| field.name == "values")
        .unwrap();
    assert!(values.ffi_compatible);
    assert_eq!(values.abi, "vec");
    assert_eq!(
        values.free_symbol,
        "rustcall_Child_get_values_free_rust_vec"
    );
    assert!(wrapped
        .lib_rs
        .contains("pub struct rustcall_Child_get_values_RustCallOwnedVec"));
    assert!(wrapped.lib_rs.contains("getattr(\"doubled\")"));
    assert!(wrapped.lib_rs.contains("setattr(\"doubled\", value)"));
    assert!(!wrapped.lib_rs.contains("call_method(\"doubled\""));
}

/// The generated default-arity entry points are symbols like any other, and have
/// to be reserved before wrappers are emitted (#370). `foo(value = 1)` also
/// defines `rustcall_foo__default_1`, so a root function actually *named*
/// `foo__default_1` is a collision — and reserving only `rustcall_foo` let both
/// items through to define the same symbol twice.
#[test]
fn default_arity_symbols_are_reserved_against_a_natural_name() {
    let scan = extract(
        r#"
        #[pyfunction]
        #[pyo3(signature = (value = 1))]
        pub fn foo(value: i32) -> i32 { value }

        #[pyfunction]
        pub fn foo__default_1() -> i32 { 0 }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let wrapped = wrapper_crate(&scan, "user_crate", true);
    let refused: Vec<_> = wrapped
        .manifest
        .functions
        .iter()
        .filter(|f| !f.skip_reason.is_empty())
        .collect();
    // One of the two has to lose; which one is the existing ordering rule's
    // business. What must not happen is both being emitted.
    assert_eq!(refused.len(), 1, "expected exactly one refusal");
    assert!(
        refused[0].skip_reason.contains("symbol"),
        "refused for the wrong reason: {}",
        refused[0].skip_reason
    );
    // Exactly one definition of the contested symbol. The open paren matters:
    // without it this also counts `rustcall_foo__default_1_take_panic`.
    assert_eq!(
        wrapped
            .lib_rs
            .matches("fn rustcall_foo__default_1(")
            .count(),
        1,
        "the contested symbol is defined more than once"
    );
}

/// A defaulted function on its own still gets every arity.
#[test]
fn default_arity_symbols_are_emitted_when_nothing_collides() {
    let scan = extract(
        r#"
        #[pyfunction]
        #[pyo3(signature = (value = 1))]
        pub fn solo(value: i32) -> i32 { value }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let wrapped = wrapper_crate(&scan, "user_crate", true);
    assert!(wrapped
        .manifest
        .functions
        .iter()
        .all(|f| f.skip_reason.is_empty()));
    assert!(wrapped.lib_rs.contains("fn rustcall_solo("));
    assert!(wrapped.lib_rs.contains("fn rustcall_solo__default_1("));
}

/// A Python-owned method returning `&str` used to fail the whole wrapper crate
/// (#370): the reference is extracted inside `Python::attach` and borrows the
/// Python string bound to `py`, so the helper could not return it — and had it
/// compiled, the buffer belongs to an object only the attachment keeps alive.
#[test]
fn python_owned_borrowed_string_returns_are_lowered_to_owned() {
    let scan = extract(
        r#"
        #[pyclass]
        pub struct Base;
        #[pyclass(extends = Base)]
        pub struct Child { label: String }
        #[pymethods]
        impl Child {
            #[new]
            pub fn new() -> (Self, Base) { (Self { label: String::from("x") }, Base) }
            pub fn name(&self) -> &str { &self.label }
            #[getter]
            pub fn tag(&self) -> &str { &self.label }
        }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let wrapped = wrapper_crate(&scan, "user_crate", true);
    let class = wrapped
        .manifest
        .structs
        .iter()
        .find(|class| class.name == "Child")
        .unwrap();
    // A plain method and a getter take the same route.
    for name in ["name", "tag"] {
        let method = class
            .methods
            .iter()
            .find(|method| method.name == name)
            .unwrap();
        assert_eq!(method.skip_reason, "", "{name} was refused");
        // The manifest describes the wrapper, not the user's signature: this
        // one hands Julia an owned buffer to release, not a borrowed pointer.
        assert_eq!(method.return_type, "String", "{name}");
        assert_eq!(method.return_abi, "string", "{name}");
        assert_eq!(method.string_owner, format!("Child_{name}"));
        assert!(
            wrapped
                .lib_rs
                .contains(&format!("pub struct Child_{name}_RustCallOwnedString")),
            "{name} has no owned-string buffer"
        );
    }
    // The shape that did not compile, in the exact place it appeared.
    assert!(!wrapped.lib_rs.contains("PyResult<&str>"));
    assert!(wrapped
        .lib_rs
        .contains("::rustcall_pyo3::Python::attach(|py| -> ::rustcall_pyo3::PyResult<String>"));
}

/// ...and the lowering stays inside the Python-owned flavours. A plain
/// `#[pyfunction]` returning `&str` is called directly, and its buffer is the
/// crate's own, so it keeps the borrowed ABI and the copy it saves.
#[test]
fn a_plain_pyfunction_keeps_the_borrowed_string_abi() {
    let scan = extract(
        r#"
        #[pyfunction]
        pub fn label() -> &'static str { "x" }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let wrapped = wrapper_crate(&scan, "user_crate", true);
    let label = wrapped
        .manifest
        .functions
        .iter()
        .find(|f| f.name == "label")
        .unwrap();
    assert_eq!(label.return_abi, "str");
    assert_eq!(label.return_type, "&'static str");
}

#[test]
fn python_owned_handle_decision_survives_a_skipped_defaulted_method() {
    let scan = extract(
        r#"
        #[pyclass]
        pub struct FilteredOwned;
        #[pymethods]
        impl FilteredOwned {
            #[new]
            pub fn new() -> Self { Self }
            #[pyo3(signature = (value = None))]
            pub fn filtered(&self, value: Option<Py<PyAny>>) { let _ = value; }
        }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let wrapped = wrapper_crate(&scan, "user_crate", true);
    let class = wrapped
        .manifest
        .structs
        .iter()
        .find(|class| class.name == "FilteredOwned")
        .unwrap();
    let filtered = class
        .methods
        .iter()
        .find(|method| method.name == "filtered")
        .unwrap();

    assert!(!filtered.skip_reason.is_empty());
    assert!(class.python_owned_handle);
    assert!(wrapped
        .lib_rs
        .contains("struct FilteredOwned_RustCallPythonHandle"));
}
