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
//! ## Functions with Result/Option
//!
//! Functions returning `Result<T, E>` or `Option<T>` are automatically wrapped:
//!
//! ```rust,ignore
//! use lastcall_macros::julia;
//!
//! #[julia]
//! fn safe_divide(a: f64, b: f64) -> Option<f64> {
//!     if b == 0.0 { None } else { Some(a / b) }
//! }
//!
//! #[julia]
//! fn parse_number(s: i32) -> Result<i32, i32> {
//!     if s >= 0 { Ok(s * 2) } else { Err(-1) }
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
    Attribute, FnArg, GenericArgument, Ident, ItemFn, ItemImpl, ItemStruct, Pat, PathArguments,
    ReturnType, Type, Visibility,
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

/// Information about a Result<T, E> type
struct ResultTypeInfo {
    ok_type: Type,
    err_type: Type,
}

/// Information about an Option<T> type
struct OptionTypeInfo {
    inner_type: Type,
}

/// Check if a type is Result<T, E> and extract the type parameters
fn extract_result_type(ty: &Type) -> Option<ResultTypeInfo> {
    match ty {
        Type::Path(type_path) => {
            if let Some(segment) = type_path.path.segments.last() {
                if segment.ident == "Result" {
                    if let PathArguments::AngleBracketed(args) = &segment.arguments {
                        let mut types = args.args.iter().filter_map(|arg| {
                            if let GenericArgument::Type(t) = arg {
                                Some(t.clone())
                            } else {
                                None
                            }
                        });
                        if let (Some(ok_type), Some(err_type)) = (types.next(), types.next()) {
                            return Some(ResultTypeInfo { ok_type, err_type });
                        }
                    }
                }
            }
            None
        }
        _ => None,
    }
}

/// Check if a type is Option<T> and extract the inner type
fn extract_option_type(ty: &Type) -> Option<OptionTypeInfo> {
    match ty {
        Type::Path(type_path) => {
            if let Some(segment) = type_path.path.segments.last() {
                if segment.ident == "Option" {
                    if let PathArguments::AngleBracketed(args) = &segment.arguments {
                        if let Some(GenericArgument::Type(inner_type)) = args.args.first() {
                            return Some(OptionTypeInfo {
                                inner_type: inner_type.clone(),
                            });
                        }
                    }
                }
            }
            None
        }
        _ => None,
    }
}

/// Generate C-compatible Result type definition for a specific T, E
fn generate_c_result_type(func_name: &Ident, ok_type: &Type, err_type: &Type) -> TokenStream2 {
    let result_type_name = format_ident!("CResult_{}", func_name);

    quote! {
        #[repr(C)]
        pub struct #result_type_name {
            pub is_ok: u8,
            pub ok_value: #ok_type,
            pub err_value: #err_type,
        }
    }
}

