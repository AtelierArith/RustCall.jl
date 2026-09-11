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
    pyo3_signature, visibility_string, Pyo3Marker, Pyo3MethodMarker, Pyo3ParameterKind,
};
use crate::cfg::predicate_string;
use crate::extract::fn_args;
use crate::manifest::{
    skip_reason, Attribute, Field, Function, Manifest, Method, ReturnKind, Struct,
};
use crate::paths::{
    import_of_type_alias, imports_of_use, locate, ImplHeader, Located, ScannedImport,
};
use crate::types::{
    extract_option_type, extract_result_type, generics_to_type_params, has_impl_trait,
    has_type_params, is_ffi_compatible_type, is_str_ref_type, is_string_type,
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
    let pending = scan.file(items, &[], true, &[], manifest);
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
    /// The `#[cfg]` attributes of the declaration and of every module enclosing
    /// it, which every item in the module's file inherits (#300 review).
    pub cfg: Vec<syn::Attribute>,
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
    routes: crate::public_routes::PublicRoutes,
    edition_2015: bool,
    intrinsic_skips: std::collections::BTreeMap<(Vec<String>, String, usize, String), String>,
}

impl Pyo3Scan {
    pub fn with_edition(edition: &str) -> Self {
        Self {
            routes: crate::public_routes::PublicRoutes::with_edition(edition),
            edition_2015: edition == "2015",
            ..Self::default()
        }
    }
}

#[derive(Debug)]
struct ScannedClass {
    module_path: Vec<String>,
    entry: Struct,
    visibility: syn::Visibility,
    /// Accessors under the same field/type checks, before module reachability
    /// disables them. A public re-export can restore that reachability later.
    reachable_fields: Vec<Field>,
    /// The `#[cfg]` of the enclosing modules: what tells cfg-exclusive copies
    /// of one fragment apart, and what a `#[pymethods]` block written beside
    /// one copy shares with it (#357 review).
    cfg: Vec<syn::Attribute>,
}

#[derive(Debug)]
struct ScannedImpl {
    /// The type the block is for, the qualifier written in front of it
    /// (`impl a::C` names the class exactly when several modules define a
    /// `C`) and the module the block sits in — what the shared resolver in
    /// `crate::paths` matches on.
    header: ImplHeader,
    line: usize,
    funcs: Vec<ImplItemFn>,
    /// The `#[cfg]` of the block itself and of every module enclosing it: a
    /// `#[pymethods]` block may sit in a gated module far from its class, and
    /// its methods exist only under that predicate (#300 review).
    cfg: Vec<syn::Attribute>,
    /// The enclosing modules' `#[cfg]` alone; see [`ScannedClass::cfg`].
    enclosing_cfg: Vec<syn::Attribute>,
}

/// The classes a `#[pymethods]` block resolved to `index` attaches to, among
/// the cfg-exclusive copies of that class at that module path: the copy whose
/// enclosing `#[cfg]` is `enclosing` when there is one; else every copy whose
/// predicate can coexist with `enclosing` — a block written outside the
/// copies applies to whichever one rustc compiles; else the located one
/// (#357 review).
fn cfg_variants_of(
    classes: &[ScannedClass],
    index: usize,
    enclosing: &[syn::Attribute],
) -> Vec<usize> {
    let want = crate::cfg::predicate_string(enclosing);
    let here = &classes[index];
    let same =
        |c: &ScannedClass| c.entry.name == here.entry.name && c.module_path == here.module_path;
    if crate::cfg::predicate_string(&here.cfg) == want {
        return vec![index];
    }
    if let Some(exact) = classes
        .iter()
        .position(|c| same(c) && crate::cfg::predicate_string(&c.cfg) == want)
    {
        return vec![exact];
    }
    // Written outside every copy — at the root, or in a module gated on
    // something else: every copy whose predicate can hold together with the
    // block's, i.e. all but the provably exclusive ones (#357 review).
    let overlapping: Vec<usize> = classes
        .iter()
        .enumerate()
        .filter(|(_, c)| same(c) && !cfg_exclusive(&crate::cfg::predicate_string(&c.cfg), &want))
        .map(|(i, _)| i)
        .collect();
    if !overlapping.is_empty() {
        return overlapping;
    }
    vec![index]
}

impl Located for ScannedClass {
    fn name(&self) -> &str {
        &self.entry.name
    }

    fn module_path(&self) -> &[String] {
        &self.module_path
    }

