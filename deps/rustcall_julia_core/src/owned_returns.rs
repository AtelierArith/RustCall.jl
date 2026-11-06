//! Explicit owned-result mapping for concrete facade composition (#572).
use crate::{manifest::skip_reason, refusal::Refusal};
use syn::{Attribute, ReturnType, Type};

pub(crate) const ATTRIBUTE: &str = "rustcall_owned_return";

pub(crate) fn annotation(attrs: &[Attribute]) -> Result<Option<Type>, Refusal> {
    let attrs: Vec<_> = attrs
        .iter()
        .filter(|a| a.path().is_ident(ATTRIBUTE))
        .collect();
    let Some(attr) = attrs.first() else {
        return Ok(None);
    };
    if attrs.len() != 1 {
        return Err(Refusal::over(
            skip_reason::OWNED_RETURN,
            "annotation",
            attr,
            "Use exactly one rustcall_owned_return(ConcreteOwner) annotation (#572)",
        ));
    }
    let owner = attr.parse_args::<Type>().map_err(|_| {
        Refusal::over(
            skip_reason::OWNED_RETURN,
            "annotation",
            attr,
            "rustcall_owned_return requires one concrete annotated owner type (#572)",
        )
    })?;
    if !matches!(crate::types::unparen(&owner), Type::Path(p) if p.qself.is_none()) {
        return Err(Refusal::over(skip_reason::OWNED_RETURN, "owner", &owner,
            "An explicit owned return requires a concrete #[julia] owner, never a borrowed, pointer or aggregate type (#572)"));
    }
    Ok(Some(owner))
}

pub(crate) fn refusal(attrs: &[Attribute], sig: &syn::Signature) -> Option<Refusal> {
    let owner = match annotation(attrs) {
        Ok(Some(owner)) => owner,
        Ok(None) => return None,
        Err(e) => return Some(e),
    };
    let error = |detail, message| Refusal::over(skip_reason::OWNED_RETURN, detail, &owner, message);
    if sig.asyncness.is_some() || crate::types::has_type_params(&sig.generics) {
        return Some(error(
            "signature",
            "Explicit owned returns require a concrete synchronous signature (#572)",
        ));
    }
    let ReturnType::Type(_, output) = &sig.output else {
        return Some(error(
            "shape",
            "Explicit owned returns require an owner or Result<Owner, E> return (#572)",
        ));
    };
    if crate::types::extract_option_type(output).is_some() {
        return Some(error("shape", "Option<Owner> explicit owned returns are unsupported; use Owner or Result<Owner, E> (#572)"));
    }
    if let Some(r) = crate::types::extract_result_type(output) {
        if !crate::refusal::payload_is_representable(&r.err_type) {
            return Some(error("error", "An explicit owned Result requires an existing supported FFI error payload; owned error objects are unsupported (#572)"));
        }
    } else if !matches!(crate::types::unparen(output), Type::Path(_)) {
        return Some(error(
            "shape",
            "Explicit owned returns require an owner or Result<Owner, E> return (#572)",
        ));
    }
    None
}

pub(crate) fn strip(attrs: &mut Vec<Attribute>) {
    attrs.retain(|a| !a.path().is_ident(ATTRIBUTE));
}

/// Strip consumed helper attributes only when native source is finally emitted.
pub(crate) fn strip_file(file: &mut syn::File) {
    struct Strip;
    impl syn::visit_mut::VisitMut for Strip {
        fn visit_item_fn_mut(&mut self, item: &mut syn::ItemFn) {
            strip(&mut item.attrs);
            syn::visit_mut::visit_item_fn_mut(self, item);
        }
        fn visit_impl_item_fn_mut(&mut self, item: &mut syn::ImplItemFn) {
            strip(&mut item.attrs);
            syn::visit_mut::visit_impl_item_fn_mut(self, item);
        }
    }
    syn::visit_mut::VisitMut::visit_file_mut(&mut Strip, file);
}

/// Resolve only lifetime arguments here; concrete type/const generic owners
/// still require a separately declared nongeneric facade.
pub(crate) fn resolution_type(owner: &Type) -> Option<Type> {
    let Type::Path(p) = crate::types::unparen(owner) else {
        return None;
    };
    let mut p = p.clone();
    for segment in &mut p.path.segments {
        if let syn::PathArguments::AngleBracketed(args) = &segment.arguments {
            if !args
                .args
                .iter()
                .all(|a| matches!(a, syn::GenericArgument::Lifetime(_)))
            {
                return None;
            }
            segment.arguments = syn::PathArguments::None;
        } else if !segment.arguments.is_none() {
            return None;
        }
    }
    Some(Type::Path(p))
}

/// Record only a scan-proven annotated owner, never guess by a type spelling.
pub(crate) fn mark(
    attrs: &[Attribute],
    sig: &syn::Signature,
    handle: &mut String,
    reason: &mut String,
    mut resolve: impl FnMut(&Type) -> Option<String>,
) {
    let Ok(Some(owner)) = annotation(attrs) else {
        return;
    };
    if !reason.is_empty() {
        return;
    }
    let resolved = resolution_type(&owner).and_then(|ty| resolve(&ty));
    if let Some(resolved) = resolved {
        *handle = resolved;
    } else {
        *reason = format!("{}:unresolved", skip_reason::OWNED_RETURN);
        return;
    }
    if let ReturnType::Type(_, output) = &sig.output {
        if let Some(result) = crate::types::extract_result_type(output) {
            if resolution_type(&result.err_type)
                .and_then(|ty| resolve(&ty))
                .is_some()
            {
                *reason = format!("{}:error", skip_reason::OWNED_RETURN);
            }
        }
    }
}
