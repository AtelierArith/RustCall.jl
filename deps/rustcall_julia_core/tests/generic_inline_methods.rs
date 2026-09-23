//! A generic method of a **non-generic** inline struct is refused (#471).
//!
//! `rust"""` wraps every `pub fn` of a struct's inherent impl in an
//! `extern "C"` entry point with a fixed symbol. A method generic over a type
//! or a const (`pub fn echo<T>(&self, x: T) -> T`), or through `impl Trait`,
//! used to get such a wrapper naming its unbound parameter, so the expanded
//! block failed to compile inside generated code. The struct's other methods
//! have fixed symbols the Julia side binds at macro-expansion time, so there
//! is no monomorphization path to hang the method on; the expander refuses it
//! at the method instead, gated by its `#[cfg]`, and leaves it out of the
//! manifest, since no wrapper exists for Julia to bind.

use std::{fs, process::Command};

use rustcall_julia_core::expand::expand;

fn rustc(label: &str, source: &str) -> std::process::Output {
    let dir = std::env::temp_dir().join(format!(
        "rustcall_generic_method_{}_{label}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    let input = dir.join("lib.rs");
    fs::write(
        &input,
        format!("#![allow(non_snake_case, unexpected_cfgs, dead_code)]\n{source}"),
    )
    .unwrap();
    // No `--edition`: `RustCall.compile_rust_to_shared_lib` passes none, so a
    // `rust"""` block is an edition-2015 crate, where a refusal spelled
    // `::core::compile_error!` would not even resolve.
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

const GENERIC_METHOD: &str = r#"
    #[julia]
    pub struct Acc { pub total: i64 }

    #[julia]
    impl Acc {
        pub fn new() -> Self { Acc { total: 0 } }
        pub fn add(&mut self, x: i64) { self.total += x; }
        pub fn echo<T: Copy>(&self, x: T) -> T { x }
    }
"#;

#[test]
fn a_generic_method_is_refused_at_the_method() {
    let expanded = expand(GENERIC_METHOD).unwrap();
    let source = flat(&expanded.source);
    assert!(
        source.contains("compile_error!"),
        "no refusal:\n{}",
        expanded.source
    );
    assert!(
        source.contains("`Acc::echo` is generic over `T`"),
        "{source}"
    );
    assert!(source.contains("generic free function"), "{source}");
    // No wrapper naming the unbound `T` ...
    assert!(!source.contains("fn rustcall_Acc_echo"), "{source}");
    // ... while the struct's other methods are wrapped as before.
    assert!(source.contains("fn rustcall_Acc_add("), "{source}");
    assert!(source.contains("fn rustcall_Acc_new("), "{source}");

    // The manifest describes what was emitted: no `echo` for Julia to bind.
    let acc = &expanded.manifest.structs[0];
    let names: Vec<&str> = acc.methods.iter().map(|m| m.name.as_str()).collect();
    assert_eq!(names, ["new", "add"]);

    // rustc stops at the refusal, not inside a generated wrapper.
    let out = rustc("refused", &expanded.source);
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("`Acc::echo` is generic over `T`"),
        "{stderr}"
    );
    assert!(!stderr.contains("cannot find type `T`"), "{stderr}");
}

/// Const parameters and `impl Trait` make a method generic just as well; a
/// lifetime parameter does not, and such a method is still wrapped.
#[test]
fn const_and_impl_trait_are_refused_lifetimes_are_not() {
    let src = r#"
        #[julia]
        pub struct Buf { pub n: i32 }
        impl Buf {
            pub fn sized<const N: usize>(&self) -> usize { N }
            pub fn shown(&self, x: impl Copy) -> i32 { let _ = x; self.n }
            pub fn pick<'a>(&'a self, s: &'a str) -> usize { s.len() + self.n as usize }
        }
    "#;
    let expanded = expand(src).unwrap();
    let source = flat(&expanded.source);
    assert!(
        source.contains("`Buf::sized` is generic over `const N`"),
        "{source}"
    );
    assert!(
        source.contains("`Buf::shown` uses `impl Trait`"),
        "{source}"
    );
    assert!(!source.contains("fn rustcall_Buf_sized"), "{source}");
    assert!(!source.contains("fn rustcall_Buf_shown"), "{source}");
    assert!(source.contains("fn rustcall_Buf_pick("), "{source}");
    let names: Vec<&str> = expanded.manifest.structs[0]
        .methods
        .iter()
        .map(|m| m.name.as_str())
        .collect();
    assert_eq!(names, ["pick"]);

    let lifetimes_only = expand(
        r#"
        #[julia]
        pub struct Buf { pub n: i32 }
        impl Buf {
            pub fn pick<'a>(&'a self, s: &'a str) -> usize { s.len() + self.n as usize }
        }
    "#,
    )
    .unwrap();
    let out = rustc("lifetimes", &lifetimes_only.source);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// A method whose block sits in another module is wrapped at the block
/// (#342); it is refused there the same way.
#[test]
fn a_generic_method_in_a_foreign_block_is_refused() {
    let src = r#"
        #[julia]
        pub struct Gauge { pub v: f64 }
        pub mod ops {
            impl super::Gauge {
                pub fn scaled<T: Into<f64>>(&self, k: T) -> f64 { self.v * k.into() }
                pub fn read(&self) -> f64 { self.v }
            }
        }
    "#;
    let expanded = expand(src).unwrap();
    let source = flat(&expanded.source);
    assert!(
        source.contains("`Gauge::scaled` is generic over `T`"),
        "{source}"
    );
    assert!(!source.contains("fn rustcall_Gauge_scaled"), "{source}");
    assert!(source.contains("fn rustcall_Gauge_read("), "{source}");
    let names: Vec<&str> = expanded.manifest.structs[0]
        .methods
        .iter()
        .map(|m| m.name.as_str())
        .collect();
    assert_eq!(names, ["read"]);
}

/// The refusal exists only where the method does: a generic method gated off
/// by its own, its block's or its struct's `#[cfg]` leaves a block that
/// compiles (PR #470 review, for the crate flavour).
#[test]
fn the_refusal_carries_the_cfg() {
    let src = r#"
        #[julia]
        pub struct Acc { pub total: i64 }
        impl Acc {
            pub fn new() -> Self { Acc { total: 0 } }
            #[cfg(rustcall_never)]
            pub fn echo<T: Copy>(&self, x: T) -> T { x }
        }
        #[cfg(rustcall_never)]
        impl Acc {
            pub fn other<T: Copy>(&self, x: T) -> T { x }
        }

        #[cfg(rustcall_never)]
        #[julia]
        pub struct Gone { pub x: i32 }
        #[cfg(rustcall_never)]
        impl Gone {
            pub fn echo<T: Copy>(&self, x: T) -> T { x }
        }
    "#;
    let expanded = expand(src).unwrap();
    assert!(
        expanded.source.contains("compile_error!"),
        "{}",
        expanded.source
    );
    let out = rustc("gated", &expanded.source);
    assert!(
        out.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&out.stderr),
        expanded.source
    );
}
