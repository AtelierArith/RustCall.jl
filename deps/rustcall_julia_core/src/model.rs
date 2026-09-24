//! Intermediate model of `#[julia]` structs and their impl blocks, built from a
//! parsed file and shared by extraction and code generation.

use syn::spanned::Spanned;
use syn::{FnArg, ImplItem, ImplItemFn, Item, ItemImpl, ItemStruct, Type, Visibility};

use crate::attrs::{derive_list, is_julia_attr, rustcall_attribute};
use crate::manifest::{Attribute, Mode};

/// Where a method's `#[julia] impl` block was written: the module the block
/// sits in, and the path its header spells the struct with (`super::Gauge`).
///
/// A block may sit in another module than its struct (#315). The inline
/// expander emits such a block's wrappers **at the block** (#342), where the
/// types its signatures name are in scope, spelling the struct exactly as the
/// header does — which is what the proc-macro already does for the crate
/// flavour (`transform_impl_crate`).
#[derive(Debug, Clone)]
pub struct ImplSite {
    /// The module the block sits in, as a path from the crate root.
    pub module_path: Vec<String>,
    /// The impl header's own type path (`super::Gauge`, `crate::a::C`).
    pub self_ty: Type,
}

/// The header of the impl block a method was written in: what its signature's
/// `Self` and the block's own generics mean (#482). A generated wrapper
/// declares the block's generics and `where` clause, then the method's, and
/// spells `Self` as `self_ty` (`crate::environment`).
#[derive(Debug, Clone)]
pub struct ImplHost {
    /// The block's generics, `where` clause included (`impl<'x> Buf where ..`).
    pub generics: syn::Generics,
    /// The header's type as written (`Buf`, `super::Buf`).
    pub self_ty: Type,
    /// The trait of a trait impl, through which a bare `Self::Assoc` resolves.
    pub trait_: Option<syn::Path>,
}

impl ImplHost {
    pub fn of(imp: &ItemImpl) -> Self {
        ImplHost {
            generics: imp.generics.clone(),
            self_ty: (*imp.self_ty).clone(),
            trait_: imp.trait_.as_ref().map(|(_, path, _)| path.clone()),
        }
    }
}

#[derive(Debug, Clone)]
pub struct MethodModel {
    pub func: ImplItemFn,
    pub is_static: bool,
    pub is_mutable: bool,
    /// The RustCall attribute of the impl block the method was collected from
    /// (`Julia`, or `None` for an inline-mode impl that carries none).
    /// Recorded on the manifest entry (`Method.attribute`, #275 Phase 3).
    pub attribute: Attribute,
    /// The `#[cfg]` of the impl block and of every module enclosing it: the
    /// method exists only under those predicates as much as under its own
    /// (#300 review, #315). Empty for a wrapper generated from a lone method.
    pub enclosing_cfg: Vec<syn::Attribute>,
    /// Where the block that declared the method was written (#342). `None`
    /// for a method not collected from a block ([`MethodModel::from_fn`]) and
    /// for a block attached without a module (`attach_impl` with `None`),
    /// which is then its struct's neighbour.
    pub site: Option<ImplSite>,
    /// The header of the block the method was collected from (#482). `None`
    /// for a lone method ([`MethodModel::from_fn`]); its wrapper then takes
    /// the struct as `Self` and no generics of a block.
    pub host: Option<ImplHost>,
}

impl MethodModel {
    pub fn from_fn(func: &ImplItemFn, attribute: Attribute) -> Self {
        let receiver = func.sig.inputs.iter().find_map(|a| match a {
            FnArg::Receiver(r) => Some(r),
            _ => None,
        });
        MethodModel {
            func: func.clone(),
            is_static: receiver.is_none(),
            is_mutable: receiver.map(|r| r.mutability.is_some()).unwrap_or(false),
            attribute,
            enclosing_cfg: Vec::new(),
            site: None,
            host: None,
        }
    }

    pub fn name(&self) -> String {
        self.func.sig.ident.to_string()
    }