/// Generate C-compatible Option type definition for a specific T
fn generate_c_option_type(func_name: &Ident, inner_type: &Type) -> TokenStream2 {
    let option_type_name = format_ident!("COption_{}", func_name);

    quote! {
        #[repr(C)]
        pub struct #option_type_name {
            pub is_some: u8,
            pub value: #inner_type,
        }
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
fn transform_function(func: ItemFn) -> TokenStream2 {
    // Check for unsafe functions
    if func.sig.unsafety.is_some() {
        return quote! {
            compile_error!("#[julia] cannot be applied to unsafe functions directly. The function will be made extern \"C\" which has its own safety semantics.");
        };
    }

    // Check if the return type is Result<T, E> or Option<T>
    if let ReturnType::Type(_, ref ret_type) = func.sig.output {
        if let Some(result_info) = extract_result_type(ret_type) {
            return transform_result_function(func, result_info);
        }
        if let Some(option_info) = extract_option_type(ret_type) {
            return transform_option_function(func, option_info);
        }
    }

    // Standard function transformation
    transform_simple_function(func)
}

/// Transform a simple function (no Result/Option) to FFI-compatible form
fn transform_simple_function(mut func: ItemFn) -> TokenStream2 {
    // Add #[no_mangle]
    let no_mangle: Attribute = syn::parse_quote!(#[no_mangle]);
    func.attrs.insert(0, no_mangle);

    // Make it pub extern "C"
    func.vis = Visibility::Public(syn::token::Pub::default());
    func.sig.abi = Some(syn::parse_quote!(extern "C"));

    quote! { #func }
}

/// Transform a function returning Result<T, E> to FFI-compatible form
fn transform_result_function(func: ItemFn, result_info: ResultTypeInfo) -> TokenStream2 {
    let func_name = &func.sig.ident;
    let ok_type = &result_info.ok_type;
    let err_type = &result_info.err_type;

    // Generate C-compatible result type
    let c_result_type = generate_c_result_type(func_name, ok_type, err_type);
    let result_type_name = format_ident!("CResult_{}", func_name);

    // Collect function arguments
    let args: Vec<_> = func.sig.inputs.iter().collect();
    let arg_names: Vec<_> = func
        .sig
        .inputs
        .iter()
        .filter_map(|arg| {
            if let FnArg::Typed(pat_type) = arg {
                if let Pat::Ident(pat_ident) = pat_type.pat.as_ref() {
                    return Some(pat_ident.ident.clone());
                }
            }
            None
        })
        .collect();

    // Get the original function body
    let body = &func.block;

    // Create the inner function that returns Result
    let inner_fn_name = format_ident!("{}_inner", func_name);
    let inner_fn_args = &func.sig.inputs;

    quote! {
        #c_result_type

        fn #inner_fn_name(#inner_fn_args) -> Result<#ok_type, #err_type> #body

        #[no_mangle]
        pub extern "C" fn #func_name(#(#args),*) -> #result_type_name {
            match #inner_fn_name(#(#arg_names),*) {
                Ok(value) => #result_type_name {
                    is_ok: 1,
                    ok_value: value,
                    err_value: unsafe { std::mem::zeroed() },
                },
                Err(err) => #result_type_name {
                    is_ok: 0,
                    ok_value: unsafe { std::mem::zeroed() },
                    err_value: err,
                },
            }
        }
    }
}

/// Transform a function returning Option<T> to FFI-compatible form
fn transform_option_function(func: ItemFn, option_info: OptionTypeInfo) -> TokenStream2 {
    let func_name = &func.sig.ident;
    let inner_type = &option_info.inner_type;

    // Generate C-compatible option type
    let c_option_type = generate_c_option_type(func_name, inner_type);
    let option_type_name = format_ident!("COption_{}", func_name);

    // Collect function arguments
    let args: Vec<_> = func.sig.inputs.iter().collect();
    let arg_names: Vec<_> = func
        .sig
        .inputs
        .iter()
        .filter_map(|arg| {
            if let FnArg::Typed(pat_type) = arg {
                if let Pat::Ident(pat_ident) = pat_type.pat.as_ref() {
                    return Some(pat_ident.ident.clone());
                }
            }
            None
        })
        .collect();

    // Get the original function body
    let body = &func.block;

    // Create the inner function that returns Option
    let inner_fn_name = format_ident!("{}_inner", func_name);
    let inner_fn_args = &func.sig.inputs;

    quote! {
        #c_option_type

        fn #inner_fn_name(#inner_fn_args) -> Option<#inner_type> #body

        #[no_mangle]
        pub extern "C" fn #func_name(#(#args),*) -> #option_type_name {
            match #inner_fn_name(#(#arg_names),*) {
                Some(value) => #option_type_name {
                    is_some: 1,
                    value,
                },
                None => #option_type_name {
                    is_some: 0,
                    value: unsafe { std::mem::zeroed() },
                },
            }
        }
    }
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
        Type::Path(type_path) => type_path.path.segments.last().map(|s| s.ident.clone()),
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
    let is_static = !method
        .sig
        .inputs
        .iter()
        .any(|arg| matches!(arg, FnArg::Receiver(_)));

    let is_constructor = method_name_str == "new"
        || matches!(
            &method.sig.output,
            ReturnType::Type(_, ty) if is_self_type(ty, struct_name)
        );

    let _is_mutable = method
        .sig
        .inputs
        .iter()
        .any(|arg| matches!(arg, FnArg::Receiver(r) if r.mutability.is_some()));

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

// ============================================================================
// #[julia_pyo3] - Unified macro for Julia + Python bindings
// ============================================================================

