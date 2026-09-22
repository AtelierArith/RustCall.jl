use std::{fs, process::Command};

mod support;

use rustcall_core::{
    codegen::transform_struct_crate, expand::expand, extract::extract, manifest::Mode,
};

#[test]
fn string_setters_copy_byte_pairs_in_both_flavours() {
    for flavour in ["inline", "crate"] {
        let declaration = if flavour == "inline" {
            expand("#[julia] pub struct Text { pub value: String }")
                .unwrap()
                .source
        } else {
            transform_struct_crate(
                syn::parse_quote! {
                    pub struct Text { pub value: String }
                },
                &[],
            )
            .to_string()
        };
        let source = format!(
            r#"
            #![allow(non_snake_case)]
            {declaration}
            fn main() {{
                let mut object = Text {{ value: String::new() }};
                for value in ["日本語\0末尾", "", "replacement"] {{
                    Text_set_value(&mut object, value.as_ptr(), value.len());
                    assert_eq!(object.value, value);
                    assert_eq!(Text_set_value_take_panic(std::ptr::null_mut(), 0), 0);
                }}
            }}
        "#
        );
        let dir = std::env::temp_dir().join(format!(
            "rustcall_string_setter_{}_{flavour}",
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
            "{flavour}: {}",
            String::from_utf8_lossy(&run.stderr)
        );
        fs::remove_dir_all(dir).unwrap();
    }
}

#[test]
fn accessor_channels_are_reserved() {
    let source = r#"
        #[julia] pub struct rustcall_Fields { pub value: i32 }
        #[julia] pub fn Fields_get_value_take_panic() {}
    "#;
    assert!(extract(source, Mode::Crate).is_err());
    let mixed = source.replace("#[julia] pub fn", "#[pyfunction] pub fn");
    assert!(extract(&mixed, Mode::Crate).unwrap().functions[0]
        .skip_reason
        .starts_with("symbol_collision:"));
    let python = mixed.replace(
        "#[julia] pub struct rustcall_Fields",
        "#[pyclass(get_all)] pub struct Fields",
    );
    let manifest = extract(&python, Mode::Crate).unwrap();
    assert!(manifest.structs[0].fields[0].getter.is_empty());
}

/// A `Vec` field gets no accessor (#453), so the only generated helper that runs
/// user code is the inline flavour's `<Struct>_clone`: it must contain a panic
/// raised by an element's `Clone`.
#[test]
fn generated_clone_helper_contains_clone_panics() {
    for flavour in ["inline", "crate"] {
        let declaration = if flavour == "inline" {
            expand("#[julia] #[derive(Clone)] pub struct Fields { pub values: Vec<Explode> }")
                .unwrap()
                .source
        } else {
            transform_struct_crate(
                syn::parse_quote! {
                    pub struct Fields { pub values: Vec<Explode> }
                },
                &[],
            )
            .to_string()
        };
        assert!(!declaration.contains("Fields_get_values"), "{flavour}");
        assert!(!declaration.contains("Fields_set_values"), "{flavour}");
        let clone_probe = if flavour == "inline" {
            r#"
                let object = std::mem::ManuallyDrop::new(Fields { values: vec![Explode { fail: true }] });
                let mut bytes = [0u8; 512];
                assert!(Fields_clone(&*object).is_null());
                let n = Fields_clone_take_panic(bytes.as_mut_ptr(), bytes.len());
                assert!(std::str::from_utf8(&bytes[..n]).unwrap().contains("accessor clone panic"));
                assert_eq!(Fields_clone_take_panic(bytes.as_mut_ptr(), bytes.len()), 0);
            "#
        } else {
            r#"
                let _ = Fields { values: vec![Explode { fail: false }] };
            "#
        };
        let source = format!(
            r#"
            #![allow(non_snake_case, improper_ctypes_definitions, dead_code)]
            {declaration}
            pub struct Explode {{ fail: bool }}
            impl Clone for Explode {{
                fn clone(&self) -> Self {{
                    if self.fail {{ panic!("accessor clone panic"); }}
                    Self {{ fail: false }}
                }}
            }}
            fn main() {{
                {clone_probe}
            }}
        "#
        );
        let dir = std::env::temp_dir().join(format!(
            "rustcall_accessor_{}_{flavour}",
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
            "{flavour}: {}",
            String::from_utf8_lossy(&run.stderr)
        );
        fs::remove_dir_all(dir).unwrap();
    }
}
