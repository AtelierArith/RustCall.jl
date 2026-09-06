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
//! Every `extern "C"` entry point — inline function, crate function,
//! specialized generic instantiation, inline method, crate method,
//! `julia_pyo3` function — is produced by the one generator
//! [`generate_wrapper`]; the public `transform_*` functions are thin adapters
//! that fill in a [`WrapperSpec`]. Adding a flavour therefore cannot lose the
//! string ABI, the `#[cfg]` propagation or the receiver handling again (#279).
//!
//! # `#[julia]` is additive (#279)
//!
//! The annotated item is kept **byte-for-byte**, minus the `#[julia]`
//! attribute itself, and the FFI entry point is emitted *next to it* under a
//! distinct symbol. Every in-crate caller, `#[test]`, `pub use` re-export and
//! other proc-macro (notably `#[pyfunction]`) therefore still sees the Rust
//! signature that was written.
//!
//! # Export-symbol scheme
//!
//! | generated item | symbol |
//! |---|---|
//! | free function `f` | `rustcall_f` |
//! | method / constructor `Struct::m` | `rustcall_Struct_m` |
//! | specialized generic instantiation `f_i32` | `rustcall_f_i32` |
//! | struct destructor | `Struct_free` |
//! | field accessors | `Struct_get_x` / `Struct_set_x` |
//! | clone | `Struct_clone` |
//! | `Result` / `Option` payload | `CResult_f` / `COption_f` |
//! | owned string buffer / release | `<owner>_RustCallOwnedString` / `<owner>_free_rust_string` |
//! | borrowed string view | `<owner>_RustCallBorrowedString` |
//! | panic channel of a wrapper | `<wrapper symbol>_take_panic` |
//!
//! Only the first three wrap a user-written item and so must step aside from
//! its name; `<owner>` is the free function, `<Struct>_<method>` or `<Struct>`
//! the buffer belongs to. The remaining items are purely generated and keep
//! the names they have always had.
//!
//! The scheme is stable and part of artifact identity: the manifest carries it
//! in `Function.symbol` / `Method.symbol` (schema 3) and every Julia-side
//! `ccall` / `dlsym` goes through those fields, never through the Rust name.
//! Inline expansion additionally refuses a block in which a user item already
//! owns a generated symbol (see `crate::expand::symbol_collisions`); the
//! proc-macro sees one item at a time and cannot make that check.

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
    is_string_type, is_vec_type, needs_clone_for_getter, unparen,
};

// ============================================================================
// Export-symbol scheme (#279)
// ============================================================================

/// Prefix of every exported symbol that stands in for a user-written item.
pub const SYMBOL_PREFIX: &str = "rustcall_";

/// Exported symbol of the `extern "C"` wrapper of the free function `name`.
pub fn function_symbol(name: &str) -> String {
    format!("{SYMBOL_PREFIX}{name}")
}

/// Exported symbol of the `extern "C"` wrapper of `Struct::method`.
pub fn method_symbol(struct_name: &str, method: &str) -> String {
    format!("{SYMBOL_PREFIX}{struct_name}_{method}")
}

// ============================================================================
// Signature predicates (shared)
// ============================================================================

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

/// The manifest `return_abi` of a signature: `"string"` (owned buffer),
/// `"str"` (borrowed view) or `""`.
pub fn return_abi(sig: &syn::Signature) -> &'static str {
    if function_returns_string(sig) || returns_copied_str(sig) {
        "string"
    } else if returns_borrowed_str(sig) {
        "str"
    } else {
        ""
    }
}

/// The manifest `abi` of a struct field: `"string"` when the generated getter
/// returns an owned `<Struct>_RustCallOwnedString` buffer (released through
/// `<Struct>_free_rust_string`), `""` when it returns the field as written.
///
/// Both wrapper flavours lower a `String` field the same way, so this depends
/// on the field type alone (#276).
pub fn field_abi(ty: &Type) -> &'static str {
    if is_string_type(ty) {
        "string"
    } else {
        ""
    }
}

/// An identifier the generated wrapper introduces (`s_ptr`, `s_len`, `s_bytes`,
/// `s_cow`, the receiver `ptr`, `self_obj`), chosen so that it never coincides
/// with one of the function's own argument names (`taken`): a trailing
/// underscore is appended until the name is free. `fn f(s: String, s_ptr:
/// usize)` therefore gets `s_ptr_` / `s_len` and keeps the user's `s_ptr`.
fn fresh_ident(base: &str, taken: &[String]) -> Ident {
    let mut name = base.to_string();
    while taken.iter().any(|t| t == &name) {
        name.push('_');
    }
    format_ident!("{}", name)
}

/// Names of every typed argument of a signature. A destructuring pattern
/// (`fn f((a, b): (i32, i32))`) has no name of its own, so the wrapper calls
/// its argument `argN`; the annotated item keeps the pattern, because the
/// wrapper passes the arguments on positionally.
fn typed_arg_names(sig: &syn::Signature) -> Vec<Ident> {
    sig.inputs
        .iter()
        .enumerate()
        .filter_map(|(i, arg)| match arg {
            FnArg::Typed(pat_type) => Some(match pat_type.pat.as_ref() {
                Pat::Ident(pi) => pi.ident.clone(),
                _ => format_ident!("arg{}", i),
            }),
            FnArg::Receiver(_) => None,
        })
        .collect()
}

