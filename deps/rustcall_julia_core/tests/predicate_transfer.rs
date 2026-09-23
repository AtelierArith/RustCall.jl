//! A method's `where` predicates on its `extern "C"` wrapper (#482).
//!
//! The wrapper declares the item's whole environment — the lifetime
//! parameters and `where` clause of the impl block, then the method's — with
//! `Self` spelled as the impl header's type (`rustcall_julia_core::environment`).
//! Every predicate shape below either compiles and is called through its
//! wrapper, or is refused with RustCall's own diagnostic naming the method; none
//! fails with a rustc error inside generated code. Every block is compiled the
//! way `rust"""` compiles it: `rustc` with no `--edition`.
//!
//! The proc-macro flavour of the same corpus is
//! `deps/rustcall_julia_macros/tests/predicate_transfer.rs` (and
//! `tests/ui/lowered_lifetime.rs` for the refusals).

use std::{fs, process::Command};

use rustcall_julia_core::expand::expand;
use rustcall_julia_core::specialize::specialize;

/// Compile `source` with no `--edition`, as `RustCall.compile_rust_to_shared_lib`
/// does; with `main`, as a binary that is then run.
fn rustc(label: &str, source: &str, main: Option<&str>) -> std::process::Output {
    let dir = std::env::temp_dir().join(format!(
        "rustcall_predicate_transfer_{}_{label}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    let input = dir.join("lib.rs");
    let text = match main {
        Some(main) => format!("#![allow(non_snake_case, unexpected_cfgs, dead_code)]\n{source}\nfn main() {{ {main} }}\n"),
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

const TRAITS: &str = r#"
    pub trait Tagged { type Tag; fn tag() -> i32; }
    impl Tagged for Buf { type Tag = i32; fn tag() -> i32 { 3 } }
    pub trait Rel<T> { type Out; fn rel(&self, other: T) -> i32; }
    // Only for a `'static` argument: a predicate naming it is the only proof a
    // call with a shorter `'a` is valid (PR #480 review).
    impl<'x> Rel<&'static Buf> for &'x Buf {
        type Out = i32;
        fn rel(&self, other: &'static Buf) -> i32 { self.n - other.n }
    }
    pub trait Any2<T> {}
    impl<A: ?Sized, B> Any2<B> for A {}
    macro_rules! same { ($t:ty) => { $t }; }
"#;

/// Every shape the issue lists that must compile, each in the impl block
/// (inherent, lifetime-generic, `where`-bounded, in another module) that
/// makes it one.
const CALLABLE: &str = r#"
    #[julia]
    pub struct Buf { pub n: i32 }

    impl Buf {
        pub fn new(n: i32) -> Self { Buf { n } }

        // Lifetime-only predicates: a parameter bound and a `where` clause.
        pub fn outlives<'a, 'b: 'a>(&self, x: &'a Buf, y: &'b Buf) -> i32 { x.n + y.n }
        pub fn outlives_where<'a, 'b>(&self, x: &'a Buf, y: &'b Buf) -> i32 where 'b: 'a { x.n - y.n }

        // Higher-ranked: a binder on the predicate, one nested in a bound, a
        // fn-pointer type and a trait-object type.
        pub fn hrtb<'a>(&self, o: &'a Buf) -> i32 where for<'b> &'b Buf: Rel<&'a Buf> { let _ = o; self.n }
        pub fn hrtb_nested<'a>(&self, o: &'a Buf) -> i32 where &'a Buf: for<'b> Any2<&'b Buf> { o.n }
        pub fn hrtb_fn_ptr<'a>(&self, o: &'a Buf) -> i32 where for<'b> fn(&'b Buf) -> &'a Buf: Copy { o.n }
        pub fn hrtb_dyn<'a>(&self, o: &'a Buf) -> i32 where &'a (dyn for<'b> Fn(&'b Buf) -> i32 + 'a): Copy { o.n }

        // `Self`: a trait bound, a qualified associated type bounded by a
        // declared lifetime, `Self` as the only proof, and `Self` in an
        // argument type.
        pub fn self_bound(&self) -> i32 where Self: Tagged { <Self as Tagged>::tag() + self.n }
        pub fn self_assoc<'a>(&self, o: &'a Buf) -> i32 where Self: Tagged, <Self as Tagged>::Tag: Copy + 'a { o.n + self.n }
        pub fn self_proof<'a>(&self, o: &'a Buf) -> i32 where for<'b> &'b Self: Rel<&'a Buf> { (&*self).rel(o) }
        pub fn self_proof_qualified<'a>(&self, o: &'a Buf) -> i32
        where
            for<'b> &'b Self: Rel<&'a Buf>,
            for<'b> <&'b Self as Rel<&'a Buf>>::Out: Copy,
        {
            (&*self).rel(o)
        }
        pub fn self_arg<'a>(&self, o: &'a Self) -> i32 where Self: Tagged { o.n * self.n }

        // No lifetimes at all.
        pub fn no_lifetimes(&self) -> i32 where Buf: Tagged, i32: Copy { self.n }

        // Declared and undeclared lifetimes mixed: `'c` is named only by the
        // predicate, or only by a lowered string that may shrink to the call.
        pub fn mixed<'a, 'c>(&self, o: &'a Buf) -> i32 where &'c Buf: Any2<&'a Buf> { o.n }
        pub fn mixed_string<'a, 'c>(&self, o: &'a Buf, s: &'c str) -> i32 where 'a: 'c { o.n + s.len() as i32 }
        pub fn mixed_string_shrinks<'a, 'c>(&self, o: &'a Buf, s: &'c str) -> i32 where 'c: 'a { o.n + s.len() as i32 }
        pub fn shared_string<'a>(&self, o: &'a Buf, s: &'a str) -> i32 { o.n + s.len() as i32 }

        // Gated away: the predicate names a trait that does not exist.
        #[cfg(rustcall_never)]
        pub fn gated<'a>(&self, o: &'a Buf) -> i32 where Self: Missing { o.n }
        #[cfg(rustcall_never)]
        pub fn gated_refusal(&self, s: &'static str) -> i32 { s.len() as i32 }
    }

    // The block's own lifetime parameter and `where` clause.
    impl<'x> Buf {
        pub fn block_lifetime(&self, o: &'x Buf) -> i32 { o.n + 100 }
    }
    impl Buf where Buf: Tagged {
        pub fn block_where(&self) -> i32 { self.n + 200 }
    }

    #[cfg(rustcall_never)]
    impl Buf {
        pub fn gated_block<'a>(&self, o: &'a Buf) -> i32 where Self: Missing { o.n }
    }

    // A block in another module, spelling the struct `super::Buf`.
    pub mod ops {
        use super::{Rel, Tagged};
        impl super::Buf {
            pub fn foreign<'a>(&self, o: &'a super::Buf) -> i32
            where
                Self: Tagged,
                for<'b> &'b Self: Rel<&'a super::Buf>,
            {
                (&*self).rel(o) + <Self as Tagged>::tag()
            }
        }
        impl<'x> super::Buf {
            pub fn foreign_block_lifetime(&self, o: &'x Self) -> i32 { o.n - self.n }
        }
    }

    #[julia]
    pub fn free_where<'a, 'b>(x: &'a Buf, y: &'b Buf) -> i32 where 'b: 'a { x.n * y.n }
    #[julia]
    pub fn free_hrtb<'a>(x: &'a Buf) -> i32 where for<'b> &'b Buf: Rel<&'a Buf> { x.n }
