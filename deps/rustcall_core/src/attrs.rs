//! Attribute inspection helpers (`#[julia]`, `#[julia_pyo3]`,
//! `#[derive(JuliaStruct)]`, and the PyO3 entry-point attributes scanned by
//! #275).

use syn::{Attribute, Expr, Lit, Meta, Visibility};

use crate::manifest::Attribute as ManifestAttribute;

pub fn is_julia_attr(attr: &Attribute) -> bool {
    attr.path().is_ident("julia")
}

pub fn is_julia_pyo3_attr(attr: &Attribute) -> bool {
    attr.path().is_ident("julia_pyo3")
}

pub fn is_rustcall_attr(attr: &Attribute) -> bool {
    is_julia_attr(attr) || is_julia_pyo3_attr(attr)
}

/// A PyO3 entry-point attribute on an item.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pyo3Marker {
    /// `#[pyfunction]`
    Function,
    /// `#[pyclass]`
    Class,
    /// `#[pymethods]`
    Methods,
    /// `#[pymodule]`
    Module,
}

/// A PyO3 attribute *inside* a `#[pymethods]` block.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pyo3MethodMarker {
    /// `#[new]` — the Python constructor.
    New,
    /// `#[staticmethod]`
    StaticMethod,
    /// `#[classmethod]` — takes a `&Bound<'_, PyType>` first argument, so the
    /// scan almost always skips it for using a pyo3 type.
    ClassMethod,
    /// `#[getter]` / `#[getter(python_name)]`
    Getter,
    /// `#[setter]` / `#[setter(python_name)]`
    Setter,
}

/// The path of `attr` written as `pyo3`-qualified or bare: `#[pyfunction]` and
/// `#[pyo3::pyfunction]` both yield `Some("pyfunction")`, while a `#[foo::pyfunction]`
/// from an unrelated crate yields `None`.
fn pyo3_path_name(attr: &Attribute) -> Option<String> {
    let segments = &attr.path().segments;
    let last = segments.last()?.ident.to_string();
    match segments.len() {
        1 => Some(last),
        _ if segments[0].ident == "pyo3" => Some(last),
        _ => None,
    }
}

/// Which PyO3 entry-point attribute marks the item, if any. Both the bare and
/// the `pyo3::`-qualified spelling are recognised.
pub fn pyo3_marker(attrs: &[Attribute]) -> Option<Pyo3Marker> {
    attrs
        .iter()
        .find_map(|a| match pyo3_path_name(a)?.as_str() {
            "pyfunction" => Some(Pyo3Marker::Function),
            "pyclass" => Some(Pyo3Marker::Class),
            "pymethods" => Some(Pyo3Marker::Methods),
            "pymodule" => Some(Pyo3Marker::Module),
            _ => None,
        })
}

/// Whether the item carries a PyO3 entry-point attribute (`#[pyfunction]`,
/// `#[pyo3::pyfunction]`, `#[pymethods]`, `#[pyclass]`, `#[pymodule]`).
pub fn is_pyo3_attr(attr: &Attribute) -> bool {
    matches!(
        pyo3_path_name(attr).as_deref(),
        Some("pyfunction" | "pymethods" | "pyclass" | "pymodule")
    )
}

/// The PyO3 method attributes carried by an `impl` item, in source order.
pub fn pyo3_method_markers(attrs: &[Attribute]) -> Vec<Pyo3MethodMarker> {
    attrs
        .iter()
        .filter_map(|a| match pyo3_path_name(a)?.as_str() {
            "new" => Some(Pyo3MethodMarker::New),
            "staticmethod" => Some(Pyo3MethodMarker::StaticMethod),
            "classmethod" => Some(Pyo3MethodMarker::ClassMethod),
            "getter" => Some(Pyo3MethodMarker::Getter),
            "setter" => Some(Pyo3MethodMarker::Setter),
            _ => None,
        })
        .collect()
}

