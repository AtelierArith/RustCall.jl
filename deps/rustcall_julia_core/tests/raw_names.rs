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

#[test]
fn a_python_owned_class_with_raw_members_gets_a_wrapper_crate() {
    // A class with a defaulted method is Python-owned, so its methods and
    // fields get `__rustcall_python_<class>_<member>` helpers. Built from the
    // raw names they read `__rustcall_python_Kw_r#match`, which
    // `format_ident!` refuses with a panic (PR #515 review).
    let scanned = extract(
        r#"
        #[pyclass] pub struct Kw { #[pyo3(get, set)] pub r#let: i32 }
        #[pymethods] impl Kw {
            #[pyo3(signature = (x = 1))]
            pub fn r#match(&self, x: i32) -> i32 { self.r#let + x }
        }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let wrapped = rustcall_julia_core::wrap::wrapper_crate(&scanned, "user_crate", true);
    let source = &wrapped.lib_rs;
    for helper in [
        "__rustcall_python_Kw_match",
        "__rustcall_python_Kw_get_let",
        "__rustcall_python_Kw_set_let",
    ] {
        assert!(source.contains(helper), "{helper} missing from {source}");
    }
    assert!(!source.contains("_r#"), "{source}");
    // The Python attributes are the unraw names PyO3 exposes.
    assert!(
        source.contains("\"match\"") && source.contains("\"let\""),
        "{source}"
    );
}

#[test]
fn a_pyo3_accessor_method_records_the_property_python_exposes() {
    // A `#[getter]` / `#[setter]` method is the Python property PyO3 derives
    // from it: the attribute's name, or the method's name without `r#` and
    // without a `get_` / `set_` prefix. The manifest's `python_name` carries
    // it, so the PyO3 host and the wrapper crate look up one name (#524).
    let manifest = extract(
        r#"
        #[pyclass] pub struct Acc { v: i32 }
        #[pymethods] impl Acc {
            #[getter] fn r#for(&self) -> i32 { self.v }
            #[setter] fn set_for(&mut self, x: i32) { self.v = x; }
            #[getter(end)] fn ending(&self) -> i32 { self.v }
            #[setter(name = "end")] fn put_end(&mut self, x: i32) { self.v = x; }
            #[getter] #[pyo3(name = "total")] fn get_sum(&self) -> i32 { self.v }
            #[getter] fn get_plain(&self) -> i32 { self.v }
            #[getter] fn plain_too(&self) -> i32 { self.v }
            #[getter] fn get_(&self) -> i32 { self.v }
            fn get_value(&self) -> i32 { self.v }
            #[getter(r#type)] fn kind(&self) -> i32 { self.v }
            #[setter(r#type)] fn put_kind(&mut self, x: i32) { self.v = x; }
            #[getter(name = "r#literal")] fn lit(&self) -> i32 { self.v }
        }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let methods = &manifest.structs[0].methods;
    let python = |name: &str| {
        methods
            .iter()
            .find(|m| m.name == name)
            .unwrap()
            .python_name
            .clone()
    };
    assert_eq!(python("r#for"), "for");
    assert_eq!(python("set_for"), "for");
    assert_eq!(python("ending"), "end");
    assert_eq!(python("put_end"), "end");
    assert_eq!(python("get_sum"), "total");
    assert_eq!(python("get_plain"), "plain");
    // The method's own name: nothing to record.
    assert_eq!(python("plain_too"), "");
    // An empty remainder is no property name; the method keeps its own.
    assert_eq!(python("get_"), "");
    // Not an accessor: a method keeps its name, prefix and all.
    assert_eq!(python("get_value"), "");
    // An identifier override is a Rust name, unrawed as every name is (PR
    // #525 review); a string `name = "..."` is taken as written.
    assert_eq!(python("kind"), "type");
    assert_eq!(python("put_kind"), "type");
    assert_eq!(python("lit"), "r#literal");
}

#[test]
fn a_raw_no_mangle_export_records_its_native_symbol() {
    // `#[no_mangle] pub extern "C" fn r#for` is exported by rustc as `for`;
    // the manifest's symbol is what Julia `dlsym`s (PR #515 review).
    let manifest = extract(
        r#"#[no_mangle] pub extern "C" fn r#for(x: i32) -> i32 { x }"#,
        Mode::Inline,
    )
    .unwrap();
    let f = &manifest.functions[0];
    assert_eq!(f.name, "r#for");
    assert_eq!(f.symbol, "for");
}

