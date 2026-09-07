//! The one symbol-derivation function (#300): `codegen::symbol_stem` and the
//! `function_symbol` / `method_symbol` built on it, as every flavour reaches
//! it — inline expansion, crate extraction, `specialize`, struct methods and
//! accessors, and the PyO3 wrapper generator.

use rustcall_core::codegen::{
    field_getter_symbol, field_setter_symbol, function_symbol, method_symbol, method_symbol_of,
    struct_free_symbol, symbol_stem,
};
use rustcall_core::extract::{extract, ExtractError};
use rustcall_core::manifest::Mode;

fn path(segments: &[&str]) -> Vec<String> {
    segments.iter().map(|s| s.to_string()).collect()
}

#[test]
fn a_root_item_keeps_its_bare_name() {
    assert_eq!(symbol_stem(&[], "run"), "run");
    assert_eq!(symbol_stem(&[], "my_fn"), "my_fn");
    assert_eq!(function_symbol(&[], "run"), "rustcall_run");
    assert_eq!(method_symbol(&[], "C", "new"), "rustcall_C_new");
    assert_eq!(struct_free_symbol("C"), "C_free");
    assert_eq!(field_getter_symbol("C", "x"), "C_get_x");
    assert_eq!(field_setter_symbol("C", "x"), "C_set_x");
    // A raw identifier is spelled without its prefix, which is not a symbol
    // character.
    assert_eq!(symbol_stem(&[], "r#mod"), "mod");
}

#[test]
fn a_module_path_is_folded_into_the_stem() {
    assert_eq!(symbol_stem(&path(&["a"]), "run"), "a__run");
    assert_eq!(
        symbol_stem(&path(&["geometry", "shapes"]), "Circle"),
        "geometry__shapes__Circle"
    );
    assert_eq!(function_symbol(&path(&["a"]), "run"), "rustcall_a__run");
    assert_eq!(
        method_symbol(&path(&["a"]), "C", "new"),
        "rustcall_a__C_new"
    );
    assert_eq!(method_symbol_of("a__C", "new"), "rustcall_a__C_new");
    assert_eq!(struct_free_symbol("a__C"), "a__C_free");
    assert_eq!(field_getter_symbol("a__C", "x"), "a__C_get_x");
    assert_eq!(symbol_stem(&path(&["r#mod"]), "r#fn"), "mod__fn");
}

/// `a_b::c` and `a::b_c` must not share a stem: every underscore inside a
/// segment is escaped, so a `_` in a stem is always followed by `0` (escaped)
/// or `_` (separator) and the encoding decodes unambiguously.
#[test]
fn the_encoding_is_prefix_free() {
    assert_eq!(symbol_stem(&path(&["a_b"]), "c"), "a_0b__c");
    assert_eq!(symbol_stem(&path(&["a"]), "b_c"), "a__b_0c");
    assert_eq!(symbol_stem(&path(&["a", "b"]), "c"), "a__b__c");
    assert_eq!(symbol_stem(&path(&["a_"]), "b"), "a_0__b");
    assert_eq!(symbol_stem(&path(&["a"]), "_b"), "a___0b");
    assert_eq!(symbol_stem(&path(&["my_mod"]), "my_fn"), "my_0mod__my_0fn");

    let cases: Vec<(Vec<&str>, &str)> = vec![
        (vec!["a_b"], "c"),
        (vec!["a"], "b_c"),
        (vec!["a", "b"], "c"),
        (vec!["a_"], "b"),
        (vec!["a"], "_b"),
        (vec!["a__b"], "c"),
        (vec!["a"], "_"),
        (vec!["_a"], "b"),
        (vec!["a", "_"], "b"),
    ];
    let mut seen = std::collections::HashSet::new();
    for (segments, name) in &cases {
        let stem = symbol_stem(&path(segments), name);
        // Tokenize: a `_` opens a two-byte token that must be `_0` or `__`.
        let bytes = stem.as_bytes();
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == b'_' {
                let next = bytes.get(i + 1).copied();
                assert!(
                    matches!(next, Some(b'0') | Some(b'_')),
                    "{stem}: `_` followed by {next:?}"
                );
                i += 2;
            } else {
                i += 1;
            }
        }
        assert!(seen.insert(stem.clone()), "duplicate stem {stem}");
    }
}

