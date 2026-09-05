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
//! unknown and keeps the item. Cargo builds (crate mode, `// cargo-deps:`
//! blocks) use it because their cfg set is decided by Cargo, not by a bare
//! `rustc --print cfg`.

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

fn target_decided(name: &str) -> bool {
    TARGET_CFG_NAMES.contains(&name)
}

impl CfgSet {
    /// Parse the output of `rustc --print cfg`: one option per line, either
    /// `name` or `name="value"`. Blank lines are ignored.
    pub fn parse(text: &str) -> CfgSet {
        let mut set = CfgSet::default();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            match line.split_once('=') {
                Some((name, value)) => {
                    let value = value.trim().trim_matches('"');
                    set.pairs
                        .insert((name.trim().to_string(), value.to_string()));
                }
                None => {
                    set.names.insert(line.to_string());
                }
            }
        }
        set
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

    /// Evaluate one `cfg` predicate to a boolean; `Unknown` counts as true
    /// (the item is kept). Prefer [`CfgSet::eval3`] when the distinction matters.
    pub fn eval(&self, meta: &Meta) -> Result<bool, String> {
        Ok(self.eval3(meta)?.keeps_item())
    }

    fn lookup_name(&self, name: &str) -> Truth {
        if self.lenient && !target_decided(name) {
            return Truth::Unknown;
        }
        Truth::from_bool(self.names.contains(name))
    }

    fn lookup_pair(&self, name: &str, value: &str) -> Truth {
        if self.lenient && !target_decided(name) {
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

    /// Remove every item, impl item and named struct field disabled under this
    /// configuration. Inline modules are pruned recursively. Returns the
    /// predicates that could not be evaluated (their items are removed).
    pub fn prune_items(&self, items: &mut Vec<Item>) -> Vec<String> {
        let mut errors = Vec::new();
        items.retain_mut(|item| {
            let attrs = item_attrs(item);
            match self.attrs_active(attrs) {
                Ok(true) => {}
                Ok(false) => return false,
                Err(e) => {
                    errors.push(e);
                    return false;
                }
            }
            match item {
                Item::Mod(m) => {
                    if let Some((_, inner)) = &mut m.content {
                        errors.extend(self.prune_items(inner));
                    }
                }
                Item::Impl(imp) => {
                    imp.items.retain(|ii| {
                        let attrs = match ii {
                            syn::ImplItem::Fn(f) => &f.attrs,
                            syn::ImplItem::Const(c) => &c.attrs,
                            syn::ImplItem::Type(t) => &t.attrs,
                            syn::ImplItem::Macro(m) => &m.attrs,
                            _ => return true,
                        };
                        match self.attrs_active(attrs) {
                            Ok(active) => active,
                            Err(e) => {
                                errors.push(e);
                                false
                            }
                        }
                    });
                }
                Item::Struct(s) => {
                    if let syn::Fields::Named(named) = &mut s.fields {
                        let mut kept = syn::punctuated::Punctuated::new();
                        for field in named.named.iter() {
                            match self.attrs_active(&field.attrs) {
                                Ok(true) => kept.push(field.clone()),
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
}

/// Prune `items` and turn unevaluable predicates into a `syn::Error` so the
/// extractor fails closed instead of reporting guessed availability.
pub fn prune_or_error(set: &CfgSet, items: &mut Vec<Item>) -> Result<(), syn::Error> {
    let errors = set.prune_items(items);
    if errors.is_empty() {
        Ok(())
    } else {
        Err(syn::Error::new(
            proc_macro2::Span::call_site(),
            format!("cannot evaluate #[cfg] predicate: {}", errors.join("; ")),
        ))
    }
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

/// All `#[cfg(...)]` attributes of an item.
pub fn cfg_attrs(attrs: &[Attribute]) -> Vec<Attribute> {
    attrs
        .iter()
        .filter(|a| a.path().is_ident("cfg"))
        .cloned()
        .collect()
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
            CfgSet::parse("debug_assertions\npanic=\"unwind\"\ntarget_os=\"macos\"\n\nunix\n");
        assert!(set.eval(&pred("unix")).unwrap());
        assert!(set.eval(&pred("debug_assertions")).unwrap());
        assert!(set.eval(&pred("target_os = \"macos\"")).unwrap());
        assert!(!set.eval(&pred("target_os = \"linux\"")).unwrap());
        assert!(!set.eval(&pred("windows")).unwrap());
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
    fn predicate_string_joins_multiple_cfgs() {
        let f: syn::ItemFn =
            syn::parse_str("#[cfg(unix)] #[doc = \"x\"] #[cfg(feature = \"a\")] fn f() {}")
                .unwrap();
        assert_eq!(predicate_string(&f.attrs), "all(unix, feature = \"a\")");
        let g: syn::ItemFn = syn::parse_str("fn g() {}").unwrap();
        assert_eq!(predicate_string(&g.attrs), "");
    }
}
