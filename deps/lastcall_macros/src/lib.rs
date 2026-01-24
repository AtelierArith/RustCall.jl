//! Proc macros for LastCall.jl - Julia-Rust FFI
//!
//! This crate provides the `#[julia]` attribute macro that simplifies creating
//! FFI-compatible functions and structs for use with Julia through LastCall.jl.
//!
//! # Usage
//!
//! ## Functions
//!
//! The `#[julia]` attribute on functions expands to `#[no_mangle] pub extern "C"`:
//!
//! ```rust,ignore
//! use lastcall_macros::julia;
//!
//! #[julia]
//! fn add(a: i32, b: i32) -> i32 {
//!     a + b
//! }
//! ```
//!
//! This expands to:
//!
//! ```rust,ignore
//! #[no_mangle]
//! pub extern "C" fn add(a: i32, b: i32) -> i32 {
//!     a + b
//! }
//! ```
//!
//! ## Structs
//!
//! The `#[julia]` attribute on structs adds `#[repr(C)]` and generates FFI functions:
//!
//! ```rust,ignore
//! use lastcall_macros::julia;
//!
//! #[julia]
//! pub struct Point {
//!     pub x: f64,
//!     pub y: f64,
//! }
//! ```
//!
//! This generates FFI functions like `Point_new`, `Point_free`, getters, and setters.

use proc_macro::TokenStream;
use proc_macro2::TokenStream as TokenStream2;
use quote::{format_ident, quote};
use syn::{
    Attribute, FnArg, Ident, ItemFn, ItemImpl, ItemStruct, Pat, ReturnType, Type, Visibility,
};

/// Check if a type is FFI-compatible (primitive types that can be passed through C ABI)
fn is_ffi_compatible_type(ty: &Type) -> bool {
    match ty {
        Type::Path(type_path) => {
            if let Some(segment) = type_path.path.segments.last() {
                let type_name = segment.ident.to_string();
                matches!(
                    type_name.as_str(),
                    "i8" | "i16"
                        | "i32"
                        | "i64"
                        | "i128"
                        | "u8"
                        | "u16"
                        | "u32"
                        | "u64"
                        | "u128"
                        | "f32"
                        | "f64"
                        | "bool"
                        | "char"
                        | "usize"
                        | "isize"
                )
            } else {
                false
            }
        }
        Type::Tuple(tuple) if tuple.elems.is_empty() => true, // () is FFI-compatible
        Type::Ptr(_) => true,                                 // Raw pointers are FFI-compatible
        _ => false,
    }
}

/// Check if a type needs cloning for getter (String, Vec, etc.)
fn needs_clone_for_getter(ty: &Type) -> bool {
    match ty {
        Type::Path(type_path) => {
            if let Some(segment) = type_path.path.segments.last() {
                let type_name = segment.ident.to_string();
                matches!(type_name.as_str(), "String" | "Vec")
            } else {
                false
            }
        }
        _ => false,
    }
}

/// The `#[julia]` attribute macro for FFI-compatible functions and structs.
///
/// # For Functions
///
/// Transforms a function to be FFI-compatible by adding `#[no_mangle]` and `extern "C"`.
///
/// ## Example
///
/// ```rust,ignore
/// #[julia]
/// fn add(a: i32, b: i32) -> i32 {
///     a + b
/// }
/// ```
///
/// # For Structs
///
/// Adds `#[repr(C)]` and generates FFI wrapper functions for construction,
/// destruction, and field access.
///
/// ## Example
///
/// ```rust,ignore
/// #[julia]
/// pub struct Point {
///     pub x: f64,
///     pub y: f64,
/// }
/// ```
#[proc_macro_attribute]
pub fn julia(_attr: TokenStream, item: TokenStream) -> TokenStream {
    // Try to parse as a function first
    if let Ok(func) = syn::parse::<ItemFn>(item.clone()) {
        return transform_function(func).into();
    }

    // Try to parse as a struct
    if let Ok(item_struct) = syn::parse::<ItemStruct>(item.clone()) {
        return transform_struct(item_struct).into();
    }

    // Try to parse as an impl block
    if let Ok(item_impl) = syn::parse::<ItemImpl>(item.clone()) {
        return transform_impl(item_impl).into();
    }

    // If nothing matches, return an error
    let item2: TokenStream2 = item.into();
    quote! {
        compile_error!("#[julia] can only be applied to functions, structs, or impl blocks");
        #item2
    }
    .into()
}

