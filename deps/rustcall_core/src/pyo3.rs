//! Scanning a crate that only carries PyO3 attributes (#275, Phase 1).
//!
//! A crate written for [PyO3](https://pyo3.rs) has no RustCall attribute
//! anywhere, but its `#[pyfunction]` / `#[pyclass]` / `#[pymethods]` items are
//! ordinary Rust items: a wrapper crate can call them exactly like any other
//! dependency (verified end to end in the #275 MWE). This module reports those
//! items in the manifest so that a Phase-2 wrapper crate can generate
//! `extern "C"` entry points for them.
//!
//! Three rules shape what is reported:
//!
//! * **The manifest describes what Phase 2 *will* generate.** Every scanned
//!   item carries the symbol the wrapper crate is going to export
//!   (`rustcall_<name>` / `rustcall_<Struct>_<method>`, the #279 scheme) with
//!   [`Function::exported`] = `false`, because today nothing emits it.
//! * **`#[julia]` owns an item it also marks.** `#[julia]` is additive since
//!   #279 and already exports `rustcall_<name>`; emitting a second wrapper for
//!   the same item from the PyO3 side would collide on that symbol, so the
//!   scan skips any item carrying a RustCall attribute (it is reported through
//!   the `#[julia]` path instead).
//! * **Fail closed.** Anything the wrapper crate could not compile — a
//!   non-`pub` item, a signature mentioning a type that needs a live Python
//!   interpreter, a generic — is still reported, but with a
//!   [`skip_reason`](crate::manifest::skip_reason) so `@rust_crate` can tell
//!   the user *why* an item is missing instead of silently dropping it.
//!
//! `PyResult<T>` is deliberately **not** a skip reason: creating and dropping a
//! `PyErr` without an interpreter is safe, only rendering one is not (it panics
//! inside pyo3, and the panic crossing `extern "C"` aborts the process). It is
//! recorded as [`ReturnKind::PyResult`] with the `Ok` type, so Phase 2 can lower
//! it to an opaque error flag.

use syn::spanned::Spanned;
use syn::{FnArg, ImplItem, ImplItemFn, Item, ItemFn, ItemStruct, ReturnType, Type};

use crate::attrs::{
    julia_owns_entry_point, pyo3_field_access, pyo3_marker, pyo3_method_markers, pyo3_name,
    visibility_string, Pyo3Marker, Pyo3MethodMarker,
};
use crate::cfg::predicate_string;
use crate::extract::fn_args;
use crate::manifest::{
    skip_reason, Attribute, Field, Function, Manifest, Method, ReturnKind, Struct,
};
use crate::types::{
    extract_option_type, extract_result_type, generics_to_type_params, has_impl_trait,
    has_type_params, is_ffi_compatible_type, last_ident, needs_clone_for_getter,
    return_type_to_string, type_to_string, unparen,
};

/// Append every PyO3-only item of `items` to `manifest`.
///
/// `items` is one level of a parsed file; inline `mod`s are visited
/// recursively and their names recorded in `module_path`, because a wrapper
/// crate has to name the item as `user_crate::module::item`.
///
/// Returns the **out-of-line** module declarations found on the way
/// (`pub mod api;` with no body): they live in another file, which only a
/// caller that can read files — `rustcall-extract --crate-root` — can follow.
/// Scanning each `.rs` file as its own root instead would report `api::deep` as
/// a crate-root item and miss a private parent module entirely (#275).
pub fn extract_pyo3_items(items: &[Item], manifest: &mut Manifest) -> Vec<PendingModule> {
    let mut scan = Pyo3Scan::new();
    let pending = scan.file(items, &[], true, manifest);
    scan.finish(manifest);
    pending
}

/// One out-of-line `mod name;` declaration: where it sits in the module tree,
/// whether that position is reachable from outside the crate, where its file
/// lives relative to the declaring file's directory, and the `#[path = "..."]`
/// override if it has one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingModule {
    /// Module path of the declaration itself, including its own name.
    pub module_path: Vec<String>,
    /// Whether every module on the way here (and this one) is `pub`.
    pub reachable: bool,
    /// The module's name, i.e. the last element of `module_path`.
    pub name: String,
    /// `#[path = "..."]` on the declaration, if present.
    pub path_attr: Option<String>,
    /// The **inline** modules enclosing the declaration within its own file.
    ///
    /// rustc resolves `mod outer { pub mod child; }` in `src/lib.rs` to
    /// `src/outer/child.rs`, not `src/child.rs`: an inline module contributes a
    /// directory to the search path of its out-of-line children. Empty when the
    /// declaration is at the top level of its file.
    pub dir_components: Vec<String>,
}

/// Crate-wide state of a PyO3 scan.
///
/// `#[pyclass]` structs and their `#[pymethods]` blocks are collected
/// separately and married in [`Pyo3Scan::finish`], because Rust does not
/// require them to live together: `impl C` is legal in any module that has `C`
/// in scope, and in a multi-file crate the two are routinely in different
/// files. Matching them per file (or per module level) would silently drop the
/// methods of every such class.
#[derive(Debug, Default)]
pub struct Pyo3Scan {
    classes: Vec<ScannedClass>,
    impls: Vec<ScannedImpl>,
    imports: Vec<ScannedImport>,
}