/// `(name, type)` of every typed argument, in declaration order.
fn arg_pairs(sig: &syn::Signature) -> Vec<(Ident, Type)> {
    sig.inputs
        .iter()
        .filter_map(|a| match a {
            FnArg::Typed(pt) => Some((*pt.ty).clone()),
            FnArg::Receiver(_) => None,
        })
        .zip(typed_arg_names(sig))
        .map(|(ty, name)| (name, ty))
        .collect()
}

/// Wrapper-side view of one argument: `String` / `&str` become a
/// `(ptr, len)` byte pair (`conversion` rebuilds the Rust value under the
/// argument's own name, lossily for invalid UTF-8, never through
/// `from_utf8_unchecked`); everything else is passed through.
fn string_arg_conversion(
    name: &Ident,
    ty: &Type,
    taken: &[String],
) -> (Vec<TokenStream2>, Option<TokenStream2>) {
    if is_string_type(ty) {
        let p = fresh_ident(&format!("{name}_ptr"), taken);
        let l = fresh_ident(&format!("{name}_len"), taken);
        (
            vec![quote! { #p: *const u8 }, quote! { #l: usize }],
            Some(quote! {
                let #name = unsafe {
                    let slice = std::slice::from_raw_parts(#p, #l);
                    String::from_utf8_lossy(slice).into_owned()
                };
            }),
        )
    } else if is_str_ref_type(ty) {
        let p = fresh_ident(&format!("{name}_ptr"), taken);
        let l = fresh_ident(&format!("{name}_len"), taken);
        let b = fresh_ident(&format!("{name}_bytes"), taken);
        let c = fresh_ident(&format!("{name}_cow"), taken);
        (
            vec![quote! { #p: *const u8 }, quote! { #l: usize }],
            Some(quote! {
                let #b = unsafe { std::slice::from_raw_parts(#p, #l) };
                let #c = String::from_utf8_lossy(#b);
                let #name: &str = &#c;
            }),
        )
    } else {
        (vec![quote! { #name: #ty }], None)
    }
}

// ============================================================================
// The one wrapper generator (#279)
// ============================================================================

/// The receiver of a method wrapper: the wrapper takes `*const` / `*mut Struct`
/// and dereferences it into `self_obj`.
pub(crate) struct WrapperReceiver {
    pub ty: Ident,
    pub mutable: bool,
}

/// The item the wrapper calls. Always the original, under its own name.
pub(crate) enum CallTarget {
    /// `f(args)`
    Free(Ident),
    /// `Struct::m(args)`
    Assoc { ty: Ident, method: Ident },
    /// `self_obj.m(args)`
    Instance(Ident),
}

/// How the wrapper hands the value back across the C ABI.
///
/// `syn::Type` is a large enum; the variants carry it by value because a
/// wrapper spec is built once per generated item and immediately consumed.
#[allow(clippy::large_enum_variant)]
pub(crate) enum WrapperReturn {
    /// No return value.
    Unit,
    /// Returned as written.
    Plain(Type),
    /// The value is boxed and returned as `*mut Struct` (constructors and
    /// anything returning `Self`).
    Boxed(Ident),
    /// `<helper> { ptr, len, cap }`, released through `<free>`.
    OwnedString {
        helper: Ident,
        free: Ident,
        /// Whether this wrapper declares the buffer type and its release
        /// function (false when a struct-level helper is shared).
        declare: bool,
    },
    /// `<helper> { ptr, len }` borrowed from the callee.
    BorrowedStr { helper: Ident, declare: bool },
    /// `CResult_<owner> { is_ok, ok_value, err_value }`.
    CResult { name: Ident, ok: Type, err: Type },
    /// `COption_<owner> { is_some, value }`.
    COption { name: Ident, inner: Type },
}

/// Everything [`generate_wrapper`] needs: a signature model plus the call
/// target. Every flavour of `#[julia]` codegen fills this in and so gets
/// identical lowering by construction (#279).
pub(crate) struct WrapperSpec {
    /// Exported symbol, see the module docs.
    pub symbol: Ident,
    /// `#[cfg]` / `#[cfg_attr]` attributes replicated onto every generated item.
    pub cfg_attrs: Vec<Attribute>,
    pub receiver: Option<WrapperReceiver>,
    pub args: Vec<(Ident, Type)>,
    /// Whether `String` / `&str` arguments are lowered to `(ptr, len)` pairs.
    /// Only `#[julia_pyo3]`, which exports the signature as written, says no.
    pub lower_strings: bool,
    pub ret: WrapperReturn,
    pub target: CallTarget,
}

/// Suffix of the panic-channel reader a wrapper exports next to itself.
pub const PANIC_SYMBOL_SUFFIX: &str = "_take_panic";

/// The panic-channel reader of the wrapper exported as `symbol`.
pub fn panic_symbol(symbol: &str) -> String {
    format!("{symbol}{PANIC_SYMBOL_SUFFIX}")
}

/// The per-wrapper panic channel: a thread-local message slot and the
/// `extern "C"` reader Julia polls after every call (#244).
///
/// # Why one channel per wrapper rather than one per crate
///
/// The obvious design — a single `rustcall_take_last_panic` per library —
/// cannot be emitted reliably by a proc macro. `#[julia]` expands one item at a
/// time and has no crate-wide state it may depend on, so "emit these three
/// items exactly once per crate" is either a mutable static in the macro
/// (fragile, and silently produces duplicate symbols when it is wrong) or a
/// convention the user has to follow. Worse, wherever the shared items landed,
/// a wrapper in a *different module* could not name them: a `#[no_mangle]`
/// symbol is not a Rust path, and reaching it would need an `extern "C"`
/// block, which edition 2024 requires to be written `unsafe extern` — so the
/// generated code would depend on the user crate's edition.
///
/// A channel per wrapper has none of those problems: the slot and its reader
/// sit in the same module as the wrapper that writes them, are named after a
/// symbol that is already unique, need no crate-wide coordination and no
/// `extern` block, and make every library self-contained (a generated `cdylib`
/// does not link `rust_helpers`). The cost is one thread-local and one exported
/// symbol per `#[julia]` item.
///
/// # Protocol
///
/// `<symbol>_take_panic(out, cap) -> usize` returns the byte length of the
/// pending message, or 0 when there is none. The slot is cleared **only** when
/// the whole message fitted in `cap`, so a caller that guessed too small a
/// buffer can simply call again with the length it was told. Nothing is
/// allocated across the boundary and there is nothing to free.
fn panic_channel(cfg_attrs: &[Attribute], slot: &Ident, reader: &Ident) -> TokenStream2 {
    quote! {
        #(#cfg_attrs)*
        thread_local! {
            static #slot: ::std::cell::RefCell<::std::option::Option<::std::string::String>> =
                ::std::cell::RefCell::new(::std::option::Option::None);
        }

        #(#cfg_attrs)*
        #[no_mangle]
        pub extern "C" fn #reader(out: *mut u8, cap: usize) -> usize {
            #slot.with(|rustcall_slot| {
                let mut rustcall_slot = rustcall_slot.borrow_mut();
                let rustcall_len = match rustcall_slot.as_ref() {
                    ::std::option::Option::Some(message) => {
                        let bytes = message.as_bytes();
                        if bytes.len() <= cap && !out.is_null() {
                            unsafe {
                                ::std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len());
                            }
                            Some(bytes.len())
                        } else {
                            // Too small a buffer: report the length and keep
                            // the message so the caller can ask again.
                            return bytes.len();
                        }
                    }
                    ::std::option::Option::None => ::std::option::Option::None,
                };
                match rustcall_len {
                    ::std::option::Option::Some(n) => {
                        *rustcall_slot = ::std::option::Option::None;
                        n
                    }
                    ::std::option::Option::None => 0,
                }
            })
        }
    }
}

/// The body of a generated wrapper, with the user's code inside
/// `catch_unwind`.
///
/// A panic no longer crosses `extern "C"` at all: it is caught, its message is
/// recorded in this wrapper's channel, and a sentinel of the right shape is
/// returned. Julia reads the channel after the call and raises
/// `RustCall.RustPanicError` — the process survives and the failure is
/// catchable, which is what #244 asks for.
///
/// The prologue (string argument conversion, receiver binding) runs *inside*
/// the closure: converting a `(ptr, len)` pair can itself panic, and that panic
/// must be contained too.
///
/// `AssertUnwindSafe` is required because the closure captures raw pointers and
/// `&mut` receivers. The assertion is sound for the use RustCall makes of it:
/// on the unwind path the sentinel is returned to Julia, which raises
/// immediately, so no Rust code observes a value the panic may have left
/// half-updated. What the *user's* `&mut self` looks like afterwards is their
/// business — the object is still theirs, and the exception says so.
fn guarded_body(
    julia_name: &str,
    slot: &Ident,
    prologue: &TokenStream2,
    body: TokenStream2,
    sentinel: TokenStream2,
    returns_unit: bool,
) -> TokenStream2 {
    // A unit-returning wrapper must not *evaluate* to `()`: clippy's
    // `unused_unit` fires on the generated `Ok(v) => v` arm, and the match is a
    // statement there anyway.
    let ok_arm = if returns_unit {
        quote! { ::std::result::Result::Ok(_) => {} }
    } else {
        quote! { ::std::result::Result::Ok(rustcall_value) => rustcall_value, }
    };
    quote! {
        match ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| {
            #prologue
            #body
        })) {
            #ok_arm
            ::std::result::Result::Err(rustcall_payload) => {
                // `panic!("...")` with a literal gives `&'static str`; with
                // arguments, `String`. Anything else came from
                // `panic_any` and has no text.
                let rustcall_message: ::std::string::String =
                    if let ::std::option::Option::Some(s) =
                        rustcall_payload.downcast_ref::<&'static str>()
                    {
                        ::std::string::ToString::to_string(s)
                    } else if let ::std::option::Option::Some(s) =
                        rustcall_payload.downcast_ref::<::std::string::String>()
                    {
                        s.clone()
                    } else {
                        ::std::string::ToString::to_string("Box<dyn Any>")
                    };
                let rustcall_message = ::std::format!(
                    "{} panicked: {}", #julia_name, rustcall_message);
                #slot.with(|rustcall_slot| {
                    *rustcall_slot.borrow_mut() =
                        ::std::option::Option::Some(rustcall_message);
                });
                #sentinel
            }
        }
    }
}