/// Inline expansion qualifies by the module path it walks, without a marker.
#[test]
fn inline_flavour() {
    let src = r#"
        mod a { #[julia] pub fn run() -> i32 { 1 } }
        mod b { #[julia] pub fn run() -> i32 { 2 } }
        #[julia] pub fn run() -> i32 { 0 }
    "#;
    let e = rustcall_core::expand::expand(src).unwrap();
    let mut symbols: Vec<(String, String)> = e
        .manifest
        .functions
        .iter()
        .map(|f| (f.symbol.clone(), f.ffi_name.clone()))
        .collect();
    symbols.sort();
    assert_eq!(
        symbols,
        vec![
            ("rustcall_a__run".to_string(), "a__run".to_string()),
            ("rustcall_b__run".to_string(), "b__run".to_string()),
            ("rustcall_run".to_string(), "run".to_string()),
        ]
    );
    for (symbol, _) in &symbols {
        assert!(
            e.source
                .contains(&format!("pub extern \"C\" fn {symbol}()")),
            "{symbol} missing from\n{}",
            e.source
        );
    }
}

/// Crate extraction mirrors the proc-macro: `#[julia]` on the module carries
/// the path, a `#[julia]` item in an unmarked inline module is refused.
#[test]
fn crate_flavour() {
    let src = r#"
        #[julia] pub mod a { #[julia] pub fn run() -> i32 { 1 } }
        #[julia] pub mod b { #[julia] pub fn run() -> i32 { 2 } }
        #[julia] pub fn run() -> i32 { 0 }
    "#;
    let m = extract(src, Mode::Crate).unwrap();
    let mut symbols: Vec<String> = m.functions.iter().map(|f| f.symbol.clone()).collect();
    symbols.sort();
    assert_eq!(
        symbols,
        vec!["rustcall_a__run", "rustcall_b__run", "rustcall_run"]
    );
    let in_a = m
        .functions
        .iter()
        .find(|f| f.module_path == path(&["a"]))
        .unwrap();
    assert_eq!(in_a.ffi_name, "a__run");

    // The same block without the marker on `b`.
    let unmarked = src.replace("#[julia] pub mod b", "pub mod b");
    let err = extract(&unmarked, Mode::Crate).unwrap_err();
    assert!(matches!(err, ExtractError::Unsupported(_)), "{err}");
    let msg = err.to_string();
    assert!(msg.contains("`run`"), "{msg}");
    assert!(msg.contains("inline module `b`"), "{msg}");
    assert!(msg.contains("#[julia] pub mod b"), "{msg}");

    // A nested unmarked module below a marked one is refused as well, and a
    // parse failure stays a parse failure so the CLI can still skip fragments.
    let nested = "#[julia] pub mod a { pub mod inner { #[julia] pub fn f() {} } }";
    let err = extract(nested, Mode::Crate).unwrap_err();
    assert!(
        err.to_string().contains("inline module `a::inner`"),
        "{err}"
    );
    assert!(matches!(
        extract("fn (", Mode::Crate).unwrap_err(),
        ExtractError::Parse(_)
    ));
}

/// The inline and crate flavours agree symbol for symbol on the same items.
#[test]
fn inline_and_crate_flavours_agree() {
    let src = r#"
        #[julia] pub mod a {
            #[julia] pub fn run() -> i32 { 1 }
            #[julia] pub struct C { pub v: i32, pub label: String }
            #[julia] impl C {
                #[julia] pub fn new(v: i32) -> Self { Self { v, label: String::new() } }
                #[julia] pub fn get(&self) -> i32 { self.v }
            }
        }
    "#;
    let inline = rustcall_core::expand::expand(src).unwrap().manifest;
    let krate = extract(src, Mode::Crate).unwrap();
    assert_eq!(inline.functions[0].symbol, krate.functions[0].symbol);
    assert_eq!(inline.functions[0].ffi_name, krate.functions[0].ffi_name);
    let (si, sk) = (&inline.structs[0], &krate.structs[0]);
    assert_eq!(si.ffi_name, "a__C");
    assert_eq!(si.ffi_name, sk.ffi_name);
    assert_eq!(si.module_path, sk.module_path);
    let methods = |s: &rustcall_core::manifest::Struct| {
        let mut v: Vec<String> = s.methods.iter().map(|m| m.symbol.clone()).collect();
        v.sort();
        v
    };
    assert_eq!(methods(si), methods(sk));
    assert_eq!(methods(si), vec!["rustcall_a__C_get", "rustcall_a__C_new"]);
    let accessors = |s: &rustcall_core::manifest::Struct| {
        let mut v: Vec<String> = s
            .fields
            .iter()
            .flat_map(|f| [f.getter.clone(), f.setter.clone()])
            .filter(|s| !s.is_empty())
            .collect();
        v.sort();
        v
    };
    assert_eq!(accessors(si), accessors(sk));
    assert_eq!(
        accessors(si),
        vec![
            "a__C_get_label",
            "a__C_get_v",
            "a__C_set_label",
            "a__C_set_v"
        ]
    );
}

