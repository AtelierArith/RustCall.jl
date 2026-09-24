//! A crate trait impl's `#[julia]` methods are described and named apart
//! (#506).
//!
//! The crate scan used to skip trait impls (`ImplHeader::of`), so the
//! methods the proc macro wrapped were never in the manifest and `@rust_crate`
//! bound none of them; and a trait method exported the symbol an inherent
//! method of the same name exports, so an inherent `m` and `m` of a trait —
//! or `m` of two traits — on one struct defined `rustcall_Buf_m` twice. Every
//! per-method name now hangs off one method stem
//! (`codegen::method_stem`): the name for an inherent method, the
//! length-prefixed trait ahead of it for a trait's (`3Far_m`). The manifest
//! describes every trait method with its `trait_path`, its symbol and, when
//! its name is shared, the Julia name it is bound under (`Far_m`).

use std::{fs, process::Command};

mod support;

use quote::quote;
use rustcall_julia_core::codegen::{method_stem, transform_impl_crate, transform_struct_crate};
use rustcall_julia_core::extract::extract;
use rustcall_julia_core::manifest::{Method, Mode};

const CRATE: &str = r#"
    pub mod tr {
        pub trait A {
            fn m(&self) -> i32;
            fn make() -> i32;
            fn build(n: i32) -> Self;
        }
    }
    pub trait B {
        fn m(&mut self, by: i32) -> i32;
        fn only_b(&self) -> i32;
    }

    #[julia]
    pub struct Buf { pub n: i32 }

    #[julia]
    impl Buf {
        #[julia]
        pub fn new(n: i32) -> Self { Buf { n } }
        #[julia]
        pub fn m(&self) -> i32 { self.n }
        #[julia]
        pub fn make() -> i32 { 1 }
    }

    #[julia]
    impl tr::A for Buf {
        #[julia]
        fn m(&self) -> i32 { self.n * 10 }
        #[julia]
        fn make() -> i32 { 2 }
        #[julia]
        fn build(n: i32) -> Self { Buf { n: n + 100 } }
    }

    #[julia]
    impl B for Buf {
        #[julia]
        fn m(&mut self, by: i32) -> i32 { self.n += by; self.n * 100 }
        #[julia]
        fn only_b(&self) -> i32 { self.n + 7 }
    }
"#;

fn method<'a>(methods: &'a [Method], trait_path: &str, name: &str) -> &'a Method {
    methods
        .iter()
        .find(|m| m.trait_path == trait_path && m.name == name)
        .unwrap_or_else(|| panic!("no `{trait_path}::{name}` in {methods:#?}"))
}

#[test]
fn the_method_stem_tells_every_trait_apart() {
    assert_eq!(method_stem(None, "m"), "m");
    assert_eq!(method_stem(Some("Far"), "m"), "3Far_m");
    assert_eq!(method_stem(Some("r#Far"), "r#m"), "3Far_m");
    // No inherent name starts with a digit, and the prefix splits the pair:
    // (`Ab`, `c_d`) and (`Ab_c`, `d`) differ.
    assert_ne!(
        method_stem(Some("Ab"), "c_d"),
        method_stem(Some("Ab_c"), "d")
    );
}

#[test]
fn every_trait_method_is_described_with_its_own_symbol_and_julia_name() {
    let manifest = extract(CRATE, Mode::Crate).unwrap();
    let buf = &manifest.structs[0];
    let expect = [
        // (trait, name, symbol, julia_name, is_static, is_mutable, is_constructor)
        ("", "m", "rustcall_Buf_m", "", false, false, false),
        ("", "make", "rustcall_Buf_make", "", true, false, false),
        ("", "new", "rustcall_Buf_new", "", true, false, true),
        (
            "tr::A",
            "m",
            "rustcall_Buf_1A_m",
            "A_m",
            false,
            false,
            false,
        ),
        (
            "tr::A",
            "make",
            "rustcall_Buf_1A_make",
            "A_make",
            true,
            false,
            false,
        ),
        // A trait's `Self`-returning function keeps its name rather than
        // becoming the struct's constructor, whose `Buf(n)` it would shadow.
        (
            "tr::A",
            "build",
            "rustcall_Buf_1A_build",
            "",
            true,
            false,
            false,
        ),
        ("B", "m", "rustcall_Buf_1B_m", "B_m", false, true, false),
        (
            "B",
            "only_b",
            "rustcall_Buf_1B_only_b",
            "",
            false,
            false,
            false,
        ),
    ];
    assert_eq!(buf.methods.len(), expect.len(), "{:#?}", buf.methods);
    for (trait_path, name, symbol, julia_name, is_static, is_mutable, is_constructor) in expect {
        let m = method(&buf.methods, trait_path, name);
        assert_eq!(m.symbol, symbol, "{trait_path}::{name}");
        assert_eq!(m.julia_name, julia_name, "{trait_path}::{name}");
        assert_eq!(m.is_static, is_static, "{trait_path}::{name}");
        assert_eq!(m.is_mutable, is_mutable, "{trait_path}::{name}");
        assert_eq!(m.is_constructor, is_constructor, "{trait_path}::{name}");
        assert!(m.skip_reason.is_empty(), "{trait_path}::{name}");
        // The string owner hangs off the same stem as the symbol.
        assert_eq!(
            m.string_owner,
            symbol.trim_start_matches("rustcall_"),
            "{trait_path}::{name}"
        );
    }
    assert!(method(&buf.methods, "tr::A", "build").returns_boxed_struct);
}

