//! `Result` / `Option` returns on `#[julia]` struct methods (#268).
//!
//! Methods are lowered exactly like free functions: `CResult_<Struct>_<method>`
//! / `COption_<Struct>_<method>`, with a `String` / `&str` payload composed onto
//! the owner's owned-string buffer. The golden corpus pins the whole expansion;
//! these tests pin the properties that must hold in *both* flavours.

use rustcall_core::codegen::{generate_method_wrapper_crate, transform_impl_crate};
use rustcall_core::expand::expand;
use rustcall_core::extract::extract;
use rustcall_core::manifest::{Mode, ReturnKind};

const SRC: &str = r#"
#[julia]
pub struct Div { n: i32 }

impl Div {
    pub fn new(n: i32) -> Self { Div { n } }
    pub fn checked_div(&self, d: i32) -> Result<i32, String> {
        if d == 0 { Err("zero".to_string()) } else { Ok(self.n / d) }
    }
    pub fn find(&self, k: i32) -> Option<f64> {
        if k == 0 { None } else { Some(self.n as f64 / k as f64) }
    }
    pub fn describe(&self, unit: String) -> Result<String, String> {
        if unit.is_empty() { Err("empty".to_string()) } else { Ok(unit) }
    }
    pub fn label(&self) -> Option<&'static str> { Some("div") }
    pub fn plain(&self) -> i32 { self.n }
}
"#;

/// Normalize `prettyplease` output so a signature can be matched on one line:
/// doc comments dropped, whitespace collapsed, trailing commas removed.
fn flatten(source: &str) -> String {
    let without_docs: String = source
        .lines()
        .filter(|l| !l.trim_start().starts_with("///"))
        .collect::<Vec<_>>()
        .join("\n");
    without_docs
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace("( ", "(")
        .replace(" )", ")")
        .replace(", )", ")")
        .replace(",)", ")")
}

#[test]
fn inline_methods_get_payload_aggregates() {
    let src = flatten(&expand(SRC).unwrap().source);

    // The wrapper returns the aggregate, not the `Result` as written.
    assert!(
        src.contains(
            "pub extern \"C\" fn rustcall_Div_checked_div(ptr: *const Div, d: i32) -> CResult_Div_checked_div"
        ),
        "{src}"
    );
    assert!(
        src.contains(
            "pub extern \"C\" fn rustcall_Div_find(ptr: *const Div, k: i32) -> COption_Div_find"
        ),
        "{src}"
    );

    // Private fields behind `MaybeUninit`, with the accessors the free-function
    // path already generates.
    assert!(
        src.contains("pub struct CResult_Div_checked_div { is_ok: u8,"),
        "{src}"
    );
    assert!(
        src.contains("ok_value: ::std::mem::MaybeUninit<i32>,"),
        "{src}"
    );
    assert!(
        src.contains("err_value: ::std::mem::MaybeUninit<Div_RustCallOwnedString>,"),
        "{src}"
    );
    for accessor in [
        "impl CResult_Div_checked_div",
        "pub fn is_ok(&self)",
        "pub fn ok(&self)",
        "pub fn err(&self)",
        "pub fn panicked()",
        "impl COption_Div_find",
        "pub fn is_some(&self)",
        "pub fn some(&self)",
    ] {
        assert!(src.contains(accessor), "missing {accessor} in {src}");
    }

    // The inner call is preserved: the wrapper calls the method the user wrote.
    assert!(src.contains("self_obj.checked_div(d)"), "{src}");
    assert!(src.contains("self_obj.find(k)"), "{src}");

    // A plain method is untouched.
    assert!(
        src.contains("pub extern \"C\" fn rustcall_Div_plain(ptr: *const Div) -> i32"),
        "{src}"
    );
}

#[test]
fn string_payloads_compose_with_the_string_lowering() {
    let src = flatten(&expand(SRC).unwrap().source);

    // One buffer type per struct in the inline flavour, declared next to it and
    // shared by every method that needs it.
    assert_eq!(src.matches("pub struct Div_RustCallOwnedString").count(), 1);
    assert_eq!(
        src.matches("pub extern \"C\" fn Div_free_rust_string")
            .count(),
        1
    );

    // `Result<String, String>`: both payload slots are the buffer.
    assert!(
        src.contains(
            "pub struct CResult_Div_describe { is_ok: u8, ok_value: ::std::mem::MaybeUninit<Div_RustCallOwnedString>, err_value: ::std::mem::MaybeUninit<Div_RustCallOwnedString>, }"
        ),
        "{src}"
    );
    // A `&str` payload is copied, never borrowed.
    assert!(
        src.contains("pub struct COption_Div_label { is_some: u8, value: ::std::mem::MaybeUninit<Div_RustCallOwnedString>, }"),
        "{src}"
    );
    assert!(!src.contains("Div_RustCallBorrowedString"), "{src}");
    // The buffer is built by forgetting a `Vec`, exactly as a `String` return is.
    assert!(src.contains("::std::mem::forget(rustcall_bytes);"), "{src}");
}

#[test]
fn crate_flavour_declares_a_per_method_buffer() {
    let item: syn::ItemImpl = syn::parse_quote! {
        impl Div {
            #[julia]
            pub fn describe(&self, unit: String) -> Result<String, String> {
                Ok(unit)
            }
            #[julia]
            pub fn find(&self, k: i32) -> Option<f64> { Some(k as f64) }
        }
    };
    let src = flatten(&prettyplease::unparse(
        &syn::parse2(transform_impl_crate(item)).unwrap(),
    ));

    // The proc-macro sees one impl block and cannot share a struct-level
    // helper, so the buffer is named after `<Struct>_<method>` — the same rule
    // a `String`-returning crate method already follows.
    assert!(
        src.contains("pub struct Div_describe_RustCallOwnedString"),
        "{src}"
    );
    assert!(
        src.contains("pub extern \"C\" fn Div_describe_free_rust_string"),
        "{src}"
    );
    assert!(src.contains("-> CResult_Div_describe"), "{src}");
    assert!(src.contains("-> COption_Div_find"), "{src}");
    // A method with no string payload declares no buffer.
    assert!(!src.contains("Div_find_RustCallOwnedString"), "{src}");
    // The method itself is kept as written next to the wrapper (#279).
    assert!(
        src.contains("pub fn describe(&self, unit: String) -> Result<String, String>"),
        "{src}"
    );
}

