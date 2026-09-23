//! Two gaps of the inline expander left by #471 (#477).
//!
//! 1. A method of a **generic** inline struct that is generic in its own right
//!    (`impl<T> W<T> { pub fn f<U>(..) }`) got a generic wrapper carrying both
//!    parameters, while instantiating the struct binds only `T`. It is refused
//!    at the method now, as #471 refuses a generic method of a concrete struct.
//! 2. A method taking a struct reference with a named lifetime
//!    (`fn f<'a>(&self, other: &'a Buf)`) got a wrapper spelling `other: &'a Buf`
//!    without declaring `'a`, so the expanded block did not compile. The
//!    wrapper declares the lifetimes its signature names now, with their
//!    bounds.
//!
//! Every block is compiled the way `rust"""` compiles it: `rustc` with no
//! `--edition`.

use std::{fs, process::Command};

use rustcall_julia_core::expand::expand;
use rustcall_julia_core::specialize::specialize;

fn rustc(label: &str, source: &str) -> std::process::Output {
    let dir = std::env::temp_dir().join(format!(
        "rustcall_inline_gaps_{}_{label}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    let input = dir.join("lib.rs");
    fs::write(
        &input,
        format!("#![allow(non_snake_case, unexpected_cfgs, dead_code)]\n{source}"),
    )
    .unwrap();
    // No `--edition`, as `RustCall.compile_rust_to_shared_lib`.
    let out = Command::new("rustc")
        .args(["--crate-type=cdylib", "-C", "panic=unwind"])
        .arg(&input)
        .arg("--out-dir")
        .arg(&dir)
        .output()
        .unwrap();
    fs::remove_dir_all(dir).unwrap();
    out
}

fn assert_compiles(label: &str, source: &str) {
    let out = rustc(label, source);
    assert!(
        out.status.success(),
        "{}\n{source}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// One line, without the line breaks `prettyplease` puts inside a long
/// parameter list (`f( a: A, b: B, )` reads `f(a: A, b: B)`).
fn flat(source: &str) -> String {
    source
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace("( ", "(")
        .replace(", )", ")")
}

const GENERIC_STRUCT_GENERIC_METHOD: &str = r#"
    #[julia]
    pub struct Wrap<T> { pub v: T }
    impl<T: Copy> Wrap<T> {
        pub fn new(v: T) -> Self { Wrap { v } }
        pub fn get(&self) -> T { self.v }
        pub fn pair<U: Copy>(&self, u: U) -> U { u }
    }
"#;

#[test]
fn a_generic_method_of_a_generic_struct_is_refused_at_the_method() {
    let expanded = expand(GENERIC_STRUCT_GENERIC_METHOD).unwrap();
    let source = flat(&expanded.source);
    assert!(
        source.contains("compile_error!"),
        "no refusal:\n{}",
        expanded.source
    );
    assert!(
        source.contains("`Wrap::pair` is generic over `U`"),
        "{source}"
    );
    assert!(source.contains("instantiated per struct type"), "{source}");

    // No generic wrapper carrying the unbound `U` ...
    let wrap = &expanded.manifest.structs[0];
    let wrappers: Vec<&str> = wrap
        .generic_wrappers
        .iter()
        .map(|w| w.name.as_str())
        .collect();
    assert!(!wrappers.contains(&"Wrap_pair"), "{wrappers:?}");
    assert!(!source.contains("fn Wrap_pair"), "{source}");
    // ... while the methods that use only the struct's parameter keep theirs.
    assert!(wrappers.contains(&"Wrap_get"), "{wrappers:?}");
    assert!(wrappers.contains(&"Wrap_new"), "{wrappers:?}");

    // The manifest describes what can be bound: no `pair`.
    let names: Vec<&str> = wrap.methods.iter().map(|m| m.name.as_str()).collect();
    assert_eq!(names, ["new", "get"]);

    // rustc stops at the refusal, not inside generated code.
    let out = rustc("refused", &expanded.source);
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("`Wrap::pair` is generic over `U`"),
        "{stderr}"
    );
    assert!(!stderr.contains("cannot find type `U`"), "{stderr}");

    // What is left instantiates: `Wrap_get` at `T = i32` compiles.
    let get = wrap
        .generic_wrappers
        .iter()
        .find(|w| w.name == "Wrap_get")
        .unwrap();
    let out = specialize(
        &format!("{}\n{}", wrap.context_source, get.source),
        "Wrap_get",
        &[("T".into(), "i32".into())],
        "Wrap_get_i32",
    )
    .unwrap();
    assert!(
        out.source.contains("rustcall_Wrap_get_i32"),
        "{}",
        out.source
    );
}

/// `impl Trait` and a const parameter make a generic struct's method generic
/// in its own right as well; a lifetime does not.
#[test]
fn impl_trait_and_const_methods_of_a_generic_struct_are_refused() {
    let expanded = expand(
        r#"
        #[julia]
        pub struct Cell<T> { pub v: T }
        impl<T: Copy> Cell<T> {
            pub fn shown(&self, x: impl Copy) -> T { let _ = x; self.v }
            pub fn sized<const N: usize>(&self) -> usize { N }
            pub fn pick<'a>(&'a self, other: &'a Cell<T>) -> T { let _ = other; self.v }
        }
    "#,
    )
    .unwrap();
    let source = flat(&expanded.source);
    assert!(
        source.contains("`Cell::shown` uses `impl Trait`"),
        "{source}"
    );
    assert!(
        source.contains("`Cell::sized` is generic over `const N`"),
        "{source}"
    );
    let names: Vec<&str> = expanded.manifest.structs[0]
        .methods
        .iter()
        .map(|m| m.name.as_str())
        .collect();
    assert_eq!(names, ["pick"]);
}

/// The refusal exists only where the method does.
#[test]
fn the_generic_struct_refusal_carries_the_cfg() {
    let expanded = expand(
        r#"
        #[julia]
        pub struct Wrap<T> { pub v: T }
        impl<T: Copy> Wrap<T> {
            pub fn get(&self) -> T { self.v }
            #[cfg(rustcall_never)]
            pub fn pair<U: Copy>(&self, u: U) -> U { u }
        }
        #[cfg(rustcall_never)]
        impl<T: Copy> Wrap<T> {
            pub fn other<U: Copy>(&self, u: U) -> U { u }
        }

        #[cfg(rustcall_never)]
        #[julia]
        pub struct Gone<T> { pub v: T }
        #[cfg(rustcall_never)]
        impl<T: Copy> Gone<T> {
            pub fn pair<U: Copy>(&self, u: U) -> U { u }
        }
    "#,
    )
    .unwrap();
    assert!(
        expanded.source.contains("compile_error!"),
        "{}",
        expanded.source
    );
    assert_compiles("gated", &expanded.source);
}

const NAMED_LIFETIMES: &str = r#"
    #[julia]
    pub struct Buf { pub n: i32 }
    impl Buf {
        pub fn new(n: i32) -> Self { Buf { n } }
        pub fn sum<'a>(&self, other: &'a Buf) -> i32 { self.n + other.n }
        pub fn both<'a>(&'a self, other: &'a Buf) -> i32 { self.n * other.n }
        pub fn nested<'a, 'b: 'a>(&'a self, x: &'a Buf, y: &'b Buf) -> i32 { x.n - y.n + self.n }
        pub fn bounded<'a, 'b>(&self, x: &'a Buf, y: &'b Buf) -> i32 where 'b: 'a { x.n + y.n }
        pub fn absorb<'a>(&mut self, other: &'a mut Buf) { self.n += other.n; other.n = 0; }
        pub fn labelled<'a>(&self, other: &'a Buf, s: &'a str) -> usize { s.len() + other.n as usize }
    }

    #[julia]
    pub fn buf_total<'a>(a: &'a Buf, b: &'a Buf) -> i32 { a.n + b.n }

    pub mod ops {
        impl super::Buf {
            pub fn diff<'a>(&self, other: &'a super::Buf) -> i32 { self.n - other.n }
        }
    }
