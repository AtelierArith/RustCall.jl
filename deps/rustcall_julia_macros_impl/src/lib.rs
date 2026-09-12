//! The proc-macro implementation behind `rustcall_julia_macros`.
//!
//! Do not depend on this crate directly: it is an implementation detail, a
//! proc-macro crate can export nothing but proc macros, and the `#[julia]`
//! wrappers it emits name `::rustcall_julia_macros` for their boundary guard
//! (RustCall.jl #304). Use `rustcall_julia_macros`, which re-exports
//! [`julia`] and carries that runtime state.

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
        // `PanicHook::Runtime`: this is the proc macro, handed one item of a
        // crate RustCall does not write, so it cannot emit the crate-wide
        // quiet-hook state — it takes the guard from `rustcall_julia_macros`,
        // the crate `#[julia]` itself came from, which the user therefore
        // already depends on (#304).
        return codegen::transform_function(func, &[], codegen::PanicHook::Runtime).into();
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