/// A specialized generic instantiation is placed in the generic's module and
/// carries that module's path in its symbol.
#[test]
fn specialized_flavour() {
    let src = "mod api { pub fn twice<T: std::ops::Add<Output = T> + Copy>(x: T) -> T { x + x } }";
    let out = rustcall_core::specialize::specialize(
        src,
        "api::twice",
        &[("T".to_string(), "i32".to_string())],
        "twice_i32",
    )
    .unwrap();
    let f = &out.manifest.functions[0];
    assert_eq!(f.module_path, path(&["api"]));
    assert_eq!(f.ffi_name, "api__twice_0i32");
    assert_eq!(f.symbol, "rustcall_api__twice_0i32");
    assert!(out
        .source
        .contains("pub extern \"C\" fn rustcall_api__twice_0i32(x: i32) -> i32"));

    // At the crate root the instantiation keeps the bare name.
    let root = rustcall_core::specialize::specialize(
        "pub fn twice<T: std::ops::Add<Output = T> + Copy>(x: T) -> T { x + x }",
        "twice",
        &[("T".to_string(), "i32".to_string())],
        "twice_i32",
    )
    .unwrap();
    assert_eq!(root.manifest.functions[0].symbol, "rustcall_twice_i32");
    assert_eq!(root.manifest.functions[0].ffi_name, "twice_i32");
}

/// The crate-wide duplicate check: what the scheme cannot keep apart is
/// reported, what it does keep apart is not, and undecided `#[cfg]` variants
/// are never a clash.
#[test]
fn symbol_owners_feed_the_duplicate_check() {
    let m = extract(
        r#"
            #[julia] pub mod a { #[julia] pub fn run() -> i32 { 1 } }
            #[julia] pub fn a__run() -> i32 { 2 }
            #[cfg(unix)] #[julia] pub fn portable() -> i32 { 1 }
            #[cfg(windows)] #[julia] pub fn portable() -> i32 { 2 }
            #[julia] pub struct C { pub v: i32 }
            #[julia] impl C { #[julia] pub fn get(&self) -> i32 { self.v } }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let owners = m.symbol_owners();
    let claims = |symbol: &str| owners.iter().filter(|(s, _)| s == symbol).count();
    assert_eq!(claims("rustcall_a__run"), 2, "{owners:?}");
    assert_eq!(claims("rustcall_portable"), 0, "cfg variants are left out");
    assert_eq!(claims("C_free"), 1);
    assert_eq!(claims("C_get_v"), 1);
    assert_eq!(claims("C_set_v"), 1);
    assert_eq!(claims("rustcall_C_get"), 1);
    let (_, who) = owners.iter().find(|(s, _)| s == "rustcall_a__run").unwrap();
    assert!(
        who.contains("`a::run`") || who.contains("`a__run`"),
        "{who}"
    );
}

/// The PyO3 wrapper generator names the destructor and the string helpers
/// after the manifest's `ffi_name`, so two `#[pyclass] C` in different modules
/// build into one wrapper crate.
#[test]
fn pyo3_wrapper_flavour() {
    let src = r#"
        pub mod a {
            #[pyclass] pub struct C { #[pyo3(get)] pub v: i32 }
            #[pymethods] impl C { pub fn name(&self) -> String { String::new() } }
        }
        pub mod b {
            #[pyclass] pub struct C { #[pyo3(get)] pub v: i32 }
            #[pymethods] impl C { pub fn name(&self) -> String { String::new() } }
        }
    "#;
    let scanned = extract(src, Mode::Crate).unwrap();
    let wrapper = rustcall_core::wrap::wrapper_crate(&scanned, "user_crate", true);
    for needle in [
        "pub extern \"C\" fn a__C_free(ptr: *mut user_crate::a::C)",
        "pub extern \"C\" fn b__C_free(ptr: *mut user_crate::b::C)",
        "pub extern \"C\" fn rustcall_a__C_get_v(",
        "pub extern \"C\" fn rustcall_b__C_get_v(",
        "pub extern \"C\" fn rustcall_a__C_name(",
        "pub extern \"C\" fn rustcall_b__C_name(",
        "a__C_name_free_rust_string",
        "b__C_name_free_rust_string",
    ] {
        assert!(
            wrapper.lib_rs.contains(needle),
            "{needle} missing from\n{}",
            wrapper.lib_rs
        );
    }
    let skipped: Vec<_> = wrapper
        .manifest
        .structs
        .iter()
        .filter(|s| !s.skip_reason.is_empty())
        .collect();
    assert!(skipped.is_empty(), "{skipped:?}");
    assert!(!wrapper.manifest.structs.iter().any(|s| s
        .methods
        .iter()
        .any(|m| m.skip_reason.starts_with("symbol_collision"))),);
}