"#;

#[test]
fn a_named_lifetime_on_a_struct_reference_is_declared_on_the_wrapper() {
    let expanded = expand(NAMED_LIFETIMES).unwrap();
    let source = flat(&expanded.source);
    for sig in [
        "pub extern \"C\" fn rustcall_Buf_sum<'a>(ptr: *const Buf, other: &'a Buf)",
        "pub extern \"C\" fn rustcall_Buf_both<'a>(ptr: *const Buf, other: &'a Buf)",
        "pub extern \"C\" fn rustcall_Buf_nested<'a, 'b: 'a>(",
        "pub extern \"C\" fn rustcall_Buf_bounded<'a, 'b>(",
        "where 'b: 'a",
        "pub extern \"C\" fn rustcall_Buf_absorb<'a>(ptr: *mut Buf, other: &'a mut Buf)",
        "pub extern \"C\" fn rustcall_buf_total<'a>(a: &'a Buf, b: &'a Buf)",
        "pub extern \"C\" fn rustcall_Buf_diff<'a>(",
        // A lifetime only a string argument names is not declared: the
        // string becomes a pointer and a length.
        "pub extern \"C\" fn rustcall_Buf_labelled<'a>(ptr: *const Buf, other: &'a Buf, s_ptr: *const u8, s_len: usize)",
    ] {
        assert!(source.contains(sig), "missing `{sig}`:\n{source}");
    }
    assert_compiles("lifetimes", &expanded.source);

    // Every method is still reported for Julia to bind.
    let names: Vec<&str> = expanded.manifest.structs[0]
        .methods
        .iter()
        .map(|m| m.name.as_str())
        .collect();
    assert_eq!(
        names,
        ["new", "sum", "both", "nested", "bounded", "absorb", "labelled", "diff"]
    );
}