    /// The trait of the block the method was written in, as the header
    /// spells it (`tr::Limits`), or empty for an inherent method: the
    /// manifest's `Method.trait_path` (#503).
    pub fn trait_path(&self) -> String {
        self.host
            .as_ref()
            .and_then(|h| h.trait_.as_ref())
            .map(|path| {
                crate::types::type_to_string(&syn::Type::Path(syn::TypePath {
                    qself: None,
                    path: path.clone(),
                }))
            })
            .unwrap_or_default()
    }

    /// Whether `other` is this method: the same name in the same trait (or
    /// both inherent). Two blocks may define a method of one name only when
    /// one is a trait impl, and then both are distinct methods (#503 review).
    pub fn is_same_method(&self, other: &MethodModel) -> bool {
        self.name() == other.name() && self.trait_path() == other.trait_path()
    }

    /// Whether the method's block sits in the same module as its struct, which
    /// is where `struct_module_path` points. A method with no recorded site is
    /// its struct's neighbour (#342).
    pub fn is_local_to(&self, struct_module_path: &[String]) -> bool {
        self.site
            .as_ref()
            .is_none_or(|site| site.module_path == struct_module_path)
    }
}

#[derive(Debug, Clone)]
pub struct StructModel {
    pub item: ItemStruct,
    pub attribute: Attribute,
    pub derives: Vec<String>,
    pub impls: Vec<ItemImpl>,
    pub methods: Vec<MethodModel>,
    pub line: usize,
}

impl StructModel {
    pub fn name(&self) -> String {
        self.item.ident.to_string()
    }

    pub fn is_generic(&self) -> bool {
        crate::types::has_type_params(&self.item.generics)
    }

    /// The struct's own type parameter names (`T` in `S<'a, T, const N: usize>`).
    pub fn type_param_names(&self) -> Vec<String> {
        self.item
            .generics
            .params
            .iter()
            .filter_map(|p| match p {
                syn::GenericParam::Type(tp) => Some(tp.ident.to_string()),
                _ => None,
            })
            .collect()
    }

    /// The `#[cfg]` / `#[cfg_attr]` attributes of the named field `name`: a
    /// generated accessor exists only where its field does (#462).
    pub fn field_cfg_attrs(&self, name: &syn::Ident) -> Vec<syn::Attribute> {
        match &self.item.fields {
            syn::Fields::Named(named) => named
                .named
                .iter()
                .find(|f| f.ident.as_ref() == Some(name))
                .map(|f| crate::cfg::cfg_attrs(&f.attrs))
                .unwrap_or_default(),
            _ => Vec::new(),
        }
    }

    /// Named fields `(ident, type)`; tuple and unit structs yield nothing.
    pub fn named_fields(&self) -> Vec<(syn::Ident, Type)> {
        match &self.item.fields {
            syn::Fields::Named(named) => named
                .named
                .iter()
                .filter_map(|f| f.ident.clone().map(|id| (id, f.ty.clone())))
                .collect(),
            _ => Vec::new(),
        }
    }

    /// The model of a struct item selected under `mode`: a `#[julia]` struct,
    /// or in inline mode also a `#[derive(JuliaStruct)]` one. `None` when the
    /// struct carries neither.
    pub fn of(s: &ItemStruct, mode: Mode) -> Option<StructModel> {
        let attribute = rustcall_attribute(&s.attrs);
        let selected = matches!(
            (mode, attribute),
            (_, Attribute::Julia) | (Mode::Inline, Attribute::DeriveJuliaStruct)
        );
        if !selected {
            return None;
        }
        Some(StructModel {
            item: s.clone(),
            attribute,
            derives: derive_list(&s.attrs)
                .into_iter()
                .filter(|d| d != "JuliaStruct")
                .collect(),
            impls: Vec::new(),
            methods: Vec::new(),
            line: s.span().start().line,
        })
    }

