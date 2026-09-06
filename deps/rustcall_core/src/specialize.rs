//! AST-level generic instantiation.
//!
//! Given a source file, the name of a generic free function in it, and a set of
//! `TypeParam = concrete type` bindings, produce a copy of the file with a
//! `#[no_mangle] pub extern "C"` instantiation inserted right after the
//! generic function, with the type parameters substituted by the concrete
//! types. The generic original and every other item are kept unchanged, so
//! struct definitions, impl blocks and other callers of the generic function
//! keep compiling.
//!
//! This replaces the historical Julia-side regex substitution
//! (`specialize_generic_code`).

use std::collections::HashMap;

use syn::visit_mut::{self, VisitMut};
use syn::{GenericParam, Item, ItemFn, Path, PathArguments, Type, WherePredicate};

use crate::cfg::body_has_cfg;
use crate::codegen::{function_symbol, plain_function_wrapper};
use crate::manifest::{Arg, Attribute, Function, Manifest, Mode, ReturnKind};
use crate::types::{return_type_to_string, type_to_string};

#[derive(Debug)]
pub enum SpecializeError {
    Parse(String),
    FunctionNotFound(String),
    InvalidType {
        param: String,
        ty: String,
        err: String,
    },
    UnboundParams(Vec<String>),
    InvalidName(String),
}

impl std::fmt::Display for SpecializeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SpecializeError::Parse(e) => write!(f, "failed to parse Rust source: {e}"),
            SpecializeError::FunctionNotFound(n) => {
                write!(
                    f,
                    "generic function `{n}` not found at top level of the source"
                )
            }
            SpecializeError::InvalidType { param, ty, err } => {
                write!(
                    f,
                    "invalid concrete type `{ty}` for parameter `{param}`: {err}"
                )
            }
            SpecializeError::UnboundParams(ps) => {
                write!(f, "type parameters without a binding: {}", ps.join(", "))
            }
            SpecializeError::InvalidName(n) => write!(f, "`{n}` is not a valid Rust identifier"),
        }
    }
}

impl std::error::Error for SpecializeError {}

struct TypeSubst {
    map: HashMap<String, Type>,
}

impl TypeSubst {
    fn concrete_path(&self, name: &str) -> Option<&Path> {
        match self.map.get(name) {
            Some(Type::Path(tp)) if tp.qself.is_none() => Some(&tp.path),
            _ => None,
        }
    }
}

