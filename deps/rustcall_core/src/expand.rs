//! Inline expansion for `rust"""..."""` blocks.
//!
//! Applies the same transformations the proc-macro applies inside a crate, but
//! ahead of `rustc`, so inline blocks need neither Cargo nor a proc-macro
//! dependency:
//!
//! * `#[julia] fn`            -> `#[no_mangle] pub extern "C" fn` (+ `CResult`/`COption` wrappers)
//! * `#[julia] fn f<T>`       -> plain `pub fn` reported for runtime monomorphization
//! * `#[julia] struct` / `#[derive(JuliaStruct)] struct` -> `pub struct` + `_free`, accessors, method wrappers
//! * generic `#[julia] struct`-> wrappers reported for runtime monomorphization
//! * everything else          -> unchanged
//!
//! The manifest is built from the very same items, so it always matches the
//! emitted code.

use syn::{Item, Visibility};

use crate::attrs::{rustcall_attribute, strip_julia_struct_derive, strip_rustcall_attrs};
use crate::codegen::{inline_generic_wrappers, inline_struct_wrappers, transform_function};
use crate::extract::{fn_args, function_entry};
use crate::manifest::{Attribute, Field, Manifest, Method, Mode, Struct};
use crate::model::{collect_struct_models, StructModel};
use crate::types::{
    generics_to_type_params, has_type_params, is_inline_accessible_field_type,
    return_type_to_string, type_to_string,
};

pub struct Expanded {
    /// Transformed Rust source, ready for `rustc`.
    pub source: String,
    pub manifest: Manifest,
}

fn items_of(tokens: proc_macro2::TokenStream) -> Result<Vec<Item>, syn::Error> {
    let file: syn::File = syn::parse2(tokens)?;
    Ok(file.items)
}

fn unparse_items(items: Vec<Item>) -> String {
    unparse_file(Vec::new(), items)
}

fn unparse_file(attrs: Vec<syn::Attribute>, items: Vec<Item>) -> String {
    let file = syn::File {
        shebang: None,
        attrs,
        items,
    };
    prettyplease::unparse(&file)
}

pub fn expand(source: &str) -> Result<Expanded, syn::Error> {
    let file = syn::parse_file(source)?;
    let models = collect_struct_models(&file, Mode::Inline);
    let mut manifest = Manifest::new(Mode::Inline);
    let mut out: Vec<Item> = Vec::new();

    for item in &file.items {
        match item {
            Item::Fn(f) => {
                let attribute = rustcall_attribute(&f.attrs);
                match attribute {
                    Attribute::Julia | Attribute::JuliaPyo3 => {
                        let mut f = f.clone();
                        strip_rustcall_attrs(&mut f.attrs);
                        if has_type_params(&f.sig.generics) {
                            f.vis = Visibility::Public(Default::default());
                            manifest
                                .functions
                                .push(function_entry(&f, attribute, false));
                            out.push(Item::Fn(f));
                        } else {
                            manifest.functions.push(function_entry(&f, attribute, true));
                            out.extend(items_of(transform_function(f))?);
                        }
                    }
                    _ => {
                        manifest
                            .functions
                            .push(function_entry(f, Attribute::None, false));
                        out.push(item.clone());
                    }
                }
            }
            Item::Struct(s) => {
                let Some(model) = models.iter().find(|m| s.ident == m.name()) else {
                    out.push(item.clone());
                    continue;
                };
                let mut s = s.clone();
                strip_rustcall_attrs(&mut s.attrs);
                strip_julia_struct_derive(&mut s.attrs);
                s.vis = Visibility::Public(Default::default());
                out.push(Item::Struct(s.clone()));

                if model.is_generic() {
                    manifest.structs.push(generic_struct_entry(model, &s));
                } else {
                    let (tokens, meta) = inline_struct_wrappers(model);
                    out.extend(items_of(tokens)?);
                    manifest.structs.push(concrete_struct_entry(model, &meta));
                }
            }
            Item::Impl(imp) => {
                let mut imp = imp.clone();
                strip_rustcall_attrs(&mut imp.attrs);
                for ii in &mut imp.items {
                    if let syn::ImplItem::Fn(func) = ii {
                        strip_rustcall_attrs(&mut func.attrs);
                    }
                }
                out.push(Item::Impl(imp));
            }
            other => out.push(other.clone()),
        }
    }

    Ok(Expanded {
        // Crate-level inner attributes (`#![allow(...)]`, `//!` docs) are kept;
        // ordinary comments are not part of the AST and are dropped.
        source: unparse_file(file.attrs.clone(), out),
        manifest,
    })
}

