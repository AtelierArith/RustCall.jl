//! Every refusal the `#[julia]` codegen makes, decided in one place (#503).
//!
//! An item RustCall cannot give an `extern "C"` entry point is refused with a
//! `compile_error!` at the item — and the manifest has to say so, or the Julia
//! generators and the boundary report stay silent about an item whose build
//! fails. Three review rounds of #491 each found one more place where the
//! codegen refused an item that the manifest omitted or did not mark. So the
//! decision is made here, once, as a [`Refusal`], and both outputs are derived
//! from it:
//!
//! * the expansion (the proc macro, `rust"""` expansion) emits
//!   [`Refusal::compile_error`] — a bare `compile_error!` (it resolves in the
//!   edition-2015 crate a `rust"""` block is compiled as), spanned at the
//!   offending token, gated by the item's `#[cfg]`;
//! * the manifest keeps the item and records [`Refusal::skip_reason`], a value
//!   of [`skip_reason::CODEGEN_REFUSALS`].
//!
//! The decisions:
//!
//! | function | position | refusals |
//! |---|---|---|
//! | [`function_refusal`] | a `#[julia]` free function | `unsafe_fn`, `non_ffi_payload`, `generic_signature`, `impl_trait`, then the wrapper's own |
//! | [`method_refusal`] | a method a `#[julia]` struct's wrappers wrap | `generic_signature`, `impl_trait`, `unsafe_fn`, then the wrapper's own |
//! | [`struct_refusal`] | a `#[julia]` struct (crate) | `generic_signature` |
//! | [`impl_refusal`] | a `#[julia] impl` block (crate) | a header that is not a type path, `generic_signature` |
//! | [`module_refusal`] | a `#[julia]` module (crate) | a file module |
//! | [`item_kind_refusal`] | `#[julia]` on anything else (crate) | — |
//!
//! "The wrapper's own" are the refusals only building the wrapper can decide —
//! a `Self` it cannot spell, a lowered `&str` whose lifetime it cannot honour
//! (`crate::environment`). They are made by the one wrapper generator
//! (`codegen::generate_wrapper`), and [`function_refusal`] / [`method_refusal`]
//! ask that generator for them rather than repeating its rules.
//!
//! The last three refuse no item Julia could bind — a block, a module, an
//! enum — so the manifest has no entry to mark; crate extraction fails closed
//! with the same message instead, as it does for a `#[julia]` item in an
//! unmarked module (`crate::extract`).

use proc_macro2::{
    Delimiter, Group, Literal, Punct, Spacing, Span, TokenStream as TokenStream2, TokenTree,
};
use quote::{quote, ToTokens};
use syn::spanned::Spanned;
use syn::{Attribute, Ident, ItemFn, ItemImpl, ItemMod, ItemStruct, ReturnType, Type};

use crate::manifest::{skip_reason, Mode};
use crate::model::{ImplHost, MethodModel};
use crate::types::{extract_option_type, extract_result_type, type_to_string};

/// Why the codegen refuses an item, and where.
#[derive(Debug, Clone)]
pub struct Refusal {
    /// One of [`skip_reason::CODEGEN_REFUSALS`], or — for a refusal of no
    /// bindable item ([`impl_refusal`], [`module_refusal`],
    /// [`item_kind_refusal`]) — a label of its own.
    pub kind: &'static str,
    /// What follows the colon of the manifest's `skip_reason`; may be empty.
    pub detail: String,
    /// The first token the `compile_error!` points at.
    pub span: Span,
    /// The last one: a diagnostic underlines `span..end`, as
    /// `syn::Error::new_spanned` does.
    pub end: Span,
    /// The full diagnostic.
    pub message: String,
}

/// [`Refusal::kind`] of [`impl_refusal`]'s header refusal.
pub const IMPL_NOT_A_PATH: &str = "impl_not_a_path";
/// [`Refusal::kind`] of [`module_refusal`].
pub const FILE_MODULE: &str = "file_module";
/// [`Refusal::kind`] of [`item_kind_refusal`].
pub const UNSUPPORTED_ITEM: &str = "unsupported_item";

