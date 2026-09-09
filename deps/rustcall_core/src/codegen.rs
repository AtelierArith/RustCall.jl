//! Wrapper code generation.
//!
//! Two flavours share this module:
//!
//! * **crate** codegen, used by the `juliacall_macros` proc-macro for
//!   `@rust_crate` (`transform_function`, `transform_struct_crate`,
//!   `transform_impl_crate`);
//! * **inline** codegen, used by the extractor CLI's `expand` command for
//!   `rust"""` blocks (`inline_struct_wrappers`, `inline_generic_wrappers`).
//!
//! Every `extern "C"` entry point — inline function, crate function,
//! specialized generic instantiation, inline method, crate method — is
//! produced by the one generator
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
//! Every exported symbol hangs off the item's **FFI name** ([`symbol_stem`]):
//! the item's own name at the crate root, and its module path folded in
//! otherwise (`a::run` -> `a__run`, see [`symbol_stem`] for the escaping).
//! The manifest carries it as `Function.ffi_name` / `Struct.ffi_name`
//! (schema 7, #300); `<f>` and `<Struct>` below stand for that name.
//!
//! | generated item | symbol |
//! |---|---|
//! | free function `f` | `rustcall_<f>` |
//! | method / constructor `Struct::m` | `rustcall_<Struct>_m` |
//! | specialized generic instantiation `f_i32` | `rustcall_<f_i32>` |
//! | struct destructor | `<Struct>_free` |
//! | field accessors | `<Struct>_get_x` / `<Struct>_set_x` |
//! | clone | `<Struct>_clone` |
//! | `Result` / `Option` payload | `CResult_<f>` / `COption_<f>` |
//! | owned string buffer / release | `<owner>_RustCallOwnedString` / `<owner>_free_rust_string` |
//! | borrowed string view | `<owner>_RustCallBorrowedString` |
//! | panic channel of a wrapper | `<wrapper symbol>_take_panic` |
//!
//! Only the first three wrap a user-written item and so must step aside from
//! its name; `<owner>` is the free function, `<Struct>_<method>` or `<Struct>`
//! the buffer belongs to.
//!
//! The scheme is stable and part of artifact identity: the manifest carries it
//! in `Function.symbol` / `Method.symbol` (schema 3) and every Julia-side
//! `ccall` / `dlsym` goes through those fields, never through the Rust name.
//! Inline expansion additionally refuses a block in which a user item already
//! owns a generated symbol (see `crate::expand::symbol_collisions`); the
//! proc-macro sees one item at a time and cannot make that check.
//!
//! # Where the module path comes from (#300)
//!
//! * Inline expansion (`rust"""`) walks the block's inline modules itself and
//!   qualifies every item by the path it finds.
//! * In a crate the proc-macro cannot see its enclosing module, so the path is
//!   spelled by `#[julia]` **on the module**: `#[julia] pub mod a { #[julia] pub
//!   fn run() }` expands the nested items with `["a"]` ([`transform_module`]),
//!   and nested marked modules accumulate. A `#[julia]` item inside an inline
//!   module that is *not* marked would be exported under the crate-root symbol,
//!   which is why crate extraction refuses it (`crate::extract`). File modules
//!   (`mod a;`) cannot carry an attribute macro and are transparent: their
//!   items keep root symbols.
//! * PyO3-scanned items (#275) carry the real module path of the crate's tree
//!   walk and are qualified by it, so two `#[pyclass] C` in different modules
//!   no longer collide.

use proc_macro2::TokenStream as TokenStream2;
use quote::{format_ident, quote};
use syn::{
    Attribute, FnArg, Ident, Item, ItemFn, ItemImpl, ItemMod, ItemStruct, Pat, ReturnType, Type,
    Visibility,
};

use crate::cfg::cfg_attrs;
use crate::manifest::GenericWrapper;
use crate::model::{MethodModel, StructModel};
use crate::types::{
    extract_option_type, extract_result_type, is_ffi_compatible_type,
    is_inline_accessible_field_type, is_non_ffi_type, is_self_type, is_str_ref_type,
    is_string_type, is_vec_type, last_ident, needs_clone_for_getter, unparen,
};

// ============================================================================
// Export-symbol scheme (#279, #300)
// ============================================================================

/// Prefix of every exported symbol that stands in for a user-written item.
pub const SYMBOL_PREFIX: &str = "rustcall_";

/// Separator between the segments of a module-qualified FFI name.
pub const MODULE_SEPARATOR: &str = "__";

/// Replacement for an underscore inside a segment of a module-qualified FFI
/// name.
pub const ESCAPED_UNDERSCORE: &str = "_0";

/// The **FFI name** of an item: the stem every generated symbol of the item is
/// derived from (`rustcall_<stem>`, `<stem>_free`, `<stem>_get_<field>`, ...).
///
/// * At the crate root (`module_path` empty) it is the item's own name,
///   unchanged: `run` -> `run`, `my_fn` -> `my_fn`.
/// * Inside modules every segment — the modules and the item name — has each
///   `_` replaced by [`ESCAPED_UNDERSCORE`] (`_0`), and the segments are joined
///   with [`MODULE_SEPARATOR`] (`__`): `a::run` -> `a__run`,
///   `geometry::shapes::Circle` -> `geometry__shapes__Circle`,
///   `my_mod::my_fn` -> `my_0mod__my_0fn`.
///
/// The encoding is prefix-free: in a qualified stem every `_` is followed by
/// either `0` (an escaped underscore) or `_` (a separator), so it decodes
/// unambiguously and two different paths never share a stem — `a_b::c` is
/// `a_0b__c`, `a::b_c` is `a__b_0c`. A raw-identifier prefix (`r#mod`) is
/// dropped, since `#` cannot appear in a symbol. Only identifier characters
/// are used, so the stem is valid as a Rust item name and as a linker symbol
/// on every platform.
///
/// A crate-root item whose *name* happens to spell an encoding (`fn a__run`
/// next to `a::run`) is the one coincidence the encoding cannot exclude; crate
/// extraction reports such a duplicate symbol instead of describing it.
pub fn symbol_stem(module_path: &[String], name: &str) -> String {
    let name = name.strip_prefix("r#").unwrap_or(name);
    if module_path.is_empty() {
        return name.to_string();
    }
    module_path
        .iter()
        .map(|segment| segment.as_str())
        .chain(std::iter::once(name))
        .map(|segment| {
            segment
                .strip_prefix("r#")
                .unwrap_or(segment)
                .replace('_', ESCAPED_UNDERSCORE)
        })
        .collect::<Vec<_>>()
        .join(MODULE_SEPARATOR)
}