/// Transform a function with #[julia] attribute to FFI-compatible form
fn transform_function(mut func: ItemFn) -> TokenStream2 {
    // Check for unsafe functions
    if func.sig.unsafety.is_some() {
        return quote! {
            compile_error!("#[julia] cannot be applied to unsafe functions directly. The function will be made extern \"C\" which has its own safety semantics.");
        };
    }

    // Add #[no_mangle]
    let no_mangle: Attribute = syn::parse_quote!(#[no_mangle]);
    func.attrs.insert(0, no_mangle);

    // Make it pub extern "C"
    func.vis = Visibility::Public(syn::token::Pub::default());
    func.sig.abi = Some(syn::parse_quote!(extern "C"));

    quote! { #func }
}

/// Transform a struct with #[julia] attribute
fn transform_struct(mut item_struct: ItemStruct) -> TokenStream2 {
    let struct_name = &item_struct.ident;
    let _struct_name_str = struct_name.to_string();

    // Add #[repr(C)] attribute
    let repr_c: Attribute = syn::parse_quote!(#[repr(C)]);
    item_struct.attrs.insert(0, repr_c);

    // Make it pub if not already
    item_struct.vis = Visibility::Public(syn::token::Pub::default());

    // Generate FFI wrapper functions
    let mut ffi_functions = TokenStream2::new();

    // Generate _free function
    let free_fn_name = format_ident!("{}_free", struct_name);
    ffi_functions.extend(quote! {
        #[no_mangle]
        pub extern "C" fn #free_fn_name(ptr: *mut #struct_name) {
            if !ptr.is_null() {
                unsafe { drop(Box::from_raw(ptr)); }
            }
        }
    });

    // Generate field accessors for named fields
    if let syn::Fields::Named(ref fields) = item_struct.fields {
        for field in &fields.named {
            if let Some(ref field_name) = field.ident {
                let field_ty = &field.ty;

                // Only generate accessors for FFI-compatible types
                if is_ffi_compatible_type(field_ty) || needs_clone_for_getter(field_ty) {
                    // Getter
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

                    // Setter
                    let setter_name = format_ident!("{}_set_{}", struct_name, field_name);
                    ffi_functions.extend(quote! {
                        #[no_mangle]
                        pub extern "C" fn #setter_name(ptr: *mut #struct_name, value: #field_ty) {
                            unsafe { (*ptr).#field_name = value; }
                        }
                    });
                }
            }
        }
    }

    quote! {
        #item_struct

        #ffi_functions
    }
}

/// Transform an impl block with #[julia] attribute on methods
fn transform_impl(mut item_impl: ItemImpl) -> TokenStream2 {
    let self_ty = &item_impl.self_ty;

    // Extract the struct name from the type
    let struct_name = match self_ty.as_ref() {
        Type::Path(type_path) => {
            type_path.path.segments.last().map(|s| s.ident.clone())
        }
        _ => None,
    };

    let struct_name = match struct_name {
        Some(name) => name,
        None => {
            return quote! {
                compile_error!("#[julia] on impl block requires a simple type path");
            }
        }
    };

    let mut ffi_wrappers = TokenStream2::new();

    // Process each method in the impl block
    for item in &mut item_impl.items {
        if let syn::ImplItem::Fn(method) = item {
            // Check if method has #[julia] attribute
            let has_julia_attr = method
                .attrs
                .iter()
                .any(|attr| attr.path().is_ident("julia"));

            if has_julia_attr {
                // Remove #[julia] attribute from the method
                method.attrs.retain(|attr| !attr.path().is_ident("julia"));

                // Generate FFI wrapper for this method
                let wrapper = generate_method_wrapper(&struct_name, method);
                ffi_wrappers.extend(wrapper);
            }
        }
    }

    quote! {
        #item_impl

        #ffi_wrappers
    }
}

/// Generate FFI wrapper for a method
fn generate_method_wrapper(struct_name: &Ident, method: &syn::ImplItemFn) -> TokenStream2 {
    let method_name = &method.sig.ident;
    let method_name_str = method_name.to_string();
    let wrapper_name = format_ident!("{}_{}", struct_name, method_name);

    // Analyze the method signature
    let is_static = !method.sig.inputs.iter().any(|arg| matches!(arg, FnArg::Receiver(_)));

    let is_constructor = method_name_str == "new"
        || matches!(
            &method.sig.output,
            ReturnType::Type(_, ty) if is_self_type(ty, struct_name)
        );

    let _is_mutable = method.sig.inputs.iter().any(|arg| {
        matches!(arg, FnArg::Receiver(r) if r.mutability.is_some())
    });

    // Build wrapper arguments
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

    // Determine return type handling
    let return_type = &method.sig.output;

    if is_constructor {
        // Constructor: returns *mut StructName
        quote! {
            #[no_mangle]
            pub extern "C" fn #wrapper_name(#(#wrapper_args),*) -> *mut #struct_name {
                let obj = #struct_name::#method_name(#(#call_args),*);
                Box::into_raw(Box::new(obj))
            }
        }
    } else if is_static {
        // Static method
        match return_type {
            ReturnType::Default => {
                quote! {
                    #[no_mangle]
                    pub extern "C" fn #wrapper_name(#(#wrapper_args),*) {
                        #struct_name::#method_name(#(#call_args),*);
                    }
                }
            }
            ReturnType::Type(_, ty) => {
                if is_self_type(ty, struct_name) {
                    // Returns Self, box it
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
        // Instance method
        match return_type {
            ReturnType::Default => {
                quote! {
                    #[no_mangle]
                    pub extern "C" fn #wrapper_name(#(#wrapper_args),*) {
                        #self_handling
                        self_ref.#method_name(#(#call_args),*);
                    }
                }
            }
            ReturnType::Type(_, ty) => {
                if is_self_type(ty, struct_name) {
                    // Returns Self, box it
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

/// Check if a type is Self or the struct name
fn is_self_type(ty: &Type, struct_name: &Ident) -> bool {
    match ty {
        Type::Path(type_path) => {
            if let Some(segment) = type_path.path.segments.last() {
                segment.ident == "Self" || segment.ident == *struct_name
            } else {
                false
            }
        }
        _ => false,
    }
}
