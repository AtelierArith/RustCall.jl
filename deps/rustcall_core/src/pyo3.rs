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
use syn::{FnArg, ImplItem, ImplItemFn, Item, ItemFn, ItemImpl, ItemStruct, ReturnType, Type};

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
pub fn extract_pyo3_items(items: &[Item], manifest: &mut Manifest) {
    let mut path = Vec::new();
    extract_pyo3_items_in(items, &mut path, true, manifest);
}

fn extract_pyo3_items_in(
    items: &[Item],
    module_path: &mut Vec<String>,
    reachable: bool,
    manifest: &mut Manifest,
) {
    // `#[pyclass]` structs at this level, so a `#[pymethods] impl` below can be
    // matched to one (impl blocks are matched within the same level, as
    // `crate::model::collect_struct_models_in` does).
    let mut classes: Vec<Struct> = Vec::new();

    for item in items {
        match item {
            Item::Fn(f) => {
                if julia_owns_entry_point(&f.attrs) {
                    // Owned by `#[julia]`, which exports `rustcall_<name>`
                    // itself (#279): reporting it here would describe a second
                    // wrapper under the same symbol.
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
                    classes.push(class_entry(s, reachable, module_path));
                }
            }
            Item::Mod(m) => {
                if let Some((_, inner)) = &m.content {
                    let inner_reachable = reachable && matches!(m.vis, syn::Visibility::Public(_));
                    module_path.push(m.ident.to_string());
                    extract_pyo3_items_in(inner, module_path, inner_reachable, manifest);
                    module_path.pop();
                }
            }
            _ => {}
        }
    }

    // A `#[pyclass]` may have several `#[pymethods]` blocks (pyo3 supports it
    // through `multiple-pymethods`, and one `impl` per concern is common), so
    // methods accumulate across every matching block in source order.
    for item in items {
        let Item::Impl(imp) = item else { continue };
        if pyo3_marker(&imp.attrs) != Some(Pyo3Marker::Methods) {
            continue;
        }
        let Some(target) = impl_target_name(imp) else {
            continue;
        };
        let Some(class) = classes.iter_mut().find(|c| c.name == target) else {
            continue;
        };
        let owner_skip = class.skip_reason.clone();
        let target_ident = match last_ident(&imp.self_ty) {
            Some(id) => id.clone(),
            None => continue,
        };
        for ii in &imp.items {
            let ImplItem::Fn(func) = ii else { continue };
            class
                .methods
                .push(method_entry(&target_ident, func, &owner_skip));
        }
    }

    manifest.structs.extend(classes);
}

fn impl_target_name(item: &ItemImpl) -> Option<String> {
    if item.trait_.is_some() {
        return None;
    }
    last_ident(&item.self_ty).map(|id| id.to_string())
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

    let mut ok_type = String::new();
    let mut err_type = String::new();
    let mut inner_type = String::new();
    let return_kind = match &func.sig.output {
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
            } else if return_type == "()" {
                ReturnKind::Unit
            } else {
                ReturnKind::Plain
            }
        }
    };

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

    let mut fields = Vec::new();
    if let syn::Fields::Named(named) = &item.fields {
        for f in &named.named {
            let Some(ident) = f.ident.clone() else {
                continue;
            };
            let access = pyo3_field_access(&f.attrs);
            if !access.get && !access.set {
                continue;
            }
            // A skipped class has no handle type, so its fields have no
            // accessors either, whatever their types.
            let usable = reason.is_empty()
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
    let return_kind = match &func.sig.output {
        ReturnType::Type(_, ty) if py_result_ok_type(ty).is_some() => ReturnKind::PyResult,
        _ => ReturnKind::Plain,
    };
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
