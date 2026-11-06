//! Nullable thin owner-pointer contract (#571), shared by both front ends.
use rustcall_julia_core::{expand::expand, extract::extract_crate};
use std::{fs, process::Command};

const SOURCE: &str = r#"
#[julia] pub struct Owner { pub value: i32 }
#[julia] pub fn sum(a: Option<&Owner>, b: Option<&Owner>) -> i32 {
 a.map_or(0, |v| v.value) + b.map_or(0, |v| v.value)
}
#[julia] pub fn mutate(a: Option<&mut Owner>, b: &Owner) -> i32 {
 if let Some(v) = a { v.value += b.value; v.value } else { b.value }
}
"#;

fn compile(label: &str, source: &str, main: Option<&str>) -> std::process::Output {
    let dir =
        std::env::temp_dir().join(format!("rustcall_optional_{}_{label}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let input = dir.join("lib.rs");
    let output = dir.join(format!("out{}", std::env::consts::EXE_SUFFIX));
    fs::write(
        &input,
        format!(
            "#![allow(dead_code, non_snake_case, unexpected_cfgs)]\n{source}\n{}",
            main.map_or(String::new(), |m| format!("fn main() {{ {m} }}"))
        ),
    )
    .unwrap();
    let out = Command::new("rustc")
        .args([
            "--crate-type",
            if main.is_some() { "bin" } else { "cdylib" },
            "-C",
            "panic=unwind",
            "-o",
        ])
        .arg(&output)
        .arg(input)
        .output()
        .unwrap();
    let out = if out.status.success() && main.is_some() {
        Command::new(&output).output().unwrap()
    } else {
        out
    };
    fs::remove_dir_all(dir).ok();
    out
}

#[test]
fn optional_metadata_is_explicit_in_both_frontends() {
    let inline = expand(SOURCE).unwrap();
    for m in [&inline.manifest, &extract_crate(SOURCE).unwrap()] {
        let sum = m.functions.iter().find(|f| f.name == "sum").unwrap();
        for a in &sum.args {
            assert_eq!((&*a.abi, &*a.handle), ("handle_optional", "Owner"));
        }
        let mutate = m.functions.iter().find(|f| f.name == "mutate").unwrap();
        assert_eq!(
            (&*mutate.args[0].abi, &*mutate.args[0].handle),
            ("handle_optional_mut", "Owner")
        );
        assert_eq!(
            (&*mutate.args[1].abi, &*mutate.args[1].handle),
            ("handle", "Owner")
        );
    }
}

#[test]
fn multiple_optional_arguments_compile_and_reconstruct_none_some() {
    let expanded = expand(SOURCE).unwrap();
    assert!(expanded
        .source
        .contains("rustcall_sum_optional_owner_ptr_v1"));
    let out = compile(
        "pairs",
        &expanded.source,
        Some(
            r#"
 let mut a = Owner { value: 7 }; let b = Owner { value: 11 };
 assert_eq!(unsafe { rustcall_sum(std::ptr::null(), std::ptr::null()).assume_init() }, 0);
 assert_eq!(unsafe { rustcall_sum(&a, std::ptr::null()).assume_init() }, 7);
 assert_eq!(unsafe { rustcall_sum(std::ptr::null(), &b).assume_init() }, 11);
 assert_eq!(unsafe { rustcall_sum(&a, &b).assume_init() }, 18);
 assert_eq!(unsafe { rustcall_mutate(&mut a, &b).assume_init() }, 18);
 assert_eq!(unsafe { rustcall_mutate(std::ptr::null_mut(), &b).assume_init() }, 11);
 "#,
        ),
    );
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn shadowed_option_and_unsized_alias_cannot_claim_nullable_owner_abi() {
    for (label, source) in [
 ("shadow", "pub enum Option<T> { None, Some(T) } #[julia] pub struct Owner { pub n: i32 } #[julia] pub fn f(x: Option<&Owner>) -> i32 { 1 }"),
 ("dst", "type Owner = [i32]; #[julia] pub fn f(x: Option<&Owner>) -> i32 { 1 }")
 ] {
  let expanded = expand(source).unwrap(); let out = compile(label, &expanded.source, None);
  assert!(!out.status.success(), "{label} unexpectedly accepted");
 }
}

#[test]
fn optional_owner_lifetimes_and_unsupported_shapes_are_precise_refusals() {
    for signature in [
        "pub fn f(v: Option<&'static Owner>) -> i32 { 0 }",
        "pub fn f(v: Option<&Owner>) -> &str { unimplemented!() }",
        "pub fn f<'a>(v: Option<&'a Owner>) -> &'a str { unimplemented!() }",
        "pub fn f<'a>(v: Option<&'a Owner>) -> &'a i32 { &v.unwrap().value }",
        "pub fn f<'a>(v: Option<&'a Owner>, keep: Holder<'a>) -> i32 { 0 }",
        "pub fn f<'a: 'static>(v: Option<&'a Owner>) -> i32 { 0 }",
        "pub async fn f(v: Option<&Owner>) -> i32 { 0 }",
        "pub fn f<T>(v: Option<&Owner>, x: T) -> i32 { 0 }",
        "pub fn f(v: Option<Option<&Owner>>) -> i32 { 0 }",
        "pub fn f(v: Option<Box<Owner>>) -> i32 { 0 }",
        "pub fn f(v: Option<*const Owner>) -> i32 { 0 }",
        "pub fn f(v: Option<&[i32]>) -> i32 { 0 }",
    ] {
        let source = format!("#[julia] pub struct Owner {{ pub value: i32 }} pub struct Holder<'a>(std::marker::PhantomData<&'a i32>); #[julia] {signature}");
        for m in [
            expand(&source).unwrap().manifest,
            extract_crate(&source).unwrap(),
        ] {
            let f = m.functions.iter().find(|f| f.name == "f").unwrap();
            assert!(
                f.skip_reason.starts_with("optional_owner_signature:")
                    || (signature.contains("f<T>")
                        && f.skip_reason.starts_with("generic_signature:")),
                "{signature}: {}",
                f.skip_reason
            );
        }
    }
}

#[test]
fn optional_owner_unbounded_named_lifetime_is_lowered_call_locally() {
    let source = "#[julia] pub struct Owner { pub value: i32 } #[julia] pub fn f<'a>(v: Option<&'a Owner>) -> i32 { v.map_or(0, |v| v.value) }";
    let expanded = expand(source).unwrap();
    let out = compile(
        "named",
        &expanded.source,
        Some("assert_eq!(unsafe { rustcall_f(std::ptr::null()).assume_init() }, 0);"),
    );
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn optional_owner_producer_marker_covers_every_return_shape() {
    let source = r#"
    #[julia] pub struct Owner { pub value: i32 }
    #[julia] pub fn scalar(v: Option<&Owner>) -> i32 { 0 }
    #[julia] pub fn label(v: Option<&Owner>) -> &'static str { "static" }
    #[julia] pub fn string(v: Option<&Owner>) -> String { String::new() }
    #[julia] pub fn result(v: Option<&Owner>) -> Result<i32, String> { Ok(0) }
    #[julia] pub fn optional(v: Option<&Owner>) -> Option<i32> { None }
    #[julia] impl Owner {
      #[julia] pub fn new(v: Option<&Owner>) -> Self { Self { value: 0 } }
      #[julia] pub fn checked(v: Option<&Owner>) -> Result<Self, String> { Ok(Self { value: 0 }) }
      #[julia] pub fn scalar(&self, v: Option<&Owner>) -> i32 { 0 }
      #[julia] pub fn string(&self, v: Option<&Owner>) -> String { String::new() }
      #[julia] pub fn result(&self, v: Option<&Owner>) -> Result<i32, String> { Ok(0) }
      #[julia] pub fn optional(&self, v: Option<&Owner>) -> Option<i32> { None }
    }
    "#;
    let expanded = expand(source).unwrap();
    for symbol in [
        "scalar",
        "label",
        "string",
        "result",
        "optional",
        "Owner_new",
        "Owner_checked",
        "Owner_scalar",
        "Owner_string",
        "Owner_result",
        "Owner_optional",
    ] {
        assert!(
            expanded
                .source
                .contains(&format!("rustcall_{symbol}_optional_owner_ptr_v1")),
            "{symbol}"
        );
    }
    let out = compile("return_shapes", &expanded.source, None);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn optional_owner_marker_collisions_are_reported_by_both_frontends() {
    let source = "#[julia] pub struct Owner { pub n: i32 } #[julia] pub fn read(v: Option<&Owner>) -> i32 { 0 } #[julia] pub fn read_optional_owner_ptr_v1() -> u8 { 1 }";
    let inline = expand(source).unwrap();
    assert!(inline
        .manifest
        .duplicate_symbols()
        .iter()
        .any(|(symbol, _, _)| symbol == "rustcall_read_optional_owner_ptr_v1"));
    assert!(inline.source.contains("compile_error"));
    assert!(extract_crate(source)
        .unwrap_err()
        .to_string()
        .contains("rustcall_read_optional_owner_ptr_v1"));
}

#[test]
fn optional_owner_methods_cannot_return_borrowed_string_views() {
    for method in [
        "pub fn label(v: Option<&Owner>) -> &str { unimplemented!() }",
        "pub fn label<'a>(v: Option<&'a Owner>) -> &'a str { unimplemented!() }",
        "pub fn label(&self, v: Option<&Owner>) -> &str { unimplemented!() }",
        "pub fn label<'a>(&self, v: Option<&'a Owner>) -> &'a str { unimplemented!() }",
    ] {
        let source = format!("#[julia] pub struct Owner {{ pub n: i32 }} #[julia] impl Owner {{ #[julia] {method} }}");
        for m in [
            expand(&source).unwrap().manifest,
            extract_crate(&source).unwrap(),
        ] {
            let entry = m.structs[0]
                .methods
                .iter()
                .find(|m| m.name == "label")
                .unwrap();
            assert_eq!(entry.skip_reason, "optional_owner_signature:v", "{method}");
        }
    }
}