fn proc_macro_expansion(source: &str) -> String {
    let file: syn::File = syn::parse_str(source).unwrap();
    let mut out = proc_macro2::TokenStream::new();
    for item in file.items {
        out.extend(match item {
            syn::Item::Struct(mut s) if s.attrs.iter().any(|a| a.path().is_ident("julia")) => {
                s.attrs.retain(|a| !a.path().is_ident("julia"));
                transform_struct_crate(s, &[])
            }
            syn::Item::Impl(mut i) if i.attrs.iter().any(|a| a.path().is_ident("julia")) => {
                i.attrs.retain(|a| !a.path().is_ident("julia"));
                transform_impl_crate(i, &[])
            }
            other => quote!(#other),
        });
    }
    out.to_string()
}

#[test]
fn the_manifest_symbols_are_the_ones_the_proc_macro_exports() {
    // Compiled and called: every symbol the manifest names exists, and each
    // reaches its own method.
    let expansion = proc_macro_expansion(CRATE);
    let manifest = extract(CRATE, Mode::Crate).unwrap();
    for m in &manifest.structs[0].methods {
        assert!(
            expansion.contains(&format!("fn {} (", m.symbol)),
            "{} is not exported: {expansion}",
            m.symbol
        );
    }
    let main = r#"
        fn main() {
            unsafe {
                let p = rustcall_Buf_new(3);
                assert_eq!(rustcall_Buf_m(p).assume_init(), 3);
                assert_eq!(rustcall_Buf_1A_m(p).assume_init(), 30);
                assert_eq!(rustcall_Buf_1B_m(p, 2).assume_init(), 500);
                assert_eq!((*p).n, 5);
                assert_eq!(rustcall_Buf_1B_only_b(p).assume_init(), 12);
                assert_eq!(rustcall_Buf_make().assume_init(), 1);
                assert_eq!(rustcall_Buf_1A_make().assume_init(), 2);
                let built = rustcall_Buf_1A_build(1);
                assert_eq!((*built).n, 101);
                Buf_free(built);
                Buf_free(p);
            }
        }
    "#;
    let dir = std::env::temp_dir().join(format!("rustcall_trait_methods_{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let input = dir.join("probe.rs");
    let binary = dir.join(format!("probe{}", std::env::consts::EXE_SUFFIX));
    fs::write(
        &input,
        format!("#![allow(non_snake_case, dead_code, improper_ctypes_definitions)]\n{expansion}\n{main}"),
    )
    .unwrap();
    let compile = Command::new("rustc")
        .args(["--edition=2021", "-C", "panic=unwind", "--extern"])
        .arg(support::runtime_extern_arg(&dir))
        .arg(&input)
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        compile.status.success(),
        "{}",
        String::from_utf8_lossy(&compile.stderr)
    );
    let run = Command::new(&binary).output().unwrap();
    assert!(
        run.status.success(),
        "{}",
        String::from_utf8_lossy(&run.stderr)
    );
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn two_traits_ending_in_one_name_are_refused_by_the_symbol_check() {
    // `a::Tr::m` and `b::Tr::m` share the method stem `2Tr_m`: the scan's
    // duplicate-symbol check refuses the crate rather than letting rustc
    // report a duplicate `#[no_mangle]` export.
    let source = r#"
        pub mod a { pub trait Tr { fn m(&self) -> i32; } }
        pub mod b { pub trait Tr { fn m(&self) -> i32; } }
        #[julia] pub struct Buf { pub n: i32 }
        #[julia] impl a::Tr for Buf { #[julia] fn m(&self) -> i32 { 1 } }
        #[julia] impl b::Tr for Buf { #[julia] fn m(&self) -> i32 { 2 } }
    "#;
    let err = extract(source, Mode::Crate).unwrap_err().to_string();
    assert!(err.contains("rustcall_Buf_2Tr_m"), "{err}");
}

#[test]
fn a_qualified_julia_name_taken_by_another_method_is_refused() {
    // The trait's `m` would be bound as `Far_m`, which an inherent method
    // already is.
    let source = r#"
        pub trait Far { fn m(&self) -> i32; }
        #[julia] pub struct Buf { pub n: i32 }
        #[julia] impl Buf {
            #[julia] pub fn m(&self) -> i32 { 0 }
            #[julia] pub fn Far_m(&self) -> i32 { 1 }
        }
        #[julia] impl Far for Buf { #[julia] fn m(&self) -> i32 { 2 } }
    "#;
    let err = extract(source, Mode::Crate).unwrap_err().to_string();
    assert!(
        err.contains("`Buf::Far_m`") && err.contains("`<Buf as Far>::m`"),
        "{err}"
    );
    assert!(err.contains("both be bound in Julia as `Far_m`"), "{err}");
}

#[test]
fn a_trait_impl_of_a_plain_type_is_left_alone() {
    // The scan never refused a trait impl whose header names no `#[julia]`
    // struct; its wrappers are exported and nothing describes them.
    let source = r#"
        pub trait Far { fn m(&self) -> i32; }
        pub struct Plain { pub n: i32 }
        #[julia] impl Far for Plain { #[julia] fn m(&self) -> i32 { self.n } }
    "#;
    let manifest = extract(source, Mode::Crate).unwrap();
    assert!(manifest.structs.is_empty());
}

#[test]
fn a_raw_trait_name_leaves_no_hash_in_the_julia_name() {
    // `r#type` is the trait `type`: its `r#` belongs in neither the symbol
    // nor the Julia name, where `#` would start a comment in a module written
    // by `write_bindings_to_file` (PR #513 review).
    let source = r#"
        pub trait r#type { fn m(&self) -> i32; fn r#match(&self) -> i32; }
        #[julia] pub struct Buf { pub n: i32 }
        #[julia] impl Buf {
            #[julia] pub fn m(&self) -> i32 { 0 }
            #[julia] pub fn r#match(&self) -> i32 { 1 }
        }
        #[julia] impl r#type for Buf {
            #[julia] fn m(&self) -> i32 { 2 }
            #[julia] fn r#match(&self) -> i32 { 3 }
        }
    "#;
    let manifest = extract(source, Mode::Crate).unwrap();
    let methods = &manifest.structs[0].methods;
    let m = method(methods, "r#type", "m");
    assert_eq!(m.symbol, "rustcall_Buf_4type_m");
    assert_eq!(m.julia_name, "type_m");
    let matched = method(methods, "r#type", "r#match");
    assert_eq!(matched.symbol, "rustcall_Buf_4type_match");
    assert_eq!(matched.julia_name, "type_match");
    for m in methods {
        assert!(!m.julia_name.contains('#'), "{m:?}");
    }
}