fn methods_of(model: &StructModel, symbols: bool) -> Vec<Method> {
    let struct_name = &model.item.ident;
    model
        .methods
        .iter()
        .map(|m| {
            let returns_self = matches!(
                &m.func.sig.output,
                syn::ReturnType::Type(_, ty) if crate::types::is_self_type(ty, struct_name)
            );
            Method {
                name: m.name(),
                symbol: if symbols {
                    format!("{}_{}", struct_name, m.name())
                } else {
                    String::new()
                },
                is_static: m.is_static,
                is_mutable: m.is_mutable,
                is_constructor: m.name() == "new" || returns_self,
                args: fn_args(&m.func.sig),
                return_type: return_type_to_string(&m.func.sig.output),
                generic_wrapper: String::new(),
            }
        })
        .collect()
}

fn fields_of(model: &StructModel, accessors: &[(String, String, String)]) -> Vec<Field> {
    model
        .named_fields()
        .iter()
        .map(|(name, ty)| {
            let acc = accessors.iter().find(|(f, _, _)| *name == *f);
            Field {
                name: name.to_string(),
                rust_type: type_to_string(ty),
                ffi_compatible: acc.is_some(),
                getter: acc.map(|a| a.1.clone()).unwrap_or_default(),
                setter: acc.map(|a| a.2.clone()).unwrap_or_default(),
            }
        })
        .collect()
}

fn concrete_struct_entry(model: &StructModel, meta: &crate::codegen::InlineStructMeta) -> Struct {
    Struct {
        name: model.name(),
        attribute: model.attribute,
        type_params: Vec::new(),
        fields: fields_of(model, &meta.accessors),
        methods: methods_of(model, true),
        derives: model.derives.clone(),
        has_clone: meta.has_clone,
        has_owned_string_helper: meta.has_owned_string_helper,
        has_borrowed_string_helper: meta.has_borrowed_string_helper,
        context_source: String::new(),
        generic_wrappers: Vec::new(),
        line: model.line,
    }
}

fn generic_struct_entry(model: &StructModel, stripped_struct: &syn::ItemStruct) -> Struct {
    let wrappers = inline_generic_wrappers(model);
    let wrapper_names: Vec<&str> = wrappers.iter().map(|w| w.name.as_str()).collect();
    let accessors: Vec<(String, String, String)> = model
        .named_fields()
        .iter()
        .filter(|(_, ty)| is_inline_accessible_field_type(ty))
        .map(|(n, _)| {
            let getter = format!("{}_get_{}", model.name(), n);
            let setter = format!("{}_set_{}", model.name(), n);
            let has_setter = wrapper_names.contains(&setter.as_str());
            (
                n.to_string(),
                getter,
                if has_setter { setter } else { String::new() },
            )
        })
        .collect();

    let mut context_items: Vec<Item> = vec![Item::Struct(stripped_struct.clone())];
    for imp in &model.impls {
        let mut imp = imp.clone();
        strip_rustcall_attrs(&mut imp.attrs);
        for ii in &mut imp.items {
            if let syn::ImplItem::Fn(func) = ii {
                strip_rustcall_attrs(&mut func.attrs);
            }
        }
        context_items.push(Item::Impl(imp));
    }

    let mut methods = methods_of(model, false);
    for m in &mut methods {
        let wrapper_name = format!("{}_{}", model.name(), m.name);
        if let Some(w) = wrappers.iter().find(|w| w.name == wrapper_name) {
            m.generic_wrapper = w.source.clone();
        }
    }

    Struct {
        name: model.name(),
        attribute: model.attribute,
        type_params: generics_to_type_params(&model.item.generics),
        fields: fields_of(model, &accessors),
        methods,
        derives: model.derives.clone(),
        has_clone: false,
        has_owned_string_helper: false,
        has_borrowed_string_helper: false,
        context_source: unparse_items(context_items),
        generic_wrappers: wrappers,
        line: model.line,
    }
}
