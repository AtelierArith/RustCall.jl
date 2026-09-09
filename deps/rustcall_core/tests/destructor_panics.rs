use std::fs;
use std::process::Command;

use rustcall_core::codegen::transform_struct_crate;
use rustcall_core::expand::expand;
use rustcall_core::extract::extract;
use rustcall_core::manifest::Mode;

#[test]
fn destructor_channels_participate_in_symbol_collisions() {
    let source = r#"
        #[julia] pub struct rustcall_Bomb;
        #[julia] pub fn Bomb_free_take_panic() {}
    "#;
    assert!(extract(source, Mode::Crate).is_err());

    let mixed = source.replace("#[julia] pub fn", "#[pyfunction] pub fn");
    let manifest = extract(&mixed, Mode::Crate).unwrap();
    assert!(manifest.functions[0]
        .skip_reason
        .starts_with("symbol_collision:"));

    let pyo3 = mixed.replace("#[julia] pub struct", "#[pyclass] pub struct");
    let manifest = extract(&pyo3, Mode::Crate).unwrap();
    assert!(manifest.structs[0]
        .skip_reason
        .starts_with("symbol_collision:"));
}

#[test]
fn generated_destructors_contain_panics_in_both_flavours() {
    for flavour in ["inline", "crate"] {
        let declarations = if flavour == "inline" {
            expand("#[julia] pub struct Bomb; #[julia] pub struct bomb;")
                .unwrap()
                .source
        } else {
            let upper = transform_struct_crate(
                syn::parse_quote!(
                    pub struct Bomb;
                ),
                &[],
            );
            let lower = transform_struct_crate(
                syn::parse_quote!(
                    pub struct bomb;
                ),
                &[],
            );
            format!("{upper}\n{lower}")
        };
        let source = format!(
            r#"
            #![allow(non_camel_case_types, non_snake_case)]
            {declarations}
            impl Drop for Bomb {{
                fn drop(&mut self) {{ panic!("destructor sentinel"); }}
            }}
            fn main() {{
                let ptr = Box::into_raw(Box::new(Bomb));
                Bomb_free(ptr);
                let mut bytes = [0u8; 512];
                let needed = Bomb_free_take_panic(std::ptr::null_mut(), 0);
                assert!(needed > 0);
                let n = Bomb_free_take_panic(bytes.as_mut_ptr(), bytes.len());
                assert_eq!(n, needed);
                let message = std::str::from_utf8(&bytes[..n]).unwrap();
                assert!(message.contains("destructor sentinel"));
                assert_eq!(Bomb_free_take_panic(bytes.as_mut_ptr(), bytes.len()), 0);
                Bomb_free(Box::into_raw(Box::new(Bomb)));
                assert_eq!(Bomb_free_take_panic(std::ptr::null_mut(), usize::MAX), n);
                assert_eq!(Bomb_free_take_panic(std::ptr::null_mut(), usize::MAX), 0);
                Bomb_free(std::ptr::null_mut());
                assert_eq!(Bomb_free_take_panic(bytes.as_mut_ptr(), bytes.len()), 0);
                bomb_free(Box::into_raw(Box::new(bomb)));
                assert_eq!(bomb_free_take_panic(bytes.as_mut_ptr(), bytes.len()), 0);
            }}
            "#
        );
        let dir = std::env::temp_dir().join(format!(
            "rustcall_destructor_panic_{}_{flavour}",
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
        fs::remove_dir_all(&dir).unwrap();
    }
}