"#;

const CALLS: &str = r#"
    static OTHER: Buf = Buf { n: 1 };
    let o = Buf { n: 2 };
    let s = "four";
    unsafe {
        let p = rustcall_Buf_new(5);
        assert_eq!(rustcall_Buf_outlives(p, &o, &OTHER).assume_init(), 3);
        assert_eq!(rustcall_Buf_outlives_where(p, &o, &OTHER).assume_init(), 1);
        assert_eq!(rustcall_Buf_hrtb(p, &OTHER).assume_init(), 5);
        assert_eq!(rustcall_Buf_hrtb_nested(p, &o).assume_init(), 2);
        assert_eq!(rustcall_Buf_hrtb_fn_ptr(p, &o).assume_init(), 2);
        assert_eq!(rustcall_Buf_hrtb_dyn(p, &o).assume_init(), 2);
        assert_eq!(rustcall_Buf_self_bound(p).assume_init(), 8);
        assert_eq!(rustcall_Buf_self_assoc(p, &o).assume_init(), 7);
        assert_eq!(rustcall_Buf_self_proof(p, &OTHER).assume_init(), 4);
        assert_eq!(rustcall_Buf_self_proof_qualified(p, &OTHER).assume_init(), 4);
        assert_eq!(rustcall_Buf_self_arg(p, &o).assume_init(), 10);
        assert_eq!(rustcall_Buf_no_lifetimes(p).assume_init(), 5);
        assert_eq!(rustcall_Buf_mixed(p, &o).assume_init(), 2);
        assert_eq!(rustcall_Buf_mixed_string(p, &o, s.as_ptr(), s.len()).assume_init(), 6);
        assert_eq!(rustcall_Buf_mixed_string_shrinks(p, &o, s.as_ptr(), s.len()).assume_init(), 6);
        assert_eq!(rustcall_Buf_shared_string(p, &o, s.as_ptr(), s.len()).assume_init(), 6);
        assert_eq!(rustcall_Buf_block_lifetime(p, &o).assume_init(), 102);
        assert_eq!(rustcall_Buf_block_where(p).assume_init(), 205);
        assert_eq!(ops::rustcall_Buf_foreign(p, &OTHER).assume_init(), 7);
        assert_eq!(ops::rustcall_Buf_foreign_block_lifetime(p, &o).assume_init(), -3);
        assert_eq!(rustcall_free_where(&o, &OTHER).assume_init(), 2);
        assert_eq!(rustcall_free_hrtb(&OTHER).assume_init(), 1);
        Buf_free(p);
    }