#[derive(Debug)]
struct ScannedClass {
    module_path: Vec<String>,
    entry: Struct,
}

#[derive(Debug)]
struct ScannedImpl {
    module_path: Vec<String>,
    /// The module qualifier written in front of the type: `impl a::C` gives a
    /// relative `["a"]`, a bare `impl C` gives an empty one. It names the class
    /// exactly when several modules define one of that name, so it is kept
    /// rather than collapsed to the final identifier.
    qualifier: PathQualifier,
    target: syn::Ident,
    line: usize,
    funcs: Vec<ImplItemFn>,
}

/// Where a written path is rooted, which decides what a qualifier may match.
///
/// `crate::a::C` and `a::C` are **not** the same class when the enclosing
/// module `m` also has an `a`: the first is `a::C` at the crate root, the
/// second is `m::a::C` (2018 paths) or, through a `use`, whatever brought `a`
/// into scope. Collapsing the two attached a `#[pymethods]` block to the wrong
/// class, which Phase 2 then compiled into a call to the wrong type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PathAnchor {
    /// `crate::…` — the crate root, and nothing else.
    Crate,
    /// `self::…` — the module the path was written in, and nothing else.
    SelfModule,
    /// A bare path: the enclosing module first, then the crate root.
    Relative,
    /// `super::…`, which walks up an unknown number of levels for this
    /// matcher. Nothing is matched on the qualifier at all.
    Unknown,
}

/// A path qualifier: where it is rooted and the module segments it names,
/// without the type's own name (`a::b::C` -> `["a", "b"]`).
#[derive(Debug, Clone)]
struct PathQualifier {
    anchor: PathAnchor,
    segments: Vec<String>,
}

impl PathQualifier {
    fn relative(segments: Vec<String>) -> Self {
        PathQualifier {
            anchor: PathAnchor::Relative,
            segments,
        }
    }

    /// Whether the qualifier says nothing (a bare `impl C`, or a `super::`
    /// path this matcher cannot follow).
    fn is_uninformative(&self) -> bool {
        self.anchor == PathAnchor::Unknown
            || (self.anchor == PathAnchor::Relative && self.segments.is_empty())
    }

    /// The module paths this qualifier can name, from inside `module_path`,
    /// nearest first.
    fn candidates(&self, module_path: &[String]) -> Vec<Vec<String>> {
        let mut nested = module_path.to_vec();
        nested.extend(self.segments.iter().cloned());
        match self.anchor {
            PathAnchor::Unknown => Vec::new(),
            PathAnchor::Crate => vec![self.segments.clone()],
            PathAnchor::SelfModule => vec![nested],
            PathAnchor::Relative => vec![nested, self.segments.clone()],
        }
    }
}

/// The qualifier of a path type, anchor included.
fn type_path_qualifier(ty: &Type) -> PathQualifier {
    let Type::Path(p) = unparen(ty) else {
        return PathQualifier::relative(Vec::new());
    };
    path_qualifier(p.path.segments.iter().map(|s| s.ident.to_string()))
}