#[test]
fn every_raw_method_name_is_bound_without_its_prefix() {
    // A raw name is normalized for every method, not only a shared one, and
    // `foo` and `r#foo` are one name when deciding whether it is shared
    // (PR #513 review, round 2).
    let source = r#"
        pub trait Tr { fn r#match(&self) -> i32; fn r#loop(&self) -> i32; }
        #[julia] pub struct Buf { pub n: i32 }
        #[julia] impl Buf {
            #[julia] pub fn r#loop(&self) -> i32 { 0 }
            #[julia] pub fn r#fn(&self) -> i32 { 1 }
        }
        #[julia] impl Tr for Buf {
            #[julia] fn r#match(&self) -> i32 { 2 }
            #[julia] fn r#loop(&self) -> i32 { 3 }
        }
    "#;
    let manifest = extract(source, Mode::Crate).unwrap();
    let methods = &manifest.structs[0].methods;
    // Unique names, inherent or a trait's: bound under the bare name.
    assert_eq!(method(methods, "Tr", "r#match").julia_name, "match");
    assert_eq!(method(methods, "", "r#fn").julia_name, "fn");
    // `loop` is shared: the inherent one keeps it, the trait's is qualified.
    assert_eq!(method(methods, "", "r#loop").julia_name, "loop");
    assert_eq!(method(methods, "Tr", "r#loop").julia_name, "Tr_loop");
    for m in methods {
        assert!(!m.julia_name().contains('#'), "{m:?}");
    }
}