"#;

/// The methods of [`CALLABLE`] Julia binds, in order, and their symbols: the
/// scheme of #279 / #300, unchanged by where the environment comes from.
const METHODS: &[&str] = &[
    "new",
    "outlives",
    "outlives_where",
    "hrtb",
    "hrtb_nested",
    "hrtb_fn_ptr",
    "hrtb_dyn",
    "self_bound",
    "self_assoc",
    "self_proof",
    "self_proof_qualified",
    "self_arg",
    "no_lifetimes",
    "mixed",
    "mixed_string",
    "mixed_string_shrinks",
    "shared_string",
    "gated",
    "gated_refusal",
    "block_lifetime",
    "block_where",
    "gated_block",
    "foreign",
    "foreign_block_lifetime",
];

#[test]
fn every_predicate_shape_compiles_and_is_called_through_its_wrapper() {
    let expanded = expand(&format!("{TRAITS}{CALLABLE}")).unwrap();
    let out = rustc("callable", &expanded.source, Some(CALLS));
    assert!(
        out.status.success(),
        "{}{}\n{}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout),
        expanded.source
    );
    // The same source as the `cdylib` `rust"""` builds.
    let out = rustc("callable_cdylib", &expanded.source, None);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    // Exported symbols are the scheme's, whatever the environment.
    let buf = &expanded.manifest.structs[0];
    let reported: Vec<(&str, &str)> = buf
        .methods
        .iter()
        .map(|m| (m.name.as_str(), m.symbol.as_str()))
        .collect();
    let expected: Vec<(&str, String)> = METHODS
        .iter()
        .map(|m| (*m, format!("rustcall_Buf_{m}")))
        .collect();
    assert_eq!(
        reported,
        expected
            .iter()
            .map(|(m, s)| (*m, s.as_str()))
            .collect::<Vec<_>>()
    );
    let functions: Vec<(&str, &str)> = expanded
        .manifest
        .functions
        .iter()
        .map(|f| (f.name.as_str(), f.symbol.as_str()))
        .collect();
    assert_eq!(
        functions,
        [
            ("free_where", "rustcall_free_where"),
            ("free_hrtb", "rustcall_free_hrtb")
        ]
    );
}

