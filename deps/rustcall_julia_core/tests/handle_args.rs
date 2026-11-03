//! Borrowed `#[julia]` struct arguments (#565): `&Self`, `&Value` and
//! `&mut a::Value` are reported as opaque handles, so Julia passes the pointer
//! its handle owns instead of trying to pass the object by value. Only a path
//! that names the struct with certainty is classified.

use rustcall_julia_core::manifest::{Arg, Manifest};

fn arg<'a>(manifest: &'a Manifest, owner: Option<&str>, item: &str, name: &str) -> &'a Arg {
    let args = match owner {
        Some(owner) => {
            let s = manifest
                .structs
                .iter()
                .find(|s| s.name == owner)
                .unwrap_or_else(|| panic!("no struct {owner}"));
            &s.methods
                .iter()
                .find(|m| m.name == item)
                .unwrap_or_else(|| panic!("no method {owner}::{item}"))
                .args
        }
        None => {
            &manifest
                .functions
                .iter()
                .find(|f| f.name == item)
                .unwrap_or_else(|| panic!("no function {item}"))
                .args
        }
    };
    args.iter()
        .find(|a| a.name == name)
        .unwrap_or_else(|| panic!("no argument {name} of {item}"))
}

fn assert_handle(a: &Arg, abi: &str, handle: &str) {
    assert_eq!((a.abi.as_str(), a.handle.as_str()), (abi, handle), "{a:?}");
}

const CRATE_SOURCE: &str = r#"
    use rustcall_julia_macros::julia;

    #[julia]
    pub struct Value { n: i32 }

    #[julia]
    impl Value {
        #[julia]
        pub fn new(n: i32) -> Self { Self { n } }
        #[julia]
        pub fn sum(&self, other: &Value) -> i32 { self.n + other.n }
        #[julia]
        pub fn same(&self, other: &Self) -> bool { self.n == other.n }
        #[julia]
        pub fn absorb(&mut self, other: &mut Value) { self.n += other.n; }
        #[julia]
        pub fn tagged(&self, other: &a::Other) -> i32 { self.n + other.m }
        #[julia]
        pub fn named(&self, s: &str) -> usize { s.len() }
        #[julia]
        pub fn generic(&self, g: &Gen<i32>) -> i32 { g.0 }
    }

    pub struct Gen<T>(pub T);

    #[julia]
    pub fn total(a: &Value, b: &crate::Value) -> i32 { a.n + b.n }

    #[julia]
    pub mod a {
        use super::Value;

        #[julia]
        pub struct Other { pub m: i32 }

        #[julia]
        impl Other {
            #[julia]
            pub fn add(&self, v: &Value) -> i32 { self.m + v.n }
            #[julia]
            pub fn up(&self, v: &super::Value) -> i32 { self.m + v.n }
        }

        #[julia]
        pub fn peek(o: &Other, v: &mut Value) -> i32 { v.n += 1; o.m }

        #[julia]
        pub mod shadow {
            // A local plain type shadows the `#[julia]` one for rustc, so the
            // argument is not a handle.
            pub struct Value;
            #[julia]
            pub fn local(v: &Value) -> i32 { let _ = v; 0 }
        }
    }
"#;

#[test]
fn crate_scan_classifies_borrowed_julia_structs() {
    let m = rustcall_julia_core::extract::extract_crate(CRATE_SOURCE).unwrap();
    assert_handle(arg(&m, Some("Value"), "sum", "other"), "handle", "Value");
    assert_handle(arg(&m, Some("Value"), "same", "other"), "handle", "Value");
    assert_handle(
        arg(&m, Some("Value"), "absorb", "other"),
        "handle_mut",
        "Value",
    );
    assert_handle(
        arg(&m, Some("Value"), "tagged", "other"),
        "handle",
        "a__Other",
    );
    assert_handle(arg(&m, Some("Value"), "named", "s"), "str", "");
    assert_handle(arg(&m, Some("Value"), "generic", "g"), "", "");
    assert_handle(arg(&m, None, "total", "a"), "handle", "Value");
    assert_handle(arg(&m, None, "total", "b"), "handle", "Value");
    assert_handle(arg(&m, Some("Other"), "add", "v"), "handle", "Value");
    assert_handle(arg(&m, Some("Other"), "up", "v"), "handle", "Value");
    assert_handle(arg(&m, None, "peek", "o"), "handle", "a__Other");
    assert_handle(arg(&m, None, "peek", "v"), "handle_mut", "Value");
    assert_handle(arg(&m, None, "local", "v"), "", "");
}

#[test]
fn crate_scan_does_not_classify_a_generic_julia_struct() {
    // The proc macro refuses a generic `#[julia]` struct (#462): Julia binds no
    // handle type for it, so a borrow of it stays unclassified.
    let source = r#"
        #[julia]
        pub struct Holder<T> { v: T }
        #[julia]
        pub fn read(h: &Holder) -> i32 { 0 }
    "#;
    let m = rustcall_julia_core::extract::extract_crate(source).unwrap();
    assert_handle(arg(&m, None, "read", "h"), "", "");
}

#[test]
fn inline_expansion_classifies_borrowed_julia_structs() {
    let source = r#"
        #[julia]
        pub struct Value { n: i32 }
        impl Value {
            pub fn new(n: i32) -> Self { Self { n } }
            pub fn sum(&self, other: &Value) -> i32 { self.n + other.n }
            pub fn same(&self, other: &Self) -> bool { self.n == other.n }
            pub fn absorb(&mut self, other: &mut Value) { self.n += other.n; }
        }
        #[julia]
        pub fn total(a: &Value, b: &crate::Value) -> i32 { a.n + b.n }
        #[julia]
        pub fn generic<T: Copy>(a: &Value, t: T) -> T { let _ = a; t }
        pub mod m {
            #[julia]
            pub struct Inner { pub k: i32 }
            #[julia]
            pub fn both(i: &Inner, v: &super::Value) -> i32 { i.k + v.n }
        }
    "#;
    let expanded = rustcall_julia_core::expand::expand(source).unwrap();
    let m = &expanded.manifest;
    assert_handle(arg(m, Some("Value"), "sum", "other"), "handle", "Value");
    assert_handle(arg(m, Some("Value"), "same", "other"), "handle", "Value");
    assert_handle(
        arg(m, Some("Value"), "absorb", "other"),
        "handle_mut",
        "Value",
    );
    assert_handle(arg(m, None, "total", "a"), "handle", "Value");
    assert_handle(arg(m, None, "total", "b"), "handle", "Value");
    assert_handle(arg(m, None, "generic", "a"), "", "");
    assert_handle(arg(m, None, "both", "i"), "handle", "m__Inner");
    assert_handle(arg(m, None, "both", "v"), "handle", "Value");
    // The wrapper takes the reference as written: one thin pointer each.
    assert!(!expanded.source.contains("compile_error"));
}

#[test]
fn handle_columns_round_trip_through_toml() {
    let m = rustcall_julia_core::extract::extract_crate(CRATE_SOURCE).unwrap();
    let text = toml::to_string(&m).unwrap();
    assert!(text.contains("handle = \"a__Other\""));
    let back: Manifest = toml::from_str(&text).unwrap();
    assert_eq!(back, m);
}
