//! An elided lifetime in a wrapper's plain return (#484).
//!
//! A wrapper cannot copy `-> &i32` as written: its receiver is a raw pointer
//! and a lowered string a pointer and a length, so elision on the wrapper
//! finds no input lifetime and rustc failed with E0106 inside generated code.
//! The lifetime Rust's elision rules pick on the *item* is spelled out on the
//! wrapper instead (`rustcall_julia_core::environment::name_elided_return`):
//! the receiver's, or the one lifetime of a passed-through argument. When that
//! one lifetime is a lowered string's, the returned value would borrow a
//! string that is gone when the wrapper returns, and the item is refused at
//! the argument. Every block is compiled the way `rust"""` compiles it:
//! `rustc` with no `--edition`.
//!
//! The proc-macro flavour is `deps/rustcall_julia_macros/tests/elided_returns.rs`
//! and `tests/ui/elided_return.rs`.

use std::{fs, process::Command};

use rustcall_julia_core::expand::expand;
use rustcall_julia_core::specialize::specialize;

/// Compile `source` with no `--edition`, as `RustCall.compile_rust_to_shared_lib`
/// does; with `main`, as a binary that is then run.
fn rustc(label: &str, source: &str, main: Option<&str>) -> std::process::Output {
    let dir = std::env::temp_dir().join(format!(
        "rustcall_elided_returns_{}_{label}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    let input = dir.join("lib.rs");
    let text = match main {
        Some(main) => format!(
            "#![allow(non_snake_case, unexpected_cfgs, dead_code)]\n{source}\nfn main() {{ {main} }}\n"
        ),
        None => format!("#![allow(non_snake_case, unexpected_cfgs, dead_code)]\n{source}"),
    };
    fs::write(&input, text).unwrap();
    let crate_type = if main.is_some() { "bin" } else { "cdylib" };
    let out = Command::new("rustc")
        .args(["--crate-type", crate_type, "-C", "panic=unwind", "-o"])
        .arg(dir.join("out"))
        .arg(&input)
        .output()
        .unwrap();
    let out = if out.status.success() && main.is_some() {
        Command::new(dir.join("out")).output().unwrap()
    } else {
        out
    };
    fs::remove_dir_all(dir).ok();
    out
}

/// One line, without the line breaks `prettyplease` puts inside a long
/// parameter list.
fn flat(source: &str) -> String {
    source
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace("( ", "(")
        .replace(", )", ")")
}

const CALLABLE: &str = r#"
    #[julia]
    pub struct Buf { pub n: i32 }

    impl Buf {
        pub fn new(n: i32) -> Self { Buf { n } }

        // From the receiver.
        pub fn get(&self) -> &i32 { &self.n }
        pub fn get_mut(&mut self) -> &mut i32 { &mut self.n }
        pub fn anon(&self) -> &'_ i32 { &self.n }
        pub fn named<'a>(&'a self) -> &i32 { &self.n }
        pub fn me(&self) -> &Self { self }
        pub fn maybe(&self, some: bool) -> Option<&i32> { if some { Some(&self.n) } else { None } }
        // The receiver wins over every other input, a lowered string included.
        pub fn with_str(&self, s: &str) -> &i32 { let _ = s; &self.n }
        pub fn with_other(&self, o: &Buf) -> &i32 { let _ = o; &self.n }
        // A user lifetime spelled like the fresh one: the fresh one moves on.
        pub fn taken<'rustcall>(&self, o: &'rustcall Buf) -> &i32 { let _ = o; &self.n }

        // No receiver: the one lifetime of a passed-through argument.
        pub fn pick(o: &Buf) -> &i32 { &o.n }
        pub fn pick_named<'a>(o: &'a Buf, flag: bool) -> &i32 { let _ = flag; &o.n }
    }

    impl<'x> Buf {
        pub fn block(&'x self) -> &i32 { &self.n }
    }

    #[julia]
    pub fn free_pick(b: &Buf) -> &i32 { &b.n }
    #[julia]
    pub fn free_static(x: &'static i32, s: String) -> &i32 { let _ = s; x }
"#;

const CALLS: &str = r#"
    static SEVEN: i32 = 7;
    let o = Buf { n: 2 };
    let s = "four";
    unsafe {
        let p = rustcall_Buf_new(5);
        let n: *const i32 = &(*p).n;
        assert!(::std::ptr::eq(rustcall_Buf_get(p).assume_init(), n));
        *rustcall_Buf_get_mut(p).assume_init() = 6;
        assert_eq!((*p).n, 6);
        assert!(::std::ptr::eq(rustcall_Buf_anon(p).assume_init(), n));
        assert!(::std::ptr::eq(rustcall_Buf_named(p).assume_init(), n));
        assert!(::std::ptr::eq(rustcall_Buf_me(p).assume_init(), p));
        assert_eq!(rustcall_Buf_maybe(p, true).assume_init(), Some(&6));
        assert_eq!(rustcall_Buf_maybe(p, false).assume_init(), None);
        assert!(::std::ptr::eq(rustcall_Buf_with_str(p, s.as_ptr(), s.len()).assume_init(), n));
        assert!(::std::ptr::eq(rustcall_Buf_with_other(p, &o).assume_init(), n));
        assert!(::std::ptr::eq(rustcall_Buf_taken(p, &o).assume_init(), n));
        assert!(::std::ptr::eq(rustcall_Buf_pick(&o).assume_init(), &o.n));
        assert!(::std::ptr::eq(rustcall_Buf_pick_named(&o, true).assume_init(), &o.n));
        assert!(::std::ptr::eq(rustcall_Buf_block(p).assume_init(), n));
        assert!(::std::ptr::eq(rustcall_free_pick(&o).assume_init(), &o.n));
        assert!(::std::ptr::eq(rustcall_free_static(&SEVEN, s.as_ptr(), s.len()).assume_init(), &SEVEN));
        Buf_free(p);
    }
"#;

const METHODS: &[&str] = &[
    "new",
    "get",
    "get_mut",
    "anon",
    "named",
    "me",
    "maybe",
    "with_str",
    "with_other",
    "taken",
    "pick",
    "pick_named",
    "block",
];

#[test]
fn every_elided_return_compiles_and_is_called_through_its_wrapper() {
    let expanded = expand(CALLABLE).unwrap();
    let out = rustc("callable", &expanded.source, Some(CALLS));
    assert!(
        out.status.success(),
        "{}{}\n{}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout),
        expanded.source
    );
    let out = rustc("callable_cdylib", &expanded.source, None);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    // Exported symbols are the scheme's, unchanged by the naming.
    let buf = &expanded.manifest.structs[0];
    let reported: Vec<(String, String)> = buf
        .methods
        .iter()
        .map(|m| (m.name.clone(), m.symbol.clone()))
        .collect();
    let expected: Vec<(String, String)> = METHODS
        .iter()
        .map(|m| (m.to_string(), format!("rustcall_Buf_{m}")))
        .collect();
    assert_eq!(reported, expected);
    let functions: Vec<(&str, &str)> = expanded
        .manifest
        .functions
        .iter()
        .map(|f| (f.name.as_str(), f.symbol.as_str()))
        .collect();
    assert_eq!(
        functions,
        [
            ("free_pick", "rustcall_free_pick"),
            ("free_static", "rustcall_free_static")
        ]
    );
}

/// The lifetime elision picks on the item is the one the wrapper spells.
#[test]
fn the_wrapper_names_the_lifetime_elision_picks_on_the_item() {
    let expanded = expand(CALLABLE).unwrap();
    let source = flat(&expanded.source);
    for sig in [
        // An elided receiver: a fresh lifetime, declared on the wrapper.
        "fn rustcall_Buf_get<'rustcall>(ptr: *const Buf) -> ::std::mem::MaybeUninit<&'rustcall i32> {",
        "fn rustcall_Buf_get_mut<'rustcall>(ptr: *mut Buf) -> ::std::mem::MaybeUninit<&'rustcall mut i32> {",
        "fn rustcall_Buf_anon<'rustcall>(ptr: *const Buf) -> ::std::mem::MaybeUninit<&'rustcall i32> {",
        "fn rustcall_Buf_me<'rustcall>(ptr: *const Buf) -> ::std::mem::MaybeUninit<&'rustcall Buf> {",
        "-> ::std::mem::MaybeUninit<Option<&'rustcall i32>> {",
        "fn rustcall_Buf_with_str<'rustcall>(ptr: *const Buf, s_ptr: *const u8, s_len: usize) -> ::std::mem::MaybeUninit<&'rustcall i32> {",
        "fn rustcall_Buf_with_other<'rustcall>(ptr: *const Buf, o: &Buf) -> ::std::mem::MaybeUninit<&'rustcall i32> {",
        "fn rustcall_Buf_taken<'rustcall, 'rustcall1>(ptr: *const Buf, o: &'rustcall Buf) -> ::std::mem::MaybeUninit<&'rustcall1 i32> {",
        // A named receiver: its own lifetime.
        "fn rustcall_Buf_named<'a>(ptr: *const Buf) -> ::std::mem::MaybeUninit<&'a i32> {",
        "fn rustcall_Buf_block<'x>(ptr: *const Buf) -> ::std::mem::MaybeUninit<&'x i32> {",
        // No receiver: the argument's, named on both sides.
        "fn rustcall_Buf_pick<'rustcall>(o: &'rustcall Buf) -> ::std::mem::MaybeUninit<&'rustcall i32> {",
        "fn rustcall_Buf_pick_named<'a>(o: &'a Buf, flag: bool) -> ::std::mem::MaybeUninit<&'a i32> {",
        "fn rustcall_free_pick<'rustcall>(b: &'rustcall Buf) -> ::std::mem::MaybeUninit<&'rustcall i32> {",
        "-> ::std::mem::MaybeUninit<&'static i32> {",
    ] {
        assert!(source.contains(sig), "missing `{sig}`:\n{source}");
    }
}

/// A lowered string is rebuilt into a local: a return that elision ties to it
/// is refused with RustCall's own message, and nothing else fails. (The span
/// is the argument's; the proc-macro UI test shows it, an expanded `rust"""`
/// block is re-printed source.)
#[test]
fn a_return_borrowed_from_a_lowered_string_is_refused() {
    let cases: &[(&str, &str, &str)] = &[
        (
            "static_method",
            "impl Buf { pub fn a(s: &str) -> &i32 { let _ = s; &N } }",
            "`Buf::a`: the returned reference borrows from argument `s` by lifetime elision, but `s` arrives from Julia as a pointer and a length",
        ),
        (
            "free",
            "#[julia] pub fn a(s: &str) -> &i32 { let _ = s; &N }",
            "`a`: the returned reference borrows from argument `s` by lifetime elision",
        ),
        (
            "anonymous",
            "#[julia] pub fn a(s: &'_ str) -> Option<i32> { let _ = s; None }
             #[julia] pub fn b(s: &'_ str) -> &'_ i32 { let _ = s; &N }",
            "`b`: the returned reference borrows from argument `s` by lifetime elision",
        ),
        (
            // Named, the lifetime is the string's too; #482's rule refuses it.
            "named",
            "#[julia] pub fn a<'a>(s: &'a str) -> &i32 { let _ = s; &N }",
            "`a`: argument `s` arrives from Julia as a pointer and a length and is rebuilt into a string that lives only for the call, so `'a` cannot be required to outlive the call; but the wrapper returns `&'a i32`, which names it",
        ),
    ];
    for (label, items, message) in cases {
        let block = format!(
            "static N: i32 = 3;
            #[julia]
            pub struct Buf {{ pub n: i32 }}
            {items}"
        );
        let expanded = expand(&block).unwrap();
        let out = rustc(label, &expanded.source, None);
        assert!(
            !out.status.success(),
            "{label} compiled:\n{}",
            expanded.source
        );
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(stderr.contains(message), "{label}: {stderr}");
        assert!(!stderr.contains("error["), "{label}: {stderr}");
    }
}

/// An item whose own output lifetime is ambiguous is E0106 at its own
/// signature; no wrapper repeats the error inside generated code.
#[test]
fn an_ambiguous_item_is_left_to_rustc_at_its_own_signature() {
    let expanded = expand(
        "#[julia]
        pub struct Buf { pub n: i32 }
        #[julia]
        pub fn ambiguous(a: &Buf, b: &Buf) -> &i32 { let _ = b; &a.n }",
    )
    .unwrap();
    assert!(
        !expanded.source.contains("fn rustcall_ambiguous"),
        "{}",
        expanded.source
    );
    let out = rustc("ambiguous", &expanded.source, None);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(!out.status.success());
    assert_eq!(stderr.matches("error[E0106]").count(), 1, "{stderr}");
    assert!(
        stderr.contains("pub fn ambiguous(a: &Buf, b: &Buf) -> &i32"),
        "{stderr}"
    );
}

/// A generic struct's method wrapper names the receiver's lifetime too, and
/// every instance compiles.
#[test]
fn a_generic_structs_wrappers_name_the_receivers_lifetime() {
    let expanded = expand(
        r#"
        #[julia]
        pub struct Wrap<T> { pub v: T, pub n: i32 }
        impl<T: Copy> Wrap<T> {
            pub fn new(v: T) -> Self { Wrap { v, n: 1 } }
            pub fn get(&self) -> &T { &self.v }
            pub fn num(&self) -> &i32 { &self.n }
            pub fn anon(&mut self) -> &'_ mut T { &mut self.v }
            pub fn named<'a>(&'a self) -> &T { &self.v }
            pub fn pick(o: &Wrap<T>) -> &T { &o.v }
            pub fn text(&self) -> &str { "x" }
        }
    "#,
    )
    .unwrap();
    let source = flat(&expanded.source);
    let out = rustc("generic", &expanded.source, None);
    assert!(
        out.status.success(),
        "{}\n{source}",
        String::from_utf8_lossy(&out.stderr)
    );
    let wrap = &expanded.manifest.structs[0];
    for (method, spelled) in [
        ("get", "-> &'rustcall T"),
        ("num", "-> &'rustcall i32"),
        ("anon", "-> &'rustcall mut T"),
        ("named", "-> &'a T"),
        ("pick", "-> &T"),
        ("text", "-> &'rustcall str"),
    ] {
        let name = format!("Wrap_{method}");
        let wrapper = wrap
            .generic_wrappers
            .iter()
            .find(|w| w.name == name)
            .unwrap_or_else(|| panic!("no {name}"));
        assert!(
            flat(&wrapper.source).contains(spelled),
            "{method}: {}",
            wrapper.source
        );
        let instance = specialize(
            &format!("{}\n{}", wrap.context_source, wrapper.source),
            &name,
            &[("T".into(), "i32".into())],
            &format!("{name}_i32"),
        )
        .unwrap();
        let out = rustc(&format!("generic_{method}"), &instance.source, None);
        assert!(
            out.status.success(),
            "{method}: {}\n{}",
            String::from_utf8_lossy(&out.stderr),
            instance.source
        );
    }
}

