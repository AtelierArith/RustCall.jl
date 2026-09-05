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
use crate::cfg::{predicate_string, CfgSet};
use crate::codegen::{inline_generic_wrappers, inline_struct_wrappers, transform_function};
use crate::extract::{fn_args, function_entry};
use crate::manifest::{Attribute, Field, Manifest, Method, Mode, Struct};
use crate::model::{collect_struct_models_in, StructModel};
use crate::types::{
    const_param_names, generics_to_type_params, has_impl_trait, has_type_params,
    is_inline_accessible_field_type, return_type_to_string, type_to_string,
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
    expand_with_cfg(source, None)
}

/// Like [`expand`], but items disabled under `cfg` are dropped before
/// expansion, so the manifest only reports what rustc will compile. Without a
/// configuration every item is kept and its predicate is recorded.
pub fn expand_with_cfg(source: &str, cfg: Option<&CfgSet>) -> Result<Expanded, syn::Error> {
    let mut file = syn::parse_file(source)?;
    if let Some(set) = cfg {
        // Crate-level `#![cfg(...)]` first: a disabled crate compiles to
        // nothing, so none of its items may be reported.
        crate::cfg::prune_file_or_error(set, &mut file)?;
    }
    let mut manifest = Manifest::new(Mode::Inline);
    let out = expand_items(&file.items, &mut manifest, &[])?;

    Ok(Expanded {
        // Crate-level inner attributes (`#![allow(...)]`, `//!` docs) are kept;
        // ordinary comments are not part of the AST and are dropped.
        source: unparse_file(file.attrs.clone(), out),
        manifest,
    })
}

/// Expand one level of items. Inline modules (`mod m { ... }`) are expanded
/// recursively so `#[julia]` items inside them are transformed and reported;
/// `#[no_mangle]` symbols are unaffected by the module path.
fn expand_items(
    items: &[Item],
    manifest: &mut Manifest,
    module_path: &[String],
) -> Result<Vec<Item>, syn::Error> {
    let models = collect_struct_models_in(items, Mode::Inline);
    let mut out: Vec<Item> = Vec::new();
    let push_fn = |manifest: &mut Manifest, mut entry: crate::manifest::Function| {
        entry.module_path = module_path.to_vec();
        manifest.functions.push(entry);
    };

    for item in items {
        match item {
            Item::Fn(f) => {
                let attribute = rustcall_attribute(&f.attrs);
                match attribute {
                    Attribute::Julia | Attribute::JuliaPyo3 => {
                        let mut f = f.clone();
                        strip_rustcall_attrs(&mut f.attrs);
                        let consts = const_param_names(&f.sig.generics);
                        let impl_trait = has_impl_trait(&f.sig);
                        if !consts.is_empty() || impl_trait {
                            // Const generics and `impl Trait` cannot be instantiated
                            // from Julia, and `#[no_mangle]` on a still-generic fn
                            // exports no symbol: fail at compile time rather than at
                            // the first call.
                            let name = f.sig.ident.to_string();
                            let msg = if impl_trait {
                                format!("#[julia] function `{name}` uses `impl Trait` in its signature; `impl Trait` is not supported by RustCall")
                            } else {
                                format!(
                                    "#[julia] function `{name}` has const generic parameter(s) {}; const generics are not supported by RustCall",
                                    consts.join(", ")
                                )
                            };
                            out.push(syn::parse_quote! { compile_error!(#msg); });
                            f.vis = Visibility::Public(Default::default());
                            push_fn(manifest, function_entry(&f, attribute, false));
                            out.push(Item::Fn(f));
                        } else if has_type_params(&f.sig.generics) {
                            f.vis = Visibility::Public(Default::default());
                            push_fn(manifest, function_entry(&f, attribute, false));
                            out.push(Item::Fn(f));
                        } else {
                            push_fn(manifest, function_entry(&f, attribute, true));
                            out.extend(items_of(transform_function(f))?);
                        }
                    }
                    _ => {
                        push_fn(manifest, function_entry(f, Attribute::None, false));
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
                    let mut entry = generic_struct_entry(model, &s);
                    // Emit the generic wrappers (not exported) next to the struct so
                    // `specialize` can instantiate them in place, with every
                    // module-scoped name in reach.
                    for w in &entry.generic_wrappers {
                        let f: syn::File = syn::parse_str(&w.source)?;
                        out.extend(f.items);
                    }
                    entry.module_path = module_path.to_vec();
                    manifest.structs.push(entry);
                } else {
                    let (tokens, meta) = inline_struct_wrappers(model);
                    out.extend(items_of(tokens)?);
                    let mut entry = concrete_struct_entry(model, &meta);
                    entry.module_path = module_path.to_vec();
                    manifest.structs.push(entry);
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
            Item::Mod(m) => match &m.content {
                Some((brace, inner)) => {
                    let mut m = m.clone();
                    let mut path = module_path.to_vec();
                    path.push(m.ident.to_string());
                    m.content = Some((*brace, expand_items(inner, manifest, &path)?));
                    out.push(Item::Mod(m));
                }
                None => out.push(item.clone()),
            },
            other => out.push(other.clone()),
        }
    }

    Ok(out)
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
                return_abi: crate::codegen::return_abi(&m.func.sig).to_string(),
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
        cfg: predicate_string(&model.item.attrs),
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
        module_path: Vec::new(),
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
        cfg: predicate_string(&model.item.attrs),
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
        module_path: Vec::new(),
    }
}
