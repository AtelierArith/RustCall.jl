//! Optional numeric slice ABI (#619): an `i32` presence tag followed by the
//! typed pointer and `usize` length a required slice uses.
use rustcall_julia_core::{expand::expand, extract::extract_crate};
use std::{fs, process::Command};

const SOURCE: &str = r#"
#[julia]
pub fn sum(xs: Option<&[f64]>) -> f64 { xs.map_or(-1.0, |x| x.iter().sum()) }
#[julia]
pub fn present(xs: Option<&[f64]>) -> i32 { xs.is_some() as i32 }
#[julia]
pub fn len(xs: Option<&[f64]>) -> usize { xs.map_or(usize::MAX, |x| x.len()) }
#[julia]
pub fn fill(xs: Option<&mut [f64]>, delta: f64) -> usize {
    match xs {
        Some(x) => { for v in x.iter_mut() { *v += delta; } x.len() }
        None => 0,
    }
}
"#;

fn compile(label: &str, source: &str, main: &str) -> std::process::Output {
    let dir = std::env::temp_dir().join(format!(
        "rustcall_optional_slice_{}_{label}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    let input = dir.join("main.rs");
    let output = dir.join(format!("out{}", std::env::consts::EXE_SUFFIX));
    fs::write(
        &input,
        format!("#![allow(dead_code, non_snake_case, unexpected_cfgs)]\n{source}\nfn main() {{ {main} }}"),
    )
    .unwrap();
    let out = Command::new("rustc")
        .args(["--edition=2021", "-C", "panic=unwind", "-o"])
        .arg(&output)
        .arg(input)
        .output()
        .unwrap();
    // Compiling only proves the ABI shapes type-check; run the generated
    // executable so the presence/payload assertions and the panic-channel
    // check actually execute.
    let out = if out.status.success() {
        Command::new(&output).output().unwrap()
    } else {
        out
    };
    fs::remove_dir_all(dir).ok();
    out
}

#[test]
fn optional_slice_metadata_is_explicit_in_both_frontends() {
    for manifest in [
        expand(SOURCE).unwrap().manifest,
        extract_crate(SOURCE).unwrap(),
    ] {
        let sum = manifest.functions.iter().find(|f| f.name == "sum").unwrap();
        assert_eq!(sum.args[0].abi, "option_slice");
        assert_eq!(sum.args[0].slice_element, "f64");
        assert_eq!(sum.args[0].slice_length, "usize");
        let fill = manifest
            .functions
            .iter()
            .find(|f| f.name == "fill")
            .unwrap();
        assert_eq!(fill.args[0].abi, "option_slice_mut");
        assert_eq!(fill.args[0].slice_element, "f64");
        assert_eq!(fill.args[0].slice_length, "usize");
        assert!(manifest.functions.iter().all(|f| f.skip_reason.is_empty()));
    }
    // The element vocabulary is the required-slice vocabulary.
    for (ty, expected) in [
        ("f32", "f32"),
        ("core::primitive::i64", "i64"),
        ("usize", "usize"),
        ("num_complex::Complex<f32>", "complex32"),
        ("num_complex::Complex64", "complex64"),
        ("num_complex::Complex<f64>", "complex64"),
    ] {
        let src = format!(
            "#[julia] pub fn f(x: Option<&[{ty}]>) -> usize {{ x.map_or(0, |x| x.len()) }}"
        );
        let manifest = extract_crate(&src).unwrap();
        assert_eq!(manifest.functions[0].args[0].abi, "option_slice");
        assert_eq!(manifest.functions[0].args[0].slice_element, expected);
        assert_eq!(manifest.functions[0].args[0].slice_length, "usize");
        assert!(manifest.functions[0].skip_reason.is_empty(), "{src}");
    }
}

#[test]
fn optional_slice_lowering_reconstructs_absent_and_present_values() {
    let expanded = expand(SOURCE).unwrap();
    assert!(expanded.source.contains("rustcall_sum_slice_ptr_len_v1"));
    assert!(expanded.source.contains("rustcall_fill_slice_ptr_len_v1"));
    let out = compile(
        "values",
        &expanded.source,
        r#"
 let xs = [1.0, 2.0, 3.0];
 assert_eq!(unsafe { rustcall_sum(0, std::ptr::null(), 0).assume_init() }, -1.0);
 assert_eq!(unsafe { rustcall_sum(1, xs.as_ptr(), xs.len()).assume_init() }, 6.0);
 assert_eq!(unsafe { rustcall_sum(1, xs.as_ptr(), 0).assume_init() }, 0.0);
 assert_eq!(unsafe { rustcall_present(0, std::ptr::null(), 0).assume_init() }, 0);
 assert_eq!(unsafe { rustcall_present(1, xs.as_ptr(), 0).assume_init() }, 1);
 assert_eq!(unsafe { rustcall_len(0, std::ptr::null(), 0).assume_init() }, usize::MAX);
 assert_eq!(unsafe { rustcall_len(1, xs.as_ptr(), 0).assume_init() }, 0);
 // The pointer and length of an absent value are never validated or read.
 assert_eq!(unsafe { rustcall_len(0, 1usize as *const f64, usize::MAX).assume_init() }, usize::MAX);
 assert_eq!(unsafe { rustcall_sum(0, 1usize as *const f64, usize::MAX).assume_init() }, -1.0);
 let mut ys = [1.0, 2.0, 3.0];
 assert_eq!(unsafe { rustcall_fill(1, ys.as_mut_ptr(), ys.len(), 2.5).assume_init() }, 3);
 assert_eq!(ys, [3.5, 4.5, 5.5]);
 assert_eq!(unsafe { rustcall_fill(0, std::ptr::null_mut(), 0, 1.0).assume_init() }, 0);
 let mut buf = [0u8; 256];
 // A present nonempty slice with a null pointer is refused through the
 // panic channel, before any reference is formed.
 rustcall_fill(1, std::ptr::null_mut(), 1, 1.0);
 assert!(rustcall_fill_take_panic(buf.as_mut_ptr(), buf.len()) > 0);
 "#,
    );
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn optional_slice_refuses_unsupported_layouts_and_retention() {
    for src in [
        "#[julia] pub fn f(x: Option<&[bool]>) {}",
        "#[julia] pub fn f(x: Option<&[char]>) {}",
        "#[julia] pub fn f(x: Option<&[Vec<f64>]>) {}",
        "#[julia] pub fn f(x: Option<&'static [f64]>) {}",
        "#[julia] pub fn f<'a: 'static>(x: Option<&'a [f64]>) {}",
        "#[julia] pub fn f<'a>(x: Option<&'a [f64]>) -> &'a [f64] { unimplemented!() }",
        "#[julia] pub fn f<'a>(x: Option<&'a [f64]>, saved: &mut Vec<&'a [f64]>) { saved.extend(x); }",
        "#[julia] pub async fn f(x: Option<&[f64]>) {}",
        "#[julia] pub struct Owner { pub value: i32 } #[julia] pub fn f(x: Option<&[Owner]>) {}",
    ] {
        let expanded = expand(src).unwrap();
        assert!(
            !expanded.manifest.functions[0].skip_reason.is_empty(),
            "{src}"
        );
        assert!(expanded.source.contains("compile_error!"), "{src}");
        // The crate scan makes the same decision (#503).
        assert!(
            !extract_crate(src).unwrap().functions[0]
                .skip_reason
                .is_empty(),
            "{src}"
        );
    }
    let generic =
        expand("#[julia] pub fn f<T>(x: Option<&[T]>) -> usize { x.map_or(0, |x| x.len()) }")
            .unwrap();
    assert_eq!(
        generic.manifest.functions[0].skip_reason,
        "slice_signature:generic"
    );
    // `Option<Vec<T>>` is neither a slice nor a borrowed owner.
    let owned =
        expand("#[julia] pub fn f(x: Option<Vec<f64>>) -> usize { x.map_or(0, |x| x.len()) }")
            .unwrap();
    assert!(!owned.manifest.functions[0].skip_reason.is_empty());
}

#[test]
fn optional_slice_marker_claims_cfg_and_return_shapes() {
    let source = r#"
        #[julia] pub fn plain(x: Option<&[f64]>) -> usize { x.map_or(0, |x| x.len()) }
        #[julia] pub fn text(x: Option<&[f64]>) -> String { x.map_or(0, |x| x.len()).to_string() }
        #[julia] pub fn optional(x: Option<&[f64]>) -> Option<f64> { x.and_then(|v| v.first().copied()) }
        #[julia] pub struct Owner { pub n: usize }
        #[julia] impl Owner {
            #[julia] pub fn new(x: Option<&[f64]>) -> Self { Self { n: x.map_or(0, |v| v.len()) } }
            #[julia] pub fn checked(x: Option<&[f64]>) -> Result<Self,String> { Ok(Self::new(x)) }
            #[julia] pub fn sum(&self, x: Option<&[f64]>) -> f64 { x.map_or(0.0, |v| v.iter().sum()) }
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
        expand("#[cfg(any())] #[julia] pub fn off(x: Option<&[f64]>) -> usize { 0 }").unwrap();
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
    let collision =
        "#[julia] pub fn f(x: Option<&[f64]>) {} #[julia] pub fn f_slice_ptr_len_v1() {}";
    assert!(rustcall_julia_core::extract::extract_crate(collision).is_err());
    assert!(expand(collision).unwrap().source.contains("compile_error!"));
}
