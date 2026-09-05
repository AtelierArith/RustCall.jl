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
    // Lifetime-qualified &str is a string argument as well.
    assert!(src.contains("pub extern \"C\" fn identity(s_ptr: *const u8, s_len: usize) -> identity_RustCallBorrowedString"), "{src}");
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
        assert!(f("identity").has_borrowed_string_helper);
    }
}
