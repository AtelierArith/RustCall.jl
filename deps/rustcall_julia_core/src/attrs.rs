//! Attribute inspection helpers (`#[julia]`, `#[derive(JuliaStruct)]`, and the
//! PyO3 entry-point attributes scanned by #275).

use syn::parse::{Parse, ParseStream};
use syn::punctuated::Punctuated;
use syn::{parenthesized, Attribute, Expr, Ident, Lit, Meta, Token, Visibility};

use crate::manifest::Attribute as ManifestAttribute;

pub fn is_julia_attr(attr: &Attribute) -> bool {
    attr.path().is_ident("julia")
}

pub fn is_rustcall_attr(attr: &Attribute) -> bool {
    is_julia_attr(attr)
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

/// The path of a meta written as `pyo3`-qualified or bare: `#[pyfunction]` and
/// `#[pyo3::pyfunction]` both yield `Some("pyfunction")`, while a `#[foo::pyfunction]`
/// from an unrelated crate yields `None`.
fn pyo3_path_name(meta: &Meta) -> Option<String> {
    let segments = &meta.path().segments;
    let last = segments.last()?.ident.to_string();
    match segments.len() {
        1 => Some(last),
        _ if segments[0].ident == "pyo3" => Some(last),
        _ => None,
    }
}

/// Every attribute of an item as a [`Meta`], with the *conditional* attributes
/// of a `#[cfg_attr(predicate, a, b)]` flattened in alongside it.
///
/// A crate that makes pyo3 optional writes its markers that way
/// (`#[cfg_attr(feature = "python", pyfunction)]`), and the crate scan runs
/// with lenient `cfg` evaluation — a `feature` predicate is deliberately left
/// undecided, so the `cfg_attr` is still there when the scan looks. Reading
/// only the outer attribute would make exactly the crates on the
/// `:python_free` path (#275 Phase 1.5) invisible to the scan.
///
/// The predicate itself (the first element) is dropped: it is a `cfg`
/// predicate, not an attribute. Nesting is followed to any depth.
pub fn effective_metas(attrs: &[Attribute]) -> Vec<Meta> {
    let mut out = Vec::with_capacity(attrs.len());
    for attr in attrs {
        push_effective_meta(attr.meta.clone(), &mut out);
    }
    out
}

fn push_effective_meta(meta: Meta, out: &mut Vec<Meta>) {
    if meta.path().is_ident("cfg_attr") {
        if let Meta::List(list) = &meta {
            if let Ok(items) = list.parse_args_with(Punctuated::<Meta, Token![,]>::parse_terminated)
            {
                for inner in items.into_iter().skip(1) {
                    push_effective_meta(inner, out);
                }
            }
        }
        // A `cfg_attr` is never itself a marker, so it is not pushed.
        return;
    }
    out.push(meta);
}

/// Which PyO3 entry-point attribute marks the item, if any. Both the bare and
/// the `pyo3::`-qualified spelling are recognised, and a marker nested in a
/// `#[cfg_attr(...)]` counts (see [`effective_metas`]).
pub fn pyo3_marker(attrs: &[Attribute]) -> Option<Pyo3Marker> {
    effective_metas(attrs)
        .iter()
        .find_map(|m| match pyo3_path_name(m)?.as_str() {
            "pyfunction" => Some(Pyo3Marker::Function),
            "pyclass" => Some(Pyo3Marker::Class),
            "pymethods" => Some(Pyo3Marker::Methods),
            "pymodule" => Some(Pyo3Marker::Module),
            _ => None,
        })
}

/// Whether the item carries a PyO3 entry-point attribute (`#[pyfunction]`,
/// `#[pyo3::pyfunction]`, `#[pymethods]`, `#[pyclass]`, `#[pymodule]`),
/// directly or through a `#[cfg_attr(...)]`.
pub fn has_pyo3_attr(attrs: &[Attribute]) -> bool {
    pyo3_marker(attrs).is_some()
}

/// The PyO3 method attributes carried by an `impl` item, in source order.
pub fn pyo3_method_markers(attrs: &[Attribute]) -> Vec<Pyo3MethodMarker> {
    effective_metas(attrs)
        .iter()
        .filter_map(|m| match pyo3_path_name(m)?.as_str() {
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
    for meta in effective_metas(attrs) {
        let Some(name) = pyo3_path_name(&meta) else {
            continue;
        };
        match name.as_str() {
            "pyo3" | "pyfunction" | "pyclass" | "pymodule" => {
                if let Some(value) = nested_name_value(&meta) {
                    return value;
                }
            }
            "getter" | "setter" => {
                // `#[getter(python_name)]` / `#[getter(name = "python_name")]`.
                if let Some(value) = nested_name_value(&meta) {
                    return value;
                }
                if let Meta::List(list) = &meta {
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
fn nested_name_value(meta: &Meta) -> Option<String> {
    let Meta::List(list) = meta else {
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

/// Class-level options of `#[pyclass(...)]` that decide field exposure.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Pyo3ClassOptions {
    /// `get_all`: every field gets a getter, without a per-field attribute.
    pub get_all: bool,
    /// `set_all`: every field gets a setter.
    pub set_all: bool,
    /// `frozen`: the class is immutable from Python, so no setters at all —
    /// it overrides `set_all` and a field's own `set`.
    pub frozen: bool,
    /// Rust base type named by `extends = ...`, preserving its path spelling.
    pub extends: String,
    /// The remaining options which change the Python object layout or type.
    pub subclass: bool,
    pub dict: bool,
    pub weakref: bool,
}

/// Read the class-shape options of `#[pyclass(...)]`.
///
/// `get_all` / `set_all` expose fields *without* a per-field `#[pyo3(get, set)]`,
/// so a scan that only looked at field attributes would drop them — including
/// for the dual-binding shape `docs/src/pyo3.md` recommends (`#[julia]`
/// stacked with `#[pyclass(get_all, set_all)]`).
pub fn pyo3_class_options(attrs: &[Attribute]) -> Pyo3ClassOptions {
    let mut options = Pyo3ClassOptions::default();
    for meta in effective_metas(attrs) {
        if pyo3_path_name(&meta).as_deref() != Some("pyclass") {
            continue;
        }
        let Meta::List(list) = &meta else { continue };
        let _ = list.parse_nested_meta(|nested| {
            if nested.path.is_ident("get_all") {
                options.get_all = true;
            } else if nested.path.is_ident("set_all") {
                options.set_all = true;
            } else if nested.path.is_ident("frozen") {
                options.frozen = true;
            } else if nested.path.is_ident("extends") {
                if let Ok(value) = nested.value() {
                    if let Ok(path) = value.parse::<syn::Path>() {
                        options.extends = quote::quote!(#path).to_string().replace(' ', "");
                    }
                }
            } else if nested.path.is_ident("subclass") {
                options.subclass = true;
            } else if nested.path.is_ident("dict") {
                options.dict = true;
            } else if nested.path.is_ident("weakref") {
                options.weakref = true;
            }
            Ok(())
        });
    }
    options
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pyo3ParameterKind {
    PositionalOnly,
    PositionalOrKeyword,
    KeywordOnly,
    VarArgs,
    KwArgs,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pyo3Parameter {
    pub name: String,
    pub default: String,
    pub kind: Pyo3ParameterKind,
}

#[derive(Default)]
struct ParsedPyo3Signature {
    parameters: Vec<Pyo3Parameter>,
}

impl Parse for ParsedPyo3Signature {
    fn parse(input: ParseStream<'_>) -> syn::Result<Self> {
        let mut parameters: Vec<Pyo3Parameter> = Vec::new();
        let mut keyword_only = false;
        while !input.is_empty() {
            if input.peek(Token![/]) {
                input.parse::<Token![/]>()?;
                for parameter in &mut parameters {
                    if parameter.kind == Pyo3ParameterKind::PositionalOrKeyword {
                        parameter.kind = Pyo3ParameterKind::PositionalOnly;
                    }
                }
            } else if input.peek(Token![*]) {
                input.parse::<Token![*]>()?;
                if input.peek(Token![*]) {
                    input.parse::<Token![*]>()?;
                    let name: Ident = input.parse()?;
                    parameters.push(Pyo3Parameter {
                        name: name.to_string(),
                        default: String::new(),
                        kind: Pyo3ParameterKind::KwArgs,
                    });
                } else if input.peek(Ident) {
                    let name: Ident = input.parse()?;
                    parameters.push(Pyo3Parameter {
                        name: name.to_string(),
                        default: String::new(),
                        kind: Pyo3ParameterKind::VarArgs,
                    });
                    keyword_only = true;
                } else {
                    keyword_only = true;
                }
            } else {
                let name: Ident = input.parse()?;
                let default = if input.peek(Token![=]) {
                    input.parse::<Token![=]>()?;
                    let expr: Expr = input.parse()?;
                    quote::quote!(#expr).to_string()
                } else {
                    String::new()
                };
                parameters.push(Pyo3Parameter {
                    name: name.to_string(),
                    default,
                    kind: if keyword_only {
                        Pyo3ParameterKind::KeywordOnly
                    } else {
                        Pyo3ParameterKind::PositionalOrKeyword
                    },
                });
            }
            if input.peek(Token![,]) {
                input.parse::<Token![,]>()?;
            } else if !input.is_empty() {
                return Err(input.error("expected `,` in PyO3 signature"));
            }
        }
        Ok(Self { parameters })
    }
}

/// Structured Python call signature from `#[pyo3(signature = (...))]`, the
/// equivalent option nested in `#[pyfunction(...)]`, or legacy `#[args(...)]`.
pub fn pyo3_signature(attrs: &[Attribute]) -> syn::Result<Option<Vec<Pyo3Parameter>>> {
    for meta in effective_metas(attrs) {
        let Some(name) = pyo3_path_name(&meta) else {
            continue;
        };
        if name == "args" {
            if let Meta::List(list) = meta {
                return syn::parse2::<ParsedPyo3Signature>(list.tokens)
                    .map(|signature| Some(signature.parameters));
            }
        }
        if !matches!(name.as_str(), "pyo3" | "pyfunction") {
            continue;
        }
        let Meta::List(list) = meta else { continue };
        let mut found = None;
        list.parse_nested_meta(|nested| {
            if nested.path.is_ident("signature") {
                let value = nested.value()?;
                let content;
                parenthesized!(content in value);
                found = Some(content.parse::<ParsedPyo3Signature>()?.parameters);
            } else if nested.input.peek(Token![=]) {
                let value = nested.value()?;
                let _: Expr = value.parse()?;
            } else if nested.input.peek(syn::token::Paren) {
                let content;
                parenthesized!(content in nested.input);
                let _: proc_macro2::TokenStream = content.parse()?;
            }
            Ok(())
        })?;
        if found.is_some() {
            return Ok(found);
        }
    }
    Ok(None)
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
    for meta in effective_metas(attrs) {
        if pyo3_path_name(&meta).as_deref() != Some("pyo3") {
            continue;
        }
        let Meta::List(list) = &meta else {
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
    has_pyo3_attr(attrs) && !julia_owns_entry_point(attrs)
}

/// Which RustCall attribute marks the item, if any.
pub fn rustcall_attribute(attrs: &[Attribute]) -> ManifestAttribute {
    if attrs.iter().any(is_julia_attr) {
        ManifestAttribute::Julia
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

/// Remove `#[julia]` attributes.
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

    #[test]
    fn pyclass_object_shape_options_are_structured() {
        let item: syn::ItemStruct = syn::parse_str(
            "#[pyclass(extends = crate::base::Base, subclass, dict, weakref, get_all, frozen)] struct Child {}",
        )
        .unwrap();
        let options = pyo3_class_options(&item.attrs);
        assert_eq!(options.extends, "crate::base::Base");
        assert!(options.subclass);
        assert!(options.dict);
        assert!(options.weakref);
        assert!(options.get_all);
        assert!(options.frozen);
        assert!(!options.set_all);
    }

    #[test]
    fn pyo3_call_signatures_preserve_defaults_and_parameter_kinds() {
        let attrs = attrs_of(
            "#[pyfunction(signature = (a, b = private_default(), /, c = 3, *, d = Some(4)))] fn f(a:i32,b:i32,c:i32,d:Option<i32>) {}",
        );
        let parameters = pyo3_signature(&attrs).unwrap().unwrap();
        assert_eq!(parameters.len(), 4);
        assert_eq!(parameters[0].kind, Pyo3ParameterKind::PositionalOnly);
        assert_eq!(parameters[1].default.replace(' ', ""), "private_default()");
        assert_eq!(parameters[2].kind, Pyo3ParameterKind::PositionalOrKeyword);
        assert_eq!(parameters[3].kind, Pyo3ParameterKind::KeywordOnly);
        assert_eq!(parameters[3].default.replace(' ', ""), "Some(4)");

        let attrs = attrs_of("#[pyo3(signature = (*args, **kwargs))] fn f() {}");
        let parameters = pyo3_signature(&attrs).unwrap().unwrap();
        assert_eq!(parameters[0].kind, Pyo3ParameterKind::VarArgs);
        assert_eq!(parameters[1].kind, Pyo3ParameterKind::KwArgs);

        let attrs = attrs_of(
            "#[pyfunction(name = \"renamed\", signature = (value = 1), text_signature = \"(value=1)\")] fn f(value:i32) {}",
        );
        let parameters = pyo3_signature(&attrs).unwrap().unwrap();
        assert_eq!(parameters[0].name, "value");
        assert_eq!(parameters[0].default, "1");
    }
}