impl TypeSubst {
    fn substitute_tokens(&self, tokens: proc_macro2::TokenStream) -> proc_macro2::TokenStream {
        use proc_macro2::{Group, TokenTree};
        let mut out: Vec<TokenTree> = Vec::new();
        let mut after_dollar = false;
        for tt in tokens {
            match tt {
                // `$T` inside a `macro_rules!` definition is a metavariable, not a type.
                TokenTree::Ident(ref id) if !after_dollar => match self.map.get(&id.to_string()) {
                    Some(ty) => out.extend(quote::quote!(#ty)),
                    None => out.push(tt),
                },
                TokenTree::Group(g) => {
                    let mut ng = Group::new(g.delimiter(), self.substitute_tokens(g.stream()));
                    ng.set_span(g.span());
                    out.push(TokenTree::Group(ng));
                }
                other => out.push(other),
            }
            after_dollar = matches!(out.last(), Some(TokenTree::Punct(p)) if p.as_char() == '$');
        }
        out.into_iter().collect()
    }

    /// Type parameters declared by an item that shadow outer bindings.
    fn shadowed_by(&self, generics: &syn::Generics) -> Vec<(String, Type)> {
        generics
            .params
            .iter()
            .filter_map(|p| match p {
                GenericParam::Type(tp) => {
                    let name = tp.ident.to_string();
                    self.map.get(&name).map(|t| (name, t.clone()))
                }
                _ => None,
            })
            .collect()
    }

    fn with_shadowed<F: FnOnce(&mut Self)>(&mut self, generics: &syn::Generics, f: F) {
        let shadowed = self.shadowed_by(generics);
        for (name, _) in &shadowed {
            self.map.remove(name);
        }
        f(self);
        for (name, ty) in shadowed {
            self.map.insert(name, ty);
        }
    }
}

fn item_generics(item: &Item) -> Option<syn::Generics> {
    match item {
        Item::Fn(f) => Some(f.sig.generics.clone()),
        Item::Impl(i) => Some(i.generics.clone()),
        Item::Struct(s) => Some(s.generics.clone()),
        Item::Enum(e) => Some(e.generics.clone()),
        Item::Union(u) => Some(u.generics.clone()),
        Item::Trait(t) => Some(t.generics.clone()),
        Item::Type(t) => Some(t.generics.clone()),
        _ => None,
    }
}

impl VisitMut for TypeSubst {
    /// Nested items (`fn inner<T>` inside the body, local structs, impls) may
    /// redeclare an outer type parameter; their `T` is a different binding and
    /// must not be substituted.
    fn visit_item_mut(&mut self, item: &mut Item) {
        match item_generics(item) {
            Some(g) => self.with_shadowed(&g, |s| visit_mut::visit_item_mut(s, item)),
            None => visit_mut::visit_item_mut(self, item),
        }
    }

    fn visit_impl_item_fn_mut(&mut self, node: &mut syn::ImplItemFn) {
        let g = node.sig.generics.clone();
        self.with_shadowed(&g, |s| visit_mut::visit_impl_item_fn_mut(s, node));
    }

    fn visit_trait_item_fn_mut(&mut self, node: &mut syn::TraitItemFn) {
        let g = node.sig.generics.clone();
        self.with_shadowed(&g, |s| visit_mut::visit_trait_item_fn_mut(s, node));
    }

    /// Macro bodies are opaque token streams; rewrite bound identifiers there
    /// too (`assert_eq!(x, T::default())`).
    fn visit_macro_mut(&mut self, mac: &mut syn::Macro) {
        mac.tokens = self.substitute_tokens(mac.tokens.clone());
    }

    fn visit_type_mut(&mut self, ty: &mut Type) {
        if let Type::Path(tp) = ty {
            if tp.qself.is_none() && tp.path.segments.len() == 1 {
                let seg = &tp.path.segments[0];
                if matches!(seg.arguments, PathArguments::None) {
                    if let Some(concrete) = self.map.get(&seg.ident.to_string()) {
                        *ty = concrete.clone();
                        return;
                    }
                }
            }
        }
        visit_mut::visit_type_mut(self, ty);
    }

    /// Handle expression paths such as `T::default()` or `T::MAX`.
    fn visit_path_mut(&mut self, path: &mut Path) {
        if path.segments.len() > 1 {
            let first = path.segments[0].ident.to_string();
            if let Some(concrete) = self.concrete_path(&first) {
                if matches!(path.segments[0].arguments, PathArguments::None) {
                    let rest: Vec<_> = path.segments.iter().skip(1).cloned().collect();
                    let mut segs = concrete.segments.clone();
                    segs.extend(rest);
                    path.segments = segs;
                }
            }
        }
        visit_mut::visit_path_mut(self, path);
    }
}

/// Result of a specialization.
#[derive(Debug)]
pub struct Specialized {
    /// Full source: original items plus the specialized function.
    pub source: String,
    /// Manifest describing only the specialized function.
    pub manifest: Manifest,
}

pub fn specialize(
    source: &str,
    fn_name: &str,
    bindings: &[(String, String)],
    new_name: &str,
) -> Result<Specialized, SpecializeError> {
    let mut file: syn::File =
        syn::parse_file(source).map_err(|e| SpecializeError::Parse(e.to_string()))?;

    // `fn_name` may be qualified with the enclosing inline modules
    // (`api::deep::f`); the function is replaced where it lives so sibling
    // items, `use` imports and `super::` paths keep resolving.
    let segments: Vec<&str> = fn_name.split("::").collect();
    let (module_path, bare_name) = segments.split_at(segments.len() - 1);
    let bare_name = bare_name[0];
    let items = locate_items(&mut file.items, module_path)
        .ok_or_else(|| SpecializeError::FunctionNotFound(fn_name.to_string()))?;
    let position = items
        .iter()
        .position(|item| matches!(item, Item::Fn(f) if f.sig.ident == bare_name))
        .ok_or_else(|| SpecializeError::FunctionNotFound(fn_name.to_string()))?;
    let original = match &items[position] {
        Item::Fn(f) => f.clone(),
        _ => unreachable!(),
    };

    let mut map = HashMap::new();
    for (param, ty) in bindings {
        let parsed: Type = syn::parse_str(ty).map_err(|e| SpecializeError::InvalidType {
            param: param.clone(),
            ty: ty.clone(),
            err: e.to_string(),
        })?;
        map.insert(param.clone(), parsed);
    }

    let new_ident: syn::Ident =
        syn::parse_str(new_name).map_err(|_| SpecializeError::InvalidName(new_name.to_string()))?;
    let mut func = original;
    func.sig.ident = new_ident;

    // Drop the bound type parameters from the generics list.
    let mut unbound = Vec::new();
    let remaining: Vec<GenericParam> = func
        .sig
        .generics
        .params
        .iter()
        .filter(|p| match p {
            GenericParam::Type(tp) => {
                let bound = map.contains_key(&tp.ident.to_string());
                if !bound {
                    unbound.push(tp.ident.to_string());
                }
                !bound
            }
            _ => true,
        })
        .cloned()
        .collect();
    // Const parameters have no binding mechanism; a `#[no_mangle]` function that
    // is still generic exports no symbol, so refuse instead of silently
    // producing an unusable library.
    unbound.extend(crate::types::const_param_names(&func.sig.generics));
    if !unbound.is_empty() {
        return Err(SpecializeError::UnboundParams(unbound));
    }
    func.sig.generics.params = remaining.into_iter().collect();
    if let Some(wc) = func.sig.generics.where_clause.take() {
        let kept: Vec<WherePredicate> = wc
            .predicates
            .into_iter()
            .filter(|p| match p {
                WherePredicate::Type(pt) => match &pt.bounded_ty {
                    Type::Path(tp) if tp.path.segments.len() == 1 => {
                        !map.contains_key(&tp.path.segments[0].ident.to_string())
                    }
                    _ => true,
                },
                _ => true,
            })
            .collect();
        if !kept.is_empty() {
            func.sig.generics.where_clause = Some(syn::WhereClause {
                where_token: wc.where_token,
                predicates: kept.into_iter().collect(),
            });
        }
    }
    if func.sig.generics.params.is_empty() {
        func.sig.generics.lt_token = None;
        func.sig.generics.gt_token = None;
    }

    let mut subst = TypeSubst { map };
    subst.visit_item_fn_mut(&mut func);

    func.attrs
        .retain(|a| !a.path().is_ident("no_mangle") && !a.path().is_ident("julia"));

    let mut entry = function_entry(&func);
    entry.module_path = module_path.iter().map(|s| s.to_string()).collect();

    // The instantiation is emitted the same way `#[julia]` emits a function
    // (#279): the plain Rust function under `new_name`, and the `extern "C"`
    // entry point next to it under `rustcall_<new_name>`. Fixed `String` /
    // `&str` parameters or returns get the `(ptr, len)` ABI (#242); the
    // manifest records the helpers so the caller uses the string ABI.
    entry.return_abi = crate::codegen::return_abi(&func.sig).to_string();
    entry.has_owned_string_helper = entry.return_abi == "string";
    entry.has_borrowed_string_helper = entry.return_abi == "str";
    let new_items: Vec<Item> = {
        func.vis = syn::Visibility::Public(Default::default());
        let wrapper: syn::File = syn::parse2(plain_function_wrapper(&func))
            .map_err(|e| SpecializeError::Parse(e.to_string()))?;
        let mut items = vec![Item::Fn(func)];
        items.extend(wrapper.items);
        items
    };
    let items = locate_items(&mut file.items, module_path).expect("module path resolved above");
    for (offset, item) in new_items.into_iter().enumerate() {
        items.insert(position + 1 + offset, item);
    }

    let mut manifest = Manifest::new(Mode::Inline);
    manifest.functions.push(entry);

    Ok(Specialized {
        source: prettyplease::unparse(&file),
        manifest,
    })
}

/// Item list of the inline module chain `path` (empty path = file root).
fn locate_items<'a>(items: &'a mut Vec<Item>, path: &[&str]) -> Option<&'a mut Vec<Item>> {
    let Some((head, rest)) = path.split_first() else {
        return Some(items);
    };
    for item in items.iter_mut() {
        if let Item::Mod(m) = item {
            if m.ident == head {
                if let Some((_, inner)) = &mut m.content {
                    return locate_items(inner, rest);
                }
            }
        }
    }
    None
}

