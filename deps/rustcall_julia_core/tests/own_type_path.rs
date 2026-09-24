//! Whether a method returns its own type is decided by path, never by the
//! last segment (#518).
//!
//! `codegen::returns_own_type` compared only the last segment of the declared
//! return type with the impl header's, so in `use super::Gauge as Meter; impl
//! Meter { fn raw(&self) -> other::Meter }` the `other::Meter` — here an
//! `i32` — was taken for `Self`, boxed as `*mut Meter`, and the expansion did
//! not compile. A return type is the implementing type when it is spelled
//! `Self` or exactly as the header spells it (both flavours), or — inline
//! only, where the expander resolves names — when the header's path
//! machinery (`paths::names_struct`) resolves it to the block's struct.
//!
//! Every expansion here is compiled **without `--edition`**, as RustCall
//! compiles an inline block, and called through its exported symbols.

use std::{fs, process::Command};

mod support;

use quote::quote;
use rustcall_julia_core::codegen::{transform_impl_crate, transform_struct_crate};
use rustcall_julia_core::expand::expand;
use rustcall_julia_core::extract::extract;
use rustcall_julia_core::manifest::{Manifest, Method, Mode};

fn method<'a>(manifest: &'a Manifest, strukt: &str, name: &str) -> &'a Method {
    manifest
        .structs
        .iter()
        .find(|s| s.name == strukt)
        .and_then(|s| s.methods.iter().find(|m| m.name == name))
        .unwrap_or_else(|| panic!("no `{strukt}::{name}` in {manifest:#?}"))
}

/// `(returns_boxed_struct, is_constructor)` of `strukt::name`.
fn boxed(manifest: &Manifest, strukt: &str, name: &str) -> (bool, bool) {
    let m = method(manifest, strukt, name);
    (m.returns_boxed_struct, m.is_constructor)
}

/// The inline flavour: the issue's example. The header renames the struct,
/// and a same-named type from another module is returned next to the struct
/// itself, spelled every way a block can spell it.
#[test]
fn an_aliased_header_does_not_claim_a_same_named_type_inline() {
    let src = r#"
        #[julia] pub struct Gauge { pub value: i32 }
        pub mod other {
            pub type Meter = i32;
            #[julia] pub struct Gauge { pub other: i32 }
        }
        pub mod ops {
            use super::other;
            use super::Gauge as Meter;
            impl Meter {
                pub fn raw(&self) -> other::Meter { self.value + 1 }
                pub fn peer(&self) -> other::Gauge { other::Gauge { other: self.value } }
                pub fn same(&self) -> Self { Meter { value: self.value * 2 } }
                pub fn spelled(&self) -> Meter { Meter { value: self.value * 3 } }
                pub fn resolved(&self) -> super::Gauge { super::Gauge { value: self.value * 4 } }
            }
        }
    "#;
    let expanded = expand(src).unwrap();
    let m = &expanded.manifest;
    // `other::Meter` is an `i32` and `other::Gauge` another struct: neither
    // is `Gauge`, whatever their last segment.
    assert_eq!(boxed(m, "Gauge", "raw"), (false, false));
    assert_eq!(boxed(m, "Gauge", "peer"), (false, false));
    // `Self`, the header's own spelling, and a path the header's resolver
    // takes to the struct are.
    assert_eq!(boxed(m, "Gauge", "same"), (true, true));
    assert_eq!(boxed(m, "Gauge", "spelled"), (true, true));
    assert_eq!(boxed(m, "Gauge", "resolved"), (true, true));
    assert_eq!(method(m, "Gauge", "raw").return_type, "other::Meter");

    let main = r#"
        fn main() {
            unsafe {
                let p = Box::into_raw(Box::new(Gauge { value: 5 }));
                assert_eq!(ops::rustcall_Gauge_raw(p).assume_init(), 6);
                let peer = ops::rustcall_Gauge_peer(p).assume_init();
                assert_eq!(peer.other, 5);
                for (symbol, factor) in [
                    (ops::rustcall_Gauge_same as unsafe extern "C" fn(*const Gauge) -> *mut Gauge, 2),
                    (ops::rustcall_Gauge_spelled, 3),
                    (ops::rustcall_Gauge_resolved, 4),
                ] {
                    let q = symbol(p);
                    assert_eq!((*q).value, 5 * factor);
                    Gauge_free(q);
                }
                Gauge_free(p);
            }
        }
    "#;
    compile_and_run("inline_alias", &expanded.source, main, false);
}

