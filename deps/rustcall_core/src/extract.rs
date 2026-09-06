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
use crate::cfg::{body_has_cfg, predicate_string, CfgSet};
use crate::codegen::returns_boxed_struct;

use crate::manifest::{
    Arg, Attribute, Field, Function, Manifest, Method, Mode, ReturnKind, Struct,
};
use crate::model::{collect_struct_models_in, StructModel};
use crate::types::{
    extract_option_type, extract_result_type, generics_to_type_params, has_impl_trait,
    has_type_params, is_ffi_compatible_type, is_str_ref_type, is_string_type,
    needs_clone_for_getter, return_type_to_string, type_to_string,
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
                abi: arg_abi(&pt.ty).to_string(),
            }),
            FnArg::Receiver(_) => None,
        })
        .collect()
}

/// The return kind of a wrapper that does no `Result`/`Option` lowering:
/// `Unit` for `()` or no return type, `Plain` otherwise. Struct method
/// wrappers are in that category (`generate_method_wrapper*` never wraps a
/// `Result`), so their manifest entry says so explicitly rather than leaving a
/// consumer to infer it from the type spelling (#275, #276).
pub fn plain_return_kind(output: &ReturnType) -> ReturnKind {
    match output {
        ReturnType::Default => ReturnKind::Unit,
        ReturnType::Type(..) => {
            if return_type_to_string(output) == "()" {
                ReturnKind::Unit
            } else {
                ReturnKind::Plain
            }
        }
    }
}

/// The manifest `abi` column of an argument type (see [`Arg::abi`]).
pub fn arg_abi(ty: &syn::Type) -> &'static str {
    if is_string_type(ty) {
        "string"
    } else if is_str_ref_type(ty) {
        "str"
    } else {
        ""
    }
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
    let name = func.sig.ident.to_string();
    // `#[julia]` / `#[julia_pyo3]` are additive: the item keeps its name and
    // the exported entry point is the wrapper next to it (#279). A plain
    // `#[no_mangle] extern "C"` function is exported under its own name.
    let symbol = match attribute {
        Attribute::Julia | Attribute::JuliaPyo3 if !is_generic => {
            crate::codegen::function_symbol(&name)
        }
        _ => name.clone(),
    };
    // The wrapper only lowers strings when it is actually generated; a generic
    // item is wrapped per instantiation (see `specialize`), not here.
    let return_abi = if wrapped && !is_generic {
        crate::codegen::return_abi(&func.sig)
    } else {
        ""
    };
    Function {
        name,
        symbol,
        attribute,
        vis: crate::attrs::visibility_string(&func.vis),
        skip_reason: String::new(),
        python_name: String::new(),
        exported,
        cfg: predicate_string(&func.attrs),
        cfg_features: crate::cfg::predicate_features(&func.attrs),
        is_generic,
        type_params: generics_to_type_params(&func.sig.generics),
        args: fn_args(&func.sig),
        return_type,
        return_kind,
        return_abi: return_abi.to_string(),
        ok_type,
        err_type,
        inner_type,
        // Derived from the normative `return_abi` column since schema 4 (#276).
        has_owned_string_helper: return_abi == "string",
        has_borrowed_string_helper: return_abi == "str",
        source: if is_generic {
            let mut stripped = func.clone();
            crate::attrs::strip_rustcall_attrs(&mut stripped.attrs);
            item_fn_source(&stripped)
        } else {
            String::new()
        },
        body_has_cfg: body_has_cfg(&func.block),
        line: func.span().start().line,
        module_path: Vec::new(),
    }
}

/// Manifest for a crate source file (proc-macro semantics).
pub fn extract_crate(source: &str) -> Result<Manifest, syn::Error> {
    extract_crate_with_cfg(source, None)
}

pub fn extract_crate_with_cfg(source: &str, cfg: Option<&CfgSet>) -> Result<Manifest, syn::Error> {
    extract_crate_with_cfg_scan(source, cfg, true)
}

/// Like [`extract_crate_with_cfg`], with the PyO3 scan (#275) switchable.
///
/// The scan is on by default: one file, treated as its own root. A caller that
/// can read files instead walks the crate's module tree with
/// [`extract_pyo3_file`] — which records the real `module_path` and the
/// reachability of every enclosing `mod` — and then passes `false` here so the
/// per-file pass does not report the same items a second time under the wrong
/// path.
pub fn extract_crate_with_cfg_scan(
    source: &str,
    cfg: Option<&CfgSet>,
    pyo3_scan: bool,
) -> Result<Manifest, syn::Error> {
    let mut file = syn::parse_file(source)?;
    if let Some(set) = cfg {
        crate::cfg::prune_file_or_error(set, &mut file)?;
    }
    let mut manifest = Manifest::new(Mode::Crate);
    extract_crate_items(&file.items, &mut manifest);
    // Items that carry only PyO3 attributes (#275). Reported with a PyO3
    // origin, `exported = false` and the symbol a Phase-2 wrapper crate will
    // emit; an item that also carries `#[julia]` is owned by `#[julia]` and is
    // skipped by the scan (see `crate::pyo3`). The scan walks inline modules
    // itself, because unlike the `#[julia]` path it records `module_path`: a
    // wrapper crate has to name the item as `user_crate::module::item`.
    if pyo3_scan {
        crate::pyo3::extract_pyo3_items(&file.items, &mut manifest);
    }
    Ok(manifest)
}

