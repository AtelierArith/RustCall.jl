//! `#[cfg(...)]` evaluation.
//!
//! Items that are disabled by a `#[cfg]` predicate are not compiled by rustc,
//! so they must not be reported as exported in the manifest. The active
//! configuration comes from `rustc --print cfg` (see [`CfgSet::parse`]); the
//! evaluator supports the standard predicate grammar: `name`, `name = "value"`,
//! `all(...)`, `any(...)`, `not(...)`.
//!
//! When no configuration is supplied every item is considered active and the
//! predicate is only recorded in the manifest (`cfg` field).
//!
//! A *lenient* set decides only the predicates that follow from the target
//! (`unix`, `windows`, `target_*`); everything else (`feature = "..."`,
//! build-script `--cfg`s, profile-dependent `debug_assertions`, `panic`) is
//! unknown and keeps the item. It is meant for an external crate whose own
//! features and build script the caller does not control (`@rust_crate`).
//! When the caller generates the crate itself and probes Cargo for the
//! effective configuration, the probe is authoritative and the full (strict)
//! set applies.

use std::collections::HashSet;

use syn::{Attribute, Item, Meta};

/// The set of active configuration options of a rustc target.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct CfgSet {
    names: HashSet<String>,
    pairs: HashSet<(String, String)>,
    /// Only target-derived predicates are decidable; others are unknown.
    lenient: bool,
}

/// Three-valued predicate result.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Truth {
    True,
    False,
    Unknown,
}

impl Truth {
    fn from_bool(b: bool) -> Truth {
        if b {
            Truth::True
        } else {
            Truth::False
        }
    }

    fn not(self) -> Truth {
        match self {
            Truth::True => Truth::False,
            Truth::False => Truth::True,
            Truth::Unknown => Truth::Unknown,
        }
    }

    /// Items with an unknown predicate are kept (reported).
    pub fn keeps_item(self) -> bool {
        !matches!(self, Truth::False)
    }
}

/// The built-in cfg names decided by the compilation target alone (rustc
/// reference, "Set configuration options"). A build script may emit any other
/// name, including `target_custom`, so the list is closed rather than a prefix.
/// `target_feature` is deliberately absent: it depends on codegen options
/// (`-C target-feature`, `RUSTFLAGS`) that Cargo may add.
const TARGET_CFG_NAMES: &[&str] = &[
    "unix",
    "windows",
    "target_abi",
    "target_arch",
    "target_endian",
    "target_env",
    "target_family",
    "target_has_atomic",
    "target_has_atomic_equal_alignment",
    "target_has_atomic_load_store",
    "target_os",
    "target_pointer_width",
    "target_thread_local",
    "target_vendor",
];

/// Safety net for [`CfgSet::expand_cfg_attrs`]: `cfg_attr` nested deeper than
/// this is rejected rather than partially expanded.
const CFG_ATTR_MAX_DEPTH: usize = 64;

fn target_decided(name: &str) -> bool {
    TARGET_CFG_NAMES.contains(&name)
}

