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
    assert!(src.contains("pub extern \"C\" fn rustcall_shout(input_ptr: *const u8, input_len: usize) -> shout_RustCallOwnedString"), "{src}");
    assert!(src.contains(
        "pub extern \"C\" fn shout_free_rust_string(ptr: *mut u8, len: usize, cap: usize)"
    ));
    // The annotated item survives verbatim next to the wrapper (#279).
    assert!(src.contains("fn shout(input: String) -> String"));
    assert!(!src.contains("shout_inner"));
    assert!(src.contains("pub extern \"C\" fn rustcall_concat(a_ptr: *const u8, a_len: usize, b_ptr: *const u8, b_len: usize, times: u32) -> concat_RustCallOwnedString"), "{src}");
    assert!(src.contains(
        "pub extern \"C\" fn rustcall_byte_len(s_ptr: *const u8, s_len: usize) -> usize"
    ));
    assert!(
        src.contains("pub extern \"C\" fn rustcall_greeting() -> greeting_RustCallBorrowedString")
    );
    assert!(!src.contains("greeting_free_rust_string"));
    assert!(src.contains("pub extern \"C\" fn rustcall_plain(x: i32) -> i32"));
    // Result / Option functions convert string arguments too.
    assert!(
        src.contains(
            "pub extern \"C\" fn rustcall_parse_num(s_ptr: *const u8, s_len: usize) -> CResult_parse_num"
        ),
        "{src}"
    );
    assert!(
        src.contains(
            "pub extern \"C\" fn rustcall_first_char(s_ptr: *const u8, s_len: usize) -> COption_first_char"
        ),
        "{src}"
    );
    // Lifetime-qualified &str is a string argument as well. Because the result
    // may borrow from the converted argument, it is copied into an owned buffer.
    assert!(src.contains("pub extern \"C\" fn rustcall_identity(s_ptr: *const u8, s_len: usize) -> identity_RustCallOwnedString"), "{src}");
    assert!(src.contains("pub extern \"C\" fn identity_free_rust_string"));
    // `greeting()` takes no strings, so its &str result stays borrowed.
    assert!(
        src.contains("pub extern \"C\" fn rustcall_greeting() -> greeting_RustCallBorrowedString")
    );
    // Qualified std::string::String is a string type too.
    assert!(src.contains("pub extern \"C\" fn rustcall_qualified(s_ptr: *const u8, s_len: usize) -> qualified_RustCallOwnedString"), "{src}");
    assert!(
        src.contains(
            "pub extern \"C\" fn rustcall_qualified2(s_ptr: *const u8, s_len: usize) -> usize"
        ),
        "{src}"
    );
    // The lifetime parameter stays on the inner fn.
    assert!(
        src.contains("fn identity<'a>(s: &'a str) -> &'a str"),
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
        source.contains(
            "pub extern \"C\" fn rustcall_consume(s_ptr: *const u8, s_len: usize) -> usize"
        ),
        "{source}"
    );
    assert!(
        source.contains(
            "pub extern \"C\" fn rustcall_paren_ref(s_ptr: *const u8, s_len: usize) -> (usize)"
        ),
        "{source}"
    );
    assert!(
        source.contains("pub extern \"C\" fn rustcall_paren_ret(s_ptr: *const u8, s_len: usize) -> paren_ret_RustCallOwnedString"),
        "{source}"
    );
    assert!(
        source.contains(
            "pub extern \"C\" fn rustcall_paren_res(s_ptr: *const u8, s_len: usize) -> CResult_paren_res"
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
fn generated_identifiers_never_collide_with_arguments() {
    // The wrapper introduces `<arg>_ptr`, `<arg>_len`, `<arg>_bytes`,
    // `<arg>_cow` (and, for methods, `ptr` / `self_obj`); a user argument may
    // carry any of those names.
    let src = r#"
#[julia]
pub fn f(s: String, s_ptr: usize) -> usize { s.len() + s_ptr }
#[julia]
pub fn g(s: &str, s_bytes: i32, s_cow: i32, s_len: i32) -> i32 { s.len() as i32 + s_bytes * 10 + s_cow * 100 + s_len * 1000 }
#[julia]
pub fn h(s_ptr_: u8, s: String) -> usize { s.len() + s_ptr_ as usize }
#[julia]
pub struct Holder { pub n: u32 }
impl Holder {
    pub fn m(&self, ptr: u32, self_obj: u32, s: &str, s_bytes: u32) -> u32 { self.n + ptr + self_obj + s.len() as u32 + s_bytes }
}
"#;
    let e = expand(src).unwrap();
    let source = flat(&e.source);
    assert!(
        source.contains(
            "pub extern \"C\" fn rustcall_f(s_ptr_: *const u8, s_len: usize, s_ptr: usize) -> usize"
        ),
        "{source}"
    );
    assert!(source.contains("fn f(s: String, s_ptr: usize) -> usize"));
    assert!(
        source.contains("pub extern \"C\" fn rustcall_g(s_ptr: *const u8, s_len_: usize, s_bytes: i32, s_cow: i32, s_len: i32) -> i32"),
        "{source}"
    );
    assert!(
        source.contains("let s_bytes_ = unsafe { std::slice::from_raw_parts(s_ptr, s_len_) };"),
        "{source}"
    );
    assert!(
        source.contains("let s_cow_ = String::from_utf8_lossy(s_bytes_);"),
        "{source}"
    );
    assert!(source.contains("g(s, s_bytes, s_cow, s_len)"), "{source}");
    // The user owns `s_ptr_`; the generated `s_ptr` is free and keeps its name.
    assert!(source.contains("h(s_ptr_, s)"), "{source}");
    assert!(
        source.contains(
            "pub extern \"C\" fn rustcall_h(s_ptr_: u8, s_ptr: *const u8, s_len: usize) -> usize"
        ),
        "{source}"
    );
    assert!(
        source.contains("pub extern \"C\" fn rustcall_Holder_m(ptr_: *const Holder, ptr: u32, self_obj: u32, s_ptr: *const u8, s_len: usize, s_bytes: u32) -> u32"),
        "{source}"
    );
    assert!(
        source.contains("let self_obj_ = unsafe { &*ptr_ };"),
        "{source}"
    );
    assert!(
        source.contains("self_obj_.m(ptr, self_obj, s, s_bytes)"),
        "{source}"
    );

    // The manifest keeps the user's names and ABIs.
    for mode in [Mode::Inline, Mode::Crate] {
        let m = extract(src, mode).unwrap();
        let f = m.functions.iter().find(|f| f.name == "f").unwrap();
        assert_eq!(f.args[0].abi, "string");
        assert_eq!(f.args[1].name, "s_ptr");
        assert_eq!(f.args[1].abi, "");
        let g = m.functions.iter().find(|f| f.name == "g").unwrap();
        assert_eq!(
            g.args.iter().map(|a| a.name.as_str()).collect::<Vec<_>>(),
            ["s", "s_bytes", "s_cow", "s_len"]
        );
    }
}

#[test]
fn generic_struct_wrappers_name_the_lifetime_of_borrowed_str_returns() {
    // `fn tag_ref(&self) -> &str` elides the lifetime from `&self`; the generic
    // wrapper receives a raw pointer instead, so it must name one.
    let src = r#"
#[julia]
pub struct Tagged<T> { tag: String, v: T }
impl<T: Copy> Tagged<T> {
    pub fn new(tag: String, v: T) -> Self { Self { tag, v } }
    pub fn tag_ref(&self) -> &str { &self.tag }
    pub fn label(&self, suffix: &str) -> String { format!("{}{}", self.tag, suffix) }
    pub fn fixed(&self) -> &'static str { "fixed" }
    pub fn explicit<'a>(&'a self) -> &'a str { &self.tag }
}
"#;
    let e = expand(src).unwrap();
    let s = &e.manifest.structs[0];
    let wrapper = |n: &str| {
        flat(
            &s.generic_wrappers
                .iter()
                .find(|w| w.name == n)
                .unwrap()
                .source,
        )
    };
    assert!(
        wrapper("Tagged_tag_ref").contains(
            "pub fn Tagged_tag_ref<'rustcall, T: Copy + 'rustcall>(ptr: *const Tagged<T>) -> &'rustcall str"
        ),
        "{}",
        wrapper("Tagged_tag_ref")
    );
    // Explicit lifetimes (the method's own `<'a>` is carried over) and plain
    // returns are left as written.
    assert!(wrapper("Tagged_fixed").contains("-> &'static str"));
    assert!(
        wrapper("Tagged_explicit").contains("pub fn Tagged_explicit<'a, T: Copy>"),
        "{}",
        wrapper("Tagged_explicit")
    );
    assert!(wrapper("Tagged_explicit").contains("-> &'a str"));
    assert!(!wrapper("Tagged_explicit").contains("'rustcall"));
    assert!(wrapper("Tagged_label").contains("suffix: &str) -> String"));
    assert!(wrapper("Tagged_new").contains("(tag: String, v: T) -> *mut Tagged<T>"));

    // The specialization of the wrapper gets the string ABI.
    let out = rustcall_core::specialize::specialize(
        &wrapper("Tagged_tag_ref"),
        "Tagged_tag_ref",
        &[("T".into(), "i32".into())],
        "Tagged_tag_ref_i32",
    )
    .unwrap();
    assert!(out.manifest.functions[0].has_borrowed_string_helper);
    assert!(
        flat(&out.source).contains("pub extern \"C\" fn rustcall_Tagged_tag_ref_i32(ptr: *const Tagged<i32>) -> Tagged_tag_ref_i32_RustCallBorrowedString"),
        "{}",
        flat(&out.source)
    );
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
        source.contains("pub extern \"C\" fn rustcall_Greeter_new(count: u32) -> *mut Greeter"),
        "{source}"
    );
    assert!(
        source.contains("pub extern \"C\" fn rustcall_Greeter_shout(ptr: *const Greeter, suffix_ptr: *const u8, suffix_len: usize) -> Greeter_shout_RustCallOwnedString"),
        "{source}"
    );
    assert!(source.contains("pub struct Greeter_shout_RustCallOwnedString"));
    assert!(source.contains(
        "pub extern \"C\" fn Greeter_shout_free_rust_string(ptr: *mut u8, len: usize, cap: usize)"
    ));
    assert!(
        source.contains("pub extern \"C\" fn rustcall_Greeter_label(ptr: *const Greeter) -> Greeter_label_RustCallBorrowedString"),
        "{source}"
    );
    assert!(!source.contains("Greeter_label_free_rust_string"));
    // A &str result that may borrow from a converted argument is copied.
    assert!(
        source.contains("pub extern \"C\" fn rustcall_Greeter_echo(ptr: *const Greeter, s_ptr: *const u8, s_len: usize) -> Greeter_echo_RustCallOwnedString"),
        "{source}"
    );
    assert!(
        source.contains("pub extern \"C\" fn rustcall_Greeter_take(ptr: *mut Greeter, s_ptr: *const u8, s_len: usize) -> usize"),
        "{source}"
    );
    assert!(source.contains(
        "pub extern \"C\" fn rustcall_Greeter_plain(ptr: *const Greeter, x: i32) -> i32"
    ));
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
    assert_eq!(method("new").symbol, "rustcall_Greeter_new");

    // `#[julia_pyo3] impl` methods go through the same wrapper generator, so
    // their manifest entries keep the string ABI.
    let py_impl: syn::ItemImpl = syn::parse_str(
        "impl DualCounter { pub fn describe(&self, s: &str) -> String { s.to_string() } }",
    )
    .unwrap();
    let py_file: syn::File = syn::parse2(transform_impl_julia_pyo3(py_impl)).unwrap();
    let py = flat(&prettyplease::unparse(&py_file));
    assert!(
        py.contains("pub extern \"C\" fn rustcall_DualCounter_describe(ptr: *const DualCounter, s_ptr: *const u8, s_len: usize) -> DualCounter_describe_RustCallOwnedString"),
        "{py}"
    );
}