/// The single `extern "C"` wrapper generator: every entry point of this module
/// goes through it, so the string ABI, the `#[cfg]` propagation, the receiver
/// handling and the panic boundary cannot diverge between flavours.
pub(crate) fn generate_wrapper(spec: WrapperSpec) -> TokenStream2 {
    let WrapperSpec {
        symbol,
        cfg_attrs,
        receiver,
        args,
        lower_strings,
        ret,
        target,
    } = spec;

    let taken: Vec<String> = args.iter().map(|(n, _)| n.to_string()).collect();
    let ptr = fresh_ident("ptr", &taken);
    let self_obj = fresh_ident("self_obj", &taken);

    let mut wrapper_args: Vec<TokenStream2> = Vec::new();
    let mut conversions: Vec<TokenStream2> = Vec::new();
    let mut call_args: Vec<TokenStream2> = Vec::new();

    if let Some(r) = &receiver {
        let ty = &r.ty;
        wrapper_args.push(if r.mutable {
            quote! { #ptr: *mut #ty }
        } else {
            quote! { #ptr: *const #ty }
        });
    }
    for (name, ty) in &args {
        if lower_strings {
            let (a, conversion) = string_arg_conversion(name, ty, &taken);
            wrapper_args.extend(a);
            conversions.extend(conversion);
        } else {
            wrapper_args.push(quote! { #name: #ty });
        }
        call_args.push(quote! { #name });
    }

    let self_binding = match &receiver {
        None => quote! {},
        Some(r) if r.mutable => quote! { let #self_obj = unsafe { &mut *#ptr }; },
        Some(_) => quote! { let #self_obj = unsafe { &*#ptr }; },
    };
    let call = match &target {
        CallTarget::Free(name) => quote! { #name(#(#call_args),*) },
        CallTarget::Assoc { ty, method } => quote! { #ty::#method(#(#call_args),*) },
        CallTarget::Instance(method) => quote! { #self_obj.#method(#(#call_args),*) },
    };
    let prologue = quote! { #(#conversions)* #self_binding };

    // The Julia-facing name this wrapper stands for, used in the panic
    // message. Derived from the call target rather than from the symbol, so
    // the message reads `Point::area panicked: ...` and not
    // `rustcall_Point_area panicked: ...`.
    let julia_name = match &target {
        CallTarget::Free(name) => name.to_string(),
        CallTarget::Assoc { ty, method } => format!("{ty}::{method}"),
        CallTarget::Instance(method) => match &receiver {
            Some(r) => format!("{}::{}", r.ty, method),
            None => method.to_string(),
        },
    };
    let slot = format_ident!("__RUSTCALL_PANIC_{}", symbol.to_string().to_uppercase());
    let reader = format_ident!("{}", panic_symbol(&symbol.to_string()));

    let mut out = TokenStream2::new();
    out.extend(panic_channel(&cfg_attrs, &slot, &reader));

    let wrapper = match ret {
        WrapperReturn::Unit => {
            let guarded = guarded_body(
                &julia_name,
                &slot,
                &prologue,
                quote! { #call },
                quote! {},
                true,
            );
            quote! {
                #(#cfg_attrs)*
                #[no_mangle]
                pub extern "C" fn #symbol(#(#wrapper_args),*) {
                    #guarded
                }
            }
        }
        WrapperReturn::Plain(ty) => {
            // A zeroed primitive / raw pointer is the sentinel: Julia raises
            // before it is ever read. Every type that reaches `Plain` is
            // `#[repr(C)]`-compatible and has no niche that makes all-zero
            // invalid (`is_ffi_compatible_type`).
            let sentinel = quote! { unsafe { ::std::mem::zeroed::<#ty>() } };
            let guarded = guarded_body(
                &julia_name,
                &slot,
                &prologue,
                quote! { #call },
                sentinel,
                false,
            );
            quote! {
                #(#cfg_attrs)*
                #[no_mangle]
                pub extern "C" fn #symbol(#(#wrapper_args),*) -> #ty {
                    #guarded
                }
            }
        }
        WrapperReturn::Boxed(ty) => {
            let body = quote! {
                let obj = #call;
                Box::into_raw(Box::new(obj))
            };
            let guarded = guarded_body(
                &julia_name,
                &slot,
                &prologue,
                body,
                quote! { ::std::ptr::null_mut() },
                false,
            );
            quote! {
                #(#cfg_attrs)*
                #[no_mangle]
                pub extern "C" fn #symbol(#(#wrapper_args),*) -> *mut #ty {
                    #guarded
                }
            }
        }
        WrapperReturn::OwnedString {
            helper,
            free,
            declare,
        } => {
            if declare {
                out.extend(owned_string_helper(&cfg_attrs, &helper, &free));
            }
            let body = quote! {
                let rustcall_value = #call;
                // `ToString` covers both `String` and a `&str` result that
                // must be copied because it may borrow from a converted
                // argument (see `returns_copied_str`).
                let mut rustcall_bytes = ToString::to_string(&rustcall_value).into_bytes();
                let rustcall_ret = #helper {
                    ptr: rustcall_bytes.as_mut_ptr(),
                    len: rustcall_bytes.len(),
                    cap: rustcall_bytes.capacity(),
                };
                std::mem::forget(rustcall_bytes);
                rustcall_ret
            };
            // An empty buffer: `ptr` is dangling-but-aligned, `cap == 0`, so
            // the release function is a no-op on it.
            let sentinel = quote! {
                #helper { ptr: ::std::ptr::null_mut(), len: 0, cap: 0 }
            };
            let guarded = guarded_body(&julia_name, &slot, &prologue, body, sentinel, false);
            quote! {
                #(#cfg_attrs)*
                #[no_mangle]
                pub extern "C" fn #symbol(#(#wrapper_args),*) -> #helper {
                    #guarded
                }
            }
        }
        WrapperReturn::BorrowedStr { helper, declare } => {
            if declare {
                out.extend(borrowed_string_helper(&cfg_attrs, &helper));
            }
            let body = quote! {
                let rustcall_value = #call;
                #helper {
                    ptr: rustcall_value.as_ptr(),
                    len: rustcall_value.len(),
                }
            };
            let sentinel = quote! {
                #helper { ptr: ::std::ptr::null(), len: 0 }
            };
            let guarded = guarded_body(&julia_name, &slot, &prologue, body, sentinel, false);
            quote! {
                #(#cfg_attrs)*
                #[no_mangle]
                pub extern "C" fn #symbol(#(#wrapper_args),*) -> #helper {
                    #guarded
                }
            }
        }
        WrapperReturn::CResult { name, ok, err } => {
            out.extend(generate_c_result_type(&name, &ok, &err, &cfg_attrs));
            // `is_ok = 0` with an uninitialized payload: the `Err` branch, and
            // Julia raises before it decodes either payload.
            let sentinel = quote! { #name::panicked() };
            let guarded = guarded_body(
                &julia_name,
                &slot,
                &prologue,
                quote! { #name::new(#call) },
                sentinel,
                false,
            );
            quote! {
                #(#cfg_attrs)*
                #[no_mangle]
                pub extern "C" fn #symbol(#(#wrapper_args),*) -> #name {
                    #guarded
                }
            }
        }
        WrapperReturn::COption { name, inner } => {
            out.extend(generate_c_option_type(&name, &inner, &cfg_attrs));
            let sentinel = quote! { #name::panicked() };
            let guarded = guarded_body(
                &julia_name,
                &slot,
                &prologue,
                quote! { #name::new(#call) },
                sentinel,
                false,
            );
            quote! {
                #(#cfg_attrs)*
                #[no_mangle]
                pub extern "C" fn #symbol(#(#wrapper_args),*) -> #name {
                    #guarded
                }
            }
        }
    };
    out.extend(wrapper);
    out
}

/// The owned string buffer `<name> { ptr, len, cap }` and the `extern "C"`
/// function that releases it (the Rust `Vec` is reconstructed and dropped).
fn owned_string_helper(cfg_attrs: &[Attribute], helper: &Ident, free: &Ident) -> TokenStream2 {
    quote! {
        #(#cfg_attrs)*
        #[repr(C)]
        pub struct #helper {
            pub ptr: *mut u8,
            pub len: usize,
            pub cap: usize,
        }

        #(#cfg_attrs)*
        #[no_mangle]
        pub extern "C" fn #free(ptr: *mut u8, len: usize, cap: usize) {
            if !ptr.is_null() {
                unsafe { drop(Vec::from_raw_parts(ptr, len, cap)); }
            }
        }
    }
}

/// The borrowed string view `<name> { ptr, len }`.
fn borrowed_string_helper(cfg_attrs: &[Attribute], helper: &Ident) -> TokenStream2 {
    quote! {
        #(#cfg_attrs)*
        #[repr(C)]
        pub struct #helper {
            pub ptr: *const u8,
            pub len: usize,
        }
    }
}

fn generate_c_result_type(
    name: &Ident,
    ok_type: &Type,
    err_type: &Type,
    cfg_attrs: &[Attribute],
) -> TokenStream2 {
    quote! {
        #(#cfg_attrs)*
        #[repr(C)]
        pub struct #name {
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
        impl #name {
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
            /// The value returned after a caught panic (#244): the `Err`
            /// discriminant with **no** payload initialized.
            ///
            /// Julia reads this wrapper's panic channel before it decodes
            /// anything, and raises `RustPanicError`, so neither payload is
            /// ever observed. Both stay `MaybeUninit::zeroed()`, which is what
            /// `new` already writes for the inactive side.
            pub fn panicked() -> Self {
                Self {
                    is_ok: 0,
                    ok_value: ::std::mem::MaybeUninit::zeroed(),
                    err_value: ::std::mem::MaybeUninit::zeroed(),
                }
            }
        }
    }
}

fn generate_c_option_type(
    name: &Ident,
    inner_type: &Type,
    cfg_attrs: &[Attribute],
) -> TokenStream2 {
    quote! {
        #(#cfg_attrs)*
        #[repr(C)]
        pub struct #name {
            // Private, see the CResult type: the discriminant guards a
            // `MaybeUninit` payload. The C layout is unchanged.
            is_some: u8,
            /// Only initialized when `is_some == 1`.
            value: ::std::mem::MaybeUninit<#inner_type>,
        }

        #(#cfg_attrs)*
        impl #name {
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
            /// The value returned after a caught panic (#244): the `None`
            /// discriminant with an uninitialized payload. Julia raises
            /// `RustPanicError` before it looks at either field.
            pub fn panicked() -> Self {
                Self {
                    is_some: 0,
                    value: ::std::mem::MaybeUninit::zeroed(),
                }
            }
        }
    }
}

// ============================================================================
// Free functions: thin adapters over the generator
// ============================================================================

/// How a free function is lowered.
struct FreeFnOptions {
    /// Wrap a `Result` / `Option` return into `CResult_<fn>` / `COption_<fn>`.
    wrap_result: bool,
    /// Lower `String` / `&str` arguments and returns to the byte-pair ABI.
    lower_strings: bool,
    /// Extra `#[cfg]` attributes (the `julia_pyo3` non-Python branch).
    extra_cfg: Vec<Attribute>,
}

impl Default for FreeFnOptions {
    fn default() -> Self {
        FreeFnOptions {
            wrap_result: true,
            lower_strings: true,
            extra_cfg: Vec::new(),
        }
    }
}

/// The wrapper (and its helpers) of a free function. The function itself is
/// **not** part of the output: the caller emits the original item next to it.
fn free_function_wrapper(func: &ItemFn, options: &FreeFnOptions) -> TokenStream2 {
    let name = func.sig.ident.clone();
    let symbol = format_ident!("{}", function_symbol(&name.to_string()));
    let mut cfgs = cfg_attrs(&func.attrs);
    cfgs.extend(options.extra_cfg.iter().cloned());

    let ret = free_fn_return(func, &name, options);
    generate_wrapper(WrapperSpec {
        symbol,
        cfg_attrs: cfgs,
        receiver: None,
        args: arg_pairs(&func.sig),
        lower_strings: options.lower_strings,
        ret,
        target: CallTarget::Free(name),
    })
}

fn free_fn_return(func: &ItemFn, name: &Ident, options: &FreeFnOptions) -> WrapperReturn {
    let ReturnType::Type(_, ty) = &func.sig.output else {
        return WrapperReturn::Unit;
    };
    if options.wrap_result {
        if let Some(r) = extract_result_type(ty) {
            return WrapperReturn::CResult {
                name: format_ident!("CResult_{}", name),
                ok: r.ok_type,
                err: r.err_type,
            };
        }
        if let Some(o) = extract_option_type(ty) {
            return WrapperReturn::COption {
                name: format_ident!("COption_{}", name),
                inner: o.inner_type,
            };
        }
    }
    if options.lower_strings {
        if function_returns_string(&func.sig) || returns_copied_str(&func.sig) {
            return WrapperReturn::OwnedString {
                helper: format_ident!("{}_RustCallOwnedString", name),
                free: format_ident!("{}_free_rust_string", name),
                declare: true,
            };
        }
        if returns_borrowed_str(&func.sig) {
            return WrapperReturn::BorrowedStr {
                helper: format_ident!("{}_RustCallBorrowedString", name),
                declare: true,
            };
        }
    }
    WrapperReturn::Plain((**ty).clone())
}

/// Transform a `#[julia]` function: the annotated item is kept as written (the
/// attribute itself is already gone) and the `extern "C"` entry point is
/// emitted next to it under `rustcall_<fn>` (#279).
pub fn transform_function(func: ItemFn) -> TokenStream2 {
    if func.sig.unsafety.is_some() {
        return quote! {
            compile_error!("#[julia] cannot be applied to unsafe functions directly. The function will be made extern \"C\" which has its own safety semantics.");
        };
    }
    if let Some(error) = non_ffi_payload_error(&func) {
        return error;
    }

    let wrapper = free_function_wrapper(&func, &FreeFnOptions::default());
    quote! {
        #func
        #wrapper
    }
}

/// `Result` / `Option` payloads must survive the C ABI; refuse at compile time
/// rather than emit a wrapper that cannot be called.
fn non_ffi_payload_error(func: &ItemFn) -> Option<TokenStream2> {
    let ReturnType::Type(_, ty) = &func.sig.output else {
        return None;
    };
    let func_name = &func.sig.ident;
    if let Some(r) = extract_result_type(ty) {
        let ok_type = &r.ok_type;
        let err_type = &r.err_type;
        if is_non_ffi_type(ok_type) {
            return Some(quote! {
                compile_error!(concat!(
                    "#[julia] function `", stringify!(#func_name),
                    "` returns Result with non-FFI-compatible Ok type `", stringify!(#ok_type),
                    "`. Use a primitive or #[repr(C)] type instead."
                ));
            });
        }
        if is_non_ffi_type(err_type) {
            return Some(quote! {
                compile_error!(concat!(
                    "#[julia] function `", stringify!(#func_name),
                    "` returns Result with non-FFI-compatible Err type `", stringify!(#err_type),
                    "`. Use a primitive or #[repr(C)] type instead."
                ));
            });
        }
    }
    if let Some(o) = extract_option_type(ty) {
        let inner_type = &o.inner_type;
        if is_non_ffi_type(inner_type) {
            return Some(quote! {
                compile_error!(concat!(
                    "#[julia] function `", stringify!(#func_name),
                    "` returns Option with non-FFI-compatible type `", stringify!(#inner_type),
                    "`. Use a primitive or #[repr(C)] type instead."
                ));
            });
        }
    }
    None
}

/// The wrapper of a function exported with the signature as written: `Result` /
/// `Option` are not wrapped. Used by [`crate::specialize`] for the
/// instantiation of a generic function, whose fixed `String` / `&str`
/// parameters still get the byte-pair ABI (#242).
pub fn plain_function_wrapper(func: &ItemFn) -> TokenStream2 {
    free_function_wrapper(
        func,
        &FreeFnOptions {
            wrap_result: false,
            ..Default::default()
        },
    )
}

// ============================================================================
// Crate flavour: structs and impl blocks (proc-macro)
// ============================================================================

/// Whether the crate flavour emits the `<Struct>_RustCallOwnedString` /
/// `<Struct>_free_rust_string` helpers for this struct: it does exactly when a
/// field getter has to hand an owned `String` back (#276).
pub fn crate_struct_needs_owned_string_helper(item_struct: &ItemStruct) -> bool {
    let syn::Fields::Named(ref fields) = item_struct.fields else {
        return false;
    };
    fields.named.iter().any(|f| {
        f.ident.is_some()
            && (is_ffi_compatible_type(&f.ty) || needs_clone_for_getter(&f.ty))
            && is_string_type(&f.ty)
    })
}

fn crate_field_accessors(item_struct: &ItemStruct) -> TokenStream2 {
    let struct_name = &item_struct.ident;
    let owned_helper = format_ident!("{}_RustCallOwnedString", struct_name);
    let owned_free = format_ident!("{}_free_rust_string", struct_name);
    let mut ffi_functions = TokenStream2::new();
    if crate_struct_needs_owned_string_helper(item_struct) {
        ffi_functions.extend(owned_string_helper(&[], &owned_helper, &owned_free));
    }
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
            if is_string_type(field_ty) {
                // A `String` cannot cross `extern "C"` by value: it leaves as an
                // owned `(ptr, len, cap)` buffer the caller hands back to
                // `<Struct>_free_rust_string`, exactly as the inline flavour
                // and the string-returning method wrappers do (#246).
                ffi_functions.extend(quote! {
                    #[no_mangle]
                    pub extern "C" fn #getter_name(ptr: *const #struct_name) -> #owned_helper {
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
            } else if needs_clone_for_getter(field_ty) {
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

/// Generate the FFI wrapper for a method (crate flavour).
///
/// Same generator as the inline flavour ([`inline_method_wrapper`]): `String` /
/// `&str` arguments arrive as `(ptr, len)` pairs, a string result leaves as an
/// owned or borrowed buffer. The proc-macro transforms one impl block at a time
/// and cannot see the struct or sibling impl blocks, so the buffer types are
/// per method rather than per struct:
/// `<Struct>_<method>_RustCallOwnedString` released through
/// `<Struct>_<method>_free_rust_string`, and
/// `<Struct>_<method>_RustCallBorrowedString`. The method itself is left in the
/// impl block untouched; the wrapper calls it (#279).
pub fn generate_method_wrapper_crate(
    struct_name: &Ident,
    method: &syn::ImplItemFn,
) -> TokenStream2 {
    let model = MethodModel::from_fn(method);
    let owner = format_ident!("{}_{}", struct_name, method.sig.ident);
    let owned_helper = format_ident!("{}_RustCallOwnedString", owner);
    let owned_free = format_ident!("{}_free_rust_string", owner);
    let borrowed_helper = format_ident!("{}_RustCallBorrowedString", owner);
    generate_wrapper(method_spec(
        struct_name,
        &model,
        &owned_helper,
        &owned_free,
        &borrowed_helper,
        true,
    ))
}

// ============================================================================
// Crate flavour: #[julia_pyo3]
// ============================================================================

/// `#[julia_pyo3]` keeps its either/or `cfg(feature = "python")` shape, but the
/// non-Python branch is now "original item + additive wrapper" like `#[julia]`
/// (#279). The exported signature stays the one that was written — no
/// `Result` / `Option` wrapping and no string lowering — so the manifest `abi`
/// this attribute advertises remains honest (pending #275).
pub fn transform_function_julia_pyo3(func: ItemFn) -> TokenStream2 {
    let func_attrs = &func.attrs;
    let func_vis = &func.vis;
    let func_sig = &func.sig;
    let func_block = &func.block;

    let wrapper = free_function_wrapper(
        &func,
        &FreeFnOptions {
            wrap_result: false,
            lower_strings: false,
            extra_cfg: vec![syn::parse_quote!(#[cfg(not(feature = "python"))])],
        },
    );

    quote! {
        #[cfg(not(feature = "python"))]
        #(#func_attrs)*
        #func_vis #func_sig #func_block

        #wrapper

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
        out.extend(owned_string_helper(&[], &owned_helper, &owned_free));
    }
    if needs_borrowed {
        meta.has_borrowed_string_helper = true;
        out.extend(borrowed_string_helper(&[], &borrowed_helper));
    }

    // Field accessors (skipped when a method wrapper would take the same
    // symbol; since #279 the method wrappers are prefixed, so this can only
    // happen through a deliberately named accessor-shaped method).
    let method_symbols: Vec<String> = model
        .methods
        .iter()
        .map(|m| method_symbol(&struct_name.to_string(), &m.name()))
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
            &owned_free,
            &borrowed_helper,
        ));
    }

    (out, meta)
}

/// The [`WrapperSpec`] of a struct method, shared by the inline and the crate
/// flavour: `declare` says whether the string buffer helpers are emitted by
/// this wrapper (crate flavour, per method) or already exist next to the struct
/// (inline flavour, per struct).
fn method_spec(
    struct_name: &Ident,
    m: &MethodModel,
    owned_helper: &Ident,
    owned_free: &Ident,
    borrowed_helper: &Ident,
    declare: bool,
) -> WrapperSpec {
    let method_name = m.func.sig.ident.clone();
    let symbol = format_ident!(
        "{}",
        method_symbol(&struct_name.to_string(), &method_name.to_string())
    );
    let receiver = (!m.is_static).then(|| WrapperReceiver {
        ty: struct_name.clone(),
        mutable: m.is_mutable,
    });
    let target = if m.is_static {
        CallTarget::Assoc {
            ty: struct_name.clone(),
            method: method_name,
        }
    } else {
        CallTarget::Instance(method_name)
    };
    let ret = if inline_method_is_ctor(struct_name, m) {
        // `new`, or any method returning `Self` / the struct type, hands Julia
        // an owning pointer. The string helpers are not involved.
        WrapperReturn::Boxed(struct_name.clone())
    } else if method_returns_string(m) || method_copies_str(m) {
        WrapperReturn::OwnedString {
            helper: owned_helper.clone(),
            free: owned_free.clone(),
            declare,
        }
    } else if method_returns_borrowed_str(m) {
        WrapperReturn::BorrowedStr {
            helper: borrowed_helper.clone(),
            declare,
        }
    } else {
        match &m.func.sig.output {
            ReturnType::Default => WrapperReturn::Unit,
            ReturnType::Type(_, ty) => WrapperReturn::Plain((**ty).clone()),
        }
    };
    WrapperSpec {
        symbol,
        cfg_attrs: cfg_attrs(&m.func.attrs),
        receiver,
        args: arg_pairs(&m.func.sig),
        lower_strings: true,
        ret,
        target,
    }
}

/// The `extern "C"` wrapper of an inline struct method. The string buffer types
/// are shared per struct, so the wrapper only refers to them.
fn inline_method_wrapper(
    struct_name: &Ident,
    m: &MethodModel,
    owned_helper: &Ident,
    owned_free: &Ident,
    borrowed_helper: &Ident,
) -> TokenStream2 {
    generate_wrapper(method_spec(
        struct_name,
        m,
        owned_helper,
        owned_free,
        borrowed_helper,
        false,
    ))
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
        // An elided `&str` return borrows from `self`, which the wrapper
        // receives as a raw pointer; name the lifetime so the wrapper itself
        // is valid Rust (`&*ptr` is unbounded and coerces to it).
        let (decl_generics, ret) = match &m.func.sig.output {
            ReturnType::Type(_, ty)
                if !m.is_static
                    && is_str_ref_type(ty)
                    && matches!(unparen(ty), Type::Reference(r) if r.lifetime.is_none()) =>
            {
                let mut g = decl_generics.clone();
                // `&'rustcall Self<T>` requires every type parameter to outlive it.
                for param in g.params.iter_mut() {
                    if let syn::GenericParam::Type(tp) = param {
                        tp.bounds.push(syn::parse_quote!('rustcall));
                    }
                }
                g.params.insert(0, syn::parse_quote!('rustcall));
                (g, quote! { -> &'rustcall str })
            }
            other => (decl_generics.clone(), quote! { #other }),
        };
        let ret = &ret;
        let func: ItemFn = if is_ctor {
            syn::parse_quote! {
                pub fn #wrapper_name #decl_generics (#(#wrapper_args),*) -> *mut #self_ty #where_clause {
                    let obj = #struct_name::#method_name(#(#call_args),*);
                    Box::into_raw(Box::new(obj))
                }
            }
        } else {
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
