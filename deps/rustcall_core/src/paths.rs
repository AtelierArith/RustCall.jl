//! Resolving the type path an `impl` header writes to the struct it names.
//!
//! Rust does not require an `impl C` to live next to `struct C`: it is legal in
//! any module that has `C` in scope, and in a multi-file crate the two are
//! routinely in different files. Both scans — `#[pymethods]` blocks for
//! `#[pyclass]` structs (#275) and `#[julia] impl` blocks for `#[julia]`
//! structs (#315) — collect the structs and the impl blocks of the whole crate
//! separately and marry them afterwards, and this module is the one resolver
//! they share: the qualifier written in front of the type (`crate::a::C`,
//! `super::C`, `self::C`, `a::C`, a bare `C`), the `use` declarations of the
//! impl's module, and finally the one struct of that name anywhere.

use syn::{Ident, Item, ItemType, ItemUse, Type};

use crate::types::unparen;

/// Where a written path is rooted, which decides what a qualifier may match.
///
/// `crate::a::C` and `a::C` are **not** the same struct when the enclosing
/// module `m` also has an `a`: the first is `a::C` at the crate root, the
/// second is `m::a::C` (2018 paths) or, through a `use`, whatever brought `a`
/// into scope. Collapsing the two attached a `#[pymethods]` block to the wrong
/// class, which Phase 2 then compiled into a call to the wrong type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PathAnchor {
    /// `crate::…` — the crate root, and nothing else.
    Crate,
    /// `self::…` — the module the path was written in, and nothing else.
    SelfModule,
    /// A bare path: the enclosing module first, then the crate root.
    Relative,
    /// `super::…` (repeated `n` times): the module `n` levels above the one
    /// the path was written in, and nothing else. Treating it as
    /// uninformative sent `impl super::C` to a same-named `C` in the impl's
    /// own module (#307 review).
    Super(usize),
    /// A path this matcher cannot follow: `super` after another segment,
    /// which Rust itself rejects, or a qualified `<T as Trait>::C`. Nothing is
    /// matched on the qualifier at all.
    Unknown,
}

/// A path qualifier: where it is rooted and the module segments it names,
/// without the type's own name (`a::b::C` -> `["a", "b"]`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathQualifier {
    pub anchor: PathAnchor,
    pub segments: Vec<String>,
}

impl PathQualifier {
    pub fn relative(segments: Vec<String>) -> Self {
        PathQualifier {
            anchor: PathAnchor::Relative,
            segments,
        }
    }

    /// Whether the qualifier says nothing (a bare `impl C`, or a path this
    /// matcher cannot follow).
    pub fn is_uninformative(&self) -> bool {
        self.anchor == PathAnchor::Unknown
            || (self.anchor == PathAnchor::Relative && self.segments.is_empty())
    }

    /// Whether the qualifier names one place and one place only, so that when
    /// no struct is found there the block must be dropped rather than matched
    /// by its bare name: `super::C` is never the impl's own module's `C`.
    pub fn forbids_fallback(&self) -> bool {
        matches!(self.anchor, PathAnchor::Super(_))
    }

    /// The module paths this qualifier can name, from inside `module_path`,
    /// nearest first. A `super::` that walks past the crate root names
    /// nothing.
    pub fn candidates(&self, module_path: &[String]) -> Vec<Vec<String>> {
        let mut nested = module_path.to_vec();
        nested.extend(self.segments.iter().cloned());
        match self.anchor {
            PathAnchor::Unknown => Vec::new(),
            PathAnchor::Crate => vec![self.segments.clone()],
            PathAnchor::SelfModule => vec![nested],
            PathAnchor::Relative => vec![nested, self.segments.clone()],
            PathAnchor::Super(levels) => {
                if levels > module_path.len() {
                    return Vec::new();
                }
                let mut base = module_path[..module_path.len() - levels].to_vec();
                base.extend(self.segments.iter().cloned());
                vec![base]
            }
        }
    }

