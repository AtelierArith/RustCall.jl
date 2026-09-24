//! One receiver model for every `#[julia]` method (#509).
//!
//! `rustcall_julia_core::receiver::Receiver::of` reads a method's receiver
//! from its syntax, and the wrapper's pointer (`*const` / `*mut`), its
//! `self_obj` binding, the first argument of its path call (`<Buf>::m(..)`,
//! `<Buf as tr::Forms>::m(..)`) and the manifest's `is_mutable` all come from
//! it — for an inherent and a trait impl's method alike, in both flavours.
//!
//! Every accepted form is compiled with a plain `rustc` and called through
//! its exported symbol: the proc-macro flavour for an inherent block and a
//! trait impl, the inline flavour for an inherent block and a generic
//! struct's wrappers. Every refused form — a type alias, a smart pointer, the
//! type spelled otherwise than the header — is in the manifest with
//! `receiver_type` and gets exactly one `compile_error!`.

use std::{fs, process::Command};

mod support;

use quote::quote;
use rustcall_julia_core::codegen::{transform_impl_crate, transform_struct_crate};
use rustcall_julia_core::expand::expand;
use rustcall_julia_core::extract::extract;
use rustcall_julia_core::manifest::{Manifest, Mode};

/// Every receiver form the wrapper passes, as `(method, receiver, mutable)`:
/// the method returns `self.n` after adding `by` where it can, so a call
/// through a mutable receiver is observed on the object.
const FORMS: &[(&str, &str, bool)] = &[
    ("shared", "&self", false),
    ("shared_named", "&'s self", false),
    ("exclusive", "&mut self", true),
    ("typed_shared", "self: &Self", false),
    ("typed_exclusive", "self: &mut Self", true),
    ("paren_exclusive", "self: (&mut Self)", true),
    ("own_shared", "self: &Buf", false),
    ("own_exclusive", "self: &mut Buf", true),
    ("shared_shared", "self: &&Self", false),
    ("exclusive_exclusive", "self: &mut &mut Self", true),
    ("exclusive_shared", "self: &mut &Self", false),
    ("shared_exclusive", "self: &&mut Self", true),
    ("value", "self", false),
    ("mut_value", "mut self", false),
    ("typed_value", "self: Self", false),
    ("own_value", "self: Buf", false),
];

/// Whether the method changes the object: through an exclusive borrow that no
/// shared one encloses (`self: &&mut Self` borrows mutably but cannot write).
fn mutates(receiver: &str, mutable: bool) -> bool {
    mutable && !receiver.contains("&&mut")
}

/// The body of a form: mutate where the receiver allows it, read otherwise.
fn body(receiver: &str, mutable: bool) -> &'static str {
    if mutates(receiver, mutable) {
        "{ self.n += by; self.n }"
    } else if receiver == "mut self" {
        // A by-value receiver works on a copy: the object is not changed.
        "{ self.n += by; self.n }"
    } else {
        "{ self.n + by }"
    }
}

fn methods(prefix: &str, vis: &str, attr: &str) -> String {
    FORMS
        .iter()
        .map(|(name, receiver, mutable)| {
            let generics = if receiver.contains("'s") { "<'s>" } else { "" };
            format!(
                "{attr} {vis} fn {prefix}{name}{generics}({receiver}, by: i32) -> i32 {}\n",
                body(receiver, *mutable)
            )
        })
        .collect()
}

fn trait_decl() -> String {
    let items: String = FORMS
        .iter()
        .map(|(name, receiver, _)| {
            // A declaration takes no pattern: `mut self` is the impl's own.
            let receiver = match *receiver {
                "mut self" => "self".to_string(),
                other => other.replace("Buf", "Self"),
            };
            let generics = if receiver.contains("'s") { "<'s>" } else { "" };
            format!("fn t_{name}{generics}({receiver}, by: i32) -> i32;\n")
        })
        .collect();
    format!("pub mod tr {{ pub trait Forms {{ {items} fn t_make() -> i32; }} }}")
}

/// `main`: call every form through its symbol and check what it returns and
/// what it leaves in the object.
fn calls(prefix: &str) -> String {
    let mut out = String::from("let mut b = Buf { n: 10 };\n");
    for (name, receiver, mutable) in FORMS {
        let symbol = format!("rustcall_Buf_{prefix}{name}");
        let pointer = if *mutable { "&mut b" } else { "&b" };
        if mutates(receiver, *mutable) {
            out.push_str(&format!(
                "let before = b.n; let got = unsafe {{ {symbol}({pointer}, 1).assume_init() }}; \
                 assert_eq!(got, before + 1, \"{symbol}\"); assert_eq!(b.n, before + 1, \"{symbol}\");\n"
            ));
        } else {
            out.push_str(&format!(
                "let before = b.n; let got = unsafe {{ {symbol}({pointer}, 1).assume_init() }}; \
                 assert_eq!(got, before + 1, \"{symbol}\"); assert_eq!(b.n, before, \"{symbol}\");\n"
            ));
        }
    }
    out
}