/// A lifetime only a lowered string names stays undeclared, so the wrappers of
/// `&'a str` functions are unchanged.
#[test]
fn a_lifetime_only_a_string_names_is_not_declared() {
    let expanded = expand(
        r#"
        #[julia]
        pub fn echo_len<'a>(s: &'a str) -> usize { s.len() }
    "#,
    )
    .unwrap();
    let source = flat(&expanded.source);
    assert!(
        source.contains("pub extern \"C\" fn rustcall_echo_len(s_ptr: *const u8, s_len: usize)"),
        "{source}"
    );
    assert_compiles("strings", &expanded.source);
}

/// A `for<'b>` binder inside a `where` predicate names a lifetime that is not
/// the item's: it must not drop the predicate from the wrapper, or the call
/// inside it loses the bound it needs (E0277, PR #480 review).
#[test]
fn a_higher_ranked_bound_is_kept_on_the_wrapper() {
    let expanded = expand(
        r#"
        pub trait Rel<T> { fn rel(&self, other: T) -> i32; }
        // Only for a `'static` argument, so the bound is not provable for an
        // arbitrary `'a`: a wrapper without it does not compile.
        impl<'x> Rel<&'static Buf> for &'x Buf {
            fn rel(&self, other: &'static Buf) -> i32 { self.n - other.n }
        }

        #[julia]
        pub struct Buf { pub n: i32 }
        impl Buf {
            pub fn new(n: i32) -> Self { Buf { n } }
            pub fn related<'a>(&self, other: &'a Buf) -> i32
            where
                for<'b> &'b Buf: Rel<&'a Buf>,
            {
                (&*self).rel(other)
            }
        }
    "#,
    )
    .unwrap();
    let source = flat(&expanded.source);
    assert!(
        source.contains(
            "pub extern \"C\" fn rustcall_Buf_related<'a>(ptr: *const Buf, other: &'a Buf)"
        ),
        "{source}"
    );
    assert!(
        source.contains(
            "other: &'a Buf) -> ::std::mem::MaybeUninit<i32> where for<'b> &'b Buf: Rel<&'a Buf>"
        ),
        "{source}"
    );
    assert_compiles("higher_ranked", &expanded.source);
}

