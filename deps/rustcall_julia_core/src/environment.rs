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
//!   `<Buf as Trait>::Assoc` in a trait impl), in type and in expression
//!   position (`[(); Self::N]`). A `Self` this cannot reach — inside a macro
//!   invocation — is refused at that token ([`leftover_self`]);
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
//!
//! An output lifetime the item leaves to elision (`-> &i32`) is the other
//! (#484): the wrapper's receiver is a raw pointer and a lowered string a
//! pointer and a length, so elision on the wrapper would find nothing.
//! [`name_elided_return`] applies Rust's rules to the item's signature and
//! spells out the lifetime they pick, or refuses an item whose returned value
//! would borrow a lowered string.

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
/// what `Self` is an alias for inside the block: in type position
/// (`Self: Tr`, `&'a Self`, `<Self as Tr>::Assoc`, `Self::Assoc`) and in
/// expression position — an associated const in an array length or a const
/// generic argument (`[(); Self::N]`, `Holder<{ Self::N }>`, PR #483 review).
///
/// An unqualified `Self::X` keeps the lookup rustc gives it inside the block:
///
/// * as a **type** it is `<Buf>::X` in an inherent impl and `<Buf as Trait>::X`
///   in a trait impl — an associated type of a concrete type resolves only
///   through the trait (`<Buf>::X` is E0223 outside an impl);
/// * as an **expression** (an associated const) it is `<Buf>::X` in both:
///   rustc resolves `Self::X` inherent first, then through the traits in
///   scope, and `<Buf>::X` is that same lookup, where `<Buf as Trait>::X`
///   would bypass an inherent `X` (PR #492 review). The implemented trait is
///   in scope at the wrapper — emitted in the block's module — only when the
///   header names it by a bare name; otherwise the path is left alone and
///   reported in `out_of_scope`.
struct SelfAlias<'h> {
    host: &'h ImplHost,
    /// The first unqualified `Self::X` expression of a trait impl whose trait
    /// the header names by a path (`impl tr::Limits for Buf`): the wrapper
    /// cannot be sure `<Buf>::X` finds it.
    out_of_scope: Option<Span>,
}

/// Whether a path without a `<..>` qualifier starts with a bare `Self`.
fn starts_with_self(qself: &Option<syn::QSelf>, path: &syn::Path) -> bool {
    qself.is_none()
        && path.leading_colon.is_none()
        && path
            .segments
            .first()
            .is_some_and(|s| s.ident == "Self" && s.arguments.is_none())
}

impl<'h> SelfAlias<'h> {
    fn new(host: &'h ImplHost) -> Self {
        SelfAlias {
            host,
            out_of_scope: None,
        }
    }

