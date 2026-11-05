//! Finite, signature-aware numeric slice ABI (#570).
use syn::{GenericArgument, PathArguments, Type};

/// Recognize representations whose initialized bits are valid Rust elements.
/// bool, char, user aliases, nested slices and arbitrary repr(C) types are excluded.
pub(crate) fn shape(ty: &Type) -> Option<(bool, &Type, &'static str)> {
    let Type::Reference(r) = crate::types::unparen(ty) else {
        return None;
    };
    let Type::Slice(slice) = crate::types::unparen(&r.elem) else {
        return None;
    };
    let Type::Path(p) = crate::types::unparen(&slice.elem) else {
        return None;
    };
    if p.qself.is_some() {
        return None;
    }
    let parts: Vec<_> = p.path.segments.iter().collect();
    let scalar = |name: &str| match name {
        "f32" => Some("f32"),
        "f64" => Some("f64"),
        "i8" => Some("i8"),
        "u8" => Some("u8"),
        "i16" => Some("i16"),
        "u16" => Some("u16"),
        "i32" => Some("i32"),
        "u32" => Some("u32"),
        "i64" => Some("i64"),
        "u64" => Some("u64"),
        "isize" => Some("isize"),
        "usize" => Some("usize"),
        _ => None,
    };
    let element = if parts.len() == 1 && parts[0].arguments.is_none() {
        scalar(&parts[0].ident.to_string())?
    } else if parts.len() == 3
        && parts[0].ident == "core"
        && parts[1].ident == "primitive"
        && parts.iter().all(|s| s.arguments.is_none())
    {
        scalar(&parts[2].ident.to_string())?
    } else if parts.len() == 2 && parts[0].ident == "num_complex" && parts[0].arguments.is_none() {
        let last = parts[1];
        match (last.ident.to_string().as_str(), &last.arguments) {
            ("Complex32", PathArguments::None) => "complex32",
            ("Complex64", PathArguments::None) => "complex64",
            ("Complex", PathArguments::AngleBracketed(a)) if a.args.len() == 1 => {
                let Some(GenericArgument::Type(Type::Path(t))) = a.args.first() else {
                    return None;
                };
                if t.qself.is_some()
                    || t.path.segments.len() != 1
                    || !t.path.segments[0].arguments.is_none()
                {
                    return None;
                }
                match t.path.segments[0].ident.to_string().as_str() {
                    "f32" => "complex32",
                    "f64" => "complex64",
                    _ => return None,
                }
            }
            _ => return None,
        }
    } else {
        return None;
    };
    Some((r.mutability.is_some(), &slice.elem, element))
}

pub(crate) fn is_slice(ty: &Type) -> bool {
    matches!(crate::types::unparen(ty), Type::Reference(r)
        if matches!(crate::types::unparen(&r.elem), Type::Slice(_)))
}