/// A generic struct's method may declare a lifetime spelled like the fresh
/// one (PR #498 review): the wrapper takes the next free name, by the same
/// rule as a concrete struct's wrapper, instead of declaring `'rustcall`
/// twice (E0403 once specialized).
#[test]
fn a_generic_structs_fresh_lifetime_avoids_the_methods_own() {
    let expanded = expand(
        r#"
        #[julia]
        pub struct Wrap<T> { pub v: T }
        impl<T: Copy> Wrap<T> {
            pub fn new(v: T) -> Self { Wrap { v } }
            pub fn get<'rustcall>(&self, x: &'rustcall i32) -> &T { let _ = x; &self.v }
            pub fn both<'rustcall, 'rustcall1>(&self, x: &'rustcall i32, y: &'rustcall1 i32) -> &T {
                let _ = (x, y);
                &self.v
            }
        }
    "#,
    )
    .unwrap();
    let wrap = &expanded.manifest.structs[0];
    for (method, spelled) in [("get", "-> &'rustcall1 T"), ("both", "-> &'rustcall2 T")] {
        let name = format!("Wrap_{method}");
        let wrapper = wrap
            .generic_wrappers
            .iter()
            .find(|w| w.name == name)
            .unwrap_or_else(|| panic!("no {name}"));
        assert!(
            flat(&wrapper.source).contains(spelled),
            "{method}: {}",
            wrapper.source
        );
        let instance = specialize(
            &format!("{}\n{}", wrap.context_source, wrapper.source),
            &name,
            &[("T".into(), "i32".into())],
            &format!("{name}_i32"),
        )
        .unwrap();
        let out = rustc(&format!("generic_taken_{method}"), &instance.source, None);
        assert!(
            out.status.success(),
            "{method}: {}\n{}",
            String::from_utf8_lossy(&out.stderr),
            instance.source
        );
    }
}
