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
    assert_eq!(claims("rustcall_a__run"), 1, "{owners:?}");
    assert_eq!(claims("rustcall_portable"), 0, "cfg variants are left out");
    assert_eq!(claims("C_free"), 1);
    assert_eq!(claims("C_get_v"), 1);
    assert_eq!(claims("C_set_v"), 1);
    assert_eq!(claims("rustcall_C_get"), 1);
    let (_, who) = owners.iter().find(|(s, _)| s == "rustcall_a__run").unwrap();
    assert!(who.contains("`a::run`"), "{who}");
}

/// The release function of an owned-string buffer is a `#[no_mangle]` export
/// like any other, so it is claimed too — once however many items share the
/// buffer (#342 review). The buffer *types* are not symbols, and a borrowed
/// `&str` view exports nothing at all.
#[test]
fn owned_string_buffers_are_claimed_once_each() {
    let m = extract(
        r#"
            #[julia] pub fn shout(s: &str) -> String { s.to_uppercase() }
            #[julia] pub fn peek() -> &'static str { "hi" }
            #[julia] pub struct Tag { pub name: String }
            #[julia] impl Tag {
                #[julia] pub fn label(&self) -> String { self.name.clone() }
                #[julia] pub fn size(&self) -> i32 { 0 }
            }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let owners = m.symbol_owners();
    let claims = |symbol: &str| owners.iter().filter(|(s, _)| s == symbol).count();
    assert_eq!(claims("shout_free_rust_string"), 1, "{owners:?}");
    assert_eq!(
        claims("peek_free_rust_string"),
        0,
        "a borrowed `&str` owns nothing"
    );
    // The struct's own buffer, for the `String` field getter, and the crate
    // flavour's per-method one.
    assert_eq!(claims("Tag_free_rust_string"), 1, "{owners:?}");
    assert_eq!(claims("Tag_label_free_rust_string"), 1, "{owners:?}");
    assert_eq!(claims("Tag_size_free_rust_string"), 0);
    assert!(
        m.duplicate_symbols().is_empty(),
        "{:?}",
        m.duplicate_symbols()
    );
}

/// An inline method wrapped next to its struct *shares* the struct's buffer,
/// so the two must not claim `<Struct>_free_rust_string` twice (#342).
#[test]
fn a_shared_inline_buffer_is_not_a_duplicate() {
    let inline = rustcall_core::expand::expand(
        r#"
        #[julia] pub struct Tag { pub name: String }
        impl Tag {
            pub fn label(&self) -> String { self.name.clone() }
            pub fn other(&self) -> String { self.name.clone() }
        }
        "#,
    )
    .unwrap();
    let owners = inline.manifest.symbol_owners();
    assert_eq!(
        owners
            .iter()
            .filter(|(s, _)| s == "Tag_free_rust_string")
            .count(),
        1,
        "{owners:?}"
    );
    assert!(
        inline.manifest.duplicate_symbols().is_empty(),
        "{:?}",
        inline.manifest.duplicate_symbols()
    );
    assert!(
        !inline.source.contains("compile_error"),
        "{}",
        inline.source
    );
}