impl Refusal {
    /// A refusal pointing at one token.
    pub(crate) fn new(
        kind: &'static str,
        detail: impl Into<String>,
        span: Span,
        message: impl Into<String>,
    ) -> Self {
        Refusal {
            kind,
            detail: detail.into(),
            span,
            end: span,
            message: message.into(),
        }
    }

    /// A refusal pointing at every token of `node`.
    pub(crate) fn over(
        kind: &'static str,
        detail: impl Into<String>,
        node: &dyn ToTokens,
        message: impl Into<String>,
    ) -> Self {
        let tokens: Vec<TokenTree> = node.to_token_stream().into_iter().collect();
        let first = tokens
            .first()
            .map(TokenTree::span)
            .unwrap_or_else(Span::call_site);
        let last = tokens.last().map(TokenTree::span).unwrap_or(first);
        Refusal {
            end: last,
            ..Refusal::new(kind, detail, first, message)
        }
    }

    /// The manifest's `skip_reason` for the refused item: `kind` or
    /// `kind:detail`.
    pub fn skip_reason(&self) -> String {
        if self.detail.is_empty() {
            self.kind.to_string()
        } else {
            skip_reason::detailed(self.kind, &self.detail)
        }
    }

    /// The `compile_error!` the expansion emits for this refusal, gated by
    /// `cfgs` — the item's effective `#[cfg]` set — so it fires only where the
    /// item exists.
    ///
    /// The proc macro can run before rustc evaluates an item's predicates —
    /// for every item inside a `#[julia] mod`, and for a `#[cfg]` written
    /// after `#[julia]` — so an ungated `compile_error!` would break a build
    /// in which the item is configured away (PR #470 review). A bare
    /// `compile_error!`, not `syn::Error::to_compile_error`: that spells it
    /// `::core::compile_error!`, which does not resolve in the edition-2015
    /// crate a `rust"""` block is compiled as (`rustc` with no `--edition`).
    /// Its name carries [`Refusal::span`] and its argument [`Refusal::end`],
    /// so the diagnostic underlines the whole offending node. This is the
    /// only place a refusal becomes tokens.
    pub fn compile_error(&self, cfgs: &[Attribute]) -> TokenStream2 {
        let mut bang = Punct::new('!', Spacing::Alone);
        bang.set_span(self.span);
        let mut message = Literal::string(&self.message);
        message.set_span(self.end);
        let mut args = Group::new(Delimiter::Parenthesis, TokenTree::from(message).into());
        args.set_span(self.end);
        let mut semi = Punct::new(';', Spacing::Alone);
        semi.set_span(self.end);
        let error: TokenStream2 = [
            TokenTree::from(Ident::new("compile_error", self.span)),
            bang.into(),
            args.into(),
            semi.into(),
        ]
        .into_iter()
        .collect();
        if cfgs.is_empty() {
            error
        } else {
            quote! { #(#cfgs)* #error }
        }
    }
}

/// The type and const parameters of `generics`, spelled for a diagnostic
/// (`` `T` ``, `` `const N` ``). Lifetimes are left out: they never stop an item
/// from getting an `extern "C"` entry point.
fn generic_param_list(generics: &syn::Generics) -> Vec<String> {
    generics
        .params
        .iter()
        .filter_map(|p| match p {
            syn::GenericParam::Type(t) => Some(format!("`{}`", t.ident)),
            syn::GenericParam::Const(c) => Some(format!("`const {}`", c.ident)),
            syn::GenericParam::Lifetime(_) => None,
        })
        .collect()
}

/// [`generic_param_list`] without the backticks, for a `skip_reason` detail.
fn generic_param_detail(generics: &syn::Generics) -> String {
    generic_param_list(generics)
        .iter()
        .map(|p| p.trim_matches('`').to_string())
        .collect::<Vec<_>>()
        .join(", ")
}

/// Refuse a generic `#[julia]` item in the crate flavour (#462).
///
/// An `extern "C"` entry point needs concrete types, and the proc macro sees one
/// item and cannot know which instantiations Julia will call, so a type or
/// const parameter used to produce a wrapper naming an unbound `T` and rustc
/// failed inside generated code. Lifetime parameters are not refused:
/// `fn f<'a>(s: &'a str) -> &'a str` lowers to a wrapper that names no
/// lifetime at all, and one a passed-through argument still names
/// (`other: &'a Buf`) is declared on the wrapper (#477).
///
/// The inline flavour never reaches this for a type parameter: `rust"""`
/// emits a generic function or struct unwrapped and monomorphizes it on demand
/// through `specialize`.
fn crate_generic_refusal(generics: &syn::Generics, what: &str, name: &Ident) -> Option<Refusal> {
    let params = generic_param_list(generics);
    if params.is_empty() {
        return None;
    }
    let msg = format!(
        "#[julia] {what} `{name}` is generic over {}: an `extern \"C\"` entry point needs \
         concrete types, and #[julia] cannot know which instantiations Julia will call. \
         Write a non-generic `#[julia]` item that uses it, or define it in a `rust\"\"\"` block, where \
         RustCall monomorphizes generics on demand.",
        params.join(", ")
    );
    Some(Refusal::over(
        skip_reason::GENERIC_SIGNATURE,
        generic_param_detail(generics),
        generics,
        msg,
    ))
}

/// [`crate_generic_refusal`] for a function or method signature, which may
/// also be generic through `impl Trait` in an argument or its return type.
fn crate_signature_refusal(sig: &syn::Signature, what: &str) -> Option<Refusal> {
    if let Some(refusal) = crate_generic_refusal(&sig.generics, what, &sig.ident) {
        return Some(refusal);
    }
    if crate::types::has_impl_trait(sig) {
        let msg = format!(
            "#[julia] {what} `{}` uses `impl Trait` in its signature, which makes it generic: \
             an `extern \"C\"` entry point needs concrete types. Name the concrete type instead.",
            sig.ident
        );
        return Some(Refusal::over(skip_reason::IMPL_TRAIT, "", sig, msg));
    }
    None
}

/// Refuse an `unsafe fn` `#[julia]` function (#491): its `extern "C"` entry
/// point would let Julia call it with none of the requirements its `unsafe`
/// states upheld. A generic one is refused too — a specialized wrapper would
/// otherwise call it from a safe body and fail with E0133 at the first `@rust`
/// call.
fn unsafe_function_refusal(func: &ItemFn) -> Option<Refusal> {
    let unsafety = func.sig.unsafety.as_ref()?;
    Some(Refusal::new(
        skip_reason::UNSAFE_FN,
        "",
        unsafety.span(),
        "#[julia] cannot be applied to unsafe functions directly. The function will be made \
         extern \"C\" which has its own safety semantics.",
    ))
}

/// Whether a `Result` / `Option` payload can be carried by the generated
/// `#[repr(C)]` aggregate: anything the C ABI takes as written, plus `String` /
/// `&str`, which are lowered to an owned buffer (#268).
pub fn payload_is_representable(ty: &Type) -> bool {
    crate::types::is_string_type(ty)
        || crate::types::is_str_ref_type(ty)
        || !crate::types::is_non_ffi_type(ty)
}

/// `Result` / `Option` payloads of a free function must survive the C ABI;
/// refuse at compile time rather than emit a wrapper that cannot be called.
fn non_ffi_payload_refusal(func: &ItemFn) -> Option<Refusal> {
    let ReturnType::Type(_, ty) = &func.sig.output else {
        return None;
    };
    let name = &func.sig.ident;
    let refuse = |what: &str, payload: &Type| {
        let spelled = type_to_string(payload);
        Refusal::over(
            skip_reason::NON_FFI_PAYLOAD,
            spelled.clone(),
            payload,
            format!(
                "#[julia] function `{name}` returns {what} type `{spelled}`. Use a primitive or \
                 #[repr(C)] type instead."
            ),
        )
    };
    if let Some(r) = extract_result_type(ty) {
        if !payload_is_representable(&r.ok_type) {
            return Some(refuse("Result with non-FFI-compatible Ok", &r.ok_type));
        }
        if !payload_is_representable(&r.err_type) {
            return Some(refuse("Result with non-FFI-compatible Err", &r.err_type));
        }
    }
    if let Some(o) = extract_option_type(ty) {
        if !payload_is_representable(&o.inner_type) {
            return Some(refuse("Option with non-FFI-compatible", &o.inner_type));
        }
    }
    None
}

/// Const generics and `impl Trait` cannot be instantiated from Julia, and
/// `#[no_mangle]` on a still-generic fn exports no symbol: a `rust"""` block
/// fails at compile time rather than at the first call.
fn inline_generic_function_refusal(func: &ItemFn) -> Option<Refusal> {
    let name = &func.sig.ident;
    if crate::types::has_impl_trait(&func.sig) {
        return Some(Refusal::over(
            skip_reason::IMPL_TRAIT,
            "",
            &func.sig,
            format!(
                "#[julia] function `{name}` uses `impl Trait` in its signature; `impl Trait` is \
                 not supported by RustCall"
            ),
        ));
    }
    let consts = crate::types::const_param_names(&func.sig.generics);
    if consts.is_empty() {
        return None;
    }
    Some(Refusal::over(
        skip_reason::GENERIC_SIGNATURE,
        consts
            .iter()
            .map(|c| format!("const {c}"))
            .collect::<Vec<_>>()
            .join(", "),
        &func.sig.generics,
        format!(
            "#[julia] function `{name}` has const generic parameter(s) {}; const generics are \
             not supported by RustCall",
            consts.join(", ")
        ),
    ))
}

/// Whether a `#[julia]` function is generic — over a type parameter or through
/// `impl Trait` — and so gets no wrapper of its own where it is written.
fn function_is_generic(func: &ItemFn) -> bool {
    crate::types::has_type_params(&func.sig.generics) || crate::types::has_impl_trait(&func.sig)
}

/// Why the codegen of `mode` refuses the `#[julia]` function `func` living
/// under `module_path`, if it does — the one decision both the expansion
/// (`codegen::transform_function`, `crate::expand`) and the manifest
/// (`crate::extract::function_entry`) take (#503).
///
/// In order: an `unsafe fn` (#491); a `Result` / `Option` payload that cannot
/// cross the C ABI, for a function wrapped where it is written; a generic
/// signature the flavour cannot bind (in a crate any type or const parameter or
/// `impl Trait`, #462; in a `rust"""` block const generics and `impl Trait` —
/// a type parameter is monomorphized on demand instead); then whatever the
/// wrapper generator refuses for the function's signature
/// (`crate::environment`).
pub fn function_refusal(func: &ItemFn, module_path: &[String], mode: Mode) -> Option<Refusal> {
    if let Some(refusal) = unsafe_function_refusal(func) {
        return Some(refusal);
    }
    let type_generic = crate::types::has_type_params(&func.sig.generics);
    if mode == Mode::Crate || !type_generic {
        if let Some(refusal) = non_ffi_payload_refusal(func) {
            return Some(refusal);
        }
    }
    let generic = match mode {
        Mode::Crate => crate_signature_refusal(&func.sig, "function"),
        Mode::Inline => inline_generic_function_refusal(func),
    };
    if generic.is_some() {
        return generic;
    }
    if function_is_generic(func) {
        return None;
    }
    crate::codegen::free_function_wrapper_refusal(func, module_path)
}

/// Where a method's wrapper is generated, which decides what may be refused.
#[derive(Debug, Clone, Copy)]
pub enum MethodSite<'a> {
    /// A `#[julia]` method of a `#[julia] impl` block, wrapped by the proc
    /// macro at the block: `self_ty` is the header as written.
    Crate { self_ty: &'a Type },
    /// A method of a concrete `#[julia]` struct of a `rust"""` block. The
    /// wrapper spells the struct as `self_ty`: its bare name beside the
    /// struct, the header as written at a block in another module (#342).
    Inline {
        self_ty: &'a Type,
        struct_name: &'a Ident,
    },
    /// A method of a generic `#[julia]` struct of a `rust"""` block: its
    /// wrapper is instantiated per struct type (`specialize`), which binds the
    /// struct's parameters and no others.
    InlineGeneric { struct_name: &'a Ident },
}

/// Whether a method of an inline struct is generic in its own right — over a
/// type or a const parameter of the method, or through `impl Trait` (#471,
/// #477). Only the method's own parameters count: a method of a generic struct
/// that uses just the struct's parameters (`impl<T> W<T> { fn get(&self) -> T
/// }`) is instantiated with the struct, and lifetimes never stop a wrapper.
fn method_is_generic(m: &MethodModel) -> bool {
    crate::types::has_type_params(&m.func.sig.generics) || crate::types::has_impl_trait(&m.func.sig)
}

/// Refuse a method of an inline struct that is generic in its own right
/// (#471, #477).
///
/// `rust"""` wraps every `pub fn` of a concrete struct's inherent impl in an
/// `extern "C"` entry point with a fixed symbol, which needs concrete types; a
/// method generic over `T` used to get a wrapper naming the unbound `T`, and
/// rustc failed inside generated code. A generic struct's wrappers are
/// instantiated per struct type, which binds the struct's parameters and no
/// others, so a method parameter `U` of `impl<T> W<T> { fn f<U>(..) }` stayed
/// unbound there in the same way. Monomorphizing either on demand would need a
/// path that binds a parameter only the method has, so the block is refused at
/// the method, naming what works instead.
fn inline_generic_method_refusal(
    struct_name: &Ident,
    struct_is_generic: bool,
    m: &MethodModel,
) -> Option<Refusal> {
    if !method_is_generic(m) {
        return None;
    }
    let sig = &m.func.sig;
    let method = &sig.ident;
    let params = generic_param_list(&sig.generics);
    let (kind, detail, what, span) = if params.is_empty() {
        (
            skip_reason::IMPL_TRAIT,
            String::new(),
            "uses `impl Trait` in its signature".to_string(),
            sig.span(),
        )
    } else {
        (
            skip_reason::GENERIC_SIGNATURE,
            generic_param_detail(&sig.generics),
            format!("is generic over {}", params.join(", ")),
            sig.generics.span(),
        )
    };
    let msg = if struct_is_generic {
        format!(
            "`{struct_name}::{method}` {what}: a generic `#[julia]` struct in a `rust\"\"\"` \
             block has its methods instantiated per struct type, which binds the struct's own \
             type parameters and no parameter only the method has. Make it a generic free \
             function, which RustCall instantiates for the argument types of each call, write \
             one method per type Julia calls using only the struct's parameters (it may \
             delegate to the generic one), or drop `pub` if Julia does not call it (#477)."
        )
    } else {
        format!(
            "`{struct_name}::{method}` {what}: every `pub fn` of a `#[julia]` struct in a \
             `rust\"\"\"` block gets an `extern \"C\"` entry point, which needs concrete types, and \
             RustCall monomorphizes on demand only generic free functions and generic structs. \
             Make it a generic free function, which RustCall instantiates for the argument types \
             of each call, write one non-generic method per type Julia calls (it may delegate to \
             the generic one), or drop `pub` if Julia does not call it (#471)."
        )
    };
    Some(Refusal::new(kind, detail, span, msg))
}

/// Refuse an `unsafe fn` method of a `#[julia]` struct (#491), in either
/// flavour. The wrapper would call it from a safe `extern "C"` body — which
/// used to fail inside generated code with rustc's E0133 — and, were that call
/// put in an `unsafe` block, would let Julia call it with none of the
/// requirements its `unsafe` states upheld.
fn unsafe_method_refusal(struct_name: &Ident, m: &MethodModel) -> Option<Refusal> {
    let unsafety = m.func.sig.unsafety.as_ref()?;
    let method = &m.func.sig.ident;
    Some(Refusal::new(
        skip_reason::UNSAFE_FN,
        "",
        unsafety.span(),
        format!(
            "`{struct_name}::{method}` is an `unsafe fn`: its `extern \"C\"` entry point would let \
             Julia call it with none of the requirements its `unsafe` states upheld. Expose a \
             safe method that upholds them and calls this one, and let Julia call that instead \
             (#491)."
        ),
    ))
}

/// Refuse a trait method whose typed receiver is not literal reference layers
/// over `Self` (`codegen::TraitReceiver::of`, #497): its wrapper calls
/// `<Buf as Tr>::m(..)`, whose first argument must match the receiver
/// exactly, and the written type does not say what that is. A
/// `self: &mut Self` receiver is refused too until #509 binds it as `&mut`.
/// `None` for a method of an inherent block, which keeps method-call syntax.
fn trait_receiver_refusal(struct_name: &Ident, m: &MethodModel) -> Option<Refusal> {
    m.host.as_ref()?.trait_.as_ref()?;
    let receiver = m.func.sig.receiver()?;
    let method = &m.func.sig.ident;
    let spelled = type_to_string(&receiver.ty);
    match crate::codegen::TraitReceiver::of(Some(receiver)) {
        Err(_) => Some(Refusal::over(
            skip_reason::TRAIT_RECEIVER,
            spelled,
            &receiver.ty,
            format!(
                "`{struct_name}::{method}`: the wrapper calls this trait method through the \
                 trait, which passes the receiver exactly as declared, and this receiver type \
                 does not show its shape. Write it as `self`, `&self`, `&mut self` or reference \
                 layers over `Self` (`self: &&Self`) — not a type alias, a smart pointer or the \
                 type's own name — or expose an inherent method that calls this one (#509)."
            ),
        )),
        // `self: &mut Self` binds `self_obj` as `&Buf`: `MethodModel::is_mutable`
        // reads only the `&mut self` shorthand (#509), so the call would not
        // compile either.
        Ok(_)
            if receiver.reference.is_none()
                && !m.is_mutable
                && matches!(
                    crate::types::unparen(&receiver.ty),
                    Type::Reference(r) if r.mutability.is_some()
                ) =>
        {
            Some(Refusal::over(
                skip_reason::TRAIT_RECEIVER,
                spelled,
                &receiver.ty,
                format!(
                    "`{struct_name}::{method}`: a `self: &mut Self` receiver is not yet wrapped \
                     (#509). Write it as `&mut self`."
                ),
            ))
        }
        Ok(_) => None,
    }
}

/// Why the codegen refuses to wrap the method `m` at `site`, if it does — the
/// one decision both the expansion (`codegen::inline_struct_wrappers`,
/// `codegen::inline_foreign_method_wrapper`,
/// `codegen::inline_generic_method_refusals`, `codegen::transform_impl_crate`)
/// and the manifest (`crate::expand`, `crate::extract`) take (#503).
///
/// In order: a method of a generic `#[julia] impl` block of a crate, which the
/// block's own refusal covers ([`impl_refusal`]); a method generic in its own
/// right (#462, #471, #477); an `unsafe fn` (#491); then whatever the wrapper
/// generator refuses for the method's signature (`crate::environment`) — for a
/// concrete struct's method, whose wrapper is generated now. A generic inline
/// struct's wrappers are instantiated later, by `specialize`.
pub fn method_refusal(site: MethodSite<'_>, m: &MethodModel) -> Option<Refusal> {
    match site {
        MethodSite::Crate { self_ty } => {
            if let Some(host) = &m.host {
                if let Some(refusal) = generic_block_refusal(host) {
                    return Some(refusal);
                }
            }
            if let Some(refusal) = crate_signature_refusal(&m.func.sig, "method") {
                return Some(refusal);
            }
            let struct_name = crate::types::last_ident(self_ty)?;
            if let Some(refusal) = unsafe_method_refusal(struct_name, m)
                .or_else(|| trait_receiver_refusal(struct_name, m))
            {
                return Some(refusal);
            }
            crate::codegen::method_wrapper_refusal(self_ty, struct_name, m)
        }
        MethodSite::Inline {
            self_ty,
            struct_name,
        } => {
            if let Some(refusal) = inline_generic_method_refusal(struct_name, false, m)
                .or_else(|| unsafe_method_refusal(struct_name, m))
                .or_else(|| trait_receiver_refusal(struct_name, m))
            {
                return Some(refusal);
            }
            crate::codegen::method_wrapper_refusal(self_ty, struct_name, m)
        }
        MethodSite::InlineGeneric { struct_name } => {
            inline_generic_method_refusal(struct_name, true, m)
                .or_else(|| unsafe_method_refusal(struct_name, m))
        }
    }
}

/// Refuse a generic `#[julia]` struct of a crate (#462). A `rust"""` block
/// monomorphizes a generic struct on demand and refuses none.
pub fn struct_refusal(item: &ItemStruct, mode: Mode) -> Option<Refusal> {
    match mode {
        Mode::Crate => crate_generic_refusal(&item.generics, "struct", &item.ident),
        Mode::Inline => None,
    }
}

/// The refusal of a generic `#[julia] impl` block (`impl<T> Wrapper<T>`, #462):
/// it has no concrete receiver type to wrap.
fn generic_block_refusal(host: &ImplHost) -> Option<Refusal> {
    if !crate::types::has_type_params(&host.generics) {
        return None;
    }
    let name = crate::types::last_ident(&host.self_ty)?;
    crate_generic_refusal(&host.generics, "impl block for", name)
}

/// Refuse a `#[julia] impl` block of a crate: one whose header is not a type
/// path, or a generic one (#462), whose methods it covers.
pub fn impl_refusal(item: &ItemImpl) -> Option<Refusal> {
    impl_header_refusal(&item.self_ty).or_else(|| generic_block_refusal(&ImplHost::of(item)))
}

/// Refuse a `#[julia] impl` header that is not a type path: the wrappers hang
/// off the type's name.
pub fn impl_header_refusal(self_ty: &Type) -> Option<Refusal> {
    if crate::types::last_ident(self_ty).is_some() {
        return None;
    }
    Some(Refusal::over(
        IMPL_NOT_A_PATH,
        "",
        self_ty,
        "#[julia] on impl block requires a simple type path",
    ))
}

/// Refuse a `#[julia]` file module (`mod a;`) of a crate: an attribute macro
/// cannot expand a module whose body is in another file.
pub fn module_refusal(item: &ItemMod) -> Option<Refusal> {
    if item.content.is_some() {
        return None;
    }
    Some(Refusal::over(
        FILE_MODULE,
        item.ident.to_string(),
        item,
        "#[julia] on a file module (`mod name;`) is not supported: attribute macros cannot \
         expand a non-inline module. Write the module inline (`#[julia] pub mod name { ... }`) \
         to give its items a module-qualified symbol.",
    ))
}

/// Refuse `#[julia]` on an item that is not a function, a struct, an impl
/// block or an inline module.
pub fn item_kind_refusal(span: Span) -> Refusal {
    Refusal::new(
        UNSUPPORTED_ITEM,
        "",
        span,
        "#[julia] can only be applied to functions, structs, impl blocks, or inline modules",
    )
}
