//! `#[julia]` functions with `String` / `&str` (#242).

use rustcall_core::expand::expand;
use rustcall_core::extract::extract;
use rustcall_core::manifest::Mode;

const SRC: &str = r#"
#[julia]
pub fn shout(input: String) -> String { input.to_uppercase() }
#[julia]
pub fn concat(a: &str, b: &str, times: u32) -> String { a.repeat(times as usize) + b }
#[julia]
pub fn byte_len(s: &str) -> usize { s.len() }
#[julia]
pub fn greeting() -> &'static str { "hello" }
#[julia]
pub fn plain(x: i32) -> i32 { x }
#[julia]
pub fn parse_num(s: &str) -> Result<i32, i32> { s.parse().map_err(|_| -1) }
#[julia]
pub fn first_char(s: String) -> Option<u32> { s.chars().next().map(|c| c as u32) }
#[julia]
pub fn identity<'a>(s: &'a str) -> &'a str { s }
#[julia]
pub fn qualified(s: std::string::String) -> std::string::String { s }
#[julia]
pub fn qualified2(s: ::std::string::String) -> usize { s.len() }
"#;

#[test]
fn string_functions_get_ptr_len_wrappers() {
    let e = expand(SRC).unwrap();
    // prettyplease wraps long signatures; compare without layout.
    let flat: String = e.source.split_whitespace().collect::<Vec<_>>().join(" ");
    let src = &flat
        .replace("( ", "(")
        .replace(", )", ")")
        .replace(" )", ")");
    assert!(src.contains("pub extern \"C\" fn shout(input_ptr: *const u8, input_len: usize) -> shout_RustCallOwnedString"), "{src}");
    assert!(src.contains(
        "pub extern \"C\" fn shout_free_rust_string(ptr: *mut u8, len: usize, cap: usize)"
    ));
    assert!(src.contains("fn shout_inner(input: String) -> String"));
    assert!(src.contains("pub extern \"C\" fn concat(a_ptr: *const u8, a_len: usize, b_ptr: *const u8, b_len: usize, times: u32) -> concat_RustCallOwnedString"), "{src}");
    assert!(src.contains("pub extern \"C\" fn byte_len(s_ptr: *const u8, s_len: usize) -> usize"));
    assert!(src.contains("pub extern \"C\" fn greeting() -> greeting_RustCallBorrowedString"));
    assert!(!src.contains("greeting_free_rust_string"));
    assert!(src.contains("pub extern \"C\" fn plain(x: i32) -> i32"));
    // Result / Option functions convert string arguments too.
    assert!(
        src.contains(
            "pub extern \"C\" fn parse_num(s_ptr: *const u8, s_len: usize) -> CResult_parse_num"
        ),
        "{src}"
    );
    assert!(
        src.contains(
            "pub extern \"C\" fn first_char(s_ptr: *const u8, s_len: usize) -> COption_first_char"
        ),
        "{src}"
    );
    // Lifetime-qualified &str is a string argument as well. Because the result
    // may borrow from the converted argument, it is copied into an owned buffer.
    assert!(src.contains("pub extern \"C\" fn identity(s_ptr: *const u8, s_len: usize) -> identity_RustCallOwnedString"), "{src}");
    assert!(src.contains("pub extern \"C\" fn identity_free_rust_string"));
    // `greeting()` takes no strings, so its &str result stays borrowed.
    assert!(src.contains("pub extern \"C\" fn greeting() -> greeting_RustCallBorrowedString"));
    // Qualified std::string::String is a string type too.
    assert!(src.contains("pub extern \"C\" fn qualified(s_ptr: *const u8, s_len: usize) -> qualified_RustCallOwnedString"), "{src}");
    assert!(
        src.contains("pub extern \"C\" fn qualified2(s_ptr: *const u8, s_len: usize) -> usize"),
        "{src}"
    );
    // The lifetime parameter stays on the inner fn.
    assert!(
        src.contains("fn identity_inner<'a>(s: &'a str) -> &'a str"),
        "{src}"
    );
    // No unchecked UTF-8 construction anywhere.
    assert!(!src.contains("from_utf8_unchecked"));
}

