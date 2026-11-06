//! Native value-namespace hygiene shared by every wrapper frontend (#579).
use quote::ToTokens;
use rustcall_julia_core::{expand, extract, specialize, wrap};
use std::{
    fs,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

const SOURCE: &str = r#"
#[julia] pub fn scalar(scalar: i32) -> i32 { scalar + 1 }
#[julia] pub fn callback(callback: extern "C" fn() -> i32) -> i32 { callback() + 1 }
#[julia] pub fn collision(collision: i32, __rustcall_arg_collision: i32) -> i32 { collision * 10 + __rustcall_arg_collision }
#[julia] pub fn text_ptr(text: String) -> usize { text.len() }
#[julia] pub fn text_len(text: &str) -> usize { text.len() }
#[julia] pub fn text_bytes(text: &str) -> usize { text.len() }
#[julia] pub fn text_cow(text: &str) -> usize { text.len() }
#[julia] pub fn data_ptr(data: &[i32]) -> i32 { data.iter().sum() }
#[julia] pub fn data_len(data: &[i32]) -> usize { data.len() }
#[julia] pub fn _rustcall_boundary(value: i32) -> i32 { value + 2 }
#[julia] pub fn guard_arg(_rustcall_boundary: i32) -> i32 { _rustcall_boundary + 3 }
#[julia] pub fn r#type(r#type: i32) -> i32 { r#type + 4 }
#[julia] pub fn K579(K579: i32) -> i32 { K579 + 5 }
#[julia] pub fn K_ptr(K: String) -> usize { K.len() }
#[julia] pub fn unit(unit: i32) { assert_eq!(unit, 12); }
#[julia] pub fn result(result: i32) -> Result<i32, i32> { Ok(result + 6) }
#[julia] pub fn option(option: i32) -> Option<i32> { Some(option + 7) }
#[julia] pub fn owned(owned: String) -> String { owned }
#[julia] pub struct Output579 { pub value: i32 }
#[julia] #[rustcall_owned_return(Output579)]
pub fn __rustcall_owned_scope(value: i32) -> Output579 { Output579 { value } }
#[julia] pub fn optional_ptr(optional: Option<&Output579>) -> i32 { optional.map_or(0, |v| v.value) }
#[julia] pub mod nested {
    #[julia] pub fn nested_value(nested_value: i32) -> i32 { nested_value + 8 }
}
"#;