/// Every public name helper of `codegen` is total over a raw name: called with
/// `r#` spellings wherever it takes a name or a stem, it returns what the
/// exported item is called, without a `#` (PR #517 review:
/// `method_symbol(&[], "S", "r#match")` returned `rustcall_S_r#match`).
///
/// The helpers checked are listed here, and the list is compared with the
/// source: every `pub fn` of `codegen.rs` that takes a `&str` and returns a
/// `String` must be in it, so a new helper is checked the day it is added.
#[test]
fn every_public_symbol_helper_drops_a_raw_prefix() {
    use rustcall_julia_core::codegen::*;
    let raw_path = vec!["r#mod".to_string()];
    let checked: Vec<(&str, String, &str)> = vec![
        ("symbol_stem", symbol_stem(&[], "r#for"), "for"),
        ("symbol_stem", symbol_stem(&raw_path, "r#for"), "mod__for"),
        (
            "function_symbol",
            function_symbol(&[], "r#for"),
            "rustcall_for",
        ),
        (
            "function_symbol",
            function_symbol(&raw_path, "r#for"),
            "rustcall_mod__for",
        ),
        (
            "method_symbol",
            method_symbol(&[], "S", "r#match"),
            "rustcall_S_match",
        ),
        (
            "method_symbol",
            method_symbol(&raw_path, "r#type", "r#match"),
            "rustcall_mod__type_match",
        ),
        ("method_stem", method_stem(None, "r#match"), "match"),
        (
            "method_stem",
            method_stem(Some("r#type"), "r#match"),
            "4type_match",
        ),
        (
            "method_symbol_of",
            method_symbol_of("r#type", "r#match"),
            "rustcall_type_match",
        ),
        (
            "struct_free_symbol",
            struct_free_symbol("r#type"),
            "type_free",
        ),
        (
            "method_string_owner",
            method_string_owner("r#type", "r#match"),
            "type_match",
        ),
        (
            "field_getter_symbol",
            field_getter_symbol("r#type", "r#let"),
            "type_get_let",
        ),
        (
            "field_setter_symbol",
            field_setter_symbol("r#type", "r#let"),
            "type_set_let",
        ),
        ("panic_symbol", panic_symbol("r#for"), "for_take_panic"),
        (
            "generic_method_wrapper_name",
            generic_method_wrapper_name("r#type", "r#match"),
            "type_match",
        ),
    ];
    for (helper, got, want) in &checked {
        assert_eq!(got, want, "{helper}");
        assert!(!got.contains('#'), "{helper}: {got}");
    }

    // The list is the source's list.
    let codegen = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/codegen.rs"),
    )
    .unwrap();
    let mut helpers = Vec::new();
    for item in codegen.split("\npub fn ").skip(1) {
        // The signature, however rustfmt wrapped it: up to the body's brace.
        let signature = item.split('{').next().unwrap_or_default();
        let Some((name, rest)) = signature.split_once('(') else {
            continue;
        };
        if rest.contains("&str") && rest.trim_end().ends_with("-> String") {
            helpers.push(name.to_string());
        }
    }
    let missing: Vec<&String> = helpers
        .iter()
        .filter(|h| !checked.iter().any(|(name, _, _)| name == h))
        .collect();
    assert!(
        !helpers.is_empty() && missing.is_empty(),
        "public name helpers not checked with a raw name: {missing:?}"
    );
}

/// The class-level guarantee (#514): every identifier, symbol or helper name
/// the core builds from a Rust item's name goes through `codegen::unraw`,
/// directly or through a helper built on it (`symbol_stem`, `method_stem`,
/// `Method::method_stem`, `source_ident`). A `format_ident!` / `Ident::new`
/// whose arguments read an item name (`.name`, `ident.to_string()`) without one
/// of those is what produced `rustcall_r#for_new`, `for_get_r#let` and
/// `__rustcall_python_Kw_r#match`, each found one at a time; this finds the
/// next one before a review does. `r#` is stripped in `codegen.rs` only.
#[test]
fn no_identifier_is_built_from_a_raw_name() {
    let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let helpers = ["unraw(", "symbol_stem(", "method_stem(", "source_ident("];
    let mut offenders = Vec::new();
    for entry in std::fs::read_dir(&src).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|e| e.to_str()) != Some("rs") {
            continue;
        }
        let text = std::fs::read_to_string(&path).unwrap();
        for opener in ["format_ident!(", "Ident::new(", "Ident::new_raw("] {
            let mut from = 0;
            while let Some(found) = text[from..].find(opener) {
                let start = from + found;
                let open = start + opener.len() - 1;
                let mut depth = 0usize;
                let mut end = open;
                for (i, c) in text[open..].char_indices() {
                    match c {
                        '(' => depth += 1,
                        ')' => {
                            depth -= 1;
                            if depth == 0 {
                                end = open + i;
                                break;
                            }
                        }
                        _ => {}
                    }
                }
                let call = &text[start..=end];
                let reads_name = call.contains(".name") || call.contains("ident.to_string()");
                if reads_name && !helpers.iter().any(|h| call.contains(h)) {
                    let line = text[..start].matches('\n').count() + 1;
                    offenders.push(format!("{}:{line}: {call}", path.display()));
                }
                from = end + 1;
            }
        }
        if path.file_name().unwrap() != "codegen.rs" && text.contains("strip_prefix(\"r#\")") {
            offenders.push(format!("{}: strips `r#` itself", path.display()));
        }
    }
    assert!(offenders.is_empty(), "{offenders:#?}");
}
