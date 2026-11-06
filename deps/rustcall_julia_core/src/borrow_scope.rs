//! Exact, conservative type-namespace lookup for checked owner borrows.
//! Kept separate from the heuristic impl-target resolver.
use crate::paths::{imports_of_use, visible_from, PathAnchor, ScannedImport};
use std::collections::HashSet;
use syn::{Item, Type, Visibility};
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone)]
enum Kind {
    Alias,
    Type { owner: bool },
    Module(Vec<String>),
}
#[derive(Debug, Clone)]
struct Decl {
    scope: Vec<String>,
    name: String,
    vis: Visibility,
    kind: Kind,
    uncertain: bool,
}
#[derive(Debug, Clone)]
struct Import {
    import: ScannedImport,
    vis: Visibility,
    uncertain: bool,
    absolute: bool,
}
#[derive(Debug, Default)]
pub(crate) struct Scope {
    decls: Vec<Decl>,
    imports: Vec<Import>,
    opaque: HashSet<Vec<String>>,
    rewritten: HashSet<Vec<String>>,
}
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Borrow {
    Owner(Vec<String>, String),
    Plain,
    Unresolved(&'static str),
}
fn semantic_name(name: &str) -> String {
    crate::codegen::unraw(name).nfc().collect()
}
fn semantic_path(path: &[String]) -> Vec<String> {
    path.iter().map(|name| semantic_name(name)).collect()
}
fn semantic_visibility(vis: &Visibility) -> Visibility {
    let mut normalized = vis.clone();
    if let Visibility::Restricted(restricted) = &mut normalized {
        for segment in &mut restricted.path.segments {
            segment.ident = crate::codegen::source_ident(
                &semantic_name(&segment.ident.to_string()),
                segment.ident.span(),
            );
        }
    }
    normalized
}
pub(crate) fn same_name(name: &str, other: &str) -> bool {
    crate::codegen::unraw(name)
        .nfc()
        .eq(crate::codegen::unraw(other).nfc())
}
/// Compare semantic lookup identities without rewriting source/codegen spelling.
pub(crate) fn same_item(
    scope: &[String],
    name: &str,
    other_scope: &[String],
    other_name: &str,
) -> bool {
    same_name(name, other_name)
        && scope
            .iter()
            .map(|s| semantic_name(s))
            .eq(other_scope.iter().map(|s| semantic_name(s)))
}

type LookupKey = (Vec<String>, String, Vec<String>);

#[derive(Debug, Default)]
struct Found {
    ids: HashSet<usize>,
    // Module identity is its canonical lexical path, including the virtual root.
    modules: HashSet<Vec<String>>,
    unknown: bool,
    inaccessible: bool,
    // A cycle contributes no binding yet; it is not an unknown external
    // module. Without a concrete exit it can never prove an owner.
    pending: HashSet<LookupKey>,
}
impl Found {
    fn merge(&mut self, other: Self) {
        self.ids.extend(other.ids);
        self.modules.extend(other.modules);
        self.unknown |= other.unknown;
        self.inaccessible |= other.inaccessible;
        self.pending.extend(other.pending);
    }
    fn unknown() -> Self {
        Self {
            unknown: true,
            ..Self::default()
        }
    }
}
impl Scope {
    pub(crate) fn context_error(&self, scope: &[String]) -> Option<&'static str> {
        let scope = semantic_path(scope);
        self.rewritten.iter().any(|context| scope.starts_with(context)).then_some(
            "borrowed owner scope may be rewritten by an opaque module or file attribute; use expanded Rust source whose owner boundary can be proved",
        )
    }
    pub(crate) fn record_context_attrs(&mut self, attrs: &[syn::Attribute], scope: &[String]) {
        if rewriting_attrs(attrs) {
            self.rewritten.insert(semantic_path(scope));
        }
    }
    pub(crate) fn record(
        &mut self,
        items: &[Item],
        scope: &[String],
        gated: bool,
        symbol_path: &[String],
        mode: crate::manifest::Mode,
    ) {
        let normalized_scope = semantic_path(scope);
        let scope = normalized_scope.as_slice();
        for item in items {
            let attrs = match item {
                Item::Const(x) => &x.attrs,
                Item::Enum(x) => &x.attrs,
                Item::ExternCrate(x) => &x.attrs,
                Item::Fn(x) => &x.attrs,
                Item::ForeignMod(x) => &x.attrs,
                Item::Impl(x) => &x.attrs,
                Item::Macro(x) => &x.attrs,
                Item::Mod(x) => &x.attrs,
                Item::Static(x) => &x.attrs,
                Item::Struct(x) => &x.attrs,
                Item::Trait(x) => &x.attrs,
                Item::TraitAlias(x) => &x.attrs,
                Item::Type(x) => &x.attrs,
                Item::Union(x) => &x.attrs,
                Item::Use(x) => &x.attrs,
                _ => &Vec::new(),
            };
            // The selected function wrapper consumes this helper itself;
            // on modules/other items the same spelling may still be an
            // arbitrary rewriting attribute and must remain opaque.
            let mut selected_attrs;
            let scope_attrs = if matches!(item, Item::Fn(f) if f.attrs.iter().any(crate::attrs::is_julia_attr))
            {
                selected_attrs = attrs.clone();
                crate::owned_returns::strip(&mut selected_attrs);
                &selected_attrs
            } else {
                attrs
            };
            if opaque_attrs(scope_attrs) {
                self.opaque.insert(scope.to_vec());
            }
            let (name, vis, attrs, kind) = match item {
                Item::Struct(s) => (
                    s.ident.to_string(),
                    s.vis.clone(),
                    &s.attrs,
                    Kind::Type {
                        owner: crate::model::StructModel::of(s, mode).is_some()
                            && !crate::types::has_type_params(&s.generics),
                    },
                ),
                Item::Fn(f) if f.attrs.iter().any(crate::attrs::is_julia_attr) => {
                    if gated || conditional(&f.attrs) {
                        self.opaque.insert(scope.to_vec());
                    }
                    let entry = crate::extract::function_entry(
                        f,
                        crate::manifest::Attribute::Julia,
                        mode,
                        symbol_path,
                        &[],
                    );
                    self.generated(entry.claims().into_iter().map(|(c, _)| c), scope);
                    continue;
                }
                Item::Trait(s) => (
                    s.ident.to_string(),
                    s.vis.clone(),
                    &s.attrs,
                    Kind::Type { owner: false },
                ),
                Item::TraitAlias(s) => (
                    s.ident.to_string(),
                    s.vis.clone(),
                    &s.attrs,
                    Kind::Type { owner: false },
                ),
                Item::ExternCrate(s) => (
                    s.rename
                        .as_ref()
                        .map(|(_, name)| name)
                        .unwrap_or(&s.ident)
                        .to_string(),
                    s.vis.clone(),
                    &s.attrs,
                    Kind::Type { owner: false },
                ),
                Item::Enum(s) => (
                    s.ident.to_string(),
                    s.vis.clone(),
                    &s.attrs,
                    Kind::Type { owner: false },
                ),
                Item::Union(s) => (
                    s.ident.to_string(),
                    s.vis.clone(),
                    &s.attrs,
                    Kind::Type { owner: false },
                ),
                Item::Type(s) => (s.ident.to_string(), s.vis.clone(), &s.attrs, Kind::Alias),
                Item::Mod(m) => {
                    let mut path = scope.to_vec();
                    path.push(semantic_name(&m.ident.to_string()));
                    self.record_context_attrs(&m.attrs, &path);
                    (
                        m.ident.to_string(),
                        m.vis.clone(),
                        &m.attrs,
                        Kind::Module(path),
                    )
                }
                Item::Use(u) => {
                    self.imports
                        .extend(imports_of_use(u, scope).into_iter().map(|mut import| {
                            import.module_path = semantic_path(&import.module_path);
                            import.alias = semantic_name(&import.alias);
                            import.path = semantic_path(&import.path);
                            import.qualifier.segments = semantic_path(&import.qualifier.segments);
                            Import {
                                import,
                                vis: semantic_visibility(&u.vis),
                                uncertain: gated || conditional(&u.attrs) || opaque_attrs(&u.attrs),
                                absolute: u.leading_colon.is_some(),
                            }
                        }));
                    continue;
                }
                Item::Macro(m) if m.ident.is_none() => {
                    self.opaque.insert(scope.to_vec());
                    continue;
                }
                _ => continue,
            };
            // #[julia] makes selected structs public; all other bindings keep
            // their actual visibility. A private binding still shadows globs.
            let vis = if matches!(kind, Kind::Type { owner: true }) {
                syn::parse_quote!(pub)
            } else {
                semantic_visibility(&vis)
            };
            self.decls.push(Decl {
                scope: scope.to_vec(),
                name: semantic_name(&name),
                vis,
                kind,
                uncertain: gated || conditional(attrs) || rewriting_attrs(attrs),
            });
        }
    }
    fn generated(
        &mut self,
        claims: impl IntoIterator<Item = crate::claims::Claim>,
        scope: &[String],
    ) {
        let normalized_scope = semantic_path(scope);
        let scope = normalized_scope.as_slice();
        for claim in claims {
            if claim.namespace != crate::claims::Namespace::Type {
                continue;
            }
            let name = semantic_name(&claim.name);
            if self.decls.iter().any(|d| {
                d.scope == scope
                    && d.name == name
                    && matches!(d.kind, Kind::Type { owner: false })
                    && !d.uncertain
            }) {
                continue;
            }
            self.decls.push(Decl {
                scope: scope.to_vec(),
                name,
                // Type claims are module-scoped for collision checking, not
                // private Rust declarations: codegen emits public buffer and
                // Result/Option helper structs. Keep their real visibility so
                // named imports cannot fall through to unrelated glob owners.
                vis: syn::parse_quote!(pub),
                kind: Kind::Type { owner: false },
                uncertain: false,
            });
        }
    }
    pub(crate) fn generated_struct(
        &mut self,
        entry: &crate::manifest::Struct,
        model: &crate::model::StructModel,
        scope: &[String],
    ) {
        let normalized_scope = semantic_path(scope);
        let scope = normalized_scope.as_slice();
        if !entry.cfg.is_empty() {
            self.opaque.insert(scope.to_vec());
        }
        let mut own = entry.clone();
        own.methods.clear();
        self.generated(own.claims().into_iter().map(|(c, _)| c), scope);
        for method in &entry.methods {
            let site = model
                .methods
                .iter()
                .find(|m| m.name() == method.name && m.trait_path() == method.trait_path)
                .and_then(|m| m.site.as_ref())
                .map(|site| semantic_path(&site.module_path))
                .unwrap_or_else(|| scope.to_vec());
            if !entry.cfg.is_empty() || !method.cfg.is_empty() {
                self.opaque.insert(site.to_vec());
            }
            let mut one = entry.clone();
            one.methods = vec![method.clone()];
            self.generated(one.claims().into_iter().map(|(c, _)| c), &site);
        }
    }
    pub(crate) fn resolve(&self, ty: &Type, scope: &[String], edition_2015: bool) -> Borrow {
        if let Some(reason) = self.context_error(scope) {
            return Borrow::Unresolved(reason);
        }
        let normalized_scope = semantic_path(scope);
        let scope = normalized_scope.as_slice();
        let Type::Path(path) = crate::types::unparen(ty) else {
            return Borrow::Plain;
        };
        if path.qself.is_some() || path.path.segments.iter().any(|s| !s.arguments.is_none()) {
            return Borrow::Plain;
        }
        let names: Vec<String> = path
            .path
            .segments
            .iter()
            .map(|s| semantic_name(&s.ident.to_string()))
            .collect();
        let found = self.path(
            &names,
            scope,
            scope,
            path.path.leading_colon.is_some(),
            edition_2015,
            &mut HashSet::new(),
        );
        // Primitive identifiers can be shadowed. Consult lexical bindings first;
        // only an otherwise empty lookup may use their language-prelude meaning.
        if found.ids.is_empty()
            && found.modules.is_empty()
            && !found.unknown
            && !found.inaccessible
            && names.len() == 1
            && matches!(
                names[0].as_str(),
                "bool"
                    | "char"
                    | "i8"
                    | "i16"
                    | "i32"
                    | "i64"
                    | "i128"
                    | "isize"
                    | "u8"
                    | "u16"
                    | "u32"
                    | "u64"
                    | "u128"
                    | "usize"
                    | "f32"
                    | "f64"
                    | "str"
            )
        {
            return Borrow::Plain;
        }
        if found.unknown || found.inaccessible || found.ids.len() + found.modules.len() > 1 {
            return Borrow::Unresolved(
                "ambiguous, conditional, external, or opaque borrowed type scope",
            );
        }
        let Some(id) = found.ids.into_iter().next() else {
            if !found.modules.is_empty() {
                return Borrow::Plain;
            }
            return Borrow::Unresolved("borrowed type path cannot be proved in its lexical scope");
        };
        let decl = &self.decls[id];
        match &decl.kind {
            Kind::Type { owner: true } => Borrow::Owner(decl.scope.clone(), decl.name.clone()),
            Kind::Alias => {
                Borrow::Unresolved("borrowed type alias requires an explicit concrete owner path")
            }
            _ => Borrow::Plain,
        }
    }
    fn path(
        &self,
        names: &[String],
        scope: &[String],
        from: &[String],
        absolute: bool,
        edition_2015: bool,
        visiting: &mut HashSet<LookupKey>,
    ) -> Found {
        if names.is_empty() {
            return Found::unknown();
        }
        if absolute && !edition_2015 {
            return Found::unknown();
        }
        let (base, skip) = if absolute {
            (Vec::new(), 0)
        } else {
            match names[0].as_str() {
                "crate" => (Vec::new(), 1),
                "self" => (scope.to_vec(), 1),
                "super" => {
                    let n = names.iter().take_while(|n| *n == "super").count();
                    if n > scope.len() {
                        return Found::unknown();
                    }
                    (scope[..scope.len() - n].to_vec(), n)
                }
                _ => (scope.to_vec(), 0),
            }
        };
        let rest = &names[skip..];
        if rest.is_empty() {
            // An anchored path can denote a module itself (`use crate as
            // root`, `use self as here`, `use super as parent`). The crate
            // root has no source declaration, so keep module identities
            // separate from type-declaration indices.
            return Found {
                modules: HashSet::from([base]),
                ..Found::default()
            };
        }
        let mut found = self.name(&base, &rest[0], from, edition_2015, visiting);
        for name in &rest[1..] {
            let mut next = Found {
                unknown: found.unknown,
                inaccessible: found.inaccessible,
                pending: found.pending,
                ..Found::default()
            };
            // A type or alias cannot be guessed to be a module prefix.
            next.unknown |=
                !found.ids.is_empty() || (found.modules.is_empty() && next.pending.is_empty());
            for module in found.modules {
                next.merge(self.name(&module, name, from, edition_2015, visiting));
            }
            found = next;
        }
        found
    }
    fn glob_module(
        &self,
        edge: &Import,
        edition_2015: bool,
        visiting: &mut HashSet<LookupKey>,
    ) -> Found {
        let i = &edge.import;
        if edge.absolute && !edition_2015 {
            return Found::unknown();
        }
        let base = match i.qualifier.anchor {
            PathAnchor::Crate => Vec::new(),
            PathAnchor::Relative if edition_2015 => Vec::new(),
            PathAnchor::SelfModule | PathAnchor::Relative => i.module_path.clone(),
            PathAnchor::Super(n) if n <= i.module_path.len() => {
                i.module_path[..i.module_path.len() - n].to_vec()
            }
            _ => return Found::unknown(),
        };
        if i.path.is_empty() {
            return Found {
                modules: HashSet::from([base]),
                ..Found::default()
            };
        }
        let names = import_path(edge, edition_2015);
        let mut found = self.path(
            &names,
            &i.module_path,
            &i.module_path,
            edge.absolute,
            edition_2015,
            visiting,
        );
        found.unknown |= found.inaccessible || !found.ids.is_empty();
        found.inaccessible = false;
        found.ids.clear();
        if found.modules.is_empty() && found.pending.is_empty() {
            found.unknown = true;
        }
        found
    }
    fn name(
        &self,
        scope: &[String],
        name: &str,
        from: &[String],
        edition_2015: bool,
        visiting: &mut HashSet<LookupKey>,
    ) -> Found {
        if self.context_error(scope).is_some() {
            return Found::unknown();
        }
        let key = (scope.to_vec(), name.to_string(), from.to_vec());
        if !visiting.insert(key.clone()) {
            return Found {
                pending: HashSet::from([key]),
                ..Found::default()
            };
        }
        let mut found = Found::default();
        let local: Vec<_> = self
            .decls
            .iter()
            .enumerate()
            .filter(|(_, d)| d.scope == scope && d.name == name)
            .collect();
        let named: Vec<_> = self
            .imports
            .iter()
            .filter(|i| i.import.module_path == scope && !i.import.glob && i.import.alias == name)
            .collect();
        if !local.is_empty() {
            for (id, d) in local {
                if d.uncertain {
                    found.unknown = true;
                } else if !visible_from(&d.vis, scope, from) {
                    found.inaccessible = true;
                } else if let Kind::Module(module) = &d.kind {
                    found.modules.insert(module.clone());
                } else {
                    found.ids.insert(id);
                }
            }
        } else {
            // A use imports each Rust namespace independently. A complete
            // lookup with no type binding (for example a function/const)
            // cannot hide a type supplied by a glob. Unresolved externals,
            // expansion scopes and pending imports remain conservative.
            for edge in named {
                if edge.uncertain {
                    found.unknown = true;
                    continue;
                }
                let names = import_path(edge, edition_2015);
                let mut imported =
                    self.path(&names, scope, scope, edge.absolute, edition_2015, visiting);
                // An inaccessible target contributes no imported type. It
                // may still supply a public value of the same name.
                imported.inaccessible = false;
                // Since 2018 an unanchored single-segment use can name an
                // extern-prelude crate. An absent indexed type is not proof
                // that such an import is value-only.
                if !edition_2015
                    && !edge.absolute
                    && edge.import.qualifier.anchor == PathAnchor::Relative
                    && edge.import.path.len() == 1
                    && imported.ids.is_empty()
                    && imported.modules.is_empty()
                    && imported.pending.is_empty()
                {
                    imported.unknown = true;
                }
                if !visible_from(&edge.vis, scope, from)
                    && (!imported.ids.is_empty() || !imported.modules.is_empty())
                {
                    imported.ids.clear();
                    imported.modules.clear();
                    imported.inaccessible = true;
                }
                found.merge(imported);
            }
            if found.ids.is_empty()
                && found.modules.is_empty()
                && !found.unknown
                && !found.inaccessible
                && found.pending.is_empty()
            {
                found.unknown = self.opaque.contains(scope);
                for edge in self
                    .imports
                    .iter()
                    .filter(|i| i.import.module_path == scope && i.import.glob)
                {
                    if !visible_from(&edge.vis, scope, from) {
                        continue;
                    }
                    if edge.uncertain {
                        found.unknown = true;
                        continue;
                    }
                    let target = self.glob_module(edge, edition_2015, visiting);
                    found.unknown |= target.unknown;
                    found.pending.extend(target.pending);
                    for module in target.modules {
                        let mut member = self.name(&module, name, scope, edition_2015, visiting);
                        // A glob imports accessible type bindings only; a
                        // private local still blocks its own module's globs.
                        member.inaccessible = false;
                        found.merge(member);
                    }
                }
            }
        }
        visiting.remove(&key);
        found.pending.remove(&key);
        found
    }
}
fn import_path(edge: &Import, edition_2015: bool) -> Vec<String> {
    let mut names = if edge.absolute {
        Vec::new()
    } else {
        match edge.import.qualifier.anchor {
            PathAnchor::Crate => vec!["crate".into()],
            PathAnchor::Relative if edition_2015 => vec!["crate".into()],
            PathAnchor::SelfModule => vec!["self".into()],
            PathAnchor::Super(n) => vec!["super".into(); n],
            _ => Vec::new(),
        }
    };
    names.extend(edge.import.path.clone());
    names
}

