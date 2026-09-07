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
/// **Deprecated** (RustCall.jl #275, Phase 3). `#[julia]` is additive since
/// #279 — it keeps the annotated item exactly as written and emits the C entry
/// point next to it — so it composes with PyO3's own attributes, which do the
/// Python half properly (options, `#[new]`, `#[getter]`, `#[pyo3(name = ...)]`,
/// …) where this macro could only guess. Write, instead of `#[julia_pyo3]`:
///
/// | item | replacement |
/// | --- | --- |
/// | function | `#[julia] #[cfg_attr(feature = "python", pyo3::pyfunction)] pub fn f(...)` |
/// | struct | `#[julia] #[cfg_attr(feature = "python", pyo3::pyclass(get_all, set_all))] pub struct S { ... }` |
/// | impl block | `#[julia] impl S { #[julia] pub fn m(...) }` for Julia, plus a `#[cfg(feature = "python")] #[pyo3::pymethods] impl S { ... }` written as PyO3 code (`#[new]`, `#[pyo3(name = "...")]`) that delegates to the Rust methods — pyo3's inner attributes cannot be gated with `cfg_attr` |
///
/// The macro still expands as it always did — Julia FFI bindings when the
/// downstream `python` feature is off, PyO3 bindings when it is on — and the
/// `rustcall-extract` manifest keeps reporting its items under the
/// `julia_pyo3` origin, so existing crates keep building; rustc reports
/// `use of deprecated macro` at every use site. It is removed in the next
/// breaking release. See `docs/src/pyo3.md`, "Migrating from `#[julia_pyo3]`".
#[deprecated(
    note = "`#[julia_pyo3]` is deprecated (RustCall.jl #275 Phase 3) and will be removed: write \
            `#[julia]` next to PyO3's own attributes — `#[julia] #[cfg_attr(feature = \"python\", \
            pyo3::pyfunction)]` on a function, `#[julia] #[cfg_attr(feature = \"python\", \
            pyo3::pyclass(get_all, set_all))]` on a struct, and a `#[cfg(feature = \"python\")] \
            #[pyo3::pymethods] impl` next to the `#[julia] impl` for methods. See docs/src/pyo3.md, \
            \"Migrating from #[julia_pyo3]\"."
)]
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
