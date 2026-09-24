//! A raw struct or field name is described as the proc macro exports it
//! (#514).
//!
//! `#[julia] pub struct r#for { pub r#let: i32 }` is legal Rust, and the proc
//! macro exports `rustcall_for_new`, `for_get_let` and `for_free`: a raw
//! identifier's `r#` is no part of a symbol. The crate scan used to panic on
//! such a struct (the method-wrapper refusal check built `rustcall_r#for_new`
//! as an identifier) and described a raw field's accessors as
//! `for_get_r#let`, a symbol nothing exports. The Julia name of each item is
//! decided on the Julia side (`julia_binding_name`); the symbols are decided
//! here, and must match what the expansion defines.

use rustcall_julia_core::codegen::{transform_impl_crate, transform_struct_crate};
use rustcall_julia_core::extract::extract;
use rustcall_julia_core::manifest::Mode;

const STRUCT: &str = "pub struct r#for { pub r#let: i32, pub x: i32 }";
const IMPL: &str = r#"
    impl r#for {
        #[julia] pub fn new(x: i32) -> Self { r#for { r#let: 0, x } }
        #[julia] pub fn r#if(&self) -> i32 { self.x }
    }
"#;

#[test]
fn a_raw_struct_and_field_are_described_as_the_proc_macro_exports_them() {
    let source = format!("#[julia] {STRUCT}\n#[julia] {IMPL}");
    let manifest = extract(&source, Mode::Crate).unwrap();
    let s = &manifest.structs[0];
    assert_eq!(s.name, "r#for");
    assert_eq!(s.ffi_name, "for");
    let field = s.fields.iter().find(|f| f.name == "r#let").unwrap();
    assert_eq!(field.getter, "for_get_let");
    assert_eq!(field.setter, "for_set_let");
    let mut symbols: Vec<&str> = s.methods.iter().map(|m| m.symbol.as_str()).collect();
    symbols.sort_unstable();
    assert_eq!(symbols, ["rustcall_for_if", "rustcall_for_new"]);

    // The proc macro's expansion defines exactly those names.
    let item: syn::ItemStruct = syn::parse_str(STRUCT).unwrap();
    let expanded = transform_struct_crate(item, &[]).to_string();
    for name in ["for_get_let", "for_set_let", "for_free"] {
        assert!(expanded.contains(name), "{name} missing from {expanded}");
    }
    assert!(!expanded.contains("r#let_"), "{expanded}");
    let item: syn::ItemImpl = syn::parse_str(IMPL).unwrap();
    let expanded = transform_impl_crate(item, &[]).to_string();
    for name in ["rustcall_for_new", "rustcall_for_if"] {
        assert!(expanded.contains(name), "{name} missing from {expanded}");
    }
}

#[test]
fn a_raw_method_of_a_generic_inline_struct_gets_an_unraw_wrapper_name() {
    // `inline_generic_wrappers` passed `Boxed_r#match` to `format_ident!` and
    // the manifest looked the wrapper up under that spelling (PR #515
    // review). The generic wrapper hangs off the method stem, as a concrete
    // struct's symbol does.
    let source = r#"
        #[julia]
        pub struct Boxed<T> { pub v: T }
        impl<T: Copy> Boxed<T> {
            pub fn new(v: T) -> Self { Boxed { v } }
            pub fn r#match(&self) -> T { self.v }
        }
    "#;
    let expanded = rustcall_julia_core::expand::expand(source).unwrap();
    let boxed = &expanded.manifest.structs[0];
    let names: Vec<&str> = boxed
        .generic_wrappers
        .iter()
        .map(|w| w.name.as_str())
        .collect();
    assert!(names.contains(&"Boxed_match"), "{names:?}");
    let matched = boxed.methods.iter().find(|m| m.name == "r#match").unwrap();
    assert_eq!(matched.generic_wrapper_name, "Boxed_match");
    assert!(!matched.generic_wrapper.is_empty());
}

#[test]
fn a_raw_pyo3_name_is_recorded_as_python_exposes_it() {
    // PyO3 exposes `fn r#for` as `for`: the manifest's `python_name` says so,
    // and every consumer looks that name up (PR #515 review). An explicit
    // `#[pyo3(name = ...)]` still wins, and a plain name stays empty.
    let manifest = extract(
        r#"
        #[pyfunction] pub fn r#for(x: i32) -> i32 { x }
        #[pyfunction] #[pyo3(name = "go")] pub fn r#loop(x: i32) -> i32 { x }
        #[pyfunction] pub fn plain(x: i32) -> i32 { x }
        #[pyclass] pub struct r#type { #[pyo3(get, set)] pub r#let: i32 }
        #[pymethods] impl r#type {
            fn r#match(&self) -> i32 { self.r#let }
        }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let function = |name: &str| manifest.functions.iter().find(|f| f.name == name).unwrap();
    assert_eq!(function("r#for").python_name, "for");
    assert_eq!(function("r#loop").python_name, "go");
    assert_eq!(function("plain").python_name, "");
    let class = manifest
        .structs
        .iter()
        .find(|s| s.name == "r#type")
        .unwrap();
    assert_eq!(class.python_name, "type");
    let field = &class.fields[0];
    assert_eq!(field.python_name, "let");
    assert_eq!(field.getter, "rustcall_type_get_let");
    assert_eq!(field.setter, "rustcall_type_set_let");
    let method = class.methods.iter().find(|m| m.name == "r#match").unwrap();
    assert_eq!(method.python_name, "match");
    // The symbol hangs off the method stem, as a `#[julia]` method's does: the
    // wrapper crate refused `rustcall_type_r#match` as an identifier and
    // `@rust_crate` dropped the method (PR #517 review).
    assert_eq!(method.symbol, "rustcall_type_match");
    assert!(
        manifest
            .structs
            .iter()
            .flat_map(|s| s.methods.iter().map(|m| &m.symbol))
            .chain(manifest.functions.iter().map(|f| &f.symbol))
            .all(|symbol| !symbol.contains('#')),
        "{manifest:?}"
    );
}