/// The inline flavour, a plain header: a module-local `type Gauge = i32`
/// shadows the struct's name where the block is, so a bare `-> Gauge` there
/// is an `i32`; `crate::Gauge` and `self::Gauge` at the root resolve to the
/// struct.
#[test]
fn a_plain_header_resolves_the_return_type_where_the_block_is() {
    let src = r#"
        #[julia] pub struct Gauge { pub value: i32 }
        impl Gauge {
            pub fn rooted(&self) -> crate::Gauge { Gauge { value: self.value + 10 } }
            pub fn here(&self) -> self::Gauge { Gauge { value: self.value + 20 } }
        }
        pub mod ops {
            type Gauge = i32;
            impl super::Gauge {
                pub fn local(&self) -> Gauge { self.value * 7 }
                pub fn parent(&self) -> super::Gauge { super::Gauge { value: self.value * 8 } }
                pub fn extern_prelude(&self) -> ::std::primitive::i32 { self.value }
            }
        }
    "#;
    let expanded = expand(src).unwrap();
    let m = &expanded.manifest;
    assert_eq!(boxed(m, "Gauge", "rooted"), (true, true));
    assert_eq!(boxed(m, "Gauge", "here"), (true, true));
    assert_eq!(boxed(m, "Gauge", "local"), (false, false));
    assert_eq!(boxed(m, "Gauge", "parent"), (true, true));
    assert_eq!(boxed(m, "Gauge", "extern_prelude"), (false, false));

    let main = r#"
        fn main() {
            unsafe {
                let p = Box::into_raw(Box::new(Gauge { value: 2 }));
                let rooted = rustcall_Gauge_rooted(p);
                assert_eq!((*rooted).value, 12);
                Gauge_free(rooted);
                let here = rustcall_Gauge_here(p);
                assert_eq!((*here).value, 22);
                Gauge_free(here);
                assert_eq!(ops::rustcall_Gauge_local(p).assume_init(), 14);
                let parent = ops::rustcall_Gauge_parent(p);
                assert_eq!((*parent).value, 16);
                Gauge_free(parent);
                Gauge_free(p);
            }
        }
    "#;
    compile_and_run("inline_plain", &expanded.source, main, false);
}

/// RustCall compiles a `rust"""` block with no `--edition`, i.e. edition
/// 2015, where a leading `::` is the crate root: `-> ::Gauge` is the struct,
/// resolved by the anchor rule every resolution shares
/// (`paths::edition_type_qualifier`), and `-> ::other::Gauge` is not
/// (#519 review).
#[test]
fn a_leading_double_colon_is_the_crate_root_inline() {
    let src = r#"
        #[julia] pub struct Gauge { pub value: i32 }
        pub mod other { pub type Gauge = i32; }
        impl Gauge {
            pub fn copy(&self) -> ::Gauge { Gauge { value: self.value + 1 } }
            pub fn aliased(&self) -> ::other::Gauge { self.value + 2 }
        }
        pub mod ops {
            impl super::Gauge {
                pub fn rooted(&self) -> ::Gauge { ::Gauge { value: self.value + 3 } }
            }
        }
    "#;
    let expanded = expand(src).unwrap();
    let m = &expanded.manifest;
    assert_eq!(boxed(m, "Gauge", "copy"), (true, true));
    assert_eq!(boxed(m, "Gauge", "rooted"), (true, true));
    assert_eq!(boxed(m, "Gauge", "aliased"), (false, false));
    let main = r#"
        fn main() {
            unsafe {
                let p = Box::into_raw(Box::new(Gauge { value: 1 }));
                let copy = rustcall_Gauge_copy(p);
                assert_eq!((*copy).value, 2);
                Gauge_free(copy);
                let rooted = ops::rustcall_Gauge_rooted(p);
                assert_eq!((*rooted).value, 4);
                Gauge_free(rooted);
                assert_eq!(rustcall_Gauge_aliased(p).assume_init(), 3);
                Gauge_free(p);
            }
        }
    "#;
    compile_and_run("inline_leading_colon", &expanded.source, main, false);
}

