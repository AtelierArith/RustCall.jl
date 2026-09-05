//! Wrapper code generation.
//!
//! Two flavours share this module:
//!
//! * **crate** codegen, used by the `juliacall_macros` proc-macro for
//!   `@rust_crate` (`transform_function`, `transform_struct_crate`,
//!   `transform_impl_crate`, and the `julia_pyo3` variants);
//! * **inline** codegen, used by the extractor CLI's `expand` command for
//!   `rust"""` blocks (`inline_struct_wrappers`, `inline_generic_wrappers`).
//!
//! `transform_function` is common to both flavours, so `#[julia] fn` behaves
//! identically in inline blocks and in crates (including the C-compatible
//! `Result`/`Option` wrappers).

use proc_macro2::TokenStream as TokenStream2;
use quote::{format_ident, quote};
use syn::{
    Attribute, FnArg, Ident, ItemFn, ItemImpl, ItemStruct, Pat, ReturnType, Type, Visibility,
};

use crate::cfg::cfg_attrs;
use crate::manifest::GenericWrapper;
use crate::model::{MethodModel, StructModel};
use crate::types::{
    extract_option_type, extract_result_type, is_ffi_compatible_type,
    is_inline_accessible_field_type, is_non_ffi_type, is_self_type, is_str_ref_type,
    is_string_type, is_vec_type, needs_clone_for_getter, OptionTypeInfo, ResultTypeInfo,
};

// ============================================================================
// Functions (shared)
// ============================================================================

/// Transform a `#[julia]` function to FFI-compatible form.
pub fn transform_function(func: ItemFn) -> TokenStream2 {
    if func.sig.unsafety.is_some() {
        return quote! {
            compile_error!("#[julia] cannot be applied to unsafe functions directly. The function will be made extern \"C\" which has its own safety semantics.");
        };
    }

    if let ReturnType::Type(_, ref ret_type) = func.sig.output {
        if let Some(result_info) = extract_result_type(ret_type) {
            return transform_result_function(func, result_info);
        }
        if let Some(option_info) = extract_option_type(ret_type) {
            return transform_option_function(func, option_info);
        }
    }

    if function_uses_strings(&func.sig) {
        return transform_string_function(func);
    }

    transform_simple_function(func)
}

/// Whether a `#[julia]` function takes or returns `String` / `&str` (#242).
pub fn function_uses_strings(sig: &syn::Signature) -> bool {
    let arg_strings = sig.inputs.iter().any(|a| match a {
        FnArg::Typed(pt) => is_string_type(&pt.ty) || is_str_ref_type(&pt.ty),
        FnArg::Receiver(_) => false,
    });
    arg_strings || function_returns_string(sig) || function_returns_str_ref(sig)
}

pub fn function_returns_string(sig: &syn::Signature) -> bool {
    matches!(&sig.output, ReturnType::Type(_, ty) if is_string_type(ty))
}

pub fn function_returns_str_ref(sig: &syn::Signature) -> bool {
    matches!(&sig.output, ReturnType::Type(_, ty) if is_str_ref_type(ty))
}

/// Whether any argument is passed as a `(ptr, len)` byte pair.
pub fn has_string_args(sig: &syn::Signature) -> bool {
    sig.inputs.iter().any(|a| match a {
        FnArg::Typed(pt) => is_string_type(&pt.ty) || is_str_ref_type(&pt.ty),
        FnArg::Receiver(_) => false,
    })
}

/// A `&str` return may only be handed to Julia as a borrowed view when it
/// cannot point into a temporary the wrapper itself created: the `(ptr, len)`
/// argument conversions build owned values (`String::from_utf8_lossy`) that
/// die with the call, so a function that both takes and returns strings
/// returns an owned copy instead (#242).
pub fn returns_borrowed_str(sig: &syn::Signature) -> bool {
    function_returns_str_ref(sig) && !has_string_args(sig)
}

/// A `&str`-returning signature whose result must be copied into an owned
/// buffer (see [`returns_borrowed_str`]).
pub fn returns_copied_str(sig: &syn::Signature) -> bool {
    function_returns_str_ref(sig) && has_string_args(sig)
}

/// Wrapper-side view of a function's arguments: `String` / `&str` become
/// `(ptr, len)` byte pairs (`conversions` rebuild the Rust value, lossily for
/// invalid UTF-8, never through `from_utf8_unchecked`), everything else is
/// passed through.
struct StringArgs {
    wrapper_args: Vec<TokenStream2>,
    conversions: Vec<TokenStream2>,
    call_args: Vec<TokenStream2>,
}

