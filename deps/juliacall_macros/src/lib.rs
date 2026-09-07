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
//!
//! ## Modules
//!
//! A proc-macro cannot see the module an item sits in, so two `#[julia] fn run`
//! in different modules would both export `rustcall_run`. Mark the **module**
//! as well (RustCall.jl #300):
//!
//! ```rust,ignore
//! #[julia]
//! pub mod a {
//!     #[julia]
//!     pub fn run() -> i32 { 1 }   // exported as `rustcall_a__run`
//! }
//!
//! #[julia]
//! pub mod b {
//!     #[julia]
//!     pub fn run() -> i32 { 2 }   // exported as `rustcall_b__run`
//! }
//! ```
//!
//! `#[julia]` on an inline module expands the `#[julia]` items inside it with
//! the module path folded into every generated symbol (`a__C_free`,
//! `rustcall_a__C_new`, ...); nested marked modules accumulate the path. The
//! attribute cannot be placed on a file module (`mod a;`), and RustCall.jl
//! refuses a `#[julia]` item inside an inline module that is not marked.

use proc_macro::TokenStream;
use proc_macro2::TokenStream as TokenStream2;
use quote::quote;
use syn::{ItemFn, ItemImpl, ItemMod, ItemStruct};

use rustcall_core::codegen;

/// The `#[julia]` attribute macro for FFI-compatible functions, structs, impl
/// blocks and inline modules.
#[proc_macro_attribute]
pub fn julia(_attr: TokenStream, item: TokenStream) -> TokenStream {
    // An item the macro meets directly is at the crate root as far as the
    // symbol scheme is concerned; items inside a `#[julia] mod` are expanded by
    // the module's own expansion with its path (#300).
    if let Ok(func) = syn::parse::<ItemFn>(item.clone()) {
        return codegen::transform_function(func, &[]).into();
    }
    if let Ok(item_struct) = syn::parse::<ItemStruct>(item.clone()) {
        return codegen::transform_struct_crate(item_struct, &[]).into();
    }
    if let Ok(item_impl) = syn::parse::<ItemImpl>(item.clone()) {
        return codegen::transform_impl_crate(item_impl, &[]).into();
    }
    if let Ok(item_mod) = syn::parse::<ItemMod>(item.clone()) {
        return codegen::transform_module(item_mod, &[]).into();
    }

    let item2: TokenStream2 = item.into();
    quote! {
        compile_error!("#[julia] can only be applied to functions, structs, impl blocks, or inline modules");
        #item2
    }
    .into()
}