    /// The module path the **proc-macro** takes the struct to live at when it
    /// expands `#[julia] impl <qualifier>::C` inside the `#[julia]` modules
    /// `symbol_path` (#315).
    ///
    /// The macro sees the header and the marked modules around it, nothing
    /// else — not the struct, not the `use` declarations of a file module, not
    /// whether a segment names a file module (transparent to the symbol
    /// scheme, #300) or a marked inline one. So it reads the header literally:
    /// `crate::a::C` is `a::C`; `self::C` and a bare `C` are in the impl's own
    /// marked path; `super::C` one level up from it, and a `super::` that
    /// walks past the marked root lands at the crate root, because the file
    /// modules above it qualify nothing; a relative `a::C` is `a` below the
    /// impl's path, as a 2018 path is; a path it cannot follow is treated as
    /// bare. The extraction pass, which knows where the struct really is,
    /// compares this against the struct's own path and refuses the impl when
    /// they disagree, so the symbols the macro emits and the manifest describes
    /// cannot drift apart.
    pub fn macro_target_path(&self, symbol_path: &[String]) -> Vec<String> {
        let below = |base: &[String]| {
            let mut out = base.to_vec();
            out.extend(self.segments.iter().cloned());
            out
        };
        match self.anchor {
            PathAnchor::Crate => self.segments.clone(),
            PathAnchor::SelfModule | PathAnchor::Relative => below(symbol_path),
            PathAnchor::Unknown => symbol_path.to_vec(),
            PathAnchor::Super(levels) if levels <= symbol_path.len() => {
                below(&symbol_path[..symbol_path.len() - levels])
            }
            PathAnchor::Super(_) => self.segments.clone(),
        }
    }

    /// The qualifier as the header spelled it, for diagnostics
    /// (`crate::a::` for `impl crate::a::C`; empty for a bare `impl C`).
    pub fn display_prefix(&self) -> String {
        let mut parts: Vec<String> = match self.anchor {
            PathAnchor::Crate => vec!["crate".to_string()],
            PathAnchor::SelfModule => vec!["self".to_string()],
            PathAnchor::Super(levels) => vec!["super".to_string(); levels],
            PathAnchor::Relative | PathAnchor::Unknown => Vec::new(),
        };
        parts.extend(self.segments.iter().cloned());
        if parts.is_empty() {
            String::new()
        } else {
            format!("{}::", parts.join("::"))
        }
    }
}

/// The qualifier of a path type, anchor included. A qualified path
/// (`<T as Trait>::C`) cannot be followed.
pub fn type_path_qualifier(ty: &Type) -> PathQualifier {
    let Type::Path(p) = unparen(ty) else {
        return PathQualifier::relative(Vec::new());
    };
    if p.qself.is_some() {
        return PathQualifier {
            anchor: PathAnchor::Unknown,
            segments: Vec::new(),
        };
    }
    path_qualifier(p.path.segments.iter().map(|s| s.ident.to_string()))
}

/// Split a written path into its anchor and its module segments, dropping the
/// final segment (the item's own name).
pub fn path_qualifier(segments: impl IntoIterator<Item = String>) -> PathQualifier {
    let all: Vec<String> = segments.into_iter().collect();
    let mut anchor = PathAnchor::Relative;
    let mut out = Vec::new();
    let mut levels = 0usize;
    let count = all.len();
    for (i, name) in all.into_iter().enumerate() {
        if i == 0 {
            match name.as_str() {
                "crate" => {
                    anchor = PathAnchor::Crate;
                    continue;
                }
                "self" => {
                    anchor = PathAnchor::SelfModule;
                    continue;
                }
                "super" => {
                    levels = 1;
                    anchor = PathAnchor::Super(levels);
                    continue;
                }
                _ => {}
            }
        } else if name == "super" {
            // A run of leading `super`s walks up one level each; a `super`
            // after a named segment is not a path Rust accepts.
            if matches!(anchor, PathAnchor::Super(_)) && out.is_empty() {
                levels += 1;
                anchor = PathAnchor::Super(levels);
                continue;
            }
            return PathQualifier {
                anchor: PathAnchor::Unknown,
                segments: Vec::new(),
            };
        }
        if i + 1 < count {
            out.push(name);
        }
    }
    PathQualifier {
        anchor,
        segments: out,
    }
}