/// A `String` field cannot cross `extern "C"` by value. Both wrapper flavours
/// lower its getter to the owned `(ptr, len, cap)` buffer and say so in the
/// manifest, so Julia never has to re-derive the lowering from the spelling
/// (#246, #276).
#[test]
fn string_fields_report_the_owned_string_abi_in_both_flavours() {
    let src = r#"
#[julia]
pub struct Counter { count: u32, name: String }
#[julia]
impl Counter {
    #[julia]
    pub fn new() -> Self { Self { count: 0, name: String::new() } }
}
"#;
    for mode in [Mode::Inline, Mode::Crate] {
        let m = extract(src, mode).unwrap();
        let s = m.structs.iter().find(|s| s.name == "Counter").unwrap();
        let name = s.fields.iter().find(|f| f.name == "name").unwrap();
        let count = s.fields.iter().find(|f| f.name == "count").unwrap();
        assert_eq!(name.abi, "string", "{mode:?}");
        assert_eq!(count.abi, "", "{mode:?}");
        assert!(name.ffi_compatible, "{mode:?}");
        assert!(s.has_owned_string_helper, "{mode:?}");
    }

    // The inline flavour emits the lowered getter directly...
    let e = expand(src).unwrap();
    assert!(
        flat(&e.source).contains(
            "pub extern \"C\" fn Counter_get_name(ptr: *const Counter) -> Counter_RustCallOwnedString"
        ),
        "{}",
        e.source
    );
    // ...and so does the crate flavour, through the proc-macro entry point.
    let item: syn::ItemStruct =
        syn::parse_str("pub struct Counter { count: u32, name: String }").unwrap();
    let crate_src = flat(&rustcall_core::codegen::transform_struct_crate(item).to_string());
    assert!(
        crate_src.contains("fn Counter_get_name")
            && crate_src.contains("-> Counter_RustCallOwnedString"),
        "{crate_src}"
    );
    assert!(
        crate_src.contains("pub extern \"C\" fn Counter_free_rust_string"),
        "{crate_src}"
    );
}

/// `Function.return_abi` is the normative column since schema 4; the
/// `has_*_string_helper` booleans are derived from it (#276).
#[test]
fn function_return_abi_is_the_normative_column() {
    let m = extract(SRC, Mode::Inline).unwrap();
    let by_name = |n: &str| m.functions.iter().find(|f| f.name == n).unwrap();
    assert_eq!(by_name("shout").return_abi, "string");
    assert_eq!(by_name("greeting").return_abi, "str");
    assert_eq!(by_name("identity").return_abi, "string");
    assert_eq!(by_name("plain").return_abi, "");
    for f in &m.functions {
        assert_eq!(f.has_owned_string_helper, f.return_abi == "string");
        assert_eq!(f.has_borrowed_string_helper, f.return_abi == "str");
    }
}