/// The `#[julia_pyo3]` attribute macro for unified Julia + Python bindings.
///
/// This macro generates both Julia FFI bindings (always) and Python/PyO3 bindings
/// (when the `python` feature is enabled in the downstream crate).
///
/// # For Functions
///
/// ```rust,ignore
/// #[julia_pyo3]
/// fn add(a: i32, b: i32) -> i32 {
///     a + b
/// }
/// ```
///
/// This generates:
/// - Julia: `#[no_mangle] pub extern "C" fn add(...)`
/// - Python (with feature): `#[pyfunction] fn add(...)`
///
/// # For Structs
///
/// ```rust,ignore
/// #[julia_pyo3]
/// pub struct Point {
///     pub x: f64,
///     pub y: f64,
/// }
/// ```
///
/// This generates:
/// - Julia: `#[repr(C)]` struct + FFI functions (Point_free, Point_get_x, etc.)
/// - Python (with feature): `#[pyclass(get_all, set_all)]`
///
/// # For Impl Blocks
///
/// ```rust,ignore
/// #[julia_pyo3]
/// impl Point {
///     pub fn new(x: f64, y: f64) -> Self { ... }
///     pub fn distance(&self) -> f64 { ... }
/// }
/// ```
///
/// This generates:
/// - Julia: FFI wrapper functions (Point_new, Point_distance)
/// - Python (with feature): `#[pymethods]` impl block with `#[new]` for constructors
#[proc_macro_attribute]
pub fn julia_pyo3(_attr: TokenStream, item: TokenStream) -> TokenStream {
    // Try to parse as a function first
    if let Ok(func) = syn::parse::<ItemFn>(item.clone()) {
        return transform_function_julia_pyo3(func).into();
    }

    // Try to parse as a struct
    if let Ok(item_struct) = syn::parse::<ItemStruct>(item.clone()) {
        return transform_struct_julia_pyo3(item_struct).into();
    }

    // Try to parse as an impl block
    if let Ok(item_impl) = syn::parse::<ItemImpl>(item.clone()) {
        return transform_impl_julia_pyo3(item_impl).into();
    }

    // If nothing matches, return an error
    let item2: TokenStream2 = item.into();
    quote! {
        compile_error!("#[julia_pyo3] can only be applied to functions, structs, or impl blocks");
        #item2
    }
    .into()
}

/// Transform a function with #[julia_pyo3] attribute
/// Generates Julia FFI (when python feature OFF) or Python pyfunction (when python feature ON)
fn transform_function_julia_pyo3(func: ItemFn) -> TokenStream2 {
    let func_attrs = &func.attrs;
    let func_sig = &func.sig;
    let func_block = &func.block;

    // Check for Result/Option return types - delegate to existing handlers for Julia
    // (Python builds will use the pyfunction version which handles these natively)
    if let ReturnType::Type(_, ref ret_type) = func.sig.output {
        if extract_result_type(ret_type).is_some() || extract_option_type(ret_type).is_some() {
            // For Result/Option types, use cfg to switch between Julia and Python handling
            return quote! {
                // Julia FFI version with C-compatible Result/Option wrapper
                #[cfg(not(feature = "python"))]
                #(#func_attrs)*
                #[no_mangle]
                pub extern "C" #func_sig #func_block

                // Python version - PyO3 handles Result/Option natively
                #[cfg(feature = "python")]
                #[pyo3::pyfunction]
                pub #func_sig #func_block
            };
        }
    }

    // For simple types, generate both versions with cfg
    quote! {
        // Julia FFI version (when python feature is OFF)
        #[cfg(not(feature = "python"))]
        #(#func_attrs)*
        #[no_mangle]
        pub extern "C" #func_sig #func_block

        // Python version (when python feature is ON)
        #[cfg(feature = "python")]
        #[pyo3::pyfunction]
        pub #func_sig #func_block
    }
}