fn string_arg_conversions(func: &ItemFn, names: &[Ident]) -> StringArgs {
    let mut wrapper_args: Vec<TokenStream2> = Vec::new();
    let mut conversions: Vec<TokenStream2> = Vec::new();
    let mut call_args: Vec<TokenStream2> = Vec::new();
    for (arg, name) in func.sig.inputs.iter().zip(names.iter()) {
        let FnArg::Typed(pat_type) = arg else {
            continue;
        };
        let ty = &pat_type.ty;
        if is_string_type(ty) {
            let p = format_ident!("{}_ptr", name);
            let l = format_ident!("{}_len", name);
            wrapper_args.push(quote! { #p: *const u8 });
            wrapper_args.push(quote! { #l: usize });
            conversions.push(quote! {
                let #name = unsafe {
                    let slice = std::slice::from_raw_parts(#p, #l);
                    String::from_utf8_lossy(slice).into_owned()
                };
            });
        } else if is_str_ref_type(ty) {
            let p = format_ident!("{}_ptr", name);
            let l = format_ident!("{}_len", name);
            let b = format_ident!("{}_bytes", name);
            let c = format_ident!("{}_cow", name);
            wrapper_args.push(quote! { #p: *const u8 });
            wrapper_args.push(quote! { #l: usize });
            conversions.push(quote! {
                let #b = unsafe { std::slice::from_raw_parts(#p, #l) };
                let #c = String::from_utf8_lossy(#b);
                let #name: &str = &#c;
            });
        } else {
            wrapper_args.push(quote! { #name: #ty });
        }
        call_args.push(quote! { #name });
    }
    StringArgs {
        wrapper_args,
        conversions,
        call_args,
    }
}

/// `#[julia] fn f(s: String, t: &str) -> String` (#242).
///
/// Same ABI as the struct method wrappers: every `String` / `&str` argument
/// becomes a `(*const u8, usize)` pair (UTF-8, not NUL-terminated); a `String`
/// return becomes `<fn>_RustCallOwnedString { ptr, len, cap }` released with
/// `<fn>_free_rust_string(ptr, len, cap)`; a `&str` return becomes
/// `<fn>_RustCallBorrowedString { ptr, len }` (the caller keeps the borrowed
/// data alive). The original function is kept as `<fn>_inner`.
fn transform_string_function(func: ItemFn) -> TokenStream2 {
    let inner_fn = func.clone();
    let mut func = func;
    let names = normalize_arg_patterns(&mut func);
    let func_name = &func.sig.ident;
    let inner_fn_name = format_ident!("{}_inner", func_name);
    let inner_fn_args = &inner_fn.sig.inputs;
    let inner_output = &inner_fn.sig.output;
    // Lifetime parameters (`fn f<'a>(s: &'a str) -> &'a str`) stay on the inner fn.
    let inner_generics = &inner_fn.sig.generics;
    let inner_where = &inner_fn.sig.generics.where_clause;
    let body = &inner_fn.block;
    let cfg_attrs = cfg_attrs(&func.attrs);
    let outer_attrs = &func.attrs;

    let StringArgs {
        wrapper_args,
        conversions,
        call_args,
    } = string_arg_conversions(&func, &names);

    let owned_helper = format_ident!("{}_RustCallOwnedString", func_name);
    let owned_free = format_ident!("{}_free_rust_string", func_name);
    let borrowed_helper = format_ident!("{}_RustCallBorrowedString", func_name);
    let call = quote! { #inner_fn_name(#(#call_args),*) };

    let returns_owned = function_returns_string(&func.sig) || returns_copied_str(&func.sig);
    let (helpers, wrapper) = if returns_owned {
        (
            quote! {
                #(#cfg_attrs)*
                #[repr(C)]
                pub struct #owned_helper {
                    pub ptr: *mut u8,
                    pub len: usize,
                    pub cap: usize,
                }

                #(#cfg_attrs)*
                #[no_mangle]
                pub extern "C" fn #owned_free(ptr: *mut u8, len: usize, cap: usize) {
                    if !ptr.is_null() {
                        unsafe { drop(Vec::from_raw_parts(ptr, len, cap)); }
                    }
                }
            },
            quote! {
                #(#outer_attrs)*
                #[no_mangle]
                pub extern "C" fn #func_name(#(#wrapper_args),*) -> #owned_helper {
                    #(#conversions)*
                    let rustcall_value = #call;
                    // `ToString` covers both `String` and a `&str` result that
                    // must be copied because it may borrow from a converted
                    // argument (see `returns_copied_str`).
                    let mut rustcall_bytes = ToString::to_string(&rustcall_value).into_bytes();
                    let rustcall_ret = #owned_helper {
                        ptr: rustcall_bytes.as_mut_ptr(),
                        len: rustcall_bytes.len(),
                        cap: rustcall_bytes.capacity(),
                    };
                    std::mem::forget(rustcall_bytes);
                    rustcall_ret
                }
            },
        )
    } else if returns_borrowed_str(&func.sig) {
        (
            quote! {
                #(#cfg_attrs)*
                #[repr(C)]
                pub struct #borrowed_helper {
                    pub ptr: *const u8,
                    pub len: usize,
                }
            },
            quote! {
                #(#outer_attrs)*
                #[no_mangle]
                pub extern "C" fn #func_name(#(#wrapper_args),*) -> #borrowed_helper {
                    #(#conversions)*
                    let rustcall_value = #call;
                    #borrowed_helper {
                        ptr: rustcall_value.as_ptr(),
                        len: rustcall_value.len(),
                    }
                }
            },
        )
    } else {
        let output = &func.sig.output;
        (
            quote! {},
            quote! {
                #(#outer_attrs)*
                #[no_mangle]
                pub extern "C" fn #func_name(#(#wrapper_args),*) #output {
                    #(#conversions)*
                    #call
                }
            },
        )
    };

    quote! {
        #helpers

        #(#cfg_attrs)*
        #[allow(clippy::ptr_arg)]
        fn #inner_fn_name #inner_generics (#inner_fn_args) #inner_output #inner_where #body

        #wrapper
    }
}

fn transform_simple_function(mut func: ItemFn) -> TokenStream2 {
    let no_mangle: Attribute = syn::parse_quote!(#[no_mangle]);
    func.attrs.insert(0, no_mangle);
    func.vis = Visibility::Public(syn::token::Pub::default());
    func.sig.abi = Some(syn::parse_quote!(extern "C"));
    quote! { #func }
}

fn generate_c_result_type(
    func_name: &Ident,
    ok_type: &Type,
    err_type: &Type,
    cfg_attrs: &[Attribute],
) -> TokenStream2 {
    let result_type_name = format_ident!("CResult_{}", func_name);
    quote! {
        #(#cfg_attrs)*
        #[repr(C)]
        pub struct #result_type_name {
            // Private: the discriminant and the payloads must stay consistent,
            // or `ok()` / `err()` would read uninitialized memory. The C layout
            // (u8 followed by both payloads) is unchanged.
            is_ok: u8,
            /// Only initialized when `is_ok == 1`. `MaybeUninit` keeps the
            /// inactive field free of validity invariants (e.g. `NonZeroU32`).
            ok_value: ::std::mem::MaybeUninit<#ok_type>,
            /// Only initialized when `is_ok == 0`.
            err_value: ::std::mem::MaybeUninit<#err_type>,
        }

        #(#cfg_attrs)*
        impl #result_type_name {
            /// Wrap a `Result` in the C-compatible representation.
            pub fn new(value: Result<#ok_type, #err_type>) -> Self {
                match value {
                    Ok(v) => Self {
                        is_ok: 1,
                        ok_value: ::std::mem::MaybeUninit::new(v),
                        err_value: ::std::mem::MaybeUninit::zeroed(),
                    },
                    Err(e) => Self {
                        is_ok: 0,
                        ok_value: ::std::mem::MaybeUninit::zeroed(),
                        err_value: ::std::mem::MaybeUninit::new(e),
                    },
                }
            }
            /// Whether the call succeeded.
            pub fn is_ok(&self) -> bool {
                self.is_ok == 1
            }
            /// The `Ok` value, if any.
            pub fn ok(&self) -> Option<&#ok_type> {
                if self.is_ok == 1 { Some(unsafe { self.ok_value.assume_init_ref() }) } else { None }
            }
            /// The `Err` value, if any.
            pub fn err(&self) -> Option<&#err_type> {
                if self.is_ok == 0 { Some(unsafe { self.err_value.assume_init_ref() }) } else { None }
            }
        }
    }
}

fn generate_c_option_type(
    func_name: &Ident,
    inner_type: &Type,
    cfg_attrs: &[Attribute],
) -> TokenStream2 {
    let option_type_name = format_ident!("COption_{}", func_name);
    quote! {
        #(#cfg_attrs)*
        #[repr(C)]
        pub struct #option_type_name {
            // Private, see the CResult type: the discriminant guards a
            // `MaybeUninit` payload. The C layout is unchanged.
            is_some: u8,
            /// Only initialized when `is_some == 1`.
            value: ::std::mem::MaybeUninit<#inner_type>,
        }

        #(#cfg_attrs)*
        impl #option_type_name {
            /// Wrap an `Option` in the C-compatible representation.
            pub fn new(value: Option<#inner_type>) -> Self {
                match value {
                    Some(v) => Self {
                        is_some: 1,
                        value: ::std::mem::MaybeUninit::new(v),
                    },
                    None => Self {
                        is_some: 0,
                        value: ::std::mem::MaybeUninit::zeroed(),
                    },
                }
            }
            /// Whether a value is present.
            pub fn is_some(&self) -> bool {
                self.is_some == 1
            }
            /// The `Some` value, if any.
            pub fn some(&self) -> Option<&#inner_type> {
                if self.is_some == 1 { Some(unsafe { self.value.assume_init_ref() }) } else { None }
            }
        }
    }
}