/// One `use` path in scope: where it was written, the name it binds, and the
/// module path it names.
#[derive(Debug, Clone)]
pub struct ScannedImport {
    pub module_path: Vec<String>,
    /// The name the import binds — the last segment, or the `as` alias.
    pub alias: String,
    /// The full path it names, anchor stripped: `crate::a::C` -> `["a", "C"]`.
    pub path: Vec<String>,
    /// Where that path is rooted, so `use crate::a::C;` and `use a::C;` are
    /// not confused when the enclosing module also has an `a`.
    pub qualifier: PathQualifier,
    /// Whether this is a glob import such as `use crate::model::*`.  Globs
    /// cannot name one alias, but they still disambiguate a bare impl header
    /// to the imported module (#303).
    pub glob: bool,
}

/// What a bare `impl C` in `module_path` could be referring to through the
/// `use` declaration `item`.
pub fn imports_of_use(item: &ItemUse, module_path: &[String]) -> Vec<ScannedImport> {
    let mut bindings = Vec::new();
    let mut prefix = Vec::new();
    flatten_use_tree(&item.tree, &mut prefix, &mut bindings);
    bindings
        .into_iter()
        .map(|(alias, anchored, glob)| {
            let qualifier = if glob {
                // `path_qualifier` normally drops the final item segment.
                // Add a sentinel so the module prefix of a glob remains in
                // the candidate path.
                path_qualifier(
                    anchored
                        .iter()
                        .cloned()
                        .chain(std::iter::once("__rustcall_glob__".to_string())),
                )
            } else {
                path_qualifier(anchored.iter().cloned())
            };
            // The anchor segments are not part of the module path; the
            // qualifier keeps what they meant.
            let path: Vec<String> = anchored
                .into_iter()
                .filter(|s| s != "crate" && s != "self" && s != "super")
                .collect();
            ScannedImport {
                module_path: module_path.to_vec(),
                alias,
                path,
                qualifier,
                glob,
            }
        })
        .collect()
}

/// Treat a plain path type alias as a local import for impl resolution. Rust
/// accepts `type Alias = crate::model::C; #[pymethods] impl Alias { ... }`,
/// while the scanner otherwise only sees the spelling `Alias` (#303).
pub fn import_of_type_alias(item: &ItemType, module_path: &[String]) -> Option<ScannedImport> {
    let Type::Path(path) = unparen(&item.ty) else {
        return None;
    };
    path.qself.is_none().then(|| {
        let anchored: Vec<String> = path
            .path
            .segments
            .iter()
            .map(|s| s.ident.to_string())
            .collect();
        let qualifier = path_qualifier(anchored.iter().cloned());
        let path = anchored
            .into_iter()
            .filter(|s| s != "crate" && s != "self" && s != "super")
            .collect();
        ScannedImport {
            module_path: module_path.to_vec(),
            alias: item.ident.to_string(),
            path,
            qualifier,
            glob: false,
        }
    })
}