impl CfgSet {
    /// Parse the output of `rustc --print cfg`: one option per line, either
    /// `name` or `name="value"`. Blank lines are ignored.
    ///
    /// The value is a Rust string literal (rustc prints it with `{:?}`) and is
    /// unescaped exactly once, so `custom="\"quoted\""` records the value
    /// `"quoted"` (with the quotes) and stays distinct from `custom="quoted"`.
    /// A right-hand side that is not a string literal is an error.
    pub fn parse(text: &str) -> Result<CfgSet, String> {
        let mut set = CfgSet::default();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            match line.split_once('=') {
                Some((name, value)) => {
                    let lit: syn::LitStr = syn::parse_str(value.trim()).map_err(|e| {
                        format!("malformed cfg line `{line}`: value is not a string literal ({e})")
                    })?;
                    set.pairs.insert((name.trim().to_string(), lit.value()));
                }
                None => {
                    set.names.insert(line.to_string());
                }
            }
        }
        Ok(set)
    }

    pub fn with_name(mut self, name: &str) -> CfgSet {
        self.names.insert(name.to_string());
        self
    }

    pub fn with_pair(mut self, name: &str, value: &str) -> CfgSet {
        self.pairs.insert((name.to_string(), value.to_string()));
        self
    }

    /// Decide only target-derived predicates; see the module docs.
    pub fn lenient(mut self) -> CfgSet {
        self.lenient = true;
        self
    }

    pub fn is_lenient(&self) -> bool {
        self.lenient
    }

    fn decided(&self, name: &str) -> bool {
        !self.lenient || target_decided(name)
    }

    /// Evaluate one `cfg` predicate to a boolean; `Unknown` counts as true
    /// (the item is kept). Prefer [`CfgSet::eval3`] when the distinction matters.
    pub fn eval(&self, meta: &Meta) -> Result<bool, String> {
        Ok(self.eval3(meta)?.keeps_item())
    }

    fn lookup_name(&self, name: &str) -> Truth {
        if !self.decided(name) {
            return Truth::Unknown;
        }
        Truth::from_bool(self.names.contains(name))
    }

    fn lookup_pair(&self, name: &str, value: &str) -> Truth {
        if !self.decided(name) {
            return Truth::Unknown;
        }
        Truth::from_bool(self.pairs.contains(&(name.to_string(), value.to_string())))
    }

    /// Evaluate one `cfg` predicate (the meta inside `#[cfg(...)]`).
    pub fn eval3(&self, meta: &Meta) -> Result<Truth, String> {
        match meta {
            Meta::Path(path) => {
                let name = path
                    .get_ident()
                    .ok_or_else(|| format!("unsupported cfg predicate `{}`", quote::quote!(#path)))?
                    .to_string();
                Ok(self.lookup_name(&name))
            }
            Meta::NameValue(nv) => {
                let name = nv
                    .path
                    .get_ident()
                    .ok_or_else(|| format!("unsupported cfg predicate `{}`", quote::quote!(#nv)))?
                    .to_string();
                let value = match &nv.value {
                    syn::Expr::Lit(syn::ExprLit {
                        lit: syn::Lit::Str(s),
                        ..
                    }) => s.value(),
                    other => {
                        return Err(format!(
                            "unsupported cfg value `{}` for `{name}`",
                            quote::quote!(#other)
                        ))
                    }
                };
                Ok(self.lookup_pair(&name, &value))
            }
            Meta::List(list) => {
                let op = list
                    .path
                    .get_ident()
                    .map(|i| i.to_string())
                    .ok_or_else(|| {
                        format!("unsupported cfg predicate `{}`", quote::quote!(#list))
                    })?;
                let nested = list
                    .parse_args_with(
                        syn::punctuated::Punctuated::<Meta, syn::Token![,]>::parse_terminated,
                    )
                    .map_err(|e| format!("cannot parse cfg predicate `{op}(...)`: {e}"))?;
                match op.as_str() {
                    "all" => {
                        let mut out = Truth::True;
                        for m in &nested {
                            match self.eval3(m)? {
                                Truth::False => return Ok(Truth::False),
                                Truth::Unknown => out = Truth::Unknown,
                                Truth::True => {}
                            }
                        }
                        Ok(out)
                    }
                    "any" => {
                        let mut out = Truth::False;
                        for m in &nested {
                            match self.eval3(m)? {
                                Truth::True => return Ok(Truth::True),
                                Truth::Unknown => out = Truth::Unknown,
                                Truth::False => {}
                            }
                        }
                        Ok(out)
                    }
                    "not" => {
                        if nested.len() != 1 {
                            return Err("`not(...)` takes exactly one predicate".to_string());
                        }
                        Ok(self.eval3(&nested[0])?.not())
                    }
                    other => Err(format!("unsupported cfg predicate `{other}(...)`")),
                }
            }
        }
    }

    /// Whether an item with these attributes is kept: no `#[cfg(...)]` may be
    /// false (unknown predicates keep the item). Predicates that cannot be
    /// parsed are reported through `Err` (fail closed).
    pub fn attrs_active(&self, attrs: &[Attribute]) -> Result<bool, String> {
        for attr in attrs {
            if let Some(meta) = cfg_predicate(attr) {
                if !self.eval3(&meta)?.keeps_item() {
                    return Ok(false);
                }
            }
        }
        Ok(true)
    }

    /// Expand `#[cfg_attr(pred, a, b, ...)]` in place: a true predicate is
    /// replaced by its attributes (recursively), a false one is dropped, an
    /// unknown one is kept verbatim (its item is neither pruned nor changed;
    /// rustc decides). Returns predicates that could not be evaluated.
    ///
    /// Expansion repeats until a pass changes nothing, so any nesting depth is
    /// handled. A hard limit remains as a safety net; reaching it is an error
    /// (fail closed), never a silent partial expansion that would leave a
    /// `cfg_attr` unseen by [`CfgSet::attrs_active`].
    pub fn expand_cfg_attrs(&self, attrs: &mut Vec<Attribute>) -> Vec<String> {
        let mut errors = Vec::new();
        // Each round removes at least one `cfg_attr` level.
        for round in 0..=CFG_ATTR_MAX_DEPTH {
            if round == CFG_ATTR_MAX_DEPTH {
                errors.push(format!(
                    "`cfg_attr` nested deeper than {CFG_ATTR_MAX_DEPTH} levels"
                ));
                break;
            }
            let mut changed = false;
            let mut out: Vec<Attribute> = Vec::with_capacity(attrs.len());
            for attr in attrs.drain(..) {
                let Some((pred, inner)) = cfg_attr_parts(&attr) else {
                    out.push(attr);
                    continue;
                };
                match self.eval3(&pred) {
                    Ok(Truth::True) => {
                        changed = true;
                        for meta in inner {
                            out.push(syn::parse_quote!(#[#meta]));
                        }
                    }
                    Ok(Truth::False) => changed = true,
                    Ok(Truth::Unknown) => out.push(attr),
                    Err(e) => {
                        errors.push(e);
                        changed = true;
                    }
                }
            }
            *attrs = out;
            if !changed {
                break;
            }
        }
        errors
    }

    /// Drop the `#[cfg(...)]` attributes this configuration decided to be true.
    /// The item stays, but its presence no longer depends on a predicate that
    /// was already resolved, so the expanded source compiles the same way under
    /// a different rustc invocation (a Cargo build, or the direct `rustc` run
    /// that later instantiates a generic). Undecided predicates are kept.
    fn strip_decided_cfgs(&self, attrs: &mut Vec<Attribute>) {
        attrs.retain(|attr| match cfg_predicate(attr) {
            Some(meta) => !matches!(self.eval3(&meta), Ok(Truth::True)),
            None => true,
        });
    }

    /// Remove the function parameters disabled under this configuration.
    ///
    /// A parameter carries its own attributes (`fn f(a: i32, #[cfg(any())] b: i32)`),
    /// which rustc evaluates like any other `#[cfg]`. They must be pruned too:
    /// otherwise the manifest reports an argument the compiled function does not
    /// take and the generated wrapper has the wrong C ABI. `cfg_attr` is expanded
    /// first and predicates decided to be true are stripped, exactly as for items.
    /// Unevaluable predicates are pushed to `errors` (the caller fails closed).
    fn prune_signature(&self, sig: &mut syn::Signature, errors: &mut Vec<String>) {
        let mut kept: syn::punctuated::Punctuated<syn::FnArg, syn::Token![,]> =
            syn::punctuated::Punctuated::new();
        for arg in sig.inputs.iter() {
            let mut arg = arg.clone();
            let attrs = match &mut arg {
                syn::FnArg::Receiver(r) => &mut r.attrs,
                syn::FnArg::Typed(t) => &mut t.attrs,
            };
            let errs = self.expand_cfg_attrs(attrs);
            if !errs.is_empty() {
                errors.extend(errs);
                continue;
            }
            match self.attrs_active(attrs) {
                Ok(true) => {
                    self.strip_decided_cfgs(attrs);
                    kept.push(arg);
                }
                Ok(false) => {}
                Err(e) => errors.push(e),
            }
        }
        sig.inputs = kept;
        self.prune_generics(&mut sig.generics, errors);
    }

    /// Remove the generic parameters (`<#[cfg(any())] T, 'a, const N: usize>`)
    /// disabled under this configuration, with the same `cfg_attr` expansion,
    /// stripping and fail-closed rules as [`CfgSet::prune_signature`]. rustc
    /// drops such a parameter, so reporting it would break Julia's inference
    /// and specialization of the generic.
    fn prune_generics(&self, generics: &mut syn::Generics, errors: &mut Vec<String>) {
        let mut kept: syn::punctuated::Punctuated<syn::GenericParam, syn::Token![,]> =
            syn::punctuated::Punctuated::new();
        for param in generics.params.iter() {
            let mut param = param.clone();
            let attrs = match &mut param {
                syn::GenericParam::Lifetime(l) => &mut l.attrs,
                syn::GenericParam::Type(t) => &mut t.attrs,
                syn::GenericParam::Const(c) => &mut c.attrs,
            };
            let errs = self.expand_cfg_attrs(attrs);
            if !errs.is_empty() {
                errors.extend(errs);
                continue;
            }
            match self.attrs_active(attrs) {
                Ok(true) => {
                    self.strip_decided_cfgs(attrs);
                    kept.push(param);
                }
                Ok(false) => {}
                Err(e) => errors.push(e),
            }
        }
        generics.params = kept;
    }

    /// Remove every item, impl item and named struct field disabled under this
    /// configuration, and drop the predicates that were decided to be true (see
    /// [`CfgSet::strip_decided_cfgs`]). Inline modules are pruned recursively.
    /// `cfg_attr` is expanded first so indirectly disabled items are pruned too.
    /// Returns the predicates that could not be evaluated (their items are removed).
    pub fn prune_items(&self, items: &mut Vec<Item>) -> Vec<String> {
        let mut errors = Vec::new();
        items.retain_mut(|item| {
            if let Some(attrs) = item_attrs_mut(item) {
                let errs = self.expand_cfg_attrs(attrs);
                if !errs.is_empty() {
                    errors.extend(errs);
                    return false;
                }
            }
            let attrs = item_attrs(item);
            match self.attrs_active(attrs) {
                Ok(true) => {}
                Ok(false) => return false,
                Err(e) => {
                    errors.push(e);
                    return false;
                }
            }
            if let Some(attrs) = item_attrs_mut(item) {
                self.strip_decided_cfgs(attrs);
            }
            match item {
                Item::Fn(f) => self.prune_signature(&mut f.sig, &mut errors),
                Item::Mod(m) => {
                    if let Some((_, inner)) = &mut m.content {
                        errors.extend(self.prune_items(inner));
                    }
                }
                Item::Enum(e) => self.prune_generics(&mut e.generics, &mut errors),
                Item::Trait(t) => self.prune_generics(&mut t.generics, &mut errors),
                Item::Impl(imp) => {
                    self.prune_generics(&mut imp.generics, &mut errors);
                    imp.items.retain_mut(|ii| {
                        let attrs = match ii {
                            syn::ImplItem::Fn(f) => &mut f.attrs,
                            syn::ImplItem::Const(c) => &mut c.attrs,
                            syn::ImplItem::Type(t) => &mut t.attrs,
                            syn::ImplItem::Macro(m) => &mut m.attrs,
                            _ => return true,
                        };
                        let errs = self.expand_cfg_attrs(attrs);
                        if !errs.is_empty() {
                            errors.extend(errs);
                            return false;
                        }
                        match self.attrs_active(attrs) {
                            Ok(true) => {
                                self.strip_decided_cfgs(attrs);
                                if let syn::ImplItem::Fn(f) = ii {
                                    self.prune_signature(&mut f.sig, &mut errors);
                                }
                                true
                            }
                            Ok(false) => false,
                            Err(e) => {
                                errors.push(e);
                                false
                            }
                        }
                    });
                }
                Item::Struct(s) => {
                    self.prune_generics(&mut s.generics, &mut errors);
                    if let syn::Fields::Named(named) = &mut s.fields {
                        let mut kept = syn::punctuated::Punctuated::new();
                        for field in named.named.iter() {
                            let mut field = field.clone();
                            let errs = self.expand_cfg_attrs(&mut field.attrs);
                            if !errs.is_empty() {
                                errors.extend(errs);
                                continue;
                            }
                            match self.attrs_active(&field.attrs) {
                                Ok(true) => {
                                    self.strip_decided_cfgs(&mut field.attrs);
                                    kept.push(field)
                                }
                                Ok(false) => {}
                                Err(e) => errors.push(e),
                            }
                        }
                        named.named = kept;
                    }
                }
                _ => {}
            }
            true
        });
        errors
    }

    /// Evaluate the crate-level inner attributes of a file (`#![cfg(...)]`,
    /// `#![cfg_attr(...)]`). `Ok(false)` means the whole crate is disabled, so
    /// rustc compiles nothing and nothing may be reported. `cfg_attr` is
    /// expanded first and predicates decided to be true are stripped, exactly
    /// as for items. Unevaluable predicates are returned (fail closed).
    pub fn file_active(&self, attrs: &mut Vec<Attribute>) -> Result<bool, Vec<String>> {
        let errors = self.expand_cfg_attrs(attrs);
        if !errors.is_empty() {
            return Err(errors);
        }
        match self.attrs_active(attrs) {
            Ok(true) => {
                self.strip_decided_cfgs(attrs);
                Ok(true)
            }
            Ok(false) => Ok(false),
            Err(e) => Err(vec![e]),
        }
    }
}

/// Evaluate a file's crate-level `#[cfg]` before pruning its items: a crate
/// disabled by `#![cfg(...)]` compiles to nothing, so its items must be
/// dropped instead of reported as exported.
pub fn prune_file_or_error(set: &CfgSet, file: &mut syn::File) -> Result<(), syn::Error> {
    match set.file_active(&mut file.attrs) {
        Ok(true) => prune_or_error(set, &mut file.items),
        Ok(false) => {
            file.items.clear();
            Ok(())
        }
        Err(errors) => Err(cfg_error(&errors)),
    }
}

fn cfg_error(errors: &[String]) -> syn::Error {
    syn::Error::new(
        proc_macro2::Span::call_site(),
        format!("cannot evaluate #[cfg] predicate: {}", errors.join("; ")),
    )
}

/// Prune `items` and turn unevaluable predicates into a `syn::Error` so the
/// extractor fails closed instead of reporting guessed availability.
pub fn prune_or_error(set: &CfgSet, items: &mut Vec<Item>) -> Result<(), syn::Error> {
    let errors = set.prune_items(items);
    if errors.is_empty() {
        Ok(())
    } else {
        Err(cfg_error(&errors))
    }
}

/// Whether a function body contains a `#[cfg(...)]` / `#[cfg_attr(...)]`
/// attribute (on a statement, expression, local, nested item, ...) or a
/// `cfg!(...)` macro. Such a body still depends on the configuration it is
/// compiled under even after item-level pruning (see `Function::body_has_cfg`).
pub fn body_has_cfg(block: &syn::Block) -> bool {
    struct Finder {
        found: bool,
    }
    impl<'ast> syn::visit::Visit<'ast> for Finder {
        fn visit_attribute(&mut self, attr: &'ast Attribute) {
            if attr.path().is_ident("cfg") || attr.path().is_ident("cfg_attr") {
                self.found = true;
            }
            syn::visit::visit_attribute(self, attr);
        }
        fn visit_macro(&mut self, mac: &'ast syn::Macro) {
            if mac.path.segments.last().is_some_and(|s| s.ident == "cfg") {
                self.found = true;
            }
            syn::visit::visit_macro(self, mac);
        }
    }
    let mut finder = Finder { found: false };
    syn::visit::Visit::visit_block(&mut finder, block);
    finder.found
}

/// `(predicate, attributes)` of a `#[cfg_attr(pred, a, b)]` attribute.
pub fn cfg_attr_parts(attr: &Attribute) -> Option<(Meta, Vec<Meta>)> {
    if !attr.path().is_ident("cfg_attr") {
        return None;
    }
    let Meta::List(list) = &attr.meta else {
        return None;
    };
    let nested = list
        .parse_args_with(syn::punctuated::Punctuated::<Meta, syn::Token![,]>::parse_terminated)
        .ok()?;
    let mut iter = nested.into_iter();
    let pred = iter.next()?;
    Some((pred, iter.collect()))
}

/// The meta of a `#[cfg(...)]` attribute, if `attr` is one.
pub fn cfg_predicate(attr: &Attribute) -> Option<Meta> {
    if !attr.path().is_ident("cfg") {
        return None;
    }
    match &attr.meta {
        Meta::List(list) => list.parse_args::<Meta>().ok(),
        _ => None,
    }
}

/// The attributes that decide whether an item is compiled: its `#[cfg(...)]`
/// attributes and the `#[cfg_attr(...)]` attributes that can expand to one.
///
/// Code generation copies these onto every item it derives from a function
/// (the `CResult`/`COption` type, its accessor impl, the inner fn), so all of
/// them appear or disappear together. A `cfg_attr` counts only for the part
/// that produces a `cfg`: `#[cfg_attr(p, cfg(any()), allow(dead_code))]`
/// contributes `#[cfg_attr(p, cfg(any()))]`, so unrelated attributes are not
/// duplicated onto the generated items.
pub fn cfg_attrs(attrs: &[Attribute]) -> Vec<Attribute> {
    attrs
        .iter()
        .filter_map(|a| {
            if a.path().is_ident("cfg") {
                return Some(a.clone());
            }
            let meta = cfg_producing_meta(&a.meta)?;
            Some(syn::parse_quote!(#[#meta]))
        })
        .collect()
}

/// The part of a `cfg_attr(...)` meta that can expand to a `#[cfg(...)]`,
/// with the attributes that cannot dropped. `None` when there is none (or the
/// meta is not a `cfg_attr`).
fn cfg_producing_meta(meta: &Meta) -> Option<Meta> {
    let Meta::List(list) = meta else {
        return None;
    };
    if list.path.is_ident("cfg") {
        return Some(meta.clone());
    }
    if !list.path.is_ident("cfg_attr") {
        return None;
    }
    let nested = list
        .parse_args_with(syn::punctuated::Punctuated::<Meta, syn::Token![,]>::parse_terminated)
        .ok()?;
    let mut iter = nested.into_iter();
    let pred = iter.next()?;
    let kept: Vec<Meta> = iter.filter_map(|m| cfg_producing_meta(&m)).collect();
    if kept.is_empty() {
        return None;
    }
    Some(syn::parse_quote!(cfg_attr(#pred, #(#kept),*)))
}

/// The combined predicate text of an item's `#[cfg(...)]` attributes
/// (`unix`, `all(unix, feature = "x")`), empty when there is none.
pub fn predicate_string(attrs: &[Attribute]) -> String {
    let preds: Vec<String> = attrs
        .iter()
        .filter_map(cfg_predicate)
        .map(|m| meta_to_string(&m))
        .collect();
    match preds.len() {
        0 => String::new(),
        1 => preds.into_iter().next().unwrap_or_default(),
        _ => format!("all({})", preds.join(", ")),
    }
}

/// Canonical text of a cfg predicate: `unix`, `feature = "x"`, `all(a, b)`.
/// (`quote` would insert spaces between every token.)
/// The crate features an item's `#[cfg(...)]` predicates depend on, in the
/// order they appear and without duplicates.
///
/// `#[cfg(all(unix, feature = "python"))]` yields `["python"]`. A consumer can
/// then ask "does this item exist when feature X is off?" by set membership,
/// without handling Rust `cfg` syntax itself — which only this crate does
/// (#264). Used by #275 to reconcile the PyO3 scan with the feature set a
/// wrapper crate would actually build under.
pub fn predicate_features(attrs: &[Attribute]) -> Vec<String> {
    let mut out = Vec::new();
    for attr in attrs {
        if let Some(meta) = cfg_predicate(attr) {
            collect_features(&meta, &mut out);
        }
    }
    out
}

fn collect_features(meta: &Meta, out: &mut Vec<String>) {
    match meta {
        Meta::NameValue(nv) => {
            if nv.path.is_ident("feature") {
                if let syn::Expr::Lit(syn::ExprLit {
                    lit: syn::Lit::Str(s),
                    ..
                }) = &nv.value
                {
                    let value = s.value();
                    if !out.contains(&value) {
                        out.push(value);
                    }
                }
            }
        }
        Meta::List(list) => {
            if let Ok(nested) = list.parse_args_with(
                syn::punctuated::Punctuated::<Meta, syn::Token![,]>::parse_terminated,
            ) {
                for inner in nested.iter() {
                    collect_features(inner, out);
                }
            }
        }
        Meta::Path(_) => {}
    }
}

pub fn meta_to_string(meta: &Meta) -> String {
    match meta {
        Meta::Path(path) => path
            .segments
            .iter()
            .map(|s| s.ident.to_string())
            .collect::<Vec<_>>()
            .join("::"),
        Meta::NameValue(nv) => {
            let name = meta_to_string(&Meta::Path(nv.path.clone()));
            let value = &nv.value;
            match value {
                syn::Expr::Lit(syn::ExprLit {
                    lit: syn::Lit::Str(s),
                    ..
                }) => format!("{name} = {:?}", s.value()),
                other => format!("{name} = {}", quote::quote!(#other)),
            }
        }
        Meta::List(list) => {
            let op = meta_to_string(&Meta::Path(list.path.clone()));
            match list.parse_args_with(
                syn::punctuated::Punctuated::<Meta, syn::Token![,]>::parse_terminated,
            ) {
                Ok(nested) => format!(
                    "{op}({})",
                    nested
                        .iter()
                        .map(meta_to_string)
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
                Err(_) => format!("{op}({})", list.tokens),
            }
        }
    }
}

fn item_attrs_mut(item: &mut Item) -> Option<&mut Vec<Attribute>> {
    Some(match item {
        Item::Const(i) => &mut i.attrs,
        Item::Enum(i) => &mut i.attrs,
        Item::ExternCrate(i) => &mut i.attrs,
        Item::Fn(i) => &mut i.attrs,
        Item::ForeignMod(i) => &mut i.attrs,
        Item::Impl(i) => &mut i.attrs,
        Item::Macro(i) => &mut i.attrs,
        Item::Mod(i) => &mut i.attrs,
        Item::Static(i) => &mut i.attrs,
        Item::Struct(i) => &mut i.attrs,
        Item::Trait(i) => &mut i.attrs,
        Item::TraitAlias(i) => &mut i.attrs,
        Item::Type(i) => &mut i.attrs,
        Item::Union(i) => &mut i.attrs,
        Item::Use(i) => &mut i.attrs,
        _ => return None,
    })
}

fn item_attrs(item: &Item) -> &[Attribute] {
    match item {
        Item::Const(i) => &i.attrs,
        Item::Enum(i) => &i.attrs,
        Item::ExternCrate(i) => &i.attrs,
        Item::Fn(i) => &i.attrs,
        Item::ForeignMod(i) => &i.attrs,
        Item::Impl(i) => &i.attrs,
        Item::Macro(i) => &i.attrs,
        Item::Mod(i) => &i.attrs,
        Item::Static(i) => &i.attrs,
        Item::Struct(i) => &i.attrs,
        Item::Trait(i) => &i.attrs,
        Item::TraitAlias(i) => &i.attrs,
        Item::Type(i) => &i.attrs,
        Item::Union(i) => &i.attrs,
        Item::Use(i) => &i.attrs,
        _ => &[],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pred(s: &str) -> Meta {
        syn::parse_str(s).expect("valid meta")
    }

    #[test]
    fn parses_rustc_print_cfg() {
        let set =
            CfgSet::parse("debug_assertions\npanic=\"unwind\"\ntarget_os=\"macos\"\n\nunix\n")
                .unwrap();
        assert!(set.eval(&pred("unix")).unwrap());
        assert!(set.eval(&pred("debug_assertions")).unwrap());
        assert!(set.eval(&pred("target_os = \"macos\"")).unwrap());
        assert!(!set.eval(&pred("target_os = \"linux\"")).unwrap());
        assert!(!set.eval(&pred("windows")).unwrap());
    }

    #[test]
    fn parses_values_as_string_literals() {
        // rustc prints values with `{:?}`: escapes are decoded exactly once.
        let set = CfgSet::parse(
            "plain=\"x\"\nquoted=\"\\\"q\\\"\"\nescaped=\"a\\\\b\\n\"\ntarget_feature=\"sse4.2\"\n",
        )
        .unwrap();
        assert_eq!(set.eval3(&pred("plain = \"x\"")).unwrap(), Truth::True);
        // The recorded value keeps its literal quote characters ...
        assert_eq!(
            set.eval3(&pred("quoted = \"\\\"q\\\"\"")).unwrap(),
            Truth::True
        );
        // ... and is not conflated with the unquoted value.
        assert_eq!(set.eval3(&pred("quoted = \"q\"")).unwrap(), Truth::False);
        assert_eq!(
            set.eval3(&pred("escaped = \"a\\\\b\\n\"")).unwrap(),
            Truth::True
        );
        assert_eq!(
            set.eval3(&pred("escaped = \"a\\\\\\\\b\\\\n\"")).unwrap(),
            Truth::False
        );
        assert_eq!(
            set.eval3(&pred("target_feature = \"sse4.2\"")).unwrap(),
            Truth::True
        );
        // Not a string literal: fail rather than guess.
        assert!(CfgSet::parse("custom=\"\"quoted\"\"").is_err());
        assert!(CfgSet::parse("custom=quoted").is_err());
        assert!(CfgSet::parse("custom=\"unterminated").is_err());
    }

    #[test]
    fn evaluates_combinators() {
        let set = CfgSet::default()
            .with_name("unix")
            .with_pair("feature", "fast");
        assert!(set.eval(&pred("all(unix, feature = \"fast\")")).unwrap());
        assert!(!set.eval(&pred("all(unix, feature = \"slow\")")).unwrap());
        assert!(set.eval(&pred("any(windows, unix)")).unwrap());
        assert!(!set.eval(&pred("any()")).unwrap());
        assert!(set.eval(&pred("all()")).unwrap());
        assert!(set.eval(&pred("not(windows)")).unwrap());
        assert!(!set.eval(&pred("not(unix)")).unwrap());
        assert!(set
            .eval(&pred("not(any(windows, feature = \"slow\"))"))
            .unwrap());
    }

    #[test]
    fn lenient_sets_decide_only_target_predicates() {
        let set = CfgSet::default()
            .with_name("unix")
            .with_name("debug_assertions")
            .lenient();
        assert_eq!(set.eval3(&pred("unix")).unwrap(), Truth::True);
        assert_eq!(set.eval3(&pred("windows")).unwrap(), Truth::False);
        assert_eq!(set.eval3(&pred("feature = \"x\"")).unwrap(), Truth::Unknown);
        assert_eq!(
            set.eval3(&pred("debug_assertions")).unwrap(),
            Truth::Unknown
        );
        assert_eq!(
            set.eval3(&pred("all(unix, feature = \"x\")")).unwrap(),
            Truth::Unknown
        );
        assert_eq!(
            set.eval3(&pred("all(windows, feature = \"x\")")).unwrap(),
            Truth::False
        );
        assert_eq!(
            set.eval3(&pred("any(unix, feature = \"x\")")).unwrap(),
            Truth::True
        );
        assert_eq!(
            set.eval3(&pred("any(windows, feature = \"x\")")).unwrap(),
            Truth::Unknown
        );
        assert_eq!(
            set.eval3(&pred("not(feature = \"x\")")).unwrap(),
            Truth::Unknown
        );
        // Build scripts may emit arbitrary names, even with a `target_` prefix.
        assert_eq!(set.eval3(&pred("target_custom")).unwrap(), Truth::Unknown);
        // `-C target-feature` / RUSTFLAGS can enable features Cargo-side.
        assert_eq!(
            set.eval3(&pred("target_feature = \"avx2\"")).unwrap(),
            Truth::Unknown
        );
        assert_eq!(
            set.eval3(&pred("target_os = \"linux\"")).unwrap(),
            Truth::False
        );
        // Unknown keeps the item.
        assert!(set.eval(&pred("feature = \"x\"")).unwrap());
        assert!(!set.eval(&pred("windows")).unwrap());
    }

    #[test]
    fn rejects_unknown_predicates() {
        let set = CfgSet::default();
        assert!(set.eval(&pred("version(\"1.0\")")).is_err());
        assert!(set.eval(&pred("not(a, b)")).is_err());
    }

    #[test]
    fn prunes_items_recursively() {
        let mut file: syn::File = syn::parse_str(
            r#"
            #[cfg(unix)] pub fn keep() {}
            #[cfg(windows)] pub fn drop_me() {}
            #[cfg(unix)] #[cfg(feature = "x")] pub fn drop_two() {}
            pub struct S { a: i32, #[cfg(windows)] b: i32 }
            impl S { pub fn m(&self) {} #[cfg(windows)] pub fn win(&self) {} }
            mod inner { #[cfg(windows)] pub fn gone() {} pub fn stays() {} }
            #[cfg(windows)] mod winonly { pub fn f() {} }
            "#,
        )
        .unwrap();
        let set = CfgSet::default().with_name("unix");
        let errors = set.prune_items(&mut file.items);
        assert!(errors.is_empty(), "{errors:?}");
        let text = prettyplease::unparse(&file);
        assert!(text.contains("fn keep"));
        // The decided predicate is gone from the kept item.
        assert!(!text.contains("#[cfg(unix)]"), "{text}");
        assert!(!text.contains("drop_me"));
        assert!(!text.contains("drop_two"));
        assert!(text.contains("a: i32"));
        assert!(!text.contains("b: i32"));
        assert!(text.contains("fn m("));
        assert!(!text.contains("fn win"));
        assert!(text.contains("fn stays"));
        assert!(!text.contains("gone"));
        assert!(!text.contains("winonly"));
    }

    #[test]
    fn expands_cfg_attr_before_pruning() {
        let mut file: syn::File = syn::parse_str(
            r#"
            #[cfg_attr(unix, cfg(any()))] pub fn indirectly_off() {}
            #[cfg_attr(windows, cfg(any()))] pub fn stays_on() {}
            #[cfg_attr(unix, cfg(all()), allow(dead_code))] pub fn on_with_attrs() {}
            #[cfg_attr(feature = "x", cfg(any()))] pub fn unknown_kept() {}
            #[cfg_attr(unix, cfg_attr(unix, cfg(any())))] pub fn nested_off() {}
            pub struct S { #[cfg_attr(unix, cfg(any()))] a: i32, b: i32 }
            impl S { #[cfg_attr(unix, cfg(any()))] pub fn m(&self) {} pub fn n(&self) {} }
            "#,
        )
        .unwrap();
        let set = CfgSet::default().with_name("unix").lenient();
        let errors = set.prune_items(&mut file.items);
        assert!(errors.is_empty(), "{errors:?}");
        let text = prettyplease::unparse(&file);
        assert!(!text.contains("indirectly_off"));
        assert!(text.contains("stays_on"));
        assert!(text.contains("on_with_attrs"));
        assert!(text.contains("unknown_kept") && text.contains("cfg_attr(feature = \"x\""));
        // A decided `cfg_attr` inlines its attributes; `cfg(all())` is decided
        // true and therefore dropped, the other attribute stays.
        assert!(text.contains("#[allow(dead_code)]") && !text.contains("#[cfg(all())]"));
        assert!(!text.contains("nested_off"));
        assert!(!text.contains("a: i32") && text.contains("b: i32"));
        assert!(!text.contains("fn m(") && text.contains("fn n("));
    }

    #[test]
    fn predicate_string_joins_multiple_cfgs() {
        let f: syn::ItemFn =
            syn::parse_str("#[cfg(unix)] #[doc = \"x\"] #[cfg(feature = \"a\")] fn f() {}")
                .unwrap();
        assert_eq!(predicate_string(&f.attrs), "all(unix, feature = \"a\")");
        let g: syn::ItemFn = syn::parse_str("fn g() {}").unwrap();
        assert_eq!(predicate_string(&g.attrs), "");
    }
}