/// Give every typed argument a plain identifier (`argN` for destructuring
/// patterns) so the outer `extern "C"` signature and the inner call agree.
fn normalize_arg_patterns(func: &mut ItemFn) -> Vec<Ident> {
    let mut names = Vec::new();
    for (i, arg) in func.sig.inputs.iter_mut().enumerate() {
        if let FnArg::Typed(pat_type) = arg {
            match pat_type.pat.as_ref() {
                Pat::Ident(pat_ident) => names.push(pat_ident.ident.clone()),
                _ => {
                    let ident = format_ident!("arg{}", i);
                    *pat_type.pat = syn::parse_quote!(#ident);
                    names.push(ident);
                }
            }
        }
    }
    names
}

fn transform_result_function(func: ItemFn, result_info: ResultTypeInfo) -> TokenStream2 {
    let inner_fn = func.clone();
    let mut func = func;
    let names = normalize_arg_patterns(&mut func);
    let func_name = &func.sig.ident;
    let ok_type = &result_info.ok_type;
    let err_type = &result_info.err_type;

    if is_non_ffi_type(ok_type) {
        return quote! {
            compile_error!(concat!(
                "#[julia] function `", stringify!(#func_name),
                "` returns Result with non-FFI-compatible Ok type `", stringify!(#ok_type),
                "`. Use a primitive or #[repr(C)] type instead."
            ));
        };
    }
    if is_non_ffi_type(err_type) {
        return quote! {
            compile_error!(concat!(
                "#[julia] function `", stringify!(#func_name),
                "` returns Result with non-FFI-compatible Err type `", stringify!(#err_type),
                "`. Use a primitive or #[repr(C)] type instead."
            ));
        };
    }

    let cfg_attrs = cfg_attrs(&func.attrs);
    let c_result_type = generate_c_result_type(func_name, ok_type, err_type, &cfg_attrs);
    let result_type_name = format_ident!("CResult_{}", func_name);
    let StringArgs {
        wrapper_args: args,
        conversions,
        call_args: names,
    } = string_arg_conversions(&func, &names);
    let body = &inner_fn.block;
    let inner_fn_name = format_ident!("{}_inner", func_name);
    let inner_fn_args = &inner_fn.sig.inputs;
    let inner_generics = &inner_fn.sig.generics;
    let inner_where = &inner_fn.sig.generics.where_clause;
    // `#[cfg]` must gate every generated item (struct, accessor impl, inner
    // fn, extern fn); other attributes (docs, lints) stay on the exported fn.
    let outer_attrs = &func.attrs;

    quote! {
        #c_result_type

        #(#cfg_attrs)*
        fn #inner_fn_name #inner_generics (#inner_fn_args) -> Result<#ok_type, #err_type> #inner_where #body

        #(#outer_attrs)*
        #[no_mangle]
        pub extern "C" fn #func_name(#(#args),*) -> #result_type_name {
            #(#conversions)*
            #result_type_name::new(#inner_fn_name(#(#names),*))
        }
    }
}

fn transform_option_function(func: ItemFn, option_info: OptionTypeInfo) -> TokenStream2 {
    let inner_fn = func.clone();
    let mut func = func;
    let names = normalize_arg_patterns(&mut func);
    let func_name = &func.sig.ident;
    let inner_type = &option_info.inner_type;

    if is_non_ffi_type(inner_type) {
        return quote! {
            compile_error!(concat!(
                "#[julia] function `", stringify!(#func_name),
                "` returns Option with non-FFI-compatible type `", stringify!(#inner_type),
                "`. Use a primitive or #[repr(C)] type instead."
            ));
        };
    }

    let cfg_attrs = cfg_attrs(&func.attrs);
    let c_option_type = generate_c_option_type(func_name, inner_type, &cfg_attrs);
    let option_type_name = format_ident!("COption_{}", func_name);
    let StringArgs {
        wrapper_args: args,
        conversions,
        call_args: names,
    } = string_arg_conversions(&func, &names);
    let body = &inner_fn.block;
    let inner_fn_name = format_ident!("{}_inner", func_name);
    let inner_fn_args = &inner_fn.sig.inputs;
    let inner_generics = &inner_fn.sig.generics;
    let inner_where = &inner_fn.sig.generics.where_clause;
    let outer_attrs = &func.attrs;

    quote! {
        #c_option_type

        #(#cfg_attrs)*
        fn #inner_fn_name #inner_generics (#inner_fn_args) -> Option<#inner_type> #inner_where #body

        #(#outer_attrs)*
        #[no_mangle]
        pub extern "C" fn #func_name(#(#args),*) -> #option_type_name {
            #(#conversions)*
            #option_type_name::new(#inner_fn_name(#(#names),*))
        }
    }
}

// ============================================================================
// Crate flavour: structs and impl blocks (proc-macro)
// ============================================================================

fn crate_field_accessors(item_struct: &ItemStruct) -> TokenStream2 {
    let struct_name = &item_struct.ident;
    let mut ffi_functions = TokenStream2::new();
    if let syn::Fields::Named(ref fields) = item_struct.fields {
        for field in &fields.named {
            let Some(ref field_name) = field.ident else {
                continue;
            };
            let field_ty = &field.ty;
            if !(is_ffi_compatible_type(field_ty) || needs_clone_for_getter(field_ty)) {
                continue;
            }
            let getter_name = format_ident!("{}_get_{}", struct_name, field_name);
            if needs_clone_for_getter(field_ty) {
                ffi_functions.extend(quote! {
                    #[no_mangle]
                    pub extern "C" fn #getter_name(ptr: *const #struct_name) -> #field_ty {
                        unsafe { (*ptr).#field_name.clone() }
                    }
                });
            } else {
                ffi_functions.extend(quote! {
                    #[no_mangle]
                    pub extern "C" fn #getter_name(ptr: *const #struct_name) -> #field_ty {
                        unsafe { (*ptr).#field_name }
                    }
                });
            }
            let setter_name = format_ident!("{}_set_{}", struct_name, field_name);
            ffi_functions.extend(quote! {
                #[no_mangle]
                pub extern "C" fn #setter_name(ptr: *mut #struct_name, value: #field_ty) {
                    unsafe { (*ptr).#field_name = value; }
                }
            });
        }
    }
    ffi_functions
}

fn crate_free_fn(struct_name: &Ident) -> TokenStream2 {
    let free_fn_name = format_ident!("{}_free", struct_name);
    quote! {
        #[no_mangle]
        pub extern "C" fn #free_fn_name(ptr: *mut #struct_name) {
            if !ptr.is_null() {
                unsafe { drop(Box::from_raw(ptr)); }
            }
        }
    }
}

/// Transform a `#[julia]` struct (crate flavour): `#[repr(C)]`, `pub`, free + accessors.
pub fn transform_struct_crate(mut item_struct: ItemStruct) -> TokenStream2 {
    let repr_c: Attribute = syn::parse_quote!(#[repr(C)]);
    item_struct.attrs.insert(0, repr_c);
    item_struct.vis = Visibility::Public(syn::token::Pub::default());

    let free = crate_free_fn(&item_struct.ident);
    let accessors = crate_field_accessors(&item_struct);

    quote! {
        #item_struct
        #free
        #accessors
    }
}

/// Transform a `#[julia]` impl block (crate flavour): wrap `#[julia]` methods.
pub fn transform_impl_crate(mut item_impl: ItemImpl) -> TokenStream2 {
    let struct_name = match item_impl.self_ty.as_ref() {
        Type::Path(type_path) => type_path.path.segments.last().map(|s| s.ident.clone()),
        _ => None,
    };
    let Some(struct_name) = struct_name else {
        return quote! {
            compile_error!("#[julia] on impl block requires a simple type path");
        };
    };

    let mut ffi_wrappers = TokenStream2::new();
    for item in &mut item_impl.items {
        if let syn::ImplItem::Fn(method) = item {
            let has_julia_attr = method
                .attrs
                .iter()
                .any(|attr| attr.path().is_ident("julia"));
            if has_julia_attr {
                method.attrs.retain(|attr| !attr.path().is_ident("julia"));
                ffi_wrappers.extend(generate_method_wrapper_crate(&struct_name, method));
            }
        }
    }

    quote! {
        #item_impl
        #ffi_wrappers
    }
}

/// Whether the wrapper of a method returns a boxed `*mut Struct`: `new`, or any
/// method (static or instance) returning `Self` / the struct type. This is what
/// Julia needs to know; both codegen flavours box these cases.
pub fn returns_boxed_struct(struct_name: &Ident, method: &syn::ImplItemFn) -> bool {
    method.sig.ident == "new"
        || matches!(&method.sig.output, ReturnType::Type(_, ty) if is_self_type(ty, struct_name))
}

/// Whether a method is treated as a constructor: static and either named `new`
/// or returning `Self` / the struct type.
pub fn is_constructor(struct_name: &Ident, method: &syn::ImplItemFn, is_static: bool) -> bool {
    let returns_self = matches!(
        &method.sig.output,
        ReturnType::Type(_, ty) if is_self_type(ty, struct_name)
    );
    is_static && (method.sig.ident == "new" || returns_self)
}

/// Generate the FFI wrapper for a method (crate flavour).
pub fn generate_method_wrapper_crate(
    struct_name: &Ident,
    method: &syn::ImplItemFn,
) -> TokenStream2 {
    let method_name = &method.sig.ident;
    let wrapper_name = format_ident!("{}_{}", struct_name, method_name);

    let is_static = !method
        .sig
        .inputs
        .iter()
        .any(|arg| matches!(arg, FnArg::Receiver(_)));
    let is_constructor = is_constructor(struct_name, method, is_static);

    let mut wrapper_args = Vec::new();
    let mut call_args = Vec::new();
    let mut self_handling = TokenStream2::new();

    for (i, arg) in method.sig.inputs.iter().enumerate() {
        match arg {
            FnArg::Receiver(r) => {
                if r.mutability.is_some() {
                    wrapper_args.push(quote! { ptr: *mut #struct_name });
                    self_handling = quote! { let self_ref = unsafe { &mut *ptr }; };
                } else {
                    wrapper_args.push(quote! { ptr: *const #struct_name });
                    self_handling = quote! { let self_ref = unsafe { &*ptr }; };
                }
            }
            FnArg::Typed(pat_type) => {
                let ty = &pat_type.ty;
                let arg_name: Ident = match pat_type.pat.as_ref() {
                    Pat::Ident(pat_ident) => pat_ident.ident.clone(),
                    _ => format_ident!("arg{}", i),
                };
                wrapper_args.push(quote! { #arg_name: #ty });
                call_args.push(quote! { #arg_name });
            }
        }
    }

    let return_type = &method.sig.output;

    if is_constructor {
        quote! {
            #[no_mangle]
            pub extern "C" fn #wrapper_name(#(#wrapper_args),*) -> *mut #struct_name {
                let obj = #struct_name::#method_name(#(#call_args),*);
                Box::into_raw(Box::new(obj))
            }
        }
    } else if is_static {
        match return_type {
            ReturnType::Default => quote! {
                #[no_mangle]
                pub extern "C" fn #wrapper_name(#(#wrapper_args),*) {
                    #struct_name::#method_name(#(#call_args),*);
                }
            },
            ReturnType::Type(_, ty) => {
                if is_self_type(ty, struct_name) {
                    quote! {
                        #[no_mangle]
                        pub extern "C" fn #wrapper_name(#(#wrapper_args),*) -> *mut #struct_name {
                            let obj = #struct_name::#method_name(#(#call_args),*);
                            Box::into_raw(Box::new(obj))
                        }
                    }
                } else {
                    quote! {
                        #[no_mangle]
                        pub extern "C" fn #wrapper_name(#(#wrapper_args),*) #return_type {
                            #struct_name::#method_name(#(#call_args),*)
                        }
                    }
                }
            }
        }
    } else {
        match return_type {
            ReturnType::Default => quote! {
                #[no_mangle]
                pub extern "C" fn #wrapper_name(#(#wrapper_args),*) {
                    #self_handling
                    self_ref.#method_name(#(#call_args),*);
                }
            },
            ReturnType::Type(_, ty) => {
                if is_self_type(ty, struct_name) {
                    quote! {
                        #[no_mangle]
                        pub extern "C" fn #wrapper_name(#(#wrapper_args),*) -> *mut #struct_name {
                            #self_handling
                            let obj = self_ref.#method_name(#(#call_args),*);
                            Box::into_raw(Box::new(obj))
                        }
                    }
                } else {
                    quote! {
                        #[no_mangle]
                        pub extern "C" fn #wrapper_name(#(#wrapper_args),*) #return_type {
                            #self_handling
                            self_ref.#method_name(#(#call_args),*)
                        }
                    }
                }
            }
        }
    }
}

// ============================================================================
// Crate flavour: #[julia_pyo3]
// ============================================================================

pub fn transform_function_julia_pyo3(func: ItemFn) -> TokenStream2 {
    let func_attrs = &func.attrs;
    let func_sig = &func.sig;
    let func_block = &func.block;

    if let ReturnType::Type(_, ref ret_type) = func.sig.output {
        if extract_result_type(ret_type).is_some() || extract_option_type(ret_type).is_some() {
            return quote! {
                #[cfg(not(feature = "python"))]
                #(#func_attrs)*
                #[no_mangle]
                pub extern "C" #func_sig #func_block

                #[cfg(feature = "python")]
                #[pyo3::pyfunction]
                pub #func_sig #func_block
            };
        }
    }

    quote! {
        #[cfg(not(feature = "python"))]
        #(#func_attrs)*
        #[no_mangle]
        pub extern "C" #func_sig #func_block

        #[cfg(feature = "python")]
        #[pyo3::pyfunction]
        pub #func_sig #func_block
    }
}

pub fn transform_struct_julia_pyo3(mut item_struct: ItemStruct) -> TokenStream2 {
    let repr_c: Attribute = syn::parse_quote!(#[repr(C)]);
    item_struct.attrs.insert(0, repr_c);
    item_struct.vis = Visibility::Public(syn::token::Pub::default());

    let free = crate_free_fn(&item_struct.ident);
    let accessors = crate_field_accessors(&item_struct);

    quote! {
        #[cfg_attr(feature = "python", pyo3::pyclass(get_all, set_all))]
        #item_struct
        #free
        #accessors
    }
}

pub fn transform_impl_julia_pyo3(item_impl: ItemImpl) -> TokenStream2 {
    let struct_name = match item_impl.self_ty.as_ref() {
        Type::Path(type_path) => type_path.path.segments.last().map(|s| s.ident.clone()),
        _ => None,
    };
    let Some(struct_name) = struct_name else {
        return quote! {
            compile_error!("#[julia_pyo3] on impl block requires a simple type path");
        };
    };

    let mut julia_ffi_wrappers = TokenStream2::new();
    let mut pyo3_methods = TokenStream2::new();

    for item in &item_impl.items {
        if let syn::ImplItem::Fn(method) = item {
            julia_ffi_wrappers.extend(generate_method_wrapper_crate(&struct_name, method));
            pyo3_methods.extend(generate_pyo3_method_impl(method));
        }
    }

    quote! {
        #[cfg(not(feature = "python"))]
        #item_impl

        #[cfg(feature = "python")]
        #[pyo3::pymethods]
        impl #struct_name {
            #pyo3_methods
        }

        #julia_ffi_wrappers
    }
}

fn generate_pyo3_method_impl(method: &syn::ImplItemFn) -> TokenStream2 {
    let method_vis = &method.vis;
    let method_attrs = &method.attrs;
    let method_block = &method.block;
    let method_sig = &method.sig;

    let is_static = !method
        .sig
        .inputs
        .iter()
        .any(|arg| matches!(arg, FnArg::Receiver(_)));
    let is_pyo3_constructor = method.sig.ident == "new" && is_static;

    if is_pyo3_constructor {
        quote! {
            #(#method_attrs)*
            #[new]
            #method_vis #method_sig #method_block
        }
    } else {
        quote! {
            #(#method_attrs)*
            #method_vis #method_sig #method_block
        }
    }
}

// ============================================================================
// Inline flavour: struct wrappers for rust"""...""" blocks
// ============================================================================

/// What the inline struct wrapper generator produced, for the manifest.
#[derive(Debug, Default, Clone)]
pub struct InlineStructMeta {
    pub has_clone: bool,
    pub has_owned_string_helper: bool,
    pub has_borrowed_string_helper: bool,
    /// `(field, getter symbol, setter symbol)` for every accessible field. When a
    /// method wrapper already owns the `<Struct>_get_<field>` symbol, that wrapper
    /// serves as the getter and no setter is generated.
    pub accessors: Vec<(String, String, String)>,
}

fn method_returns_string(m: &MethodModel) -> bool {
    matches!(&m.func.sig.output, ReturnType::Type(_, ty) if is_string_type(ty))
}

/// A method returning `&str` that also takes string arguments: the result may
/// borrow from a converted argument, so it is copied (see [`returns_borrowed_str`]).
fn method_copies_str(m: &MethodModel) -> bool {
    returns_copied_str(&m.func.sig)
}

fn method_returns_borrowed_str(m: &MethodModel) -> bool {
    returns_borrowed_str(&m.func.sig)
}

fn inline_method_is_ctor(struct_name: &Ident, m: &MethodModel) -> bool {
    // Historical inline rule: `new`, or any method returning Self / the struct type
    // (static or not) is treated as returning a boxed struct.
    m.name() == "new"
        || matches!(&m.func.sig.output, ReturnType::Type(_, ty) if is_self_type(ty, struct_name))
}

/// Generate the `extern "C"` wrappers for a non-generic inline struct.
pub fn inline_struct_wrappers(model: &StructModel) -> (TokenStream2, InlineStructMeta) {
    let struct_name = &model.item.ident;
    let mut out = TokenStream2::new();
    let mut meta = InlineStructMeta::default();

    let free_name = format_ident!("{}_free", struct_name);
    out.extend(quote! {
        #[no_mangle]
        pub extern "C" fn #free_name(ptr: *mut #struct_name) {
            if !ptr.is_null() {
                unsafe { drop(Box::from_raw(ptr)); }
            }
        }
    });

    let fields = model.named_fields();
    let accessible: Vec<&(Ident, Type)> = fields
        .iter()
        .filter(|(_, ty)| is_inline_accessible_field_type(ty))
        .collect();

    let needs_owned = accessible.iter().any(|(_, ty)| is_string_type(ty))
        || model.methods.iter().any(|m| {
            (method_returns_string(m) || method_copies_str(m))
                && !inline_method_is_ctor(struct_name, m)
        });
    let needs_borrowed = model
        .methods
        .iter()
        .any(|m| method_returns_borrowed_str(m) && !inline_method_is_ctor(struct_name, m));

    let owned_helper = format_ident!("{}_RustCallOwnedString", struct_name);
    let borrowed_helper = format_ident!("{}_RustCallBorrowedString", struct_name);
    let owned_free = format_ident!("{}_free_rust_string", struct_name);

    if needs_owned {
        meta.has_owned_string_helper = true;
        out.extend(quote! {
            #[repr(C)]
            pub struct #owned_helper {
                ptr: *mut u8,
                len: usize,
                cap: usize,
            }

            #[no_mangle]
            pub extern "C" fn #owned_free(ptr: *mut u8, len: usize, cap: usize) {
                if !ptr.is_null() {
                    unsafe { drop(Vec::from_raw_parts(ptr, len, cap)); }
                }
            }
        });
    }
    if needs_borrowed {
        meta.has_borrowed_string_helper = true;
        out.extend(quote! {
            #[repr(C)]
            pub struct #borrowed_helper {
                ptr: *const u8,
                len: usize,
            }
        });
    }

    // Field accessors (skipped when a method wrapper would take the same symbol).
    let method_symbols: Vec<String> = model
        .methods
        .iter()
        .map(|m| format!("{}_{}", struct_name, m.name()))
        .collect();
    for (field_name, field_ty) in &accessible {
        let getter = format_ident!("{}_get_{}", struct_name, field_name);
        if method_symbols.contains(&getter.to_string()) {
            meta.accessors
                .push((field_name.to_string(), getter.to_string(), String::new()));
            continue;
        }
        let setter = format_ident!("{}_set_{}", struct_name, field_name);
        meta.accessors.push((
            field_name.to_string(),
            getter.to_string(),
            setter.to_string(),
        ));
        if is_string_type(field_ty) {
            out.extend(quote! {
                #[no_mangle]
                pub extern "C" fn #getter(ptr: *const #struct_name) -> #owned_helper {
                    let mut rustcall_bytes = unsafe { (*ptr).#field_name.clone().into_bytes() };
                    let rustcall_ret = #owned_helper {
                        ptr: rustcall_bytes.as_mut_ptr(),
                        len: rustcall_bytes.len(),
                        cap: rustcall_bytes.capacity(),
                    };
                    std::mem::forget(rustcall_bytes);
                    rustcall_ret
                }
            });
        } else if is_vec_type(field_ty) {
            out.extend(quote! {
                #[no_mangle]
                pub extern "C" fn #getter(ptr: *const #struct_name) -> #field_ty {
                    unsafe { (*ptr).#field_name.clone() }
                }
            });
        } else {
            out.extend(quote! {
                #[no_mangle]
                pub extern "C" fn #getter(ptr: *const #struct_name) -> #field_ty {
                    unsafe { (*ptr).#field_name }
                }
            });
        }
        out.extend(quote! {
            #[no_mangle]
            pub extern "C" fn #setter(ptr: *mut #struct_name, value: #field_ty) {
                unsafe { (*ptr).#field_name = value; }
            }
        });
    }

    if model.derives.iter().any(|d| d == "Clone") {
        meta.has_clone = true;
        let clone_name = format_ident!("{}_clone", struct_name);
        out.extend(quote! {
            #[no_mangle]
            pub extern "C" fn #clone_name(ptr: *const #struct_name) -> *mut #struct_name {
                unsafe { Box::into_raw(Box::new((*ptr).clone())) }
            }
        });
    }

    for m in &model.methods {
        out.extend(inline_method_wrapper(
            struct_name,
            m,
            &owned_helper,
            &borrowed_helper,
        ));
    }

    (out, meta)
}

