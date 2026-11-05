//! Numeric slice ABI, scope proof and panic containment (#570).
use rustcall_julia_core::{expand::expand, extract::extract_crate};
use std::{fs, process::Command};

const SOURCE: &str = r#"
#[julia]
pub fn transform(x: &[f64], y: &mut [f64]) -> Result<(), String> {
    if x.len() != y.len() { return Err("length mismatch".into()); }
    for (x,y) in x.iter().zip(y) { *y = 2.0 * x; }
    Ok(())
}
#[julia]
pub fn fail(y: &mut [f64]) { y[0] = 9.0; panic!("slice panic"); }
#[julia]
pub fn address(x: &[f64]) -> usize { x.as_ptr() as usize }
"#;

#[test]
fn manifest_declares_element_length_access_in_both_flavours() {
    for manifest in [
        extract_crate(SOURCE).unwrap(),
        expand(SOURCE).unwrap().manifest,
    ] {
        let args = &manifest.functions[0].args;
        assert_eq!(args[0].abi, "slice");
        assert_eq!(args[1].abi, "slice_mut");
        for a in args {
            assert_eq!(a.slice_element, "f64");
            assert_eq!(a.slice_length, "usize");
        }
    }
    for (ty, expected) in [
        ("f32", "f32"),
        ("core::primitive::i64", "i64"),
        ("num_complex::Complex<f32>", "complex32"),
        ("num_complex::Complex64", "complex64"),
    ] {
        let src = format!("#[julia] pub fn f(x: &[{ty}]) -> usize {{ x.len() }}");
        let manifest = extract_crate(&src).unwrap();
        assert_eq!(manifest.functions[0].args[0].slice_element, expected);
        assert!(manifest.functions[0].skip_reason.is_empty());
    }
}

#[test]
fn slices_are_opt_in_and_unsupported_layouts_and_retention_are_refused() {
    let plain =
        expand("#[no_mangle] pub extern \"C\" fn f(x: &[f64]) -> usize { x.len() }").unwrap();
    assert!(plain.manifest.functions[0].args[0].abi.is_empty());
    for src in [
        "#[julia] pub fn f(x: &[bool]) {}",
        "#[julia] pub async fn f(x: &[f64]) {}",
        "#[julia] pub fn f(x: &[Complex64]) {}",
        "#[julia] pub fn f(x: &'static [f64]) {}",
        "#[julia] pub fn f<'a: 'static>(x: &'a [f64]) {}",
        "#[julia] pub fn f<'a>(x: &'a [f64]) -> &'a [f64] { x }",
        "#[julia] pub fn f(x: &[f64]) -> &[f64] { x }",
        "#[julia] pub fn f<'a>(x: &'a [f64], saved: &mut Vec<&'a [f64]>) { saved.push(x); }",
    ] {
        let expanded = expand(src).unwrap();
        assert!(
            !expanded.manifest.functions[0].skip_reason.is_empty(),
            "{src}"
        );
        assert!(expanded.source.contains("compile_error!"), "{src}");
    }
    let generic = expand("#[julia] pub fn f<T>(x: &[T]) -> usize { x.len() }").unwrap();
    assert_eq!(
        generic.manifest.functions[0].skip_reason,
        "slice_signature:generic"
    );
}

#[test]
fn pointer_length_shim_borrows_and_validates_before_reference_creation() {
    let expanded = expand(SOURCE).unwrap();
    let tmp = std::env::temp_dir().join(format!("rustcall_slice_{}", std::process::id()));
    fs::create_dir_all(&tmp).unwrap();
    let source = format!(
        r#"
#![allow(non_snake_case, dead_code, improper_ctypes_definitions)]
{}
fn main() {{
    assert_eq!(rustcall_address_slice_ptr_len_v1(),1);
    assert_eq!(rustcall_transform_slice_ptr_len_v1(),1);
    assert_eq!(rustcall_fail_slice_ptr_len_v1(),1);
    let input = [1.0,2.0]; let mut output = [0.0,0.0];
    assert_eq!(unsafe {{ rustcall_address(input.as_ptr(), 2).assume_init() }}, input.as_ptr() as usize);
    let result = rustcall_transform(input.as_ptr(),2,output.as_mut_ptr(),2);
    assert_eq!(result.is_ok,1); assert_eq!(output,[2.0,4.0]);
    let result = rustcall_transform(std::ptr::null(),0,std::ptr::null_mut(),0);
    assert_eq!(result.is_ok,1);
    // Guard errors travel through the panic channel and never form invalid references.
    rustcall_address(std::ptr::null(),1);
    let mut buf = [0u8;256];
    assert!(rustcall_address_take_panic(buf.as_mut_ptr(),buf.len()) > 0);
    rustcall_address(1usize as *const f64,1);
    assert!(rustcall_address_take_panic(buf.as_mut_ptr(),buf.len()) > 0);
    rustcall_address(input.as_ptr(),usize::MAX);
    assert!(rustcall_address_take_panic(buf.as_mut_ptr(),buf.len()) > 0);
    rustcall_fail(output.as_mut_ptr(),2);
    assert_eq!(output[0],9.0);
    assert!(rustcall_fail_take_panic(buf.as_mut_ptr(),buf.len()) > 0);
}}
"#,
        expanded.source
    );
    let path = tmp.join("main.rs");
    fs::write(&path, source).unwrap();
    let binary = tmp.join(format!("slice_test{}", std::env::consts::EXE_SUFFIX));
    let compile = Command::new("rustc")
        .args(["--edition=2021"])
        .arg(&path)
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
    let _ = fs::remove_dir_all(tmp);
    assert!(
        run.status.success(),
        "{}",
        String::from_utf8_lossy(&run.stderr)
    );
}

