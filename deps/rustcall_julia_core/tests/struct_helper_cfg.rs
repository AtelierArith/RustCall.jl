//! Every item generated for a struct carries the `#[cfg]` of what it touches
//! (#462).
//!
//! The inline flavour used to emit a struct's destructor, accessors, `clone`,
//! string buffers and method wrappers with no `#[cfg]` at all, so a
//! `#[cfg(unix)] struct` got an ungated `<Struct>_free` naming a type that does
//! not exist off unix; and neither flavour copied a **field's** own `#[cfg]`
//! onto its accessors. Under a `--cfg-file` the extractor prunes the struct and
//! the defect is latent; without one (`expand` with no configuration, which is
//! what the golden run does) the generated source does not compile.
//!
//! `rustcall_never` is a cfg no configuration sets: lenient evaluation cannot
//! decide it, so the items are kept and reach rustc, which drops them.

use std::{fs, process::Command};

mod support;

use rustcall_julia_core::{codegen::transform_struct_crate, expand::expand};

const INLINE: &str = r#"
    #[cfg(rustcall_never)]
    #[julia]
    #[derive(Clone)]
    pub struct Gone { pub x: i32, pub name: String }

    #[cfg(rustcall_never)]
    impl Gone {
        pub fn new(x: i32) -> Self { Self { x, name: String::new() } }
        pub fn label(&self) -> String { self.name.clone() }
        pub fn view(&self) -> &str { &self.name }
    }

    #[julia]
    pub struct Kept {
        pub x: i32,
        #[cfg(rustcall_never)]
        pub gone: i32,
        #[cfg(rustcall_never)]
        pub gone_name: String,
    }

    impl Kept {
        pub fn new(x: i32) -> Self { Self { x, #[cfg(rustcall_never)] gone: 0, #[cfg(rustcall_never)] gone_name: String::new() } }
    }
"#;

fn compiles(label: &str, source: &str, runtime: bool) {
    let dir = std::env::temp_dir().join(format!(
        "rustcall_struct_cfg_{}_{label}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    let input = dir.join("lib.rs");
    fs::write(
        &input,
        format!("#![allow(non_snake_case, unexpected_cfgs, dead_code)]\n{source}"),
    )
    .unwrap();
    let mut rustc = Command::new("rustc");
    rustc.args([
        "--edition=2021",
        "--crate-type=cdylib",
        "-C",
        "panic=unwind",
    ]);
    if runtime {
        rustc.arg("--extern").arg(support::runtime_extern_arg(&dir));
    }
    let out = rustc
        .arg(&input)
        .arg("--out-dir")
        .arg(&dir)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{label}: {}\n{source}",
        String::from_utf8_lossy(&out.stderr)
    );
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn inline_struct_helpers_carry_the_struct_and_field_cfg() {
    let expanded = expand(INLINE).unwrap();
    let flat: String = expanded
        .source
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    // Every generated item of the gated struct is gated by its predicate...
    for item in [
        "pub extern \"C\" fn Gone_free(",
        "pub extern \"C\" fn Gone_get_x(",
        "pub extern \"C\" fn Gone_set_name(",
        "pub extern \"C\" fn Gone_clone(",
        "pub struct Gone_RustCallOwnedString",
        "pub struct Gone_RustCallBorrowedString",
        "pub extern \"C\" fn rustcall_Gone_label(",
    ] {
        let at = flat.find(item).unwrap_or_else(|| panic!("no {item}"));
        assert!(
            flat[..at].ends_with("#[cfg(rustcall_never)] #[no_mangle] ")
                || flat[..at].ends_with("#[cfg(rustcall_never)] #[repr(C)] "),
            "{item} is not gated: {}",
            &flat[at.saturating_sub(120)..at]
        );
    }
    // ...and a gated field's accessors by the field's.
    for item in ["Kept_get_gone(", "Kept_set_gone_name("] {
        let at = flat.find(item).unwrap_or_else(|| panic!("no {item}"));
        assert!(
            flat[..at].ends_with("#[cfg(rustcall_never)] #[no_mangle] pub extern \"C\" fn "),
            "{item} is not gated"
        );
    }
    compiles("inline", &expanded.source, false);
}

/// A generic struct's wrappers are emitted (unexported) into the expanded
/// source next to it, so they carry its `#[cfg]` too, and a field's or a
/// method's own on top (PR #470 review).
#[test]
fn generic_inline_struct_wrappers_carry_the_cfg() {
    let src = r#"
        #[cfg(rustcall_never)]
        #[julia]
        pub struct GonePair<T> { pub a: T }
        #[cfg(rustcall_never)]
        impl<T: Copy> GonePair<T> {
            pub fn new(a: T) -> Self { Self { a } }
            pub fn first(&self) -> T { self.a }
        }

        #[julia]
        pub struct KeptPair<T> {
            pub a: T,
            #[cfg(rustcall_never)]
            pub gone: T,
        }
        impl<T: Copy> KeptPair<T> {
            pub fn first(&self) -> T { self.a }
            #[cfg(rustcall_never)]
            pub fn gone(&self) -> T { self.gone }
        }
    "#;
    let expanded = expand(src).unwrap();
    let s = |name: &str| {
        expanded
            .manifest
            .structs
            .iter()
            .find(|s| s.name == name)
            .unwrap()
    };
    for w in &s("GonePair").generic_wrappers {
        assert!(w.source.contains("#[cfg(rustcall_never)]"), "{}", w.source);
    }
    for w in &s("KeptPair").generic_wrappers {
        let gated = w.source.contains("#[cfg(rustcall_never)]");
        let expected = w.name.ends_with("_gone");
        assert_eq!(gated, expected, "{}", w.source);
    }
    compiles("generic", &expanded.source, false);
}

#[test]
fn crate_field_accessors_carry_the_field_cfg() {
    let item: syn::ItemStruct = syn::parse_quote! {
        pub struct Kept {
            pub x: i32,
            #[cfg(rustcall_never)]
            pub gone: i32,
            #[cfg(rustcall_never)]
            pub gone_name: String,
        }
    };
    let generated = transform_struct_crate(item, &[]).to_string();
    compiles("crate", &generated, true);
}