/// The PyO3 items of one file of a crate's module tree, plus the out-of-line
/// `mod` declarations it makes (#275).
///
/// `module_path` is where this file sits in the tree (empty for the crate
/// root) and `reachable` says whether every `mod` on the way to it is `pub`.
/// The caller resolves each returned [`crate::pyo3::PendingModule`] to a file
/// and calls this again; only it can touch the filesystem.
///
/// `scan` carries the crate-wide state: `#[pyclass]` structs and their
/// `#[pymethods]` blocks may live in different files, so the structs are only
/// written to a manifest by [`crate::pyo3::Pyo3Scan::finish`], once every file
/// has been seen.
pub fn extract_pyo3_file(
    source: &str,
    cfg: Option<&CfgSet>,
    module_path: &[String],
    reachable: bool,
    scan: &mut crate::pyo3::Pyo3Scan,
    manifest: &mut Manifest,
) -> Result<Vec<crate::pyo3::PendingModule>, syn::Error> {
    let mut file = syn::parse_file(source)?;
    if let Some(set) = cfg {
        crate::cfg::prune_file_or_error(set, &mut file)?;
    }
    Ok(scan.file(&file.items, module_path, reachable, manifest))
}

/// One level of items; inline modules are visited recursively.
fn extract_crate_items(items: &[Item], manifest: &mut Manifest) {
    for item in items {
        match item {
            Item::Fn(f) => {
                let attribute = rustcall_attribute(&f.attrs);
                match attribute {
                    Attribute::Julia => manifest.functions.push(function_entry(f, attribute, true)),
                    // `#[julia_pyo3]` exports the signature as written: no
                    // Result/Option wrapping and no string conversion (the
                    // attribute is not extended pending #275), so the manifest
                    // must not advertise the `(ptr, len)` string ABI either.
                    Attribute::JuliaPyo3 => {
                        let mut entry = function_entry(f, attribute, false);
                        entry.exported = !entry.is_generic;
                        for arg in &mut entry.args {
                            arg.abi.clear();
                        }
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
                abi: crate::codegen::field_abi(ty).to_string(),
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
                python_name: String::new(),
                vis: String::new(),
            }
        })
        .collect();
    let methods = model
        .methods
        .iter()
        .map(|m| Method {
            name: m.name(),
            symbol: crate::codegen::method_symbol(&struct_name.to_string(), &m.name()),
            is_static: m.is_static,
            is_mutable: m.is_mutable,
            is_constructor: returns_boxed_struct(struct_name, &m.func),
            vis: crate::attrs::visibility_string(&m.func.vis),
            skip_reason: String::new(),
            python_name: String::new(),
            accessor: String::new(),
            return_kind: plain_return_kind(&m.func.sig.output),
            ok_type: String::new(),
            err_type: String::new(),
            inner_type: String::new(),
            returns_boxed_struct: returns_boxed_struct(struct_name, &m.func),
            args: fn_args(&m.func.sig),
            return_type: return_type_to_string(&m.func.sig.output),
            // Crate method wrappers (`generate_method_wrapper_crate`) use the
            // same string ABI as inline ones, with per-method buffer types
            // (`<Struct>_<method>_RustCallOwnedString` / `_free_rust_string`).
            return_abi: crate::codegen::return_abi(&m.func.sig).to_string(),
            generic_wrapper: String::new(),
        })
        .collect();
    Struct {
        cfg: predicate_string(&model.item.attrs),
        cfg_features: crate::cfg::predicate_features(&model.item.attrs),
        name: model.name(),
        attribute: model.attribute,
        vis: crate::attrs::visibility_string(&model.item.vis),
        skip_reason: String::new(),
        python_name: String::new(),
        type_params: generics_to_type_params(&model.item.generics),
        fields,
        methods,
        derives: model.derives.clone(),
        has_clone: false,
        // A `String` field getter hands back an owned buffer, so the struct
        // carries `<Struct>_RustCallOwnedString` / `<Struct>_free_rust_string`
        // in crate mode too (#246).
        has_owned_string_helper: crate::codegen::crate_struct_needs_owned_string_helper(
            &model.item,
        ),
        has_borrowed_string_helper: false,
        context_source: String::new(),
        generic_wrappers: Vec::new(),
        line: model.line,
        module_path: Vec::new(),
    }
}