/// The Python-visible name an item is exposed under, when it differs from the
/// Rust name: `#[pyo3(name = "x")]`, `#[pyfunction(name = "x")]`,
/// `#[pyclass(name = "X")]`, and the `#[getter(x)]` / `#[setter(x)]` shorthand.
/// Empty when the Rust name is used as-is.
pub fn pyo3_name(attrs: &[Attribute]) -> String {
    for attr in attrs {
        let Some(name) = pyo3_path_name(attr) else {
            continue;
        };
        match name.as_str() {
            "pyo3" | "pyfunction" | "pyclass" | "pymodule" => {
                if let Some(value) = nested_name_value(attr) {
                    return value;
                }
            }
            "getter" | "setter" => {
                // `#[getter(python_name)]` / `#[getter(name = "python_name")]`.
                if let Some(value) = nested_name_value(attr) {
                    return value;
                }
                if let Meta::List(list) = &attr.meta {
                    if let Ok(id) = syn::parse2::<syn::Ident>(list.tokens.clone()) {
                        return id.to_string();
                    }
                }
            }
            _ => {}
        }
    }
    String::new()
}

/// `name = "..."` inside a `#[...(...)]` attribute, if present.
fn nested_name_value(attr: &Attribute) -> Option<String> {
    let Meta::List(list) = &attr.meta else {
        return None;
    };
    let mut found = None;
    let _ = list.parse_nested_meta(|meta| {
        if meta.path.is_ident("name") {
            if let Ok(value) = meta.value() {
                if let Ok(Expr::Lit(lit)) = value.parse::<Expr>() {
                    if let Lit::Str(s) = lit.lit {
                        found = Some(s.value());
                    }
                }
            }
        }
        Ok(())
    });
    found
}

/// How a `#[pyclass]` field is exposed: `#[pyo3(get)]`, `#[pyo3(get, set)]`,
/// optionally with `name = "..."`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Pyo3FieldAccess {
    pub get: bool,
    pub set: bool,
    pub python_name: String,
}

/// Read `#[pyo3(get, set, name = "...")]` off a `#[pyclass]` field.
pub fn pyo3_field_access(attrs: &[Attribute]) -> Pyo3FieldAccess {
    let mut access = Pyo3FieldAccess::default();
    for attr in attrs {
        if pyo3_path_name(attr).as_deref() != Some("pyo3") {
            continue;
        }
        let Meta::List(list) = &attr.meta else {
            continue;
        };
        let _ = list.parse_nested_meta(|meta| {
            if meta.path.is_ident("get") {
                access.get = true;
            } else if meta.path.is_ident("set") {
                access.set = true;
            } else if meta.path.is_ident("name") {
                if let Ok(value) = meta.value() {
                    if let Ok(Expr::Lit(lit)) = value.parse::<Expr>() {
                        if let Lit::Str(s) = lit.lit {
                            access.python_name = s.value();
                        }
                    }
                }
            }
            Ok(())
        });
    }
    access
}