/// Flatten a `use` tree into the names it binds and the paths they name,
/// **anchor included**.
///
/// `use crate::a::{C, D as E};` yields `("C", ["crate", "a", "C"])` and
/// `("E", ["crate", "a", "D"])`; the caller splits the anchor off with
/// [`path_qualifier`], so `use crate::a::C;` and `use a::C;` stay distinct.
/// A glob (`use a::*;`) binds no name it can be matched on and is skipped.
/// `super::` is kept: [`path_qualifier`] resolves it against the module the
/// `use` was written in, like any other anchor (#307 review).
fn flatten_use_tree(
    tree: &syn::UseTree,
    prefix: &mut Vec<String>,
    out: &mut Vec<(String, Vec<String>, bool)>,
) {
    match tree {
        syn::UseTree::Path(path) => {
            let segment = path.ident.to_string();
            prefix.push(segment);
            flatten_use_tree(&path.tree, prefix, out);
            prefix.pop();
        }
        syn::UseTree::Name(name) => {
            let mut full = prefix.clone();
            full.push(name.ident.to_string());
            out.push((name.ident.to_string(), full, false));
        }
        syn::UseTree::Rename(rename) => {
            let mut full = prefix.clone();
            full.push(rename.ident.to_string());
            out.push((rename.rename.to_string(), full, false));
        }
        syn::UseTree::Group(group) => {
            for item in &group.items {
                flatten_use_tree(item, prefix, out);
            }
        }
        // A glob binds no name this matcher can key on.
        syn::UseTree::Glob(_) => out.push(("*".to_string(), prefix.clone(), true)),
    }
}

/// An `impl` header as far as resolution is concerned: the type's own name,
/// the qualifier written in front of it, and the module the block sits in.
#[derive(Debug, Clone)]
pub struct ImplHeader {
    pub target: Ident,
    pub qualifier: PathQualifier,
    pub module_path: Vec<String>,
}

impl ImplHeader {
    /// The header of an inherent `impl`; `None` for a trait impl or a target
    /// that is not a path type.
    pub fn of(item: &syn::ItemImpl, module_path: &[String]) -> Option<Self> {
        if item.trait_.is_some() {
            return None;
        }
        let target = crate::types::last_ident(&item.self_ty)?.clone();
        Some(ImplHeader {
            target,
            qualifier: type_path_qualifier(&item.self_ty),
            module_path: module_path.to_vec(),
        })
    }

    /// The header as written, `impl crate::a::C`, for diagnostics.
    pub fn display(&self) -> String {
        format!("impl {}{}", self.qualifier.display_prefix(), self.target)
    }
}

/// A struct a header can be matched against: its name and the module it is
/// declared in.
pub trait Located {
    fn name(&self) -> &str;
    fn module_path(&self) -> &[String];
}

/// Why a header matched no struct, for the diagnostic of a scan that must not
/// drop the block silently (#315).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Unresolved {
    /// No struct of that name is where the header points (or anywhere, for a
    /// bare name).
    NotFound,
    /// A bare name that several modules declare, and nothing — qualifier,
    /// `use`, the impl's own module — picks one; the paths of the candidates.
    Ambiguous(Vec<Vec<String>>),
}

/// Locate the struct an `impl` header names among `structs`.
///
/// A header is matched, in order, to: the struct named by an explicit
/// qualifier (`impl a::C`, resolved against the impl's own module and against
/// the crate root); the struct of that name in the impl's own module; the one
/// a `use` in that module brought into scope under that name; and finally the
/// one struct of that name anywhere in the crate. When two modules declare
/// structs of the same name and nothing disambiguates, the block is not
/// attached to a guess — a wrong `Struct::method` would not compile — and the
/// caller decides how to report that.
pub fn locate<T: Located>(
    structs: &[T],
    header: &ImplHeader,
    imports: &[ScannedImport],
) -> Result<usize, Unresolved> {
    locate_with_fallback(structs, header, imports, true)
}

/// Resolve a return type using the same imports as impl targets, but never
/// discard a written qualifier to match an unrelated same-named class.
pub fn locate_type<T: Located>(
    structs: &[T],
    header: &ImplHeader,
    imports: &[ScannedImport],
) -> Result<usize, Unresolved> {
    locate_with_fallback(structs, header, imports, false)
}

