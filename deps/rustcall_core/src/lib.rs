//! Shared Rust core for RustCall.jl.
//!
//! This crate is the single place where Rust syntax is interpreted on behalf
//! of RustCall.jl. It is consumed by two front ends:
//!
//! * `juliacall_macros` (proc-macro) for `@rust_crate`;
//! * `rustcall_extract` (CLI) for `rust"""` blocks, `@rust_crate` scanning and
//!   generic monomorphization.
//!
//! Julia never parses Rust source itself; it reads the [`manifest::Manifest`]
//! produced here.

pub mod attrs;
pub mod cfg;
pub mod codegen;
pub mod expand;
pub mod extract;
pub mod manifest;
pub mod model;
pub mod pyo3;
pub mod specialize;
pub mod types;
pub mod wrap;

pub use manifest::{Manifest, Mode, SCHEMA_VERSION};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inline_manifest_matches_expanded_code() {
        let src = r#"
            #[julia]
            fn add(a: i32, b: i32) -> i32 { a + b }

            #[julia]
            fn safe_div(a: f64, b: f64) -> Option<f64> { if b == 0.0 { None } else { Some(a / b) } }

            #[julia]
            pub struct Point { x: f64, y: f64 }

            impl Point {
                pub fn new(x: f64, y: f64) -> Self { Self { x, y } }
                pub fn norm(&self) -> f64 { (self.x * self.x + self.y * self.y).sqrt() }
                fn private(&self) -> f64 { 0.0 }
            }

            #[no_mangle]
            pub extern "C" fn raw(a: u8) -> u8 { a }

            pub fn identity<T: Copy>(x: T) -> T where T: Clone { x }
        "#;
        let e = expand::expand(src).unwrap();
        let m = &e.manifest;

        let add = m.functions.iter().find(|f| f.name == "add").unwrap();
        assert!(add.exported);
        assert_eq!(add.return_kind, manifest::ReturnKind::Plain);
        assert_eq!(add.args.len(), 2);
        assert!(e
            .source
            .contains("pub extern \"C\" fn rustcall_add(a: i32, b: i32) -> i32"));

        let div = m.functions.iter().find(|f| f.name == "safe_div").unwrap();
        assert_eq!(div.return_kind, manifest::ReturnKind::Option);
        assert_eq!(div.inner_type, "f64");
        assert!(e.source.contains("COption_safe_div"));

        let raw = m.functions.iter().find(|f| f.name == "raw").unwrap();
        assert_eq!(raw.attribute, manifest::Attribute::None);
        assert!(raw.exported);

        let id = m.functions.iter().find(|f| f.name == "identity").unwrap();
        assert!(id.is_generic);
        assert!(!id.exported);
        assert_eq!(id.type_params[0].name, "T");
        let bounds: Vec<_> = id.type_params[0]
            .bounds
            .iter()
            .map(|b| b.trait_name.clone())
            .collect();
        assert_eq!(bounds, vec!["Copy", "Clone"]);
        assert!(id.source.contains("fn identity"));

        let p = &m.structs[0];
        assert_eq!(p.name, "Point");
        assert_eq!(p.fields.len(), 2);
        let names: Vec<_> = p.methods.iter().map(|m| m.name.clone()).collect();
        assert_eq!(names, vec!["new", "norm"]);
        assert!(p.methods[0].is_constructor);
        assert!(e.source.contains("pub extern \"C\" fn Point_free"));
        assert!(e.source.contains("pub extern \"C\" fn rustcall_Point_new"));
        assert!(e.source.contains("pub extern \"C\" fn Point_get_x"));
        assert!(!e.source.contains("#[julia]"));
    }

    #[test]
    fn julia_attr_inside_string_is_ignored() {
        let src = r##"
            fn f() -> &'static str { "#[julia] fn fake() {}" }
        "##;
        let e = expand::expand(src).unwrap();
        assert!(e
            .manifest
            .functions
            .iter()
            .all(|f| f.attribute == manifest::Attribute::None));
        assert!(!e.source.contains("extern \"C\" fn fake"));
    }

    #[test]
    fn nested_block_comments_and_raw_strings() {
        let src = r##"
            #[julia]
            fn f() -> i32 { /* outer /* inner */ } still outer */ let s = r#"{"#; let _ = s; 1 }
            #[julia]
            fn g() -> i32 { 2 }
        "##;
        let e = expand::expand(src).unwrap();
        let names: Vec<_> = e
            .manifest
            .functions
            .iter()
            .map(|f| f.name.clone())
            .collect();
        assert_eq!(names, vec!["f", "g"]);
    }

    #[test]
    fn where_clause_and_const_generic_expr() {
        let src = r#"
            #[julia]
            fn foo(x: [u8; { if 1 < 2 { 3 } else { 4 } }], y: i32) {}
            fn bar<T>(x: T) -> T where T: Copy { x }
        "#;
        let e = expand::expand(src).unwrap();
        let foo = &e.manifest.functions[0];
        assert_eq!(foo.args[1].rust_type, "i32");
        assert_eq!(foo.return_type, "()");
        let bar = &e.manifest.functions[1];
        assert_eq!(bar.return_type, "T");
        assert_eq!(bar.type_params[0].bounds[0].trait_name, "Copy");
    }

    #[test]
    fn crate_mode_follows_proc_macro_rules() {
        let src = r#"
            use juliacall_macros::julia;
            #[julia]
            fn add(a: i32, b: i32) -> i32 { a + b }
            #[julia]
            fn parse(n: i32) -> Result<u32, i32> { Ok(n as u32) }
            #[julia]
            pub struct Counter { count: u32, name: String }
            #[julia]
            impl Counter {
                #[julia]
                pub fn new() -> Self { Self { count: 0, name: String::new() } }
                #[julia]
                pub fn increment(&mut self) { self.count += 1; }
                pub fn not_wrapped(&self) {}
            }
            impl Counter {
                pub fn also_not_wrapped(&self) {}
            }
        "#;
        let m = extract::extract(src, Mode::Crate).unwrap();
        assert_eq!(m.functions.len(), 2);
        assert_eq!(m.functions[1].return_kind, manifest::ReturnKind::Result);
        assert_eq!(m.functions[1].ok_type, "u32");
        let c = &m.structs[0];
        let names: Vec<_> = c.methods.iter().map(|m| m.name.clone()).collect();
        assert_eq!(names, vec!["new", "increment"]);
        assert_eq!(c.methods[0].symbol, "rustcall_Counter_new");
        assert!(c.fields.iter().all(|f| f.ffi_compatible));
    }

    #[test]
    fn generic_struct_reports_wrappers() {
        let src = r#"
            #[julia]
            pub struct Pair<T> { a: T, b: T }
            impl<T: Copy> Pair<T> {
                pub fn new(a: T, b: T) -> Self { Self { a, b } }
                pub fn first(&self) -> T { self.a }
            }
        "#;
        let e = expand::expand(src).unwrap();
        let s = &e.manifest.structs[0];
        assert_eq!(s.type_params[0].name, "T");
        let names: Vec<_> = s.generic_wrappers.iter().map(|w| w.name.clone()).collect();
        assert!(names.contains(&"Pair_new".to_string()));
        assert!(names.contains(&"Pair_first".to_string()));
        assert!(names.contains(&"Pair_free".to_string()));
        assert!(names.contains(&"Pair_get_a".to_string()));
        assert!(s.context_source.contains("pub struct Pair<T>"));
        // generic wrappers are emitted (unexported) so they can be specialized in place
        assert!(e.source.contains("pub fn Pair_free<T>"));
        assert!(!e.source.contains("extern \"C\" fn Pair_free"));
        let sp = specialize::specialize(
            &e.source,
            "Pair_first",
            &[("T".to_string(), "i32".to_string())],
            "Pair_first_i32",
        )
        .unwrap();
        assert!(sp
            .source
            .contains("pub extern \"C\" fn rustcall_Pair_first_i32(ptr: *const Pair<i32>) -> i32"));

        let full = format!("{}\n{}", s.context_source, s.generic_wrappers[0].source);
        let sp = specialize::specialize(
            &full,
            "Pair_new",
            &[("T".to_string(), "i32".to_string())],
            "Pair_new_i32",
        )
        .unwrap();
        assert!(sp.source.contains(
            "pub extern \"C\" fn rustcall_Pair_new_i32(a: i32, b: i32) -> *mut Pair<i32>"
        ));
    }

    #[test]
    fn inline_modules_are_expanded_recursively() {
        let src = r#"
            mod api {
                #[julia]
                pub fn inner_add(a: i32, b: i32) -> i32 { a + b }
                #[julia]
                pub struct P { x: f64 }
                impl P { pub fn new(x: f64) -> Self { Self { x } } }
                mod deep { #[julia] fn deeper() -> u8 { 1 } }
            }
            mod external;
        "#;
        let e = expand::expand(src).unwrap();
        let names: Vec<_> = e
            .manifest
            .functions
            .iter()
            .map(|f| f.name.clone())
            .collect();
        assert_eq!(names, vec!["inner_add", "deeper"]);
        assert_eq!(e.manifest.functions[1].module_path, vec!["api", "deep"]);
        assert_eq!(e.manifest.structs[0].name, "P");
        assert_eq!(e.manifest.structs[0].module_path, vec!["api"]);
        assert!(e.source.contains("pub extern \"C\" fn rustcall_inner_add"));
        assert!(e.source.contains("pub extern \"C\" fn rustcall_P_new"));
        assert!(!e.source.contains("#[julia]"));
        assert!(e.source.contains("mod external;"));

        let c = extract::extract(src, Mode::Crate).unwrap();
        assert_eq!(c.functions.len(), 2);
        assert_eq!(c.structs.len(), 1);
    }

    #[test]
    fn generic_wrappers_typecheck_generically() {
        let src = r#"
            #[julia]
            pub struct Bag<T> where T: Copy { items: Vec<Option<T>>, first: T }
            impl<T> Bag<T> where T: Copy {
                pub fn new(first: T) -> Self { Self { items: Vec::new(), first } }
                pub fn first(&self) -> T { self.first }
            }
        "#;
        let e = expand::expand(src).unwrap();
        assert!(e.source.contains("Vec<Option<T>>: Clone"));
        assert!(e.source.contains("T: Copy"));
        // Prove it with rustc when available.
        if let Ok(rustc) = std::env::var("RUSTC").or_else(|_| Ok::<_, ()>("rustc".to_string())) {
            let dir =
                std::env::temp_dir().join(format!("rustcall_core_gen_{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            let file = dir.join("bag.rs");
            std::fs::write(&file, format!("#![allow(unused)]\n{}", e.source)).unwrap();
            if let Ok(out) = std::process::Command::new(rustc)
                .args(["--crate-type", "cdylib", "--edition", "2021", "-o"])
                .arg(dir.join("libbag.so"))
                .arg(&file)
                .output()
            {
                assert!(
                    out.status.success(),
                    "{}",
                    String::from_utf8_lossy(&out.stderr)
                );
            }
            let _ = std::fs::remove_dir_all(&dir);
        }
    }

    #[test]
    fn const_generics_are_not_exported() {
        let src = r#"
            #[julia]
            fn lookup<const N: usize>(x: [u8; N]) -> u8 { x[0] }
            pub fn plain<const N: usize>() -> usize { N }
        "#;
        let e = expand::expand(src).unwrap();
        let lookup = &e.manifest.functions[0];
        assert!(!lookup.exported);
        assert!(lookup.is_generic);
        assert!(e.source.contains("compile_error!"));
        assert!(!e.source.contains("extern \"C\" fn lookup"));
        let plain = &e.manifest.functions[1];
        assert!(!plain.exported && plain.is_generic);
        let err = specialize::specialize(&e.source, "plain", &[], "plain_1").unwrap_err();
        assert!(
            matches!(err, specialize::SpecializeError::UnboundParams(ref p) if p == &vec!["N".to_string()])
        );
    }

    #[test]
    fn impl_with_renamed_parameters() {
        let src = r#"
            #[julia]
            pub struct Wrapper<T> { value: T }
            impl<U: Copy> Wrapper<U> {
                pub fn new(value: U) -> Self { Self { value } }
                pub fn get(&self) -> U { self.value }
            }
        "#;
        let e = expand::expand(src).unwrap();
        assert!(e
            .source
            .contains("pub fn Wrapper_get<U: Copy>(ptr: *const Wrapper<U>) -> U"));
        let s = &e.manifest.structs[0];
        let get = s
            .generic_wrappers
            .iter()
            .find(|w| w.name == "Wrapper_get")
            .unwrap();
        assert_eq!(get.type_params, vec!["U"]);
        let free = s
            .generic_wrappers
            .iter()
            .find(|w| w.name == "Wrapper_free")
            .unwrap();
        assert_eq!(free.type_params, vec!["T"]);
        let sp = specialize::specialize(
            &e.source,
            "Wrapper_get",
            &[("U".into(), "i32".into())],
            "Wrapper_get_i32",
        )
        .unwrap();
        assert!(sp
            .source
            .contains("fn Wrapper_get_i32(ptr: *const Wrapper<i32>) -> i32"));
        assert!(e
            .source
            .contains("pub fn Wrapper_new<U: Copy>(value: U) -> *mut Wrapper<U>"));
        assert!(!e.source.contains("Wrapper<T>) -> U"));
    }

    #[test]
    fn impl_trait_arguments_are_not_exported() {
        let src = "#[julia] fn f(x: impl Copy) -> i32 { let _ = x; 1 }\n#[julia] fn g() -> impl Copy { 1 }\n#[julia] fn h(x: &impl Copy) {}";
        let e = expand::expand(src).unwrap();
        assert!(e
            .manifest
            .functions
            .iter()
            .all(|f| !f.exported && f.is_generic));
        assert_eq!(e.source.matches("compile_error!").count(), 3);
        assert!(!e.source.contains("extern \"C\""));
    }

    #[test]
    fn manifest_roundtrips_through_toml() {
        let e = expand::expand("#[julia] fn a(x: i32) -> i32 { x }").unwrap();
        let toml = e.manifest.to_toml().unwrap();
        let back = Manifest::from_toml(&toml).unwrap();
        assert_eq!(back, e.manifest);
    }
}