/// Compile `source` with a `main` into a binary, run it, and require success.
fn run(label: &str, source: &str, runtime: bool) {
    let dir =
        std::env::temp_dir().join(format!("rustcall_receivers_{}_{label}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let input = dir.join("probe.rs");
    let binary = dir.join(format!("probe{}", std::env::consts::EXE_SUFFIX));
    fs::write(
        &input,
        format!(
            "#![allow(non_snake_case, improper_ctypes_definitions, dead_code, unused_mut, clippy::all)]\n{source}"
        ),
    )
    .unwrap();
    let mut rustc = Command::new("rustc");
    rustc.args(["-C", "panic=unwind"]);
    if runtime {
        // The crate flavour names the runtime crate's boundary (#304).
        rustc
            .arg("--edition=2021")
            .arg("--extern")
            .arg(support::runtime_extern_arg(&dir));
    }
    let compile = rustc.arg(&input).arg("-o").arg(&binary).output().unwrap();
    assert!(
        compile.status.success(),
        "{label}: {}\n{source}",
        String::from_utf8_lossy(&compile.stderr)
    );
    let out = Command::new(&binary).output().unwrap();
    assert!(
        out.status.success(),
        "{label}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    fs::remove_dir_all(dir).unwrap();
}

fn transform(source: &str) -> String {
    let file: syn::File = syn::parse_str(source).unwrap();
    let mut out = proc_macro2::TokenStream::new();
    for item in file.items {
        out.extend(match item {
            syn::Item::Struct(mut s) if s.attrs.iter().any(|a| a.path().is_ident("julia")) => {
                s.attrs.retain(|a| !a.path().is_ident("julia"));
                transform_struct_crate(s, &[])
            }
            syn::Item::Impl(mut i) if i.attrs.iter().any(|a| a.path().is_ident("julia")) => {
                i.attrs.retain(|a| !a.path().is_ident("julia"));
                transform_impl_crate(i, &[])
            }
            other => quote!(#other),
        });
    }
    out.to_string()
}

const STRUCT: &str = "#[julia] #[derive(Clone, Copy)] pub struct Buf { pub n: i32 }";

fn method_mutability(manifest: &Manifest, name: &str) -> (bool, bool, String) {
    let m = manifest.structs[0]
        .methods
        .iter()
        .find(|m| m.name == name)
        .unwrap_or_else(|| panic!("no `{name}` in the manifest"));
    (m.is_static, m.is_mutable, m.skip_reason.clone())
}

#[test]
fn every_accepted_receiver_is_callable_in_the_crate_flavour() {
    // An inherent block and a trait impl, with every form and a static
    // method, through the proc macro.
    let source = format!(
        "{STRUCT}\n{}\n#[julia] impl Buf {{ {} #[julia] pub fn make() -> i32 {{ 7 }} }}\n\
         #[julia] impl tr::Forms for Buf {{ {} #[julia] fn t_make() -> i32 {{ 8 }} }}",
        trait_decl(),
        methods("", "pub", "#[julia]"),
        methods("t_", "", "#[julia]"),
    );
    let manifest = extract(&source, Mode::Crate).unwrap();
    for (name, _, mutable) in FORMS {
        assert_eq!(
            method_mutability(&manifest, name),
            (false, *mutable, String::new()),
            "{name}"
        );
    }
    assert_eq!(
        method_mutability(&manifest, "make"),
        (true, false, String::new())
    );
    let expansion = transform(&source);
    assert!(!expansion.contains("compile_error"), "{expansion}");
    let main = format!(
        "fn main() {{ {} {} \
         assert_eq!(unsafe {{ rustcall_Buf_make().assume_init() }}, 7); \
         assert_eq!(unsafe {{ rustcall_Buf_t_make().assume_init() }}, 8); }}",
        calls(""),
        calls("t_")
    );
    run("crate", &format!("{expansion}\n{main}"), true);
}

#[test]
fn every_accepted_receiver_is_callable_in_the_inline_flavour() {
    let source = format!(
        "{STRUCT}\nimpl Buf {{ {} pub fn make() -> i32 {{ 7 }} }}",
        methods("", "pub", "")
    );
    let expanded = expand(&source).unwrap();
    for (name, _, mutable) in FORMS {
        assert_eq!(
            method_mutability(&expanded.manifest, name),
            (false, *mutable, String::new()),
            "{name}"
        );
    }
    assert!(
        !expanded.source.contains("compile_error"),
        "{}",
        expanded.source
    );
    let main = format!(
        "fn main() {{ {} assert_eq!(unsafe {{ rustcall_Buf_make().assume_init() }}, 7); }}",
        calls("")
    );
    // A `rust"""` block is an edition-2015 crate with its own boundary.
    run("inline", &format!("{}\n{main}", expanded.source), false);
}

#[test]
fn a_generic_structs_wrappers_follow_the_same_model() {
    // A generic struct's wrappers are generic functions instantiated later by
    // `specialize`; here they are compiled as they are and called with `T`
    // inferred.
    let source = "#[julia] pub struct W<T> { pub v: T }
         impl<T: Copy + std::ops::AddAssign> W<T> {
             pub fn typed_exclusive(self: &mut Self, by: T) -> T { self.v += by; self.v }
             pub fn exclusive(&mut self, by: T) -> T { self.v += by; self.v }
             pub fn own_shared(self: &W<T>) -> T { self.v }
             pub fn shared_shared(self: &&Self) -> T { self.v }
             pub fn exclusive_shared(self: &mut &Self) -> T { self.v }
         }";
    let expanded = expand(source).unwrap();
    let s = &expanded.manifest.structs[0];
    let mutable: Vec<(&str, bool)> = s
        .methods
        .iter()
        .map(|m| (m.name.as_str(), m.is_mutable))
        .collect();
    assert_eq!(
        mutable,
        [
            ("typed_exclusive", true),
            ("exclusive", true),
            ("own_shared", false),
            ("shared_shared", false),
            ("exclusive_shared", false),
        ]
    );
    let wrappers: String = s
        .generic_wrappers
        .iter()
        .map(|w| w.source.clone())
        .collect::<Vec<_>>()
        .join("\n");
    let flat = wrappers.split_whitespace().collect::<Vec<_>>().join(" ");
    assert!(
        flat.contains("let self_obj = unsafe { &mut *ptr }; <W<T>>::typed_exclusive(self_obj, by)"),
        "{flat}"
    );
    assert!(flat.contains("<W<T>>::shared_shared(&self_obj)"), "{flat}");
    assert!(
        flat.contains(
            "let mut self_obj = unsafe { &*ptr }; <W<T>>::exclusive_shared(&mut self_obj)"
        ),
        "{flat}"
    );
    let main = "fn main() {
        let mut w = W { v: 1i32 };
        assert_eq!(W_typed_exclusive(&mut w, 2), 3);
        assert_eq!(W_exclusive(&mut w, 1), 4);
        assert_eq!(w.v, 4);
        assert_eq!(W_own_shared(&w), 4);
        assert_eq!(W_shared_shared(&w), 4);
        assert_eq!(W_exclusive_shared(&w), 4);
    }";
    run("generic", &format!("{}\n{main}", expanded.source), false);
}

/// Receivers the syntax cannot resolve, as `(method, receiver, detail)`.
const REFUSED: &[(&str, &str, &str)] = &[
    ("aliased", "self: Ref<'_, Self>", "Ref<'_, Self>"),
    ("boxed", "self: Box<Self>", "Box<Self>"),
    ("rc", "self: std::rc::Rc<Self>", "std::rc::Rc<Self>"),
    ("arc", "self: std::sync::Arc<Self>", "std::sync::Arc<Self>"),
    (
        "pinned",
        "self: std::pin::Pin<&mut Self>",
        "std::pin::Pin<&mut Self>",
    ),
    ("respelled", "self: &crate::Buf", "&crate::Buf"),
];

fn refused_methods(prefix: &str, vis: &str, attr: &str) -> String {
    REFUSED
        .iter()
        .map(|(name, receiver, _)| {
            format!("{attr} {vis} fn {prefix}{name}({receiver}) -> i32 {{ 0 }}\n")
        })
        .collect()
}

#[test]
fn every_refused_receiver_is_in_the_manifest_with_one_error() {
    let alias = "pub type Ref<'a, T> = &'a T;";
    let trait_items: String = REFUSED
        .iter()
        .map(|(name, receiver, _)| {
            format!(
                "fn t_{name}({}) -> i32;\n",
                receiver.replace("crate::Buf", "Self")
            )
        })
        .collect();
    let crate_source = format!(
        "{alias}\n{STRUCT}\npub mod tr {{ use super::Ref; pub trait Refused {{ {trait_items} }} }}\n\
         #[julia] impl Buf {{ {} }}\n#[julia] impl tr::Refused for Buf {{ {} }}",
        refused_methods("", "pub", "#[julia]"),
        refused_methods("t_", "", "#[julia]"),
    );
    let manifest = extract(&crate_source, Mode::Crate).unwrap();
    let expansion = transform(&crate_source);
    let inline_source = format!(
        "{alias}\n{STRUCT}\nimpl Buf {{ {} }}",
        refused_methods("", "pub", "")
    );
    let inline = expand(&inline_source).unwrap();
    for (label, manifest, expansion, prefixes) in [
        ("crate", &manifest, expansion, vec!["", "t_"]),
        ("inline", &inline.manifest, inline.source.clone(), vec![""]),
    ] {
        assert_eq!(
            expansion.matches("compile_error").count(),
            REFUSED.len() * prefixes.len(),
            "{label}: {expansion}"
        );
        for prefix in prefixes {
            for (name, _, detail) in REFUSED {
                let (is_static, is_mutable, reason) =
                    method_mutability(manifest, &format!("{prefix}{name}"));
                assert!(!is_static && !is_mutable, "{label} {name}");
                assert_eq!(reason, format!("receiver_type:{detail}"), "{label} {name}");
                assert!(
                    !expansion.contains(&format!("rustcall_Buf_{prefix}{name}")),
                    "{label}: {name} has a wrapper"
                );
            }
        }
    }
}
