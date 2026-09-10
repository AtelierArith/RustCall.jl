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
use crate::model::{ModelTree, StructModel};
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
    // Structs and their impl blocks are matched across the whole block first
    // (#315), so an `impl super::Gauge` inside `mod ops` wraps `Gauge`'s
    // methods next to the struct.
    let tree = ModelTree::collect(&file.items, Mode::Inline);
    let mut out = expand_items(&file.items, &mut manifest, &[], &[], &tree)?;

    // Two generated `#[no_mangle]` items of one block wanting the same symbol
    // (#342 review). The scheme keeps items in different modules apart by
    // construction, so what is left is a coincidence it cannot exclude — a
    // struct `Foo_bar` next to a `Foo::bar` that hands back an owned string,
    // both wanting `Foo_bar_free_rust_string`. rustc would report it inside
    // generated code; say which two items collide instead.
    for (symbol, first, second) in manifest.duplicate_symbols() {
        let msg = format!(
            "RustCall would export the symbol `{symbol}` twice in this block: for {first} and \
             for {second}. The scheme derives every symbol from the item's name and module \
             path (`rustcall_<fn>`, `rustcall_<Struct>_<method>`, `<Struct>_free`, \
             `<Struct>_get_<field>`, `<owner>_free_rust_string`, ... — #300), so two items \
             whose names differ only where the scheme joins them meet here. Rename one of \
             them."
        );
        out.insert(0, syn::parse_quote! { compile_error!(#msg); });
    }

    Ok(Expanded {
        // Crate-level inner attributes (`#![allow(...)]`, `//!` docs) are kept;
        // ordinary comments are not part of the AST and are dropped.
        source: unparse_file(file.attrs.clone(), out),
        manifest,
    })
}

/// Expand one level of items. Inline modules (`mod m { ... }`) are expanded
/// recursively so `#[julia]` items inside them are transformed and reported,
/// and every exported symbol is qualified by the module path (#300): the
/// expander sees the whole block, so — unlike the proc-macro — it needs no
/// `#[julia]` marker on the module (one is accepted and stripped).
///
/// `enclosing_cfg` is the `#[cfg]` of every enclosing module, folded into each
/// entry's `cfg` / `cfg_features` (#300 review).
fn expand_items(
    items: &[Item],
    manifest: &mut Manifest,
    module_path: &[String],
    enclosing_cfg: &[syn::Attribute],
    tree: &ModelTree,
) -> Result<Vec<Item>, syn::Error> {
    let mut out: Vec<Item> = Vec::new();
    let push_fn = |manifest: &mut Manifest, entry: crate::manifest::Function| {
        manifest.functions.push(entry);
    };

    for item in items {
        match item {
            Item::Fn(f) => {
                let attribute = rustcall_attribute(&f.attrs);
                match attribute {
                    Attribute::Julia => {
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
                            push_fn(
                                manifest,
                                function_entry(&f, attribute, false, module_path, enclosing_cfg),
                            );
                            out.push(Item::Fn(f));
                        } else if has_type_params(&f.sig.generics) {
                            f.vis = Visibility::Public(Default::default());
                            push_fn(
                                manifest,
                                function_entry(&f, attribute, false, module_path, enclosing_cfg),
                            );
                            out.push(Item::Fn(f));
                        } else {
                            push_fn(
                                manifest,
                                function_entry(&f, attribute, true, module_path, enclosing_cfg),
                            );
                            out.extend(items_of(transform_function(f, module_path))?);
                        }
                    }
                    _ => {
                        push_fn(
                            manifest,
                            function_entry(f, Attribute::None, false, module_path, enclosing_cfg),
                        );
                        out.push(item.clone());
                    }
                }
            }
            Item::Struct(s) => {
                let Some(model) = tree.find(module_path, &s.ident.to_string()) else {
                    out.push(item.clone());
                    continue;
                };
                let mut s = s.clone();
                strip_rustcall_attrs(&mut s.attrs);
                strip_julia_struct_derive(&mut s.attrs);
                s.vis = Visibility::Public(Default::default());
                out.push(Item::Struct(s.clone()));

                if model.is_generic() {
                    let entry = generic_struct_entry(model, &s, module_path, enclosing_cfg);
                    // Emit the generic wrappers (not exported) next to the struct so
                    // `specialize` can instantiate them in place, with every
                    // module-scoped name in reach.
                    for w in &entry.generic_wrappers {
                        let f: syn::File = syn::parse_str(&w.source)?;
                        out.extend(f.items);
                    }
                    manifest.structs.push(entry);
                } else {
                    let (tokens, meta) = inline_struct_wrappers(model, module_path);
                    out.extend(items_of(tokens)?);
                    let entry = concrete_struct_entry(model, &meta, module_path, enclosing_cfg);
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
                    // A `#[julia]` marker on the module is the crate-mode
                    // spelling of what the expander sees for itself (#300).
                    strip_rustcall_attrs(&mut m.attrs);
                    let mut path = module_path.to_vec();
                    path.push(m.ident.to_string());
                    let cfg = crate::cfg::effective_cfg_attrs(enclosing_cfg, &m.attrs);
                    m.content = Some((*brace, expand_items(inner, manifest, &path, &cfg, tree)?));
                    out.push(Item::Mod(m));
                }
                None => out.push(item.clone()),
            },
            other => out.push(other.clone()),
        }
    }

    // The wrappers of `#[julia] impl` blocks that sit in *this* module while
    // their struct lives elsewhere (#342). They are emitted here, where the
    // types their signatures name are in scope, spelling the struct the way
    // the header does; the exported symbol still follows the struct, so this
    // changes nothing a caller can see.
    for foreign in tree.foreign_methods(module_path) {
        out.extend(items_of(crate::codegen::inline_foreign_method_wrapper(
            foreign.self_ty,
            foreign.struct_name,
            foreign.struct_module_path,
            foreign.method,
        ))?);
    }

    for name in symbol_collisions(items, &out) {
        let msg = format!(
            "RustCall generates an item named `{name}` in this module, but the block already \
             defines one. `#[julia]` keeps the annotated item and emits its `extern \"C\"` entry \
             point next to it (`rustcall_<fn>`, `rustcall_<Struct>_<method>`, `<Struct>_free`, \
             `<Struct>_get_<field>`, `CResult_<fn>`, `<fn>_RustCallOwnedString`, ... — with the \
             module path folded into `<fn>` / `<Struct>` inside a module, #300), so rename \
             the conflicting item (#279)."
        );
        out.insert(0, syn::parse_quote! { compile_error!(#msg); });
    }

    Ok(out)
}

/// Rust name-resolution namespace of an item: `struct Foo` and `fn Foo` may
/// coexist, `fn Foo` and `const Foo` may not.
fn item_key(item: &Item) -> Option<(u8, String)> {
    const TYPE_NS: u8 = 0;
    const VALUE_NS: u8 = 1;
    match item {
        Item::Fn(f) => Some((VALUE_NS, f.sig.ident.to_string())),
        Item::Const(c) => Some((VALUE_NS, c.ident.to_string())),
        Item::Static(s) => Some((VALUE_NS, s.ident.to_string())),
        Item::Struct(s) => Some((TYPE_NS, s.ident.to_string())),
        Item::Enum(e) => Some((TYPE_NS, e.ident.to_string())),
        Item::Union(u) => Some((TYPE_NS, u.ident.to_string())),
        Item::Trait(t) => Some((TYPE_NS, t.ident.to_string())),
        Item::Type(t) => Some((TYPE_NS, t.ident.to_string())),
        Item::Mod(m) => Some((TYPE_NS, m.ident.to_string())),
        _ => None,
    }
}

fn key_counts(items: &[Item]) -> std::collections::HashMap<(u8, String), usize> {
    let mut counts = std::collections::HashMap::new();
    for item in items {
        if let Some(key) = item_key(item) {
            *counts.entry(key).or_insert(0) += 1;
        }
    }
    counts
}

/// Names that the wrappers generated for one module level would take away from
/// an item the user wrote there.
///
/// `#[julia]` is additive (#279), so the exported symbols are chosen not to
/// collide with the annotated items themselves (`rustcall_<fn>`); a *different*
/// user item may still happen to carry a generated name. Inline expansion sees
/// the whole module and can say so precisely, which is worth a clear error
/// rather than a duplicate-definition diagnostic pointing at generated code.
/// The proc-macro sees one item at a time and cannot make this check.
fn symbol_collisions(original: &[Item], expanded: &[Item]) -> Vec<String> {
    let before = key_counts(original);
    let after = key_counts(expanded);
    let mut clashes: Vec<String> = after
        .iter()
        .filter(|(key, count)| **count > before.get(*key).copied().unwrap_or(0))
        .filter(|(key, _)| before.contains_key(*key))
        .map(|((_, name), _)| name.clone())
        .collect();
    clashes.sort();
    clashes
}

/// `symbols` doubles as "this struct's methods are wrapped here": a concrete
/// struct gets `extern "C"` wrappers with exported symbols, a generic one gets
/// generic wrappers registered for monomorphization instead. Only the former
/// lower `Result` / `Option` (#268).
///
/// `module_path` is the struct's own module: a method whose block sits there
/// is wrapped next to the struct and shares its string buffers, one from a
/// block elsewhere carries buffers of its own (#342). The manifest states
/// which (`Method.string_owner`) instead of leaving Julia to derive it from
/// the flavour.
fn methods_of(
    model: &StructModel,
    symbols: bool,
    stem: &str,
    module_path: &[String],
) -> Vec<Method> {
    let struct_name = &model.item.ident;
    model
        .methods
        .iter()
        .map(|m| {
            let shape = crate::extract::method_return_shape(struct_name, &m.func, symbols);
            let returns_self = matches!(
                &m.func.sig.output,
                syn::ReturnType::Type(_, ty) if crate::types::is_self_type(ty, struct_name)
            );
            Method {
                name: m.name(),
                symbol: if symbols {
                    crate::codegen::method_symbol_of(stem, &m.name())
                } else {
                    String::new()
                },
                string_owner: match (symbols, m.is_local_to(module_path)) {
                    (false, _) => String::new(),
                    (true, true) => stem.to_string(),
                    (true, false) => crate::codegen::method_string_owner(stem, &m.name()),
                },
                is_static: m.is_static,
                is_mutable: m.is_mutable,
                is_constructor: m.name() == "new" || returns_self,
                vis: crate::attrs::visibility_string(&m.func.vis),
                skip_reason: String::new(),
                python_name: String::new(),
                accessor: String::new(),
                attribute: m.attribute,
                return_kind: shape.kind,
                ok_type: shape.ok_type,
                err_type: shape.err_type,
                inner_type: shape.inner_type,
                ok_abi: shape.ok_abi,
                err_abi: shape.err_abi,
                inner_abi: shape.inner_abi,
                returns_boxed_struct: crate::codegen::returns_boxed_struct(struct_name, &m.func),
                args: fn_args(&m.func.sig),
                return_type: return_type_to_string(&m.func.sig.output),
                return_abi: crate::codegen::return_abi(&m.func.sig).to_string(),
                generic_wrapper: String::new(),
                // The block's and its modules' predicates gate the method as
                // much as its own do (#300 review, #315).
                cfg: crate::cfg::predicate_string(&crate::cfg::effective_cfg_attrs(
                    &m.enclosing_cfg,
                    &m.func.attrs,
                )),
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
                abi: crate::codegen::field_abi(ty).to_string(),
                vec_element: String::new(),
                free_symbol: String::new(),
                ffi_compatible: acc.is_some(),
                getter: acc.map(|a| a.1.clone()).unwrap_or_default(),
                setter: acc.map(|a| a.2.clone()).unwrap_or_default(),
                python_name: String::new(),
                vis: String::new(),
                cfg: String::new(),
            }
        })
        .collect()
}

fn concrete_struct_entry(
    model: &StructModel,
    meta: &crate::codegen::InlineStructMeta,
    module_path: &[String],
    enclosing_cfg: &[syn::Attribute],
) -> Struct {
    let stem = crate::codegen::symbol_stem(module_path, &model.name());
    let effective_cfg = crate::cfg::effective_cfg_attrs(enclosing_cfg, &model.item.attrs);
    Struct {
        callable_path: Vec::new(),
        cfg: predicate_string(&effective_cfg),
        cfg_features: crate::cfg::predicate_features(&effective_cfg),
        name: model.name(),
        attribute: model.attribute,
        vis: crate::attrs::visibility_string(&model.item.vis),
        skip_reason: String::new(),
        python_name: String::new(),
        pyo3_extends: String::new(),
        pyo3_options: Vec::new(),
        type_params: Vec::new(),
        fields: fields_of(model, &meta.accessors),
        methods: methods_of(model, true, &stem, module_path),
        ffi_name: stem,
        derives: model.derives.clone(),
        has_clone: meta.has_clone,
        has_owned_string_helper: meta.has_owned_string_helper,
        has_borrowed_string_helper: meta.has_borrowed_string_helper,
        context_source: String::new(),
        generic_wrappers: Vec::new(),
        line: model.line,
        module_path: module_path.to_vec(),
    }
}

fn generic_struct_entry(
    model: &StructModel,
    stripped_struct: &syn::ItemStruct,
    module_path: &[String],
    enclosing_cfg: &[syn::Attribute],
) -> Struct {
    let effective_cfg = crate::cfg::effective_cfg_attrs(enclosing_cfg, &model.item.attrs);
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

    // A generic struct exports nothing itself: its wrappers are instantiated
    // by `specialize` under names Julia chooses, so the stem is recorded for
    // the consumer and never spelled into a symbol here.
    let stem = crate::codegen::symbol_stem(module_path, &model.name());
    let mut methods = methods_of(model, false, &stem, module_path);
    for m in &mut methods {
        let wrapper_name = format!("{}_{}", model.name(), m.name);
        if let Some(w) = wrappers.iter().find(|w| w.name == wrapper_name) {
            m.generic_wrapper = w.source.clone();
        }
    }

    Struct {
        callable_path: Vec::new(),
        cfg: predicate_string(&effective_cfg),
        cfg_features: crate::cfg::predicate_features(&effective_cfg),
        name: model.name(),
        ffi_name: stem,
        attribute: model.attribute,
        vis: crate::attrs::visibility_string(&model.item.vis),
        skip_reason: String::new(),
        python_name: String::new(),
        pyo3_extends: String::new(),
        pyo3_options: Vec::new(),
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
        module_path: module_path.to_vec(),
    }
}