    fn visible_from(&self, module_path: &[String]) -> bool {
        crate::paths::visible_from(&self.visibility, &self.module_path, module_path)
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
    ///
    /// `enclosing_cfg` is the `#[cfg]` of every module on the way to this
    /// file; every item found inherits it in its `cfg` / `cfg_features`, so a
    /// wrapper generated from a lenient scan refuses an item whose *module* is
    /// gated exactly as it refuses one gated itself (#300 review).
    pub fn file(
        &mut self,
        items: &[Item],
        module_path: &[String],
        reachable: bool,
        enclosing_cfg: &[syn::Attribute],
        manifest: &mut Manifest,
    ) -> Vec<PendingModule> {
        self.routes.file(items, module_path, enclosing_cfg);
        let mut path = module_path.to_vec();
        let mut dirs = Vec::new();
        let mut pending = Vec::new();
        self.level(
            items,
            &mut path,
            &mut dirs,
            reachable,
            enclosing_cfg,
            manifest,
            &mut pending,
        );
        pending
    }

    #[allow(clippy::too_many_arguments)]
    fn level(
        &mut self,
        items: &[Item],
        module_path: &mut Vec<String>,
        dir_components: &mut Vec<String>,
        reachable: bool,
        enclosing_cfg: &[syn::Attribute],
        manifest: &mut Manifest,
        pending: &mut Vec<PendingModule>,
    ) {
        for item in items {
            match item {
                Item::Type(alias) => {
                    if let Some(import) =
                        import_of_type_alias(alias, module_path, self.edition_2015)
                    {
                        self.imports.push(import);
                    }
                }
                Item::Fn(f) => {
                    if julia_owns_entry_point(&f.attrs) {
                        // Owned by `#[julia]`, which exports `rustcall_<name>`
                        // itself (#279): reporting it here would describe a
                        // second wrapper under the same symbol.
                        continue;
                    }
                    match pyo3_marker(&f.attrs) {
                        Some(Pyo3Marker::Function) => {
                            let intrinsic = function_entry(
                                f,
                                Attribute::PyFunction,
                                true,
                                module_path,
                                enclosing_cfg,
                            );
                            self.intrinsic_skips.insert(
                                (
                                    module_path.clone(),
                                    intrinsic.name.clone(),
                                    intrinsic.line,
                                    intrinsic.cfg.clone(),
                                ),
                                intrinsic.skip_reason,
                            );
                            manifest.functions.push(function_entry(
                                f,
                                Attribute::PyFunction,
                                reachable,
                                module_path,
                                enclosing_cfg,
                            ));
                        }
                        Some(Pyo3Marker::Module) => {
                            manifest.functions.push(function_entry(
                                f,
                                Attribute::PyModule,
                                reachable,
                                module_path,
                                enclosing_cfg,
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
                            entry: class_entry(s, reachable, module_path, enclosing_cfg),
                            reachable_fields: class_entry(s, true, module_path, enclosing_cfg)
                                .fields,
                            visibility: s.vis.clone(),
                            cfg: enclosing_cfg.to_vec(),
                        });
                    }
                }
                Item::Impl(imp) => {
                    if pyo3_marker(&imp.attrs) != Some(Pyo3Marker::Methods) {
                        continue;
                    }
                    let Some(header) = ImplHeader::of(imp, module_path) else {
                        continue;
                    };
                    self.impls.push(ScannedImpl {
                        header,
                        line: imp.span().start().line,
                        cfg: crate::cfg::effective_cfg_attrs(enclosing_cfg, &imp.attrs),
                        enclosing_cfg: enclosing_cfg.to_vec(),
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
                    self.imports.extend(imports_of_use(u, module_path));
                }
                Item::Mod(m) => {
                    let inner_reachable = reachable && matches!(m.vis, syn::Visibility::Public(_));
                    let inner_cfg = crate::cfg::effective_cfg_attrs(enclosing_cfg, &m.attrs);
                    module_path.push(m.ident.to_string());
                    match &m.content {
                        Some((_, inner)) => {
                            dir_components.push(m.ident.to_string());
                            self.level(
                                inner,
                                module_path,
                                dir_components,
                                inner_reachable,
                                &inner_cfg,
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
                            cfg: inner_cfg,
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
        let mut route_cache = std::collections::BTreeMap::new();
        for function in &mut manifest.functions {
            if !function.attribute.is_pyo3_scan() {
                continue;
            }
            let mut canonical = function.module_path.clone();
            canonical.push(function.name.clone());
            let routes = route_cache
                .entry(function.cfg.clone())
                .or_insert_with(|| self.routes.resolve_for(&function.cfg));
            if let Some(route) =
                routes.get(&(crate::public_routes::Namespace::Value, canonical.clone()))
            {
                if function.skip_reason == skip_reason::NOT_PUBLIC {
                    if let Some(intrinsic) = self.intrinsic_skips.get(&(
                        function.module_path.clone(),
                        function.name.clone(),
                        function.line,
                        function.cfg.clone(),
                    )) {
                        function.skip_reason = intrinsic.clone();
                    }
                }
                if route.path != canonical {
                    function.callable_path = route.path.clone();
                }
                merge_route_cfg(&mut function.cfg, &mut function.cfg_features, route);
            }
        }
        for class in &mut self.classes {
            let mut canonical = class.module_path.clone();
            canonical.push(class.entry.name.clone());
            let routes = route_cache
                .entry(class.entry.cfg.clone())
                .or_insert_with(|| self.routes.resolve_for(&class.entry.cfg));
            if let Some(route) =
                routes.get(&(crate::public_routes::Namespace::Type, canonical.clone()))
            {
                if class.entry.skip_reason == skip_reason::NOT_PUBLIC {
                    class.entry.skip_reason = item_skip_reason(
                        &class.visibility,
                        true,
                        !class.entry.type_params.is_empty(),
                    )
                    .unwrap_or_default();
                    class.entry.fields = std::mem::take(&mut class.reachable_fields);
                }
                if route.path != canonical {
                    class.entry.callable_path = route.path.clone();
                }
                merge_route_cfg(&mut class.entry.cfg, &mut class.entry.cfg_features, route);
            }
        }
        self.impls.sort_by(|a, b| {
            a.header
                .module_path
                .cmp(&b.header.module_path)
                .then(a.line.cmp(&b.line))
        });

        for imp in &self.impls {
            // A block that names no class, or an ambiguous one, is dropped: the
            // PyO3 scan describes what a wrapper crate could wrap, and a wrong
            // `Struct::method` would not compile in Phase 2.
            let Ok(index) = locate(&self.classes, &imp.header, &self.imports) else {
                continue;
            };
            // Cfg-exclusive copies of one class: the block written beside one
            // copy belongs to that copy, not to the first `locate` saw; a block
            // written *outside* both — an unconditional `impl api::Gauge` at
            // the root — applies to whichever copy rustc compiles, so it
            // attaches to every one (#357 review). Same rule as
            // `CrateScan::cfg_variants_for`.
            let targets = cfg_variants_of(&self.classes, index, &imp.enclosing_cfg);
            for index in targets {
                let owner_skip = self.classes[index].entry.skip_reason.clone();
                // The symbol is the *class's*: an `impl a::C` written elsewhere
                // still wraps `a::C`'s methods (#300).
                let class_path = self.classes[index].module_path.clone();
                for func in &imp.funcs {
                    let returns_self = matches!(
                        &func.sig.output,
                        syn::ReturnType::Type(_, ty) if {
                            let value = py_result_ok_type(ty).unwrap_or_else(|| (**ty).clone());
                            returns_class(
                                &value, &self.classes[index], &imp.header.module_path,
                                &self.classes, &self.imports, self.edition_2015,
                            )
                        }
                    );
                    let class_ident =
                        syn::Ident::new(&self.classes[index].entry.name, imp.header.target.span());
                    let entry = method_entry(
                        &class_ident,
                        &class_path,
                        returns_self,
                        func,
                        &owner_skip,
                        &imp.cfg,
                    );
                    self.classes[index].entry.methods.push(entry);
                }
            }
        }

        manifest
            .structs
            .extend(self.classes.into_iter().map(|c| c.entry));
        // The Julia surface first: an item it refuses claims no symbol, so a
        // `fn User()` refused for the class `User`'s name does not also cost the
        // class its `String` getters' helper (#307 review).
        mark_julia_surface_collisions(manifest);
    }
}

/// The Julia surface a wrapper is bound to has a namespace of its own, apart
/// from the exported symbols, and the scan refuses what that namespace cannot
/// hold twice (`julia_name_collision:<earlier>`, #307 review):
///
/// * a class is a Julia type *and* its constructor function, so its name is
///   taken for every arity — a free function or a static method of that name
///   would redefine the constant (`function User()` before `mutable struct
///   User`) or graft an extra constructor onto the type. Classes claim first;
/// * a `#[staticmethod]` becomes a module-level Julia function named after the
///   method, with one untyped argument per Rust argument (`crate_bindings.jl`),
///   exactly as a `#[pyfunction]` does, so two classes with a `parse(s)` each,
///   or a class `parse(s)` next to a free `parse(s)`, define one Julia method
///   twice and the later silently replaces the earlier. Free functions claim
///   their name and arity next (a caller writing `parse(s)` means the free
///   function), then classes in manifest order.
///
/// The Rust symbols of all of these are distinct — class-qualified, or in
/// different modules — so [`mark_symbol_collisions`] lets them through.
/// Constructors are named after their class and instance methods dispatch on
/// `self::Class`; neither can collide this way.
fn mark_julia_surface_collisions(manifest: &mut Manifest) {
    // Resolve the user-facing owners before reserving their implementation
    // types. An owner skipped by a class or an earlier method emits no ABI
    // aggregate and must not take a valid class's name with it.
    let owners = manifest.clone();
    mark_julia_surface_collisions_pass(manifest, None);
    mark_symbol_collisions(manifest);
    loop {
        let mut next = owners.clone();
        mark_julia_surface_collisions_pass(&mut next, Some(manifest));
        // A symbol winner may have just lost its Julia name to an aggregate.
        // Re-evaluate symbol ownership too, so it cannot leave permanent
        // tombstones on methods that are now safe to emit.
        mark_symbol_collisions(&mut next);
        if next == *manifest {
            return;
        }
        *manifest = next;
    }
}

fn mark_julia_surface_collisions_pass(
    manifest: &mut Manifest,
    aggregate_owners: Option<&Manifest>,
) {
    // A linker-excluded entry emits no Julia binding either. It remains a
    // candidate in the fresh pass, but must not reserve a surface name until
    // symbol ownership allows it again. Indexing is stable across the clones.
    let symbol_excluded = |reason: &str| {
        reason.starts_with("symbol_collision:")
            || reason.starts_with("owner_skipped:symbol_collision:")
    };
    // The Julia surface is one namespace *per generated module*, and the
    // bindings lay one Julia module out per Rust module (#300), so every key
    // below carries the module path: `a::parse` and `b::parse` live in
    // `bindings.a` and `bindings.b` and never meet.
    // (module path, name) -> qualified owner; (module path, name, arity) -> owner.
    // Every key also carries the claimant's `#[cfg]`: cfg-exclusive copies of
    // one fragment name the same things and rustc never compiles them
    // together, so they do not take the name from each other (#357 review).
    type Scoped = (Vec<String>, String);
    type ScopedArity = (Vec<String>, String, usize);
    let class_names: Vec<(Scoped, String, String)> = manifest
        .structs
        .iter()
        .enumerate()
        .filter(|(i, s)| {
            s.attribute.is_pyo3_scan()
                && s.skip_reason.is_empty()
                && aggregate_owners
                    .is_none_or(|previous| !symbol_excluded(&previous.structs[*i].skip_reason))
        })
        .map(|(_, s)| {
            (
                (s.module_path.clone(), s.name.clone()),
                qualified(&s.module_path, &s.name),
                s.cfg.clone(),
            )
        })
        .collect();
    // Result/Option wrappers are Julia types in the same generated module as
    // their owner (`CResult_<fn>`, `COption_<fn>`). Reserve those names before
    // laying out classes and functions: otherwise a user-defined `pyclass`
    // with one of those names would redefine the aggregate after the wrapper
    // emitter had already declared it (#303).
    // Recompute from surviving owners, not from the manifest being marked:
    // excluding CResult_f also removes COption_CResult_f_method. Starting
    // each pass from the original candidates restores classes blocked only
    // by a now-absent aggregate. Symbol-excluded owners likewise release
    // their surface claims, allowing previously blocked candidates back in.
    let mut aggregate_names: Vec<(Scoped, String, String)> = aggregate_owners
        .into_iter()
        .flat_map(|owners| &owners.functions)
        .filter(|f| f.attribute.is_pyo3_scan() && f.skip_reason.is_empty())
        .filter(|f| {
            matches!(
                f.return_kind,
                ReturnKind::PyResult | ReturnKind::Result | ReturnKind::Option
            )
        })
        .flat_map(|f| {
            let prefix = if f.return_kind == ReturnKind::Option {
                "COption"
            } else {
                "CResult"
            };
            let defaults = f
                .args
                .iter()
                .rev()
                .take_while(|arg| !arg.python_default.is_empty())
                .count();
            (0..=defaults).map(move |omitted| {
                let owner = if omitted == 0 {
                    f.ffi_name.clone()
                } else {
                    format!("{}__default_{omitted}", f.ffi_name)
                };
                let name = format!("{prefix}_{owner}");
                ((f.module_path.clone(), name.clone()), name, f.cfg.clone())
            })
        })
        .collect();
    for s in aggregate_owners
        .into_iter()
        .flat_map(|owners| &owners.structs)
        .filter(|s| s.attribute.is_pyo3_scan() && s.skip_reason.is_empty())
    {
        for m in s.methods.iter().filter(|m| {
            m.skip_reason.is_empty()
                && matches!(
                    m.return_kind,
                    ReturnKind::PyResult | ReturnKind::Result | ReturnKind::Option
                )
        }) {
            let prefix = if m.return_kind == ReturnKind::Option {
                "COption"
            } else {
                "CResult"
            };
            let owner = crate::codegen::method_string_owner(&s.ffi_name, &m.name);
            let defaults = m
                .args
                .iter()
                .rev()
                .take_while(|arg| !arg.python_default.is_empty())
                .count();
            for omitted in 0..=defaults {
                let variant = if omitted == 0 {
                    owner.clone()
                } else {
                    format!("{owner}__default_{omitted}")
                };
                let name = format!("{prefix}_{variant}");
                aggregate_names.push(((s.module_path.clone(), name.clone()), name, m.cfg.clone()));
            }
        }
    }
    let aggregate_named = |path: &[String], name: &str, cfg: &str| {
        aggregate_names
            .iter()
            .find(|((p, n), _, c)| p == path && n == name && cfg_clash(c, cfg))
    };
    let class_named = |path: &[String], name: &str, cfg: &str| {
        class_names
            .iter()
            .find(|((p, n), _, c)| p == path && n == name && cfg_clash(c, cfg))
    };

    let mut taken: Vec<(ScopedArity, String, String)> = Vec::new();
    for (i, f) in manifest.functions.iter_mut().enumerate() {
        if !f.attribute.is_pyo3_scan() || !f.skip_reason.is_empty() {
            continue;
        }
        if let Some((_, class, _)) = class_named(&f.module_path, &f.name, &f.cfg) {
            f.skip_reason = skip_reason::detailed(skip_reason::JULIA_NAME_COLLISION, class);
            continue;
        }
        if let Some((_, aggregate, _)) = aggregate_named(&f.module_path, &f.name, &f.cfg) {
            f.skip_reason = skip_reason::detailed(skip_reason::JULIA_NAME_COLLISION, aggregate);
            continue;
        }
        if aggregate_owners
            .is_none_or(|previous| !symbol_excluded(&previous.functions[i].skip_reason))
        {
            taken.push((
                (f.module_path.clone(), f.name.clone(), f.args.len()),
                qualified(&f.module_path, &f.name),
                f.cfg.clone(),
            ));
        }
    }
    for (i, s) in manifest.structs.iter_mut().enumerate() {
        if !s.attribute.is_pyo3_scan() || !s.skip_reason.is_empty() {
            continue;
        }
        let owner = qualified(&s.module_path, &s.name);
        let s_cfg = s.cfg.clone();
        if let Some((_, aggregate, _)) = aggregate_named(&s.module_path, &s.name, &s_cfg) {
            let reason = skip_reason::detailed(skip_reason::JULIA_NAME_COLLISION, aggregate);
            s.skip_reason = reason.clone();
            for m in &mut s.methods {
                if m.skip_reason.is_empty() {
                    m.skip_reason = skip_reason::detailed(skip_reason::OWNER_SKIPPED, &reason);
                }
            }
            continue;
        }
        for (j, m) in s.methods.iter_mut().enumerate() {
            if !m.skip_reason.is_empty() || !m.is_static || m.is_constructor {
                continue;
            }
            if let Some((_, class, _)) = class_named(&s.module_path, &m.name, &m.cfg) {
                m.skip_reason = skip_reason::detailed(skip_reason::JULIA_NAME_COLLISION, class);
                continue;
            }
            if let Some((_, aggregate, _)) = aggregate_named(&s.module_path, &m.name, &m.cfg) {
                m.skip_reason = skip_reason::detailed(skip_reason::JULIA_NAME_COLLISION, aggregate);
                continue;
            }
            let key = (s.module_path.clone(), m.name.clone(), m.args.len());
            match taken
                .iter()
                .find(|(k, _, c)| *k == key && cfg_clash(c, &m.cfg))
            {
                Some((_, other, _)) => {
                    m.skip_reason = skip_reason::detailed(skip_reason::JULIA_NAME_COLLISION, other);
                }
                None => {
                    if aggregate_owners.is_none_or(|previous| {
                        !symbol_excluded(&previous.structs[i].methods[j].skip_reason)
                    }) {
                        taken.push((key, format!("{owner}::{}", m.name), m.cfg.clone()));
                    }
                }
            }
        }
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
pub(crate) use crate::cfg::cfg_exclusive;

/// Whether two items whose symbols coincide really clash: they do unless their
/// predicates are provably exclusive — copies rustc never compiles together.
/// The same exemption `claimed_symbols` applies on the `#[julia]` side.
fn cfg_clash(a: &str, b: &str) -> bool {
    !cfg_exclusive(a, b)
}

fn mark_symbol_collisions(manifest: &mut Manifest) {
    // One table for every exported symbol of the whole manifest, whatever
    // produces it: a `#[julia]` function's wrapper, a `#[julia]` struct's
    // method and accessor wrappers, and the PyO3 entries the scan just added.
    // They all live in one `cdylib`, so `rustcall_C_f` from a `#[julia]`
    // `impl C { fn f }` and from a `#[pyclass] C` with `#[pymethods] fn f`
    // are the same symbol even though nothing else about them matches.
    let mut taken: Vec<(String, String, String)> = Vec::new();

    // Items already exported by a RustCall attribute own their symbols
    // outright: a PyO3 entry that wants one is the loser whatever the order.
    // What a RustCall-attributed entry claims is derived in exactly one place
    // (`crate::claims`, #338), so a name added to the codegen cannot be
    // remembered here and forgotten by the `#[julia]` duplicate check, or the
    // other way round.
    for f in manifest
        .functions
        .iter()
        .filter(|f| !f.attribute.is_pyo3_scan())
    {
        for claim in crate::claims::function_claims(f, crate::claims::Policy::PYO3_SCAN) {
            taken.push((
                claim.name,
                qualified(&f.module_path, &f.name),
                f.cfg.clone(),
            ));
        }
    }
    for s in manifest
        .structs
        .iter()
        .filter(|s| !s.attribute.is_pyo3_scan())
    {
        for claim in crate::claims::struct_claims(s, crate::claims::Policy::PYO3_SCAN) {
            taken.push((
                claim.name,
                qualified(&s.module_path, &s.name),
                s.cfg.clone(),
            ));
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
        let mut symbols = wrapper_symbols(&f.symbol).to_vec();
        if declares_string_helpers(&f.return_type, &f.ok_type, &f.err_type, &f.inner_type) {
            symbols.extend(string_helper_symbols(&f.ffi_name));
        }
        let f_cfg = f.cfg.clone();
        if let Some((_, owner, _)) = taken
            .iter()
            .find(|(s, _, c)| symbols.contains(s) && cfg_clash(c, &f_cfg))
        {
            let owner = owner.clone();
            manifest.functions[i].skip_reason =
                skip_reason::detailed(skip_reason::SYMBOL_COLLISION, &owner);
        } else {
            let owner = qualified(&f.module_path, &f.name);
            for symbol in symbols {
                taken.push((symbol, owner.clone(), f_cfg.clone()));
            }
        }
    }

    // A class whose *FFI name* another struct entry already claimed collides
    // on every one of its symbols at once, so there the class is the unit.
    // Since #300 the FFI name carries the module path, so this is a same-module
    // clash (or a crate-root name spelling a qualified one). Any other clash —
    // with a free function, or between a class's own method and one of its
    // field accessors — is reported on the individual entry, which leaves the
    // rest of the class wrappable.
    let mut class_names: Vec<(String, String, String)> = manifest
        .structs
        .iter()
        .filter(|s| !s.attribute.is_pyo3_scan())
        .map(|s| {
            (
                s.ffi_name.clone(),
                qualified(&s.module_path, &s.name),
                s.cfg.clone(),
            )
        })
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
        let name = s.ffi_name.clone();
        let s_cfg = s.cfg.clone();
        let free = crate::codegen::struct_free_symbol(&s.ffi_name);
        let free_symbols = [crate::codegen::panic_symbol(&free), free];

        let class_conflict = class_names
            .iter()
            .find(|(n, _, c)| *n == name && cfg_clash(c, &s_cfg))
            .or_else(|| {
                taken.iter().find(|(symbol, _, cfg)| {
                    free_symbols.contains(symbol) && cfg_clash(cfg, &s_cfg)
                })
            });
        if let Some((_, owner, _)) = class_conflict {
            let reason = skip_reason::detailed(skip_reason::SYMBOL_COLLISION, owner);
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
                f.free_symbol.clear();
            }
            continue;
        }

        // Methods claim their symbols before field accessors do, so a
        // `#[setter(x)] fn set_x` and a `#[pyo3(set)] x` — which both want
        // `rustcall_C_set_x` — leave the method wrappable and drop the
        // accessor, rather than taking the whole class down.
        let owner = qualified(&s.module_path, &s.name);
        for symbol in free_symbols {
            taken.push((symbol, owner.clone(), s_cfg.clone()));
        }
        let s = &mut manifest.structs[i];
        let class_name = s.ffi_name.clone();
        for m in &mut s.methods {
            if !m.skip_reason.is_empty() || m.symbol.is_empty() {
                continue;
            }
            let mut symbols = wrapper_symbols(&m.symbol).to_vec();
            if declares_string_helpers(&m.return_type, &m.ok_type, &m.err_type, &m.inner_type) {
                symbols.extend(string_helper_symbols(&format!("{}_{}", class_name, m.name)));
            }
            match taken
                .iter()
                .find(|(t, _, c)| symbols.contains(t) && cfg_clash(c, &s_cfg))
            {
                Some((_, other, _)) => {
                    m.skip_reason = skip_reason::detailed(skip_reason::SYMBOL_COLLISION, other);
                }
                None => {
                    for symbol in symbols {
                        taken.push((symbol, owner.clone(), s_cfg.clone()));
                    }
                }
            }
        }
        // The struct-level owned-string helper every `String` field getter of
        // the class shares (`<Class>_RustCallOwnedString`, `class_wrappers`)
        // is a declaration like any other: when another item already made it,
        // the `String` getters are what give way, and the rest of the class
        // stays wrappable (#307 review). A `#[pyfunction] fn User() -> String`
        // next to a `#[pyclass] User` used to be the case; it is now refused on
        // the Julia surface first (`mark_julia_surface_collisions`), so what
        // reaches this is an item whose own symbols spell a helper's name.
        if s.fields
            .iter()
            .any(|f| !f.getter.is_empty() && is_string_spelling(&f.rust_type))
        {
            let helpers = string_helper_symbols(&class_name);
            if taken
                .iter()
                .any(|(t, _, c)| helpers.contains(t) && cfg_clash(c, &s_cfg))
            {
                for f in &mut s.fields {
                    if is_string_spelling(&f.rust_type) {
                        f.ffi_compatible = false;
                        f.getter.clear();
                        f.setter.clear();
                        f.free_symbol.clear();
                    }
                }
            } else {
                for symbol in helpers {
                    taken.push((symbol, owner.clone(), s_cfg.clone()));
                }
            }
        }
        for f in &mut s.fields {
            if !f.getter.is_empty() {
                let mut symbols = vec![f.getter.clone(), crate::codegen::panic_symbol(&f.getter)];
                if f.abi == "vec" {
                    symbols.push(format!("{}_RustCallOwnedVec", f.getter));
                    symbols.push(f.free_symbol.clone());
                }
                if taken
                    .iter()
                    .any(|(t, _, c)| symbols.contains(t) && cfg_clash(c, &s_cfg))
                {
                    f.getter.clear();
                    f.free_symbol.clear();
                } else {
                    for symbol in symbols {
                        taken.push((symbol, owner.clone(), s_cfg.clone()));
                    }
                }
            }
            if !f.setter.is_empty() {
                let symbols = [f.setter.clone(), crate::codegen::panic_symbol(&f.setter)];
                if taken
                    .iter()
                    .any(|(t, _, c)| symbols.contains(t) && cfg_clash(c, &s_cfg))
                {
                    f.setter.clear();
                } else {
                    for symbol in symbols {
                        taken.push((symbol, owner.clone(), s_cfg.clone()));
                    }
                }
            }
            if f.getter.is_empty() && f.setter.is_empty() {
                f.ffi_compatible = false;
            }
        }
        class_names.push((name, owner, s_cfg));
    }
}

/// The string helpers a wrapper declares next to an item whose result — or
/// `Result` / `Option` payload — is a string: `<owner>_RustCallOwnedString` and
/// `<owner>_free_rust_string` for an owned buffer, `<owner>_RustCallBorrowedString`
/// for a view. The owner is the function's name, the class's name (for its
/// field getters) or `<Class>_<method>`, so two items with one owner declare
/// the same helpers twice and the generated crate does not compile; all three
/// names are reserved whenever the item may declare any of them (#307 review).
fn string_helper_symbols(owner: &str) -> [String; 3] {
    let [owned, free] = crate::claims::owned_string_names(owner);
    [owned, free, crate::claims::borrowed_string_name(owner)]
}

/// Whether a wrapper for an item with these manifest types declares a string
/// helper: a `String` / `&str` result, or such a payload.
fn declares_string_helpers(
    return_type: &str,
    ok_type: &str,
    err_type: &str,
    inner_type: &str,
) -> bool {
    [return_type, ok_type, err_type, inner_type]
        .iter()
        .any(|spelling| is_string_spelling(spelling))
}

fn is_string_spelling(spelling: &str) -> bool {
    !spelling.is_empty()
        && syn::parse_str::<Type>(spelling)
            .map(|ty| is_string_type(&ty) || is_str_ref_type(&ty))
            .unwrap_or(false)
}

/// Every name a wrapper derives from one manifest symbol: the entry point
/// itself, its panic-channel reader (`<symbol>_take_panic`,
/// `codegen::PANIC_SYMBOL_SUFFIX`), and the private thread-local slot that
/// reader drains — `__RUSTCALL_PANIC_<SYMBOL>`, the symbol upper-cased, which
/// `foo` and `FOO` would therefore share. A clash on any of them is a duplicate
/// definition in the generated crate — `foo` and `foo_take_panic` as two
/// `#[pyfunction]`s both want `rustcall_foo_take_panic` — so all are reserved
/// and all are checked (#307 review). Field accessors have no reader and
/// derive nothing.
fn wrapper_symbols(symbol: &str) -> [String; 3] {
    let claims = crate::claims::wrapper_claims(symbol);
    let mut names = claims.into_iter().map(|c| c.name);
    [
        names.next().expect("entry point"),
        names.next().expect("panic reader"),
        names.next().expect("panic slot"),
    ]
}

fn merge_route_cfg(
    cfg: &mut String,
    features: &mut Vec<String>,
    route: &crate::public_routes::PublicRoute,
) {
    let mut predicates = route.predicates.clone();
    if !cfg.is_empty() {
        predicates.insert(cfg.clone());
    }
    if predicates.is_empty() {
        return;
    }
    *cfg = if predicates.len() == 1 {
        predicates.into_iter().next().unwrap()
    } else {
        format!(
            "all({})",
            predicates.into_iter().collect::<Vec<_>>().join(",")
        )
    };
    let meta: syn::Meta =
        syn::parse_str(&format!("cfg({cfg})")).expect("cfg predicates came from syn");
    let attrs: Vec<syn::Attribute> = vec![syn::parse_quote!(#[#meta])];
    *features = crate::cfg::predicate_features(&attrs);
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
    enclosing_cfg: &[syn::Attribute],
) -> Function {
    let name = func.sig.ident.to_string();
    let effective_cfg = crate::cfg::effective_cfg_attrs(enclosing_cfg, &func.attrs);
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
        ffi_name: crate::codegen::symbol_stem(module_path, &name),
        // What Phase 2 will export, not what exists today.
        symbol: crate::codegen::function_symbol(module_path, &name),
        attribute,
        vis: visibility_string(&func.vis),
        skip_reason: reason,
        python_name: pyo3_name(&func.attrs),
        exported: false,
        cfg: predicate_string(&effective_cfg),
        cfg_features: crate::cfg::predicate_features(&effective_cfg),
        is_generic,
        type_params: generics_to_type_params(&func.sig.generics),
        args: pyo3_args(&func.sig, &func.attrs),
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
        callable_path: Vec::new(),
    }
}

/// Manifest entry of a `#[pyclass]` struct: an opaque handle. A `#[pyclass]` is
/// never `#[repr(C)]` (pyo3 owns its layout), so fields are only reachable
/// through the accessors pyo3 itself declares with `#[pyo3(get, set)]`.
fn class_entry(
    item: &ItemStruct,
    reachable: bool,
    module_path: &[String],
    enclosing_cfg: &[syn::Attribute],
) -> Struct {
    let effective_cfg = crate::cfg::effective_cfg_attrs(enclosing_cfg, &item.attrs);
    let is_generic = has_type_params(&item.generics);
    let reason = item_skip_reason(&item.vis, reachable, is_generic).unwrap_or_default();
    let name = item.ident.to_string();
    let stem = crate::codegen::symbol_stem(module_path, &name);

    // `#[pyclass(get_all, set_all)]` exposes every field without a per-field
    // attribute, and `frozen` takes every setter away. The dual-binding shape
    // `docs/src/pyo3.md` recommends is exactly that, so a scan that read only
    // field attributes would drop those fields.
    let options = crate::attrs::pyo3_class_options(&item.attrs);
    let mut pyo3_options = Vec::new();
    if options.subclass {
        pyo3_options.push("subclass".to_string());
    }
    if options.dict {
        pyo3_options.push("dict".to_string());
    }
    if options.weakref {
        pyo3_options.push("weakref".to_string());
    }

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
            let vec_element = crate::types::pyo3_vec_element_type(&f.ty);
            // A `String` field crosses as the owned-string ABI. A `Vec<T>` is
            // available when T has a concrete Julia FFI scalar representation;
            // its element and allocator-matched release export are manifest
            // data rather than guesses made by the consumer (#303).
            let usable = reason.is_empty()
                && field_is_public
                && pyo3_type_in(&f.ty).is_none()
                && (is_ffi_compatible_type(&f.ty)
                    || is_string_type(&f.ty)
                    || vec_element.is_some());
            let getter = if usable && access.get {
                crate::codegen::method_symbol_of(&stem, &format!("get_{ident}"))
            } else {
                String::new()
            };
            let vec_free = if vec_element.is_some() && !getter.is_empty() {
                format!("{getter}_free_rust_vec")
            } else {
                String::new()
            };
            fields.push(Field {
                name: ident.to_string(),
                rust_type: type_to_string(&f.ty),
                abi: if vec_element.is_some() {
                    "vec".to_string()
                } else {
                    crate::codegen::field_abi(&f.ty).to_string()
                },
                vec_element: vec_element.as_ref().map(type_to_string).unwrap_or_default(),
                free_symbol: vec_free,
                ffi_compatible: usable,
                getter,
                setter: if usable && access.set {
                    crate::codegen::method_symbol_of(&stem, &format!("set_{ident}"))
                } else {
                    String::new()
                },
                python_name: access.python_name,
                vis: visibility_string(&f.vis),
                // Whatever `#[cfg]` survived pruning is one the scan could not
                // decide; the generator refuses the accessors under a lenient
                // scan (#307 review).
                cfg: predicate_string(&f.attrs),
            });
        }
    }

    Struct {
        name: name.clone(),
        ffi_name: stem,
        attribute: Attribute::PyClass,
        vis: visibility_string(&item.vis),
        skip_reason: reason,
        python_name: pyo3_name(&item.attrs),
        pyo3_extends: options.extends,
        pyo3_options,
        python_owned_handle: false,
        cfg: predicate_string(&effective_cfg),
        cfg_features: crate::cfg::predicate_features(&effective_cfg),
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
        callable_path: Vec::new(),
    }
}

/// Manifest entry of one method of a `#[pymethods]` block.
fn method_entry(
    struct_ident: &syn::Ident,
    class_path: &[String],
    returns_self: bool,
    func: &ImplItemFn,
    owner_skip: &str,
    enclosing_cfg: &[syn::Attribute],
) -> Method {
    // The block's and its modules' predicates gate the method as much as its
    // own do (#300 review).
    let effective_cfg = crate::cfg::effective_cfg_attrs(enclosing_cfg, &func.attrs);
    let struct_stem = crate::codegen::symbol_stem(class_path, &struct_ident.to_string());
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
        symbol: crate::codegen::method_symbol_of(&struct_stem, &name),
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
        attribute: Attribute::PyMethods,
        // A scanned `#[pymethods]` method has no wrapper and so no string
        // buffers; the Phase-2 wrapper crate names the ones it declares when
        // it generates them (`crate::wrap::method_wrapper`).
        string_owner: String::new(),
        return_kind,
        ok_type,
        err_type,
        inner_type,
        // No `#[julia]` wrapper exists for a scanned PyO3 item, so no payload
        // lowering (#268).
        ok_abi: String::new(),
        err_abi: String::new(),
        inner_abi: String::new(),
        // Only a return payload that resolves to `Self` / the class is an
        // opaque handle this wrapper may box (`#[pyclass]` is never `repr(C)`).
        // The `#[new]` marker alone is insufficient: an inheritance
        // constructor returns `(Self, Base)` (possibly inside `PyResult`),
        // which cannot inhabit a `*mut Self` success slot (#303).
        returns_boxed_struct: returns_self,
        args: pyo3_args(&func.sig, &func.attrs),
        return_type: return_type_to_string(&func.sig.output),
        return_abi: String::new(),
        generic_wrapper: String::new(),
        cfg: predicate_string(&effective_cfg),
    }
}

/// Rust arguments annotated with the Python call shape PyO3 generated.
/// Parsing failures are left to rustc/PyO3 (the target crate cannot build),
/// while a valid signature is matched by parameter name so the receiver —
/// absent from `fn_args` — never shifts the metadata onto another argument.
fn pyo3_args(sig: &syn::Signature, attrs: &[syn::Attribute]) -> Vec<crate::manifest::Arg> {
    let mut args = fn_args(sig);
    let Ok(Some(parameters)) = pyo3_signature(attrs) else {
        return args;
    };
    for parameter in parameters {
        let Some(arg) = args.iter_mut().find(|arg| arg.name == parameter.name) else {
            continue;
        };
        arg.python_default = parameter.default;
        arg.python_kind = match parameter.kind {
            Pyo3ParameterKind::PositionalOnly => "positional_only",
            Pyo3ParameterKind::PositionalOrKeyword => "positional_or_keyword",
            Pyo3ParameterKind::KeywordOnly => "keyword_only",
            Pyo3ParameterKind::VarArgs => "var_args",
            Pyo3ParameterKind::KwArgs => "kw_args",
        }
        .to_string();
    }
    args
}

/// Whether a method's return type names the class itself: `Self`, the bare
/// class name, or a `crate::` / `self::` / `super::`-anchored path ending in
/// it. A path anchored elsewhere — `std::string::String` on a `#[pyclass]
/// struct String` — is some other type that happens to share the last
/// segment, and boxing it as the class would not compile (#307 review).
/// `codegen::returns_boxed_struct`'s last-segment rule stays with the
/// `#[julia]` path, whose items live in the crate that defines the struct.
fn returns_class(
    ty: &Type,
    class: &ScannedClass,
    impl_path: &[String],
    classes: &[ScannedClass],
    imports: &[ScannedImport],
    edition_2015: bool,
) -> bool {
    let Type::Path(path) = unparen(ty) else {
        return false;
    };
    if path.qself.is_some() {
        return false;
    }
    // A leading `::` names the current crate only in edition 2015. In newer
    // editions it starts in the extern prelude, which this scanner cannot
    // resolve and must not confuse with a same-named local module.
    if path.path.leading_colon.is_some() && !edition_2015 {
        return false;
    }
    if path.path.is_ident("Self") {
        return true;
    }
    let Some(target) = path.path.segments.last() else {
        return false;
    };
    let mut qualifier = crate::paths::type_path_qualifier(ty);
    if path.path.leading_colon.is_some() {
        qualifier.anchor = crate::paths::PathAnchor::Crate;
    }
    let header = ImplHeader {
        target: target.ident.clone(),
        qualifier,
        module_path: impl_path.to_vec(),
    };
    crate::paths::locate_type(classes, &header, imports).is_ok_and(|index| {
        classes[index].entry.name == class.entry.name
            && classes[index].module_path == class.module_path
    })
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
///
/// An `async fn` is refused outright: its declared output is what the future
/// *resolves to*, and a wrapper that called it would hand back the future
/// itself — a type error in the generated crate, which no `extern "C"` can
/// return anyway. pyo3 lets a `#[pyfunction]` be `async` (with its
/// `experimental-async` feature); the wrapper has no executor to drive it
/// (#307 review).
fn signature_skip_reason(sig: &syn::Signature, return_kind: ReturnKind) -> Option<String> {
    if sig.asyncness.is_some() {
        return Some(skip_reason::ASYNC_FN.to_string());
    }
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
