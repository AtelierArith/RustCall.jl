//! The generic environment a generated wrapper declares (#482).
//!
//! An `extern "C"` wrapper calls the item it wraps, so it has to be valid
//! under the same assumptions the item is: the lifetimes its passed-through
//! arguments name, the relations among them, and every `where` predicate the
//! call needs as proof. PR #480 moved those onto the wrapper predicate by
//! predicate, each move a token-level guess about what rustc would accept.
//! There is no choice to make here any more:
//!
//! * the wrapper declares the item's **whole** environment — the lifetime
//!   parameters and `where` clause of the impl block the method was written in
//!   ([`ImplHost`]), then the method's own — verbatim;
//! * `Self`, the one name of that environment that a free function does not
//!   have, is spelled as what it is an alias for: the impl header's type
//!   ([`expand_self`]; `Self::Assoc` becomes `<Buf>::Assoc`, or
//!   `<Buf as Trait>::Assoc` in a trait impl). A `Self` this cannot reach — inside a
//!   macro invocation — is refused at that token ([`leftover_self`]);
//! * a lifetime parameter the resulting signature and predicates name nowhere
//!   is left out ([`prune_unused_lifetimes`]): an unconstrained, unused
//!   parameter means nothing, and keeping it would only rename the wrappers of
//!   every `&'a str` function.
//!
//! The one place where the wrapper's signature does not mean what the item's
//! does is a lowered string argument: `s: &'a str` arrives as a pointer and a
//! length and is rebuilt into a local, so the item's `'a` is instantiated with
//! a region that ends inside the wrapper. [`lowered_lifetime_error`] proves
//! that such an instantiation exists, or refuses the item at the argument.

use std::collections::{BTreeMap, BTreeSet};

use proc_macro2::{Span, TokenStream as TokenStream2, TokenTree};
use quote::{quote, quote_spanned};
use syn::visit_mut::VisitMut;
use syn::{Ident, Type};

use crate::model::ImplHost;
use crate::types::{is_str_ref_type, is_string_type};

/// The lifetime names (`a` for `'a`) spelled anywhere in `tokens`, `for<'b>`
/// binders and `'static` included.
pub(crate) fn lifetime_names(tokens: TokenStream2, out: &mut BTreeSet<String>) {
    let mut after_quote = false;
    for tree in tokens {
        match tree {
            TokenTree::Punct(p) => {
                after_quote = p.as_char() == '\'' && p.spacing() == proc_macro2::Spacing::Joint;
                continue;
            }
            TokenTree::Ident(i) if after_quote => {
                out.insert(i.to_string());
            }
            TokenTree::Group(g) => lifetime_names(g.stream(), out),
            _ => {}
        }
        after_quote = false;
    }
}

fn names_of(tokens: TokenStream2) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    lifetime_names(tokens, &mut out);
    out
}

/// The lifetime parameters of `generics`, with their bounds, and its `where`
/// clause. A type or const parameter never reaches a wrapper of its own — the
/// item is refused, or monomorphized first — so none is kept, and neither is
/// a `where` clause that could name one.
fn lifetime_part(generics: &syn::Generics) -> (Vec<syn::GenericParam>, Vec<syn::WherePredicate>) {
    let params: Vec<syn::GenericParam> = generics
        .params
        .iter()
        .filter(|p| matches!(p, syn::GenericParam::Lifetime(_)))
        .cloned()
        .collect();
    let predicates = if params.len() == generics.params.len() {
        generics
            .where_clause
            .iter()
            .flat_map(|w| w.predicates.iter().cloned())
            .collect()
    } else {
        Vec::new()
    };
    (params, predicates)
}

/// Rebuild a `syn::Generics` from parameters and predicates.
fn generics_of(
    params: Vec<syn::GenericParam>,
    predicates: Vec<syn::WherePredicate>,
) -> syn::Generics {
    syn::Generics {
        lt_token: (!params.is_empty()).then(Default::default),
        gt_token: (!params.is_empty()).then(Default::default),
        params: params.into_iter().collect(),
        where_clause: (!predicates.is_empty()).then(|| syn::WhereClause {
            where_token: Default::default(),
            predicates: predicates.into_iter().collect(),
        }),
    }
}