/// Transform a struct with #[julia_pyo3] attribute
fn transform_struct_julia_pyo3(mut item_struct: ItemStruct) -> TokenStream2 {
    let struct_name = &item_struct.ident;

    // Add #[repr(C)] attribute
    let repr_c: Attribute = syn::parse_quote!(#[repr(C)]);
    item_struct.attrs.insert(0, repr_c);

    // Make it pub if not already
    item_struct.vis = Visibility::Public(syn::token::Pub::default());

    // Generate Julia FFI wrapper functions
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

    // Generate output with conditional PyO3 attributes
    quote! {
        #[cfg_attr(feature = "python", pyo3::pyclass(get_all, set_all))]
        #item_struct

        #ffi_functions
    }
}

/// Transform an impl block with #[julia_pyo3] attribute
fn transform_impl_julia_pyo3(item_impl: ItemImpl) -> TokenStream2 {
    let self_ty = &item_impl.self_ty;

    // Extract the struct name from the type
    let struct_name = match self_ty.as_ref() {
        Type::Path(type_path) => type_path.path.segments.last().map(|s| s.ident.clone()),
        _ => None,
    };

    let struct_name = match struct_name {
        Some(name) => name,
        None => {
            return quote! {
                compile_error!("#[julia_pyo3] on impl block requires a simple type path");
            }
        }
    };

    let mut julia_ffi_wrappers = TokenStream2::new();
    let mut pyo3_methods = TokenStream2::new();

    // Process each method
    for item in &item_impl.items {
        if let syn::ImplItem::Fn(method) = item {
            // Generate Julia FFI wrapper
            let julia_wrapper = generate_method_wrapper_pyo3(&struct_name, method);
            julia_ffi_wrappers.extend(julia_wrapper);

            // Generate PyO3 method variant
            let pyo3_method = generate_pyo3_method_impl(method);
            pyo3_methods.extend(pyo3_method);
        }
    }

    // Output:
    // 1. Original impl block when python feature is OFF
    // 2. #[pymethods] impl block when python feature is ON
    // 3. Julia FFI wrappers (always)
    //
    // We use cfg to switch between regular and pymethods impl to avoid duplicate definitions
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

/// Generate a PyO3-compatible method for the #[pymethods] impl block
fn generate_pyo3_method_impl(method: &syn::ImplItemFn) -> TokenStream2 {
    let method_name = &method.sig.ident;
    let method_name_str = method_name.to_string();
    let method_vis = &method.vis;
    let method_attrs = &method.attrs;
    let method_block = &method.block;

    // Check if method is a static method (no self receiver)
    let is_static = !method
        .sig
        .inputs
        .iter()
        .any(|arg| matches!(arg, FnArg::Receiver(_)));

    // Only "new" static method is treated as PyO3 constructor
    let is_pyo3_constructor = method_name_str == "new" && is_static;

    // Get the method signature
    let method_sig = &method.sig;

    if is_pyo3_constructor {
        // Constructor - add #[new] attribute
        quote! {
            #(#method_attrs)*
            #[new]
            #method_vis #method_sig #method_block
        }
    } else {
        // Regular method - keep as is
        quote! {
            #(#method_attrs)*
            #method_vis #method_sig #method_block
        }
    }
}

/// Generate FFI wrapper for a method (for julia_pyo3)
fn generate_method_wrapper_pyo3(struct_name: &Ident, method: &syn::ImplItemFn) -> TokenStream2 {
    let method_name = &method.sig.ident;
    let method_name_str = method_name.to_string();
    let wrapper_name = format_ident!("{}_{}", struct_name, method_name);

    // Analyze the method signature
    let is_static = !method
        .sig
        .inputs
        .iter()
        .any(|arg| matches!(arg, FnArg::Receiver(_)));

    // A constructor must be STATIC (no &self) AND either named "new" or return Self
    let is_constructor = is_static
        && (method_name_str == "new"
            || matches!(
                &method.sig.output,
                ReturnType::Type(_, ty) if is_self_type(ty, struct_name)
            ));

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
        // Constructor: static method that returns Self, returns *mut StructName
        quote! {
            #[no_mangle]
            pub extern "C" fn #wrapper_name(#(#wrapper_args),*) -> *mut #struct_name {
                let obj = #struct_name::#method_name(#(#call_args),*);
                Box::into_raw(Box::new(obj))
            }
        }
    } else if is_static {
        // Other static methods (not returning Self)
        match return_type {
            ReturnType::Default => {
                quote! {
                    #[no_mangle]
                    pub extern "C" fn #wrapper_name(#(#wrapper_args),*) {
                        #struct_name::#method_name(#(#call_args),*);
                    }
                }
            }
            ReturnType::Type(_, _) => {
                quote! {
                    #[no_mangle]
                    pub extern "C" fn #wrapper_name(#(#wrapper_args),*) #return_type {
                        #struct_name::#method_name(#(#call_args),*)
                    }
                }
            }
        }
    } else {
        // Instance methods (have &self or &mut self)
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
                    // Instance method returning Self -> box and return pointer
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
