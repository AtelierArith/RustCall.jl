//! Explicit nullable-pointer optional borrowed-owner ABI (#571).
use syn::{GenericArgument, PathArguments, Type, TypeReference};

pub(crate) fn is_option(ty: &Type) -> bool {
    matches!(crate::types::unparen(ty), Type::Path(p)
        if p.qself.is_none() && p.path.segments.last().is_some_and(|s| s.ident == "Option"))
}

pub(crate) fn inner(ty: &Type) -> Option<&Type> {
    let Type::Path(p) = crate::types::unparen(ty) else {
        return None;
    };
    if p.qself.is_some() {
        return None;
    }
    let last = p.path.segments.last()?;
    if last.ident != "Option" {
        return None;
    }
    let PathArguments::AngleBracketed(a) = &last.arguments else {
        return None;
    };
    if a.args.len() != 1 {
        return None;
    }
    match a.args.first()? {
        GenericArgument::Type(t) => Some(t),
        _ => None,
    }
}

/// The canonical scalar representation of an `Option<T>` whose `T` is a
/// primitive, or `None` for every other `Option` (an optional borrowed owner,
/// an owned string, a slice, or an unsupported type). The wrapper lowers such
/// an argument to two C slots: an `i32` presence tag and the value.
pub(crate) fn scalar_element(ty: &Type) -> Option<&'static str> {
    let Type::Path(p) = crate::types::unparen(inner(ty)?) else {
        return None;
    };
    if p.qself.is_some() || p.path.leading_colon.is_some() || p.path.segments.len() != 1 {
        return None;
    }
    let segment = p.path.segments.first()?;
    if !segment.arguments.is_none() {
        return None;
    }
    match segment.ident.to_string().as_str() {
        "bool" => Some("bool"),
        "f32" => Some("f32"),
        "f64" => Some("f64"),
        "i8" => Some("i8"),
        "i16" => Some("i16"),
        "i32" => Some("i32"),
        "i64" => Some("i64"),
        "u8" => Some("u8"),
        "u16" => Some("u16"),
        "u32" => Some("u32"),
        "u64" => Some("u64"),
        "isize" => Some("isize"),
        "usize" => Some("usize"),
        _ => None,
    }
}

pub(crate) fn reference(ty: &Type) -> Option<&TypeReference> {
    match crate::types::unparen(inner(ty)?) {
        Type::Reference(r) => Some(r),
        _ => None,
    }
}

pub(crate) fn pointee(ty: &Type) -> Option<(bool, &Type)> {
    let r = reference(ty)?;
    let Type::Path(p) = crate::types::unparen(&r.elem) else {
        return None;
    };
    if p.qself.is_some()
        || p.path.segments.iter().any(|s| !s.arguments.is_none())
        || p.path.is_ident("str")
    {
        return None;
    }
    Some((r.mutability.is_some(), &r.elem))
}

// Lowering erases this reference's lifetime from the wrapper signature. The
// local annotation retains the original Option spelling for compiler-checked
// identity against core::option::Option, with a fresh call-local borrow.
pub(crate) fn local_annotation(ty: &Type) -> Type {
    let mut annotation = crate::types::unparen(ty).clone();
    let Type::Path(p) = &mut annotation else {
        unreachable!()
    };
    let PathArguments::AngleBracketed(a) = &mut p.path.segments.last_mut().unwrap().arguments
    else {
        unreachable!()
    };
    let GenericArgument::Type(inner) = a.args.first_mut().unwrap() else {
        unreachable!()
    };
    let mut reference = reference(ty).unwrap().clone();
    reference.lifetime = None;
    *inner = Type::Reference(reference);
    annotation
}
