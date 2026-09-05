//! Proc macros for RustCall.jl - Julia-Rust FFI
//!
//! This crate provides the `#[julia]` attribute macro that simplifies creating
//! FFI-compatible functions and structs for use with Julia through RustCall.jl.
//!
//! All code generation lives in the `rustcall_core` crate, which is shared with
//! the `rustcall-extract` CLI used for inline `rust"""` blocks. This crate is a
//! thin adapter so that both front ends emit identical wrappers.
//!
//! # Usage
//!
//! ## Functions
//!
//! `#[julia]` is **additive** (#279): the annotated item is kept exactly as
//! written and a `#[no_mangle] pub extern "C" fn rustcall_<name>` wrapper that
//! calls it is emitted next to it. The function therefore still has its own
//! Rust signature for in-crate callers, `#[test]`s and other proc-macros such
//! as `#[pyfunction]`, while Julia calls the `rustcall_`-prefixed symbol
//! recorded in the manifest.
//!
//! ```rust,ignore
//! use juliacall_macros::julia;
//!
//! #[julia]
//! fn add(a: i32, b: i32) -> i32 {
//!     a + b
//! }
//! ```
//!
//! ## Functions with Result/Option
//!
//! Functions returning `Result<T, E>` or `Option<T>` are automatically wrapped
//! into C-compatible `CResult_<fn>` / `COption_<fn>` structs.
//!
//! ## Structs
//!
//! The `#[julia]` attribute on structs adds `#[repr(C)]` and generates FFI functions
//! like `Point_free`, getters, and setters. `#[julia]` on an impl block leaves the
//! methods alone and emits a wrapper next to the block for each method that is
//! itself marked `#[julia]` (`rustcall_Point_new`, `rustcall_Point_distance`, ...).

use proc_macro::TokenStream;
use proc_macro2::TokenStream as TokenStream2;
use quote::quote;
use syn::{ItemFn, ItemImpl, ItemStruct};

use rustcall_core::codegen;

/// The `#[julia]` attribute macro for FFI-compatible functions, structs and impl blocks.
#[proc_macro_attribute]
pub fn julia(_attr: TokenStream, item: TokenStream) -> TokenStream {
    if let Ok(func) = syn::parse::<ItemFn>(item.clone()) {
        return codegen::transform_function(func).into();
    }
    if let Ok(item_struct) = syn::parse::<ItemStruct>(item.clone()) {
        return codegen::transform_struct_crate(item_struct).into();
    }
    if let Ok(item_impl) = syn::parse::<ItemImpl>(item.clone()) {
        return codegen::transform_impl_crate(item_impl).into();
    }

    let item2: TokenStream2 = item.into();
    quote! {
        compile_error!("#[julia] can only be applied to functions, structs, or impl blocks");
        #item2
    }
    .into()
}

/// The `#[julia_pyo3]` attribute macro for unified Julia + Python bindings.
///
/// Generates Julia FFI bindings (always) and Python/PyO3 bindings (when the
/// `python` feature is enabled in the downstream crate).
#[proc_macro_attribute]
pub fn julia_pyo3(_attr: TokenStream, item: TokenStream) -> TokenStream {
    if let Ok(func) = syn::parse::<ItemFn>(item.clone()) {
        return codegen::transform_function_julia_pyo3(func).into();
    }
    if let Ok(item_struct) = syn::parse::<ItemStruct>(item.clone()) {
        return codegen::transform_struct_julia_pyo3(item_struct).into();
    }
    if let Ok(item_impl) = syn::parse::<ItemImpl>(item.clone()) {
        return codegen::transform_impl_julia_pyo3(item_impl).into();
    }

    let item2: TokenStream2 = item.into();
    quote! {
        compile_error!("#[julia_pyo3] can only be applied to functions, structs, or impl blocks");
        #item2
    }
    .into()
}