    /// `Self::rest` as a qualified path (see the type docs for which);
    /// `None` for a bare `Self` (no `rest`), and for an expression whose trait
    /// may be out of scope (recorded in `out_of_scope`).
    fn qualified(&mut self, path: &syn::Path, expression: bool) -> Option<syn::TypePath> {
        let mut rest: syn::punctuated::Punctuated<syn::PathSegment, syn::Token![::]> =
            path.segments.iter().skip(1).cloned().collect();
        if rest.is_empty() {
            return None;
        }
        for segment in rest.iter_mut() {
            self.visit_path_segment_mut(segment);
        }
        let self_ty = &self.host.self_ty;
        match &self.host.trait_ {
            Some(trait_path) if !expression => {
                Some(syn::parse_quote!(<#self_ty as #trait_path>::#rest))
            }
            Some(trait_path)
                if trait_path.leading_colon.is_some() || trait_path.segments.len() > 1 =>
            {
                if self.out_of_scope.is_none() {
                    self.out_of_scope = path.segments.first().map(|s| s.ident.span());
                }
                None
            }
            _ => Some(syn::parse_quote!(<#self_ty>::#rest)),
        }
    }

    /// A bare `Self` in expression position (a unit or tuple struct's
    /// constructor) as a path: the header's, when the header is a plain path.
    fn header_path(&self) -> Option<syn::Path> {
        match &self.host.self_ty {
            Type::Path(tp) if tp.qself.is_none() => Some(tp.path.clone()),
            _ => None,
        }
    }

    /// Rewrite an expression's `(qself, path)` pair in place; `false` when it
    /// is left as is.
    fn alias_path(&mut self, qself: &mut Option<syn::QSelf>, path: &mut syn::Path) -> bool {
        if !starts_with_self(qself, path) {
            return false;
        }
        if path.segments.len() > 1 {
            return match self.qualified(path, true) {
                Some(qualified) => {
                    *qself = qualified.qself;
                    *path = qualified.path;
                    true
                }
                None => false,
            };
        }
        match self.header_path() {
            Some(header) => {
                *path = header;
                true
            }
            None => false,
        }
    }
}

impl VisitMut for SelfAlias<'_> {
    fn visit_type_mut(&mut self, ty: &mut Type) {
        if let Type::Path(tp) = ty {
            if starts_with_self(&tp.qself, &tp.path) {
                *ty = match self.qualified(&tp.path, false) {
                    Some(qualified) => Type::Path(qualified),
                    None => self.host.self_ty.clone(),
                };
                return;
            }
        }
        syn::visit_mut::visit_type_mut(self, ty);
    }

    fn visit_expr_path_mut(&mut self, expr: &mut syn::ExprPath) {
        if !self.alias_path(&mut expr.qself, &mut expr.path) {
            syn::visit_mut::visit_expr_path_mut(self, expr);
        }
    }

    fn visit_expr_struct_mut(&mut self, expr: &mut syn::ExprStruct) {
        if self.alias_path(&mut expr.qself, &mut expr.path) {
            for field in expr.fields.iter_mut() {
                self.visit_field_value_mut(field);
            }
            if let Some(rest) = expr.rest.as_mut() {
                self.visit_expr_mut(rest);
            }
        } else {
            syn::visit_mut::visit_expr_struct_mut(self, expr);
        }
    }
}

/// [`SelfAlias`] over a type. Returns the span of an unqualified `Self::X`
/// expression it left alone because the trait may be out of scope.
pub(crate) fn expand_self_in_type(host: &ImplHost, ty: &mut Type) -> Option<Span> {
    let mut alias = SelfAlias::new(host);
    alias.visit_type_mut(ty);
    alias.out_of_scope
}

/// [`SelfAlias`] over a whole signature: a generic struct's method wrapper
/// is a generic free function that declares the block's generics and the
/// method's (`wrapper_generics` in `codegen`) and spells its argument and
/// return types as the method does. Its block is inherent, so nothing is
/// ever out of scope.
pub(crate) fn expand_self_in_signature(host: &ImplHost, sig: &mut syn::Signature) {
    SelfAlias::new(host).visit_signature_mut(sig);
}

/// [`SelfAlias`] over a set of generics: parameter bounds and `where` clause.
/// Returns what [`expand_self_in_type`] does.
pub(crate) fn expand_self(host: &ImplHost, generics: &mut syn::Generics) -> Option<Span> {
    let mut alias = SelfAlias::new(host);
    alias.visit_generics_mut(generics);
    alias.out_of_scope
}

/// The refusal of an unqualified `Self::X` expression in a trait impl whose
/// trait the header names by a path: `<Buf>::X` — the lookup `Self::X` has in
/// the block, inherent first — finds the trait's `X` only where the trait is in
/// scope, which the wrapper cannot see (PR #492 review).
pub(crate) fn out_of_scope_error(span: Span, host: &ImplHost, julia_name: &str) -> TokenStream2 {
    let trait_path = host.trait_.as_ref().map(readable_path).unwrap_or_default();
    let self_ty = &host.self_ty;
    let self_ty = readable(quote! { #self_ty });
    let msg = format!(
        "`{julia_name}`: an unqualified `Self::…` constant here resolves as \
         `<{self_ty}>::…` — inherent first, then through the traits in scope — and \
         the `extern \"C\"` wrapper cannot tell whether `{trait_path}` is in scope where it \
         is emitted. Write `<Self as {trait_path}>::…` for the trait's constant, or \
         `{self_ty}::…` for an inherent one, or import the trait and name it by its bare \
         name in the impl header (#482)."
    );
    quote_spanned! {span=> compile_error!(#msg); }
}

fn readable_path(path: &syn::Path) -> String {
    readable(quote! { #path })
}

/// A `Self` left in `tokens` after [`expand_self`], with the name of the
/// macro whose invocation holds it, if one does. Inside a macro (`m!(Self)`)
/// the tokens are not a type or an expression until the macro has run, so
/// they cannot be rewritten; anything else is a position [`SelfAlias`] does
/// not reach.
pub(crate) fn leftover_self(tokens: TokenStream2) -> Option<(Span, Option<String>)> {
    fn find(tokens: TokenStream2, in_macro: &Option<String>) -> Option<(Span, Option<String>)> {
        let trees: Vec<TokenTree> = tokens.into_iter().collect();
        for (i, tree) in trees.iter().enumerate() {
            match tree {
                TokenTree::Ident(id) if id == "Self" => {
                    return Some((id.span(), in_macro.clone()));
                }
                TokenTree::Group(g) => {
                    // `name ! ( .. )`: the group is a macro's input.
                    let before = |back: usize| i.checked_sub(back).map(|j| &trees[j]);
                    let called = match (before(2), before(1)) {
                        (Some(TokenTree::Ident(name)), Some(TokenTree::Punct(bang)))
                            if bang.as_char() == '!' =>
                        {
                            Some(format!("{name}!"))
                        }
                        _ => None,
                    };
                    let scope = in_macro.clone().or(called);
                    if let Some(found) = find(g.stream(), &scope) {
                        return Some(found);
                    }
                }
                _ => {}
            }
        }
        None
    }
    find(tokens, &None)
}

/// The refusal of a `Self` [`expand_self`] could not spell, saying which case
/// it is. A bare `compile_error!`, which resolves in the edition-2015 crate a
/// `rust"""` block is compiled as.
pub(crate) fn leftover_self_error(
    span: Span,
    in_macro: Option<&str>,
    julia_name: &str,
) -> TokenStream2 {
    let msg = match in_macro {
        Some(name) => format!(
            "`{julia_name}`: this `Self` is inside an invocation of `{name}`, whose tokens are \
             not a type until the macro has run, so RustCall cannot spell it as the impl's type \
             on the `extern \"C\"` wrapper, which is a free function. Write the type instead of \
             `Self` here (#482)."
        ),
        None => format!(
            "`{julia_name}`: RustCall does not spell a `Self` in this position as the impl's \
             type, and the `extern \"C\"` wrapper, a free function, has no `Self`. Write the \
             type instead of `Self` here (#482)."
        ),
    };
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

/// The lifetime positions of a type as Rust's elision rules count them
/// (#484): a reference's, a lifetime argument's (`Foo<'a>`, `Foo<'_>`) and a
/// bound's (`dyn Trait + 'a`). A fn-pointer type, `Fn(..)` sugar and a
/// `for<'b>` bound bind their own and are not entered. With `rename`, every
/// elided position (`&T`, `'_`) is given that lifetime.
struct Positions<'l> {
    rename: Option<&'l syn::Lifetime>,
    /// Where each elided position is: a reference's `&`, or the `'_`.
    elided: Vec<Span>,
    named: BTreeSet<String>,
}

impl Positions<'_> {
    fn lifetime(&mut self, lifetime: &mut syn::Lifetime) {
        if lifetime.ident == "_" {
            self.elided.push(lifetime.span());
            if let Some(name) = self.rename {
                *lifetime = name.clone();
            }
        } else {
            self.named.insert(lifetime.ident.to_string());
        }
    }
}

impl VisitMut for Positions<'_> {
    fn visit_type_reference_mut(&mut self, r: &mut syn::TypeReference) {
        match &mut r.lifetime {
            Some(lifetime) => self.lifetime(lifetime),
            None => {
                self.elided.push(r.and_token.span);
                r.lifetime = self.rename.cloned();
            }
        }
        self.visit_type_mut(&mut r.elem);
    }

    fn visit_lifetime_mut(&mut self, lifetime: &mut syn::Lifetime) {
        self.lifetime(lifetime);
    }

    fn visit_type_bare_fn_mut(&mut self, _: &mut syn::TypeBareFn) {}

    fn visit_parenthesized_generic_arguments_mut(
        &mut self,
        _: &mut syn::ParenthesizedGenericArguments,
    ) {
    }

    fn visit_trait_bound_mut(&mut self, bound: &mut syn::TraitBound) {
        if bound.lifetimes.is_none() {
            syn::visit_mut::visit_trait_bound_mut(self, bound);
        }
    }
}

fn positions(ty: &mut Type, rename: Option<&syn::Lifetime>) -> (Vec<Span>, BTreeSet<String>) {
    let mut p = Positions {
        rename,
        elided: Vec::new(),
        named: BTreeSet::new(),
    };
    p.visit_type_mut(ty);
    (p.elided, p.named)
}

/// Whether `ty` leaves an output lifetime to elision (`&T`, `'_`).
pub(crate) fn has_elided_lifetime(ty: &Type) -> bool {
    !positions(&mut ty.clone(), None).0.is_empty()
}

/// Give every elided lifetime of `ty` the name `lifetime`.
pub(crate) fn name_elided_lifetimes(ty: &mut Type, lifetime: &syn::Lifetime) {
    positions(ty, Some(lifetime));
}

/// The receiver of the item a wrapper calls, as lifetime elision sees it.
#[derive(Clone, Debug)]
pub(crate) enum SelfBorrow {
    /// No receiver, or one that is not a reference (`self`, `self: Box<Self>`).
    None,
    /// `&self`, `&'a mut self`, `self: &Self`: the lifetime as written, or
    /// `None` where it is elided.
    Ref(Option<syn::Lifetime>),
}

impl SelfBorrow {
    pub(crate) fn of(receiver: &syn::Receiver) -> Self {
        match crate::types::unparen(&receiver.ty) {
            Type::Reference(r) => SelfBorrow::Ref(r.lifetime.clone().filter(|l| l.ident != "_")),
            _ => SelfBorrow::None,
        }
    }
}

/// The lifetime a wrapper declares for an output lifetime elision picks
/// (#484): `'rustcall`, or the first `'rustcall<n>` that `spelled` — the
/// wrapper's generics, `where` clause and types — names nowhere. The one rule
/// for a concrete wrapper ([`name_elided_return`]) and a generic struct's
/// (`inline_generic_wrappers`), so a user lifetime spelled `'rustcall` is
/// never declared twice (PR #498 review).
pub(crate) fn fresh_lifetime(spelled: TokenStream2) -> syn::Lifetime {
    let taken = names_of(spelled);
    let name = std::iter::once("rustcall".to_string())
        .chain((1..).map(|n| format!("rustcall{n}")))
        .find(|n| !taken.contains(n))
        .expect("an unbounded sequence has a free name");
    syn::Lifetime::new(&format!("'{name}"), Span::call_site())
}

/// What [`name_elided_return`] decided.
pub(crate) enum ElidedReturn {
    /// Every lifetime of the return is named now; declare the wrapper.
    Named,
    /// The item's own signature leaves its output lifetime undecidable: more
    /// than one input lifetime and no reference receiver. That is E0106 at
    /// the user's signature, where rustc reports it; a wrapper would only
    /// repeat the error inside generated code, so none is emitted.
    Undecidable,
    /// Refused, with this bare `compile_error!`.
    Refused(TokenStream2),
}

/// Name the output lifetimes the item's return type leaves to elision (#484).
///
/// A wrapper cannot copy an elided return as written: its inputs are not the
/// item's — the receiver is a raw pointer and a lowered string a pointer and a
/// length, neither of which has a lifetime — so elision on the wrapper finds
/// nothing (E0106 inside generated code), or something else. Rust's rules are
/// applied to the **item's** signature instead, and the lifetime they pick is
/// spelled out:
///
/// * a reference receiver (`&self`, `&'a mut self`) gives its lifetime: `'a`
///   as written, or a fresh one declared on the wrapper. The wrapper's
///   receiver is `&*ptr`, which is unbounded, so the call instantiates the
///   method's receiver lifetime with it — what `&'a self -> &'a T` written
///   out already did;
/// * otherwise, the one lifetime the arguments name, elided or not: a named
///   one is used as is, an elided one on a passed-through argument is given a
///   fresh name there and in the return;
/// * an elided one on a lowered string (`s: &str`) is **refused** at that
///   argument: the string is rebuilt into a local, so the returned value would
///   borrow a string that is gone when the wrapper returns. A *named* one
///   (`s: &'a str`, `-> &'a i32` or `-> &i32`) is left to
///   [`lowered_lifetime_error`], which refuses it for the same reason once the
///   return names it.
pub(crate) fn name_elided_return(
    environment: &mut syn::Generics,
    receiver: &SelfBorrow,
    args: &mut [(Ident, Type)],
    returned: Vec<&mut Type>,
    julia_name: &str,
) -> ElidedReturn {
    if !returned.iter().any(|ty| has_elided_lifetime(ty)) {
        return ElidedReturn::Named;
    }
    let fresh = {
        let predicates = &environment.where_clause;
        let arg_types = args.iter().map(|(_, ty)| ty);
        let returned = &returned;
        fresh_lifetime(quote! { #environment #predicates #(#arg_types)* #(#returned)* })
    };
    let declare = |environment: &mut syn::Generics, lifetime: &syn::Lifetime| {
        environment
            .params
            .push(syn::GenericParam::Lifetime(syn::LifetimeParam::new(
                lifetime.clone(),
            )));
        environment.lt_token.get_or_insert_with(Default::default);
        environment.gt_token.get_or_insert_with(Default::default);
    };

    let lifetime = match receiver {
        SelfBorrow::Ref(Some(named)) => named.clone(),
        SelfBorrow::Ref(None) => {
            declare(environment, &fresh);
            fresh
        }
        SelfBorrow::None => {
            let mut elided: Vec<(usize, Span)> = Vec::new();
            let mut named: BTreeSet<String> = BTreeSet::new();
            for (i, (_, ty)) in args.iter().enumerate() {
                let (spans, names) = positions(&mut ty.clone(), None);
                elided.extend(spans.into_iter().map(|s| (i, s)));
                named.extend(names);
            }
            match (elided.as_slice(), named.len()) {
                ([], 1) => {
                    let name = named.into_iter().next().expect("one name");
                    syn::Lifetime::new(&format!("'{name}"), Span::call_site())
                }
                ([(i, span)], 0) => {
                    let (arg, ty) = &mut args[*i];
                    if is_str_ref_type(ty) {
                        let msg = format!(
                            "`{julia_name}`: the returned reference borrows from argument `{arg}` \
                             by lifetime elision, but `{arg}` arrives from Julia as a pointer and \
                             a length and is rebuilt into a string that lives only for the call, \
                             so nothing borrowed from it can be returned. Return an owned value, \
                             or give the returned reference a lifetime that does not come from \
                             `{arg}` (#484)."
                        );
                        let span = *span;
                        return ElidedReturn::Refused(
                            quote_spanned! {span=> compile_error!(#msg); },
                        );
                    }
                    name_elided_lifetimes(ty, &fresh);
                    declare(environment, &fresh);
                    fresh
                }
                // No lifetime is visible in the arguments: the item's is one
                // hidden in a path (`w: Wrapper` for `Wrapper<'a>`), or it has
                // none and its own signature is E0106. The wrapper passes every
                // such argument through as written, so elision on the wrapper
                // decides exactly as it does on the item.
                ([], 0) => return ElidedReturn::Named,
                _ => return ElidedReturn::Undecidable,
            }
        }
    };
    for ty in returned {
        name_elided_lifetimes(ty, &lifetime);
    }
    ElidedReturn::Named
}
