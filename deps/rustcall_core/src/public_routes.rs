//! External call paths, distinct from canonical definition identities (#303).
//! Inputs are the same cfg-pruned syn items as the PyO3 scan. Predicates are
//! retained for lenient scans; a conditional import must not grant unconditional
//! access to an otherwise unconditional definition.
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use syn::{Attribute, Item, Visibility};

use crate::paths::{imports_of_use, visible_from, ScannedImport};

type Path = Vec<String>;

#[derive(Clone, Debug)]
struct Definition {
    visibility: Visibility,
    module: bool,
    predicates: BTreeSet<String>,
}

#[derive(Clone, Debug)]
struct Import {
    binding: ScannedImport,
    visibility: Visibility,
    predicates: BTreeSet<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct Target {
    path: Path,
    predicates: BTreeSet<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PublicRoute {
    pub path: Path,
    pub predicates: BTreeSet<String>,
}

#[derive(Clone, Default, Debug)]
pub struct PublicRoutes {
    definitions: BTreeMap<Path, Vec<Definition>>,
    imports: Vec<Import>,
    names: BTreeSet<String>,
}

impl PublicRoutes {
    /// Resolve within one cfg variant. A public module in a mutually exclusive
    /// variant must not grant access to the private copy at the same path.
    pub fn resolve_for(&self, cfg: &str) -> BTreeMap<Path, PublicRoute> {
        let compatible = |predicates: &BTreeSet<String>| {
            !predicates
                .iter()
                .any(|predicate| crate::cfg::cfg_exclusive(predicate, cfg))
        };
        let mut scoped = self.clone();
        scoped.definitions.retain(|_, definitions| {
            definitions.retain(|definition| compatible(&definition.predicates));
            !definitions.is_empty()
        });
        scoped
            .imports
            .retain(|import| compatible(&import.predicates));
        scoped.resolve()
    }
    /// Add one file; inline modules recurse here, file modules are supplied by
    /// the existing file walker with their canonical path and enclosing cfg.
    pub fn file(&mut self, items: &[Item], module: &[String], cfg: &[Attribute]) {
        for item in items {
            let entry = match item {
                Item::Fn(v) => Some((&v.sig.ident, &v.vis, &v.attrs, false)),
                Item::Struct(v) => Some((&v.ident, &v.vis, &v.attrs, false)),
                Item::Enum(v) => Some((&v.ident, &v.vis, &v.attrs, false)),
                Item::Type(v) => Some((&v.ident, &v.vis, &v.attrs, false)),
                Item::Const(v) => Some((&v.ident, &v.vis, &v.attrs, false)),
                Item::Static(v) => Some((&v.ident, &v.vis, &v.attrs, false)),
                Item::Union(v) => Some((&v.ident, &v.vis, &v.attrs, false)),
                Item::Trait(v) => Some((&v.ident, &v.vis, &v.attrs, false)),
                Item::Mod(v) => Some((&v.ident, &v.vis, &v.attrs, true)),
                _ => None,
            };
            if let Some((name, visibility, attrs, is_module)) = entry {
                let mut path = module.to_vec();
                self.names.insert(name.to_string());
                path.push(name.to_string());
                let effective = crate::cfg::effective_cfg_attrs(cfg, attrs);
                self.definitions
                    .entry(path.clone())
                    .or_default()
                    .push(Definition {
                        visibility: visibility.clone(),
                        module: is_module,
                        predicates: predicates(&effective),
                    });
                if let Item::Mod(v) = item {
                    if let Some((_, items)) = &v.content {
                        self.file(items, &path, &effective);
                    }
                }
            }
            if let Item::Use(v) = item {
                for binding in imports_of_use(v, module) {
                    // `use ... as _` imports anonymously and creates no path
                    // a dependent crate can name, even when the use is pub.
                    if !binding.glob && binding.alias == "_" {
                        continue;
                    }
                    if !binding.glob {
                        self.names.insert(binding.alias.clone());
                    }
                    self.imports.push(Import {
                        binding,
                        visibility: v.vis.clone(),
                        predicates: predicates(&crate::cfg::effective_cfg_attrs(cfg, &v.attrs)),
                    });
                }
            }
        }
    }

    fn name(
        &self,
        module: &[String],
        name: &str,
        observer: Option<&[String]>,
        visiting: &mut BTreeSet<(Path, String)>,
    ) -> BTreeSet<Target> {
        let key = (module.to_vec(), name.to_string());
        if !visiting.insert(key.clone()) {
            return BTreeSet::new();
        }
        let mut path = module.to_vec();
        path.push(name.to_string());
        let mut result = BTreeSet::new();
        let direct = self.definitions.get(&path);
        let explicit: Vec<_> = self
            .imports
            .iter()
            .filter(|v| {
                v.binding.module_path == module && !v.binding.glob && v.binding.alias == name
            })
            .collect();
        if let Some(definitions) = direct {
            for definition in definitions {
                if accessible(&definition.visibility, module, observer) {
                    result.insert(Target {
                        path: path.clone(),
                        predicates: definition.predicates.clone(),
                    });
                }
            }
        }
        for import in &explicit {
            if accessible(&import.visibility, module, observer) {
                for mut target in self.import_target(import, visiting) {
                    target.predicates.extend(import.predicates.clone());
                    result.insert(target);
                }
            }
        }
        // Named bindings shadow globs even when the named binding is private.
        if direct.is_none() && explicit.is_empty() {
            for import in self.imports.iter().filter(|v| {
                v.binding.module_path == module
                    && v.binding.glob
                    && accessible(&v.visibility, module, observer)
            }) {
                for source in self.import_target(import, visiting) {
                    for mut target in self.name(&source.path, name, Some(module), visiting) {
                        target.predicates.extend(source.predicates.clone());
                        target.predicates.extend(import.predicates.clone());
                        result.insert(target);
                    }
                }
            }
        }
        visiting.remove(&key);
        result
    }

    fn import_target(
        &self,
        import: &Import,
        visiting: &mut BTreeSet<(Path, String)>,
    ) -> BTreeSet<Target> {
        let binding = &import.binding;
        let mut qualifier = binding.qualifier.clone();
        if !binding.glob {
            if let Some(last) = binding.path.last() {
                qualifier.segments.push(last.clone());
            }
        }
        for path in qualifier.candidates(&binding.module_path) {
            let mut targets = BTreeSet::from([Target {
                path: Vec::new(),
                predicates: BTreeSet::new(),
            }]);
            for segment in path {
                let mut next = BTreeSet::new();
                for parent in targets {
                    for mut target in
                        self.name(&parent.path, &segment, Some(&binding.module_path), visiting)
                    {
                        target.predicates.extend(parent.predicates.clone());
                        next.insert(target);
                    }
                }
                targets = next;
            }
            if !targets.is_empty() {
                return targets;
            }
        }
        BTreeSet::new()
    }

    /// Select a deterministic externally reachable spelling for each canonical
    /// item. Ambiguous names are never chosen. Module cycles are traversed once
    /// per route, so re-export loops cannot grow paths indefinitely.
    pub fn resolve(&self) -> BTreeMap<Path, PublicRoute> {
        let mut result = BTreeMap::new();
        let mut queue =
            VecDeque::from([(Vec::new(), Vec::new(), BTreeSet::new(), BTreeSet::new())]);
        while let Some((module, prefix, inherited, mut ancestors)) = queue.pop_front() {
            if !ancestors.insert(module.clone()) {
                continue;
            }
            for name in &self.names {
                let targets = self.name(&module, name, None, &mut BTreeSet::new());
                if targets
                    .iter()
                    .map(|v| &v.path)
                    .collect::<BTreeSet<_>>()
                    .len()
                    != 1
                {
                    continue;
                }
                for target in targets {
                    let Some(definitions) = self.definitions.get(&target.path) else {
                        continue;
                    };
                    if !definitions
                        .iter()
                        .any(|v| matches!(v.visibility, Visibility::Public(_)))
                    {
                        continue;
                    }
                    let mut path = prefix.clone();
                    path.push(name.clone());
                    let mut predicates = inherited.clone();
                    predicates.extend(target.predicates);
                    let candidate = PublicRoute {
                        path: path.clone(),
                        predicates: predicates.clone(),
                    };
                    let rank = |route: &PublicRoute| {
                        (route.predicates.len(), route.path.len(), route.path.clone())
                    };
                    result
                        .entry(target.path.clone())
                        .and_modify(|current| {
                            if rank(&candidate) < rank(current) {
                                *current = candidate.clone();
                            }
                        })
                        .or_insert(candidate);
                    if definitions.iter().any(|v| v.module) {
                        queue.push_back((target.path, path, predicates, ancestors.clone()));
                    }
                }
            }
        }
        result
    }
}

fn accessible(vis: &Visibility, module: &[String], observer: Option<&[String]>) -> bool {
    observer.map_or(matches!(vis, Visibility::Public(_)), |from| {
        visible_from(vis, module, from)
    })
}

fn predicates(attrs: &[Attribute]) -> BTreeSet<String> {
    let text = crate::cfg::predicate_string(attrs);
    if text.is_empty() {
        BTreeSet::new()
    } else {
        BTreeSet::from([text])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn routes(source: &str) -> BTreeMap<Path, PublicRoute> {
        let file = syn::parse_file(source).unwrap();
        let mut routes = PublicRoutes::default();
        routes.file(&file.items, &[], &[]);
        routes.resolve()
    }
    fn path(value: &str) -> Path {
        value.split("::").map(String::from).collect()
    }

    #[test]
    fn follows_alias_chains_globs_and_module_aliases() {
        for (export, expected) in [
            ("pub use hidden::calculate as exposed;", "exposed"),
            (
                "mod bridge { pub use crate::hidden::calculate as exposed; } pub use bridge::*;",
                "exposed",
            ),
            ("pub use hidden::api as facade;", "facade::calculate"),
        ] {
            let nested = expected.contains("::");
            let source = if nested {
                "mod hidden { pub mod api { pub fn calculate() {} } }"
            } else {
                "mod hidden { pub fn calculate() {} }"
            };
            let routes = routes(&format!("{source} {export}"));
            let canonical = if nested {
                "hidden::api::calculate"
            } else {
                "hidden::calculate"
            };
            assert_eq!(routes[&path(canonical)].path, path(expected));
        }
    }

    #[test]
    fn rejects_private_ambiguous_and_cyclic_routes() {
        for export in [
            "use hidden::calculate;",
            "pub(crate) use hidden::calculate;",
        ] {
            assert!(!routes(&format!(
                "mod hidden {{ pub fn calculate() {{}} }} {export}"
            ))
            .contains_key(&path("hidden::calculate")));
        }
        let result =
            routes("mod a { pub fn f() {} } mod b { pub fn f() {} } pub use a::*; pub use b::*;");
        assert!(!result.contains_key(&path("a::f")));
        assert!(!result.contains_key(&path("b::f")));
        assert!(routes(
            "mod a { pub use crate::b::*; } mod b { pub use crate::a::*; } pub use a::*;"
        )
        .is_empty());
    }

    #[test]
    fn retains_conditional_import_predicates() {
        let result =
            routes("mod hidden { pub fn f() {} } #[cfg(feature = \"api\")] pub use hidden::f;");
        assert!(!result[&path("hidden::f")].predicates.is_empty());
    }

    #[test]
    fn conditional_alias_does_not_gate_an_unconditional_public_path() {
        let result = routes(
            "pub mod api { pub fn f() {} } #[cfg(feature = \"optional\")] pub use api::f as alias;",
        );
        assert_eq!(result[&path("api::f")].path, path("api::f"));
        assert!(result[&path("api::f")].predicates.is_empty());
    }

    #[test]
    fn named_import_shadows_globs_and_private_modules_stay_private() {
        let result =
            routes("mod a { pub fn f() {} } mod b { pub fn f() {} } pub use a::*; pub use b::f;");
        assert_eq!(result[&path("b::f")].path, path("f"));
        assert!(!result.contains_key(&path("a::f")));
        let result =
            routes("mod hidden { mod private { pub fn f() {} } } pub use hidden::private::f;");
        assert!(!result.contains_key(&path("hidden::private::f")));
    }
}
