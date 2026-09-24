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