fn function_entry(func: &ItemFn) -> Function {
    let args = func
        .sig
        .inputs
        .iter()
        .filter_map(|a| match a {
            syn::FnArg::Typed(pt) => Some(Arg {
                name: match pt.pat.as_ref() {
                    syn::Pat::Ident(pi) => pi.ident.to_string(),
                    other => quote::quote!(#other).to_string(),
                },
                rust_type: type_to_string(&pt.ty),
                abi: crate::extract::arg_abi(&pt.ty).to_string(),
            }),
            syn::FnArg::Receiver(_) => None,
        })
        .collect();
    let return_type = return_type_to_string(&func.sig.output);
    Function {
        cfg: crate::cfg::predicate_string(&func.attrs),
        name: func.sig.ident.to_string(),
        // The exported entry point is the additive wrapper, not the
        // instantiation itself (#279).
        symbol: function_symbol(&func.sig.ident.to_string()),
        attribute: Attribute::None,
        vis: crate::attrs::visibility_string(&func.vis),
        skip_reason: String::new(),
        python_name: String::new(),
        exported: true,
        is_generic: false,
        type_params: Vec::new(),
        args,
        return_kind: if return_type == "()" {
            ReturnKind::Unit
        } else {
            ReturnKind::Plain
        },
        return_type,
        return_abi: crate::codegen::return_abi(&func.sig).to_string(),
        ok_type: String::new(),
        err_type: String::new(),
        inner_type: String::new(),
        source: String::new(),
        body_has_cfg: body_has_cfg(&func.block),
        line: 0,
        has_owned_string_helper: false,
        has_borrowed_string_helper: false,
        module_path: Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn substitutes_type_params_and_exports() {
        let src = "pub fn identity<T: Copy>(x: T) -> T where T: Clone { let y: T = x; y }";
        let out = specialize(
            src,
            "identity",
            &[("T".to_string(), "i32".to_string())],
            "identity_i32",
        )
        .unwrap();
        assert!(out.source.contains("#[no_mangle]"));
        assert!(out
            .source
            .contains("pub extern \"C\" fn rustcall_identity_i32(x: i32) -> i32"));
        assert!(!out.source.contains("identity_i32<"));
        assert!(out.source.contains("let y: i32 = x;"));
        // The generic original stays next to the instantiation.
        assert!(out.source.contains("pub fn identity<T: Copy>"));
        let f = &out.manifest.functions[0];
        assert_eq!(f.name, "identity_i32");
        assert_eq!(f.return_type, "i32");
        assert_eq!(f.args[0].rust_type, "i32");
    }

    #[test]
    fn substitutes_expression_paths() {
        let src = "fn zero<T: Default>() -> T { T::default() }";
        let out = specialize(
            src,
            "zero",
            &[("T".to_string(), "f64".to_string())],
            "zero_f64",
        )
        .unwrap();
        assert!(out.source.contains("f64::default()"));
    }

    #[test]
    fn keeps_struct_context_generic() {
        let src = "pub struct Point<T> { x: T }\nimpl<T> Point<T> { pub fn new(x: T) -> Self { Self { x } } }\npub fn Point_new<T>(x: T) -> *mut Point<T> { Box::into_raw(Box::new(Point::new(x))) }";
        let out = specialize(
            src,
            "Point_new",
            &[("T".to_string(), "i64".to_string())],
            "Point_new_i64",
        )
        .unwrap();
        assert!(out.source.contains("pub struct Point<T>"));
        assert!(out
            .source
            .contains("pub extern \"C\" fn rustcall_Point_new_i64(x: i64) -> *mut Point<i64>"));
    }

    #[test]
    fn specializes_inside_inline_modules() {
        let src =
            "mod api { fn helper() -> i32 { 7 } pub fn f<T>(x: T) -> T { let _ = helper(); x } }";
        let out = specialize(
            src,
            "api::f",
            &[("T".to_string(), "i32".to_string())],
            "f_i32",
        )
        .unwrap();
        assert!(out.source.contains("mod api {"));
        assert!(out
            .source
            .contains("pub extern \"C\" fn rustcall_f_i32(x: i32) -> i32"));
        assert!(out.source.contains("pub fn f<T>"));
        assert_eq!(out.manifest.functions[0].module_path, vec!["api"]);
        assert!(matches!(
            specialize(src, "api::nope", &[], "n").unwrap_err(),
            SpecializeError::FunctionNotFound(_)
        ));
        assert!(matches!(
            specialize(src, "other::f", &[], "n").unwrap_err(),
            SpecializeError::FunctionNotFound(_)
        ));
    }

    #[test]
    fn keeps_generic_original_for_other_callers() {
        let src = "pub fn f<T: Copy>(x: T) -> T { x }\nfn helper() -> i32 { f(1) }";
        let out = specialize(src, "f", &[("T".into(), "i32".into())], "f_i32").unwrap();
        assert!(out.source.contains("pub fn f<T: Copy>(x: T) -> T"));
        assert!(out
            .source
            .contains("pub extern \"C\" fn rustcall_f_i32(x: i32) -> i32"));
        assert!(out.source.contains("fn helper() -> i32 {"));
        let f_pos = out.source.find("pub fn f<T: Copy>").unwrap();
        let s_pos = out.source.find("fn f_i32").unwrap();
        let h_pos = out.source.find("fn helper").unwrap();
        assert!(f_pos < s_pos && s_pos < h_pos);
    }

    #[test]
    fn nested_items_shadowing_a_parameter_are_left_alone() {
        let src = "pub fn outer<T: Copy>(x: T) -> T { fn inner<T>(x: T) -> T { x } struct Local<T>(T); inner(x) }";
        let out = specialize(src, "outer", &[("T".into(), "i32".into())], "outer_i32").unwrap();
        assert!(out
            .source
            .contains("pub extern \"C\" fn rustcall_outer_i32(x: i32) -> i32"));
        assert!(out.source.contains("fn inner<T>(x: T) -> T"));
        assert!(out.source.contains("struct Local<T>(T);"));
        // A nested item that does not redeclare T still sees the substitution.
        let src2 = "pub fn outer<T: Copy>(x: T) -> T { fn inner(y: T) -> T { y } inner(x) }";
        let out2 = specialize(src2, "outer", &[("T".into(), "i32".into())], "outer_i32").unwrap();
        assert!(out2.source.contains("fn inner(y: i32) -> i32"));
    }

    #[test]
    fn substitutes_inside_macro_tokens() {
        let src = "pub fn check<T: Default + PartialEq + std::fmt::Debug>(x: T) -> T { assert_eq!(x, T::default()); let v: Vec<T> = vec![T::default()]; v.into_iter().next().unwrap() }";
        let out = specialize(src, "check", &[("T".into(), "i32".into())], "check_i32").unwrap();
        assert!(out.source.contains("assert_eq!(x, i32::default())"));
        assert!(out.source.contains("vec![i32::default()]"));
        assert!(!out.source.contains("fn check_i32<"));
    }

    #[test]
    fn macro_rules_metavariables_are_preserved() {
        let src = "pub fn m<T: Default>(x: T) -> T { macro_rules! mk { ($T:ty) => { <$T>::default() }; } let _y: T = mk!(T); x }";
        let out = specialize(src, "m", &[("T".into(), "i32".into())], "m_i32").unwrap();
        assert!(out.source.contains("($T:ty)"));
        assert!(out.source.contains("$T >::default()"));
        assert!(!out.source.contains("$i32"));
        assert!(out.source.contains("mk!(i32)"));
        assert!(out.source.contains("let _y: i32"));
    }

    /// Source without layout (prettyplease wraps long signatures).
    fn flat(source: &str) -> String {
        source
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .replace("( ", "(")
            .replace(", )", ")")
            .replace(" )", ")")
    }

    #[test]
    fn fixed_string_parameters_get_the_string_wrapper() {
        let src = "pub fn tag<T: std::fmt::Display>(x: T, label: String) -> String { format!(\"{label}{x}\") }";
        let out = specialize(src, "tag", &[("T".into(), "i32".into())], "tag_i32").unwrap();
        let source = flat(&out.source);
        assert!(source.contains("pub fn tag_i32(x: i32, label: String) -> String"));
        assert!(
            source.contains("pub extern \"C\" fn rustcall_tag_i32(x: i32, label_ptr: *const u8, label_len: usize) -> tag_i32_RustCallOwnedString"),
            "{source}"
        );
        assert!(source.contains("pub extern \"C\" fn tag_i32_free_rust_string("));
        // The generic original is untouched.
        assert!(source.contains("pub fn tag<T: std::fmt::Display>(x: T, label: String) -> String"));
        let f = &out.manifest.functions[0];
        assert!(f.has_owned_string_helper);
        assert!(!f.has_borrowed_string_helper);
        assert_eq!(f.args[1].abi, "string");
        assert_eq!(f.return_type, "String");

        let src = "pub fn count<T: Copy>(x: T, s: &str) -> usize { let _ = x; s.len() }";
        let out = specialize(src, "count", &[("T".into(), "i32".into())], "count_i32").unwrap();
        let source = flat(&out.source);
        assert!(
            source.contains(
                "pub extern \"C\" fn rustcall_count_i32(x: i32, s_ptr: *const u8, s_len: usize) -> usize"
            ),
            "{source}"
        );
        let f = &out.manifest.functions[0];
        assert!(!f.has_owned_string_helper && !f.has_borrowed_string_helper);
        assert_eq!(f.args[1].abi, "str");

        let src = "pub fn label<T>(_x: T) -> &'static str { \"v\" }";
        let out = specialize(src, "label", &[("T".into(), "i32".into())], "label_i32").unwrap();
        let source = flat(&out.source);
        assert!(
            source.contains(
                "pub extern \"C\" fn rustcall_label_i32(_x: i32) -> label_i32_RustCallBorrowedString"
            ),
            "{source}"
        );
        assert!(out.manifest.functions[0].has_borrowed_string_helper);
    }

    #[test]
    fn missing_function_errors() {
        let err = specialize("fn a() {}", "b", &[], "b_i32").unwrap_err();
        assert!(matches!(err, SpecializeError::FunctionNotFound(_)));
    }

    #[test]
    fn unbound_param_errors() {
        let err = specialize(
            "fn a<T, U>(x: T, y: U) {}",
            "a",
            &[("T".into(), "i32".into())],
            "a_i32",
        )
        .unwrap_err();
        assert!(matches!(err, SpecializeError::UnboundParams(_)));
    }
}
