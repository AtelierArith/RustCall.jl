//! A `#[julia]` item that is an `unsafe fn` is refused, and the manifest says
//! so (#491).
//!
//! The `extern "C"` entry point of an `unsafe fn` would let Julia call it with
//! none of the requirements its `unsafe` states upheld. A free function was
//! already refused with a `compile_error!` (`transform_function`); a method
//! got a wrapper calling it from a safe body, which failed inside generated
//! code with rustc's E0133. Both are now refused at the item, gated by its
//! `#[cfg]`, and a refused item carries `skip_reason = "unsafe_fn"`, so the
//! Julia generators — and through them the boundary report — can name the
//! refusal before anything is built.

use std::{fs, process::Command};

use rustcall_julia_core::expand::expand;
use rustcall_julia_core::extract::extract;
use rustcall_julia_core::manifest::{skip_reason, Mode};

fn rustc(label: &str, source: &str) -> std::process::Output {
    let dir = std::env::temp_dir().join(format!(
        "rustcall_unsafe_items_{}_{label}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    let input = dir.join("lib.rs");
    fs::write(
        &input,
        format!("#![allow(non_snake_case, unexpected_cfgs, dead_code)]\n{source}"),
    )
    .unwrap();
    // No `--edition`, like `RustCall.compile_rust_to_shared_lib`.
    let out = Command::new("rustc")
        .args(["--crate-type=cdylib", "-C", "panic=unwind"])
        .arg(&input)
        .arg("--out-dir")
        .arg(&dir)
        .output()
        .unwrap();
    fs::remove_dir_all(dir).unwrap();
    out
}

fn flat(source: &str) -> String {
    source.split_whitespace().collect::<Vec<_>>().join(" ")
}

const INLINE: &str = r#"
    #[julia]
    pub unsafe fn danger(p: *const i32) -> i32 { *p }

    #[julia]
    pub fn safe(x: i32) -> i32 { x }

    #[julia]
    pub struct Cell { pub v: i32 }

    impl Cell {
        pub fn new() -> Self { Cell { v: 1 } }
        pub unsafe fn read(&self, p: *const i32) -> i32 { *p + self.v }
        pub fn get(&self) -> i32 { self.v }
    }
"#;

#[test]
fn inline_unsafe_items_are_refused_and_reported() {
    let expanded = expand(INLINE).unwrap();
    let source = flat(&expanded.source);
    assert!(
        source.contains("cannot be applied to unsafe functions directly"),
        "{source}"
    );
    assert!(
        source.contains("`Cell::read` is an `unsafe fn`"),
        "{source}"
    );
    // No wrapper calls the refused method; the others are wrapped as before.
    assert!(!source.contains("fn rustcall_Cell_read"), "{source}");
    assert!(source.contains("fn rustcall_Cell_get("), "{source}");
    assert!(source.contains("fn rustcall_safe("), "{source}");

    let m = &expanded.manifest;
    let reason = |name: &str| {
        m.functions
            .iter()
            .find(|f| f.name == name)
            .unwrap()
            .skip_reason
            .clone()
    };
    assert_eq!(reason("danger"), skip_reason::UNSAFE_FN);
    assert_eq!(reason("safe"), "");
    let cell = &m.structs[0];
    let methods: Vec<(&str, &str)> = cell
        .methods
        .iter()
        .map(|m| (m.name.as_str(), m.skip_reason.as_str()))
        .collect();
    assert_eq!(
        methods,
        [("new", ""), ("read", skip_reason::UNSAFE_FN), ("get", "")]
    );

    // rustc stops at the refusal, not with E0133 inside a generated wrapper.
    let out = rustc("inline", &expanded.source);
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("`Cell::read` is an `unsafe fn`"),
        "{stderr}"
    );
    assert!(!stderr.contains("E0133"), "{stderr}");
}

/// A method whose block sits in another module is wrapped at the block
/// (#342), and refused there the same way.
#[test]
fn an_unsafe_method_in_a_foreign_block_is_refused() {
    let src = r#"
        #[julia]
        pub struct Gauge { pub v: f64 }
        pub mod ops {
            impl super::Gauge {
                pub unsafe fn peek(&self, p: *const f64) -> f64 { *p + self.v }
                pub fn read(&self) -> f64 { self.v }
            }
        }
    "#;
    let expanded = expand(src).unwrap();
    let source = flat(&expanded.source);
    assert!(
        source.contains("`Gauge::peek` is an `unsafe fn`"),
        "{source}"
    );
    assert!(!source.contains("fn rustcall_Gauge_peek"), "{source}");
    assert!(source.contains("fn rustcall_Gauge_read("), "{source}");
    let peek = expanded.manifest.structs[0]
        .methods
        .iter()
        .find(|m| m.name == "peek")
        .unwrap();
    assert_eq!(peek.skip_reason, skip_reason::UNSAFE_FN);
}

/// A generic struct's methods are instantiated per struct type; an `unsafe`
/// one gets no generic wrapper and is refused next to the struct. It stays in
/// the manifest with its `skip_reason`, so the Julia generators can report it
/// (#491 review).
#[test]
fn an_unsafe_method_of_a_generic_struct_is_refused() {
    let src = r#"
        #[julia]
        pub struct W<T> { pub x: T }
        impl<T: Copy> W<T> {
            pub fn get(&self) -> T { self.x }
            pub unsafe fn peek(&self, p: *const T) -> T { *p }
        }
    "#;
    let expanded = expand(src).unwrap();
    let source = flat(&expanded.source);
    assert!(source.contains("`W::peek` is an `unsafe fn`"), "{source}");
    let w = &expanded.manifest.structs[0];
    let methods: Vec<(&str, &str, &str)> = w
        .methods
        .iter()
        .map(|m| {
            (
                m.name.as_str(),
                m.skip_reason.as_str(),
                m.generic_wrapper_name.as_str(),
            )
        })
        .collect();
    assert_eq!(methods.len(), 2);
    assert_eq!(methods[0].0, "get");
    assert_eq!(methods[0].1, "");
    assert!(!methods[0].2.is_empty());
    assert_eq!(methods[1], ("peek", skip_reason::UNSAFE_FN, ""));
    assert!(w
        .generic_wrappers
        .iter()
        .all(|g| !g.name.ends_with("_peek")));
    // The block stops at the refusal.
    let out = rustc("generic_struct", &expanded.source);
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("`W::peek` is an `unsafe fn`"), "{stderr}");
    assert!(!stderr.contains("E0133"), "{stderr}");
}

