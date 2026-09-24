//! Every refusal the `#[julia]` codegen makes reaches the manifest (#503).
//!
//! The decision is made once, in `rustcall_julia_core::refusal`, and both
//! outputs are derived from it: the expansion emits exactly one bare,
//! spanned, cfg-gated `compile_error!` for the item, and the manifest keeps
//! the item with the refusal as its `skip_reason`. This corpus walks every
//! refusal kind of `skip_reason::CODEGEN_REFUSALS` through every position it
//! can occur in — a free function, a method beside its struct, a method of a
//! generic struct, a method in a block in another module (inline), and the
//! crate flavour's function, method, struct, impl block, trait impl and
//! `#[julia] mod` — and asserts both halves. `test/test_boundary_report.jl`
//! runs the inline cases through `inline_boundary_report`.
//!
//! What no manifest entry can carry — `#[julia]` on a file module, on an impl
//! header that is not a type path, on an enum — fails the crate scan with the
//! refusal's own message instead.

use std::collections::BTreeSet;
use std::{fs, process::Command};

use proc_macro2::TokenStream;
use quote::quote;
use rustcall_julia_core::codegen::{
    transform_function, transform_impl_crate, transform_module, transform_struct_crate,
    transform_unsupported_item, PanicHook,
};
use rustcall_julia_core::expand::expand;
use rustcall_julia_core::extract::{extract, ExtractError};
use rustcall_julia_core::manifest::{skip_reason, Manifest, Mode};
use syn::Item;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Position {
    FreeFn,
    Method,
    GenericStructMethod,
    ForeignBlockMethod,
    Struct,
    ImplBlockMethod,
    TraitImplMethod,
    ModuleItem,
}

struct Case {
    label: &'static str,
    mode: Mode,
    position: Position,
    source: &'static str,
    /// `f`, `S`, `S::m`, or module-qualified (`a::f`, `a::S::m`).
    item: &'static str,
    /// The `skip_reason` the manifest carries, detail included.
    skip_reason: &'static str,
    /// The refusal text the expansion carries.
    message: &'static str,
    /// `compile_error!`s in the expansion: one for the item, and one more
    /// only where the refusal of an enclosing item covers this one (a generic
    /// crate struct and its generic impl block).
    refusals: usize,
}