fn inline_method_wrapper(
    struct_name: &Ident,
    m: &MethodModel,
    owned_helper: &Ident,
    borrowed_helper: &Ident,
) -> TokenStream2 {
    let method_name = &m.func.sig.ident;
    let wrapper_name = format_ident!("{}_{}", struct_name, method_name);
    let returns_self = inline_method_is_ctor(struct_name, m);

    let mut wrapper_args: Vec<TokenStream2> = Vec::new();
    let mut conversions: Vec<TokenStream2> = Vec::new();
    let mut call_args: Vec<TokenStream2> = Vec::new();

    if !m.is_static {
        if m.is_mutable {
            wrapper_args.push(quote! { ptr: *mut #struct_name });
        } else {
            wrapper_args.push(quote! { ptr: *const #struct_name });
        }
    }

    for (i, arg) in m.func.sig.inputs.iter().enumerate() {
        let FnArg::Typed(pat_type) = arg else {
            continue;
        };
        let ty = &pat_type.ty;
        let name: Ident = match pat_type.pat.as_ref() {
            Pat::Ident(pi) => pi.ident.clone(),
            _ => format_ident!("arg{}", i),
        };
        if is_string_type(ty) {
            let p = format_ident!("{}_ptr", name);
            let l = format_ident!("{}_len", name);
            wrapper_args.push(quote! { #p: *const u8 });
            wrapper_args.push(quote! { #l: usize });
            conversions.push(quote! {
                let #name = unsafe {
                    let slice = std::slice::from_raw_parts(#p, #l);
                    String::from_utf8_lossy(slice).into_owned()
                };
            });
            call_args.push(quote! { #name });
        } else if is_str_ref_type(ty) {
            let p = format_ident!("{}_ptr", name);
            let l = format_ident!("{}_len", name);
            let b = format_ident!("{}_bytes", name);
            wrapper_args.push(quote! { #p: *const u8 });
            wrapper_args.push(quote! { #l: usize });
            let c = format_ident!("{}_cow", name);
            conversions.push(quote! {
                let #b = unsafe { std::slice::from_raw_parts(#p, #l) };
                let #c = String::from_utf8_lossy(#b);
                let #name: &str = &#c;
            });
            call_args.push(quote! { #name });
        } else {
            wrapper_args.push(quote! { #name: #ty });
            call_args.push(quote! { #name });
        }
    }

    // A `&str` result of a method that takes string arguments may borrow from a
    // converted argument, so it is copied into the owned representation.
    let copies_str = method_copies_str(m);

    let self_binding = if m.is_static {
        quote! {}
    } else if m.is_mutable {
        quote! { let self_obj = unsafe { &mut *ptr }; }
    } else {
        quote! { let self_obj = unsafe { &*ptr }; }
    };
    let call = if m.is_static {
        quote! { #struct_name::#method_name(#(#call_args),*) }
    } else {
        quote! { self_obj.#method_name(#(#call_args),*) }
    };

    if returns_self {
        return quote! {
            #[no_mangle]
            pub extern "C" fn #wrapper_name(#(#wrapper_args),*) -> *mut #struct_name {
                #(#conversions)*
                #self_binding
                let obj = #call;
                Box::into_raw(Box::new(obj))
            }
        };
    }

    match &m.func.sig.output {
        ReturnType::Default => quote! {
            #[no_mangle]
            pub extern "C" fn #wrapper_name(#(#wrapper_args),*) {
                #(#conversions)*
                #self_binding
                #call
            }
        },
        ReturnType::Type(_, ty) if is_string_type(ty) || (is_str_ref_type(ty) && copies_str) => {
            quote! {
                #[no_mangle]
                pub extern "C" fn #wrapper_name(#(#wrapper_args),*) -> #owned_helper {
                    #(#conversions)*
                    #self_binding
                    let rustcall_value = #call;
                    let mut rustcall_bytes = ToString::to_string(&rustcall_value).into_bytes();
                    let rustcall_ret = #owned_helper {
                        ptr: rustcall_bytes.as_mut_ptr(),
                        len: rustcall_bytes.len(),
                        cap: rustcall_bytes.capacity(),
                    };
                    std::mem::forget(rustcall_bytes);
                    rustcall_ret
                }
            }
        }
        ReturnType::Type(_, ty) if is_str_ref_type(ty) && !copies_str => quote! {
            #[no_mangle]
            pub extern "C" fn #wrapper_name(#(#wrapper_args),*) -> #borrowed_helper {
                #(#conversions)*
                #self_binding
                let rustcall_value = #call;
                #borrowed_helper {
                    ptr: rustcall_value.as_ptr(),
                    len: rustcall_value.len(),
                }
            }
        },
        ReturnType::Type(_, ty) => quote! {
            #[no_mangle]
            pub extern "C" fn #wrapper_name(#(#wrapper_args),*) -> #ty {
                #(#conversions)*
                #self_binding
                #call
            }
        },
    }
}

/// Generics for a generic-struct method wrapper: the enclosing impl block's
/// parameters and `where` predicates, plus the method's own. Falls back to the
/// struct's parameters when no impl block declares the method.
/// Type parameter names of a wrapper in the struct's parameter order: for
/// `struct S<T>` and `impl<U> S<U>`, the name bound at the struct's `T` position
/// is `U`. Remaining impl/method parameters follow.
fn wrapper_param_names(decl: &syn::Generics, self_ty: &Type) -> Vec<String> {
    let declared: Vec<String> = decl
        .params
        .iter()
        .filter_map(|p| match p {
            syn::GenericParam::Type(tp) => Some(tp.ident.to_string()),
            _ => None,
        })
        .collect();
    let mut ordered: Vec<String> = Vec::new();
    if let Type::Path(tp) = self_ty {
        if let Some(seg) = tp.path.segments.last() {
            if let syn::PathArguments::AngleBracketed(args) = &seg.arguments {
                for a in &args.args {
                    if let syn::GenericArgument::Type(Type::Path(p)) = a {
                        if p.qself.is_none() && p.path.segments.len() == 1 {
                            let n = p.path.segments[0].ident.to_string();
                            if declared.contains(&n) && !ordered.contains(&n) {
                                ordered.push(n);
                            }
                        }
                    }
                }
            }
        }
    }
    for n in declared {
        if !ordered.contains(&n) {
            ordered.push(n);
        }
    }
    ordered
}

fn wrapper_generics(
    model: &StructModel,
    m: &MethodModel,
) -> (syn::Generics, Option<syn::WhereClause>, Type) {
    let owner = model.impls.iter().find(|imp| {
        imp.items
            .iter()
            .any(|ii| matches!(ii, syn::ImplItem::Fn(f) if f.sig.ident == m.func.sig.ident))
    });
    // The receiver / constructor type must be spelled with the impl block's own
    // parameter names (`impl<U> Wrapper<U>`), not the struct declaration's.
    let self_ty: Type = match owner {
        Some(imp) => (*imp.self_ty).clone(),
        None => {
            let name = &model.item.ident;
            let (_, ty_generics, _) = model.item.generics.split_for_impl();
            syn::parse_quote!(#name #ty_generics)
        }
    };
    let mut merged = owner
        .map(|imp| imp.generics.clone())
        .unwrap_or_else(|| model.item.generics.clone());
    for p in &m.func.sig.generics.params {
        merged.params.push(p.clone());
    }
    let mut predicates: Vec<syn::WherePredicate> = merged
        .where_clause
        .take()
        .map(|w| w.predicates.into_iter().collect())
        .unwrap_or_default();
    if let Some(w) = &m.func.sig.generics.where_clause {
        predicates.extend(w.predicates.iter().cloned());
    }
    if !merged.params.is_empty() {
        merged.lt_token = Some(Default::default());
        merged.gt_token = Some(Default::default());
    }
    let where_clause = if predicates.is_empty() {
        None
    } else {
        Some(syn::WhereClause {
            where_token: Default::default(),
            predicates: predicates.into_iter().collect(),
        })
    };
    (merged, where_clause, self_ty)
}

fn fn_source(func: ItemFn) -> String {
    let file = syn::File {
        shebang: None,
        attrs: Vec::new(),
        items: vec![syn::Item::Fn(func)],
    };
    prettyplease::unparse(&file)
}

/// Generate the generic wrapper functions of a generic inline struct. They are
/// not compiled into the main library; Julia registers them for on-demand
/// monomorphization through `specialize`.
pub fn inline_generic_wrappers(model: &StructModel) -> Vec<GenericWrapper> {
    let struct_name = &model.item.ident;
    let generics = &model.item.generics;
    let (_, ty_generics, _) = generics.split_for_impl();
    let decl_generics = {
        let mut g = generics.clone();
        g.where_clause = None;
        g
    };
    let mut wrappers = Vec::new();

    for m in &model.methods {
        let method_name = &m.func.sig.ident;
        let wrapper_name = format_ident!("{}_{}", struct_name, method_name);
        // The wrapper must satisfy the bounds the impl block and the method
        // themselves declare (`impl<T: Copy>`, `where T: Copy`, `fn f<U>`).
        let (decl_generics, where_clause, self_ty) = wrapper_generics(model, m);
        let where_clause = where_clause.map(|w| quote! { #w }).unwrap_or_default();
        let mut wrapper_args: Vec<TokenStream2> = Vec::new();
        let mut call_args: Vec<TokenStream2> = Vec::new();
        if !m.is_static {
            if m.is_mutable {
                wrapper_args.push(quote! { ptr: *mut #self_ty });
            } else {
                wrapper_args.push(quote! { ptr: *const #self_ty });
            }
        }
        for (i, arg) in m.func.sig.inputs.iter().enumerate() {
            let FnArg::Typed(pat_type) = arg else {
                continue;
            };
            let ty = &pat_type.ty;
            let name: Ident = match pat_type.pat.as_ref() {
                Pat::Ident(pi) => pi.ident.clone(),
                _ => format_ident!("arg{}", i),
            };
            wrapper_args.push(quote! { #name: #ty });
            call_args.push(quote! { #name });
        }
        let is_ctor = inline_method_is_ctor(struct_name, m);
        let func: ItemFn = if is_ctor {
            syn::parse_quote! {
                pub fn #wrapper_name #decl_generics (#(#wrapper_args),*) -> *mut #self_ty #where_clause {
                    let obj = #struct_name::#method_name(#(#call_args),*);
                    Box::into_raw(Box::new(obj))
                }
            }
        } else {
            let ret = &m.func.sig.output;
            if m.is_static {
                syn::parse_quote! {
                    pub fn #wrapper_name #decl_generics (#(#wrapper_args),*) #ret #where_clause {
                        #struct_name::#method_name(#(#call_args),*)
                    }
                }
            } else if m.is_mutable {
                syn::parse_quote! {
                    pub fn #wrapper_name #decl_generics (#(#wrapper_args),*) #ret #where_clause {
                        let self_obj = unsafe { &mut *ptr };
                        self_obj.#method_name(#(#call_args),*)
                    }
                }
            } else {
                syn::parse_quote! {
                    pub fn #wrapper_name #decl_generics (#(#wrapper_args),*) #ret #where_clause {
                        let self_obj = unsafe { &*ptr };
                        self_obj.#method_name(#(#call_args),*)
                    }
                }
            }
        };
        wrappers.push(GenericWrapper {
            name: wrapper_name.to_string(),
            source: fn_source(func),
            type_params: wrapper_param_names(&decl_generics, &self_ty),
        });
    }

    // Accessor and free wrappers are emitted generically into the expanded
    // source, so they must type-check for every `T`: carry the struct's own
    // `where` predicates and state what the getter body needs (`Copy` to read
    // the field out through the raw pointer, `Clone` for String/Vec).
    let struct_predicates: Vec<syn::WherePredicate> = generics
        .where_clause
        .as_ref()
        .map(|w| w.predicates.iter().cloned().collect())
        .unwrap_or_default();
    let where_of = |extra: Option<syn::WherePredicate>| -> TokenStream2 {
        let mut preds = struct_predicates.clone();
        preds.extend(extra);
        if preds.is_empty() {
            quote! {}
        } else {
            quote! { where #(#preds),* }
        }
    };
    let struct_where = where_of(None);

    let struct_param_names: Vec<String> = generics
        .params
        .iter()
        .filter_map(|p| match p {
            syn::GenericParam::Type(tp) => Some(tp.ident.to_string()),
            _ => None,
        })
        .collect();
    let method_symbols: Vec<String> = wrappers.iter().map(|w| w.name.clone()).collect();
    for (field_name, field_ty) in model.named_fields() {
        if !is_inline_accessible_field_type(&field_ty) {
            continue;
        }
        let getter = format_ident!("{}_get_{}", struct_name, field_name);
        if method_symbols.contains(&getter.to_string()) {
            continue;
        }
        let setter = format_ident!("{}_set_{}", struct_name, field_name);
        let (body, getter_where) = if is_string_type(&field_ty) || is_vec_type(&field_ty) {
            (
                quote! { unsafe { (*ptr).#field_name.clone() } },
                where_of(Some(syn::parse_quote!(#field_ty: Clone))),
            )
        } else {
            (
                quote! { unsafe { (*ptr).#field_name } },
                where_of(Some(syn::parse_quote!(#field_ty: Copy))),
            )
        };
        let g: ItemFn = syn::parse_quote! {
            pub fn #getter #decl_generics (ptr: *const #struct_name #ty_generics) -> #field_ty #getter_where { #body }
        };
        let s: ItemFn = syn::parse_quote! {
            pub fn #setter #decl_generics (ptr: *mut #struct_name #ty_generics, value: #field_ty) #struct_where {
                unsafe { (*ptr).#field_name = value; }
            }
        };
        wrappers.push(GenericWrapper {
            name: getter.to_string(),
            source: fn_source(g),
            type_params: struct_param_names.clone(),
        });
        wrappers.push(GenericWrapper {
            name: setter.to_string(),
            source: fn_source(s),
            type_params: struct_param_names.clone(),
        });
    }

    let free_name = format_ident!("{}_free", struct_name);
    let f: ItemFn = syn::parse_quote! {
        pub fn #free_name #decl_generics (ptr: *mut #struct_name #ty_generics) #struct_where {
            if !ptr.is_null() {
                unsafe { drop(Box::from_raw(ptr)); }
            }
        }
    };
    wrappers.push(GenericWrapper {
        name: free_name.to_string(),
        source: fn_source(f),
        type_params: struct_param_names,
    });

    wrappers
}