/// The environment of an item as its wrapper declares it: the lifetime
/// parameters and `where` predicates of the impl block (`host`), then the
/// item's own, verbatim. Rust forbids a method's lifetime to shadow one of its
/// block's, so the two lists never share a name. `Self` is not yet expanded.
pub(crate) fn wrapper_environment(host: Option<&ImplHost>, item: &syn::Generics) -> syn::Generics {
    let (mut params, mut predicates) = host.map(|h| lifetime_part(&h.generics)).unwrap_or_default();
    let (item_params, item_predicates) = lifetime_part(item);
    params.extend(item_params);
    predicates.extend(item_predicates);
    generics_of(params, predicates)
}

/// Spells every `Self` of an impl's signature as the header's type, which is
/// what `Self` is an alias for inside the block.
struct SelfAlias<'h>(&'h ImplHost);

impl VisitMut for SelfAlias<'_> {
    fn visit_type_mut(&mut self, ty: &mut Type) {
        if let Type::Path(tp) = ty {
            let starts_with_self = tp.qself.is_none()
                && tp.path.leading_colon.is_none()
                && tp
                    .path
                    .segments
                    .first()
                    .is_some_and(|s| s.ident == "Self" && s.arguments.is_none());
            if starts_with_self {
                let mut rest: syn::punctuated::Punctuated<syn::PathSegment, syn::Token![::]> =
                    tp.path.segments.iter().skip(1).cloned().collect();
                for segment in rest.iter_mut() {
                    self.visit_path_segment_mut(segment);
                }
                let self_ty = &self.0.self_ty;
                *ty = if rest.is_empty() {
                    self_ty.clone()
                } else {
                    match &self.0.trait_ {
                        // `Self::Assoc` in a trait impl names the trait's item.
                        Some(trait_path) => syn::parse_quote!(<#self_ty as #trait_path>::#rest),
                        None => syn::parse_quote!(<#self_ty>::#rest),
                    }
                };
                return;
            }
        }
        syn::visit_mut::visit_type_mut(self, ty);
    }
}

/// [`SelfAlias`] over a type.
pub(crate) fn expand_self_in_type(host: &ImplHost, ty: &mut Type) {
    SelfAlias(host).visit_type_mut(ty);
}

/// [`SelfAlias`] over a whole signature: a generic struct's method wrapper
/// is a generic free function that declares the block's generics and the
/// method's (`wrapper_generics` in `codegen`) and spells its argument and
/// return types as the method does.
pub(crate) fn expand_self_in_signature(host: &ImplHost, sig: &mut syn::Signature) {
    SelfAlias(host).visit_signature_mut(sig);
}

/// [`SelfAlias`] over a set of generics: parameter bounds and `where` clause.
pub(crate) fn expand_self(host: &ImplHost, generics: &mut syn::Generics) {
    SelfAlias(host).visit_generics_mut(generics);
}

/// The first `Self` token left in `tokens` after [`expand_self`]: one inside a
/// macro invocation (`m!(Self)`), whose tokens are not a type until the macro
/// has run.
pub(crate) fn leftover_self(tokens: TokenStream2) -> Option<Span> {
    tokens.into_iter().find_map(|tree| match tree {
        TokenTree::Ident(i) if i == "Self" => Some(i.span()),
        TokenTree::Group(g) => leftover_self(g.stream()),
        _ => None,
    })
}

/// The refusal of a `Self` [`expand_self`] could not spell. A bare
/// `compile_error!`, which resolves in the edition-2015 crate a `rust"""`
/// block is compiled as.
pub(crate) fn leftover_self_error(span: Span, julia_name: &str) -> TokenStream2 {
    let msg = format!(
        "`{julia_name}`: this `Self` is inside a macro invocation, so RustCall cannot spell it \
         as the impl's type on the `extern \"C\"` wrapper, which is a free function. Write the \
         type instead of `Self` here (#482)."
    );
    quote_spanned! {span=> compile_error!(#msg); }
}

/// `environment` without the lifetime parameters that `signature` (the
/// wrapper's argument and return types) and the environment's own bounds and
/// predicates name nowhere. Such a parameter is unconstrained and unused: the
/// call instantiates the item's parameters afresh, so it means nothing on the
/// wrapper. A lifetime only a lowered string names (`s: &'a str`) is one.
pub(crate) fn prune_unused_lifetimes(
    environment: syn::Generics,
    signature: TokenStream2,
) -> syn::Generics {
    let mut named = names_of(signature);
    for param in &environment.params {
        if let syn::GenericParam::Lifetime(lp) = param {
            for bound in &lp.bounds {
                named.insert(bound.ident.to_string());
            }
        }
    }
    let predicates: Vec<syn::WherePredicate> = environment
        .where_clause
        .iter()
        .flat_map(|w| w.predicates.iter().cloned())
        .collect();
    for predicate in &predicates {
        lifetime_names(quote! { #predicate }, &mut named);
    }
    let params = environment
        .params
        .into_iter()
        .filter(|p| match p {
            syn::GenericParam::Lifetime(lp) => named.contains(&lp.lifetime.ident.to_string()),
            _ => true,
        })
        .collect();
    generics_of(params, predicates)
}

/// A type or a `where` predicate as a human writes it (`&'a i32`, not the
/// token stream's `& 'a i32`), for a diagnostic.
fn readable(tokens: TokenStream2) -> String {
    let unparse = |item: syn::Item| {
        prettyplease::unparse(&syn::File {
            shebang: None,
            attrs: Vec::new(),
            items: vec![item],
        })
    };
    if let Ok(ty) = syn::parse2::<Type>(tokens.clone()) {
        let text = unparse(syn::parse_quote!(type T = #ty;));
        if let Some(body) = text.trim().strip_prefix("type T = ") {
            return body.trim_end_matches(';').to_string();
        }
    }
    if let Ok(predicate) = syn::parse2::<syn::WherePredicate>(tokens.clone()) {
        let text = unparse(syn::parse_quote!(fn f() where #predicate {}));
        let body: Vec<&str> = text
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && *l != "where" && !l.starts_with("fn f()") && *l != "{}")
            .collect();
        return body.join(" ").trim_end_matches(',').to_string();
    }
    tokens.to_string()
}

/// Why a lifetime cannot be instantiated with a region that ends inside the
/// wrapper.
fn fixed_reason(name: &str, fixed: &BTreeMap<String, String>) -> Option<String> {
    if name == "static" {
        return Some("`'static` outlives every call".to_string());
    }
    fixed.get(name).cloned()
}

/// Refuse an item one of whose lowered string arguments (`s: &'a str`) names a
/// lifetime the call cannot give a region that ends inside the wrapper (#482).
///
/// The wrapper rebuilds such an argument into a local and passes a borrow of
/// it, so the item's `'a` is instantiated with (at most) the call. That works
/// exactly when every lifetime `'a` must outlive — through a parameter bound
/// or a `where 'a: 'b` predicate, transitively — can be instantiated that way
/// too, with every other lifetime instantiated as the wrapper's own parameter
/// of that name. A lifetime cannot shrink to the call when
///
/// * it is `'static`;
/// * the wrapper hands a value naming it back (the return type, a `Result` /
///   `Option` payload): the value would outlive the local it borrows;
/// * a passed-through argument names it anywhere but as its outermost
///   reference lifetime (`&'a Buf` shrinks, `&'a mut &'a Buf` does not);
/// * a type predicate names it other than as a bare outlives bound (`X: 'a`
///   holds for a shorter `'a` when it holds for the wrapper's).
///
/// Anything else — `'x: 'a`, an outermost `&'a Buf`, a lifetime a predicate
/// relates only to shrinkable ones — is instantiated at the call and holds.
/// The check is conservative, never a guess: a refused item may be one rustc
/// would accept after all, an accepted one always compiles.
pub(crate) fn lowered_lifetime_error(
    environment: &syn::Generics,
    args: &[(Ident, Type)],
    returned: &[TokenStream2],
    julia_name: &str,
) -> Option<TokenStream2> {
    let params: BTreeSet<String> = environment
        .lifetimes()
        .map(|lp| lp.lifetime.ident.to_string())
        .collect();
    // `'a: 'b` edges: a lifetime in the closure of a lowered one shrinks too.
    let mut outlives: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut edge = |from: &syn::Lifetime, to: &syn::Lifetime| {
        outlives
            .entry(from.ident.to_string())
            .or_default()
            .insert(to.ident.to_string());
    };
    for lp in environment.lifetimes() {
        for bound in &lp.bounds {
            edge(&lp.lifetime, bound);
        }
    }
    let mut fixed: BTreeMap<String, String> = BTreeMap::new();
    let mut fix = |names: BTreeSet<String>, reason: &dyn Fn() -> String| {
        for name in names.into_iter().filter(|n| params.contains(n)) {
            fixed.entry(name).or_insert_with(reason);
        }
    };
    for predicate in environment
        .where_clause
        .iter()
        .flat_map(|w| w.predicates.iter())
    {
        match predicate {
            syn::WherePredicate::Lifetime(pl) => {
                for bound in &pl.bounds {
                    edge(&pl.lifetime, bound);
                }
            }
            syn::WherePredicate::Type(pt) => {
                let mut strict = names_of(quote! { #pt });
                // A bare `X: 'a` bound holds for a shorter `'a` as well.
                for bound in &pt.bounds {
                    if let syn::TypeParamBound::Lifetime(l) = bound {
                        let elsewhere = {
                            let ty = &pt.bounded_ty;
                            let others = pt.bounds.iter().filter(|b| {
                                !matches!(b, syn::TypeParamBound::Lifetime(o) if o.ident == l.ident)
                            });
                            let binder = &pt.lifetimes;
                            names_of(quote! { #binder #ty #(#others)* })
                        };
                        if !elsewhere.contains(&l.ident.to_string()) {
                            strict.remove(&l.ident.to_string());
                        }
                    }
                }
                let spelled = readable(quote! { #pt });
                fix(strict, &|| {
                    format!("the `where` predicate `{spelled}` names it")
                });
            }
            _ => {}
        }
    }
    let mut lowered: Vec<(&Ident, &syn::Lifetime)> = Vec::new();
    for (name, ty) in args {
        if is_str_ref_type(ty) {
            if let Type::Reference(r) = crate::types::unparen(ty) {
                if let Some(l) = &r.lifetime {
                    lowered.push((name, l));
                }
            }
            continue;
        }
        if is_string_type(ty) {
            continue;
        }
        // A passed-through argument: its outermost reference lifetime shrinks
        // with the call (`&'a T` is covariant in `'a`), nothing else does.
        let inner = match crate::types::unparen(ty) {
            Type::Reference(r) => {
                let elem = &r.elem;
                quote! { #elem }
            }
            other => quote! { #other },
        };
        let spelled = readable(quote! { #ty });
        fix(names_of(inner), &|| {
            format!("argument `{name}: {spelled}` names it inside its type")
        });
    }
    for ty in returned {
        let spelled = readable(ty.clone());
        fix(names_of(ty.clone()), &|| {
            format!("the wrapper returns `{spelled}`, which names it")
        });
    }

    for (arg, lifetime) in lowered {
        let start = lifetime.ident.to_string();
        let mut seen: BTreeSet<String> = BTreeSet::new();
        let mut queue = vec![(start.clone(), Vec::<String>::new())];
        while let Some((name, via)) = queue.pop() {
            if !seen.insert(name.clone()) {
                continue;
            }
            if let Some(reason) = fixed_reason(&name, &fixed) {
                let why = if via.is_empty() {
                    format!("but {reason}")
                } else {
                    let mut steps = vec![format!("'{start}")];
                    steps.extend(via.iter().map(|n| format!("'{n}")));
                    format!(
                        "but it must outlive `'{name}` (`{}`), and {reason}",
                        steps.join(": ")
                    )
                };
                let msg = if start == "static" {
                    format!(
                        "`{julia_name}`: argument `{arg}` arrives from Julia as a pointer and a \
                         length and is rebuilt into a string that lives only for the call, so it \
                         cannot be borrowed for `'static`. Take `String` (#482)."
                    )
                } else {
                    format!(
                        "`{julia_name}`: argument `{arg}` arrives from Julia as a pointer and a \
                         length and is rebuilt into a string that lives only for the call, so \
                         `'{start}` cannot be required to outlive the call; {why}. Take `String`, \
                         or relate `'{start}` to nothing that outlives the call (#482)."
                    )
                };
                let span = lifetime.ident.span();
                return Some(quote_spanned! {span=> compile_error!(#msg); });
            }
            for next in outlives.get(&name).into_iter().flatten() {
                let mut via = via.clone();
                via.push(next.clone());
                queue.push((next.clone(), via));
            }
        }
    }
    None
}
