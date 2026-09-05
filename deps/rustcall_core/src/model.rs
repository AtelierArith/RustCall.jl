//! Intermediate model of `#[julia]` structs and their impl blocks, built from a
//! parsed file and shared by extraction and code generation.

use syn::spanned::Spanned;
use syn::{FnArg, ImplItem, ImplItemFn, Item, ItemImpl, ItemStruct, Type, Visibility};

use crate::attrs::{derive_list, is_julia_attr, is_julia_pyo3_attr, rustcall_attribute};
use crate::manifest::{Attribute, Mode};
use crate::types::last_ident;

#[derive(Debug, Clone)]
pub struct MethodModel {
    pub func: ImplItemFn,
    pub is_static: bool,
    pub is_mutable: bool,
}

impl MethodModel {
    pub fn from_fn(func: &ImplItemFn) -> Self {
        let receiver = func.sig.inputs.iter().find_map(|a| match a {
            FnArg::Receiver(r) => Some(r),
            _ => None,
        });
        MethodModel {
            func: func.clone(),
            is_static: receiver.is_none(),
            is_mutable: receiver.map(|r| r.mutability.is_some()).unwrap_or(false),
        }
    }

    pub fn name(&self) -> String {
        self.func.sig.ident.to_string()
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
}

fn impl_target_name(item: &ItemImpl) -> Option<String> {
    if item.trait_.is_some() {
        return None;
    }
    last_ident(&item.self_ty).map(|id| id.to_string())
}

/// Collect `#[julia]` structs (and, in inline mode, `#[derive(JuliaStruct)]`
/// structs) together with their inherent impl blocks and the methods that get
/// wrapped under the given mode.
pub fn collect_struct_models(file: &syn::File, mode: Mode) -> Vec<StructModel> {
    let mut models: Vec<StructModel> = Vec::new();

    for item in &file.items {
        if let Item::Struct(s) = item {
            let attribute = rustcall_attribute(&s.attrs);
            let selected = matches!(
                (mode, attribute),
                (_, Attribute::Julia)
                    | (_, Attribute::JuliaPyo3)
                    | (Mode::Inline, Attribute::DeriveJuliaStruct)
            );
            if !selected {
                continue;
            }
            models.push(StructModel {
                item: s.clone(),
                attribute,
                derives: derive_list(&s.attrs)
                    .into_iter()
                    .filter(|d| d != "JuliaStruct")
                    .collect(),
                impls: Vec::new(),
                methods: Vec::new(),
                line: s.span().start().line,
            });
        }
    }

    for item in &file.items {
        let Item::Impl(imp) = item else { continue };
        let Some(target) = impl_target_name(imp) else {
            continue;
        };
        let Some(model) = models.iter_mut().find(|m| m.name() == target) else {
            continue;
        };
        model.impls.push(imp.clone());

        let impl_has_julia = imp.attrs.iter().any(is_julia_attr);
        let impl_has_pyo3 = imp.attrs.iter().any(is_julia_pyo3_attr);

        for ii in &imp.items {
            let ImplItem::Fn(func) = ii else { continue };
            let wrap = match mode {
                // Historical inline rule: every `pub fn` of an inherent impl.
                Mode::Inline => matches!(func.vis, Visibility::Public(_)),
                // Proc-macro rule: `#[julia]` methods inside a `#[julia] impl`,
                // or every method of a `#[julia_pyo3] impl`.
                Mode::Crate => {
                    (impl_has_julia && func.attrs.iter().any(is_julia_attr)) || impl_has_pyo3
                }
            };
            if wrap && !model.methods.iter().any(|m| func.sig.ident == m.name()) {
                model.methods.push(MethodModel::from_fn(func));
            }
        }
    }

    models
}