fn compile_and_run(label: &str, source: &str, main: &str) {
    let dir = std::env::temp_dir().join(format!(
        "rustcall579-{label}-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&dir).unwrap();
    let input = dir.join("main.rs");
    let executable = dir.join(format!("main{}", std::env::consts::EXE_SUFFIX));
    fs::write(
        &input,
        format!("#![allow(dead_code, non_snake_case)]\n{source}\nfn main() {{ {main} }}"),
    )
    .unwrap();
    let built = Command::new("rustc")
        .args(["--edition=2021", "-Awarnings", "-C", "panic=unwind"])
        .arg(&input)
        .arg("-o")
        .arg(&executable)
        .output()
        .unwrap();
    assert!(
        built.status.success(),
        "{label}: {}",
        String::from_utf8_lossy(&built.stderr)
    );
    let run = Command::new(&executable).output().unwrap();
    assert!(
        run.status.success(),
        "{label}: {}",
        String::from_utf8_lossy(&run.stderr)
    );
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn original_signatures_and_manifest_names_survive_private_binding_changes() {
    let expanded = expand::expand(SOURCE).unwrap();
    let original: syn::File = syn::parse_str(SOURCE).unwrap();
    let output: syn::File = syn::parse_str(&expanded.source).unwrap();
    for item in &original.items {
        let syn::Item::Fn(before) = item else {
            continue;
        };
        let after = output
            .items
            .iter()
            .find_map(|item| match item {
                syn::Item::Fn(f) if f.sig.ident == before.sig.ident => Some(f),
                _ => None,
            })
            .unwrap();
        assert_eq!(
            before.sig.to_token_stream().to_string(),
            after.sig.to_token_stream().to_string()
        );
        assert_eq!(
            before.block.to_token_stream().to_string(),
            after.block.to_token_stream().to_string()
        );
    }
    let scanned = extract::extract_crate(SOURCE).unwrap();
    for inline in &expanded.manifest.functions {
        let direct = scanned
            .functions
            .iter()
            .find(|f| f.name == inline.name && f.module_path == inline.module_path)
            .unwrap();
        assert_eq!(inline.symbol, direct.symbol);
        assert_eq!(inline.args, direct.args);
    }
    let callback = scanned
        .functions
        .iter()
        .find(|f| f.name == "callback")
        .unwrap();
    assert_eq!(callback.args[0].name, "callback");
    assert_eq!(callback.symbol, "rustcall_callback");
}

#[test]
fn bare_callees_survive_parameters_lowering_guards_raw_and_nfc_names() {
    let expanded = expand::expand(SOURCE).unwrap();
    compile_and_run(
        "values",
        &expanded.source,
        r#"
        extern "C" fn answer() -> i32 { 40 }
        assert_eq!(unsafe { rustcall_scalar(1).assume_init() }, 2);
        assert_eq!(unsafe { rustcall_callback(answer).assume_init() }, 41);
        assert_eq!(unsafe { rustcall_collision(2,3).assume_init() }, 23);
        let text = b"hello";
        assert_eq!(unsafe { rustcall_text_ptr(text.as_ptr(),text.len()).assume_init() }, 5);
        assert_eq!(unsafe { rustcall_text_len(text.as_ptr(),text.len()).assume_init() }, 5);
        assert_eq!(unsafe { rustcall_text_bytes(text.as_ptr(),text.len()).assume_init() }, 5);
        assert_eq!(unsafe { rustcall_text_cow(text.as_ptr(),text.len()).assume_init() }, 5);
        let data = [4,5];
        assert_eq!(unsafe { rustcall_data_ptr(data.as_ptr(),data.len()).assume_init() }, 9);
        assert_eq!(unsafe { rustcall_data_len(data.as_ptr(),data.len()).assume_init() }, 2);
        assert_eq!(unsafe { rustcall__rustcall_boundary(2).assume_init() }, 4);
        assert_eq!(unsafe { rustcall_guard_arg(2).assume_init() }, 5);
        assert_eq!(unsafe { rustcall_type(2).assume_init() }, 6);
        assert_eq!(unsafe { rustcall_K579(2).assume_init() }, 7);
        assert_eq!(unsafe { rustcall_K_ptr(text.as_ptr(),text.len()).assume_init() }, 5);
        rustcall_unit(12);
        assert_eq!(*rustcall_result(2).ok().unwrap(), 8);
        assert_eq!(*rustcall_option(2).some().unwrap(), 9);
        let owned = rustcall_owned(text.as_ptr(),text.len());
        assert_eq!(unsafe { std::slice::from_raw_parts(owned.ptr,owned.len) }, text);
        owned_free_rust_string(owned.ptr,owned.len,owned.cap);
        let output = rustcall___rustcall_owned_scope(17);
        assert_eq!(unsafe { (*output).value }, 17);
        assert_eq!(unsafe { rustcall_optional_ptr(output).assume_init() }, 17);
        assert_eq!(unsafe { rustcall_optional_ptr(std::ptr::null()).assume_init() }, 0);
        Output579_free(output);
        assert_eq!(unsafe { nested::rustcall_nested__nested_0value(2).assume_init() }, 10);
    "#,
    );
}

#[test]
fn generic_specialization_preserves_lexical_callee_lookup() {
    // The specialization deliberately has the same name as its parameter.
    let specialized = specialize::specialize(
        "pub fn generic<T: Copy>(value:T)->T { value }",
        "generic",
        &[("T".into(), "i32".into())],
        "value",
    )
    .unwrap();
    compile_and_run(
        "generic",
        &specialized.source,
        "assert_eq!(unsafe { rustcall_value(9).assume_init() },9); assert_eq!(generic(8),8);",
    );
}

#[test]
fn qualified_external_wrapper_targets_keep_their_path_and_argument_names() {
    let manifest = extract::extract_crate("#[pyfunction] pub fn external(external:i32)->i32 { external+1 } #[pyfunction] pub fn guarded(_rustcall_boundary:i32)->i32 { _rustcall_boundary+2 }").unwrap();
    let wrapped = wrap::wrapper_crate(&manifest, "user_crate", true);
    assert!(wrapped.lib_rs.contains("user_crate::external(external)"));
    compile_and_run("qualified", &format!(r#"
        extern crate self as rustcall_julia_macros;
        pub struct __RustCallBoundary;
        impl __RustCallBoundary {{ pub fn enter()->Self {{ Self }} }}
        mod user_crate {{ pub fn external(external:i32)->i32 {{ external+1 }} pub fn guarded(_rustcall_boundary:i32)->i32 {{ _rustcall_boundary+2 }} }}
        {}
    "#, wrapped.lib_rs), "assert_eq!(unsafe { rustcall_external(4).assume_init() },5); assert_eq!(unsafe { rustcall_guarded(4).assume_init() },6);");
}

#[test]
fn post_call_payload_bindings_preserve_accepted_unit_constructor_names() {
    let expanded = expand::expand(
        r#"
        #[julia] pub struct Product { pub value: i32 }
        #[allow(non_camel_case_types)] pub struct __rustcall_owned_value_;
        #[julia] #[rustcall_owned_return(Product)]
        pub fn __rustcall_owned_value() -> Product { Product { value: 3 } }
    "#,
    )
    .unwrap();
    compile_and_run(
        "post_call",
        &expanded.source,
        r#"
        let result = rustcall___rustcall_owned_value();
        assert_eq!(unsafe { (*result).value }, 3);
        unsafe { drop(Box::from_raw(result)); }
    "#,
    );
}