/// Exported symbol of the `extern "C"` wrapper of the free function `name`
/// living under `module_path`: `rustcall_<stem>`.
pub fn function_symbol(module_path: &[String], name: &str) -> String {
    format!("{SYMBOL_PREFIX}{}", symbol_stem(module_path, name))
}

/// Exported symbol of the `extern "C"` wrapper of `Struct::method`, the struct
/// living under `module_path`: `rustcall_<stem>_<method>`.
pub fn method_symbol(module_path: &[String], struct_name: &str, method: &str) -> String {
    method_symbol_of(&symbol_stem(module_path, struct_name), method)
}

/// [`method_symbol`] from an already computed struct stem.
pub fn method_symbol_of(struct_stem: &str, method: &str) -> String {
    format!("{SYMBOL_PREFIX}{struct_stem}_{method}")
}

/// The destructor of a struct with FFI name `struct_stem`: `<stem>_free`.
pub fn struct_free_symbol(struct_stem: &str) -> String {
    format!("{struct_stem}_free")
}

/// The stem a method's string buffers hang off when the wrapper **declares**
/// them itself: `<struct stem>_<method>`, giving
/// `<owner>_RustCallOwnedString`, `<owner>_free_rust_string` and
/// `<owner>_RustCallBorrowedString`.
///
/// That is every crate-flavour method — the proc-macro sees one impl block at
/// a time and cannot share a buffer per struct — and, since #342, an inline
/// method whose `#[julia] impl` block sits in another module than its struct,
/// whose wrapper is emitted at the block. An inline method emitted next to its
/// struct shares the struct's buffers, whose owner is the struct stem itself.
/// The manifest states which of the two a method uses (`Method.string_owner`)
/// rather than leaving Julia to infer it from the flavour.
pub fn method_string_owner(struct_stem: &str, method: &str) -> String {
    format!("{struct_stem}_{method}")
}

/// The field accessors of a struct with FFI name `struct_stem`:
/// `<stem>_get_<field>` and `<stem>_set_<field>`.
pub fn field_getter_symbol(struct_stem: &str, field: &str) -> String {
    format!("{struct_stem}_get_{field}")
}

pub fn field_setter_symbol(struct_stem: &str, field: &str) -> String {
    format!("{struct_stem}_set_{field}")
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
    /// Path of the receiver type. An in-crate flavour passes the bare struct
    /// name; the PyO3 wrapper crate of #275 passes `user_crate::module::Class`,
    /// because the type lives in a dependency.
    pub ty: syn::Path,
    pub mutable: bool,
}

/// The item the wrapper calls. Always the original, under its own name.
pub(crate) enum CallTarget {
    /// `f(args)` — a path, so the PyO3 wrapper crate of #275 can name
    /// `user_crate::module::f` while the in-crate flavours pass a bare name.
    Free(syn::Path),
    /// `Struct::m(args)`
    Assoc { ty: syn::Path, method: Ident },
    /// `self_obj.m(args)`
    Instance(Ident),
}

/// The last segment of a path, which is the name a human reads: the panic
/// message of a wrapper for `user_crate::geometry::Point::area` says
/// `Point::area`, not the whole path.
fn path_tail(path: &syn::Path) -> String {
    path.segments
        .last()
        .map(|s| s.ident.to_string())
        .unwrap_or_default()
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
    /// anything returning `Self`). A path, see [`CallTarget::Free`].
    Boxed(syn::Path),
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
    CResult {
        name: Ident,
        ok: WrapperPayload,
        err: WrapperPayload,
    },
    /// `COption_<owner> { is_some, value }`.
    COption { name: Ident, inner: WrapperPayload },
}

/// How one `Result` / `Option` payload is stored in the `#[repr(C)]` aggregate
/// the wrapper returns (#268).
///
/// A `String` / `&str` payload cannot be a field of that aggregate — it is not
/// FFI-safe and Julia could neither read nor release it — so it is lowered to
/// the very buffer a `String`-returning wrapper already hands back:
/// `<owner>_RustCallOwnedString { ptr, len, cap }`, released through
/// `<owner>_free_rust_string`. The `Result` / `Option` lowering and the string
/// lowering therefore compose, rather than one excluding the other.
///
/// A `&str` payload is **copied** into that buffer rather than borrowed: unlike
/// a bare `&str` return, a payload sits inside an aggregate that outlives the
/// call's temporaries in Julia's hands, and the borrowed-view optimisation
/// (`returns_borrowed_str`) would make its validity depend on where the `&str`
/// came from. One owned shape for every string payload is what keeps the
/// release rule "free exactly the active payload, through the owner's
/// `free_rust_string`" true in all cases.
#[allow(clippy::large_enum_variant)]
pub(crate) enum WrapperPayload {
    /// Stored as written.
    Plain(Type),
    /// `String` / `&str`, stored as `<helper> { ptr, len, cap }`.
    OwnedString {
        helper: Ident,
        free: Ident,
        /// Whether this wrapper declares the buffer type and its release
        /// function (false when a struct-level helper is shared).
        declare: bool,
    },
}

impl WrapperPayload {
    /// Whether the payload is stored exactly as the Rust signature wrote it.
    fn is_plain(&self) -> bool {
        matches!(self, WrapperPayload::Plain(_))
    }

