use rustcall_core::{extract::extract, manifest::Mode, wrap::wrapper_crate};

#[test]
fn renamed_and_named_self_imports_expose_modules() {
    for route in [
        "pub use outer::inner::{self as facade};",
        "pub use outer::inner::{self};",
    ] {
        let scanned = extract(&format!(
            "mod outer {{ pub mod inner {{ #[pyfunction] pub fn calculate() -> i32 {{ 42 }} }} }} {route}"
        ), Mode::Crate).unwrap();
        let expected = if route.contains("facade") {
            "facade"
        } else {
            "inner"
        };
        assert!(scanned.functions[0].skip_reason.is_empty());
        assert_eq!(scanned.functions[0].callable_path, [expected, "calculate"]);
        let wrapped = wrapper_crate(&scanned, "user_crate", true);
        assert!(wrapped
            .lib_rs
            .contains(&format!("user_crate::{expected}::calculate()")));
    }
}

#[test]
fn enum_variant_globs_prevent_ambiguous_function_routes() {
    for variant in ["calculate", "calculate(i32)"] {
        let scanned = extract(
            &format!(
                r#"
            mod a {{ pub enum E {{ {variant} }} pub use E::*; }}
            mod b {{ #[pyfunction] pub fn calculate() -> i32 {{ 42 }} }}
            pub use a::*;
            pub use b::*;
        "#
            ),
            Mode::Crate,
        )
        .unwrap();
        assert_eq!(scanned.functions[0].skip_reason, "not_public");
        assert!(scanned.functions[0].callable_path.is_empty());
    }
}

#[test]
fn disabled_enum_variants_do_not_block_public_function_routes() {
    let scanned = rustcall_core::extract::extract_with_cfg(
        r#"
        mod a { pub enum E { #[cfg(any())] calculate } pub use E::*; }
        mod b { #[pyfunction] pub fn calculate() -> i32 { 42 } }
        pub use a::*;
        pub use b::*;
    "#,
        Mode::Crate,
        Some(&rustcall_core::cfg::CfgSet::default()),
    )
    .unwrap();
    assert!(scanned.functions[0].skip_reason.is_empty());
    assert_eq!(scanned.functions[0].callable_path, ["calculate"]);
}

#[test]
fn public_class_and_unrelated_same_named_value_are_not_ambiguous() {
    let scanned = extract(
        r#"
        mod hidden {
            #[pyclass] pub struct Thing { #[pyo3(get, set)] pub value: i32 }
            #[pymethods] impl Thing { #[new] pub fn new() -> Self { Self { value: 42 } } }
        }
        pub use hidden::Thing;
        pub fn Thing() -> i32 { 99 }
    "#,
        Mode::Crate,
    )
    .unwrap();
    let class = &scanned.structs[0];
    assert!(class.skip_reason.is_empty());
    assert_eq!(class.callable_path, ["Thing"]);
    assert!(!class.fields[0].getter.is_empty());
    assert!(class.methods[0].skip_reason.is_empty());
    let wrapped = wrapper_crate(&scanned, "user_crate", true);
    assert!(wrapped.lib_rs.contains("user_crate::Thing::new()"));
}

#[test]
fn public_alias_restores_only_supported_field_accessors() {
    for options in ["", "get_all, set_all", "get_all, frozen"] {
        let definition = format!(
            r#"
            #[pyclass({options})] pub struct Counter {{
                #[pyo3(get, set)] pub value: i32,
                #[pyo3(get, set)] pub text: String,
                #[pyo3(get, set)] private: i32,
                #[pyo3(get, set)] pub unsupported: Vec<i32>,
                pub automatic: i32,
            }}
        "#
        );
        let direct = extract(&format!("pub mod hidden {{ {definition} }}"), Mode::Crate).unwrap();
        let alias = extract(
            &format!("mod hidden {{ {definition} }} pub use hidden::Counter as PublicCounter;"),
            Mode::Crate,
        )
        .unwrap();
        assert_eq!(
            alias.structs[0].fields, direct.structs[0].fields,
            "{options}"
        );
        let fields = &alias.structs[0].fields;
        assert!(!fields[0].getter.is_empty());
        assert_eq!(fields[0].setter.is_empty(), options.contains("frozen"));
        assert!(fields[2].getter.is_empty() && fields[2].setter.is_empty());
        assert!(fields[3].getter.is_empty() && fields[3].setter.is_empty());
        let wrapped = wrapper_crate(&alias, "user_crate", true);
        assert!(wrapped
            .lib_rs
            .contains("rustcall_hidden__Counter_get_value"));
    }
}

#[test]
fn underscore_imports_never_grant_callable_routes() {
    let source = "mod hidden { #[pyfunction] pub fn calculate() -> i32 { 42 } } pub use hidden::calculate as _;";
    let anonymous = extract(source, Mode::Crate).unwrap();
    assert_eq!(anonymous.functions[0].skip_reason, "not_public");
    assert!(anonymous.functions[0].callable_path.is_empty());
    let named = extract(
        &format!("{source} pub use hidden::calculate as public_calculate;"),
        Mode::Crate,
    )
    .unwrap();
    assert!(named.functions[0].skip_reason.is_empty());
    assert_eq!(named.functions[0].callable_path, ["public_calculate"]);
    let wrapped = wrapper_crate(&named, "user_crate", true);
    assert!(wrapped.lib_rs.contains("user_crate::public_calculate"));
}

#[test]
fn intrinsic_signature_reasons_are_owned_by_the_cfg_variant() {
    // Identical canonical name and source line, as when two cfg-exclusive
    // fragments define different signatures at the same source position.
    let source = r#"#[cfg(feature = "x")] mod hidden { #[pyfunction] pub fn f() -> i32 { 1 } } #[cfg(not(feature = "x"))] mod hidden { #[pyfunction] pub async fn f() -> i32 { 2 } } pub use hidden::f;"#;
    let manifest = extract(source, Mode::Crate).unwrap();
    let normal = manifest
        .functions
        .iter()
        .find(|f| f.cfg == "feature = \"x\"")
        .unwrap();
    let asynchronous = manifest
        .functions
        .iter()
        .find(|f| f.cfg == "not(feature = \"x\")")
        .unwrap();
    assert_eq!(normal.line, asynchronous.line);
    assert!(normal.skip_reason.is_empty());
    assert_eq!(asynchronous.skip_reason, "async_fn");
}

#[test]
fn cfg_exclusive_module_copies_do_not_share_reachability() {
    let manifest = extract(
        r#"
        #[cfg(feature = "x")]
        pub mod api { #[pyfunction] pub fn calculate() -> i32 { 1 } }
        #[cfg(not(feature = "x"))]
        mod api { #[pyfunction] pub fn calculate() -> i32 { 2 } }
    "#,
        Mode::Crate,
    )
    .unwrap();
    assert_eq!(manifest.functions.len(), 2);
    let public = manifest
        .functions
        .iter()
        .find(|f| f.cfg == "feature = \"x\"")
        .unwrap();
    let private = manifest
        .functions
        .iter()
        .find(|f| f.cfg == "not(feature = \"x\")")
        .unwrap();
    assert!(public.skip_reason.is_empty());
    assert_eq!(private.skip_reason, "not_public");
}

#[test]
fn cfg_exclusive_classes_keep_their_methods_predicate() {
    let manifest = extract(
        r#"
        #[cfg(feature = "x")]
        pub mod api {
            #[pyclass] pub struct Counter;
            #[pymethods] impl Counter { pub fn value(&self) -> i32 { 1 } }
        }
        #[cfg(not(feature = "x"))]
        pub mod api {
            #[pyclass] pub struct Counter;
            #[pymethods] impl Counter { pub fn value(&self) -> i32 { 2 } }
        }
    "#,
        Mode::Crate,
    )
    .unwrap();
    assert_eq!(manifest.structs.len(), 2);
    for class in manifest.structs {
        assert_eq!(class.methods.len(), 1);
        assert_eq!(class.methods[0].cfg, class.cfg);
        assert!(class.methods[0].skip_reason.is_empty());
    }
}

#[test]
fn public_routes_follow_the_selected_feature_and_keep_lenient_cfg() {
    use rustcall_core::{cfg::CfgSet, extract::extract_with_cfg};
    let source = r#"
        mod hidden { #[pyfunction] pub fn calculate() -> i32 { 42 } }
        #[cfg(feature = "api")] pub use hidden::calculate as exposed;
    "#;
    let disabled = extract_with_cfg(source, Mode::Crate, Some(&CfgSet::default())).unwrap();
    assert_eq!(disabled.functions[0].skip_reason, "not_public");
    let enabled = extract_with_cfg(
        source,
        Mode::Crate,
        Some(&CfgSet::default().with_pair("feature", "api")),
    )
    .unwrap();
    assert!(enabled.functions[0].skip_reason.is_empty());
    assert_eq!(enabled.functions[0].callable_path, ["exposed"]);
    let lenient = extract(source, Mode::Crate).unwrap();
    assert!(lenient.functions[0]
        .cfg_features
        .contains(&"api".to_string()));
    let wrapped = wrapper_crate(&lenient, "user_crate", false);
    assert!(!wrapped.manifest.functions[0].skip_reason.is_empty());
}

#[test]
fn a_public_alias_exposes_a_function_in_a_private_module() {
    let scanned = extract(
        r#"
        mod hidden { #[pyfunction] pub fn calculate() -> i32 { 42 } }
        pub use hidden::calculate as public_calculate;
    "#,
        Mode::Crate,
    )
    .unwrap();
    let function = &scanned.functions[0];
    assert!(function.skip_reason.is_empty(), "{}", function.skip_reason);
    assert_eq!(function.module_path, ["hidden"]);
    let wrapped = wrapper_crate(&scanned, "user_crate", true);
    assert!(wrapped.lib_rs.contains("user_crate::public_calculate"));
    assert!(!wrapped.lib_rs.contains("user_crate::hidden::calculate"));
}

#[test]
fn public_class_routes_are_resolved_before_method_attachment() {
    let scanned = extract(
        r#"
        mod hidden {
            #[pyclass] pub struct Counter { value: i32 }
            #[pymethods] impl Counter {
                #[new] pub fn new() -> Self { Self { value: 7 } }
                pub fn value(&self) -> i32 { self.value }
            }
        }
        pub use hidden::Counter as PublicCounter;
    "#,
        Mode::Crate,
    )
    .unwrap();
    let class = &scanned.structs[0];
    assert!(class.skip_reason.is_empty(), "{}", class.skip_reason);
    assert_eq!(class.methods.len(), 2);
    assert!(class
        .methods
        .iter()
        .all(|method| method.skip_reason.is_empty()));
    let wrapped = wrapper_crate(&scanned, "user_crate", true);
    assert!(wrapped.lib_rs.contains("user_crate::PublicCounter"));
    assert!(!wrapped.lib_rs.contains("user_crate::hidden::Counter"));
}

#[test]
fn chained_glob_and_module_alias_routes_reach_the_same_definition() {
    for exports in [
        "mod bridge { pub use crate::hidden::calculate as renamed; } pub use bridge::renamed;",
        "pub use hidden::*;",
        "pub use hidden::api as public_api;",
    ] {
        let definition = if exports.contains("hidden::api") {
            "mod hidden { pub mod api { #[pyfunction] pub fn calculate() -> i32 { 42 } } }"
        } else {
            "mod hidden { #[pyfunction] pub fn calculate() -> i32 { 42 } }"
        };
        let scanned = extract(&format!("{definition} {exports}"), Mode::Crate).unwrap();
        assert!(scanned.functions[0].skip_reason.is_empty(), "{exports}");
        assert_eq!(scanned.functions.len(), 1);
    }
}

#[test]
fn private_routes_do_not_grant_access_and_public_routes_keep_signature_checks() {
    for exports in [
        "use hidden::calculate;",
        "pub(crate) use hidden::calculate;",
    ] {
        let scanned = extract(
            &format!(
                r#"
            mod hidden {{ #[pyfunction] pub fn calculate() -> i32 {{ 42 }} }}
            {exports}
        "#
            ),
            Mode::Crate,
        )
        .unwrap();
        assert!(!scanned.functions[0].skip_reason.is_empty());
    }
    let scanned = extract(
        r#"
        mod hidden { #[pyfunction] pub async fn calculate() -> i32 { 42 } }
        pub use hidden::calculate;
    "#,
        Mode::Crate,
    )
    .unwrap();
    assert_eq!(
        scanned.functions[0].skip_reason,
        rustcall_core::manifest::skip_reason::ASYNC_FN
    );
}