#[test]
fn manifest_records_string_helpers() {
    for mode in [Mode::Inline, Mode::Crate] {
        let m = extract(SRC, mode).unwrap();
        let f = |n: &str| m.functions.iter().find(|f| f.name == n).unwrap();
        assert!(f("shout").has_owned_string_helper);
        assert!(!f("shout").has_borrowed_string_helper);
        assert_eq!(f("shout").args[0].rust_type, "String");
        assert_eq!(f("shout").return_type, "String");
        assert!(f("concat").has_owned_string_helper);
        assert_eq!(f("concat").args[0].rust_type, "&str");
        assert!(!f("byte_len").has_owned_string_helper);
        assert!(f("greeting").has_borrowed_string_helper);
        assert!(!f("plain").has_owned_string_helper && !f("plain").has_borrowed_string_helper);
        assert!(f("shout").exported);
        assert_eq!(f("shout").args[0].abi, "string");
        assert_eq!(f("concat").args[0].abi, "str");
        assert_eq!(f("concat").args[2].abi, "");
        assert_eq!(f("parse_num").args[0].abi, "str");
        assert_eq!(f("identity").args[0].rust_type, "&'a str");
        assert_eq!(f("identity").args[0].abi, "str");
        assert!(f("identity").has_owned_string_helper && !f("identity").has_borrowed_string_helper);
        assert!(f("greeting").has_borrowed_string_helper);
        assert_eq!(f("qualified").args[0].abi, "string");
        assert_eq!(f("qualified2").args[0].abi, "string");
        assert!(f("qualified").has_owned_string_helper);
    }
}

/// Source without layout (prettyplease wraps long signatures).
fn flat(source: &str) -> String {
    source
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace("( ", "(")
        .replace(", )", ")")
        .replace(" )", ")")
}

#[test]
fn parenthesized_types_are_unwrapped() {
    let src = r#"
#[julia]
pub fn consume(s: (String)) -> usize { s.len() }
#[julia]
pub fn paren_ref(s: &(str)) -> (usize) { s.len() }
#[julia]
pub fn paren_ret(s: String) -> (String) { s }
#[julia]
pub fn paren_res(s: (String)) -> (Result<i32, i32>) { s.parse().map_err(|_| -1) }
"#;
    let e = expand(src).unwrap();
    let source = flat(&e.source);
    assert!(
        source.contains("pub extern \"C\" fn consume(s_ptr: *const u8, s_len: usize) -> usize"),
        "{source}"
    );
    assert!(
        source.contains("pub extern \"C\" fn paren_ref(s_ptr: *const u8, s_len: usize) -> (usize)"),
        "{source}"
    );
    assert!(
        source.contains("pub extern \"C\" fn paren_ret(s_ptr: *const u8, s_len: usize) -> paren_ret_RustCallOwnedString"),
        "{source}"
    );
    assert!(
        source.contains(
            "pub extern \"C\" fn paren_res(s_ptr: *const u8, s_len: usize) -> CResult_paren_res"
        ),
        "{source}"
    );
    for mode in [Mode::Inline, Mode::Crate] {
        let m = extract(src, mode).unwrap();
        let f = |n: &str| m.functions.iter().find(|f| f.name == n).unwrap();
        assert_eq!(f("consume").args[0].abi, "string");
        assert_eq!(f("consume").args[0].rust_type, "String");
        assert_eq!(f("paren_ref").args[0].abi, "str");
        assert_eq!(f("paren_ref").return_type, "usize");
        assert!(f("paren_ret").has_owned_string_helper);
        assert_eq!(f("paren_ret").return_type, "String");
        assert_eq!(f("paren_res").ok_type, "i32");
    }
}

#[test]
fn julia_pyo3_functions_report_no_string_abi() {
    // `#[julia_pyo3]` exports the signature as written (no string conversion,
    // see #275), so the manifest must not advertise the (ptr, len) ABI.
    let src = r#"
#[julia_pyo3]
pub fn py_len(s: String) -> usize { s.len() }
#[julia_pyo3]
pub fn py_greet(s: &str) -> String { s.to_string() }
"#;
    let m = extract(src, Mode::Crate).unwrap();
    assert_eq!(m.functions.len(), 2);
    for f in &m.functions {
        assert!(f.args.iter().all(|a| a.abi.is_empty()), "{}", f.name);
        assert!(!f.has_owned_string_helper && !f.has_borrowed_string_helper);
        assert_eq!(f.attribute, rustcall_core::manifest::Attribute::JuliaPyo3);
    }
    assert_eq!(m.functions[0].args[0].rust_type, "String");
}

