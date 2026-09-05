//! Manifest extraction.
//!
//! * `extract_crate(source)`: manifest for a crate source file, following the
//!   proc-macro's rules (what `juliacall_macros` would actually generate).
//! * `extract_inline(source)`: manifest for a `rust"""` block; delegates to
//!   [`crate::expand::expand`] so the manifest and the expanded code cannot
//!   disagree.

use syn::spanned::Spanned;
use syn::{FnArg, Item, ItemFn, Pat, ReturnType};

use crate::attrs::{has_no_mangle, rustcall_attribute};
use crate::cfg::{predicate_string, CfgSet};
use crate::codegen::returns_boxed_struct;
use crate::manifest::{
    Arg, Attribute, Field, Function, Manifest, Method, Mode, ReturnKind, Struct,
};
use crate::model::{collect_struct_models_in, StructModel};
use crate::types::{
    extract_option_type, extract_result_type, generics_to_type_params, has_impl_trait,
    has_type_params, is_ffi_compatible_type, needs_clone_for_getter, return_type_to_string,
    type_to_string,
};

pub fn extract(source: &str, mode: Mode) -> Result<Manifest, syn::Error> {
    extract_with_cfg(source, mode, None)
}

/// Like [`extract`], but items disabled under `cfg` are dropped first
/// (see [`crate::cfg::CfgSet::prune_items`]).
pub fn extract_with_cfg(
    source: &str,
    mode: Mode,
    cfg: Option<&CfgSet>,
) -> Result<Manifest, syn::Error> {
    match mode {
        Mode::Inline => crate::expand::expand_with_cfg(source, cfg).map(|e| e.manifest),
        Mode::Crate => extract_crate_with_cfg(source, cfg),
    }
}