/// The manifest `vis` column of an item: `"pub"`, `"pub(crate)"`,
/// `"pub(super)"`, `"pub(in path)"`, or `""` for a private item.
///
/// Only a `pub` item can be called from a wrapper crate compiled outside the
/// scanned crate; anything else is a compile error (`E0603`), so #275 records
/// visibility rather than discovering it at build time.
pub fn visibility_string(vis: &Visibility) -> String {
    match vis {
        Visibility::Public(_) => "pub".to_string(),
        Visibility::Restricted(r) => {
            let path = &r.path;
            let rendered = quote::quote!(#path).to_string().replace(' ', "");
            if r.in_token.is_some() && rendered != "crate" && rendered != "super" {
                format!("pub(in {rendered})")
            } else {
                format!("pub({rendered})")
            }
        }
        Visibility::Inherited => String::new(),
    }
}

/// Whether `#[julia]` owns this item's C entry point.
///
/// Since #279 `#[julia]` is additive, so an item may carry both `#[julia]` and
/// `#[pyfunction]` and get a Julia wrapper *and* a Python one. When both are
/// present `#[julia]` is authoritative for the C symbol: it already emits
/// `rustcall_<name>`, so a PyO3-driven scan (#275) must skip the item rather
/// than emit a second wrapper under the same symbol.
pub fn julia_owns_entry_point(attrs: &[Attribute]) -> bool {
    attrs.iter().any(is_julia_attr)
}

/// Whether a PyO3 scan (#275) should generate a wrapper for this item: it
/// carries a PyO3 attribute and `#[julia]` has not already claimed it (see
/// [`julia_owns_entry_point`]).
pub fn pyo3_scan_selects(attrs: &[Attribute]) -> bool {
    attrs.iter().any(is_pyo3_attr) && !julia_owns_entry_point(attrs)
}

/// Which RustCall attribute marks the item, if any.
pub fn rustcall_attribute(attrs: &[Attribute]) -> ManifestAttribute {
    if attrs.iter().any(is_julia_attr) {
        ManifestAttribute::Julia
    } else if attrs.iter().any(is_julia_pyo3_attr) {
        ManifestAttribute::JuliaPyo3
    } else if derive_list(attrs).iter().any(|d| d == "JuliaStruct") {
        ManifestAttribute::DeriveJuliaStruct
    } else {
        ManifestAttribute::None
    }
}

/// All identifiers appearing in `#[derive(...)]` attributes.
pub fn derive_list(attrs: &[Attribute]) -> Vec<String> {
    let mut out = Vec::new();
    for attr in attrs {
        if !attr.path().is_ident("derive") {
            continue;
        }
        if let Meta::List(list) = &attr.meta {
            let _ = list.parse_nested_meta(|meta| {
                if let Some(id) = meta.path.get_ident() {
                    out.push(id.to_string());
                }
                Ok(())
            });
        }
    }
    out
}

/// Remove `#[julia]` / `#[julia_pyo3]` attributes.
pub fn strip_rustcall_attrs(attrs: &mut Vec<Attribute>) {
    attrs.retain(|a| !is_rustcall_attr(a));
}

/// Remove `JuliaStruct` from every `#[derive(...)]`, dropping the attribute if it
/// becomes empty. `JuliaStruct` is not a real derive macro in inline mode.
pub fn strip_julia_struct_derive(attrs: &mut Vec<Attribute>) {
    let mut rebuilt = Vec::with_capacity(attrs.len());
    for attr in attrs.drain(..) {
        if !attr.path().is_ident("derive") {
            rebuilt.push(attr);
            continue;
        }
        let Meta::List(list) = &attr.meta else {
            rebuilt.push(attr);
            continue;
        };
        let mut kept: Vec<syn::Path> = Vec::new();
        let mut saw_julia_struct = false;
        let _ = list.parse_nested_meta(|meta| {
            if meta.path.is_ident("JuliaStruct") {
                saw_julia_struct = true;
            } else {
                kept.push(meta.path.clone());
            }
            Ok(())
        });
        if !saw_julia_struct {
            rebuilt.push(attr);
        } else if !kept.is_empty() {
            rebuilt.push(syn::parse_quote!(#[derive(#(#kept),*)]));
        }
    }
    *attrs = rebuilt;
}

pub fn has_no_mangle(attrs: &[Attribute]) -> bool {
    attrs.iter().any(|a| {
        a.path().is_ident("no_mangle")
            || (a.path().is_ident("unsafe")
                && matches!(&a.meta, Meta::List(l) if l.tokens.to_string().contains("no_mangle")))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn attrs_of(source: &str) -> Vec<Attribute> {
        syn::parse_str::<syn::ItemFn>(source).unwrap().attrs
    }

    /// An item carrying both attributes is owned by `#[julia]`: it already
    /// exports `rustcall_<name>`, so the PyO3 scan of #275 must skip it rather
    /// than emit a second wrapper under the same symbol (#279).
    #[test]
    fn julia_wins_over_pyfunction() {
        let both = attrs_of("#[julia] #[pyfunction] fn f() {}");
        assert!(julia_owns_entry_point(&both));
        assert!(!pyo3_scan_selects(&both));

        let flipped = attrs_of("#[pyo3::pyfunction] #[julia] fn f() {}");
        assert!(julia_owns_entry_point(&flipped));
        assert!(!pyo3_scan_selects(&flipped));

        let pyo3_only = attrs_of("#[pyfunction] fn f() {}");
        assert!(!julia_owns_entry_point(&pyo3_only));
        assert!(pyo3_scan_selects(&pyo3_only));

        let neither = attrs_of("#[inline] fn f() {}");
        assert!(!julia_owns_entry_point(&neither));
        assert!(!pyo3_scan_selects(&neither));
    }
}