#[test]
fn cfg_is_propagated_to_every_generated_item() {
    let method: syn::ImplItemFn = syn::parse_quote! {
        #[cfg(unix)]
        #[cfg_attr(feature = "x", cfg(target_pointer_width = "64"))]
        pub fn describe(&self, unit: String) -> Result<String, String> { Ok(unit) }
    };
    let ty: syn::Ident = syn::parse_quote!(Div);
    let src = flatten(&prettyplease::unparse(
        &syn::parse2(generate_method_wrapper_crate(&ty, &method)).unwrap(),
    ));

    // Every item the wrapper drags in — the panic channel, its reader, the
    // string buffer, its release function, the aggregate, its impl block and
    // the wrapper itself — carries the predicate, or the crate stops compiling
    // on the other configuration.
    let file: syn::File = syn::parse2(generate_method_wrapper_crate(&ty, &method)).unwrap();
    for item in &file.items {
        let attrs = match item {
            syn::Item::Struct(s) => &s.attrs,
            syn::Item::Impl(i) => &i.attrs,
            syn::Item::Fn(f) => &f.attrs,
            syn::Item::Macro(m) => &m.attrs,
            other => panic!("unexpected generated item {other:?}"),
        };
        assert!(
            attrs.iter().any(|a| a.path().is_ident("cfg")),
            "generated item without #[cfg]: {src}"
        );
        assert!(
            attrs.iter().any(|a| a.path().is_ident("cfg_attr")),
            "generated item without #[cfg_attr]: {src}"
        );
    }
}

#[test]
fn manifest_reports_the_payloads() {
    let manifest = extract(SRC, Mode::Inline).unwrap();
    let s = &manifest.structs[0];
    let m = |name: &str| s.methods.iter().find(|m| m.name == name).unwrap();

    assert_eq!(m("checked_div").return_kind, ReturnKind::Result);
    assert_eq!(m("checked_div").ok_type, "i32");
    assert_eq!(m("checked_div").err_type, "String");
    assert_eq!(m("checked_div").ok_abi, "");
    assert_eq!(m("checked_div").err_abi, "string");
    assert_eq!(m("checked_div").symbol, "rustcall_Div_checked_div");

    assert_eq!(m("find").return_kind, ReturnKind::Option);
    assert_eq!(m("find").inner_type, "f64");
    assert_eq!(m("find").inner_abi, "");

    assert_eq!(m("describe").ok_abi, "string");
    assert_eq!(m("describe").err_abi, "string");

    assert_eq!(m("label").return_kind, ReturnKind::Option);
    assert_eq!(m("label").inner_abi, "string");

    // Neither a constructor nor a plain method acquires a payload.
    assert_eq!(m("new").return_kind, ReturnKind::Plain);
    assert!(m("new").returns_boxed_struct);
    assert_eq!(m("plain").return_kind, ReturnKind::Plain);
    assert_eq!(m("plain").ok_abi, "");

    // The struct carries the owned-string buffer because its methods need it.
    assert!(s.has_owned_string_helper);
    assert!(!s.has_borrowed_string_helper);
}

#[test]
fn generic_struct_methods_are_not_wrapped() {
    // A generic struct's methods are monomorphized on demand and return the
    // type as written, so the manifest must keep saying `Plain` — claiming the
    // aggregate ABI for a wrapper nobody generates is worse than saying
    // nothing.
    const GENERIC: &str = r#"
#[julia]
pub struct Holder<T> { value: T }

impl<T: Copy> Holder<T> {
    pub fn new(value: T) -> Self { Holder { value } }
    pub fn checked(&self, ok: bool) -> Result<i32, i32> { if ok { Ok(1) } else { Err(0) } }
}
"#;
    let manifest = extract(GENERIC, Mode::Inline).unwrap();
    let s = &manifest.structs[0];
    let checked = s.methods.iter().find(|m| m.name == "checked").unwrap();
    assert_eq!(checked.return_kind, ReturnKind::Plain);
    assert_eq!(checked.ok_type, "");
    assert!(!expand(GENERIC)
        .unwrap()
        .source
        .contains("CResult_Holder_checked"));
}

#[test]
fn a_payload_the_aggregate_cannot_carry_keeps_the_old_lowering() {
    // `Vec<i32>` is neither FFI-compatible nor a string, so there is no honest
    // way to put it in the aggregate. The method keeps the pre-#268 behaviour
    // (returned as written, reported as `Plain`) rather than turning code that
    // compiles today into a compile error.
    const SRC_VEC: &str = r#"
#[julia]
pub struct Bag { n: i32 }

impl Bag {
    pub fn new(n: i32) -> Self { Bag { n } }
    pub fn items(&self) -> Result<Vec<i32>, i32> { Ok(vec![self.n]) }
}
"#;
    let manifest = extract(SRC_VEC, Mode::Inline).unwrap();
    let s = &manifest.structs[0];
    let items = s.methods.iter().find(|m| m.name == "items").unwrap();
    assert_eq!(items.return_kind, ReturnKind::Plain);
    assert!(!expand(SRC_VEC)
        .unwrap()
        .source
        .contains("CResult_Bag_items"));
}
