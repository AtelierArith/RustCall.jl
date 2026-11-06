//! Explicit concrete owning result ABI (#572), with no named-type guessing.
use rustcall_julia_core::{expand::expand, extract::extract_crate};
use std::{fs, process::Command};

const SOURCE: &str = r#"
#[julia] pub struct Matrix { pub value: i32 }
#[julia] pub struct Factor { pub value: i32 }
#[julia] impl Matrix {
 #[julia] #[rustcall_owned_return(Factor)]
 pub fn factor(&self) -> Factor { Factor { value: self.value + 1 } }
 #[julia] #[rustcall_owned_return(Factor)]
 pub fn checked(&self, fail: bool) -> Result<Factor, String> {
  if fail { Err("factor error".into()) } else { Ok(Factor { value: self.value + 2 }) }
 }
}
#[julia] #[rustcall_owned_return(Factor)]
pub fn create(value: i32) -> Factor { Factor { value } }
#[julia] #[rustcall_owned_return(Factor)]
pub fn create_checked(value: i32) -> Result<Factor, String> { Ok(Factor { value }) }
"#;

fn compile(label: &str, source: &str, main: Option<&str>) -> std::process::Output {
    let dir = std::env::temp_dir().join(format!("rustcall_owned_{}_{label}", std::process::id()));
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
fn selected_owner_metadata_is_explicit_in_both_frontends() {
    let inline = expand(SOURCE).unwrap();
    for m in [&inline.manifest, &extract_crate(SOURCE).unwrap()] {
        for f in &m.functions {
            assert_eq!(f.return_handle, "Factor", "{}", f.name);
        }
        let matrix = m.structs.iter().find(|s| s.name == "Matrix").unwrap();
        for method in &matrix.methods {
            assert_eq!(method.return_handle, "Factor", "{}", method.name);
        }
        assert_eq!(matrix.methods[0].return_abi, "boxed");
        assert_eq!(matrix.methods[1].ok_abi, "boxed");
    }
}

#[test]
fn concrete_direct_and_result_owners_are_real_thin_boxed_values() {
    let expanded = expand(SOURCE).unwrap();
    for name in [
        "Matrix_factor",
        "Matrix_checked",
        "create",
        "create_checked",
    ] {
        assert!(
            expanded
                .source
                .contains(&format!("rustcall_{name}_owned_return_v1")),
            "{name}"
        );
    }
    let out = compile(
        "values",
        &expanded.source,
        Some(
            r#"
 let matrix=Matrix{value:7};
 let factor=rustcall_Matrix_factor(&matrix); assert!(!factor.is_null());
 assert_eq!(unsafe{(*factor).value},8); Factor_free(factor);
 let result=rustcall_Matrix_checked(&matrix,false); assert_eq!(result.is_ok,1);
 let factor=unsafe{result.ok_value.assume_init()}; assert_eq!(unsafe{(*factor).value},9); Factor_free(factor);
 let err=rustcall_Matrix_checked(&matrix,true); assert_eq!(err.is_ok,0);
 let err=unsafe{err.err_value.assume_init()}; Matrix_free_rust_string(err.ptr,err.len,err.cap);
 let factor=rustcall_create(11); assert_eq!(unsafe{(*factor).value},11); Factor_free(factor);
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
fn actual_returned_owner_must_be_static_and_annotated() {
    for (label,source) in [
 ("borrow_arg", "#[julia] pub struct Owner<'a> { pub text: &'a str } #[julia] #[rustcall_owned_return(Owner)] pub fn make<'a>(text: &'a str) -> Owner<'a> { Owner { text } }"),
 ("borrow_receiver", "#[julia] pub struct Owner<'a> { pub text: &'a str } #[julia] impl<'a> Owner<'a> { #[julia] #[rustcall_owned_return(Owner)] pub fn copy(&self) -> Owner<'a> { Owner { text:self.text } } }"),
 ("receiver_inference", "#[julia] pub struct Source { pub text: String } #[julia] pub struct Owner<'a> { pub text: &'a str } #[julia] impl Source { #[julia] #[rustcall_owned_return(Owner<'static>)] pub fn view(&self) -> Owner<'_> { Owner { text: &self.text } } }"),
        ("plain", "pub struct Plain { pub value:i32 } #[julia] #[rustcall_owned_return(Plain)] pub fn make() -> Plain { Plain { value:1 } }")
 ] {
  let expanded=expand(source).unwrap();let out=compile(label,&expanded.source,None);
  assert!(!out.status.success(),"{label} unexpectedly accepted");
 }
    let source="#[julia] pub struct Owner<'a> { pub text: &'a str } #[julia] #[rustcall_owned_return(Owner<'static>)] pub fn make() -> Owner<'static> { Owner { text: \"static\" } }";
    let expanded = expand(source).unwrap();
    let out = compile("static", &expanded.source, None);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn unknown_and_unsupported_owned_mappings_are_refused_before_binding() {
    for (label,source) in [
 ("unknown", "pub struct Plain; #[julia] #[rustcall_owned_return(Plain)] pub fn f() -> Plain { Plain }"),
 ("option", "#[julia] pub struct Owner; #[julia] #[rustcall_owned_return(Owner)] pub fn f() -> Option<Owner> { None }"),
 ("borrow", "#[julia] pub struct Owner; #[julia] #[rustcall_owned_return(&Owner)] pub fn f() -> Owner { Owner }"),
 ("error", "#[julia] pub struct Owner; #[julia] #[rustcall_owned_return(Owner)] pub fn f() -> Result<Owner,Owner> { Err(Owner) }")
 ] {
  for m in [expand(source).unwrap().manifest,extract_crate(source).unwrap()] {
   let f=m.functions.iter().find(|f|f.name=="f").unwrap();
   assert!(f.skip_reason.starts_with("owned_return:"),"{label}: {}",f.skip_reason);
  }
 }
}

#[test]
fn explicit_owner_type_identity_is_checked_on_the_actual_value() {
    let source = "#[julia] pub struct Owner; #[julia] pub struct Other; #[julia] #[rustcall_owned_return(Owner)] pub fn make() -> Other { Other }";
    let expanded = expand(source).unwrap();
    let out = compile("mismatch", &expanded.source, None);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("mismatched types"));
}

#[test]
fn explicit_owner_marker_collisions_are_reported_by_both_frontends() {
    let source = "#[julia] pub struct Owner; #[julia] #[rustcall_owned_return(Owner)] pub fn make() -> Owner { Owner } #[julia] pub fn make_owned_return_v1() -> u8 { 0 }";
    let inline = expand(source).unwrap();
    assert!(inline
        .manifest
        .duplicate_symbols()
        .iter()
        .any(|(symbol, _, _)| symbol == "rustcall_make_owned_return_v1"));
    assert!(inline.source.contains("compile_error"));
    assert!(extract_crate(source)
        .unwrap_err()
        .to_string()
        .contains("rustcall_make_owned_return_v1"));
}

#[test]
fn owner_marker_does_not_require_legacy_owners_to_be_static() {
    let source = "#[julia] pub struct Owner<'a> { pub text: &'a str }";
    let expanded = expand(source).unwrap();
    let out = compile(
        "legacy_lifetime",
        &expanded.source,
        Some(
            r#"
        fn marked<T: __RustCallOwned>(_: &T) {}
        let text=String::from("local"); let owner=Owner{text:&text}; marked(&owner);
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
fn reconstructed_receiver_borrows_cannot_infer_static_owned_results() {
    let prefix="#[julia] pub struct Source { pub text: String } #[julia] pub struct View<'a> { pub text: &'a str }";
    for (label, item) in [
        ("shared", "#[julia] impl Source { #[julia] #[rustcall_owned_return(View<'static>)] pub fn view(&self) -> View<'_> { View { text: &self.text } } }"),
        ("mutable", "#[julia] impl Source { #[julia] #[rustcall_owned_return(View<'static>)] pub fn view(&mut self) -> View<'_> { View { text: &self.text } } }"),
        ("result", "#[julia] impl Source { #[julia] #[rustcall_owned_return(View<'static>)] pub fn view(&self) -> Result<View<'_>, String> { Ok(View { text: &self.text }) } }"),
        ("mixed", "#[julia] impl Source { #[julia] #[rustcall_owned_return(View<'static>)] pub fn view(&self, independent: &'static i32) -> View<'_> { let _=independent; View { text: &self.text } } }"),
        ("free", "#[julia] #[rustcall_owned_return(View<'static>)] pub fn view(source: &Source) -> View<'_> { View { text: &source.text } }"),
        ("named_free", "#[julia] #[rustcall_owned_return(View<'static>)] pub fn view<'a>(source: &'a Source) -> View<'a> { View { text: &source.text } }"),
    ] {
        let expanded=expand(&format!("{prefix} {item}")).unwrap();
        let out=compile(label,&expanded.source,None);
        assert!(!out.status.success(),"{label} unexpectedly accepted");
        let diagnostic=String::from_utf8_lossy(&out.stderr);
        assert!(diagnostic.contains("'static"),"{label}: {diagnostic}");
    }
    let source=format!("{prefix} #[julia] impl Source {{ #[julia] #[rustcall_owned_return(View<'static>)] pub fn view(&self) -> View<'static> {{ View {{ text: \"independent\" }} }} }}");
    let expanded = expand(&source).unwrap();
    let out = compile("independent_static", &expanded.source, None);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn explicit_owned_return_annotations_on_generic_inline_hosts_are_refused() {
    let source="#[julia] pub struct Factor; #[julia] pub struct Cell<T> { pub value:T } impl<T> Cell<T> { #[julia] #[rustcall_owned_return(Factor)] pub fn factor(&self) -> Factor { Factor } #[julia] #[rustcall_owned_return(Factor)] pub fn new(value:T) -> Factor { let _=value; Factor } }";
    let inline = expand(source).unwrap();
    let cell = inline
        .manifest
        .structs
        .iter()
        .find(|s| s.name == "Cell")
        .unwrap();
    for method in &cell.methods {
        assert_eq!(
            method.skip_reason, "owned_return:generic_owner",
            "{}",
            method.name
        );
        assert!(method.return_handle.is_empty());
    }
    assert!(inline
        .source
        .contains("generic inline host wrappers are unsupported"));
}

#[test]
fn owned_value_bindings_do_not_recreate_unit_struct_owners() {
    let source = r#"
        static DROPS: std::sync::atomic::AtomicUsize=std::sync::atomic::AtomicUsize::new(0);
        #[allow(non_camel_case_types)] #[julia] pub struct rustcall_owner;
        impl Drop for rustcall_owner { fn drop(&mut self) { DROPS.fetch_add(1,std::sync::atomic::Ordering::SeqCst); } }
        #[julia] #[rustcall_owned_return(rustcall_owner)] pub fn make() -> rustcall_owner { rustcall_owner }
    "#;
    let expanded = expand(source).unwrap();
    let out = compile(
        "unit_owner",
        &expanded.source,
        Some(
            r#"
        let pointer=rustcall_make();
        assert_eq!(DROPS.load(std::sync::atomic::Ordering::SeqCst),0);
        rustcall_owner_free(pointer);
        assert_eq!(DROPS.load(std::sync::atomic::Ordering::SeqCst),1);
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
fn owned_result_binding_does_not_recreate_a_unit_struct_payload() {
    let source = r#"
        static DROPS: std::sync::atomic::AtomicUsize=std::sync::atomic::AtomicUsize::new(0);
        #[allow(non_camel_case_types)] #[julia] pub struct __rustcall_owned_ok;
        impl Drop for __rustcall_owned_ok { fn drop(&mut self) { DROPS.fetch_add(1,std::sync::atomic::Ordering::SeqCst); } }
        #[julia] #[rustcall_owned_return(__rustcall_owned_ok)] pub fn make() -> Result<__rustcall_owned_ok,i32> { Ok(__rustcall_owned_ok) }
    "#;
    let expanded = expand(source).unwrap();
    let out = compile(
        "unit_result",
        &expanded.source,
        Some(
            r#"
        let result=rustcall_make(); assert_eq!(result.is_ok,1);
        assert_eq!(DROPS.load(std::sync::atomic::Ordering::SeqCst),0);
        __rustcall_owned_ok_free(unsafe{result.ok_value.assume_init()});
        assert_eq!(DROPS.load(std::sync::atomic::Ordering::SeqCst),1);
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
fn colliding_scope_constant_cannot_promote_receiver_borrow_to_static() {
    let source="const __rustcall_owned_scope: ()=(); #[julia] pub struct Source { pub text: String } #[julia] pub struct View<'a> { pub text: &'a str } #[julia] impl Source { #[julia] #[rustcall_owned_return(View<'static>)] pub fn view(&self) -> View<'_> { View { text: &self.text } } }";
    let expanded = expand(source).unwrap();
    let out = compile("constant_scope", &expanded.source, None);
    assert!(
        !out.status.success(),
        "constant pattern silently replaced the local witness"
    );
}

#[test]
fn aliased_unit_constructor_cannot_become_an_owning_value_pattern() {
    for (label, owner, result) in [
        ("alias_direct", "__rustcall_owned_value", false),
        ("alias_result", "__rustcall_owned_ok", true),
    ] {
        let (return_type, body) = if result {
            ("Result<Selected,i32>", format!("Ok({owner})"))
        } else {
            ("Selected", owner.to_owned())
        };
        let source=format!("#[allow(non_camel_case_types)] #[julia] pub struct {owner}; use self::{owner} as Selected; #[julia] #[rustcall_owned_return(Selected)] pub fn make() -> {return_type} {{ {body} }}");
        let expanded = expand(&source).unwrap();
        assert_eq!(expanded.manifest.functions[0].return_handle, owner);
        let out = compile(label, &expanded.source, None);
        assert!(!out.status.success(),"alias must not silently match a unit constructor instead of binding the produced owner");
        assert!(
            String::from_utf8_lossy(&out.stderr).contains("cannot shadow"),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
}

#[test]
fn colliding_owned_value_constant_cannot_replace_the_produced_owner() {
    let source="#[derive(PartialEq, Eq)] #[julia] pub struct Owner; const __rustcall_owned_value: Owner=Owner; #[julia] #[rustcall_owned_return(Owner)] pub fn make() -> Owner { Owner }";
    let expanded = expand(source).unwrap();
    let out = compile("constant_value", &expanded.source, None);
    assert!(
        !out.status.success(),
        "a constant must not replace an owning value binding"
    );
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("cannot shadow"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn reconstructed_slice_and_optional_borrows_cannot_escape_owned_value_proof() {
    let prefix = r#"
        #[julia] pub struct Source { pub text: String }
        #[julia] pub struct SliceView<'a> { pub values: &'a [f64] }
        #[julia] pub struct TextView<'a> { pub text: &'a str }
        #[julia] pub struct BothView<'a> { pub text: &'a str, pub values: &'a [f64] }
    "#;
    for (label, item) in [
        ("slice_owned", "#[julia] #[rustcall_owned_return(SliceView<'static>)] pub fn view(values: &[f64]) -> SliceView<'_> { SliceView { values } }"),
        ("slice_mut_owned", "#[julia] #[rustcall_owned_return(SliceView<'static>)] pub fn view(values: &mut [f64]) -> SliceView<'_> { SliceView { values } }"),
        ("string_owned", "#[julia] #[rustcall_owned_return(TextView<'static>)] pub fn view(text: &str) -> TextView<'_> { TextView { text } }"),
        ("string_owned_result", "#[julia] #[rustcall_owned_return(TextView<'static>)] pub fn view(text: &str) -> Result<TextView<'_>, String> { Ok(TextView { text }) }"),
        ("optional_owned", "#[julia] #[rustcall_owned_return(TextView<'static>)] pub fn view(source: Option<&Source>) -> TextView<'_> { TextView { text: &source.unwrap().text } }"),
        ("optional_mut_owned", "#[julia] #[rustcall_owned_return(TextView<'static>)] pub fn view(source: Option<&mut Source>) -> TextView<'_> { TextView { text: &source.unwrap().text } }"),
        ("mixed_owned_result", "#[julia] #[rustcall_owned_return(BothView<'static>)] pub fn view<'a>(source: Option<&'a Source>, values: &'a [f64]) -> Result<BothView<'a>, String> { Ok(BothView { text: &source.unwrap().text, values }) }"),
    ] {
        let expanded = expand(&format!("{prefix} {item}")).unwrap();
        assert!(!expanded.source.contains("compile_error!"), "{label}: expected compiler lifetime proof");
        let output = compile(label, &expanded.source, None);
        assert!(!output.status.success(), "{label}: borrowed value was accepted as static");
        let diagnostic = String::from_utf8_lossy(&output.stderr);
        assert!(diagnostic.contains("'static"), "{label}: {diagnostic}");
    }
    let source = format!(
        r#"{prefix}
        #[julia] #[rustcall_owned_return(SliceView<'static>)]
        pub fn independent(source: Option<&mut Source>, values: &mut [f64]) -> SliceView<'static> {{
            if let Some(source) = source {{ source.text.push('!'); }}
            if let Some(value) = values.first_mut() {{ *value += 1.0; }}
            static VALUES: [f64; 2] = [7.0, 9.0];
            SliceView {{ values: &VALUES }}
        }}
    "#
    );
    let expanded = expand(&source).unwrap();
    let output = compile(
        "independent_mixed_static",
        &format!("#![deny(unused_unsafe)]\n{}", expanded.source),
        Some(
            r#"
        let mut source = Source { text: String::from("input") };
        let mut input = [1.0, 2.0];
        let value = rustcall_independent(&mut source, input.as_mut_ptr(), input.len());
        let value = unsafe { Box::from_raw(value) };
        assert_eq!(value.values, &[7.0, 9.0]);
        assert_eq!(source.text, "input!");
        assert_eq!(input, [2.0, 2.0]);
    "#,
        ),
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}