/// The environment is the item's, verbatim, `Self` spelled as the header —
/// no predicate is selected, rewritten or dropped.
#[test]
fn the_wrapper_declares_the_items_environment_verbatim() {
    let expanded = expand(&format!("{TRAITS}{CALLABLE}")).unwrap();
    let source = flat(&expanded.source);
    for sig in [
        "fn rustcall_Buf_outlives<'a, 'b: 'a>(ptr: *const Buf, x: &'a Buf, y: &'b Buf)",
        "fn rustcall_Buf_outlives_where<'a, 'b>(ptr: *const Buf, x: &'a Buf, y: &'b Buf) -> ::std::mem::MaybeUninit<i32> where 'b: 'a, {",
        "where for<'b> &'b Buf: Rel<&'a Buf>, {",
        "where &'a Buf: for<'b> Any2<&'b Buf>, {",
        "where for<'b> fn(&'b Buf) -> &'a Buf: Copy, {",
        "fn rustcall_Buf_self_bound(ptr: *const Buf) -> ::std::mem::MaybeUninit<i32> where Buf: Tagged, {",
        "where Buf: Tagged, <Buf as Tagged>::Tag: Copy + 'a, {",
        "where for<'b> &'b Buf: Rel<&'a Buf>, for<'b> <&'b Buf as Rel<&'a Buf>>::Out: Copy, {",
        "fn rustcall_Buf_self_arg<'a>(ptr: *const Buf, o: &'a Buf)",
        // `'c` is named only by the predicate: declared, early-bound.
        "fn rustcall_Buf_mixed<'a, 'c>(ptr: *const Buf, o: &'a Buf) -> ::std::mem::MaybeUninit<i32> where &'c Buf: Any2<&'a Buf>, {",
        // `'c` is named by a relation, so declared even though its string is
        // lowered; the call instantiates the method's own `'c`.
        "fn rustcall_Buf_mixed_string<'a, 'c>(ptr: *const Buf, o: &'a Buf, s_ptr: *const u8, s_len: usize) -> ::std::mem::MaybeUninit<i32> where 'a: 'c, {",
        // The block's generics join the method's.
        "fn rustcall_Buf_block_lifetime<'x>(ptr: *const Buf, o: &'x Buf)",
        "fn rustcall_Buf_block_where(ptr: *const Buf) -> ::std::mem::MaybeUninit<i32> where Buf: Tagged, {",
        // In another module, `Self` is the header as written.
        "where super::Buf: Tagged, for<'b> &'b super::Buf: Rel<&'a super::Buf>, {",
        "fn rustcall_Buf_foreign_block_lifetime<'x>(ptr: *const super::Buf, o: &'x super::Buf)",
    ] {
        assert!(source.contains(sig), "missing `{sig}`:\n{source}");
    }
    // A lifetime nothing on the wrapper names is not declared.
    assert!(
        source.contains("fn rustcall_Buf_shared_string<'a>(ptr: *const Buf, o: &'a Buf, s_ptr: *const u8, s_len: usize)"),
        "{source}"
    );
}

