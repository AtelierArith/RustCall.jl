//! Attribute inspection helpers (`#[julia]`, `#[julia_pyo3]`, `#[derive(JuliaStruct)]`).

use syn::{Attribute, Meta};

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

/// Whether the item carries a PyO3 entry-point attribute (`#[pyfunction]`,
/// `#[pyo3::pyfunction]`, `#[pymethods]`, `#[pyclass]`, ...).
pub fn is_pyo3_attr(attr: &Attribute) -> bool {
    attr.path()
        .segments
        .last()
        .map(|s| {
            let name = s.ident.to_string();
            matches!(
                name.as_str(),
                "pyfunction" | "pymethods" | "pyclass" | "pymodule"
            )
        })
        .unwrap_or(false)
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