#[test]
fn generic_struct_slice_methods_are_explicitly_refused() {
    let expanded = expand(
        r#"
        #[julia] pub struct Generic<T> { pub value: T }
        impl<T: Copy> Generic<T> {
            pub fn new(x: &[f64], value: T) -> Self { let _ = x; Self { value } }
            pub fn read(&self, x: &[T]) -> usize { x.len() }
        }
    "#,
    )
    .unwrap();
    for method in &expanded.manifest.structs[0].methods {
        assert_eq!(
            method.skip_reason, "slice_signature:generic",
            "{}",
            method.name
        );
    }
    assert_eq!(expanded.source.matches("compile_error!").count(), 2);
}

#[test]
fn primitive_and_complex_identity_is_compiler_checked() {
    let tmp = std::env::temp_dir().join(format!("rustcall_slice_identity_{}", std::process::id()));
    fs::create_dir_all(&tmp).unwrap();
    let complex_src = tmp.join("num_complex.rs");
    let complex_rlib = tmp.join("libnum_complex.rlib");
    fs::write(&complex_src, "#[repr(C)] pub struct Complex<T> { pub re: T, pub im: T } pub type Complex64 = Complex<f64>;").unwrap();
    let dependency = Command::new("rustc")
        .args([
            "--edition=2021",
            "--crate-name=num_complex",
            "--crate-type=rlib",
        ])
        .arg(&complex_src)
        .arg("-o")
        .arg(&complex_rlib)
        .output()
        .unwrap();
    assert!(dependency.status.success());
    // Same size and alignment is insufficient: a bool-bearing user type has
    // invalid bit patterns even though Julia's f64 has none.
    for (index, source) in [
        "#[repr(C)] pub struct f64 { flag: bool, rest: [u8;7] } #[julia] pub fn f(x: &mut [f64]) {}",
        "type f64 = bool; #[julia] pub fn f(x: &[f64]) {}",
        "pub mod num_complex { pub struct Complex64 { pub flag: bool } } #[julia] pub fn f(x: &[num_complex::Complex64]) {}",
        "type f64 = bool; extern crate num_complex; #[julia] pub fn f(x: &[num_complex::Complex<f64>]) {}",
    ].iter().enumerate() {
        let expanded = expand(source).unwrap();
        let path = tmp.join(format!("shadow{index}.rs"));
        fs::write(&path, expanded.source).unwrap();
        let output = Command::new("rustc").args(["--edition=2021","--crate-type=lib"])
            .arg(&path).arg("-o").arg(tmp.join(format!("out{index}.rlib"))).output().unwrap();
        assert!(!output.status.success(),"shadowed slice element compiled: {source}");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("mismatched types") || stderr.contains("can't find crate for `num_complex`"), "{stderr}");
    }
    let _ = fs::remove_dir_all(tmp);
}

#[test]
fn slice_marker_claims_cfg_and_return_shapes_are_shared() {
    let source = r#"
        #[julia] pub fn plain(x: &[f64]) -> usize { x.len() }
        #[julia] pub fn text(x: &[f64]) -> String { x.len().to_string() }
        #[julia] pub fn optional(x: &[f64]) -> Option<f64> { x.first().copied() }
        #[julia] pub struct Owner { pub n: usize }
        #[julia] impl Owner {
            #[julia] pub fn new(x: &[f64]) -> Self { Self { n: x.len() } }
            #[julia] pub fn checked(x: &[f64]) -> Result<Self,String> { Ok(Self::new(x)) }
            #[julia] pub fn sum(&self, x: &[f64]) -> f64 { x.iter().sum() }
        }
    "#;
    let expanded = expand(source).unwrap();
    for name in [
        "plain",
        "text",
        "optional",
        "Owner_new",
        "Owner_checked",
        "Owner_sum",
    ] {
        assert!(
            expanded
                .source
                .contains(&format!("fn rustcall_{name}_slice_ptr_len_v1()")),
            "{name}"
        );
    }
    let gated =
        expand("#[cfg(any())] #[julia] pub fn off(x: &[f64]) -> usize { x.len() }").unwrap();
    // The marker carries the item's predicate, just like the wrapper.
    let parsed = syn::parse_file(&gated.source).unwrap();
    let marker = parsed
        .items
        .iter()
        .find_map(|item| match item {
            syn::Item::Fn(f) if f.sig.ident == "rustcall_off_slice_ptr_len_v1" => Some(f),
            _ => None,
        })
        .unwrap();
    assert!(marker.attrs.iter().any(|a| a.path().is_ident("cfg")));
    let collision = "#[julia] pub fn f(x: &[f64]) {} #[julia] pub fn f_slice_ptr_len_v1() {}";
    assert!(rustcall_julia_core::extract::extract_crate(collision).is_err());
    assert!(expand(collision).unwrap().source.contains("compile_error!"));
}