/// The refusal exists only where the method does.
#[test]
fn the_refusal_carries_the_cfg() {
    let src = r#"
        #[julia]
        pub struct Cell { pub v: i32 }
        impl Cell {
            pub fn new() -> Self { Cell { v: 1 } }
            #[cfg(rustcall_never)]
            pub unsafe fn read(&self, p: *const i32) -> i32 { *p + self.v }
        }
        #[cfg(rustcall_never)]
        #[julia]
        pub unsafe fn danger(p: *const i32) -> i32 { *p }
    "#;
    let expanded = expand(src).unwrap();
    let out = rustc("cfg", &expanded.source);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// The crate flavour: the proc-macro refuses an `unsafe` `#[julia]` method
/// at the block, and crate extraction reports both items with the reason.
#[test]
fn crate_unsafe_items_are_refused_and_reported() {
    let src = r#"
        #[julia]
        pub unsafe fn danger(p: *const i32) -> i32 { *p }

        #[julia]
        pub struct Cell { pub v: i32 }

        #[julia]
        impl Cell {
            #[julia]
            pub unsafe fn read(&self, p: *const i32) -> i32 { *p + self.v }
            #[julia]
            pub fn get(&self) -> i32 { self.v }
        }
    "#;
    let m = extract(src, Mode::Crate).unwrap();
    assert_eq!(m.functions[0].name, "danger");
    assert_eq!(m.functions[0].skip_reason, skip_reason::UNSAFE_FN);
    let methods: Vec<(&str, &str)> = m.structs[0]
        .methods
        .iter()
        .map(|m| (m.name.as_str(), m.skip_reason.as_str()))
        .collect();
    assert_eq!(methods, [("read", skip_reason::UNSAFE_FN), ("get", "")]);

    let imp: syn::ItemImpl = syn::parse_str(
        "impl Cell { #[julia] pub unsafe fn read(&self, p: *const i32) -> i32 { *p + self.v } \
         #[julia] pub fn get(&self) -> i32 { self.v } }",
    )
    .unwrap();
    let out = flat(&rustcall_julia_core::codegen::transform_impl_crate(imp, &[]).to_string());
    assert!(out.contains("is an `unsafe fn`"), "{out}");
    assert!(!out.contains("rustcall_Cell_read"), "{out}");
    assert!(out.contains("rustcall_Cell_get"), "{out}");
}

/// A generic `#[julia] unsafe fn` is registered for specialization rather
/// than transformed, so it used to get no refusal: the block compiled, and the
/// first `@rust` call failed with E0133 inside the specialized wrapper. It is
/// refused at the item like a concrete one, gated by its `#[cfg]`, and the
/// manifest reports it (#491 review).
#[test]
fn a_generic_unsafe_fn_is_refused_and_reported() {
    let src = r#"
        #[julia]
        pub unsafe fn g<T: Copy>(x: T) -> T { x }
        #[julia]
        pub fn h<T: Copy>(x: T) -> T { x }
    "#;
    let expanded = expand(src).unwrap();
    let source = flat(&expanded.source);
    assert_eq!(
        source
            .matches("cannot be applied to unsafe functions directly")
            .count(),
        1,
        "{source}"
    );
    let reasons: Vec<(&str, bool, &str)> = expanded
        .manifest
        .functions
        .iter()
        .map(|f| (f.name.as_str(), f.is_generic, f.skip_reason.as_str()))
        .collect();
    assert_eq!(
        reasons,
        [("g", true, skip_reason::UNSAFE_FN), ("h", true, "")]
    );
    let out = rustc("generic", &expanded.source);
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("cannot be applied to unsafe functions directly"),
        "{stderr}"
    );

    let gated = expand(
        r#"
        #[cfg(rustcall_never)]
        #[julia]
        pub unsafe fn g<T: Copy>(x: T) -> T { x }
    "#,
    )
    .unwrap();
    let out = rustc("generic_cfg", &gated.source);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}
