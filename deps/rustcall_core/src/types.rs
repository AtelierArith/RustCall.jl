//! Type-level helpers shared by extraction and code generation.

use quote::quote;
use syn::{
    GenericArgument, GenericParam, Generics, Ident, PathArguments, ReturnType, Type,
    TypeParamBound, WherePredicate,
};

use crate::manifest::{TraitBound, TypeParam};

/// Primitive types that can cross the C ABI unchanged.
pub const PRIMITIVES: &[&str] = &[
    "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "f32", "f64", "bool",
    "char", "usize", "isize",
];

/// Render a type the way a human would write it (`Vec<Option<i32>>`, `*mut Point`).
///
/// `quote!` inserts spaces between every token; `prettyplease` restores the
/// canonical spelling. Multi-line output (const expressions in array types) is
/// collapsed to a single line.
pub fn type_to_string(ty: &Type) -> String {
    let alias: syn::ItemType = syn::parse_quote!(type __RustCallT = #ty;);
    let file = syn::File {
        shebang: None,
        attrs: Vec::new(),
        items: vec![syn::Item::Type(alias)],
    };
    let printed = prettyplease::unparse(&file);
    let body = printed
        .trim()
        .strip_prefix("type __RustCallT =")
        .unwrap_or(printed.trim())
        .trim()
        .trim_end_matches(';')
        .trim();
    collapse_whitespace(body)
}

pub fn return_type_to_string(ret: &ReturnType) -> String {
    match ret {
        ReturnType::Default => "()".to_string(),
        ReturnType::Type(_, ty) => type_to_string(ty),
    }
}

fn collapse_whitespace(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut last_space = false;
    for ch in s.chars() {
        if ch.is_whitespace() {
            if !last_space {
                out.push(' ');
                last_space = true;
            }
        } else {
            out.push(ch);
            last_space = false;
        }
    }
    out
}

/// Last path segment identifier of a path type, if any.
pub fn last_ident(ty: &Type) -> Option<&Ident> {
    match ty {
        Type::Path(tp) => tp.path.segments.last().map(|s| &s.ident),
        _ => None,
    }
}

/// Whether the type is a bare single-segment path with no generic arguments
/// whose identifier equals `name` (used for type-parameter detection).
pub fn is_bare_ident(ty: &Type, name: &str) -> bool {
    match ty {
        Type::Path(tp) if tp.qself.is_none() && tp.path.segments.len() == 1 => {
            let seg = &tp.path.segments[0];
            seg.ident == name && matches!(seg.arguments, PathArguments::None)
        }
        _ => false,
    }
}

/// Check if a type is FFI-compatible (primitive types that can be passed through C ABI).
pub fn is_ffi_compatible_type(ty: &Type) -> bool {
    match ty {
        Type::Path(_) => last_ident(ty)
            .map(|id| PRIMITIVES.contains(&id.to_string().as_str()))
            .unwrap_or(false),
        Type::Tuple(tuple) if tuple.elems.is_empty() => true,
        Type::Ptr(_) => true,
        _ => false,
    }
}

/// Check if a type needs cloning for a getter (`String`, `Vec`).
pub fn needs_clone_for_getter(ty: &Type) -> bool {
    last_ident(ty)
        .map(|id| id == "String" || id == "Vec")
        .unwrap_or(false)
}

/// Check if a type is a known non-FFI-compatible type (String, Vec<T>, Box<T>, references, ...).
pub fn is_non_ffi_type(ty: &Type) -> bool {
    match ty {
        Type::Path(_) => last_ident(ty)
            .map(|id| {
                matches!(
                    id.to_string().as_str(),
                    "String"
                        | "Vec"
                        | "Box"
                        | "Rc"
                        | "Arc"
                        | "HashMap"
                        | "HashSet"
                        | "BTreeMap"
                        | "BTreeSet"
                        | "Cow"
                )
            })
            .unwrap_or(false),
        Type::Reference(_) => true,
        _ => false,
    }
}

/// Whether the inline struct wrapper generator emits accessors for a field of this type.
///
/// Mirrors the historical Julia-side rule: primitives, `String`, `Vec<..>` and raw
/// pointers are accessible; references, known non-`Copy` containers and any other
/// generic type are skipped; unknown non-generic user types are assumed accessible.
pub fn is_inline_accessible_field_type(ty: &Type) -> bool {
    match ty {
        Type::Ptr(_) => true,
        Type::Reference(_) => false,
        Type::Tuple(t) if t.elems.is_empty() => true,
        Type::Path(tp) => {
            let Some(seg) = tp.path.segments.last() else {
                return false;
            };
            let name = seg.ident.to_string();
            if PRIMITIVES.contains(&name.as_str()) || name == "String" || name == "Vec" {
                return true;
            }
            if matches!(
                name.as_str(),
                "ThreadRng"
                    | "HashMap"
                    | "HashSet"
                    | "BTreeMap"
                    | "BTreeSet"
                    | "Mutex"
                    | "RwLock"
                    | "Arc"
                    | "Rc"
                    | "Box"
                    | "RefCell"
                    | "Cell"
            ) || name.starts_with("Array")
            {
                return false;
            }
            matches!(seg.arguments, PathArguments::None)
        }
        _ => false,
    }
}

/// `String`, however it is spelled: bare, `std::string::String`,
/// `::std::string::String`, `alloc::string::String`, `core::…`.
pub fn is_string_type(ty: &Type) -> bool {
    let Type::Path(tp) = ty else { return false };
    if tp.qself.is_some() {
        return false;
    }
    let segments: Vec<String> = tp
        .path
        .segments
        .iter()
        .map(|s| s.ident.to_string())
        .collect();
    if segments.last().map(String::as_str) != Some("String") {
        return false;
    }
    if !matches!(
        tp.path.segments.last().map(|s| &s.arguments),
        Some(PathArguments::None)
    ) {
        return false;
    }
    match segments.len() {
        1 => true,
        3 => matches!(segments[0].as_str(), "std" | "alloc" | "core") && segments[1] == "string",
        _ => false,
    }
}

/// A shared `str` reference (`&str`, `&'a str`, `&std::primitive::str`).
/// `&mut str` is not an FFI string argument.
pub fn is_str_ref_type(ty: &Type) -> bool {
    match ty {
        Type::Reference(r) if r.mutability.is_none() => {
            last_ident(&r.elem).map(|id| id == "str").unwrap_or(false)
        }
        _ => false,
    }
}

pub fn is_vec_type(ty: &Type) -> bool {
    last_ident(ty).map(|id| id == "Vec").unwrap_or(false)
}

/// Check if a type is `Self` or the struct name.
pub fn is_self_type(ty: &Type, struct_name: &Ident) -> bool {
    match ty {
        Type::Path(tp) => tp
            .path
            .segments
            .last()
            .map(|s| s.ident == "Self" || s.ident == *struct_name)
            .unwrap_or(false),
        _ => false,
    }
}

/// Information about a `Result<T, E>` type.
pub struct ResultTypeInfo {
    pub ok_type: Type,
    pub err_type: Type,
}

/// Information about an `Option<T>` type.
pub struct OptionTypeInfo {
    pub inner_type: Type,
}

fn angle_args(ty: &Type, ident: &str) -> Option<Vec<Type>> {
    let Type::Path(tp) = ty else { return None };
    let seg = tp.path.segments.last()?;
    if seg.ident != ident {
        return None;
    }
    let PathArguments::AngleBracketed(args) = &seg.arguments else {
        return None;
    };
    Some(
        args.args
            .iter()
            .filter_map(|a| match a {
                GenericArgument::Type(t) => Some(t.clone()),
                _ => None,
            })
            .collect(),
    )
}

pub fn extract_result_type(ty: &Type) -> Option<ResultTypeInfo> {
    let args = angle_args(ty, "Result")?;
    let mut it = args.into_iter();
    let ok_type = it.next()?;
    let err_type = it.next()?;
    Some(ResultTypeInfo { ok_type, err_type })
}

pub fn extract_option_type(ty: &Type) -> Option<OptionTypeInfo> {
    let args = angle_args(ty, "Option")?;
    let inner_type = args.into_iter().next()?;
    Some(OptionTypeInfo { inner_type })
}

/// Convert generics (inline bounds plus `where` clause) into manifest type parameters.
/// Lifetime and const parameters are not reported.
pub fn generics_to_type_params(generics: &Generics) -> Vec<TypeParam> {
    let mut params: Vec<TypeParam> = generics
        .params
        .iter()
        .filter_map(|p| match p {
            GenericParam::Type(tp) => Some(TypeParam {
                name: tp.ident.to_string(),
                bounds: tp.bounds.iter().filter_map(bound_to_manifest).collect(),
            }),
            _ => None,
        })
        .collect();

    if let Some(wc) = &generics.where_clause {
        for pred in &wc.predicates {
            if let WherePredicate::Type(pt) = pred {
                if let Type::Path(tp) = &pt.bounded_ty {
                    if tp.path.segments.len() == 1 {
                        let name = tp.path.segments[0].ident.to_string();
                        if let Some(param) = params.iter_mut().find(|p| p.name == name) {
                            param
                                .bounds
                                .extend(pt.bounds.iter().filter_map(bound_to_manifest));
                        }
                    }
                }
            }
        }
    }
    params
}

fn bound_to_manifest(b: &TypeParamBound) -> Option<TraitBound> {
    let TypeParamBound::Trait(tb) = b else {
        return None;
    };
    let seg = tb.path.segments.last()?;
    let type_params = match &seg.arguments {
        PathArguments::AngleBracketed(args) => args
            .args
            .iter()
            .map(|a| {
                let tokens = quote!(#a);
                collapse_whitespace(&tokens.to_string())
                    .replace(" < ", "<")
                    .replace(" >", ">")
            })
            .collect(),
        _ => Vec::new(),
    };
    Some(TraitBound {
        trait_name: seg.ident.to_string(),
        type_params,
    })
}

/// Whether the item is generic over types or consts. Lifetimes alone do not
/// prevent a function from being exported through the C ABI.
pub fn has_type_params(generics: &Generics) -> bool {
    generics
        .params
        .iter()
        .any(|p| matches!(p, GenericParam::Type(_) | GenericParam::Const(_)))
}

/// Whether the signature uses `impl Trait` anywhere in its arguments or return
/// type. Such functions are generic for rustc (`#[no_mangle]` exports nothing)
/// and have no parameter Julia could bind.
pub fn has_impl_trait(sig: &syn::Signature) -> bool {
    struct Finder(bool);
    impl<'ast> syn::visit::Visit<'ast> for Finder {
        fn visit_type_impl_trait(&mut self, _: &'ast syn::TypeImplTrait) {
            self.0 = true;
        }
    }
    let mut f = Finder(false);
    for input in &sig.inputs {
        syn::visit::Visit::visit_fn_arg(&mut f, input);
    }
    syn::visit::Visit::visit_return_type(&mut f, &sig.output);
    f.0
}

/// Names of const generic parameters (`const N: usize` -> `N`).
pub fn const_param_names(generics: &Generics) -> Vec<String> {
    generics
        .params
        .iter()
        .filter_map(|p| match p {
            GenericParam::Const(c) => Some(c.ident.to_string()),
            _ => None,
        })
        .collect()
}
