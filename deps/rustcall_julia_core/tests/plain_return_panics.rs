//! A panic in a wrapper whose return type is not valid all-zero (#462).
//!
//! The panic sentinel of a plain return used to be `mem::zeroed::<T>()`, and
//! nothing checks that a plain return type admits the all-zero bit pattern: a
//! `#[julia]` function returning `&T`, `Box<T>`, `NonZero*` or a function
//! pointer compiled, and the first panic then hit rustc's non-unwinding
//! "attempted to zero-initialize" check and **aborted the process** — the very
//! failure the `catch_unwind` boundary exists to prevent. The wrapper now
//! returns `MaybeUninit<T>` (same ABI as `T`) and `MaybeUninit::zeroed()` after
//! a panic. This compiles the generated code of both flavours with a plain
//! `rustc`, runs it, and requires the process to survive every panic.

use std::{fs, process::Command};

mod support;

use rustcall_julia_core::{
    codegen::{transform_function, transform_impl_crate, transform_struct_crate, PanicHook},
    expand::expand,
};

/// Functions whose return types reject the all-zero pattern, and one
/// `#[repr(C)]` aggregate that holds such a value — the case no return-type
/// check could have caught, because the proc macro cannot see inside it.
const ITEMS: &str = r#"
    pub static SEVEN: i32 = 7;
    extern "C" fn seven() -> i32 { 7 }
    #[repr(C)]
    pub struct Holds { pub r: &'static i32 }

    #[julia]
    pub fn borrowed(fail: bool) -> &'static i32 {
        if fail { panic!("borrowed panic"); }
        &SEVEN
    }
    #[julia]
    pub fn nonzero(fail: bool) -> std::num::NonZeroU32 {
        if fail { panic!("nonzero panic"); }
        std::num::NonZeroU32::new(7).unwrap()
    }
    #[julia]
    pub fn boxed(fail: bool) -> Box<i32> {
        if fail { panic!("boxed panic"); }
        Box::new(7)
    }
    #[julia]
    pub fn callback(fail: bool) -> extern "C" fn() -> i32 {
        if fail { panic!("callback panic"); }
        seven
    }
    #[julia]
    pub fn aggregate(fail: bool) -> Holds {
        if fail { panic!("aggregate panic"); }
        Holds { r: &SEVEN }
    }
"#;

const METHODS: &str = r#"
    #[julia]
    pub struct Counter { pub n: i32 }
    #[julia]
    impl Counter {
        #[julia]
        pub fn peek(&self, fail: bool) -> &'static i32 {
            if fail { panic!("method panic"); }
            &SEVEN
        }
    }
"#;

/// The crate flavour: every `#[julia]` item through its proc-macro entry point.
fn crate_flavour() -> String {
    let file: syn::File = syn::parse_str(&format!("{ITEMS}\n{METHODS}")).unwrap();
    let mut out = String::new();
    for item in file.items {
        // Items inside the impl keep their own `#[julia]`: the block's
        // expansion reads and strips them.
        let tokens = match item {
            syn::Item::Fn(mut f) => {
                if strip_julia(&mut f.attrs) {
                    transform_function(f, &[], PanicHook::Runtime)
                } else {
                    quote::quote! { #f }
                }
            }
            syn::Item::Struct(mut s) => {
                if strip_julia(&mut s.attrs) {
                    transform_struct_crate(s, &[])
                } else {
                    quote::quote! { #s }
                }
            }
            syn::Item::Impl(mut i) => {
                strip_julia(&mut i.attrs);
                transform_impl_crate(i, &[])
            }
            other => quote::quote! { #other },
        };
        out.push_str(&tokens.to_string());
        out.push('\n');
    }
    out
}

fn strip_julia(attrs: &mut Vec<syn::Attribute>) -> bool {
    let before = attrs.len();
    attrs.retain(|a| !a.path().is_ident("julia"));
    attrs.len() != before
}

#[test]
fn a_panic_under_a_non_zeroable_return_is_contained() {
    for flavour in ["inline", "crate"] {
        let declaration = if flavour == "inline" {
            expand(&format!("{ITEMS}\n{METHODS}")).unwrap().source
        } else {
            crate_flavour()
        };
        let source = format!(
            r#"
            #![allow(non_snake_case, improper_ctypes_definitions, dead_code)]
            {declaration}

            fn take(reader: extern "C" fn(*mut u8, usize) -> usize) -> String {{
                let mut bytes = [0u8; 256];
                let n = reader(bytes.as_mut_ptr(), bytes.len());
                String::from_utf8(bytes[..n].to_vec()).unwrap()
            }}

            fn main() {{
                // Every wrapper survives its panic and reports it on its channel.
                let _ = rustcall_borrowed(true);
                assert!(take(rustcall_borrowed_take_panic).contains("borrowed panic"));
                let _ = rustcall_nonzero(true);
                assert!(take(rustcall_nonzero_take_panic).contains("nonzero panic"));
                let _ = rustcall_boxed(true);
                assert!(take(rustcall_boxed_take_panic).contains("boxed panic"));
                let _ = rustcall_callback(true);
                assert!(take(rustcall_callback_take_panic).contains("callback panic"));
                let _ = rustcall_aggregate(true);
                assert!(take(rustcall_aggregate_take_panic).contains("aggregate panic"));
                let counter = Counter {{ n: 0 }};
                let _ = rustcall_Counter_peek(&counter, true);
                assert!(take(rustcall_Counter_peek_take_panic).contains("method panic"));

                // ...and hands the value over unchanged when nothing panics.
                unsafe {{
                    assert_eq!(*rustcall_borrowed(false).assume_init(), 7);
                    assert_eq!(rustcall_nonzero(false).assume_init().get(), 7);
                    assert_eq!(*rustcall_boxed(false).assume_init(), 7);
                    assert_eq!((rustcall_callback(false).assume_init())(), 7);
                    assert_eq!(*rustcall_aggregate(false).assume_init().r, 7);
                    assert_eq!(*rustcall_Counter_peek(&counter, false).assume_init(), 7);
                }}
                assert!(take(rustcall_borrowed_take_panic).is_empty());
            }}
        "#
        );
        let dir = std::env::temp_dir().join(format!(
            "rustcall_plain_return_{}_{flavour}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("probe.rs");
        let binary = dir.join(format!("probe{}", std::env::consts::EXE_SUFFIX));
        fs::write(&input, source).unwrap();
        let compile = Command::new("rustc")
            .args(["--edition=2021", "-C", "panic=unwind"])
            .arg("--extern")
            .arg(support::runtime_extern_arg(&dir))
            .arg(&input)
            .arg("-o")
            .arg(&binary)
            .output()
            .unwrap();
        assert!(
            compile.status.success(),
            "{flavour}: {}",
            String::from_utf8_lossy(&compile.stderr)
        );
        let run = Command::new(&binary).output().unwrap();
        assert!(
            run.status.success(),
            "{flavour}: the probe did not survive its panics: {:?}\n{}",
            run.status,
            String::from_utf8_lossy(&run.stderr)
        );
        fs::remove_dir_all(dir).unwrap();
    }
}