fn conditional(attrs: &[syn::Attribute]) -> bool {
    attrs
        .iter()
        .any(|a| a.path().is_ident("cfg") || a.path().is_ident("cfg_attr"))
}

// Unknown proc attributes/derives may inject a type that shadows an imported
// owner. Recognized built-ins cannot add such a type-namespace binding.
fn opaque_attrs(attrs: &[syn::Attribute]) -> bool {
    attrs.iter().any(|a| {
        // Derive macro names are shadowable, even Clone/Debug. Derives
        // append items, so they obscure globs but cannot replace the
        // declaration to which they are attached.
        if a.path().is_ident("derive") || a.path().is_ident("cfg_attr") {
            return true;
        }
        a.path().get_ident().is_none_or(|i| {
            !matches!(
                i.to_string().as_str(),
                "julia"
                    | "path"
                    | "cfg"
                    | "cfg_attr"
                    | "allow"
                    | "warn"
                    | "deny"
                    | "forbid"
                    | "expect"
                    | "doc"
                    | "repr"
                    | "non_exhaustive"
                    | "deprecated"
                    | "must_use"
                    | "inline"
                    | "cold"
                    | "no_mangle"
                    | "export_name"
                    | "link_section"
                    | "automatically_derived"
                    | "track_caller"
            )
        })
    })
}