#[test]
fn crate_method_wrappers_use_the_string_abi() {
    use rustcall_core::codegen::{generate_method_wrapper_crate, transform_impl_julia_pyo3};

    let item: syn::ItemImpl = syn::parse_str(
        r#"
impl Greeter {
    pub fn new(count: u32) -> Self { Self { count } }
    pub fn shout(&self, suffix: &str) -> String { format!("{}{}", self.count, suffix) }
    pub fn label(&self) -> &str { "greeter" }
    pub fn echo<'a>(&self, s: &'a str) -> &'a str { s }
    pub fn take(&mut self, s: String) -> usize { self.count += 1; s.len() }
    pub fn plain(&self, x: i32) -> i32 { x }
}
"#,
    )
    .unwrap();
    let struct_name: syn::Ident = syn::parse_str("Greeter").unwrap();
    let mut out = proc_macro2::TokenStream::new();
    for i in &item.items {
        if let syn::ImplItem::Fn(m) = i {
            out.extend(generate_method_wrapper_crate(&struct_name, m));
        }
    }
    let file: syn::File = syn::parse2(out).unwrap();
    let source = flat(&prettyplease::unparse(&file));
    assert!(
        source.contains("pub extern \"C\" fn Greeter_new(count: u32) -> *mut Greeter"),
        "{source}"
    );
    assert!(
        source.contains("pub extern \"C\" fn Greeter_shout(ptr: *const Greeter, suffix_ptr: *const u8, suffix_len: usize) -> Greeter_shout_RustCallOwnedString"),
        "{source}"
    );
    assert!(source.contains("pub struct Greeter_shout_RustCallOwnedString"));
    assert!(source.contains(
        "pub extern \"C\" fn Greeter_shout_free_rust_string(ptr: *mut u8, len: usize, cap: usize)"
    ));
    assert!(
        source.contains("pub extern \"C\" fn Greeter_label(ptr: *const Greeter) -> Greeter_label_RustCallBorrowedString"),
        "{source}"
    );
    assert!(!source.contains("Greeter_label_free_rust_string"));
    // A &str result that may borrow from a converted argument is copied.
    assert!(
        source.contains("pub extern \"C\" fn Greeter_echo(ptr: *const Greeter, s_ptr: *const u8, s_len: usize) -> Greeter_echo_RustCallOwnedString"),
        "{source}"
    );
    assert!(
        source.contains("pub extern \"C\" fn Greeter_take(ptr: *mut Greeter, s_ptr: *const u8, s_len: usize) -> usize"),
        "{source}"
    );
    assert!(
        source.contains("pub extern \"C\" fn Greeter_plain(ptr: *const Greeter, x: i32) -> i32")
    );
    assert!(!source.contains("from_utf8_unchecked"));

    // The crate manifest describes exactly that ABI.
    let src = r#"
#[julia]
pub struct Greeter { pub count: u32 }
#[julia]
impl Greeter {
    #[julia]
    pub fn new(count: u32) -> Self { Self { count } }
    #[julia]
    pub fn shout(&self, suffix: &str) -> String { format!("{}{}", self.count, suffix) }
    #[julia]
    pub fn label(&self) -> &str { "greeter" }
    #[julia]
    pub fn echo<'a>(&self, s: &'a str) -> &'a str { s }
    #[julia]
    pub fn take(&mut self, s: String) -> usize { self.count += 1; s.len() }
}
"#;
    let m = extract(src, Mode::Crate).unwrap();
    let s = &m.structs[0];
    let method = |n: &str| s.methods.iter().find(|m| m.name == n).unwrap();
    assert_eq!(method("shout").args[0].abi, "str");
    assert_eq!(method("shout").return_abi, "string");
    assert_eq!(method("label").return_abi, "str");
    assert_eq!(method("echo").return_abi, "string");
    assert_eq!(method("take").args[0].abi, "string");
    assert_eq!(method("take").return_abi, "");
    assert_eq!(method("new").symbol, "Greeter_new");

    // `#[julia_pyo3] impl` methods go through the same wrapper generator, so
    // their manifest entries keep the string ABI.
    let py_impl: syn::ItemImpl = syn::parse_str(
        "impl DualCounter { pub fn describe(&self, s: &str) -> String { s.to_string() } }",
    )
    .unwrap();
    let py_file: syn::File = syn::parse2(transform_impl_julia_pyo3(py_impl)).unwrap();
    let py = flat(&prettyplease::unparse(&py_file));
    assert!(
        py.contains("pub extern \"C\" fn DualCounter_describe(ptr: *const DualCounter, s_ptr: *const u8, s_len: usize) -> DualCounter_describe_RustCallOwnedString"),
        "{py}"
    );
}