pub fn fn_args(sig: &syn::Signature) -> Vec<Arg> {
    sig.inputs
        .iter()
        .filter_map(|a| match a {
            FnArg::Typed(pt) => Some(Arg {
                name: match pt.pat.as_ref() {
                    Pat::Ident(pi) => pi.ident.to_string(),
                    other => quote::quote!(#other).to_string(),
                },
                rust_type: type_to_string(&pt.ty),
            }),
            FnArg::Receiver(_) => None,
        })
        .collect()
}

fn item_fn_source(func: &ItemFn) -> String {
    let file = syn::File {
        shebang: None,
        attrs: Vec::new(),
        items: vec![Item::Fn(func.clone())],
    };
    prettyplease::unparse(&file)
}

/// Build the manifest entry of a free function.
///
/// `wrapped` says whether RustCall codegen (`transform_function`) is applied,
/// which decides the `Result`/`Option` return kinds and the exported flag.
pub fn function_entry(func: &ItemFn, attribute: Attribute, wrapped: bool) -> Function {
    let is_generic = has_type_params(&func.sig.generics) || has_impl_trait(&func.sig);
    let return_type = return_type_to_string(&func.sig.output);
    let mut ok_type = String::new();
    let mut err_type = String::new();
    let mut inner_type = String::new();
    let return_kind = match &func.sig.output {
        ReturnType::Default => ReturnKind::Unit,
        ReturnType::Type(_, ty) => {
            if let (true, Some(r)) = (wrapped, extract_result_type(ty)) {
                ok_type = type_to_string(&r.ok_type);
                err_type = type_to_string(&r.err_type);
                ReturnKind::Result
            } else if let (true, Some(o)) = (wrapped, extract_option_type(ty)) {
                inner_type = type_to_string(&o.inner_type);
                ReturnKind::Option
            } else if return_type == "()" {
                ReturnKind::Unit
            } else {
                ReturnKind::Plain
            }
        }
    };
    let exported = if is_generic {
        false
    } else if wrapped {
        true
    } else {
        has_no_mangle(&func.attrs)
            && func
                .sig
                .abi
                .as_ref()
                .and_then(|abi| abi.name.as_ref())
                .map(|n| n.value() == "C")
                .unwrap_or(false)
    };
    Function {
        name: func.sig.ident.to_string(),
        symbol: func.sig.ident.to_string(),
        attribute,
        exported,
        cfg: predicate_string(&func.attrs),
        is_generic,
        type_params: generics_to_type_params(&func.sig.generics),
        args: fn_args(&func.sig),
        return_type,
        return_kind,
        ok_type,
        err_type,
        inner_type,
        source: if is_generic {
            let mut stripped = func.clone();
            crate::attrs::strip_rustcall_attrs(&mut stripped.attrs);
            item_fn_source(&stripped)
        } else {
            String::new()
        },
        line: func.span().start().line,
        module_path: Vec::new(),
    }
}

/// Manifest for a crate source file (proc-macro semantics).
pub fn extract_crate(source: &str) -> Result<Manifest, syn::Error> {
    extract_crate_with_cfg(source, None)
}

pub fn extract_crate_with_cfg(source: &str, cfg: Option<&CfgSet>) -> Result<Manifest, syn::Error> {
    let mut file = syn::parse_file(source)?;
    if let Some(set) = cfg {
        crate::cfg::prune_or_error(set, &mut file.items)?;
    }
    let mut manifest = Manifest::new(Mode::Crate);
    extract_crate_items(&file.items, &mut manifest);
    Ok(manifest)
}

/// One level of items; inline modules are visited recursively.
fn extract_crate_items(items: &[Item], manifest: &mut Manifest) {
    for item in items {
        match item {
            Item::Fn(f) => {
                let attribute = rustcall_attribute(&f.attrs);
                match attribute {
                    Attribute::Julia => manifest.functions.push(function_entry(f, attribute, true)),
                    // `#[julia_pyo3]` does not wrap Result/Option; report the raw signature.
                    Attribute::JuliaPyo3 => {
                        let mut entry = function_entry(f, attribute, false);
                        entry.exported = !entry.is_generic;
                        manifest.functions.push(entry);
                    }
                    _ => {}
                }
            }
            Item::Mod(m) => {
                if let Some((_, inner)) = &m.content {
                    extract_crate_items(inner, manifest);
                }
            }
            _ => {}
        }
    }

    for model in collect_struct_models_in(items, Mode::Crate) {
        manifest.structs.push(crate_struct_entry(&model));
    }
}

fn crate_struct_entry(model: &StructModel) -> Struct {
    let struct_name = &model.item.ident;
    let fields = model
        .named_fields()
        .iter()
        .map(|(name, ty)| {
            let ffi_compatible = is_ffi_compatible_type(ty) || needs_clone_for_getter(ty);
            Field {
                name: name.to_string(),
                rust_type: type_to_string(ty),
                ffi_compatible,
                getter: if ffi_compatible {
                    format!("{}_get_{}", struct_name, name)
                } else {
                    String::new()
                },
                setter: if ffi_compatible {
                    format!("{}_set_{}", struct_name, name)
                } else {
                    String::new()
                },
            }
        })
        .collect();
    let methods = model
        .methods
        .iter()
        .map(|m| Method {
            name: m.name(),
            symbol: format!("{}_{}", struct_name, m.name()),
            is_static: m.is_static,
            is_mutable: m.is_mutable,
            is_constructor: returns_boxed_struct(struct_name, &m.func),
            args: fn_args(&m.func.sig),
            return_type: return_type_to_string(&m.func.sig.output),
            generic_wrapper: String::new(),
        })
        .collect();
    Struct {
        cfg: predicate_string(&model.item.attrs),
        name: model.name(),
        attribute: model.attribute,
        type_params: generics_to_type_params(&model.item.generics),
        fields,
        methods,
        derives: model.derives.clone(),
        has_clone: false,
        has_owned_string_helper: false,
        has_borrowed_string_helper: false,
        context_source: String::new(),
        generic_wrappers: Vec::new(),
        line: model.line,
        module_path: Vec::new(),
    }
}