    /// Record an inherent impl block of this struct and the methods of it that
    /// get wrapped under `mode`. The caller has decided that the block is this
    /// struct's (by name at one level, or by resolved path across modules,
    /// #315); a method already seen under the same name is not added twice.
    /// `enclosing_cfg` is the `#[cfg]` of every module enclosing the block.
    ///
    /// `block_module` is the module the block sits in (both callers,
    /// [`ModelTree::collect`] and the crate scan, match across the module
    /// tree and pass it); `None` records the block as the struct's
    /// neighbour. It is recorded on every method as [`MethodModel::site`],
    /// which is what decides where the inline expander emits the wrapper
    /// (#342).
    pub fn attach_impl(
        &mut self,
        imp: &ItemImpl,
        mode: Mode,
        enclosing_cfg: &[syn::Attribute],
        block_module: Option<&[String]>,
    ) {
        self.impls.push(imp.clone());
        for mut m in wrapped_methods(imp, mode, enclosing_cfg) {
            m.site = block_module.map(|path| ImplSite {
                module_path: path.to_vec(),
                self_ty: (*imp.self_ty).clone(),
            });
            if !self.methods.iter().any(|seen| seen.is_same_method(&m)) {
                self.methods.push(m);
            }
        }
    }
}

/// Whether the block carries `#[julia]` itself, which in crate mode is what
/// makes its `#[julia]` methods get wrapped.
pub fn impl_has_julia(imp: &ItemImpl) -> bool {
    imp.attrs.iter().any(is_julia_attr)
}

/// The methods of an inherent impl block that get wrapped under `mode`, in
/// source order. Each carries the block's `#[cfg]` on top of `enclosing_cfg`,
/// the predicates of the modules around the block.
pub fn wrapped_methods(
    imp: &ItemImpl,
    mode: Mode,
    enclosing_cfg: &[syn::Attribute],
) -> Vec<MethodModel> {
    let has_julia = impl_has_julia(imp);
    let block_cfg = crate::cfg::effective_cfg_attrs(enclosing_cfg, &imp.attrs);
    // What the manifest records as the method's origin: the impl block's
    // attribute, which an inline-mode impl does not have.
    let impl_attribute = if has_julia {
        Attribute::Julia
    } else {
        Attribute::None
    };
    imp.items
        .iter()
        .filter_map(|ii| match ii {
            ImplItem::Fn(func) => Some(func),
            _ => None,
        })
        .filter(|func| match mode {
            // Historical inline rule: every `pub fn` of an inherent impl.
            Mode::Inline => matches!(func.vis, Visibility::Public(_)),
            // Proc-macro rule: `#[julia]` methods inside a `#[julia] impl`.
            Mode::Crate => has_julia && func.attrs.iter().any(is_julia_attr),
        })
        .map(|func| {
            let mut m = MethodModel::from_fn(func, impl_attribute);
            m.enclosing_cfg = block_cfg.clone();
            m.host = Some(ImplHost::of(imp));
            m
        })
        .collect()
}

/// The struct models of a whole item tree, every inherent impl block attached
/// to its struct wherever the block sits (#315).
///
/// This is the inline expander's view of a `rust"""` block: every inline module
/// counts, so a struct is identified by its module path and its name, and an
/// `impl super::Gauge` in `mod ops` or an `impl Gauge` next to a
/// `use crate::Gauge;` reaches the struct at the root exactly as a block next
/// to it does. Headers are resolved by the resolver the crate scans share
/// (`crate::paths::locate`). A block that names no selected struct is left
/// alone — an inherent impl of an ordinary struct is ordinary code.
#[derive(Debug, Default)]
pub struct ModelTree {
    entries: Vec<LocatedModel>,
}

#[derive(Debug)]
struct LocatedModel {
    module_path: Vec<String>,
    name: String,
    model: StructModel,
}

/// An inherent impl block seen by [`ModelTree::collect`], with the `#[cfg]` of
/// the modules around it.
#[derive(Debug)]
struct ScannedBlock {
    item: ItemImpl,
    header: crate::paths::ImplHeader,
    enclosing_cfg: Vec<syn::Attribute>,
}

impl crate::paths::Located for LocatedModel {
    fn name(&self) -> &str {
        &self.name
    }

    fn module_path(&self) -> &[String] {
        &self.module_path
    }
}