fn rewriting_attrs(attrs: &[syn::Attribute]) -> bool {
    attrs
        .iter()
        .any(|a| !a.path().is_ident("derive") && opaque_attrs(std::slice::from_ref(a)))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn graph(source: &str) -> Scope {
        fn walk(graph: &mut Scope, items: &[Item], path: &mut Vec<String>) {
            graph.record(items, path, false, path, crate::manifest::Mode::Inline);
            for item in items {
                if let Item::Mod(m) = item {
                    if let Some((_, inner)) = &m.content {
                        path.push(m.ident.to_string());
                        walk(graph, inner, path);
                        path.pop();
                    }
                }
            }
        }
        let mut graph = Scope::default();
        walk(
            &mut graph,
            &syn::parse_file(source).unwrap().items,
            &mut Vec::new(),
        );
        graph
    }
    fn resolve(source: &str, scope: &[&str], ty: &str) -> Borrow {
        graph(source).resolve(
            &syn::parse_str(ty).unwrap(),
            &scope.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
            false,
        )
    }
    fn root_owner() -> Borrow {
        Borrow::Owner(vec![], "Owner".into())
    }
    #[test]
    fn parent_glob_and_explicit_import_prove_identical_owner() {
        for import in ["use super::*;", "use super::Owner;"] {
            assert_eq!(
                resolve(
                    &format!("#[julia] struct Owner; mod child {{ {import} }}"),
                    &["child"],
                    "Owner"
                ),
                root_owner()
            );
        }
    }
    #[test]
    fn no_parent_or_global_unique_name_fallback() {
        let source = "#[julia] struct Owner; mod child {}";
        assert!(matches!(
            resolve(source, &["child"], "Owner"),
            Borrow::Unresolved(_)
        ));
        assert_eq!(resolve(source, &["child"], "super::Owner"), root_owner());
    }
    #[test]
    fn local_and_named_plain_items_shadow_globs() {
        for item in [
            "struct Owner;",
            "trait Owner {}",
            "use crate::plain::Owner;",
        ] {
            let source = format!("mod plain {{ pub struct Owner; }} #[julia] struct Owner; mod child {{ use super::*; {item} }}");
            assert_eq!(resolve(&source, &["child"], "Owner"), Borrow::Plain);
        }
    }
    #[test]
    fn conflicting_globs_are_ambiguous_but_same_declaration_deduplicates() {
        let same = "#[julia] struct Owner; mod a { pub use crate::Owner; } mod b { pub use crate::Owner; } mod child { use crate::a::*; use crate::b::*; }";
        assert_eq!(resolve(same, &["child"], "Owner"), root_owner());
        let other = same.replace(
            "mod b { pub use crate::Owner; }",
            "mod b { pub struct Owner; }",
        );
        assert!(matches!(
            resolve(&other, &["child"], "Owner"),
            Borrow::Unresolved(_)
        ));
        let alias = same.replace(
            "mod b { pub use crate::Owner; }",
            "mod b { pub type Owner = crate::Owner; }",
        );
        assert!(matches!(
            resolve(&alias, &["child"], "Owner"),
            Borrow::Unresolved(_)
        ));
    }
    #[test]
    fn reexport_cycle_diamond_and_imported_module_prefix() {
        let source = "#[julia] struct Owner; mod a { pub use crate::b::*; pub use crate::Owner; } mod b { pub use crate::a::*; } mod child { use crate::b as alias; use alias::*; }";
        assert_eq!(resolve(source, &["child"], "Owner"), root_owner());
        assert_eq!(resolve(source, &["child"], "alias::Owner"), root_owner());
        let empty = "mod a { pub use crate::b::*; } mod b { pub use crate::a::*; } mod child { use crate::a::*; }";
        assert!(matches!(
            resolve(empty, &["child"], "Owner"),
            Borrow::Unresolved(_)
        ));
    }
    #[test]
    fn public_reexport_bypasses_private_canonical_module_but_not_private_import() {
        let source = "mod hidden { #[julia] struct Owner; } pub use hidden::Owner; mod child { use super::*; }";
        assert_eq!(
            resolve(source, &["child"], "Owner"),
            Borrow::Owner(vec!["hidden".into()], "Owner".into())
        );
        let private = "mod parent { #[julia] pub struct Owner; } mod a { use crate::parent::Owner; } mod child { use crate::a::*; }";
        assert!(matches!(
            resolve(private, &["child"], "Owner"),
            Borrow::Unresolved(_)
        ));
    }
    #[test]
    fn restricted_visibility_and_private_shadow_do_not_fall_through() {
        let source = "#[julia] struct Owner; mod a { pub(super) use crate::Owner; pub mod b { use super::*; } }";
        assert_eq!(resolve(source, &["a", "b"], "Owner"), root_owner());
        let private_shadow = "#[julia] struct Owner; mod a { use crate::*; struct Owner; } mod child { use crate::a::*; }";
        assert!(matches!(
            resolve(private_shadow, &["child"], "Owner"),
            Borrow::Unresolved(_)
        ));
    }
    #[test]
    fn conditional_and_macro_scopes_refuse_glob_proof_but_local_binding_survives() {
        for blocker in ["#[cfg(feature=\"x\")] struct Owner;", "generate!();"] {
            let source = format!("#[julia] struct Owner; mod child {{ use super::*; {blocker} }}");
            assert!(matches!(
                resolve(&source, &["child"], "Owner"),
                Borrow::Unresolved(_)
            ));
        }
        assert_eq!(
            resolve(
                "#[julia] struct Owner; mod child { use super::Owner; generate!(); }",
                &["child"],
                "Owner"
            ),
            root_owner()
        );
    }
    #[test]
    fn import_roots_follow_edition_but_type_paths_remain_lexical() {
        for import in ["use source::*;", "use source::Owner;"] {
            let g = graph(&format!("mod source {{ #[julia] struct Owner; }} mod child {{ mod source {{ #[julia] struct Owner; }} {import} }}"));
            let ty = syn::parse_str("Owner").unwrap();
            assert_eq!(
                g.resolve(&ty, &["child".into()], true),
                Borrow::Owner(vec!["source".into()], "Owner".into())
            );
            assert_eq!(
                g.resolve(&ty, &["child".into()], false),
                Borrow::Owner(vec!["child".into(), "source".into()], "Owner".into())
            );
        }
    }
    #[test]
    fn absolute_use_paths_are_rooted_only_in_edition_2015() {
        for import in ["use ::source::*;", "use ::source::Owner;"] {
            let g = graph(&format!(
                "mod source {{ #[julia] struct Owner; }} mod child {{ {import} }}"
            ));
            let ty = syn::parse_str("Owner").unwrap();
            assert_eq!(
                g.resolve(&ty, &["child".into()], true),
                Borrow::Owner(vec!["source".into()], "Owner".into())
            );
            assert!(matches!(
                g.resolve(&ty, &["child".into()], false),
                Borrow::Unresolved(_)
            ));
        }
    }
    #[test]
    fn primitive_spelling_is_shadowed_and_lifetime_owner_is_not_type_generic() {
        assert_eq!(
            resolve("#[julia] struct i32;", &[], "i32"),
            Borrow::Owner(vec![], "i32".into())
        );
        assert_eq!(
            resolve("#[julia] struct Owner<'a> { x: &'a i32 }", &[], "Owner"),
            root_owner()
        );
        assert_eq!(
            resolve("#[julia] struct Owner<T> { x: T }", &[], "Owner"),
            Borrow::Plain
        );
    }
    #[test]
    fn custom_attribute_and_derive_cannot_hide_glob_shadows() {
        for item in [
            "#[derive(Clone)] struct Trigger;",
            "#[derive(MakeOwner)] struct Trigger;",
            "#[change] fn trigger() {}",
        ] {
            assert!(matches!(
                resolve(
                    &format!("#[julia] struct Owner; mod child {{ use super::*; {item} }}"),
                    &["child"],
                    "Owner"
                ),
                Borrow::Unresolved(_)
            ));
        }
        assert_eq!(
            resolve(
                "#[derive(Clone)] #[julia] struct Owner; mod child { use super::*; }",
                &["child"],
                "Owner"
            ),
            root_owner()
        );
    }
    #[test]
    fn anchored_module_aliases_and_reexports_keep_canonical_module_identity() {
        let source = "#[julia] struct Owner; use crate as root; use self as here; mod consumer { use super::root as first; use super::here as second; use self::first::*; use self::second::*; }";
        let g = graph(source);
        for edition_2015 in [false, true] {
            for ty in ["first::Owner", "second::Owner", "Owner"] {
                assert_eq!(
                    g.resolve(
                        &syn::parse_str(ty).unwrap(),
                        &["consumer".into()],
                        edition_2015
                    ),
                    root_owner()
                );
            }
        }
        let nested = "#[julia] struct Owner; mod parent { #[julia] pub struct Local; mod child { use super as parent; use self as here; use self::parent::*; mod data { #[julia] pub struct Other; } use self::here::data::*; } }";
        assert_eq!(
            resolve(nested, &["parent", "child"], "parent::Local"),
            Borrow::Owner(vec!["parent".into()], "Local".into())
        );
        assert_eq!(
            resolve(nested, &["parent", "child"], "Other"),
            Borrow::Owner(
                vec!["parent".into(), "child".into(), "data".into()],
                "Other".into()
            )
        );
    }
    #[test]
    fn anchored_alias_reexport_cycles_deduplicate_modules_but_not_type_aliases() {
        let source = "#[julia] struct Owner; mod a { pub use crate as root; pub use crate::b::*; } mod b { pub use crate::a::*; } mod consumer { use crate::b::*; use root::*; }";
        assert_eq!(resolve(source, &["consumer"], "root::Owner"), root_owner());
        assert_eq!(resolve(source, &["consumer"], "Owner"), root_owner());
        let ambiguous = "#[julia] struct Owner; mod a { pub use crate as root; } mod b { pub type root = crate::Owner; } mod consumer { use crate::a::*; use crate::b::*; }";
        assert!(matches!(
            resolve(ambiguous, &["consumer"], "root::Owner"),
            Borrow::Unresolved(_)
        ));
    }
    #[test]
    fn external_glob_is_not_mistaken_for_a_pure_cycle() {
        let source = "#[julia] struct Owner; mod consumer { use super::*; use external::*; }";
        assert!(matches!(
            resolve(source, &["consumer"], "Owner"),
            Borrow::Unresolved(_)
        ));
    }
    #[test]
    fn raw_restricted_visibility_keeps_descendant_access_and_blocks_siblings() {
        let source = "pub mod r#outer { #[julia] pub struct r#Owner; pub mod exports { pub(in crate::r#outer) use super::r#Owner; } mod child { use super::exports::*; } } mod outsider { use crate::outer::exports::*; }";
        assert_eq!(
            resolve(source, &["r#outer", "child"], "Owner"),
            Borrow::Owner(vec!["outer".into()], "Owner".into())
        );
        assert!(matches!(
            resolve(source, &["outsider"], "Owner"),
            Borrow::Unresolved(_)
        ));
    }
    #[test]
    fn unicode_restricted_visibility_uses_the_same_semantic_module_identity() {
        let source = "pub mod K { #[julia] pub struct Owner; pub mod exports { pub(in crate::K) use super::Owner; } mod child { use super::exports::*; } } mod outsider { use crate::K::exports::*; }";
        assert_eq!(
            resolve(source, &["K", "child"], "Owner"),
            Borrow::Owner(vec!["K".into()], "Owner".into())
        );
        assert!(matches!(
            resolve(source, &["outsider"], "Owner"),
            Borrow::Unresolved(_)
        ));
    }
    #[test]
    fn raw_generic_parameter_spellings_mask_same_named_items() {
        let generics: syn::Generics = syn::parse_quote!(<r#T>);
        for ty in ["T", "r#T", "T::Assoc", "r#T::Assoc"] {
            assert!(crate::extract::type_parameter_path(
                &syn::parse_str(ty).unwrap(),
                &generics
            ));
        }
        assert!(!crate::extract::type_parameter_path(
            &syn::parse_str("crate::T").unwrap(),
            &generics
        ));
        let unicode: syn::Generics = syn::parse_quote!(<K>);
        assert!(crate::extract::type_parameter_path(
            &syn::parse_str("K").unwrap(),
            &unicode
        ));
    }
    #[test]
    fn private_module_alias_is_not_exposed_by_sibling_glob() {
        let source =
            "#[julia] struct Owner; mod a { use crate as root; } mod consumer { use crate::a::*; }";
        assert!(matches!(
            resolve(source, &["consumer"], "root::Owner"),
            Borrow::Unresolved(_)
        ));
    }
    #[test]
    fn leading_colon_obeys_edition_and_primitive_plain_types_stay_plain() {
        let graph = graph("#[julia] struct Owner; struct Plain; mod child {}");
        let ty = syn::parse_str("::Owner").unwrap();
        assert_eq!(graph.resolve(&ty, &["child".into()], true), root_owner());
        assert!(matches!(
            graph.resolve(&ty, &["child".into()], false),
            Borrow::Unresolved(_)
        ));
        assert_eq!(
            graph.resolve(&syn::parse_str("i32").unwrap(), &[], false),
            Borrow::Plain
        );
        assert_eq!(
            graph.resolve(&syn::parse_str("Plain").unwrap(), &[], false),
            Borrow::Plain
        );
    }
}