/// Split a written path into its anchor and its module segments, dropping the
/// final segment (the item's own name).
fn path_qualifier(segments: impl IntoIterator<Item = String>) -> PathQualifier {
    let all: Vec<String> = segments.into_iter().collect();
    let mut anchor = PathAnchor::Relative;
    let mut out = Vec::new();
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
                    return PathQualifier {
                        anchor: PathAnchor::Unknown,
                        segments: Vec::new(),
                    }
                }
                _ => {}
            }
        } else if name == "super" {
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

impl Pyo3Scan {
    pub fn new() -> Self {
        Pyo3Scan::default()
    }

    /// Scan one file of the crate. `module_path` is where the file sits in the
    /// module tree (empty for the crate root) and `reachable` says whether
    /// every `mod` leading to it is `pub`.
    ///
    /// Free functions go straight into `manifest`; classes and `#[pymethods]`
    /// blocks are held until [`Pyo3Scan::finish`].
    pub fn file(
        &mut self,
        items: &[Item],
        module_path: &[String],
        reachable: bool,
        manifest: &mut Manifest,
    ) -> Vec<PendingModule> {
        let mut path = module_path.to_vec();
        let mut dirs = Vec::new();
        let mut pending = Vec::new();
        self.level(
            items,
            &mut path,
            &mut dirs,
            reachable,
            manifest,
            &mut pending,
        );
        pending
    }

    fn level(
        &mut self,
        items: &[Item],
        module_path: &mut Vec<String>,
        dir_components: &mut Vec<String>,
        reachable: bool,
        manifest: &mut Manifest,
        pending: &mut Vec<PendingModule>,
    ) {
        for item in items {
            match item {
                Item::Fn(f) => {
                    if julia_owns_entry_point(&f.attrs) {
                        // Owned by `#[julia]`, which exports `rustcall_<name>`
                        // itself (#279): reporting it here would describe a
                        // second wrapper under the same symbol.
                        continue;
                    }
                    match pyo3_marker(&f.attrs) {
                        Some(Pyo3Marker::Function) => {
                            manifest.functions.push(function_entry(
                                f,
                                Attribute::PyFunction,
                                reachable,
                                module_path,
                            ));
                        }
                        Some(Pyo3Marker::Module) => {
                            manifest.functions.push(function_entry(
                                f,
                                Attribute::PyModule,
                                reachable,
                                module_path,
                            ));
                        }
                        _ => {}
                    }
                }
                Item::Struct(s) => {
                    if julia_owns_entry_point(&s.attrs) {
                        continue;
                    }
                    if pyo3_marker(&s.attrs) == Some(Pyo3Marker::Class) {
                        self.classes.push(ScannedClass {
                            module_path: module_path.clone(),
                            entry: class_entry(s, reachable, module_path),
                        });
                    }
                }
                Item::Impl(imp) => {
                    if pyo3_marker(&imp.attrs) != Some(Pyo3Marker::Methods) {
                        continue;
                    }
                    let Some(target) = last_ident(&imp.self_ty).cloned() else {
                        continue;
                    };
                    if imp.trait_.is_some() {
                        continue;
                    }
                    self.impls.push(ScannedImpl {
                        module_path: module_path.clone(),
                        // The qualifier of an explicit `impl a::C`, which names
                        // the class exactly when several modules define a `C`.
                        qualifier: type_path_qualifier(&imp.self_ty),
                        target,
                        line: imp.span().start().line,
                        funcs: imp
                            .items
                            .iter()
                            .filter_map(|ii| match ii {
                                ImplItem::Fn(f) => Some(f.clone()),
                                _ => None,
                            })
                            .collect(),
                    });
                }
                Item::Use(u) => {
                    // What a bare `impl C` in this module could be referring to.
                    let mut bindings = Vec::new();
                    let mut prefix = Vec::new();
                    flatten_use_tree(&u.tree, &mut prefix, &mut bindings);
                    for (alias, anchored) in bindings {
                        let qualifier = path_qualifier(anchored.iter().cloned());
                        // The anchor segment is not part of the module path.
                        let path: Vec<String> = anchored
                            .into_iter()
                            .filter(|s| s != "crate" && s != "self")
                            .collect();
                        self.imports.push(ScannedImport {
                            module_path: module_path.clone(),
                            alias,
                            path,
                            qualifier,
                        });
                    }
                }
                Item::Mod(m) => {
                    let inner_reachable = reachable && matches!(m.vis, syn::Visibility::Public(_));
                    module_path.push(m.ident.to_string());
                    match &m.content {
                        Some((_, inner)) => {
                            dir_components.push(m.ident.to_string());
                            self.level(
                                inner,
                                module_path,
                                dir_components,
                                inner_reachable,
                                manifest,
                                pending,
                            );
                            dir_components.pop();
                        }
                        // `mod name;` — the body is in another file; record
                        // where it belongs so the caller can follow it.
                        None => pending.push(PendingModule {
                            module_path: module_path.clone(),
                            reachable: inner_reachable,
                            name: m.ident.to_string(),
                            path_attr: path_attribute(&m.attrs),
                            dir_components: dir_components.clone(),
                        }),
                    }
                    module_path.pop();
                }
                _ => {}
            }
        }
    }

    /// Attach every `#[pymethods]` block to its class and emit the structs.
    ///
    /// A block is matched, in order, to: the class named by an explicit
    /// qualifier (`impl a::C`, resolved against the impl's own module and
    /// against the crate root); the class of that name in the impl's own
    /// module; and finally the one class of that name anywhere in the crate.
    /// When two modules define classes of the same name and nothing
    /// disambiguates, the block is dropped rather than attached to a guess — a
    /// wrong `Struct::method` would not compile in Phase 2.
    ///
    /// Order is by (module path, line) so the result does not depend on the
    /// order the caller happened to visit files in.
    pub fn finish(mut self, manifest: &mut Manifest) {
        self.impls
            .sort_by(|a, b| a.module_path.cmp(&b.module_path).then(a.line.cmp(&b.line)));

        for imp in &self.impls {
            let Some(index) = self.locate_class(imp) else {
                continue;
            };
            let owner_skip = self.classes[index].entry.skip_reason.clone();
            for func in &imp.funcs {
                let entry = method_entry(&imp.target, func, &owner_skip);
                self.classes[index].entry.methods.push(entry);
            }
        }

        manifest
            .structs
            .extend(self.classes.into_iter().map(|c| c.entry));
        mark_symbol_collisions(manifest);
    }

    fn locate_class(&self, imp: &ScannedImpl) -> Option<usize> {
        let name = imp.target.to_string();
        let named = |c: &ScannedClass| c.entry.name == name;

        if !imp.qualifier.is_uninformative() {
            // `impl a::C` inside module `m` means `m::a::C`, or `a::C` from the
            // crate root — try both, nearest first. `impl crate::a::C` means
            // only the second, and `impl self::a::C` only the first.
            for candidate in imp.qualifier.candidates(&imp.module_path) {
                if let Some(i) = self
                    .classes
                    .iter()
                    .position(|c| named(c) && c.module_path == candidate)
                {
                    return Some(i);
                }
            }
        }

        if let Some(i) = self
            .classes
            .iter()
            .position(|c| named(c) && c.module_path == imp.module_path)
        {
            return Some(i);
        }

        // A bare `impl C` is disambiguated by whatever brought `C` into scope:
        // `use crate::a::C;` in the impl's module names `a::C` exactly, even
        // though the impl itself writes no qualifier.
        for import in &self.imports {
            if import.module_path != imp.module_path || import.alias != name {
                continue;
            }
            let target = import.path.last().map(String::as_str).unwrap_or(&name);
            for candidate in import.qualifier.candidates(&imp.module_path) {
                if let Some(i) = self
                    .classes
                    .iter()
                    .position(|c| c.entry.name == target && c.module_path == candidate)
                {
                    return Some(i);
                }
            }
        }

        let mut matching = self.classes.iter().enumerate().filter(|(_, c)| named(c));
        match (matching.next(), matching.next()) {
            (Some((i, _)), None) => Some(i),
            // No class of that name, or an ambiguous one.
            _ => None,
        }
    }
}

/// One `use` path in scope: where it was written, the name it binds, and the
/// module path it names.
#[derive(Debug)]
struct ScannedImport {
    module_path: Vec<String>,
    /// The name the import binds — the last segment, or the `as` alias.
    alias: String,
    /// The full path it names, anchor stripped: `crate::a::C` -> `["a", "C"]`.
    path: Vec<String>,
    /// Where that path is rooted, so `use crate::a::C;` and `use a::C;` are
    /// not confused when the enclosing module also has an `a`.
    qualifier: PathQualifier,
}

/// Flatten a `use` tree into the names it binds and the paths they name,
/// **anchor included**.
///
/// `use crate::a::{C, D as E};` yields `("C", ["crate", "a", "C"])` and
/// `("E", ["crate", "a", "D"])`; the caller splits the anchor off with
/// [`path_qualifier`], so `use crate::a::C;` and `use a::C;` stay distinct.
/// A glob (`use a::*;`) binds no name it can be matched on and is skipped;
/// `super::` is dropped for the same reason [`type_path_qualifier`] drops it.
fn flatten_use_tree(
    tree: &syn::UseTree,
    prefix: &mut Vec<String>,
    out: &mut Vec<(String, Vec<String>)>,
) {
    match tree {
        syn::UseTree::Path(path) => {
            let segment = path.ident.to_string();
            if segment == "super" {
                return;
            }
            prefix.push(segment);
            flatten_use_tree(&path.tree, prefix, out);
            prefix.pop();
        }
        syn::UseTree::Name(name) => {
            let mut full = prefix.clone();
            full.push(name.ident.to_string());
            out.push((name.ident.to_string(), full));
        }
        syn::UseTree::Rename(rename) => {
            let mut full = prefix.clone();
            full.push(rename.ident.to_string());
            out.push((rename.rename.to_string(), full));
        }
        syn::UseTree::Group(group) => {
            for item in &group.items {
                flatten_use_tree(item, prefix, out);
            }
        }
        // A glob binds no name this matcher can key on.
        syn::UseTree::Glob(_) => {}
    }
}

/// Flag every wrappable PyO3 entry whose exported symbol another one already
/// claims (#275).
///
/// The symbol scheme is `rustcall_<name>` (#279), which does not include the
/// module path, so two `pub fn run` in different modules of one crate both want
/// `rustcall_run` — and a single wrapper crate cannot export both. The scan
/// reports the clash rather than emitting a manifest that cannot be built;
/// changing the scheme is a decision that has to be made for `#[julia]` at the
/// same time, since it has the identical collision (#300).
///
/// The first entry in manifest order keeps the symbol so the outcome does not
/// depend on which file was visited first.
fn mark_symbol_collisions(manifest: &mut Manifest) {
    // One table for every exported symbol of the whole manifest, whatever
    // produces it: a `#[julia]` function's wrapper, a `#[julia]` struct's
    // method and accessor wrappers, and the PyO3 entries the scan just added.
    // They all live in one `cdylib`, so `rustcall_C_f` from a `#[julia]`
    // `impl C { fn f }` and from a `#[pyclass] C` with `#[pymethods] fn f`
    // are the same symbol even though nothing else about them matches.
    let mut taken: Vec<(String, String)> = Vec::new();

    // Items already exported by a RustCall attribute own their symbols
    // outright: a PyO3 entry that wants one is the loser whatever the order.
    for f in manifest
        .functions
        .iter()
        .filter(|f| !f.attribute.is_pyo3_scan())
    {
        if f.exported && !f.symbol.is_empty() {
            taken.push((f.symbol.clone(), qualified(&f.module_path, &f.name)));
        }
    }
    for s in manifest
        .structs
        .iter()
        .filter(|s| !s.attribute.is_pyo3_scan())
    {
        for symbol in struct_symbols(s) {
            taken.push((symbol, qualified(&s.module_path, &s.name)));
        }
    }

    let mut order: Vec<usize> = (0..manifest.functions.len()).collect();
    order.sort_by(|&a, &b| {
        let (x, y) = (&manifest.functions[a], &manifest.functions[b]);
        x.module_path
            .cmp(&y.module_path)
            .then(x.line.cmp(&y.line))
            .then(x.name.cmp(&y.name))
    });

    for i in order {
        let f = &manifest.functions[i];
        if !f.attribute.is_pyo3_scan() || !f.skip_reason.is_empty() || f.symbol.is_empty() {
            continue;
        }
        let symbol = f.symbol.clone();
        if let Some((_, owner)) = taken.iter().find(|(s, _)| *s == symbol) {
            let owner = owner.clone();
            manifest.functions[i].skip_reason =
                skip_reason::detailed(skip_reason::SYMBOL_COLLISION, &owner);
        } else {
            let owner = qualified(&f.module_path, &f.name);
            taken.push((symbol, owner));
        }
    }

    // A class whose *name* another struct entry already claimed collides on
    // every one of its symbols at once, so there the class is the unit. Any
    // other clash — with a free function, or between a class's own method and
    // one of its field accessors — is reported on the individual entry, which
    // leaves the rest of the class wrappable.
    let mut class_names: Vec<(String, String)> = manifest
        .structs
        .iter()
        .filter(|s| !s.attribute.is_pyo3_scan())
        .map(|s| (s.name.clone(), qualified(&s.module_path, &s.name)))
        .collect();

    let mut struct_order: Vec<usize> = (0..manifest.structs.len()).collect();
    struct_order.sort_by(|&a, &b| {
        let (x, y) = (&manifest.structs[a], &manifest.structs[b]);
        x.module_path
            .cmp(&y.module_path)
            .then(x.line.cmp(&y.line))
            .then(x.name.cmp(&y.name))
    });
    for i in struct_order {
        let s = &manifest.structs[i];
        if !s.attribute.is_pyo3_scan() || !s.skip_reason.is_empty() {
            continue;
        }
        let name = s.name.clone();

        if let Some((_, owner)) = class_names.iter().find(|(n, _)| *n == name) {
            let reason = skip_reason::detailed(skip_reason::SYMBOL_COLLISION, &owner.clone());
            let s = &mut manifest.structs[i];
            s.skip_reason = reason.clone();
            for m in &mut s.methods {
                if m.skip_reason.is_empty() {
                    m.skip_reason = skip_reason::detailed(skip_reason::OWNER_SKIPPED, &reason);
                }
            }
            for f in &mut s.fields {
                f.ffi_compatible = false;
                f.getter.clear();
                f.setter.clear();
            }
            continue;
        }

        // Methods claim their symbols before field accessors do, so a
        // `#[setter(x)] fn set_x` and a `#[pyo3(set)] x` — which both want
        // `rustcall_C_set_x` — leave the method wrappable and drop the
        // accessor, rather than taking the whole class down.
        let owner = qualified(&s.module_path, &s.name);
        let s = &mut manifest.structs[i];
        for m in &mut s.methods {
            if !m.skip_reason.is_empty() || m.symbol.is_empty() {
                continue;
            }
            match taken.iter().find(|(t, _)| *t == m.symbol) {
                Some((_, other)) => {
                    m.skip_reason = skip_reason::detailed(skip_reason::SYMBOL_COLLISION, other);
                }
                None => taken.push((m.symbol.clone(), owner.clone())),
            }
        }
        for f in &mut s.fields {
            for accessor in [&mut f.getter, &mut f.setter] {
                if accessor.is_empty() {
                    continue;
                }
                match taken.iter().find(|(t, _)| t == accessor) {
                    Some(_) => accessor.clear(),
                    None => taken.push((accessor.clone(), owner.clone())),
                }
            }
            if f.getter.is_empty() && f.setter.is_empty() {
                f.ffi_compatible = false;
            }
        }
        class_names.push((name, owner));
    }
}

/// Every symbol a struct entry claims: its wrappable methods and its field
/// accessors.
fn struct_symbols(s: &Struct) -> Vec<String> {
    let mut out = Vec::new();
    for m in &s.methods {
        if m.skip_reason.is_empty() && !m.symbol.is_empty() {
            out.push(m.symbol.clone());
        }
    }
    for f in &s.fields {
        if !f.getter.is_empty() {
            out.push(f.getter.clone());
        }
        if !f.setter.is_empty() {
            out.push(f.setter.clone());
        }
    }
    out
}

fn qualified(module_path: &[String], name: &str) -> String {
    if module_path.is_empty() {
        name.to_string()
    } else {
        format!("{}::{}", module_path.join("::"), name)
    }
}

/// The `#[path = "..."]` override of a `mod` declaration, if it has one.
fn path_attribute(attrs: &[syn::Attribute]) -> Option<String> {
    for attr in attrs {
        if !attr.path().is_ident("path") {
            continue;
        }
        if let syn::Meta::NameValue(nv) = &attr.meta {
            if let syn::Expr::Lit(lit) = &nv.value {
                if let syn::Lit::Str(s) = &lit.lit {
                    return Some(s.value());
                }
            }
        }
    }
    None
}

/// Manifest entry of a `#[pyfunction]` (or a `#[pymodule]` initialiser).
fn function_entry(
    func: &ItemFn,
    attribute: Attribute,
    reachable: bool,
    module_path: &[String],
) -> Function {
    let name = func.sig.ident.to_string();
    let is_generic = has_type_params(&func.sig.generics) || has_impl_trait(&func.sig);
    let return_type = return_type_to_string(&func.sig.output);

    let (return_kind, ok_type, err_type, inner_type) = return_shape(&func.sig.output);

    let reason = if attribute == Attribute::PyModule {
        skip_reason::PYMODULE.to_string()
    } else {
        item_skip_reason(&func.vis, reachable, is_generic)
            .unwrap_or_else(|| signature_skip_reason(&func.sig, return_kind).unwrap_or_default())
    };

    Function {
        name: name.clone(),
        // What Phase 2 will export, not what exists today.
        symbol: crate::codegen::function_symbol(&name),
        attribute,
        vis: visibility_string(&func.vis),
        skip_reason: reason,
        python_name: pyo3_name(&func.attrs),
        exported: false,
        cfg: predicate_string(&func.attrs),
        cfg_features: crate::cfg::predicate_features(&func.attrs),
        is_generic,
        type_params: generics_to_type_params(&func.sig.generics),
        args: fn_args(&func.sig),
        return_type,
        return_kind,
        // `Arg::abi` follows from the argument type alone, so it is filled in
        // as usual; the *return* lowering depends on how Phase 2 chooses to
        // wrap a `PyResult`, so it stays empty until a wrapper exists.
        return_abi: String::new(),
        ok_type,
        err_type,
        inner_type,
        // Same reason: no wrapper exists yet, so no payload lowering (#268).
        ok_abi: String::new(),
        err_abi: String::new(),
        inner_abi: String::new(),
        has_owned_string_helper: false,
        has_borrowed_string_helper: false,
        source: String::new(),
        body_has_cfg: crate::cfg::body_has_cfg(&func.block),
        line: func.span().start().line,
        module_path: module_path.to_vec(),
    }
}

/// Manifest entry of a `#[pyclass]` struct: an opaque handle. A `#[pyclass]` is
/// never `#[repr(C)]` (pyo3 owns its layout), so fields are only reachable
/// through the accessors pyo3 itself declares with `#[pyo3(get, set)]`.
fn class_entry(item: &ItemStruct, reachable: bool, module_path: &[String]) -> Struct {
    let is_generic = has_type_params(&item.generics);
    let reason = item_skip_reason(&item.vis, reachable, is_generic).unwrap_or_default();
    let name = item.ident.to_string();

    // `#[pyclass(get_all, set_all)]` exposes every field without a per-field
    // attribute, and `frozen` takes every setter away. `transform_struct_julia_pyo3`
    // in this repository generates exactly that shape, so a scan that read only
    // field attributes would drop those fields.
    let options = crate::attrs::pyo3_class_options(&item.attrs);

    let mut fields = Vec::new();
    if let syn::Fields::Named(named) = &item.fields {
        for f in &named.named {
            let Some(ident) = f.ident.clone() else {
                continue;
            };
            let mut access = pyo3_field_access(&f.attrs);
            access.get |= options.get_all;
            access.set |= options.set_all;
            access.set &= !options.frozen;
            if !access.get && !access.set {
                continue;
            }
            // A `#[pyo3(get)]` on a private field still gives Python a
            // descriptor — pyo3 generates it inside the crate — but a wrapper
            // crate compiled outside cannot read `Struct::field` (E0603), so
            // only a `pub` field gets accessors. A skipped class has no handle
            // type, so its fields have none either, whatever their visibility.
            let field_is_public = matches!(f.vis, syn::Visibility::Public(_));
            let usable = reason.is_empty()
                && field_is_public
                && pyo3_type_in(&f.ty).is_none()
                && (is_ffi_compatible_type(&f.ty) || needs_clone_for_getter(&f.ty));
            fields.push(Field {
                name: ident.to_string(),
                rust_type: type_to_string(&f.ty),
                abi: crate::codegen::field_abi(&f.ty).to_string(),
                ffi_compatible: usable,
                getter: if usable && access.get {
                    crate::codegen::method_symbol(&name, &format!("get_{ident}"))
                } else {
                    String::new()
                },
                setter: if usable && access.set {
                    crate::codegen::method_symbol(&name, &format!("set_{ident}"))
                } else {
                    String::new()
                },
                python_name: access.python_name,
                vis: visibility_string(&f.vis),
            });
        }
    }

    Struct {
        name: name.clone(),
        attribute: Attribute::PyClass,
        vis: visibility_string(&item.vis),
        skip_reason: reason,
        python_name: pyo3_name(&item.attrs),
        cfg: predicate_string(&item.attrs),
        cfg_features: crate::cfg::predicate_features(&item.attrs),
        type_params: generics_to_type_params(&item.generics),
        fields,
        methods: Vec::new(),
        derives: crate::attrs::derive_list(&item.attrs),
        has_clone: false,
        has_owned_string_helper: false,
        has_borrowed_string_helper: false,
        context_source: String::new(),
        generic_wrappers: Vec::new(),
        line: item.span().start().line,
        module_path: module_path.to_vec(),
    }
}

/// Manifest entry of one method of a `#[pymethods]` block.
fn method_entry(struct_ident: &syn::Ident, func: &ImplItemFn, owner_skip: &str) -> Method {
    let struct_name = struct_ident.to_string();
    let markers = pyo3_method_markers(&func.attrs);
    let has = |m: Pyo3MethodMarker| markers.contains(&m);
    let receiver = func.sig.inputs.iter().find_map(|a| match a {
        FnArg::Receiver(r) => Some(r),
        _ => None,
    });
    let name = func.sig.ident.to_string();
    let is_constructor = has(Pyo3MethodMarker::New);
    let accessor = if has(Pyo3MethodMarker::Getter) {
        "getter"
    } else if has(Pyo3MethodMarker::Setter) {
        "setter"
    } else {
        ""
    };

    let is_generic = has_type_params(&func.sig.generics) || has_impl_trait(&func.sig);
    // The same structured description a free function gets, so a Phase-2
    // wrapper can lower a `PyResult` method without re-reading the Rust type
    // spelling (Rust syntax is parsed only here, #264).
    let (return_kind, ok_type, err_type, inner_type) = return_shape(&func.sig.output);
    let reason = if !owner_skip.is_empty() {
        skip_reason::detailed(skip_reason::OWNER_SKIPPED, owner_skip)
    } else {
        item_skip_reason(&func.vis, true, is_generic)
            .unwrap_or_else(|| signature_skip_reason(&func.sig, return_kind).unwrap_or_default())
    };

    Method {
        name: name.clone(),
        symbol: crate::codegen::method_symbol(&struct_name, &name),
        // `#[staticmethod]` and `#[classmethod]` are both static from the C
        // side: neither takes a `self` receiver. A `#[classmethod]` takes a
        // `&Bound<'_, PyType>` first argument instead, so it is normally
        // skipped for using a pyo3 type.
        is_static: receiver.is_none(),
        is_mutable: receiver.map(|r| r.mutability.is_some()).unwrap_or(false),
        is_constructor,
        vis: visibility_string(&func.vis),
        skip_reason: reason,
        python_name: pyo3_name(&func.attrs),
        accessor: accessor.to_string(),
        return_kind,
        ok_type,
        err_type,
        inner_type,
        // No `#[julia]` wrapper exists for a scanned PyO3 item, so no payload
        // lowering (#268).
        ok_abi: String::new(),
        err_abi: String::new(),
        inner_abi: String::new(),
        // A `#[new]`, and any other method returning `Self`, hands back the
        // class itself — an opaque handle a wrapper boxes (`#[pyclass]` is
        // never `repr(C)`), decided by the same rule the `#[julia]` path uses.
        returns_boxed_struct: crate::codegen::returns_boxed_struct(struct_ident, func),
        args: fn_args(&func.sig),
        return_type: return_type_to_string(&func.sig.output),
        return_abi: String::new(),
        generic_wrapper: String::new(),
    }
}

/// Skip reason that follows from the item itself rather than its signature.
///
/// Precedence is deliberate: visibility first, because it is the hard
/// compile-time blocker a wrapper crate hits (`E0603`), then genericity.
fn item_skip_reason(vis: &syn::Visibility, reachable: bool, is_generic: bool) -> Option<String> {
    if !matches!(vis, syn::Visibility::Public(_)) || !reachable {
        return Some(skip_reason::NOT_PUBLIC.to_string());
    }
    if is_generic {
        return Some(skip_reason::GENERIC.to_string());
    }
    None
}

/// Skip reason that follows from the signature: any argument or return type
/// that only exists with a live Python interpreter.
///
/// A `PyResult<T>` return is exempt — the error is opaque, never rendered — but
/// its `Ok` type is still checked, so `PyResult<PyObject>` is skipped.
fn signature_skip_reason(sig: &syn::Signature, return_kind: ReturnKind) -> Option<String> {
    for input in &sig.inputs {
        let FnArg::Typed(pt) = input else { continue };
        if let Some(found) = pyo3_type_in(&pt.ty) {
            return Some(skip_reason::detailed(skip_reason::PYO3_TYPE, &found));
        }
    }
    if let ReturnType::Type(_, ty) = &sig.output {
        let checked = if return_kind == ReturnKind::PyResult {
            py_result_ok_type(ty).unwrap_or_else(|| (**ty).clone())
        } else {
            (**ty).clone()
        };
        if let Some(found) = pyo3_type_in(&checked) {
            return Some(skip_reason::detailed(skip_reason::PYO3_TYPE, &found));
        }
    }
    None
}

/// How a scanned PyO3 item returns: `(kind, ok_type, err_type, inner_type)`,
/// with the same vocabulary a `#[julia]` function's manifest entry uses.
///
/// `PyResult<T>` is [`ReturnKind::PyResult`] with `T` as the ok type and no
/// error type: a `PyErr` is opaque and must never be rendered, so there is
/// nothing for a consumer to name.
fn return_shape(output: &ReturnType) -> (ReturnKind, String, String, String) {
    let mut ok_type = String::new();
    let mut err_type = String::new();
    let mut inner_type = String::new();
    let kind = match output {
        ReturnType::Default => ReturnKind::Unit,
        ReturnType::Type(_, ty) => {
            if let Some(ok) = py_result_ok_type(ty) {
                ok_type = type_to_string(&ok);
                ReturnKind::PyResult
            } else if let Some(r) = extract_result_type(ty) {
                ok_type = type_to_string(&r.ok_type);
                err_type = type_to_string(&r.err_type);
                ReturnKind::Result
            } else if let Some(o) = extract_option_type(ty) {
                inner_type = type_to_string(&o.inner_type);
                ReturnKind::Option
            } else if return_type_to_string(output) == "()" {
                ReturnKind::Unit
            } else {
                ReturnKind::Plain
            }
        }
    };
    (kind, ok_type, err_type, inner_type)
}

/// `T` of a `PyResult<T>` (or `pyo3::PyResult<T>`), if the type is one.
pub fn py_result_ok_type(ty: &Type) -> Option<Type> {
    let Type::Path(path) = unparen(ty) else {
        return None;
    };
    let segment = path.path.segments.last()?;
    if segment.ident != "PyResult" {
        return None;
    }
    match &segment.arguments {
        syn::PathArguments::AngleBracketed(args) => args.args.iter().find_map(|a| match a {
            syn::GenericArgument::Type(t) => Some(t.clone()),
            _ => None,
        }),
        // `PyResult` with no argument is `PyResult<()>` only by alias default;
        // syn sees no argument, so report the unit type.
        _ => Some(syn::parse_quote!(())),
    }
}

/// The first type inside `ty` that only exists with a Python interpreter, as
/// written, or `None` when the type is interpreter-free.
///
/// Recognised: anything whose path starts with `pyo3`, the `Python` /
/// `GILGuard` / `Bound` / `Borrowed` handles, and any identifier starting with
/// `Py` (`PyObject`, `PyAny`, `PyRef`, `PyRefMut`, `PyErr`, `PyList`, ...).
/// The last rule is deliberately broad and can catch a user type named
/// `PyFoo`; erring towards *skipped with a reason* is the fail-closed side,
/// since the alternative is a wrapper crate that does not compile.
pub fn pyo3_type_in(ty: &Type) -> Option<String> {
    let mut found = None;
    walk_types(ty, &mut |t| {
        if found.is_some() {
            return;
        }
        if let Type::Path(p) = t {
            let first_is_pyo3 = p
                .path
                .segments
                .first()
                .map(|s| s.ident == "pyo3")
                .unwrap_or(false);
            let last = p.path.segments.last();
            let named = last
                .map(|s| {
                    let id = s.ident.to_string();
                    id.starts_with("Py")
                        || matches!(id.as_str(), "Python" | "GILGuard" | "Bound" | "Borrowed")
                })
                .unwrap_or(false);
            if first_is_pyo3 || named {
                found = Some(type_to_string(t));
            }
        }
    });
    found
}

/// Apply `f` to `ty` and to every type nested in it.
fn walk_types(ty: &Type, f: &mut impl FnMut(&Type)) {
    let ty = unparen(ty);
    f(ty);
    match ty {
        Type::Path(p) => {
            for segment in &p.path.segments {
                if let syn::PathArguments::AngleBracketed(args) = &segment.arguments {
                    for arg in &args.args {
                        if let syn::GenericArgument::Type(t) = arg {
                            walk_types(t, f);
                        }
                    }
                }
            }
        }
        Type::Reference(r) => walk_types(&r.elem, f),
        Type::Ptr(p) => walk_types(&p.elem, f),
        Type::Slice(s) => walk_types(&s.elem, f),
        Type::Array(a) => walk_types(&a.elem, f),
        Type::Group(g) => walk_types(&g.elem, f),
        Type::Tuple(t) => {
            for elem in &t.elems {
                walk_types(elem, f);
            }
        }
        _ => {}
    }
}
