use std::{fs, process::Command};

use rustcall_core::{
    codegen::transform_struct_crate, expand::expand, extract::extract, manifest::Mode,
};

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

#[test]
fn generated_accessors_contain_clone_and_drop_panics() {
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
        let clone_probe = if flavour == "inline" {
            r#"
                assert!(Fields_clone(&*object).is_null());
                let n = Fields_clone_take_panic(bytes.as_mut_ptr(), bytes.len());
                assert!(std::str::from_utf8(&bytes[..n]).unwrap().contains("accessor clone panic"));
                assert_eq!(Fields_clone_take_panic(bytes.as_mut_ptr(), bytes.len()), 0);
            "#
        } else {
            ""
        };
        let source = format!(
            r#"
            #![allow(non_snake_case, improper_ctypes_definitions)]
            {declaration}
            pub struct Explode {{ fail: bool }}
            impl Clone for Explode {{
                fn clone(&self) -> Self {{
                    if self.fail {{ panic!("accessor clone panic"); }}
                    Self {{ fail: false }}
                }}
            }}
            impl Drop for Explode {{
                fn drop(&mut self) {{
                    if self.fail {{ panic!("accessor drop panic"); }}
                }}
            }}
            fn main() {{
                let mut object = std::mem::ManuallyDrop::new(Fields {{ values: vec![Explode {{ fail: true }}] }});
                // The unwind result must be a VALID empty Vec, not zeroed Vec.
                let sentinel = Fields_get_values(&*object);
                assert!(sentinel.is_empty());
                drop(sentinel);
                let mut bytes = [0u8; 512];
                let n = Fields_get_values_take_panic(bytes.as_mut_ptr(), bytes.len());
                assert!(std::str::from_utf8(&bytes[..n]).unwrap().contains("accessor clone panic"));
                assert_eq!(Fields_get_values_take_panic(bytes.as_mut_ptr(), bytes.len()), 0);
                {clone_probe}
                Fields_set_values(&mut *object, Vec::new());
                let n = Fields_set_values_take_panic(bytes.as_mut_ptr(), bytes.len());
                assert!(std::str::from_utf8(&bytes[..n]).unwrap().contains("accessor drop panic"));
                assert_eq!(Fields_set_values_take_panic(bytes.as_mut_ptr(), bytes.len()), 0);
                // Do not rely on the panicking setter's post-panic object state.
                let mut quiet = Fields {{ values: vec![Explode {{ fail: false }}] }};
                assert_eq!(Fields_get_values(&quiet).len(), 1);
                assert_eq!(Fields_get_values_take_panic(bytes.as_mut_ptr(), bytes.len()), 0);
                Fields_set_values(&mut quiet, Vec::new());
                assert_eq!(Fields_set_values_take_panic(bytes.as_mut_ptr(), bytes.len()), 0);
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
