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