/// A glob import or the one struct of a name anywhere is how a *header* is
/// matched when nothing else says; it is not proof that a return type names
/// the struct. `use crate::model::*;` brings `model::Gauge` in, but an item
/// of the module shadows a glob import, so the bare `Gauge` of `ops` is its
/// own `i32` alias; `inner::Gauge` is another one.
#[test]
fn a_glob_import_does_not_make_a_return_type_the_struct() {
    let src = r#"
        pub mod model {
            #[julia] pub struct Gauge { pub value: i32 }
        }
        pub mod ops {
            use crate::model::*;
            type Gauge = i32;
            pub mod inner {
                pub type Gauge = i32;
            }
            impl crate::model::Gauge {
                pub fn count(&self) -> Gauge { self.value * 5 }
                pub fn nested(&self) -> inner::Gauge { self.value * 6 }
            }
        }
    "#;
    let expanded = expand(src).unwrap();
    assert_eq!(boxed(&expanded.manifest, "Gauge", "count"), (false, false));
    assert_eq!(boxed(&expanded.manifest, "Gauge", "nested"), (false, false));
    let main = r#"
        fn main() {
            unsafe {
                let p = Box::into_raw(Box::new(model::Gauge { value: 3 }));
                assert_eq!(ops::rustcall_model__Gauge_count(p).assume_init(), 15);
                assert_eq!(ops::rustcall_model__Gauge_nested(p).assume_init(), 18);
                model::model__Gauge_free(p);
            }
        }
    "#;
    compile_and_run("inline_glob", &expanded.source, main, false);
}

const CRATE: &str = r#"
    pub mod other { pub type Gauge = i32; }

    #[julia]
    pub struct Gauge { pub value: i32 }

    #[julia]
    impl Gauge {
        #[julia]
        pub fn new(value: i32) -> Self { Gauge { value } }
        #[julia]
        pub fn spelled(&self) -> Gauge { Gauge { value: self.value * 3 } }
        #[julia]
        pub fn raw(&self) -> other::Gauge { self.value + 1 }
    }
"#;

/// The crate flavour: the proc macro sees one block and cannot resolve a
/// name, so only `Self` and the header's spelling are the struct; the crate
/// scan says exactly what the macro emits.
#[test]
fn the_crate_flavour_reads_the_spelling_and_the_manifest_agrees() {
    let manifest = extract(CRATE, Mode::Crate).unwrap();
    assert_eq!(boxed(&manifest, "Gauge", "new"), (true, true));
    assert_eq!(boxed(&manifest, "Gauge", "spelled"), (true, true));
    assert_eq!(boxed(&manifest, "Gauge", "raw"), (false, false));
    let expansion = proc_macro_expansion(CRATE);
    let main = r#"
        fn main() {
            unsafe {
                let p = rustcall_Gauge_new(4);
                assert_eq!(rustcall_Gauge_raw(p).assume_init(), 5);
                let q = rustcall_Gauge_spelled(p);
                assert_eq!((*q).value, 12);
                Gauge_free(q);
                Gauge_free(p);
            }
        }
    "#;
    compile_and_run("crate", &expansion, main, true);
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

/// Compile `source` with `main` as a binary — with no `--edition`, as
/// RustCall compiles an inline block — and run it. `runtime` links the
/// `rustcall_julia_macros` runtime a crate-flavour expansion names.
fn compile_and_run(label: &str, source: &str, main: &str, runtime: bool) {
    let dir = std::env::temp_dir().join(format!(
        "rustcall_own_type_path_{}_{label}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    let input = dir.join("probe.rs");
    let binary = dir.join(format!("probe{}", std::env::consts::EXE_SUFFIX));
    // Edition 2015 names an `--extern` crate from the root only once it is
    // declared.
    let prelude = if runtime {
        "extern crate rustcall_julia_macros;\n"
    } else {
        ""
    };
    fs::write(
        &input,
        format!(
            "#![allow(non_snake_case, dead_code, improper_ctypes_definitions)]\n{prelude}{source}\n{main}"
        ),
    )
    .unwrap();
    let mut compile = Command::new("rustc");
    compile.args(["-C", "panic=unwind"]);
    if runtime {
        compile
            .arg("--extern")
            .arg(support::runtime_extern_arg(&dir));
    }
    let compile = compile.arg(&input).arg("-o").arg(&binary).output().unwrap();
    assert!(
        compile.status.success(),
        "{label}: {}\n{source}",
        String::from_utf8_lossy(&compile.stderr)
    );
    let run = Command::new(&binary).output().unwrap();
    assert!(
        run.status.success(),
        "{label}: {}",
        String::from_utf8_lossy(&run.stderr)
    );
    fs::remove_dir_all(dir).unwrap();
}