/// A crate-root `fn a__run` spells the symbol of `a::run`: the one coincidence
/// the encoding cannot exclude. The scan refuses it with both owners instead
/// of describing a `cdylib` that could not be linked — within one file as
/// much as across files (#300, #315).
#[test]
fn a_duplicate_symbol_fails_extraction_with_both_owners() {
    let err = extract(
        r#"
            #[julia] pub mod a { #[julia] pub fn run() -> i32 { 1 } }
            #[julia] pub fn a__run() -> i32 { 2 }
        "#,
        Mode::Crate,
    )
    .expect_err("a duplicate exported symbol must fail the scan")
    .to_string();
    assert!(
        err.contains("duplicate exported symbol `rustcall_a__run`"),
        "{err}"
    );
    assert!(err.contains("`a::run` (line 2)"), "{err}");
    assert!(err.contains("`a__run` (line 3)"), "{err}");
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

/// A bare `#[julia] impl C` at the crate root for a struct in `#[julia] mod a`:
/// the proc-macro would export `rustcall_C_run` while the struct's symbols
/// are `a__C`'s, so crate extraction refuses it and spells the header that
/// agrees (`impl crate::a::C`); next to the struct, and through that header,
/// the method is wrapped under the struct's stem (#300 review, #315).
#[test]
fn an_impl_the_macro_would_qualify_differently_is_refused() {
    let src = r#"
        #[julia] pub mod a { #[julia] pub struct C { pub v: i32 } }
        use a::C;
        #[julia] impl C { #[julia] pub fn run(&self) -> i32 { self.v } }
    "#;
    let err = extract(src, Mode::Crate).unwrap_err();
    assert!(matches!(err, ExtractError::Unsupported(_)), "{err}");
    let msg = err.to_string();
    assert!(msg.contains("`impl C` (line 4)"), "{msg}");
    assert!(msg.contains("`rustcall_C_<method>`"), "{msg}");
    assert!(msg.contains("has the FFI name `a__C`"), "{msg}");
    assert!(
        msg.contains("write the header as `impl crate::a::C`"),
        "{msg}"
    );
    // Next to the struct it is wrapped under the struct's stem ...
    let ok = extract(
        "#[julia] pub mod a { #[julia] pub struct C { pub v: i32 } \
         #[julia] impl C { #[julia] pub fn run(&self) -> i32 { self.v } } }",
        Mode::Crate,
    )
    .unwrap();
    assert_eq!(ok.structs[0].methods[0].symbol, "rustcall_a__C_run");
    // ... and so is a block anywhere else whose header spells the path.
    let ok = extract(
        "#[julia] pub mod a { #[julia] pub struct C { pub v: i32 } } \
         #[julia] impl crate::a::C { #[julia] pub fn run(&self) -> i32 { self.v } }",
        Mode::Crate,
    )
    .unwrap();
    assert_eq!(ok.structs[0].methods[0].symbol, "rustcall_a__C_run");
}

/// Every wrapper exports its panic-channel reader next to itself
/// (`<symbol>_take_panic`, `crate::codegen::panic_channel`), so that reader is
/// a claimed symbol like any other — for free functions and for struct
/// methods alike (#338).
#[test]
fn panic_readers_are_claimed_symbols() {
    let m = extract(
        r#"
            #[julia] pub mod a { #[julia] pub fn run() -> i32 { 1 } }
            #[julia] pub struct C { pub v: i32 }
            #[julia] impl C { #[julia] pub fn get(&self) -> i32 { self.v } }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let owners = m.symbol_owners();
    let claims = |symbol: &str| owners.iter().filter(|(s, _)| s == symbol).count();
    assert_eq!(claims("rustcall_a__run_take_panic"), 1, "{owners:?}");
    assert_eq!(claims("rustcall_C_get_take_panic"), 1, "{owners:?}");
    // The ones the struct already claimed keep their single claim.
    assert_eq!(claims("C_free_take_panic"), 1, "{owners:?}");
    assert_eq!(claims("C_get_v_take_panic"), 1, "{owners:?}");
    // A string release function has no `catch_unwind` boundary and so no
    // reader (`crate::codegen::owned_string_helper`).
    assert_eq!(claims("C_free_rust_string_take_panic"), 0, "{owners:?}");
    assert!(
        m.duplicate_symbols().is_empty(),
        "{:?}",
        m.duplicate_symbols()
    );
}

/// A crate-root `#[julia] fn a__run_take_panic` spells the panic reader of
/// `a::run`. The wrappers differ, so only the derived symbols collide — the
/// case `symbol_owners` used to miss, letting two `#[no_mangle]` items of one
/// name reach the linker (#338).
#[test]
fn a_duplicate_panic_reader_fails_extraction_with_both_owners() {
    let err = extract(
        r#"
            #[julia] pub mod a { #[julia] pub fn run() -> i32 { 1 } }
            #[julia] pub fn a__run_take_panic() -> i32 { 2 }
        "#,
        Mode::Crate,
    )
    .expect_err("a duplicate panic reader must fail the scan")
    .to_string();
    assert!(
        err.contains("duplicate exported symbol `rustcall_a__run_take_panic`"),
        "{err}"
    );
    assert!(err.contains("`a::run` (line 2)"), "{err}");
    assert!(err.contains("`a__run_take_panic` (line 3)"), "{err}");
}

/// The same coincidence against a struct method's reader.
#[test]
fn a_duplicate_method_panic_reader_fails_extraction() {
    let err = extract(
        r#"
            #[julia] pub struct C { pub v: i32 }
            #[julia] impl C { #[julia] pub fn get(&self) -> i32 { self.v } }
            #[julia] pub fn C_get_take_panic() -> i32 { 0 }
        "#,
        Mode::Crate,
    )
    .expect_err("a duplicate method panic reader must fail the scan")
    .to_string();
    assert!(
        err.contains("duplicate exported symbol `rustcall_C_get_take_panic`"),
        "{err}"
    );
}

/// Inline expansion asks the same question of the manifest it just built, so
/// a `rust"""` block with the same coincidence fails with a `compile_error!`
/// naming both items rather than with rustc's duplicate-symbol diagnostic
/// pointing into generated code (#338, #342).
#[test]
fn an_inline_duplicate_panic_reader_is_a_compile_error() {
    let inline = rustcall_core::expand::expand(
        r#"
        #[julia] pub mod a { #[julia] pub fn run() -> i32 { 1 } }
        #[julia] pub fn a__run_take_panic() -> i32 { 2 }
        "#,
    )
    .unwrap();
    let dups = inline.manifest.duplicate_symbols();
    assert_eq!(dups.len(), 1, "{dups:?}");
    assert_eq!(dups[0].0, "rustcall_a__run_take_panic");
    assert!(inline.source.contains("compile_error"), "{}", inline.source);
    assert!(
        inline.source.contains("rustcall_a__run_take_panic"),
        "{}",
        inline.source
    );
}

/// A plain `#[no_mangle] extern "C"` function is reported so Julia can
/// register its return type, but RustCall generates nothing for it: it is
/// exported under its own name and has no panic channel. A hand-written
/// destructor and its hand-written channel — the shape `resolve_call_target`
/// is tested against — are therefore two unrelated exports, not a collision
/// (#338).
#[test]
fn a_hand_written_function_claims_only_its_own_name() {
    let inline = rustcall_core::expand::expand(
        r#"
        #[julia] pub fn value() -> i32 { 111 }
        #[no_mangle] pub extern "C" fn release() {}
        #[no_mangle] pub extern "C" fn release_take_panic(_out: *mut u8, _cap: usize) -> usize { 0 }
        "#,
    )
    .unwrap();
    let owners = inline.manifest.symbol_owners();
    let claims = |symbol: &str| owners.iter().filter(|(s, _)| s == symbol).count();
    assert_eq!(claims("release"), 1, "{owners:?}");
    assert_eq!(claims("release_take_panic"), 1, "{owners:?}");
    // The `#[julia]` item next to them keeps both of its own exports.
    assert_eq!(claims("rustcall_value"), 1, "{owners:?}");
    assert_eq!(claims("rustcall_value_take_panic"), 1, "{owners:?}");
    assert!(
        inline.manifest.duplicate_symbols().is_empty(),
        "{:?}",
        inline.manifest.duplicate_symbols()
    );
    assert!(
        !inline.source.contains("compile_error"),
        "{}",
        inline.source
    );
}

/// The converse: a hand-written `#[no_mangle]` function that spells the panic
/// reader a `#[julia]` wrapper generates *is* a collision, and is reported
/// against the item that generates it.
#[test]
fn a_hand_written_name_may_still_collide_with_a_generated_reader() {
    let inline = rustcall_core::expand::expand(
        r#"
        #[julia] pub fn value() -> i32 { 111 }
        #[no_mangle] pub extern "C" fn rustcall_value_take_panic(_out: *mut u8, _cap: usize) -> usize { 0 }
        "#,
    )
    .unwrap();
    let dups = inline.manifest.duplicate_symbols();
    assert_eq!(dups.len(), 1, "{dups:?}");
    assert_eq!(dups[0].0, "rustcall_value_take_panic");
    assert!(inline.source.contains("compile_error"), "{}", inline.source);
}

/// Both scans derive what an entry claims from one function (#338). The
/// `#[julia]` duplicate check and the PyO3 collision analysis read the same
/// list; they differ only in the two respects `claims::Policy` spells out —
/// whether module-private names count, and whether the string helpers are
/// taken as declared or reserved because the wrapper crate has not been
/// generated yet.
#[test]
fn both_scans_read_one_claim_list() {
    use rustcall_core::claims::{function_claims, struct_claims, Policy};

    let m = extract(
        r#"
            #[julia] pub fn shout(s: &str) -> String { s.to_uppercase() }
            #[julia] pub fn peek() -> &'static str { "hi" }
            #[julia] pub struct Tag { pub name: String }
            #[julia] impl Tag { #[julia] pub fn label(&self) -> String { self.name.clone() } }
        "#,
        Mode::Crate,
    )
    .unwrap();

    let names = |claims: Vec<rustcall_core::claims::Claim>| {
        let mut out: Vec<String> = claims.into_iter().map(|c| c.name).collect();
        out.sort();
        out
    };

    let shout = m.functions.iter().find(|f| f.name == "shout").unwrap();
    assert_eq!(
        names(function_claims(shout, Policy::JULIA)),
        vec![
            "__RUSTCALL_PANIC_RUSTCALL_SHOUT".to_string(),
            "rustcall_shout".to_string(),
            "rustcall_shout_take_panic".to_string(),
            "shout_RustCallOwnedString".to_string(),
            "shout_free_rust_string".to_string(),
        ]
    );
    // Both policies count the private panic slot. They part company on the
    // string helpers only: `shout` returns an owned `String`, so as declared
    // it never declares a borrowed view, while the scan reserves that name
    // too because the wrapper crate has not chosen yet.
    let reserved = names(function_claims(shout, Policy::PYO3_SCAN));
    assert!(reserved.contains(&"__RUSTCALL_PANIC_RUSTCALL_SHOUT".to_string()));
    assert!(reserved.contains(&"shout_RustCallBorrowedString".to_string()));
    assert!(!names(function_claims(shout, Policy::JULIA))
        .contains(&"shout_RustCallBorrowedString".to_string()));
    let mut exported: Vec<String> = m
        .symbol_owners()
        .into_iter()
        .filter(|(_, who)| who.contains("`shout`"))
        .map(|(s, _)| s)
        .collect();
    exported.sort();
    assert_eq!(
        exported,
        vec![
            "rustcall_shout".to_string(),
            "rustcall_shout_take_panic".to_string(),
            "shout_free_rust_string".to_string(),
        ]
    );

    // A borrowed `&str` owns nothing, so as declared it claims no release
    // function; the scan still reserves the name because the wrapper crate
    // has not chosen yet.
    let peek = m.functions.iter().find(|f| f.name == "peek").unwrap();
    assert!(
        !names(function_claims(peek, Policy::JULIA)).contains(&"peek_free_rust_string".to_string())
    );
    assert!(names(function_claims(peek, Policy::JULIA))
        .contains(&"peek_RustCallBorrowedString".to_string()));
    assert!(names(function_claims(peek, Policy::PYO3_SCAN))
        .contains(&"peek_free_rust_string".to_string()));

    // The struct's claims come from the same place, and `symbol_owners` is
    // that list with an owner attached.
    let tag = m.structs.iter().find(|s| s.name == "Tag").unwrap();
    let from_claims = names(
        struct_claims(tag, Policy::JULIA)
            .into_iter()
            .filter(|c| c.exported)
            .collect(),
    );
    let mut from_owners: Vec<String> = m
        .symbol_owners()
        .into_iter()
        .filter(|(_, who)| who.contains("`Tag`"))
        .map(|(s, _)| s)
        .collect();
    from_owners.sort();
    assert_eq!(from_claims, from_owners);
}

/// The PyO3 scan keeps a `#[cfg]`-gated entry in its table, with the
/// predicate, and decides with `cfg_exclusive` whether two claimants can ever
/// be compiled together. The `#[julia]` duplicate check drops them instead: it
/// has nowhere to record a predicate, and two variants of one function under
/// mutually exclusive predicates are the normal shape of a portable crate, not
/// a clash (#338).
#[test]
fn the_two_policies_disagree_about_cfg_gated_entries() {
    use rustcall_core::claims::{function_claims, Policy};

    let m = extract(
        r#"
            #[cfg(unix)] #[julia] pub fn portable() -> i32 { 1 }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let gated = &m.functions[0];
    assert!(!gated.cfg.is_empty(), "{gated:?}");
    assert!(function_claims(gated, Policy::JULIA).is_empty());
    assert!(!function_claims(gated, Policy::PYO3_SCAN).is_empty());
    // ... which is why the crate-wide check leaves it out entirely.
    assert!(!m
        .symbol_owners()
        .iter()
        .any(|(s, _)| s == "rustcall_portable"));
}

/// A struct helper — the destructor, `clone`, a field accessor — writes a
/// panic slot named by hex-encoding its symbol (`guard_struct_helper`), not by
/// upper-casing it the way a function or method wrapper does. The encoding is
/// injective, so two helpers share a slot only when they already share their
/// exported symbol, and nothing claims it. A wrapper's slot is not injective
/// and is claimed under the scan policy (#338).
#[test]
fn helper_slots_are_injective_and_unclaimed() {
    use rustcall_core::claims::{helper_panic_slot, panic_slot, struct_claims, Policy};

    assert_eq!(panic_slot("rustcall_foo"), panic_slot("rustcall_FOO"));
    assert_ne!(
        helper_panic_slot("Bag_get_x"),
        helper_panic_slot("Bag_get_X")
    );

    let m = extract(
        r#"
            #[julia] #[derive(Clone)] pub struct Bag { pub v: i32 }
            #[julia] impl Bag { #[julia] pub fn get(&self) -> i32 { self.v } }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let names: Vec<String> = struct_claims(&m.structs[0], Policy::JULIA)
        .into_iter()
        .map(|c| c.name)
        .collect();
    // The method wrapper's slot is claimed ...
    assert!(names.contains(&panic_slot("rustcall_Bag_get")), "{names:?}");
    // ... the destructor's and the accessor's are not, under either spelling.
    for symbol in ["Bag_free", "Bag_get_v"] {
        assert!(!names.contains(&panic_slot(symbol)), "{names:?}");
        assert!(!names.contains(&helper_panic_slot(symbol)), "{names:?}");
        assert!(names.contains(&symbol.to_string()), "{names:?}");
    }
}

/// `#[julia] fn foo` next to `#[julia] fn FOO` export two different symbols,
/// so nothing about the exports collides — but both wrappers name their panic
/// slot by upper-casing that symbol, so the crate defines
/// `__RUSTCALL_PANIC_RUSTCALL_FOO` twice. rustc would report it inside
/// generated code; the scan refuses first, and says the name is an internal
/// item rather than calling it an export (#338).
#[test]
fn a_duplicate_panic_slot_fails_extraction_as_an_internal_item() {
    let err = extract(
        r#"
            #[julia] pub fn foo() -> i32 { 1 }
            #[julia] pub fn FOO() -> i32 { 2 }
        "#,
        Mode::Crate,
    )
    .expect_err("two wrappers sharing a panic slot must fail the scan")
    .to_string();
    assert!(
        err.contains("duplicate generated item `__RUSTCALL_PANIC_RUSTCALL_FOO`"),
        "{err}"
    );
    assert!(!err.contains("duplicate exported symbol"), "{err}");
    assert!(err.contains("`foo` (line 2)"), "{err}");
    assert!(err.contains("`FOO` (line 3)"), "{err}");
    // The message explains a name the user never wrote.
    assert!(err.contains("upper-casing the wrapper's symbol"), "{err}");
    assert!(err.contains("#338"), "{err}");
}

/// The same block inline: a `compile_error!` naming both items, with the
/// wording for an internal item.
#[test]
fn an_inline_duplicate_panic_slot_is_a_compile_error() {
    let inline = rustcall_core::expand::expand(
        r#"
        #[julia] pub fn foo() -> i32 { 1 }
        #[julia] pub fn FOO() -> i32 { 2 }
        "#,
    )
    .unwrap();
    let dups = inline.manifest.duplicate_claims();
    assert_eq!(dups.len(), 1, "{dups:?}");
    assert_eq!(dups[0].0.name, "__RUSTCALL_PANIC_RUSTCALL_FOO");
    assert!(!dups[0].0.exported);
    // The exported projection sees nothing: the two wrappers differ.
    assert!(inline.manifest.duplicate_symbols().is_empty());
    assert!(
        inline
            .source
            .contains("would define the item `__RUSTCALL_PANIC_RUSTCALL_FOO` twice"),
        "{}",
        inline.source
    );
    assert!(
        !inline.source.contains("would export the symbol"),
        "{}",
        inline.source
    );
}

/// An exported clash keeps the wording it had: a reader can look the name up
/// in the naming scheme, and the exported name is reported even though the
/// private item derived from it collides too.
#[test]
fn an_exported_clash_is_still_reported_as_an_export() {
    let err = extract(
        r#"
            #[julia] pub mod a { #[julia] pub fn run() -> i32 { 1 } }
            #[julia] pub fn a__run() -> i32 { 2 }
        "#,
        Mode::Crate,
    )
    .expect_err("a duplicate exported symbol must fail the scan")
    .to_string();
    assert!(
        err.contains("duplicate exported symbol `rustcall_a__run`"),
        "{err}"
    );
    assert!(!err.contains("duplicate generated item"), "{err}");
}

/// A private name only has to be unique in the module the wrapper is emitted
/// into. `mod a { fn foo }` and `mod A { fn FOO }` export two different
/// symbols and spell one slot name, but the two slots are in different Rust
/// modules and both compile — so this is not a duplicate (#338 review).
#[test]
fn private_names_are_compared_within_their_module() {
    let src = r#"
        #[julia] pub mod a { #[julia] pub fn foo() -> i32 { 1 } }
        #[julia] pub mod A { #[julia] pub fn FOO() -> i32 { 2 } }
    "#;
    let inline = rustcall_core::expand::expand(src).unwrap();
    assert!(
        inline.manifest.duplicate_claims().is_empty(),
        "{:?}",
        inline.manifest.duplicate_claims()
    );
    assert!(
        !inline.source.contains("compile_error"),
        "{}",
        inline.source
    );
    // The crate scan agrees.
    extract(src, Mode::Crate).expect("two modules may spell one slot name");

    // Within *one* module they really do meet.
    let same = rustcall_core::expand::expand(
        r#"
        #[julia] pub mod a {
            #[julia] pub fn foo() -> i32 { 1 }
            #[julia] pub fn FOO() -> i32 { 2 }
        }
        "#,
    )
    .unwrap();
    let dups = same.manifest.duplicate_claims();
    assert_eq!(dups.len(), 1, "{dups:?}");
    assert!(!dups[0].0.exported);
}

/// Rust keeps types and values apart, so a generated buffer *type* and an
/// exported *function* of one spelling may coexist. Comparing names alone
/// refused a crate that builds (#338 review).
#[test]
fn claims_are_compared_within_their_rust_namespace() {
    use rustcall_core::claims::Namespace;

    let m = extract(
        r#"
            #[julia] pub fn peek() -> &'static str { "hi" }
        "#,
        Mode::Crate,
    )
    .unwrap();
    let claims = m.claim_owners();
    let view = claims
        .iter()
        .find(|(c, _)| c.name == "peek_RustCallBorrowedString")
        .expect("a borrowed `&str` declares its view type");
    assert_eq!(view.0.namespace, Namespace::Type);
    assert!(!view.0.exported);

    let wrapper = claims
        .iter()
        .find(|(c, _)| c.name == "rustcall_peek")
        .unwrap();
    assert_eq!(wrapper.0.namespace, Namespace::Value);

    // A second function spelling the view type's name is a value, so the two
    // do not meet.
    let both = extract(
        r#"
            #[julia] pub fn peek() -> &'static str { "hi" }
            #[no_mangle] pub extern "C" fn peek_RustCallBorrowedString() -> i32 { 0 }
        "#,
        Mode::Crate,
    );
    assert!(both.is_ok(), "{:?}", both.err());
}