    /// The type the payload occupies in the aggregate.
    fn stored_type(&self) -> Type {
        match self {
            WrapperPayload::Plain(ty) => ty.clone(),
            WrapperPayload::OwnedString { helper, .. } => syn::parse_quote!(#helper),
        }
    }

    /// The expression that turns the value bound to `value` into the stored
    /// form.
    fn store_expr(&self, value: &Ident) -> TokenStream2 {
        match self {
            WrapperPayload::Plain(_) => quote! { #value },
            WrapperPayload::OwnedString { helper, .. } => quote! {{
                // `ToString` covers both `String` and a `&str` payload, which
                // is always copied (see the type docs).
                let mut rustcall_bytes = ToString::to_string(&#value).into_bytes();
                let rustcall_buf = #helper {
                    ptr: rustcall_bytes.as_mut_ptr(),
                    len: rustcall_bytes.len(),
                    cap: rustcall_bytes.capacity(),
                };
                ::std::mem::forget(rustcall_bytes);
                rustcall_buf
            }},
        }
    }

    /// The `(helper, free)` pair this payload wants declared, if it declares one.
    fn declaration(&self) -> Option<(&Ident, &Ident)> {
        match self {
            WrapperPayload::OwnedString {
                helper,
                free,
                declare: true,
            } => Some((helper, free)),
            _ => None,
        }
    }
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
    pub ret: WrapperReturn,
    pub target: CallTarget,
    /// Tokens appended to the call expression before the return lowering sees
    /// its value. Empty for every in-crate flavour; the PyO3 wrapper crate of
    /// #275 uses it to turn a `PyResult<T>` into a `Result<T, i32>` by
    /// **dropping** the `PyErr` — rendering one panics inside pyo3 without an
    /// interpreter, and that panic crossing `extern "C"` aborts the process.
    pub call_suffix: TokenStream2,
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
                // Finalizers only need a failure count, not its text. This
                // reserved request consumes the channel without allocating a
                // Julia message buffer or leaving a stale panic for a later
                // call. Ordinary null/zero length queries still retain it.
                if out.is_null() && cap == usize::MAX {
                    return rustcall_slot.take().map_or(0, |message| message.len());
                }
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
        ret,
        target,
        call_suffix,
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
        let (a, conversion) = string_arg_conversion(name, ty, &taken);
        wrapper_args.extend(a);
        conversions.extend(conversion);
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
    let call = quote! { #call #call_suffix };
    let prologue = quote! { #(#conversions)* #self_binding };

    // The Julia-facing name this wrapper stands for, used in the panic
    // message. Derived from the call target rather than from the symbol, so
    // the message reads `Point::area panicked: ...` and not
    // `rustcall_Point_area panicked: ...`.
    let julia_name = match &target {
        CallTarget::Free(name) => path_tail(name),
        CallTarget::Assoc { ty, method } => format!("{}::{}", path_tail(ty), method),
        CallTarget::Instance(method) => match &receiver {
            Some(r) => format!("{}::{}", path_tail(&r.ty), method),
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
            out.extend(payload_helpers(&cfg_attrs, &[&ok, &err]));
            out.extend(generate_c_result_type(
                &name,
                &ok.stored_type(),
                &err.stored_type(),
                &cfg_attrs,
            ));
            // `is_ok = 0` with an uninitialized payload: the `Err` branch, and
            // Julia raises before it decodes either payload.
            let sentinel = quote! { #name::panicked() };
            // With no payload to lower the `Result` goes straight in; the
            // re-wrapping match exists only to convert a string payload.
            let body = if ok.is_plain() && err.is_plain() {
                quote! { #name::new(#call) }
            } else {
                let ok_binding = fresh_ident("rustcall_ok", &taken);
                let err_binding = fresh_ident("rustcall_err", &taken);
                let ok_store = ok.store_expr(&ok_binding);
                let err_store = err.store_expr(&err_binding);
                quote! {
                    #name::new(match #call {
                        ::std::result::Result::Ok(#ok_binding) =>
                            ::std::result::Result::Ok(#ok_store),
                        ::std::result::Result::Err(#err_binding) =>
                            ::std::result::Result::Err(#err_store),
                    })
                }
            };
            let guarded = guarded_body(&julia_name, &slot, &prologue, body, sentinel, false);
            quote! {
                #(#cfg_attrs)*
                #[no_mangle]
                pub extern "C" fn #symbol(#(#wrapper_args),*) -> #name {
                    #guarded
                }
            }
        }
        WrapperReturn::COption { name, inner } => {
            out.extend(payload_helpers(&cfg_attrs, &[&inner]));
            out.extend(generate_c_option_type(
                &name,
                &inner.stored_type(),
                &cfg_attrs,
            ));
            let sentinel = quote! { #name::panicked() };
            let body = if inner.is_plain() {
                quote! { #name::new(#call) }
            } else {
                let binding = fresh_ident("rustcall_some", &taken);
                let store = inner.store_expr(&binding);
                quote! {
                    #name::new(match #call {
                        ::std::option::Option::Some(#binding) =>
                            ::std::option::Option::Some(#store),
                        ::std::option::Option::None => ::std::option::Option::None,
                    })
                }
            };
            let guarded = guarded_body(&julia_name, &slot, &prologue, body, sentinel, false);
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

/// [`owned_string_helper`] with no `#[cfg]` attributes, for a generator that
/// emits the buffer next to a struct rather than next to a function: the PyO3
/// wrapper crate of #275 shares one buffer type per `#[pyclass]`.
pub(crate) fn owned_string_helper_items(helper: &Ident, free: &Ident) -> TokenStream2 {
    owned_string_helper(&[], helper, free)
}

/// The string buffer types the payloads of one `Result` / `Option` wrapper
/// need declared. Both payloads of a `Result<String, String>` share the owner's
/// single buffer type, so it is emitted once (#268).
fn payload_helpers(cfg_attrs: &[Attribute], payloads: &[&WrapperPayload]) -> TokenStream2 {
    let mut out = TokenStream2::new();
    let mut declared: Vec<String> = Vec::new();
    for p in payloads {
        if let Some((helper, free)) = p.declaration() {
            if declared.contains(&helper.to_string()) {
                continue;
            }
            declared.push(helper.to_string());
            out.extend(owned_string_helper(cfg_attrs, helper, free));
        }
    }
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
}

impl Default for FreeFnOptions {
    fn default() -> Self {
        FreeFnOptions { wrap_result: true }
    }
}

/// The wrapper (and its helpers) of a free function. The function itself is
/// **not** part of the output: the caller emits the original item next to it.
fn free_function_wrapper(
    func: &ItemFn,
    module_path: &[String],
    options: &FreeFnOptions,
) -> TokenStream2 {
    let name = func.sig.ident.clone();
    // Every generated name of the function hangs off its FFI name (#300).
    let stem = format_ident!("{}", symbol_stem(module_path, &name.to_string()));
    let symbol = format_ident!("{}{}", SYMBOL_PREFIX, stem);
    let cfgs = cfg_attrs(&func.attrs);

    let ret = free_fn_return(func, &stem, options);
    generate_wrapper(WrapperSpec {
        symbol,
        cfg_attrs: cfgs,
        receiver: None,
        args: arg_pairs(&func.sig),
        ret,
        target: CallTarget::Free(name.into()),
        call_suffix: TokenStream2::new(),
    })
}

/// The [`WrapperPayload`] of one `Result` / `Option` component: a `String` /
/// `&str` becomes the owner's owned-string buffer, everything else is stored as
/// written (#268).
fn payload_of(ty: &Type, helper: &Ident, free: &Ident, declare: bool) -> WrapperPayload {
    if is_string_type(ty) || is_str_ref_type(ty) {
        WrapperPayload::OwnedString {
            helper: helper.clone(),
            free: free.clone(),
            declare,
        }
    } else {
        WrapperPayload::Plain(ty.clone())
    }
}

/// Whether a `Result` / `Option` payload can be carried by the generated
/// `#[repr(C)]` aggregate: anything the C ABI takes as written, plus `String` /
/// `&str`, which are lowered to an owned buffer (#268).
pub fn payload_is_representable(ty: &Type) -> bool {
    is_string_type(ty) || is_str_ref_type(ty) || !is_non_ffi_type(ty)
}

/// Whether a method wrapper lowers this return type into `CResult_*` — i.e.
/// it is a `Result` whose payloads the aggregate can carry. A `Result` with a
/// payload it cannot carry keeps the pre-#268 behaviour (returned as written,
/// reported as `Plain`), rather than turning existing code into a compile
/// error.
pub fn method_wraps_result(ty: &Type) -> bool {
    extract_result_type(ty)
        .map(|r| payload_is_representable(&r.ok_type) && payload_is_representable(&r.err_type))
        .unwrap_or(false)
}

/// The `Option` counterpart of [`method_wraps_result`].
pub fn method_wraps_option(ty: &Type) -> bool {
    extract_option_type(ty)
        .map(|o| payload_is_representable(&o.inner_type))
        .unwrap_or(false)
}

/// Whether a `Result` / `Option` payload travels as an owned string buffer,
/// i.e. what the manifest reports as `ok_abi` / `err_abi` / `inner_abi`
/// (#268). `&str` is included: a payload is always copied, never borrowed.
pub fn payload_abi(ty: &Type) -> &'static str {
    if is_string_type(ty) || is_str_ref_type(ty) {
        "string"
    } else {
        ""
    }
}

fn free_fn_return(func: &ItemFn, name: &Ident, options: &FreeFnOptions) -> WrapperReturn {
    let ReturnType::Type(_, ty) = &func.sig.output else {
        return WrapperReturn::Unit;
    };
    if options.wrap_result {
        // A `String` payload is lowered to the function's own owned-string
        // buffer, which this wrapper declares (#268).
        let helper = format_ident!("{}_RustCallOwnedString", name);
        let free = format_ident!("{}_free_rust_string", name);
        let payload = |ty: &Type| payload_of(ty, &helper, &free, true);
        if let Some(r) = extract_result_type(ty) {
            return WrapperReturn::CResult {
                name: format_ident!("CResult_{}", name),
                ok: payload(&r.ok_type),
                err: payload(&r.err_type),
            };
        }
        if let Some(o) = extract_option_type(ty) {
            return WrapperReturn::COption {
                name: format_ident!("COption_{}", name),
                inner: payload(&o.inner_type),
            };
        }
    }
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
    WrapperReturn::Plain((**ty).clone())
}

/// Transform a `#[julia]` function: the annotated item is kept as written (the
/// attribute itself is already gone) and the `extern "C"` entry point is
/// emitted next to it under `rustcall_<fn>` (#279).
pub fn transform_function(func: ItemFn, module_path: &[String]) -> TokenStream2 {
    if func.sig.unsafety.is_some() {
        return quote! {
            compile_error!("#[julia] cannot be applied to unsafe functions directly. The function will be made extern \"C\" which has its own safety semantics.");
        };
    }
    if let Some(error) = non_ffi_payload_error(&func) {
        return error;
    }

    let wrapper = free_function_wrapper(&func, module_path, &FreeFnOptions::default());
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
        if !payload_is_representable(ok_type) {
            return Some(quote! {
                compile_error!(concat!(
                    "#[julia] function `", stringify!(#func_name),
                    "` returns Result with non-FFI-compatible Ok type `", stringify!(#ok_type),
                    "`. Use a primitive or #[repr(C)] type instead."
                ));
            });
        }
        if !payload_is_representable(err_type) {
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
        if !payload_is_representable(inner_type) {
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
pub fn plain_function_wrapper(func: &ItemFn, module_path: &[String]) -> TokenStream2 {
    free_function_wrapper(func, module_path, &FreeFnOptions { wrap_result: false })
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

/// Apply the common boundary to generated field/clone helpers. These helpers
/// return only unit, primitives, raw pointers, owned-string buffers or Vec.
/// In particular, Vec must use an empty vector, not an invalid zeroed value.
pub(crate) fn guard_struct_helper(tokens: TokenStream2) -> TokenStream2 {
    let mut function: ItemFn = syn::parse2(tokens).expect("generated struct helper is a function");
    let symbol = &function.sig.ident;
    let suffix: String = symbol
        .to_string()
        .bytes()
        .map(|b| format!("{b:02X}"))
        .collect();
    let slot = format_ident!("__RUSTCALL_HELPER_PANIC_{}", suffix);
    let reader = format_ident!("{}", panic_symbol(&symbol.to_string()));
    let channel = panic_channel(&cfg_attrs(&function.attrs), &slot, &reader);
    let (sentinel, unit) = match &function.sig.output {
        ReturnType::Default => (quote! {}, true),
        ReturnType::Type(_, ty) if matches!(unparen(ty), Type::Tuple(t) if t.elems.is_empty()) => {
            (quote! {}, true)
        }
        ReturnType::Type(_, ty) if is_vec_type(ty) => (quote! { ::std::vec::Vec::new() }, false),
        ReturnType::Type(_, ty) => (quote! { unsafe { ::std::mem::zeroed::<#ty>() } }, false),
    };
    let original = &function.block;
    let body = guarded_body(
        &symbol.to_string(),
        &slot,
        &quote! {},
        quote! { #original },
        sentinel,
        unit,
    );
    function.block = syn::parse_quote!({ #body });
    quote! { #channel #function }
}

/// Copy the struct's cfg onto every accessor and its channel, including when
/// a module macro expands the struct before rustc evaluates the predicate.
fn crate_field_accessors(
    item_struct: &ItemStruct,
    stem: &Ident,
    cfgs: &[Attribute],
) -> TokenStream2 {
    let struct_name = &item_struct.ident;
    let owned_helper = format_ident!("{}_RustCallOwnedString", stem);
    let owned_free = format_ident!("{}_free_rust_string", stem);
    let mut ffi_functions = TokenStream2::new();
    if crate_struct_needs_owned_string_helper(item_struct) {
        ffi_functions.extend(owned_string_helper(cfgs, &owned_helper, &owned_free));
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
            let getter_name = format_ident!("{}_get_{}", stem, field_name);
            if is_string_type(field_ty) {
                // A `String` cannot cross `extern "C"` by value: it leaves as an
                // owned `(ptr, len, cap)` buffer the caller hands back to
                // `<Struct>_free_rust_string`, exactly as the inline flavour
                // and the string-returning method wrappers do (#246).
                ffi_functions.extend(guard_struct_helper(quote! {
                    #(#cfgs)*
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
                }));
            } else if needs_clone_for_getter(field_ty) {
                ffi_functions.extend(guard_struct_helper(quote! {
                    #(#cfgs)*
                    #[no_mangle]
                    pub extern "C" fn #getter_name(ptr: *const #struct_name) -> #field_ty {
                        unsafe { (*ptr).#field_name.clone() }
                    }
                }));
            } else {
                ffi_functions.extend(guard_struct_helper(quote! {
                    #(#cfgs)*
                    #[no_mangle]
                    pub extern "C" fn #getter_name(ptr: *const #struct_name) -> #field_ty {
                        unsafe { (*ptr).#field_name }
                    }
                }));
            }
            let setter_name = format_ident!("{}_set_{}", stem, field_name);
            ffi_functions.extend(struct_field_setter(
                struct_name,
                field_name,
                field_ty,
                &setter_name,
                cfgs,
            ));
        }
    }
    ffi_functions
}

pub(crate) fn struct_field_setter(
    owner: &impl quote::ToTokens,
    field: &Ident,
    ty: &Type,
    setter: &Ident,
    cfgs: &[Attribute],
) -> TokenStream2 {
    let value = format_ident!("value");
    let (args, conversion) = if is_string_type(ty) {
        string_arg_conversion(&value, ty, &["ptr".into()])
    } else {
        (vec![quote! { value: #ty }], None)
    };
    guard_struct_helper(quote! {
        #(#cfgs)*
        #[no_mangle]
        pub extern "C" fn #setter(ptr: *mut #owner, #(#args),*) {
            #conversion
            unsafe { (*ptr).#field = value; }
        }
    })
}

pub(crate) fn struct_free_wrapper(
    struct_type: &syn::Path,
    stem: &Ident,
    cfgs: &[Attribute],
) -> TokenStream2 {
    let free_fn_name = format_ident!("{}_free", stem);
    // Unlike case folding, byte encoding keeps distinct struct names such as
    // `C` and `c` distinct in the private TLS namespace as well.
    let slot_suffix: String = free_fn_name
        .to_string()
        .bytes()
        .map(|byte| format!("{byte:02X}"))
        .collect();
    let slot = format_ident!("__RUSTCALL_DROP_PANIC_{}", slot_suffix);
    let reader = format_ident!("{}", panic_symbol(&free_fn_name.to_string()));
    let channel = panic_channel(cfgs, &slot, &reader);
    let body = guarded_body(
        &format!("{}::drop", path_tail(struct_type)),
        &slot,
        &quote! {},
        quote! {
            if !ptr.is_null() {
                unsafe { drop(Box::from_raw(ptr)); }
            }
        },
        quote! {},
        true,
    );
    quote! {
        #channel
        #(#cfgs)*
        #[no_mangle]
        pub extern "C" fn #free_fn_name(ptr: *mut #struct_type) {
            #body
        }
    }
}

/// The FFI name of a struct as an identifier (see [`symbol_stem`]).
fn struct_stem(module_path: &[String], struct_name: &Ident) -> Ident {
    format_ident!("{}", symbol_stem(module_path, &struct_name.to_string()))
}

/// Transform a `#[julia]` struct (crate flavour): `#[repr(C)]`, `pub`, free + accessors.
pub fn transform_struct_crate(mut item_struct: ItemStruct, module_path: &[String]) -> TokenStream2 {
    let repr_c: Attribute = syn::parse_quote!(#[repr(C)]);
    item_struct.attrs.insert(0, repr_c);
    item_struct.vis = Visibility::Public(syn::token::Pub::default());

    let stem = struct_stem(module_path, &item_struct.ident);
    // The struct's `#[cfg]` gates its helpers too (#300 review).
    let cfgs = cfg_attrs(&item_struct.attrs);
    let struct_name = &item_struct.ident;
    let free = struct_free_wrapper(&syn::parse_quote!(#struct_name), &stem, &cfgs);
    let accessors = crate_field_accessors(&item_struct, &stem, &cfgs);

    quote! {
        #item_struct
        #free
        #accessors
    }
}

/// The module path the proc-macro takes the struct of `#[julia] impl <self_ty>`
/// to live at, given the `#[julia]` modules `module_path` around the block:
/// the header read literally (`crate::a::C` is `a::C`, `super::C` one level up,
/// a bare `C` the block's own path), see
/// `PathQualifier::macro_target_path` (#315). Every symbol of the block's
/// methods hangs off this path, and crate extraction refuses a block whose
/// header names a struct that lives somewhere else.
pub fn impl_target_module_path(module_path: &[String], self_ty: &Type) -> Vec<String> {
    crate::paths::type_path_qualifier(self_ty).macro_target_path(module_path)
}

/// Transform a `#[julia]` impl block (crate flavour): wrap `#[julia]` methods.
///
/// The block may sit in another module than its struct (`impl crate::Gauge`
/// from `ops.rs`, `impl super::Gauge` from a child module, #315); the method
/// symbols follow the struct the header names, [`impl_target_module_path`].
pub fn transform_impl_crate(mut item_impl: ItemImpl, module_path: &[String]) -> TokenStream2 {
    if last_ident(&item_impl.self_ty).is_none() {
        return quote! {
            compile_error!("#[julia] on impl block requires a simple type path");
        };
    }
    let struct_path = impl_target_module_path(module_path, &item_impl.self_ty);
    // The wrappers are emitted next to the block, in *its* module, so they
    // name the struct the way the header does (`super::Gauge`): a bare
    // `Gauge` need not be in scope there.
    let self_ty = (*item_impl.self_ty).clone();

    // The block's own `#[cfg]` gates every wrapper it produces: inside a
    // `#[julia] mod` the module macro expands a gated impl before rustc
    // evaluates the predicate (#300 review).
    let block_cfgs = cfg_attrs(&item_impl.attrs);
    let mut ffi_wrappers = TokenStream2::new();
    for item in &mut item_impl.items {
        if let syn::ImplItem::Fn(method) = item {
            let has_julia_attr = method
                .attrs
                .iter()
                .any(|attr| attr.path().is_ident("julia"));
            if has_julia_attr {
                method.attrs.retain(|attr| !attr.path().is_ident("julia"));
                // The generator reads the method's `#[cfg]` set and puts it on
                // every item it emits; the block's predicates join that set
                // for the wrapper only, the method itself is left as written.
                let mut gated = method.clone();
                gated.attrs.splice(0..0, block_cfgs.iter().cloned());
                ffi_wrappers.extend(generate_method_wrapper_crate(
                    &self_ty,
                    &struct_path,
                    &gated,
                ));
            }
        }
    }

    quote! {
        #item_impl
        #ffi_wrappers
    }
}

/// Transform a `#[julia]` **module** (crate flavour, #300).
///
/// The proc-macro cannot see the module an item sits in, so the module itself
/// carries the marker and expands its own `#[julia]` items with the module
/// path — `module_path` is the path of the enclosing marked modules, and this
/// module's name is appended to it. Each nested `#[julia]` function, struct and
/// impl block is expanded exactly as [`transform_function`],
/// [`transform_struct_crate`] and [`transform_impl_crate`] would, its own
/// `#[julia]` attribute removed so the item-level macro does not run on it a
/// second time; a nested `#[julia] mod` recurses with the accumulated path;
/// everything else is kept as written.
///
/// A file module (`mod a;`) has no body to expand: the attribute is refused
/// with a `compile_error!` naming the alternative (an inline module block).
pub fn transform_module(item_mod: ItemMod, module_path: &[String]) -> TokenStream2 {
    let Some((_, items)) = item_mod.content else {
        return quote! {
            compile_error!(
                "#[julia] on a file module (`mod name;`) is not supported: attribute macros \
                 cannot expand a non-inline module. Write the module inline \
                 (`#[julia] pub mod name { ... }`) to give its items a module-qualified symbol."
            );
        };
    };
    let mut path = module_path.to_vec();
    path.push(item_mod.ident.to_string());

    let mut body = TokenStream2::new();
    for item in items {
        body.extend(expand_marked_item(item, &path));
    }

    let attrs = &item_mod.attrs;
    let vis = &item_mod.vis;
    let unsafety = &item_mod.unsafety;
    let ident = &item_mod.ident;
    quote! { #(#attrs)* #vis #unsafety mod #ident { #body } }
}

/// One item of a `#[julia]` module body: a `#[julia]` function, struct, impl
/// block or module is expanded with `module_path`; anything else is unchanged.
fn expand_marked_item(item: Item, module_path: &[String]) -> TokenStream2 {
    fn take_julia(attrs: &mut Vec<Attribute>) -> bool {
        let before = attrs.len();
        attrs.retain(|attr| !crate::attrs::is_julia_attr(attr));
        attrs.len() != before
    }
    match item {
        Item::Fn(mut f) => {
            if take_julia(&mut f.attrs) {
                transform_function(f, module_path)
            } else {
                quote! { #f }
            }
        }
        Item::Struct(mut s) => {
            if take_julia(&mut s.attrs) {
                transform_struct_crate(s, module_path)
            } else {
                quote! { #s }
            }
        }
        Item::Impl(mut i) => {
            if take_julia(&mut i.attrs) {
                transform_impl_crate(i, module_path)
            } else {
                quote! { #i }
            }
        }
        Item::Mod(mut m) => {
            if take_julia(&mut m.attrs) {
                transform_module(m, module_path)
            } else {
                quote! { #m }
            }
        }
        other => quote! { #other },
    }
}

/// Whether an inline module is marked `#[julia]`, i.e. contributes its name
/// to the symbols of the items it contains (#300).
pub fn is_marked_module(item_mod: &ItemMod) -> bool {
    item_mod.attrs.iter().any(crate::attrs::is_julia_attr)
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
    self_ty: &Type,
    module_path: &[String],
    method: &syn::ImplItemFn,
) -> TokenStream2 {
    // The origin is a manifest column; the wrapper's shape does not depend
    // on it.
    let model = MethodModel::from_fn(method, crate::manifest::Attribute::Julia);
    // The proc-macro sees one block and cannot resolve a name: the header's
    // last segment *is* the struct as far as it knows. Crate extraction
    // refuses a header the macro would read differently from the struct it
    // resolves to — a renamed import among them (#315).
    let Some(struct_name) = last_ident(self_ty) else {
        return quote! {
            compile_error!("#[julia] on impl block requires a simple type path");
        };
    };
    method_wrapper_at_impl_site(self_ty, struct_name, module_path, &model)
}

/// The FFI wrapper of a method emitted **at its impl block** rather than next
/// to its struct: `self_ty` is the impl header as written (`super::Gauge`), so
/// the struct need not be in scope under its bare name, and the string buffers
/// are declared per method ([`method_string_owner`]) so two blocks of one
/// struct cannot both claim the struct-level `#[no_mangle]` helpers.
///
/// `struct_name` is the struct's **own** identifier and `struct_module_path`
/// the module it lives in: every exported symbol hangs off those, wherever the
/// wrapper is emitted and however the header spells the type. The two are not
/// the same thing — `use super::Gauge as Meter; impl Meter` must still export
/// `rustcall_Gauge_<method>`, which is what the manifest advertises, while the
/// wrapper's own code says `Meter` because that is the name in scope there
/// (#342 review).
///
/// Used by the proc-macro for every `#[julia] impl` block
/// ([`generate_method_wrapper_crate`]) and by the inline expander for a block
/// that sits in another module than its struct (#342).
pub fn method_wrapper_at_impl_site(
    self_ty: &Type,
    struct_name: &Ident,
    struct_module_path: &[String],
    m: &MethodModel,
) -> TokenStream2 {
    let Type::Path(self_path) = unparen(self_ty) else {
        return quote! {
            compile_error!("#[julia] on impl block requires a simple type path");
        };
    };
    let stem = struct_stem(struct_module_path, struct_name);
    let owner = format_ident!("{}", method_string_owner(&stem.to_string(), &m.name()));
    let owned_helper = format_ident!("{}_RustCallOwnedString", owner);
    let owned_free = format_ident!("{}_free_rust_string", owner);
    let borrowed_helper = format_ident!("{}_RustCallBorrowedString", owner);
    generate_wrapper(method_spec(
        &self_path.path,
        struct_name,
        &stem,
        m,
        &owned_helper,
        &owned_free,
        &borrowed_helper,
        true,
    ))
}

/// The wrapper of an **inline** method whose `#[julia] impl` block sits in
/// another module than its struct (#342), emitted into the block's module.
///
/// The expander resolves the header itself, so `struct_name` /
/// `struct_module_path` are the struct the block was married to — not the
/// header's last segment, which a `use ... as` may have renamed — while
/// `self_ty` stays the header as written, the only spelling in scope where the
/// wrapper is emitted (#342 review).
///
/// The block's own `#[cfg]` — and that of the modules around it — gates the
/// wrapper as much as the method's own does, exactly as
/// [`transform_impl_crate`] splices the block's predicates onto the crate
/// flavour's wrapper.
pub fn inline_foreign_method_wrapper(
    self_ty: &Type,
    struct_name: &Ident,
    struct_module_path: &[String],
    m: &MethodModel,
) -> TokenStream2 {
    let mut gated = m.clone();
    gated
        .func
        .attrs
        .splice(0..0, m.enclosing_cfg.iter().cloned());
    method_wrapper_at_impl_site(self_ty, struct_name, struct_module_path, &gated)
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

/// The `Result<T, E>` a method wrapper lowers into `CResult_<Struct>_<method>`,
/// if it is one (#268). A constructor is excluded by the caller.
fn method_result_return(m: &MethodModel) -> Option<crate::types::ResultTypeInfo> {
    match &m.func.sig.output {
        ReturnType::Type(_, ty) if method_wraps_result(ty) => extract_result_type(ty),
        _ => None,
    }
}

/// The `Option<T>` counterpart of [`method_result_return`].
fn method_option_return(m: &MethodModel) -> Option<crate::types::OptionTypeInfo> {
    match &m.func.sig.output {
        ReturnType::Type(_, ty) if method_wraps_option(ty) => extract_option_type(ty),
        _ => None,
    }
}

/// Whether an inline method's wrapper needs the struct's owned-string buffer:
/// a `String` / copied `&str` return, or a `Result` / `Option` with a string
/// payload (#268).
fn method_needs_owned_string(m: &MethodModel) -> bool {
    if method_returns_string(m) || method_copies_str(m) {
        return true;
    }
    if let Some(r) = method_result_return(m) {
        return !payload_abi(&r.ok_type).is_empty() || !payload_abi(&r.err_type).is_empty();
    }
    if let Some(o) = method_option_return(m) {
        return !payload_abi(&o.inner_type).is_empty();
    }
    false
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

/// Generate the `extern "C"` wrappers for a non-generic inline struct: the
/// destructor, the field accessors, the shared string buffers and the wrappers
/// of the methods whose `#[julia] impl` block sits in `module_path` — the
/// struct's own module.
///
/// A method from a block in *another* module is not wrapped here: its wrapper
/// is emitted at the block by `expand::expand_items` through
/// [`inline_foreign_method_wrapper`], because its signature is written in the
/// block's scope (#342).
pub fn inline_struct_wrappers(
    model: &StructModel,
    module_path: &[String],
) -> (TokenStream2, InlineStructMeta) {
    let struct_name = &model.item.ident;
    let stem = struct_stem(module_path, struct_name);
    let mut out = TokenStream2::new();
    let mut meta = InlineStructMeta::default();

    out.extend(struct_free_wrapper(
        &syn::parse_quote!(#struct_name),
        &stem,
        &[],
    ));

    let fields = model.named_fields();
    let accessible: Vec<&(Ident, Type)> = fields
        .iter()
        .filter(|(_, ty)| is_inline_accessible_field_type(ty))
        .collect();

    // Only the methods whose `#[julia] impl` block sits beside the struct are
    // wrapped here. One in another module has its wrapper emitted at the block
    // (`inline_foreign_method_wrapper`, #342), where the types its signature
    // names are in scope, with string buffers of its own — so it neither needs
    // nor may use the struct-level helpers, and does not make them exist.
    let local: Vec<&MethodModel> = model
        .methods
        .iter()
        .filter(|m| m.is_local_to(module_path))
        .collect();

    let needs_owned = accessible.iter().any(|(_, ty)| is_string_type(ty))
        || local
            .iter()
            .any(|m| method_needs_owned_string(m) && !inline_method_is_ctor(struct_name, m));
    let needs_borrowed = local
        .iter()
        .any(|m| method_returns_borrowed_str(m) && !inline_method_is_ctor(struct_name, m));

    let owned_helper = format_ident!("{}_RustCallOwnedString", stem);
    let borrowed_helper = format_ident!("{}_RustCallBorrowedString", stem);
    let owned_free = format_ident!("{}_free_rust_string", stem);

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
        .map(|m| method_symbol_of(&stem.to_string(), &m.name()))
        .collect();
    for (field_name, field_ty) in &accessible {
        let getter = format_ident!("{}_get_{}", stem, field_name);
        if method_symbols.contains(&getter.to_string()) {
            meta.accessors
                .push((field_name.to_string(), getter.to_string(), String::new()));
            continue;
        }
        let setter = format_ident!("{}_set_{}", stem, field_name);
        meta.accessors.push((
            field_name.to_string(),
            getter.to_string(),
            setter.to_string(),
        ));
        if is_string_type(field_ty) {
            out.extend(guard_struct_helper(quote! {
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
            }));
        } else if is_vec_type(field_ty) {
            out.extend(guard_struct_helper(quote! {
                #[no_mangle]
                pub extern "C" fn #getter(ptr: *const #struct_name) -> #field_ty {
                    unsafe { (*ptr).#field_name.clone() }
                }
            }));
        } else {
            out.extend(guard_struct_helper(quote! {
                #[no_mangle]
                pub extern "C" fn #getter(ptr: *const #struct_name) -> #field_ty {
                    unsafe { (*ptr).#field_name }
                }
            }));
        }
        out.extend(struct_field_setter(
            struct_name,
            field_name,
            field_ty,
            &setter,
            &[],
        ));
    }

    if model.derives.iter().any(|d| d == "Clone") {
        meta.has_clone = true;
        let clone_name = format_ident!("{}_clone", stem);
        out.extend(guard_struct_helper(quote! {
            #[no_mangle]
            pub extern "C" fn #clone_name(ptr: *const #struct_name) -> *mut #struct_name {
                unsafe { Box::into_raw(Box::new((*ptr).clone())) }
            }
        }));
    }

    for m in &local {
        out.extend(inline_method_wrapper(
            struct_name,
            &stem,
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
/// (inline flavour, per struct). `self_path` is how the wrapper spells the
/// struct where it is emitted — the bare name next to the struct (inline), the
/// impl header's own path (`super::Gauge`) next to the block (crate, #315) —
/// and `struct_name` the struct's identifier, which a `-> Self` / `-> Gauge`
/// constructor return is recognised by.
#[allow(clippy::too_many_arguments)]
fn method_spec(
    self_path: &syn::Path,
    struct_name: &Ident,
    stem: &Ident,
    m: &MethodModel,
    owned_helper: &Ident,
    owned_free: &Ident,
    borrowed_helper: &Ident,
    declare: bool,
) -> WrapperSpec {
    let method_name = m.func.sig.ident.clone();
    let method_name_str = method_name.to_string();
    let symbol = format_ident!("{}", method_symbol_of(&stem.to_string(), &method_name_str));
    let receiver = (!m.is_static).then(|| WrapperReceiver {
        ty: self_path.clone(),
        mutable: m.is_mutable,
    });
    let target = if m.is_static {
        CallTarget::Assoc {
            ty: self_path.clone(),
            method: method_name,
        }
    } else {
        CallTarget::Instance(method_name)
    };
    let ret = if inline_method_is_ctor(struct_name, m) {
        // `new`, or any method returning `Self` / the struct type, hands Julia
        // an owning pointer. The string helpers are not involved.
        WrapperReturn::Boxed(self_path.clone())
    } else if let Some(r) = method_result_return(m) {
        // A `Result` method is lowered exactly like a free function (#268):
        // `CResult_<Struct>_<method>`, with a `String` payload composed onto
        // the owner's owned-string buffer.
        WrapperReturn::CResult {
            name: format_ident!("CResult_{}_{}", stem, method_name_str),
            ok: payload_of(&r.ok_type, owned_helper, owned_free, declare),
            err: payload_of(&r.err_type, owned_helper, owned_free, declare),
        }
    } else if let Some(o) = method_option_return(m) {
        WrapperReturn::COption {
            name: format_ident!("COption_{}_{}", stem, method_name_str),
            inner: payload_of(&o.inner_type, owned_helper, owned_free, declare),
        }
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
        ret,
        target,
        call_suffix: TokenStream2::new(),
    }
}

/// The `extern "C"` wrapper of an inline struct method. The string buffer types
/// are shared per struct, so the wrapper only refers to them.
fn inline_method_wrapper(
    struct_name: &Ident,
    stem: &Ident,
    m: &MethodModel,
    owned_helper: &Ident,
    owned_free: &Ident,
    borrowed_helper: &Ident,
) -> TokenStream2 {
    generate_wrapper(method_spec(
        &syn::Path::from(struct_name.clone()),
        struct_name,
        stem,
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