/// A method `where` predicate naming `Self` is valid in the impl but not
/// verbatim on the wrapper, a free function where `Self` does not exist
/// (E0411). A predicate that names none of the lifetimes the wrapper declares
/// is not carried over at all — the wrapper compiled without it before #477 —
/// and one that does is carried with `Self` spelled `Buf`, qualified paths
/// included (PR #480 review). (A bare `Self::Tag` is E0223 in an inherent
/// impl of a concrete type, so it never reaches the expander in a block that
/// compiles.)
#[test]
fn a_self_predicate_is_carried_only_when_it_relates_declared_lifetimes() {
    let expanded = expand(
        r#"
        pub trait Tagged { type Tag; fn tag() -> i32; }
        impl Tagged for Buf { type Tag = i32; fn tag() -> i32 { 3 } }
        pub trait Rel<T> { fn rel(&self, other: T) -> i32; }
        impl<'x, 'y> Rel<&'y Buf> for &'x Buf {
            fn rel(&self, other: &'y Buf) -> i32 { self.n - other.n }
        }

        #[julia]
        pub struct Buf { pub n: i32 }
        impl Buf {
            pub fn new(n: i32) -> Self { Buf { n } }
            pub fn run(&self) -> i32 where Self: Tagged { <Self as Tagged>::tag() + self.n }
            pub fn assoc(&self) -> i32 where Self: Tagged, <Self as Tagged>::Tag: Copy { self.n }
            pub fn plain(&self) -> i32 where Buf: Tagged { self.n }
            pub fn both<'a>(&self, other: &'a Buf) -> i32 where Self: Tagged, <Self as Tagged>::Tag: Copy + 'a { self.n + other.n }
        }
    "#,
    )
    .unwrap();
    let source = flat(&expanded.source);
    for sig in [
        "pub extern \"C\" fn rustcall_Buf_run(ptr: *const Buf) -> ::std::mem::MaybeUninit<i32> {",
        "pub extern \"C\" fn rustcall_Buf_assoc(ptr: *const Buf) -> ::std::mem::MaybeUninit<i32> {",
        "pub extern \"C\" fn rustcall_Buf_plain(ptr: *const Buf) -> ::std::mem::MaybeUninit<i32> {",
        "pub extern \"C\" fn rustcall_Buf_both<'a>(ptr: *const Buf, other: &'a Buf) -> ::std::mem::MaybeUninit<i32> where <Buf as Tagged>::Tag: Copy + 'a",
    ] {
        assert!(source.contains(sig), "missing `{sig}`:\n{source}");
    }
    assert_compiles("self_predicates", &expanded.source);
}

/// A `Self` predicate can be the only proof a call is valid: with
/// `Rel<&'static Buf>` as the only impl, `related<'a>` needs
/// `for<'b> &'b Self: Rel<&'a Buf>` on its wrapper, or `other` escapes as
/// `'static` (E0521). The wrapper carries it with `Self` spelled as the
/// receiver type, `<Self as Trait>::Assoc` included; a bare `Self::Assoc`,
/// whose trait is not written, stays on the method (PR #480 review).
#[test]
fn a_self_predicate_is_carried_with_the_receiver_type() {
    let expanded = expand(
        r#"
        pub trait Rel<T> { type Out; fn rel(&self, other: T) -> i32; }
        impl<'x> Rel<&'static Buf> for &'x Buf {
            type Out = i32;
            fn rel(&self, other: &'static Buf) -> i32 { self.n - other.n }
        }

        #[julia]
        pub struct Buf { pub n: i32 }
        impl Buf {
            pub fn new(n: i32) -> Self { Buf { n } }
            pub fn related<'a>(&self, other: &'a Buf) -> i32
            where
                for<'b> &'b Self: Rel<&'a Buf>,
            {
                (&*self).rel(other)
            }
            pub fn qualified<'a>(&self, other: &'a Buf) -> i32
            where
                for<'b> &'b Self: Rel<&'a Buf>,
                for<'b> <&'b Self as Rel<&'a Buf>>::Out: Copy,
            {
                (&*self).rel(other)
            }
        }
    "#,
    )
    .unwrap();
    let source = flat(&expanded.source);
    assert!(
        source.contains(
            "fn rustcall_Buf_related<'a>(ptr: *const Buf, other: &'a Buf) -> ::std::mem::MaybeUninit<i32> where for<'b> &'b Buf: Rel<&'a Buf>"
        ),
        "{source}"
    );
    assert!(
        source.contains("for<'b> <&'b Buf as Rel<&'a Buf>>::Out: Copy"),
        "{source}"
    );
    assert_compiles("self_proof", &expanded.source);
}