fn cases() -> Vec<Case> {
    use Mode::{Crate, Inline};
    use Position::*;
    vec![
        // ---- unsafe_fn ------------------------------------------------------
        Case {
            label: "inline unsafe fn",
            mode: Inline,
            position: FreeFn,
            source: "#[julia] pub unsafe fn danger(p: *const i32) -> i32 { *p }",
            item: "danger",
            skip_reason: "unsafe_fn",
            message: "cannot be applied to unsafe functions directly",
            refusals: 1,
        },
        Case {
            label: "inline generic unsafe fn",
            mode: Inline,
            position: FreeFn,
            source: "#[julia] pub unsafe fn g<T: Copy>(x: T) -> T { x }",
            item: "g",
            skip_reason: "unsafe_fn",
            message: "cannot be applied to unsafe functions directly",
            refusals: 1,
        },
        Case {
            label: "inline unsafe method",
            mode: Inline,
            position: Method,
            source: "#[julia] pub struct S { pub n: i32 }
                     impl S { pub unsafe fn read(&self, p: *const i32) -> i32 { *p + self.n } }",
            item: "S::read",
            skip_reason: "unsafe_fn",
            message: "`S::read` is an `unsafe fn`",
            refusals: 1,
        },
        Case {
            label: "inline unsafe method of a generic struct",
            mode: Inline,
            position: GenericStructMethod,
            source: "#[julia] pub struct W<T> { pub v: T }
                     impl<T: Copy> W<T> { pub unsafe fn peek(&self, p: *const T) -> T { *p } }",
            item: "W::peek",
            skip_reason: "unsafe_fn",
            message: "`W::peek` is an `unsafe fn`",
            refusals: 1,
        },
        Case {
            label: "inline unsafe method in a foreign block",
            mode: Inline,
            position: ForeignBlockMethod,
            source: "#[julia] pub struct G { pub v: f64 }
                     pub mod ops { impl super::G { pub unsafe fn peek(&self, p: *const f64) -> f64 { *p } } }",
            item: "G::peek",
            skip_reason: "unsafe_fn",
            message: "`G::peek` is an `unsafe fn`",
            refusals: 1,
        },
        Case {
            label: "crate unsafe fn",
            mode: Crate,
            position: FreeFn,
            source: "#[julia] pub unsafe fn danger(p: *const i32) -> i32 { *p }",
            item: "danger",
            skip_reason: "unsafe_fn",
            message: "cannot be applied to unsafe functions directly",
            refusals: 1,
        },
        Case {
            label: "crate unsafe method",
            mode: Crate,
            position: ImplBlockMethod,
            source: "#[julia] pub struct S { pub n: i32 }
                     #[julia] impl S { #[julia] pub unsafe fn read(&self, p: *const i32) -> i32 { *p } }",
            item: "S::read",
            skip_reason: "unsafe_fn",
            message: "`S::read` is an `unsafe fn`",
            refusals: 1,
        },
        Case {
            label: "crate unsafe fn in a #[julia] mod",
            mode: Crate,
            position: ModuleItem,
            source: "#[julia] pub mod a { #[julia] pub unsafe fn danger(p: *const i32) -> i32 { *p } }",
            item: "a::danger",
            skip_reason: "unsafe_fn",
            message: "cannot be applied to unsafe functions directly",
            refusals: 1,
        },
        // ---- generic_signature ----------------------------------------------
        Case {
            label: "inline const-generic fn",
            mode: Inline,
            position: FreeFn,
            source: "#[julia] pub fn sized<const N: usize>() -> usize { N }",
            item: "sized",
            skip_reason: "generic_signature:const N",
            message: "const generics are not supported",
            refusals: 1,
        },
        Case {
            label: "inline generic method of a concrete struct",
            mode: Inline,
            position: Method,
            source: "#[julia] pub struct S { pub n: i32 }
                     impl S { pub fn echo<T: Copy>(&self, x: T) -> T { x } }",
            item: "S::echo",
            skip_reason: "generic_signature:T",
            message: "`S::echo` is generic over `T`",
            refusals: 1,
        },
        Case {
            label: "inline method-level generic of a generic struct",
            mode: Inline,
            position: GenericStructMethod,
            source: "#[julia] pub struct W<T> { pub v: T }
                     impl<T: Copy> W<T> { pub fn pair<U: Copy>(&self, u: U) -> U { u } }",
            item: "W::pair",
            skip_reason: "generic_signature:U",
            message: "`W::pair` is generic over `U`",
            refusals: 1,
        },
        Case {
            label: "inline generic method in a foreign block",
            mode: Inline,
            position: ForeignBlockMethod,
            source: "#[julia] pub struct G { pub v: f64 }
                     pub mod ops { impl super::G { pub fn scaled<T: Into<f64>>(&self, k: T) -> f64 { self.v * k.into() } } }",
            item: "G::scaled",
            skip_reason: "generic_signature:T",
            message: "`G::scaled` is generic over `T`",
            refusals: 1,
        },
        Case {
            label: "crate generic fn",
            mode: Crate,
            position: FreeFn,
            source: "#[julia] pub fn id<T: Copy>(x: T) -> T { x }",
            item: "id",
            skip_reason: "generic_signature:T",
            message: "#[julia] function `id` is generic over `T`",
            refusals: 1,
        },
        Case {
            label: "crate generic method",
            mode: Crate,
            position: ImplBlockMethod,
            source: "#[julia] pub struct S { pub n: i32 }
                     #[julia] impl S { #[julia] pub fn echo<U: Copy>(&self, u: U) -> U { u } }",
            item: "S::echo",
            skip_reason: "generic_signature:U",
            message: "#[julia] method `echo` is generic over `U`",
            refusals: 1,
        },
        Case {
            label: "crate generic struct",
            mode: Crate,
            position: Struct,
            source: "#[julia] pub struct W<T> { pub v: T }",
            item: "W",
            skip_reason: "generic_signature:T",
            message: "#[julia] struct `W` is generic over `T`",
            refusals: 1,
        },
        Case {
            label: "crate generic impl block",
            mode: Crate,
            position: ImplBlockMethod,
            source: "#[julia] pub struct W<T> { pub v: T }
                     #[julia] impl<T: Copy> W<T> { #[julia] pub fn get(&self) -> T { self.v } }",
            item: "W::get",
            skip_reason: "generic_signature:T",
            message: "#[julia] impl block for `W` is generic over `T`",
            // The struct's refusal and the block's, which covers `get`.
            refusals: 2,
        },
        // ---- impl_trait -----------------------------------------------------
        Case {
            label: "inline impl Trait fn",
            mode: Inline,
            position: FreeFn,
            source: "#[julia] pub fn shown(x: impl Copy) -> i32 { let _ = x; 1 }",
            item: "shown",
            skip_reason: "impl_trait",
            message: "`impl Trait` is not supported",
            refusals: 1,
        },
        Case {
            label: "inline impl Trait method",
            mode: Inline,
            position: Method,
            source: "#[julia] pub struct S { pub n: i32 }
                     impl S { pub fn shown(&self, x: impl Copy) -> i32 { let _ = x; self.n } }",
            item: "S::shown",
            skip_reason: "impl_trait",
            message: "`S::shown` uses `impl Trait`",
            refusals: 1,
        },
        Case {
            label: "inline impl Trait method of a generic struct",
            mode: Inline,
            position: GenericStructMethod,
            source: "#[julia] pub struct W<T> { pub v: T }
                     impl<T: Copy> W<T> { pub fn shown(&self, x: impl Copy) -> T { let _ = x; self.v } }",
            item: "W::shown",
            skip_reason: "impl_trait",
            message: "`W::shown` uses `impl Trait`",
            refusals: 1,
        },
        Case {
            label: "inline impl Trait method in a foreign block",
            mode: Inline,
            position: ForeignBlockMethod,
            source: "#[julia] pub struct G { pub v: f64 }
                     pub mod ops { impl super::G { pub fn shown(&self, x: impl Copy) -> f64 { let _ = x; self.v } } }",
            item: "G::shown",
            skip_reason: "impl_trait",
            message: "`G::shown` uses `impl Trait`",
            refusals: 1,
        },
        Case {
            label: "crate impl Trait fn",
            mode: Crate,
            position: FreeFn,
            source: "#[julia] pub fn shown(x: impl Copy) -> i32 { let _ = x; 1 }",
            item: "shown",
            skip_reason: "impl_trait",
            message: "uses `impl Trait` in its signature",
            refusals: 1,
        },
        Case {
            label: "crate impl Trait method",
            mode: Crate,
            position: ImplBlockMethod,
            source: "#[julia] pub struct S { pub n: i32 }
                     #[julia] impl S { #[julia] pub fn shown(&self, x: impl Copy) -> i32 { let _ = x; self.n } }",
            item: "S::shown",
            skip_reason: "impl_trait",
            message: "#[julia] method `shown` uses `impl Trait`",
            refusals: 1,
        },
        // ---- non_ffi_payload ------------------------------------------------
        Case {
            label: "inline non-FFI Result payload",
            mode: Inline,
            position: FreeFn,
            source: "#[julia] pub fn many(a: i32) -> Result<Vec<i32>, i32> { Ok(vec![a]) }",
            item: "many",
            skip_reason: "non_ffi_payload:Vec<i32>",
            message: "returns Result with non-FFI-compatible Ok type `Vec<i32>`",
            refusals: 1,
        },
        Case {
            label: "crate non-FFI Option payload",
            mode: Crate,
            position: FreeFn,
            source: "#[julia] pub fn maybe(a: i32) -> Option<Vec<i32>> { Some(vec![a]) }",
            item: "maybe",
            skip_reason: "non_ffi_payload:Vec<i32>",
            message: "returns Option with non-FFI-compatible type `Vec<i32>`",
            refusals: 1,
        },
        Case {
            label: "crate non-FFI payload in a #[julia] mod",
            mode: Crate,
            position: ModuleItem,
            source: "#[julia] pub mod a { #[julia] pub fn many(a: i32) -> Result<i32, Vec<u8>> { Ok(a) } }",
            item: "a::many",
            skip_reason: "non_ffi_payload:Vec<u8>",
            message: "returns Result with non-FFI-compatible Err type `Vec<u8>`",
            refusals: 1,
        },
        // ---- self_trait_path ------------------------------------------------
        Case {
            label: "crate trait-path Self::N in a trait impl",
            mode: Crate,
            position: TraitImplMethod,
            source: "pub mod tr { pub trait Limits { const N: usize; fn limit(&self, a: &[u8; 2]) -> i32; } }
                     #[julia] pub struct Buf { pub n: i32 }
                     #[julia] impl tr::Limits for Buf {
                         const N: usize = 2;
                         #[julia] fn limit(&self, a: &[u8; Self::N]) -> i32 { a.len() as i32 + self.n }
                     }",
            item: "Buf::limit",
            skip_reason: "self_trait_path:tr::Limits",
            message: "an unqualified `Self::…` constant here",
            refusals: 1,
        },
        // ---- receiver_type ------------------------------------------------
        // A receiver the wrapper cannot pass (#509): the same refusal for an
        // inherent and a trait impl's method, in both flavours.
        Case {
            label: "inline method with a smart-pointer receiver",
            mode: Inline,
            position: Method,
            source: "#[julia] pub struct S { pub n: i32 }
                     impl S { pub fn boxed(self: Box<Self>) -> i32 { self.n } }",
            item: "S::boxed",
            skip_reason: "receiver_type:Box<Self>",
            message: "this receiver type does not show its shape",
            refusals: 1,
        },
        Case {
            label: "inline generic-struct method with an aliased receiver",
            mode: Inline,
            position: GenericStructMethod,
            source: "pub type Ref<'a, T> = &'a T;
                     #[julia] pub struct W<T> { pub v: T }
                     impl<T: Copy> W<T> { pub fn get(self: Ref<'_, Self>) -> T { self.v } }",
            item: "W::get",
            skip_reason: "receiver_type:Ref<'_, Self>",
            message: "this receiver type does not show its shape",
            refusals: 1,
        },
        Case {
            label: "inline foreign-block method with an Rc receiver",
            mode: Inline,
            position: ForeignBlockMethod,
            source: "#[julia] pub struct S { pub n: i32 }
                     mod ops { impl super::S { pub fn rc(self: std::rc::Rc<Self>) -> i32 { self.n } } }",
            item: "S::rc",
            skip_reason: "receiver_type:std::rc::Rc<Self>",
            message: "this receiver type does not show its shape",
            refusals: 1,
        },
        Case {
            label: "crate impl-block method with an aliased receiver",
            mode: Crate,
            position: ImplBlockMethod,
            source: "pub type Ref<'a, T> = &'a T;
                     #[julia] pub struct Buf { pub n: i32 }
                     #[julia] impl Buf { #[julia] pub fn get(self: Ref<'_, Self>) -> i32 { self.n } }",
            item: "Buf::get",
            skip_reason: "receiver_type:Ref<'_, Self>",
            message: "this receiver type does not show its shape",
            refusals: 1,
        },
        Case {
            label: "crate trait method with a smart-pointer receiver",
            mode: Crate,
            position: TraitImplMethod,
            source: "pub trait Take { fn take(self: Box<Self>) -> i32; }
                     #[julia] pub struct Buf { pub n: i32 }
                     #[julia] impl Take for Buf { #[julia] fn take(self: Box<Self>) -> i32 { self.n } }",
            item: "Buf::take",
            skip_reason: "receiver_type:Box<Self>",
            message: "this receiver type does not show its shape",
            refusals: 1,
        },
        Case {
            label: "crate module-item method with a pinned receiver",
            mode: Crate,
            position: ModuleItem,
            source: "#[julia] pub mod a {
                         #[julia] pub struct Buf { pub n: i32 }
                         #[julia] impl Buf {
                             #[julia] pub fn pinned(self: std::pin::Pin<&mut Self>) -> i32 { self.n }
                         }
                     }",
            item: "a::Buf::pinned",
            skip_reason: "receiver_type:std::pin::Pin<&mut Self>",
            message: "this receiver type does not show its shape",
            refusals: 1,
        },
        // ---- unspellable_self -----------------------------------------------
        Case {
            label: "inline Self inside a macro",
            mode: Inline,
            position: Method,
            source: "macro_rules! same { ($t:ty) => { $t }; }
                     #[julia] pub struct S { pub n: i32 }
                     impl S { pub fn other(&self, o: &same!(Self)) -> i32 { o.n + self.n } }",
            item: "S::other",
            skip_reason: "unspellable_self:same!",
            message: "this `Self` is inside an invocation of `same!`",
            refusals: 1,
        },
        Case {
            label: "inline Self inside a macro in a foreign block",
            mode: Inline,
            position: ForeignBlockMethod,
            source: "macro_rules! same { ($t:ty) => { $t }; }
                     #[julia] pub struct G { pub v: f64 }
                     pub mod ops { impl super::G { pub fn other(&self, o: &same!(Self)) -> f64 { o.v } } }",
            item: "G::other",
            skip_reason: "unspellable_self:same!",
            message: "this `Self` is inside an invocation of `same!`",
            refusals: 1,
        },
        Case {
            label: "crate Self inside a macro",
            mode: Crate,
            position: ImplBlockMethod,
            source: "macro_rules! same { ($t:ty) => { $t }; }
                     #[julia] pub struct S { pub n: i32 }
                     #[julia] impl S { #[julia] pub fn other(&self, o: &same!(Self)) -> i32 { o.n } }",
            item: "S::other",
            skip_reason: "unspellable_self:same!",
            message: "this `Self` is inside an invocation of `same!`",
            refusals: 1,
        },
        // ---- lowered_str_lifetime -------------------------------------------
        Case {
            label: "inline 'static lowered str",
            mode: Inline,
            position: FreeFn,
            source: "#[julia] pub fn keep(s: &'static str) -> usize { s.len() }",
            item: "keep",
            skip_reason: "lowered_str_lifetime:s",
            message: "cannot be borrowed for `'static`",
            refusals: 1,
        },
        Case {
            label: "inline returned lowered str lifetime",
            mode: Inline,
            position: Method,
            source: "#[julia] pub struct S { pub n: i32 }
                     impl S { pub fn first<'a>(&self, s: &'a str) -> &'a u8 { &s.as_bytes()[0] } }",
            item: "S::first",
            skip_reason: "lowered_str_lifetime:s",
            message: "`'a` cannot be required to outlive the call",
            refusals: 1,
        },
        Case {
            label: "inline lowered str lifetime in a foreign block",
            mode: Inline,
            position: ForeignBlockMethod,
            source: "#[julia] pub struct G { pub v: f64 }
                     pub mod ops { impl super::G { pub fn keep(&self, s: &'static str) -> usize { s.len() } } }",
            item: "G::keep",
            skip_reason: "lowered_str_lifetime:s",
            message: "cannot be borrowed for `'static`",
            refusals: 1,
        },
        Case {
            label: "crate lowered str lifetime",
            mode: Crate,
            position: FreeFn,
            source: "#[julia] pub fn keep(s: &'static str) -> usize { s.len() }",
            item: "keep",
            skip_reason: "lowered_str_lifetime:s",
            message: "cannot be borrowed for `'static`",
            refusals: 1,
        },
        Case {
            label: "crate lowered str lifetime of a method",
            mode: Crate,
            position: ImplBlockMethod,
            source: "#[julia] pub struct S { pub n: i32 }
                     #[julia] impl S { #[julia] pub fn keep(&self, s: &'static str) -> usize { s.len() } }",
            item: "S::keep",
            skip_reason: "lowered_str_lifetime:s",
            message: "cannot be borrowed for `'static`",
            refusals: 1,
        },
        // ---- lowered_str_borrow ---------------------------------------------
        Case {
            label: "inline elided return borrowing a lowered str",
            mode: Inline,
            position: FreeFn,
            source: "#[julia] pub fn first(s: &str) -> &u8 { &s.as_bytes()[0] }",
            item: "first",
            skip_reason: "lowered_str_borrow:s",
            message: "borrows from argument `s` by lifetime elision",
            refusals: 1,
        },
        Case {
            label: "inline static method borrowing a lowered str",
            mode: Inline,
            position: Method,
            source: "#[julia] pub struct S { pub n: i32 }
                     impl S { pub fn first(s: &str) -> &u8 { &s.as_bytes()[0] } }",
            item: "S::first",
            skip_reason: "lowered_str_borrow:s",
            message: "borrows from argument `s` by lifetime elision",
            refusals: 1,
        },
        Case {
            label: "inline foreign-block method borrowing a lowered str",
            mode: Inline,
            position: ForeignBlockMethod,
            source: "#[julia] pub struct G { pub v: f64 }
                     pub mod ops { impl super::G { pub fn first(s: &str) -> &u8 { &s.as_bytes()[0] } } }",
            item: "G::first",
            skip_reason: "lowered_str_borrow:s",
            message: "borrows from argument `s` by lifetime elision",
            refusals: 1,
        },
        Case {
            label: "crate elided return borrowing a lowered str",
            mode: Crate,
            position: FreeFn,
            source: "#[julia] pub fn first(s: &str) -> &u8 { &s.as_bytes()[0] }",
            item: "first",
            skip_reason: "lowered_str_borrow:s",
            message: "borrows from argument `s` by lifetime elision",
            refusals: 1,
        },
        Case {
            label: "crate method borrowing a lowered str in a #[julia] mod",
            mode: Crate,
            position: ModuleItem,
            source: "#[julia] pub mod a {
                         #[julia] pub struct S { pub n: i32 }
                         #[julia] impl S { #[julia] pub fn first(s: &str) -> &u8 { &s.as_bytes()[0] } }
                     }",
            item: "a::S::first",
            skip_reason: "lowered_str_borrow:s",
            message: "borrows from argument `s` by lifetime elision",
            refusals: 1,
        },
    ]
}

/// What the proc macro emits for a file: every top-level item carrying
/// `#[julia]` expanded as `rustcall_julia_macros_impl::julia` expands it.
fn crate_expansion(source: &str) -> TokenStream {
    let file: syn::File = syn::parse_str(source).unwrap();
    let mut out = TokenStream::new();
    let marked = |attrs: &[syn::Attribute]| attrs.iter().any(|a| a.path().is_ident("julia"));
    let strip = |attrs: &mut Vec<syn::Attribute>| attrs.retain(|a| !a.path().is_ident("julia"));
    for item in file.items {
        out.extend(match item {
            Item::Fn(mut f) if marked(&f.attrs) => {
                strip(&mut f.attrs);
                transform_function(f, &[], PanicHook::Runtime)
            }
            Item::Struct(mut s) if marked(&s.attrs) => {
                strip(&mut s.attrs);
                transform_struct_crate(s, &[])
            }
            Item::Impl(mut i) if marked(&i.attrs) => {
                strip(&mut i.attrs);
                transform_impl_crate(i, &[])
            }
            Item::Mod(mut m) if marked(&m.attrs) => {
                strip(&mut m.attrs);
                transform_module(m, &[])
            }
            // Any other kind: the proc macro is handed the item without its
            // `#[julia]` and cannot parse it as one of the four it expands.
            other if julia_attributed(&other) => {
                transform_unsupported_item(proc_macro_input(other))
            }
            other => quote!(#other),
        });
    }
    out
}

/// Whether any item — a `Verbatim` one included — carries `#[julia]`, read
/// the way the compiler does: from its tokens.
fn julia_attributed(item: &Item) -> bool {
    flat(&quote!(#item).to_string()).starts_with("# [julia]")
        || flat(&quote!(#item).to_string()).contains("] # [julia]")
}

/// The tokens the `#[julia]` proc macro is handed for `item`: the item with
/// that attribute removed.
fn proc_macro_input(item: Item) -> TokenStream {
    let text = quote!(#item).to_string().replacen("# [julia]", "", 1);
    text.parse().unwrap()
}

/// The manifest entry's `skip_reason` for `item`.
fn skip_reason_of(manifest: &Manifest, item: &str) -> Option<String> {
    let mut path: Vec<&str> = item.split("::").collect();
    let module_of = |len: usize, path: &[&str]| -> Vec<String> {
        path[..len].iter().map(|s| s.to_string()).collect()
    };
    let name = path.pop().unwrap();
    // `f` / `a::f`, or `S` / `a::S`.
    if let Some(f) = manifest
        .functions
        .iter()
        .find(|f| f.name == name && f.module_path == module_of(path.len(), &path))
    {
        return Some(f.skip_reason.clone());
    }
    if let Some(s) = manifest
        .structs
        .iter()
        .find(|s| s.name == name && s.module_path == module_of(path.len(), &path))
    {
        return Some(s.skip_reason.clone());
    }
    // `S::m` / `a::S::m`.
    let owner = path.pop()?;
    let s = manifest
        .structs
        .iter()
        .find(|s| s.name == owner && s.module_path == module_of(path.len(), &path))?;
    s.methods
        .iter()
        .find(|m| m.name == name)
        .map(|m| m.skip_reason.clone())
}

fn flat(source: &str) -> String {
    source.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[test]
fn every_refusal_is_in_the_manifest_and_emitted_once() {
    for case in cases() {
        let label = case.label;
        let (manifest, expansion) = match case.mode {
            Mode::Inline => {
                let expanded = expand(case.source)
                    .unwrap_or_else(|e| panic!("{label}: expansion failed: {e}"));
                (expanded.manifest, expanded.source)
            }
            Mode::Crate => (
                extract(case.source, Mode::Crate)
                    .unwrap_or_else(|e| panic!("{label}: crate scan failed: {e}")),
                crate_expansion(case.source).to_string(),
            ),
        };
        let reason = skip_reason_of(&manifest, case.item)
            .unwrap_or_else(|| panic!("{label}: `{}` is not in the manifest", case.item));
        assert_eq!(reason, case.skip_reason, "{label}");
        assert!(
            skip_reason::is_codegen_refusal(&reason),
            "{label}: `{reason}` is not a codegen refusal"
        );
        assert_eq!(
            expansion.matches("compile_error").count(),
            case.refusals,
            "{label}: {expansion}"
        );
        assert!(
            flat(&expansion).contains(case.message),
            "{label}: no `{}` in {expansion}",
            case.message
        );
    }
}

/// The corpus is exhaustive: every kind of `CODEGEN_REFUSALS` in both
/// flavours where the flavour can produce it, and every position.
#[test]
fn the_corpus_covers_every_refusal_and_position() {
    let cases = cases();
    for kind in skip_reason::CODEGEN_REFUSALS {
        for mode in [Mode::Inline, Mode::Crate] {
            // A trait impl is wrapped by the proc macro alone, and a non-FFI
            // payload refused for a free function only (a method returns
            // such a `Result` as written).
            if *kind == skip_reason::SELF_TRAIT_PATH && mode == Mode::Inline {
                continue;
            }
            assert!(
                cases
                    .iter()
                    .any(|c| c.mode == mode && c.skip_reason.split(':').next() == Some(kind)),
                "no {mode:?} case for `{kind}`"
            );
        }
    }
    let positions: BTreeSet<(bool, Position)> = cases
        .iter()
        .map(|c| (c.mode == Mode::Crate, c.position))
        .collect();
    use Position::*;
    for want in [
        (Mode::Inline, FreeFn),
        (Mode::Inline, Method),
        (Mode::Inline, GenericStructMethod),
        (Mode::Inline, ForeignBlockMethod),
        (Mode::Crate, FreeFn),
        (Mode::Crate, Struct),
        (Mode::Crate, ImplBlockMethod),
        (Mode::Crate, TraitImplMethod),
        (Mode::Crate, ModuleItem),
    ] {
        assert!(
            positions.contains(&(want.0 == Mode::Crate, want.1)),
            "no case at {want:?}"
        );
    }
}

/// A refused item defines no symbol: it is not exported and claims nothing, so
/// the collision checks of #300 / #338 do not count it (#491 review, #503).
#[test]
fn a_refused_item_claims_no_symbol() {
    for case in cases() {
        let manifest = match case.mode {
            Mode::Inline => expand(case.source).unwrap().manifest,
            Mode::Crate => extract(case.source, Mode::Crate).unwrap(),
        };
        for f in &manifest.functions {
            if skip_reason::is_codegen_refusal(&f.skip_reason) {
                assert!(!f.exported, "{}: {} is exported", case.label, f.name);
                assert!(f.claims().is_empty(), "{}: {} claims", case.label, f.name);
            }
        }
        for s in &manifest.structs {
            let refused: Vec<&str> = s
                .methods
                .iter()
                .filter(|m| skip_reason::is_codegen_refusal(&m.skip_reason))
                .map(|m| m.symbol.as_str())
                .collect();
            for (claim, _) in s.claims() {
                assert!(
                    !refused
                        .iter()
                        .any(|symbol| claim.name.starts_with(symbol) && !symbol.is_empty()),
                    "{}: `{}` is claimed for a refused method",
                    case.label,
                    claim.name
                );
            }
        }
    }
}

/// What no manifest entry can carry fails the crate scan with the refusal's
/// own message, and the proc macro emits that refusal once.
#[test]
fn a_refused_container_fails_the_crate_scan() {
    for (label, source, message) in [(
        "file module",
        "#[julia] pub mod a;",
        "#[julia] on a file module (`mod name;`) is not supported",
    )]
    .into_iter()
    .chain(unsupported_kinds().into_iter().map(|(label, source, _)| {
        (
            label,
            source,
            "#[julia] can only be applied to functions, structs, impl blocks, or inline modules",
        )
    })) {
        let err = extract(source, Mode::Crate).unwrap_err();
        assert!(matches!(err, ExtractError::Unsupported(_)), "{label}");
        assert!(err.to_string().contains(message), "{label}: {err}");
        let expansion = crate_expansion(source).to_string();
        assert_eq!(
            expansion.matches("compile_error").count(),
            1,
            "{label}: {expansion}"
        );
        assert!(flat(&expansion).contains(message), "{label}: {expansion}");
    }
    // A header that is not a type path: nothing to resolve, the block refused.
    let source = "#[julia] impl [u8; 2] { #[julia] pub fn f(&self) -> u8 { self[0] } }";
    let err = extract(source, Mode::Crate).unwrap_err();
    assert!(
        err.to_string().contains("requires a simple type path"),
        "{err}"
    );
    let expansion = crate_expansion(source).to_string();
    assert_eq!(expansion.matches("compile_error").count(), 1, "{expansion}");
}

/// `#[julia]` on every item kind it does not expand — each `syn::Item`
/// variant other than a function, a struct, an impl block and a module, and
/// tokens syn keeps as `Item::Verbatim` — with the description the refusal
/// names it by (#503 review).
fn unsupported_kinds() -> Vec<(&'static str, &'static str, &'static str)> {
    vec![
        ("const", "#[julia] pub const K: i32 = 1;", "const `K`"),
        ("enum", "#[julia] pub enum E { A }", "enum `E`"),
        (
            "extern crate",
            "#[julia] extern crate core;",
            "extern crate `core`",
        ),
        (
            "extern block",
            "#[julia] extern \"C\" { fn abs(x: i32) -> i32; }",
            "an `extern` block",
        ),
        (
            "macro_rules!",
            "#[julia] macro_rules! foo { () => {}; }",
            "macro_rules! `foo`",
        ),
        (
            "macro invocation",
            "#[julia] thread_local! { static X: i32 = 1; }",
            "a macro invocation",
        ),
        ("static", "#[julia] pub static S: i32 = 1;", "static `S`"),
        (
            "trait",
            "#[julia] pub trait T { fn f(&self); }",
            "trait `T`",
        ),
        (
            "trait alias",
            "#[julia] pub trait A = Clone;",
            "trait alias `A`",
        ),
        (
            "type alias",
            "#[julia] pub type Id = i32;",
            "type alias `Id`",
        ),
        (
            "union",
            "#[julia] pub union U { a: u32, b: f32 }",
            "union `U`",
        ),
        ("use", "#[julia] pub use std::mem;", "a `use` declaration"),
        // A free function with no body is an item syn does not parse into a
        // kind (`Item::Verbatim`).
        ("verbatim", "#[julia] pub fn declared();", "an item"),
    ]
}

/// Every unsupported kind is refused by one predicate in every place that
/// meets it: the crate scan fails, the proc macro emits one refusal, a
/// `#[julia] mod` body emits one, and a `rust"""` block fails to expand.
#[test]
fn every_unsupported_item_kind_is_refused_everywhere() {
    use rustcall_julia_core::refusal::{julia_item_refusal, unsupported_item_kind};
    let message =
        "#[julia] can only be applied to functions, structs, impl blocks, or inline modules";
    for (label, source, what) in unsupported_kinds() {
        let item: Item = syn::parse_str(source).unwrap();
        assert_eq!(
            unsupported_item_kind(&item).as_deref(),
            Some(what),
            "{label}"
        );
        assert!(julia_item_refusal(&item).is_some(), "{label}");

        let err = extract(source, Mode::Crate).unwrap_err().to_string();
        assert!(
            err.contains(message) && err.contains(what),
            "{label}: {err}"
        );

        let marked = format!("#[julia] pub mod m {{ {source} }}");
        let err = extract(&marked, Mode::Crate).unwrap_err().to_string();
        assert!(err.contains(what), "{label}: {err}");
        let module: syn::ItemMod = syn::parse_str(&marked.replacen("#[julia] ", "", 1)).unwrap();
        let expansion = transform_module(module, &[]).to_string();
        assert_eq!(
            expansion.matches("compile_error").count(),
            1,
            "{label}: {expansion}"
        );

        let err = expand(source)
            .err()
            .unwrap_or_else(|| panic!("{label}: expanded"));
        assert!(err.to_string().contains(what), "{label}: {err}");
    }
    // The same kinds without `#[julia]` are ordinary code.
    for (label, source, _) in unsupported_kinds() {
        let plain = source.replacen("#[julia] ", "", 1);
        let item: Item = syn::parse_str(&plain).unwrap();
        assert!(julia_item_refusal(&item).is_none(), "{label}");
    }
}

/// Refusals are cfg-gated like the item: a configured-away item compiles.
#[test]
fn the_refusal_carries_the_items_cfg() {
    let expanded =
        expand("#[julia] #[cfg(rustcall_never)] pub fn first(s: &str) -> &u8 { &s.as_bytes()[0] }")
            .unwrap();
    let source = flat(&expanded.source);
    assert!(
        source.contains("#[cfg(rustcall_never)] compile_error!"),
        "{source}"
    );
    let crate_side = crate_expansion(
        "#[julia] #[cfg(rustcall_never)] pub fn keep(s: &'static str) -> usize { s.len() }",
    )
    .to_string();
    assert!(
        flat(&crate_side).contains("# [cfg (rustcall_never)] compile_error !"),
        "{crate_side}"
    );
}

/// rustc agrees: an inline block with one refused item stops at exactly that
/// refusal — the item is kept as written, so nothing cascades from it.
#[test]
fn rustc_reports_exactly_the_refusal() {
    if Command::new("rustc").arg("--version").output().is_err() {
        return;
    }
    let dir = std::env::temp_dir().join(format!("rustcall_refusals_{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    for (i, case) in cases()
        .into_iter()
        .filter(|c| c.mode == Mode::Inline)
        .enumerate()
    {
        let expanded = expand(case.source).unwrap();
        let input = dir.join(format!("case{i}.rs"));
        fs::write(
            &input,
            format!(
                "#![allow(non_snake_case, unexpected_cfgs, dead_code)]\n{}",
                expanded.source
            ),
        )
        .unwrap();
        // No `--edition`, like `RustCall.compile_rust_to_shared_lib`: a
        // refusal spelled `::core::compile_error!` would not resolve.
        let out = Command::new("rustc")
            .args(["--crate-type=cdylib", "-C", "panic=unwind"])
            .arg(&input)
            .arg("--out-dir")
            .arg(&dir)
            .output()
            .unwrap();
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(!out.status.success(), "{}: compiled", case.label);
        let errors: Vec<&str> = stderr
            .lines()
            .filter(|l| l.starts_with("error") && !l.starts_with("error: aborting"))
            .collect();
        assert_eq!(errors.len(), 1, "{}: {stderr}", case.label);
        assert!(
            flat(&stderr).contains(case.message),
            "{}: {stderr}",
            case.label
        );
    }
    let _ = fs::remove_dir_all(dir);
}

/// A refused trait-impl method is recorded under its trait, so a method of
/// the same name — inherent, or of another trait impl — never merges it away
/// (#503 review): the manifest keeps both, the refused one with its
/// `skip_reason` and `trait_path`, whichever block comes first.
#[test]
fn a_refused_trait_method_survives_a_same_named_method() {
    let traits = "pub mod tr {
                      pub trait Limits { const N: usize; fn limit(&self, a: &[u8; 2]) -> i32; }
                      pub trait Other { fn limit(&self) -> i32; }
                  }
                  #[julia] pub struct Buf { pub n: i32 }";
    let inherent = "#[julia] impl Buf { #[julia] pub fn limit(&self) -> i32 { self.n } }";
    let other = "#[julia] impl tr::Other for Buf { #[julia] fn limit(&self) -> i32 { self.n } }";
    let refused = "#[julia] impl tr::Limits for Buf {
                       const N: usize = 2;
                       #[julia] fn limit(&self, a: &[u8; Self::N]) -> i32 { a.len() as i32 + self.n }
                   }";
    for (label, blocks) in [
        ("inherent first", vec![inherent, refused]),
        ("refused first", vec![refused, inherent]),
        (
            "inherent, then another trait",
            vec![inherent, other, refused],
        ),
    ] {
        let source = format!("{traits}\n{}", blocks.join("\n"));
        let manifest = extract(&source, Mode::Crate).unwrap();
        let buf = manifest.structs.iter().find(|s| s.name == "Buf").unwrap();
        let limits: Vec<(&str, &str)> = buf
            .methods
            .iter()
            .filter(|m| m.name == "limit")
            .map(|m| (m.trait_path.as_str(), m.skip_reason.as_str()))
            .collect();
        assert!(
            limits.contains(&("", "")),
            "{label}: the inherent method is gone: {limits:?}"
        );
        assert!(
            limits.contains(&("tr::Limits", "self_trait_path:tr::Limits")),
            "{label}: the refused trait method is gone: {limits:?}"
        );
        // A trait impl's wrapped methods are not described (#506).
        assert!(
            !limits.iter().any(|(t, _)| *t == "tr::Other"),
            "{label}: {limits:?}"
        );
        assert_eq!(limits.len(), 2, "{label}: {limits:?}");
        let expansion = crate_expansion(&source).to_string();
        assert_eq!(
            expansion.matches("compile_error").count(),
            1,
            "{label}: {expansion}"
        );
    }
}