/// A lowered string argument lives only for the call: an item that needs its
/// lifetime to outlive the call is refused at the argument, with RustCall's
/// own message, before rustc looks at generated code.
#[test]
fn a_lowered_string_whose_lifetime_must_outlive_the_call_is_refused() {
    let cases: &[(&str, &str, &str)] = &[
        (
            "static",
            "pub fn a(&self, s: &'static str) -> i32 { s.len() as i32 }",
            "argument `s` arrives from Julia as a pointer and a length and is rebuilt into a string that lives only for the call, so it cannot be borrowed for `'static`",
        ),
        (
            "returned",
            "pub fn a<'a>(&'a self, s: &'a str) -> &'a i32 { let _ = s; &self.n }",
            "the wrapper returns `&'a i32`, which names it",
        ),
        (
            "invariant",
            "pub fn a<'a>(&self, o: &'a mut &'a Buf, s: &'a str) -> i32 { o.n + s.len() as i32 }",
            "argument `o: &'a mut &'a Buf` names it inside its type",
        ),
        (
            "through_a_bound",
            "pub fn a<'a, 'c: 'a>(&self, o: &'a mut &'a Buf, s: &'c str) -> i32 { o.n + s.len() as i32 }",
            "but it must outlive `'a` (`'c: 'a`), and argument `o: &'a mut &'a Buf` names it inside its type",
        ),
        (
            "through_a_predicate",
            "pub fn a<'a, 'c>(&self, s: &'c str) -> i32 where 'c: 'static { s.len() as i32 }",
            "but it must outlive `'static` (`'c: 'static`), and `'static` outlives every call",
        ),
        (
            "type_predicate",
            "pub fn a<'c>(&self, s: &'c str) -> i32 where &'c str: Any2<i32> { s.len() as i32 }",
            "the `where` predicate `&'c str: Any2<i32>` names it",
        ),
    ];
    for (label, method, message) in cases {
        let block = format!(
            "{TRAITS}
            #[julia]
            pub struct Buf {{ pub n: i32 }}
            impl Buf {{
                pub fn new(n: i32) -> Self {{ Buf {{ n }} }}
                {method}
            }}"
        );
        let expanded = expand(&block).unwrap();
        let out = rustc(label, &expanded.source, None);
        assert!(
            !out.status.success(),
            "{label} compiled:\n{}",
            expanded.source
        );
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(stderr.contains("`Buf::a`: "), "{label}: {stderr}");
        assert!(stderr.contains(message), "{label}: {stderr}");
        // Nothing but the refusal: no rustc error inside generated code.
        assert!(!stderr.contains("error["), "{label}: {stderr}");
    }
}

/// A `Self` inside a macro invocation is not a type until the macro runs, so
/// it cannot be spelled as the impl's type: refused at that token.
#[test]
fn a_self_inside_a_macro_is_refused() {
    let expanded = expand(&format!(
        "{TRAITS}
        #[julia]
        pub struct Buf {{ pub n: i32 }}
        impl Buf {{
            pub fn new(n: i32) -> Self {{ Buf {{ n }} }}
            pub fn a(&self) -> i32 where same!(Self): Tagged {{ self.n }}
        }}"
    ))
    .unwrap();
    let out = rustc("macro_self", &expanded.source, None);
    assert!(!out.status.success(), "{}", expanded.source);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("`Buf::a`: this `Self` is inside a macro invocation"),
        "{stderr}"
    );
    assert!(!stderr.contains("error["), "{stderr}");
}

/// A generic struct's method wrappers are generic free functions carrying the
/// block's and the method's generics; `Self` there is the block's type too
/// (E0411 before #482).
#[test]
fn a_generic_structs_wrappers_spell_self_as_the_block_type() {
    let expanded = expand(
        r#"
        #[julia]
        pub struct Wrap<T> { pub v: T }
        impl<'x, T: Copy> Wrap<T> {
            pub fn new(v: T) -> Self { Wrap { v } }
            pub fn get(&self) -> T where Self: Sized { self.v }
            pub fn other<'a>(&self, o: &'a Self) -> T where for<'b> &'b Self: Copy { o.v }
            pub fn block(&self, o: &'x Wrap<T>) -> T { o.v }
        }
    "#,
    )
    .unwrap();
    let source = flat(&expanded.source);
    assert!(source.contains("where Wrap<T>: Sized"), "{source}");
    assert!(
        source.contains("o: &'a Wrap<T>) -> T where for<'b> &'b Wrap<T>: Copy"),
        "{source}"
    );
    let out = rustc("generic", &expanded.source, None);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    let wrap = &expanded.manifest.structs[0];
    for method in ["get", "other", "block"] {
        let name = format!("Wrap_{method}");
        let wrapper = wrap
            .generic_wrappers
            .iter()
            .find(|w| w.name == name)
            .unwrap_or_else(|| panic!("no {name}"));
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
            "{}\n{}",
            String::from_utf8_lossy(&out.stderr),
            instance.source
        );
    }
}