impl ModelTree {
    pub fn collect(items: &[Item], mode: Mode) -> ModelTree {
        let mut tree = ModelTree::default();
        let mut impls: Vec<ScannedBlock> = Vec::new();
        let mut imports = Vec::new();
        let mut path = Vec::new();
        tree.walk(items, mode, &mut path, &[], &mut impls, &mut imports);
        for block in &impls {
            if let Ok(index) = crate::paths::locate(&tree.entries, &block.header, &imports) {
                tree.entries[index].model.attach_impl(
                    &block.item,
                    mode,
                    &block.enclosing_cfg,
                    Some(&block.header.module_path),
                );
            }
        }
        tree
    }

    fn walk(
        &mut self,
        items: &[Item],
        mode: Mode,
        path: &mut Vec<String>,
        enclosing_cfg: &[syn::Attribute],
        impls: &mut Vec<ScannedBlock>,
        imports: &mut Vec<crate::paths::ScannedImport>,
    ) {
        for item in items {
            match item {
                Item::Struct(s) => {
                    if let Some(model) = StructModel::of(s, mode) {
                        self.entries.push(LocatedModel {
                            module_path: path.clone(),
                            name: model.name(),
                            model,
                        });
                    }
                }
                Item::Impl(imp) => {
                    if let Some(header) = crate::paths::ImplHeader::of(imp, path) {
                        impls.push(ScannedBlock {
                            item: imp.clone(),
                            header,
                            enclosing_cfg: enclosing_cfg.to_vec(),
                        });
                    }
                }
                Item::Use(u) => imports.extend(crate::paths::imports_of_use(u, path)),
                Item::Mod(m) => {
                    if let Some((_, inner)) = &m.content {
                        path.push(m.ident.to_string());
                        let cfg = crate::cfg::effective_cfg_attrs(enclosing_cfg, &m.attrs);
                        self.walk(inner, mode, path, &cfg, impls, imports);
                        path.pop();
                    }
                }
                _ => {}
            }
        }
    }

    /// The model of `name` declared directly in `module_path`, if selected.
    pub fn find(&self, module_path: &[String], name: &str) -> Option<&StructModel> {
        self.entries
            .iter()
            .find(|e| e.module_path == module_path && e.name == name)
            .map(|e| &e.model)
    }

    /// Every wrapped method whose `#[julia] impl` block sits in `module_path`
    /// while its struct lives somewhere else (#342).
    ///
    /// The inline expander emits these wrappers there, at the block, because a
    /// method signature is written in the block's scope: a module-local `type
    /// Count = i32;` is not in scope next to the struct. The exported symbol is
    /// crate-global and keeps following the struct, so where the wrapper is
    /// emitted changes nothing a caller can see.
    ///
    /// Generic structs are excluded: they export no wrapper at all, their
    /// generic wrappers are instantiated by `specialize` next to the struct.
    pub fn foreign_methods(&self, module_path: &[String]) -> Vec<ForeignMethod<'_>> {
        let mut out = Vec::new();
        for entry in &self.entries {
            if entry.model.is_generic() {
                continue;
            }
            for method in &entry.model.methods {
                let Some(site) = &method.site else { continue };
                if site.module_path != module_path || site.module_path == entry.module_path {
                    continue;
                }
                out.push(ForeignMethod {
                    struct_name: &entry.model.item.ident,
                    struct_module_path: &entry.module_path,
                    self_ty: &site.self_ty,
                    method,
                });
            }
        }
        out
    }
}

/// A method whose `#[julia] impl` block sits in another module than its struct
/// (#342), as reported by [`ModelTree::foreign_methods`].
#[derive(Debug)]
pub struct ForeignMethod<'a> {
    /// The **struct's own** identifier, which every exported symbol of the
    /// method hangs off together with [`ForeignMethod::struct_module_path`].
    /// Not the header's last segment: `use super::Gauge as Meter; impl Meter`
    /// still exports `rustcall_Gauge_<method>` (#342 review).
    pub struct_name: &'a syn::Ident,
    /// The module path of the **struct**, which every exported symbol of the
    /// method hangs off.
    pub struct_module_path: &'a [String],
    /// The impl header's own path — how the wrapper spells the struct in the
    /// module it is emitted into, which may be an alias.
    pub self_ty: &'a Type,
    pub method: &'a MethodModel,
}