fn locate_with_fallback<T: Located>(
    structs: &[T],
    header: &ImplHeader,
    imports: &[ScannedImport],
    allow_qualified_fallback: bool,
) -> Result<usize, Unresolved> {
    let name = header.target.to_string();
    let named = |s: &T| s.name() == name;

    if !header.qualifier.is_uninformative() {
        // An imported module alias is part of the path's meaning:
        // `use crate::z as alias; impl alias::C` names `z::C`, not a class
        // called `C` next to the impl. Refusing an unresolved alias also
        // avoids silently attaching the methods to a same-named local class
        // (#303).
        let alias_import = if header.qualifier.anchor == PathAnchor::Relative {
            header.qualifier.segments.first().and_then(|alias| {
                imports.iter().find(|import| {
                    import.module_path == header.module_path
                        && !import.glob
                        && import.alias == *alias
                })
            })
        } else {
            None
        };
        if let Some(import) = alias_import {
            let mut segments = import.path.clone();
            segments.extend(header.qualifier.segments.iter().skip(1).cloned());
            let imported = PathQualifier {
                anchor: import.qualifier.anchor,
                segments,
            };
            for candidate in imported.candidates(&header.module_path) {
                if let Some(i) = structs
                    .iter()
                    .position(|s| named(s) && s.module_path() == candidate.as_slice())
                {
                    return Ok(i);
                }
            }
            return Err(Unresolved::NotFound);
        }
        // `impl a::C` inside module `m` means `m::a::C`, or `a::C` from the
        // crate root — try both, nearest first. `impl crate::a::C` means
        // only the second, and `impl self::a::C` only the first.
        for candidate in header.qualifier.candidates(&header.module_path) {
            if let Some(i) = structs
                .iter()
                .position(|s| named(s) && s.module_path() == candidate.as_slice())
            {
                return Ok(i);
            }
        }
        // `impl super::C` names the parent module's `C` and nothing else:
        // with none there, attaching to a `C` in the impl's own module —
        // or to the one `C` anywhere — would be exactly the wrong struct
        // (#307 review).
        if !allow_qualified_fallback || header.qualifier.forbids_fallback() {
            return Err(Unresolved::NotFound);
        }
    }

    if let Some(i) = structs
        .iter()
        .position(|s| named(s) && s.module_path() == header.module_path.as_slice())
    {
        return Ok(i);
    }

    // A bare `impl C` is disambiguated by whatever brought `C` into scope:
    // `use crate::a::C;` in the impl's module names `a::C` exactly, even
    // though the impl itself writes no qualifier.
    for import in imports {
        if import.module_path != header.module_path || import.alias != name {
            continue;
        }
        let target = import.path.last().map(String::as_str).unwrap_or(&name);
        for candidate in import.qualifier.candidates(&header.module_path) {
            if let Some(i) = structs
                .iter()
                .position(|s| s.name() == target && s.module_path() == candidate.as_slice())
            {
                return Ok(i);
            }
        }
    }

    // A glob has no alias to compare, but `use a::*; impl C` is still scoped
    // to `a::C` before Rust considers unrelated same-named structs.  Only
    // accept a class whose module is exactly the imported module; this avoids
    // treating a nested module's private implementation as re-exported.
    for import in imports {
        if import.module_path != header.module_path || !import.glob {
            continue;
        }
        for candidate in import.qualifier.candidates(&header.module_path) {
            if let Some(i) = structs
                .iter()
                .position(|s| named(s) && s.module_path() == candidate.as_slice())
            {
                return Ok(i);
            }
        }
    }

    let matching: Vec<usize> = structs
        .iter()
        .enumerate()
        .filter(|(_, s)| named(s))
        .map(|(i, _)| i)
        .collect();
    match matching.as_slice() {
        [one] => Ok(*one),
        [] => Err(Unresolved::NotFound),
        many => Err(Unresolved::Ambiguous(
            many.iter()
                .map(|&i| structs[i].module_path().to_vec())
                .collect(),
        )),
    }
}

/// The `use` declarations among one level of items, for [`locate`].
pub fn imports_in(items: &[Item], module_path: &[String]) -> Vec<ScannedImport> {
    items
        .iter()
        .filter_map(|item| match item {
            Item::Use(u) => Some(imports_of_use(u, module_path)),
            _ => None,
        })
        .flatten()
        .collect()
}
