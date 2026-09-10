//! Generating the wrapper crate of a PyO3 crate (#275, Phase 2).
//!
//! Phase 1 ([`crate::pyo3`]) *describes* what a wrapper crate would export.
//! This module writes it: [`wrapper_crate`] turns a scanned [`Manifest`] into
//! the `lib.rs` of a crate that depends on the user's crate and exports one
//! `extern "C"` entry point per wrappable item.
//!
//! # One generator, not a second one
//!
//! Every entry point here is produced by [`crate::codegen::generate_wrapper`],
//! the same function `#[julia]` goes through since #279. The string ABI, the
//! `CResult` / `COption` helpers, the panic channel and the receiver handling
//! are therefore identical by construction — a PyO3-origin item and a
//! `#[julia]` item of the same shape compile to the same wrapper, and Julia
//! calls both through the same emitters.
//!
//! The three things that differ from an in-crate flavour are all inputs to
//! that generator rather than a fork of it:
//!
//! * the item lives in a **dependency**, so the call target is a path
//!   (`user_crate::module::item`) rather than a bare name;
//! * a `PyResult<T>` is lowered by *dropping* the `PyErr`
//!   ([`WrapperSpec::call_suffix`](crate::codegen)), see below;
//! * the spec is built from the manifest rather than from a `syn` item, since
//!   the wrapper crate never sees the user's source.
//!
//! # `PyResult<T>`: an opaque error, never a rendered one
//!
//! Creating and dropping a `PyErr` without a Python interpreter is safe;
//! **rendering** one is not. `Display` / `Debug` on a `PyErr` asserts inside
//! pyo3 that the interpreter is initialised, and the resulting panic crossing
//! `extern "C"` aborts the process (verified in the #275 MWE). Reading the
//! exception *type* would need a `Python` token, which by definition is not
//! available here.
//!
//! So the generated code never touches the `PyErr` beyond dropping it, and the
//! error payload of the `CResult` is the fixed code [`PYERR_CODE`]. Julia turns
//! that into the fixed sentence [`PYERR_MESSAGE`]. There is no way to make the
//! message more specific without an interpreter, and a wrong-but-specific
//! message would be worse than an honest opaque one.
//!
//! # Fail closed
//!
//! An item the generator cannot lower is **not** emitted and its manifest
//! entry gains a [`skip_reason`], exactly as the Phase-1 scan does for an item
//! it cannot describe. A wrapper crate that does not compile would fail the
//! whole `@rust_crate` call, so anything uncertain is refused with a reason a
//! user can read.

use proc_macro2::TokenStream as TokenStream2;
use quote::{format_ident, quote};
use syn::{Ident, Type};

use crate::codegen::{
    field_abi, generate_wrapper, owned_string_helper_items, CallTarget, WrapperPayload,
    WrapperReceiver, WrapperReturn, WrapperSpec,
};
use crate::manifest::{skip_reason, Arg, Manifest, Method, ReturnKind, Struct};
use crate::types::{
    is_ffi_compatible_type, is_str_ref_type, is_string_type, pyo3_vec_element_type,
};

/// The only error value a wrapped `PyResult` reports, see the module docs.
pub const PYERR_CODE: i32 = 1;

/// The message Julia reports for [`PYERR_CODE`]. Kept here so the Rust and the
/// Julia side of the contract are written down in one place;
/// `RustCall.PYO3_OPAQUE_ERROR` must equal it.
pub const PYERR_MESSAGE: &str =
    "PyErr (Python-side error; message unavailable without an interpreter)";

/// The Rust error type a lowered `PyResult` reports across the C ABI.
const PYERR_SLOT: &str = "i32";

/// A generated wrapper crate: its `lib.rs` and the manifest that describes it.
///
/// The manifest is **not** the one that went in: every emitted entry has
/// `exported = true` and a filled-in `return_abi`, and every entry the
/// generator refused carries a new `skip_reason`. Julia consumes this one, so
/// what it binds and what the crate exports cannot drift apart.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct WrapperCrate {
    /// Schema of the embedded manifest, so a consumer can gate on it exactly
    /// as it gates on a plain manifest.
    pub schema_version: u32,
    /// The dependency the wrappers call into, as a Rust identifier.
    pub crate_name: String,
    /// Source of the generated `src/lib.rs`.
    pub lib_rs: String,
    /// What the generated crate exports.
    pub manifest: Manifest,
}

impl WrapperCrate {
    /// Serialize as TOML, the form the CLI writes and Julia reads.
    pub fn to_toml(&self) -> Result<String, toml::ser::Error> {
        toml::to_string(self)
    }

    pub fn from_toml(s: &str) -> Result<WrapperCrate, toml::de::Error> {
        toml::from_str(s)
    }
}

/// Generate the wrapper crate for `scanned`.
///
/// `crate_name` is the *package* name of the dependency; `-` is translated to
/// `_` the way Cargo does when it makes a package name a crate identifier.
///
/// `cfg_resolved` says whether `scanned` was produced under a fully decided
/// configuration (`--cfg-file` without `--cfg-lenient`). When it was not, an
/// item carrying a `#[cfg]` predicate is refused: the scan could not tell
/// whether that item exists in the build the wrapper is compiled against, and
/// calling one that does not is a compile error in generated code. An item
/// marked only through `#[cfg_attr(feature = "python", pyfunction)]` has an
/// empty predicate and is *not* affected — the marker is conditional, the item
/// is not, which is exactly what makes a Python-free wrapper build possible.
pub fn wrapper_crate(scanned: &Manifest, crate_name: &str, cfg_resolved: bool) -> WrapperCrate {
    let krate = format_ident!("{}", crate_name.replace('-', "_"));
    let mut out = Manifest::new(scanned.mode);
    let mut items = TokenStream2::new();

    for f in &scanned.functions {
        if !f.attribute.is_pyo3_scan() {
            // A `#[julia]` item is exported by the user's crate itself; the
            // wrapper crate re-exports nothing and adds nothing.
            out.functions.push(f.clone());
            continue;
        }
        let mut entry = f.clone();
        if !entry.skip_reason.is_empty() {
            out.functions.push(entry);
            continue;
        }
        if let Some(reason) = cfg_refusal(&entry.cfg, cfg_resolved) {
            entry.skip_reason = reason;
            out.functions.push(entry);
            continue;
        }
        match function_wrappers(&krate, &entry) {
            Ok((tokens, updated)) => {
                items.extend(tokens);
                out.functions.extend(updated);
            }
            Err(reason) => {
                entry.skip_reason = reason;
                out.functions.push(entry);
            }
        }
    }

    for s in &scanned.structs {
        if !s.attribute.is_pyo3_scan() {
            out.structs.push(s.clone());
            continue;
        }
        let mut entry = s.clone();
        if entry.skip_reason.is_empty() {
            if let Some(reason) = cfg_refusal(&entry.cfg, cfg_resolved) {
                entry.skip_reason = reason.clone();
                for m in &mut entry.methods {
                    if m.skip_reason.is_empty() {
                        m.skip_reason = skip_reason::detailed(skip_reason::OWNER_SKIPPED, &reason);
                    }
                }
            }
        }
        if !entry.skip_reason.is_empty() {
            // A skipped class has no handle type, so it has no accessors either.
            for f in &mut entry.fields {
                f.ffi_compatible = false;
                f.getter.clear();
                f.setter.clear();
                f.free_symbol.clear();
            }
            out.structs.push(entry);
            continue;
        }
        items.extend(class_wrappers(&krate, &mut entry, cfg_resolved));
        out.structs.push(entry);
    }

    let uses_user_crate = scanned
        .functions
        .iter()
        .any(|f| !f.attribute.is_pyo3_scan() && f.exported)
        || scanned.structs.iter().any(|s| !s.attribute.is_pyo3_scan());

    WrapperCrate {
        schema_version: out.schema_version,
        crate_name: krate.to_string(),
        lib_rs: render(&krate, items, uses_user_crate),
        manifest: out,
    }
}

/// Why a `#[cfg]`-carrying item is refused when the scan could not decide it.
fn cfg_refusal(cfg: &str, cfg_resolved: bool) -> Option<String> {
    if cfg.is_empty() || cfg_resolved {
        return None;
    }
    Some(skip_reason::detailed(skip_reason::CFG_UNDECIDED, cfg))
}

/// The generated file: a header, the optional `use` of the dependency, and the
/// wrappers.
fn render(krate: &Ident, items: TokenStream2, uses_user_crate: bool) -> String {
    // `#[julia]` items of the target crate are exported by the target crate's
    // own object code; the glob import is what pulls that object code into the
    // cdylib, and is why it was here before #275 too.
    let glob = if uses_user_crate {
        quote! {
            #[allow(unused_imports)]
            use #krate::*;
        }
    } else {
        TokenStream2::new()
    };
    let file: syn::File =
        syn::parse2(quote! { #glob #items }).expect("generated wrapper crate is not valid Rust");
    let body = prettyplease::unparse(&file);
    format!(
        "// Generated by RustCall.jl for the PyO3 crate `{krate}` (#275 Phase 2).\n\
         // DO NOT EDIT: regenerate with `@rust_crate` or `write_bindings_to_file`.\n\
         //\n\
         // Every entry point below comes from `rustcall_core::codegen::generate_wrapper`,\n\
         // the generator `#[julia]` uses, so the ABI is the same one Julia already speaks.\n\
         // A `PyResult` error is reported as the opaque code {PYERR_CODE}: the `PyErr` is\n\
         // dropped without ever being rendered, because rendering one without a Python\n\
         // interpreter panics inside pyo3 and the panic would abort the process.\n\
         \n{body}"
    )
}

// ============================================================================
// Free functions
// ============================================================================

fn function_wrapper(
    krate: &Ident,
    f: &crate::manifest::Function,
) -> Result<(TokenStream2, crate::manifest::Function), String> {
    let args = wrapper_args(&f.args)?;
    let symbol = symbol_ident(&f.symbol)?;
    // Helper types and the release function hang off the FFI name (#300).
    let owner = format_ident!("{}", f.ffi_name);
    let plan = return_plan(
        &owner,
        &f.return_type,
        f.return_kind,
        &f.ok_type,
        &f.err_type,
        &f.inner_type,
        None,
        true,
        has_string_args(&f.args),
    )?;
    let tokens = generate_wrapper(WrapperSpec {
        symbol,
        cfg_attrs: Vec::new(),
        receiver: None,
        args,
        ret: plan.ret,
        target: CallTarget::Free(callable_path(
            krate,
            &f.callable_path,
            &f.module_path,
            &f.name,
        )),
        call_suffix: plan.call_suffix,
    });

    let mut updated = f.clone();
    updated.exported = true;
    updated.return_abi = plan.return_abi.to_string();
    updated.ok_abi = plan.ok_abi.to_string();
    updated.has_owned_string_helper = plan.return_abi == "string" || plan.ok_abi == "string";
    updated.has_borrowed_string_helper = plan.return_abi == "str";
    if plan.err_slot {
        updated.err_type = PYERR_SLOT.to_string();
    }
    Ok((tokens, updated))
}

/// Generate the direct wrapper, or one Python-dispatched wrapper per callable
/// positional arity when PyO3 owns default expressions. Calling the generated
/// PyO3 dispatcher is essential: a default may name a private helper in the
/// target module, so copying its Rust expression into this external crate
/// would change scope (or fail to compile).
fn function_wrappers(
    krate: &Ident,
    f: &crate::manifest::Function,
) -> Result<(TokenStream2, Vec<crate::manifest::Function>), String> {
    let defaults = trailing_default_count(&f.args);
    let has_defaults = f.args.iter().any(|arg| !arg.python_default.is_empty());
    if !has_defaults {
        let (tokens, entry) = function_wrapper(krate, f)?;
        return Ok((tokens, vec![entry]));
    }

    let mut tokens = TokenStream2::new();
    let mut entries = Vec::new();
    for omitted in 0..=defaults {
        let mut entry = f.clone();
        entry.args.truncate(f.args.len() - omitted);
        if omitted > 0 {
            entry.symbol = format!("{}__default_{omitted}", f.symbol);
            entry.ffi_name = format!("{}__default_{omitted}", f.ffi_name);
        }
        let (generated, updated) = python_function_wrapper(krate, &entry, f)?;
        tokens.extend(generated);
        entries.push(updated);
    }
    Ok((tokens, entries))
}

fn trailing_default_count(args: &[Arg]) -> usize {
    args.iter()
        .rev()
        .take_while(|arg| !arg.python_default.is_empty())
        .count()
}

fn python_function_wrapper(
    krate: &Ident,
    entry: &crate::manifest::Function,
    original: &crate::manifest::Function,
) -> Result<(TokenStream2, crate::manifest::Function), String> {
    // A Python call unwraps a Rust `Result<T, E>` into either a Python value
    // or an exception, so it cannot be extracted back into the original Rust
    // result type. `PyResult<T>` has a dedicated lowering below; ordinary
    // `Result` defaults are refused instead of silently changing their ABI.
    if entry.return_kind == ReturnKind::Result {
        return Err(skip_reason::detailed(
            skip_reason::UNSUPPORTED_RETURN,
            &entry.return_type,
        ));
    }
    let args = wrapper_args(&entry.args)?;
    let symbol = symbol_ident(&entry.symbol)?;
    let owner = format_ident!("{}", entry.ffi_name);
    let plan = return_plan(
        &owner,
        &entry.return_type,
        entry.return_kind,
        &entry.ok_type,
        &entry.err_type,
        &entry.inner_type,
        None,
        true,
        has_string_args(&entry.args),
    )?;
    let helper = format_ident!("__rustcall_python_dispatch_{}", entry.ffi_name);
    let target = callable_path(
        krate,
        &original.callable_path,
        &original.module_path,
        &original.name,
    );
    let helper_item = python_dispatch_helper(&helper, &target, &args, entry, original)?;
    let wrapper = generate_wrapper(WrapperSpec {
        symbol,
        cfg_attrs: Vec::new(),
        receiver: None,
        args,
        ret: plan.ret,
        target: CallTarget::Free(syn::Path::from(helper)),
        call_suffix: plan.call_suffix,
    });

    let mut updated = entry.clone();
    updated.exported = true;
    updated.return_abi = plan.return_abi.to_string();
    updated.ok_abi = plan.ok_abi.to_string();
    updated.has_owned_string_helper = plan.return_abi == "string" || plan.ok_abi == "string";
    updated.has_borrowed_string_helper = plan.return_abi == "str";
    if plan.err_slot {
        updated.err_type = PYERR_SLOT.to_string();
    }
    Ok((quote! { #helper_item #wrapper }, updated))
}

fn python_dispatch_helper(
    helper: &Ident,
    target: &syn::Path,
    args: &[(Ident, Type)],
    entry: &crate::manifest::Function,
    original: &crate::manifest::Function,
) -> Result<TokenStream2, String> {
    let declarations = args.iter().map(|(name, ty)| quote! { #name: #ty });
    let positional: Vec<_> = args
        .iter()
        .filter(|(name, _)| python_kind(original, name) != "keyword_only")
        .map(|(name, _)| name)
        .collect();
    let keywords: Vec<_> = args
        .iter()
        .filter(|(name, _)| python_kind(original, name) == "keyword_only")
        .map(|(name, _)| {
            let key = name.to_string();
            quote! { rustcall_kwargs.set_item(#key, #name)?; }
        })
        .collect();
    let invoke = if keywords.is_empty() {
        quote! { rustcall_callable.call1((#(#positional,)*))? }
    } else {
        quote! {
            {
                let rustcall_kwargs = ::rustcall_pyo3::types::PyDict::new(py);
                #(#keywords)*
                rustcall_callable.call((#(#positional,)*), Some(&rustcall_kwargs))?
            }
        }
    };
    let extract_type = python_extract_type(entry)?;
    let attached = quote! {
        use ::rustcall_pyo3::types::{PyAnyMethods as _, PyDictMethods as _};
        ::rustcall_pyo3::Python::initialize();
        ::rustcall_pyo3::Python::attach(|py| -> ::rustcall_pyo3::PyResult<#extract_type> {
            let rustcall_callable = ::rustcall_pyo3::wrap_pyfunction!(#target, py)?;
            #invoke.extract::<#extract_type>()
        })
    };
    if entry.return_kind == ReturnKind::PyResult {
        Ok(quote! {
            fn #helper(#(#declarations),*) -> ::rustcall_pyo3::PyResult<#extract_type> { #attached }
        })
    } else {
        let return_type: Type = syn::parse_str(&entry.return_type).map_err(|_| {
            skip_reason::detailed(skip_reason::UNSUPPORTED_RETURN, &entry.return_type)
        })?;
        Ok(quote! {
            fn #helper(#(#declarations),*) -> #return_type {
                #attached.unwrap_or_else(|rustcall_py_err| {
                    panic!("PyO3 dispatcher failed: {}", rustcall_py_err)
                })
            }
        })
    }
}

fn python_kind<'a>(f: &'a crate::manifest::Function, name: &Ident) -> &'a str {
    f.args
        .iter()
        .find(|arg| *name == arg.name)
        .map(|arg| arg.python_kind.as_str())
        .unwrap_or("")
}

fn python_extract_type(f: &crate::manifest::Function) -> Result<Type, String> {
    let spelling = if f.return_kind == ReturnKind::PyResult {
        if f.ok_type.is_empty() {
            "()"
        } else {
            &f.ok_type
        }
    } else if f.return_kind == ReturnKind::Unit {
        "()"
    } else {
        &f.return_type
    };
    syn::parse_str(spelling)
        .map_err(|_| skip_reason::detailed(skip_reason::UNSUPPORTED_RETURN, spelling))
}

// ============================================================================
// `#[pyclass]` handles
// ============================================================================

/// The destructor, the field accessors and the method wrappers of one class.
///
/// The class is an **opaque handle**: a `#[pyclass]` is never `#[repr(C)]`
/// (pyo3 owns its layout), so Julia only ever holds a `*mut Class` and reaches
/// the fields through the accessors pyo3's own `#[pyo3(get, set)]` declared.
///
/// A member whose own `#[cfg]` the scan could not decide (`cfg_resolved` is
/// false and the predicate survived pruning) is refused exactly as an item is:
/// the build the wrapper is compiled against may not have it, and a call to a
/// missing member is a compile error in generated code (#307 review).
fn class_wrappers(krate: &Ident, s: &mut Struct, cfg_resolved: bool) -> TokenStream2 {
    if python_owned_class(s) {
        return python_class_wrappers(krate, s, cfg_resolved);
    }
    let class = callable_path(krate, &s.callable_path, &s.module_path, &s.name);
    let mut out = TokenStream2::new();

    // `<Struct>_free`, the destructor `RustCall.ffi_struct_free_symbol` names
    // from the manifest's `ffi_name` (#300).
    out.extend(crate::codegen::struct_free_wrapper(
        &class,
        &format_ident!("{}", s.ffi_name),
        &[],
    ));

    // The struct-level owned-string buffer, shared by every `String` field
    // getter (`RustCall._ffi_field_return` names it after the struct).
    let owned_helper = format_ident!("{}_RustCallOwnedString", s.ffi_name);
    let owned_free = format_ident!("{}_free_rust_string", s.ffi_name);
    for f in &mut s.fields {
        if cfg_refusal(&f.cfg, cfg_resolved).is_some() {
            f.ffi_compatible = false;
            f.getter.clear();
            f.setter.clear();
            f.free_symbol.clear();
        }
    }

    let needs_owned = s.fields.iter().any(|f| {
        !f.getter.is_empty() && f.ffi_compatible && field_abi_of(&f.rust_type) == "string"
    });
    s.has_owned_string_helper = needs_owned;
    s.has_borrowed_string_helper = false;
    s.has_clone = false;
    if needs_owned {
        out.extend(owned_string_helper_items(&owned_helper, &owned_free));
    }

    for f in &mut s.fields {
        // A getter, a setter, or both: `#[pyo3(get)]` and `#[pyo3(set)]` are
        // independent, so a `set`-only field is a setter with no getter, not a
        // field with nothing (#307 review).
        if !f.ffi_compatible || (f.getter.is_empty() && f.setter.is_empty()) {
            continue;
        }
        let Ok(field) = syn::parse_str::<Ident>(&f.name) else {
            f.ffi_compatible = false;
            f.getter.clear();
            f.setter.clear();
            f.free_symbol.clear();
            continue;
        };
        let Ok(ty) = syn::parse_str::<Type>(&f.rust_type) else {
            f.ffi_compatible = false;
            f.getter.clear();
            f.setter.clear();
            f.free_symbol.clear();
            continue;
        };
        let vec_element = pyo3_vec_element_type(&ty);
        if is_string_type(&ty) {
            if !f.getter.is_empty() {
                let getter = format_ident!("{}", f.getter);
                out.extend(crate::codegen::guard_struct_helper(quote! {
                    #[no_mangle]
                    pub extern "C" fn #getter(ptr: *const #class) -> #owned_helper {
                        let mut rustcall_bytes = unsafe { (*ptr).#field.clone().into_bytes() };
                        let rustcall_ret = #owned_helper {
                            ptr: rustcall_bytes.as_mut_ptr(),
                            len: rustcall_bytes.len(),
                            cap: rustcall_bytes.capacity(),
                        };
                        ::std::mem::forget(rustcall_bytes);
                        rustcall_ret
                    }
                }));
            }
        } else if let Some(element) = &vec_element {
            if !f.getter.is_empty() {
                let getter = format_ident!("{}", f.getter);
                let helper = format_ident!("{}_RustCallOwnedVec", f.getter);
                let Ok(free) = syn::parse_str::<Ident>(&f.free_symbol) else {
                    f.ffi_compatible = false;
                    f.getter.clear();
                    f.setter.clear();
                    f.free_symbol.clear();
                    continue;
                };
                out.extend(quote! {
                    #[repr(C)]
                    pub struct #helper {
                        pub ptr: *mut #element,
                        pub len: usize,
                        pub cap: usize,
                    }

                    #[no_mangle]
                    pub extern "C" fn #free(value: #helper) {
                        if !value.ptr.is_null() {
                            unsafe { drop(Vec::from_raw_parts(value.ptr, value.len, value.cap)); }
                        }
                    }
                });
                out.extend(crate::codegen::guard_struct_helper(quote! {
                    #[no_mangle]
                    pub extern "C" fn #getter(ptr: *const #class) -> #helper {
                        let mut rustcall_vec = unsafe { (*ptr).#field.clone() };
                        let rustcall_ret = #helper {
                            ptr: rustcall_vec.as_mut_ptr(),
                            len: rustcall_vec.len(),
                            cap: rustcall_vec.capacity(),
                        };
                        ::std::mem::forget(rustcall_vec);
                        rustcall_ret
                    }
                }));
            }
        } else {
            if !f.getter.is_empty() {
                let getter = format_ident!("{}", f.getter);
                // Only `Copy` FFI types reach here: `String` has its own
                // branch above and the scan gives a `Vec<T>` no accessor
                // (no ABI for it on the Julia side yet, #303).
                out.extend(crate::codegen::guard_struct_helper(quote! {
                    #[no_mangle]
                    pub extern "C" fn #getter(ptr: *const #class) -> #ty {
                        unsafe { (*ptr).#field }
                    }
                }));
            }
        }
        if !f.setter.is_empty() {
            if let Some(element) = &vec_element {
                let setter = format_ident!("{}", f.setter);
                out.extend(crate::codegen::guard_struct_helper(quote! {
                    #[no_mangle]
                    pub extern "C" fn #setter(
                        ptr: *mut #class,
                        value: *const #element,
                        len: usize,
                    ) {
                        let value = if len == 0 {
                            Vec::new()
                        } else {
                            assert!(!value.is_null(), "non-empty Vec field input has a null pointer");
                            unsafe { ::std::slice::from_raw_parts(value, len).to_vec() }
                        };
                        unsafe { (*ptr).#field = value; }
                    }
                }));
            } else {
                // Share byte-pair String conversion and the panic boundary with
                // the in-crate/inline accessor generator (#303).
                out.extend(crate::codegen::struct_field_setter(
                    &class,
                    &field,
                    &ty,
                    &format_ident!("{}", f.setter),
                    &[],
                ));
            }
        }
    }

    let class_name = s.ffi_name.clone();
    for m in &mut s.methods {
        if !m.skip_reason.is_empty() {
            continue;
        }
        if let Some(reason) = cfg_refusal(&m.cfg, cfg_resolved) {
            m.skip_reason = reason;
            continue;
        }
        match method_wrapper(&class, &class_name, m) {
            Ok(tokens) => out.extend(tokens),
            Err(reason) => m.skip_reason = reason,
        }
    }
    out
}

fn python_owned_class(s: &Struct) -> bool {
    !s.pyo3_extends.is_empty()
        || s.methods
            .iter()
            .flat_map(|method| &method.args)
            .any(|arg| !arg.python_default.is_empty())
}

/// A class whose Python object owns state beyond the Rust `Self` value. This
/// covers inheritance initializers `(Self, Base)` and methods whose defaults
/// are evaluated by PyO3. Julia's pointer names a preallocated queue node
/// holding `Py<PyAny>`; the destructor only publishes that node atomically.
fn python_class_wrappers(krate: &Ident, s: &mut Struct, cfg_resolved: bool) -> TokenStream2 {
    let class = callable_path(krate, &s.callable_path, &s.module_path, &s.name);
    let handle = format_ident!("{}_RustCallPythonHandle", s.ffi_name);
    let pending = format_ident!("__RUSTCALL_PENDING_{}", s.ffi_name.to_uppercase());
    let drain = format_ident!("__rustcall_drain_{}", s.ffi_name);
    let start_drain = format_ident!("__rustcall_start_drain_{}", s.ffi_name);
    let drain_started = format_ident!("__RUSTCALL_DRAIN_STARTED_{}", s.ffi_name.to_uppercase());
    let free = format_ident!("{}_free", s.ffi_name);
    let mut out = quote! {
        struct #handle {
            object: ::std::option::Option<::rustcall_pyo3::Py<::rustcall_pyo3::PyAny>>,
            next: *mut #handle,
        }
        static #pending: ::std::sync::atomic::AtomicPtr<#handle> =
            ::std::sync::atomic::AtomicPtr::new(::std::ptr::null_mut());
        static #drain_started: ::std::sync::atomic::AtomicBool =
            ::std::sync::atomic::AtomicBool::new(false);

        fn #drain(_py: ::rustcall_pyo3::Python<'_>) {
            let mut rustcall_node = #pending.swap(
                ::std::ptr::null_mut(),
                ::std::sync::atomic::Ordering::Acquire,
            );
            while !rustcall_node.is_null() {
                let mut rustcall_box = unsafe { Box::from_raw(rustcall_node) };
                rustcall_node = rustcall_box.next;
                ::std::mem::drop(rustcall_box.object.take());
            }
        }

        fn #start_drain() {
            if #drain_started.compare_exchange(
                false,
                true,
                ::std::sync::atomic::Ordering::AcqRel,
                ::std::sync::atomic::Ordering::Acquire,
            ).is_ok() {
                ::std::thread::spawn(|| loop {
                    ::std::thread::park_timeout(::std::time::Duration::from_millis(25));
                    ::rustcall_pyo3::Python::attach(|py| #drain(py));
                });
            }
        }

        #[no_mangle]
        pub extern "C" fn #free(ptr: *mut #handle) {
            if ptr.is_null() { return; }
            let mut rustcall_head = #pending.load(::std::sync::atomic::Ordering::Relaxed);
            loop {
                unsafe { (*ptr).next = rustcall_head; }
                match #pending.compare_exchange_weak(
                    rustcall_head,
                    ptr,
                    ::std::sync::atomic::Ordering::Release,
                    ::std::sync::atomic::Ordering::Relaxed,
                ) {
                    Ok(_) => break,
                    Err(rustcall_actual) => rustcall_head = rustcall_actual,
                }
            }
        }
    };

    let needs_owned = s.fields.iter().any(|field| {
        !field.getter.is_empty()
            && syn::parse_str::<Type>(&field.rust_type).is_ok_and(|ty| is_string_type(&ty))
    });
    if needs_owned {
        out.extend(owned_string_helper_items(
            &format_ident!("{}_RustCallOwnedString", s.ffi_name),
            &format_ident!("{}_free_rust_string", s.ffi_name),
        ));
    }

    for field in &mut s.fields {
        if cfg_refusal(&field.cfg, cfg_resolved).is_some() {
            field.ffi_compatible = false;
            field.getter.clear();
            field.setter.clear();
            field.free_symbol.clear();
            continue;
        }
        match python_field_wrappers(&handle, &drain, field, &s.ffi_name) {
            Ok(tokens) => out.extend(tokens),
            Err(_) => {
                field.ffi_compatible = false;
                field.getter.clear();
                field.setter.clear();
                field.free_symbol.clear();
            }
        }
    }
    s.has_owned_string_helper = needs_owned;
    s.has_borrowed_string_helper = false;
    s.has_clone = false;

    let originals = s.methods.clone();
    s.methods.clear();
    for original in originals {
        if !original.skip_reason.is_empty() {
            s.methods.push(original);
            continue;
        }
        if let Some(reason) = cfg_refusal(&original.cfg, cfg_resolved) {
            let mut refused = original;
            refused.skip_reason = reason;
            s.methods.push(refused);
            continue;
        }
        let defaults = trailing_default_count(&original.args);
        for omitted in 0..=defaults {
            let mut entry = original.clone();
            entry.args.truncate(original.args.len() - omitted);
            if omitted > 0 {
                entry.symbol = format!("{}__default_{omitted}", original.symbol);
            }
            match python_method_wrapper(
                &class,
                &handle,
                &drain,
                &start_drain,
                &s.ffi_name,
                &mut entry,
                &original,
            ) {
                Ok(tokens) => {
                    out.extend(tokens);
                    s.methods.push(entry);
                }
                Err(reason) => {
                    entry.skip_reason = reason;
                    s.methods.push(entry);
                }
            }
        }
    }
    out
}

fn python_field_wrappers(
    handle: &Ident,
    drain: &Ident,
    field: &mut crate::manifest::Field,
    class_name: &str,
) -> Result<TokenStream2, String> {
    if !field.ffi_compatible {
        return Ok(TokenStream2::new());
    }
    let ty: Type = syn::parse_str(&field.rust_type)
        .map_err(|_| skip_reason::detailed(skip_reason::UNSUPPORTED_RETURN, &field.rust_type))?;
    if !(is_ffi_compatible_type(&ty) || is_string_type(&ty)) {
        return Err(skip_reason::detailed(
            skip_reason::UNSUPPORTED_RETURN,
            &field.rust_type,
        ));
    }
    let python_name = if field.python_name.is_empty() {
        field.name.clone()
    } else {
        field.python_name.clone()
    };
    let mut out = TokenStream2::new();
    if !field.getter.is_empty() {
        let symbol = symbol_ident(&field.getter)?;
        let helper = format_ident!("__rustcall_python_{}_get_{}", class_name, field.name);
        out.extend(quote! {
            fn #helper(ptr: *mut #handle) -> #ty {
                use ::rustcall_pyo3::types::PyAnyMethods as _;
                ::rustcall_pyo3::Python::initialize();
                ::rustcall_pyo3::Python::attach(|py| -> ::rustcall_pyo3::PyResult<#ty> {
                    #drain(py);
                    assert!(!ptr.is_null(), "null Python-owned class handle");
                    let rustcall_object = unsafe { (*ptr).object.as_ref().expect("retired Python-owned class handle") };
                    rustcall_object.bind(py).getattr(#python_name)?.extract::<#ty>()
                }).unwrap_or_else(|rustcall_py_err| panic!("PyO3 field getter failed: {}", rustcall_py_err))
            }
        });
        let ret = if is_string_type(&ty) {
            WrapperReturn::OwnedString {
                helper: format_ident!("{}_RustCallOwnedString", class_name),
                free: format_ident!("{}_free_rust_string", class_name),
                declare: false,
            }
        } else {
            WrapperReturn::Plain(ty.clone())
        };
        out.extend(generate_wrapper(WrapperSpec {
            symbol,
            cfg_attrs: Vec::new(),
            receiver: None,
            args: vec![(format_ident!("ptr"), syn::parse_quote!(*mut #handle))],
            ret,
            target: CallTarget::Free(syn::Path::from(helper)),
            call_suffix: TokenStream2::new(),
        }));
    }
    if !field.setter.is_empty() {
        let symbol = symbol_ident(&field.setter)?;
        let helper = format_ident!("__rustcall_python_{}_set_{}", class_name, field.name);
        out.extend(quote! {
            fn #helper(ptr: *mut #handle, value: #ty) {
                use ::rustcall_pyo3::types::PyAnyMethods as _;
                ::rustcall_pyo3::Python::initialize();
                ::rustcall_pyo3::Python::attach(|py| -> ::rustcall_pyo3::PyResult<()> {
                    #drain(py);
                    assert!(!ptr.is_null(), "null Python-owned class handle");
                    let rustcall_object = unsafe { (*ptr).object.as_ref().expect("retired Python-owned class handle") };
                    rustcall_object.bind(py).setattr(#python_name, value)
                }).unwrap_or_else(|rustcall_py_err| panic!("PyO3 field setter failed: {}", rustcall_py_err))
            }
        });
        out.extend(generate_wrapper(WrapperSpec {
            symbol,
            cfg_attrs: Vec::new(),
            receiver: None,
            args: vec![
                (format_ident!("ptr"), syn::parse_quote!(*mut #handle)),
                (format_ident!("value"), ty),
            ],
            ret: WrapperReturn::Unit,
            target: CallTarget::Free(syn::Path::from(helper)),
            call_suffix: TokenStream2::new(),
        }));
    }
    Ok(out)
}

fn python_method_wrapper(
    class: &syn::Path,
    handle: &Ident,
    drain: &Ident,
    start_drain: &Ident,
    class_name: &str,
    entry: &mut Method,
    original: &Method,
) -> Result<TokenStream2, String> {
    let native_args = wrapper_args(&entry.args)?;
    let symbol = symbol_ident(&entry.symbol)?;
    let helper = format_ident!(
        "__rustcall_python_{}_{}{}",
        class_name,
        entry.name,
        if entry.args.len() == original.args.len() {
            String::new()
        } else {
            format!("_default_{}", original.args.len() - entry.args.len())
        }
    );
    let declarations: Vec<_> = native_args
        .iter()
        .map(|(name, ty)| quote! { #name: #ty })
        .collect();
    let (call_setup, positional_args, keyword_args) =
        python_call_arguments(&native_args, &original.args);
    let python_name = if original.python_name.is_empty() {
        original.name.clone()
    } else {
        original.python_name.clone()
    };
    let omitted = original.args.len() - entry.args.len();
    let mut owner_name = crate::codegen::method_string_owner(class_name, &entry.name);
    if omitted > 0 {
        owner_name.push_str(&format!("__default_{omitted}"));
    }

    if entry.is_constructor {
        let attached = quote! {
            use ::rustcall_pyo3::types::{PyAnyMethods as _, PyDictMethods as _};
            ::rustcall_pyo3::Python::initialize();
            #start_drain();
            ::rustcall_pyo3::Python::attach(|py| -> ::rustcall_pyo3::PyResult<*mut #handle> {
                #drain(py);
                #call_setup
                let rustcall_class = py.get_type::<#class>();
                let rustcall_object = rustcall_class.call(#positional_args, #keyword_args)?;
                Ok(Box::into_raw(Box::new(#handle {
                    object: Some(rustcall_object.unbind()),
                    next: ::std::ptr::null_mut(),
                })))
            })
        };
        let (helper_item, ret, call_suffix) = if entry.return_kind == ReturnKind::PyResult {
            let aggregate = format_ident!("CResult_{}", owner_name);
            let pointer: Type = syn::parse_quote!(*mut #handle);
            let error: Type = syn::parse_str(PYERR_SLOT).expect("i32 parses");
            (
                quote! {
                    fn #helper(#(#declarations),*) -> ::rustcall_pyo3::PyResult<*mut #handle> {
                        #attached
                    }
                },
                WrapperReturn::CResult {
                    name: aggregate,
                    ok: WrapperPayload::Plain(pointer),
                    err: WrapperPayload::Plain(error),
                },
                quote! {
                    .map_err(|rustcall_py_err| {
                        ::std::mem::drop(rustcall_py_err);
                        #PYERR_CODE
                    })
                },
            )
        } else {
            (
                quote! {
                    fn #helper(#(#declarations),*) -> *mut #handle {
                        #attached.unwrap_or_else(|rustcall_py_err| {
                            panic!("PyO3 constructor failed: {}", rustcall_py_err)
                        })
                    }
                },
                WrapperReturn::Plain(syn::parse_quote!(*mut #handle)),
                TokenStream2::new(),
            )
        };
        let wrapper = generate_wrapper(WrapperSpec {
            symbol,
            cfg_attrs: Vec::new(),
            receiver: None,
            args: native_args,
            ret,
            target: CallTarget::Free(syn::Path::from(helper)),
            call_suffix,
        });
        entry.returns_boxed_struct = true;
        entry.return_abi.clear();
        entry.ok_abi.clear();
        entry.err_abi.clear();
        entry.string_owner = owner_name;
        if entry.return_kind == ReturnKind::PyResult {
            entry.err_type = PYERR_SLOT.to_string();
        }
        return Ok(quote! { #helper_item #wrapper });
    }

    let extract_type = python_method_extract_type(entry)?;
    let mut helper_declarations = Vec::new();
    if !entry.is_static {
        helper_declarations.push(quote! { ptr: *mut #handle });
    }
    helper_declarations.extend(declarations.iter().cloned());
    let call = if entry.is_static {
        quote! {
            let rustcall_class = py.get_type::<#class>();
            rustcall_class.getattr(#python_name)?.call(#positional_args, #keyword_args)?
        }
    } else {
        quote! {
            assert!(!ptr.is_null(), "null Python-owned class handle");
            let rustcall_object = unsafe { (*ptr).object.as_ref().expect("retired Python-owned class handle") };
            rustcall_object.bind(py).call_method(#python_name, #positional_args, #keyword_args)?
        }
    };

    // A Python-owned class method returning `Self` yields a Python object, not
    // a Rust value which can be extracted and boxed independently. Preserve
    // that exact object (and therefore any base-class state) in a fresh opaque
    // handle. Julia already treats `returns_boxed_struct` as an owned handle.
    if entry.returns_boxed_struct {
        let attached = quote! {
            use ::rustcall_pyo3::types::{PyAnyMethods as _, PyDictMethods as _};
            ::rustcall_pyo3::Python::initialize();
            #start_drain();
            ::rustcall_pyo3::Python::attach(|py| -> ::rustcall_pyo3::PyResult<*mut #handle> {
                #drain(py);
                #call_setup
                let rustcall_object = { #call };
                Ok(Box::into_raw(Box::new(#handle {
                    object: Some(rustcall_object.unbind()),
                    next: ::std::ptr::null_mut(),
                })))
            })
        };
        let (helper_item, ret, call_suffix) = if entry.return_kind == ReturnKind::PyResult {
            let aggregate = format_ident!("CResult_{}", owner_name);
            let pointer: Type = syn::parse_quote!(*mut #handle);
            let error: Type = syn::parse_str(PYERR_SLOT).expect("i32 parses");
            (
                quote! {
                    fn #helper(#(#helper_declarations),*) -> ::rustcall_pyo3::PyResult<*mut #handle> {
                        #attached
                    }
                },
                WrapperReturn::CResult {
                    name: aggregate,
                    ok: WrapperPayload::Plain(pointer),
                    err: WrapperPayload::Plain(error),
                },
                quote! {
                    .map_err(|rustcall_py_err| {
                        ::std::mem::drop(rustcall_py_err);
                        #PYERR_CODE
                    })
                },
            )
        } else if entry.return_kind == ReturnKind::Plain {
            (
                quote! {
                    fn #helper(#(#helper_declarations),*) -> *mut #handle {
                        #attached.unwrap_or_else(|rustcall_py_err| {
                            panic!("PyO3 method failed: {}", rustcall_py_err)
                        })
                    }
                },
                WrapperReturn::Plain(syn::parse_quote!(*mut #handle)),
                TokenStream2::new(),
            )
        } else {
            return Err(skip_reason::detailed(
                skip_reason::UNSUPPORTED_RETURN,
                &entry.return_type,
            ));
        };
        let mut ffi_args = Vec::new();
        if !entry.is_static {
            ffi_args.push((format_ident!("ptr"), syn::parse_quote!(*mut #handle)));
        }
        ffi_args.extend(native_args);
        let wrapper = generate_wrapper(WrapperSpec {
            symbol,
            cfg_attrs: Vec::new(),
            receiver: None,
            args: ffi_args,
            ret,
            target: CallTarget::Free(syn::Path::from(helper)),
            call_suffix,
        });
        entry.return_abi.clear();
        entry.ok_abi.clear();
        entry.string_owner = owner_name;
        if entry.return_kind == ReturnKind::PyResult {
            entry.err_type = PYERR_SLOT.to_string();
        }
        return Ok(quote! { #helper_item #wrapper });
    }

    let attached = quote! {
        use ::rustcall_pyo3::types::{PyAnyMethods as _, PyDictMethods as _};
        ::rustcall_pyo3::Python::initialize();
        ::rustcall_pyo3::Python::attach(|py| -> ::rustcall_pyo3::PyResult<#extract_type> {
            #drain(py);
            #call_setup
            let rustcall_result = { #call };
            rustcall_result.extract::<#extract_type>()
        })
    };
    let helper_item = if entry.return_kind == ReturnKind::PyResult {
        quote! {
            fn #helper(#(#helper_declarations),*) -> ::rustcall_pyo3::PyResult<#extract_type> {
                #attached
            }
        }
    } else {
        let ret: Type = syn::parse_str(&entry.return_type).map_err(|_| {
            skip_reason::detailed(skip_reason::UNSUPPORTED_RETURN, &entry.return_type)
        })?;
        quote! {
            fn #helper(#(#helper_declarations),*) -> #ret {
                #attached.unwrap_or_else(|rustcall_py_err| panic!("PyO3 method failed: {}", rustcall_py_err))
            }
        }
    };

    let owner = format_ident!("{}", owner_name);
    let plan = return_plan(
        &owner,
        &entry.return_type,
        entry.return_kind,
        &entry.ok_type,
        &entry.err_type,
        &entry.inner_type,
        None,
        false,
        has_string_args(&entry.args),
    )?;
    let mut ffi_args = Vec::new();
    if !entry.is_static {
        ffi_args.push((format_ident!("ptr"), syn::parse_quote!(*mut #handle)));
    }
    ffi_args.extend(native_args);
    let wrapper = generate_wrapper(WrapperSpec {
        symbol,
        cfg_attrs: Vec::new(),
        receiver: None,
        args: ffi_args,
        ret: plan.ret,
        target: CallTarget::Free(syn::Path::from(helper)),
        call_suffix: plan.call_suffix,
    });
    entry.return_abi = plan.return_abi.to_string();
    entry.ok_abi = plan.ok_abi.to_string();
    entry.string_owner = owner.to_string();
    if plan.err_slot {
        entry.err_type = PYERR_SLOT.to_string();
    }
    Ok(quote! { #helper_item #wrapper })
}

/// Statements creating `rustcall_kwargs`, and `(args, kwargs)` tokens suitable
/// for `PyAny::call` / `call_method`. Julia keeps Rust's positional surface;
/// keyword-only parameters are placed into Python kwargs internally.
fn python_call_arguments(
    args: &[(Ident, Type)],
    original: &[Arg],
) -> (TokenStream2, TokenStream2, TokenStream2) {
    let positional: Vec<_> = args
        .iter()
        .filter(|(name, _)| arg_python_kind(original, name) != "keyword_only")
        .map(|(name, _)| name)
        .collect();
    let keywords: Vec<_> = args
        .iter()
        .filter(|(name, _)| arg_python_kind(original, name) == "keyword_only")
        .map(|(name, _)| {
            let key = name.to_string();
            quote! { rustcall_kwargs.set_item(#key, #name)?; }
        })
        .collect();
    if keywords.is_empty() {
        (
            TokenStream2::new(),
            quote! { (#(#positional,)*) },
            quote! { None },
        )
    } else {
        (
            quote! {
                let rustcall_kwargs = ::rustcall_pyo3::types::PyDict::new(py);
                #(#keywords)*
            },
            quote! { (#(#positional,)*) },
            quote! { Some(&rustcall_kwargs) },
        )
    }
}

fn arg_python_kind<'a>(args: &'a [Arg], name: &Ident) -> &'a str {
    args.iter()
        .find(|arg| *name == arg.name)
        .map(|arg| arg.python_kind.as_str())
        .unwrap_or("")
}

fn python_method_extract_type(method: &Method) -> Result<Type, String> {
    let spelling = if method.return_kind == ReturnKind::PyResult {
        if method.ok_type.is_empty() {
            "()"
        } else {
            &method.ok_type
        }
    } else if method.return_kind == ReturnKind::Unit {
        "()"
    } else {
        &method.return_type
    };
    syn::parse_str(spelling)
        .map_err(|_| skip_reason::detailed(skip_reason::UNSUPPORTED_RETURN, spelling))
}

fn method_wrapper(
    class: &syn::Path,
    class_name: &str,
    m: &mut Method,
) -> Result<TokenStream2, String> {
    let args = wrapper_args(&m.args)?;
    let symbol = symbol_ident(&m.symbol)?;
    let method = symbol_ident(&m.name)?;
    // The crate flavour names a method's string buffers after the method, so
    // `RustCall._emit_method_code`'s `<Struct>_<method>` owner matches.
    let owner = format_ident!(
        "{}",
        crate::codegen::method_string_owner(class_name, &m.name)
    );
    let boxed = m.returns_boxed_struct.then(|| class.clone());
    let plan = return_plan(
        &owner,
        &m.return_type,
        m.return_kind,
        &m.ok_type,
        &m.err_type,
        &m.inner_type,
        boxed,
        false,
        has_string_args(&m.args),
    )?;
    let receiver = (!m.is_static).then(|| WrapperReceiver {
        ty: class.clone(),
        mutable: m.is_mutable,
    });
    let target = if m.is_static {
        CallTarget::Assoc {
            ty: class.clone(),
            method,
        }
    } else {
        CallTarget::Instance(method)
    };
    let tokens = generate_wrapper(WrapperSpec {
        symbol,
        cfg_attrs: Vec::new(),
        receiver,
        args,
        ret: plan.ret,
        target,
        call_suffix: plan.call_suffix,
    });
    m.return_abi = plan.return_abi.to_string();
    m.ok_abi = plan.ok_abi.to_string();
    // The wrapper this crate generates declares its own buffers, so the
    // manifest it hands Julia states their owner (#342).
    m.string_owner = owner.to_string();
    if plan.err_slot {
        m.err_type = PYERR_SLOT.to_string();
    }
    Ok(tokens)
}

// ============================================================================
// Signature lowering
// ============================================================================

/// How one item's return value crosses the C ABI.
struct ReturnPlan {
    ret: WrapperReturn,
    /// Appended to the call, see [`WrapperSpec::call_suffix`](crate::codegen).
    call_suffix: TokenStream2,
    /// Manifest `return_abi`: `""`, `"string"` or `"str"`.
    return_abi: &'static str,
    /// How the successful payload of a `PyResult` is stored. Empty as written,
    /// or `"string"` for the owner's owned-string buffer.
    ok_abi: &'static str,
    /// Whether the manifest entry's `err_type` becomes [`PYERR_SLOT`].
    err_slot: bool,
}

/// Whether any argument is lowered from a `(ptr, len)` pair into an owned
/// value the wrapper drops when it returns — the case in which a borrowed
/// `&str` result must be copied instead (see [`return_plan`]).
fn has_string_args(args: &[Arg]) -> bool {
    args.iter().any(|a| {
        syn::parse_str::<Type>(&a.rust_type)
            .map(|ty| is_string_type(&ty) || is_str_ref_type(&ty))
            .unwrap_or(false)
    })
}

/// The wrapper arguments of a manifest signature.
///
/// `String` / `&str` are lowered to `(ptr, len)` byte pairs by
/// [`generate_wrapper`] itself, so they only have to be *accepted* here;
/// everything else must be an FFI-compatible type, because the wrapper passes
/// it through as written.
fn wrapper_args(args: &[Arg]) -> Result<Vec<(Ident, Type)>, String> {
    let mut out = Vec::new();
    for a in args {
        let name = syn::parse_str::<Ident>(&a.name)
            .map_err(|_| skip_reason::detailed(skip_reason::UNSUPPORTED_ARG, &a.name))?;
        let ty = syn::parse_str::<Type>(&a.rust_type)
            .map_err(|_| skip_reason::detailed(skip_reason::UNSUPPORTED_ARG, &a.rust_type))?;
        if !(is_string_type(&ty) || is_str_ref_type(&ty) || is_ffi_compatible_type(&ty)) {
            return Err(skip_reason::detailed(
                skip_reason::UNSUPPORTED_ARG,
                &a.rust_type,
            ));
        }
        out.push((name, ty));
    }
    Ok(out)
}

/// `wraps_aggregates` says whether a plain `Result` / `Option` return may be
/// lowered to a `CResult` / `COption`.
///
/// Only a **free function** may here: a `#[julia]` method now does (#268,
/// `codegen::method_spec`), decoded by `RustCall._method_payload_plan`, but
/// that Julia-side emitter is keyed to a `#[julia]`-attributed method and does
/// not run for a `#[pymethods]` one scanned by this module. Emitting a
/// `CResult` / `COption` from a `#[pymethods]` wrapper here would therefore
/// still produce a symbol nothing on the Julia side knows how to decode — the
/// one shape that is worse than not wrapping the method at all. It is refused
/// instead, and #303 owns widening the PyO3 wrapper path to match.
#[allow(clippy::too_many_arguments)]
fn return_plan(
    owner: &Ident,
    return_type: &str,
    kind: ReturnKind,
    ok_type: &str,
    err_type: &str,
    inner_type: &str,
    boxed: Option<syn::Path>,
    wraps_aggregates: bool,
    has_string_args: bool,
) -> Result<ReturnPlan, String> {
    let plain = |ret| ReturnPlan {
        ret,
        call_suffix: TokenStream2::new(),
        return_abi: "",
        ok_abi: "",
        err_slot: false,
    };

    match kind {
        ReturnKind::Unit => Ok(plain(WrapperReturn::Unit)),
        ReturnKind::PyResult => py_result_plan(owner, ok_type, boxed),
        ReturnKind::Result => {
            if !wraps_aggregates {
                return Err(skip_reason::detailed(
                    skip_reason::UNSUPPORTED_RETURN,
                    return_type,
                ));
            }
            let ok = payload_type(ok_type)?;
            let err = payload_type(err_type)?;
            Ok(plain(WrapperReturn::CResult {
                name: format_ident!("CResult_{}", owner),
                ok,
                err,
            }))
        }
        ReturnKind::Option => {
            if !wraps_aggregates {
                return Err(skip_reason::detailed(
                    skip_reason::UNSUPPORTED_RETURN,
                    return_type,
                ));
            }
            let inner = payload_type(inner_type)?;
            Ok(plain(WrapperReturn::COption {
                name: format_ident!("COption_{}", owner),
                inner,
            }))
        }
        ReturnKind::Plain => {
            if let Some(class) = boxed {
                return Ok(plain(WrapperReturn::Boxed(class)));
            }
            let ty = syn::parse_str::<Type>(return_type)
                .map_err(|_| skip_reason::detailed(skip_reason::UNSUPPORTED_RETURN, return_type))?;
            if is_string_type(&ty) {
                return Ok(ReturnPlan {
                    ret: WrapperReturn::OwnedString {
                        helper: format_ident!("{}_RustCallOwnedString", owner),
                        free: format_ident!("{}_free_rust_string", owner),
                        declare: true,
                    },
                    call_suffix: TokenStream2::new(),
                    return_abi: "string",
                    ok_abi: "",
                    err_slot: false,
                });
            }
            if is_str_ref_type(&ty) {
                // The wrapper builds its string arguments as owned values
                // (`String::from_utf8_lossy`) that die when the call returns,
                // so a `&str` result of a function that *takes* a string may
                // point into one of them. Copy it out, exactly as the in-crate
                // generator does (`codegen::returns_copied_str`, #242); only a
                // `&str` with nothing to borrow from is handed over as a view
                // (#307 review).
                if has_string_args {
                    return Ok(ReturnPlan {
                        ret: WrapperReturn::OwnedString {
                            helper: format_ident!("{}_RustCallOwnedString", owner),
                            free: format_ident!("{}_free_rust_string", owner),
                            declare: true,
                        },
                        call_suffix: TokenStream2::new(),
                        return_abi: "string",
                        ok_abi: "",
                        err_slot: false,
                    });
                }
                return Ok(ReturnPlan {
                    ret: WrapperReturn::BorrowedStr {
                        helper: format_ident!("{}_RustCallBorrowedString", owner),
                        declare: true,
                    },
                    call_suffix: TokenStream2::new(),
                    return_abi: "str",
                    ok_abi: "",
                    err_slot: false,
                });
            }
            if !is_ffi_compatible_type(&ty) {
                return Err(skip_reason::detailed(
                    skip_reason::UNSUPPORTED_RETURN,
                    return_type,
                ));
            }
            Ok(plain(WrapperReturn::Plain(ty)))
        }
    }
}

/// `PyResult<T>`: a `CResult` whose error payload is [`PYERR_CODE`].
///
/// The `PyErr` is moved into `drop` and never rendered — see the module docs.
/// Scalar `T` is stored directly, `String` / `&str` uses the owner's released
/// buffer, and a class-valued `Self` is boxed inside the success slot. Other
/// aggregate payloads remain fail-closed (#303).
fn py_result_plan(
    owner: &Ident,
    ok_type: &str,
    boxed: Option<syn::Path>,
) -> Result<ReturnPlan, String> {
    let name = format_ident!("CResult_{}", owner);
    let err: Type = syn::parse_str(PYERR_SLOT).expect("i32 parses");
    let drop_err = quote! {
        .map_err(|rustcall_py_err| {
            // NEVER render this: `Display`/`Debug` on a `PyErr` asserts that
            // the interpreter is initialised and panics when it is not, and
            // the panic crossing `extern "C"` aborts the process (#275).
            ::std::mem::drop(rustcall_py_err);
            #PYERR_CODE
        })
    };

    if ok_type.is_empty() || ok_type == "()" {
        // `PyResult<()>` still has to report success or failure, so the `Ok`
        // slot is a `u8` placeholder rather than a zero-sized field.
        let ok: Type = syn::parse_str("u8").expect("u8 parses");
        return Ok(ReturnPlan {
            ret: WrapperReturn::CResult {
                name,
                ok: WrapperPayload::Plain(ok),
                err: WrapperPayload::Plain(err),
            },
            call_suffix: quote! { .map(|_| 0u8) #drop_err },
            return_abi: "",
            ok_abi: "",
            err_slot: true,
        });
    }

    if let Some(class) = boxed {
        return Ok(ReturnPlan {
            ret: WrapperReturn::CResult {
                name,
                ok: WrapperPayload::Boxed(class),
                err: WrapperPayload::Plain(err),
            },
            call_suffix: drop_err,
            return_abi: "",
            ok_abi: "",
            err_slot: true,
        });
    }

    let ok = syn::parse_str::<Type>(ok_type)
        .map_err(|_| skip_reason::detailed(skip_reason::PY_RESULT_PAYLOAD, ok_type))?;
    if is_string_type(&ok) || is_str_ref_type(&ok) {
        return Ok(ReturnPlan {
            ret: WrapperReturn::CResult {
                name,
                ok: WrapperPayload::OwnedString {
                    helper: format_ident!("{}_RustCallOwnedString", owner),
                    free: format_ident!("{}_free_rust_string", owner),
                    declare: true,
                },
                err: WrapperPayload::Plain(err),
            },
            call_suffix: drop_err,
            return_abi: "",
            ok_abi: "string",
            err_slot: true,
        });
    }
    if !is_ffi_compatible_type(&ok) {
        return Err(skip_reason::detailed(
            skip_reason::PY_RESULT_PAYLOAD,
            ok_type,
        ));
    }
    Ok(ReturnPlan {
        ret: WrapperReturn::CResult {
            name,
            ok: WrapperPayload::Plain(ok),
            err: WrapperPayload::Plain(err),
        },
        call_suffix: drop_err,
        return_abi: "",
        ok_abi: "",
        err_slot: true,
    })
}

/// A `Result` / `Option` payload, which sits **inside** a `#[repr(C)]`
/// aggregate and so must be a single FFI-compatible value. The PyO3 wrapper
/// never lowers a `String` / `&str` payload to the owned-buffer helper #268
/// added for `#[julia]` methods, so this is always [`WrapperPayload::Plain`].
fn payload_type(spelling: &str) -> Result<WrapperPayload, String> {
    let ty = syn::parse_str::<Type>(spelling)
        .map_err(|_| skip_reason::detailed(skip_reason::UNSUPPORTED_RETURN, spelling))?;
    if !is_ffi_compatible_type(&ty) {
        return Err(skip_reason::detailed(
            skip_reason::UNSUPPORTED_RETURN,
            spelling,
        ));
    }
    Ok(WrapperPayload::Plain(ty))
}

// ============================================================================
// Paths and names
// ============================================================================

/// `user_crate::module::item`, the path the wrapper calls.
fn item_path(krate: &Ident, module_path: &[String], name: &str) -> syn::Path {
    let mut path = syn::Path::from(krate.clone());
    for segment in module_path {
        path.segments.push(format_ident!("{}", segment).into());
    }
    path.segments.push(format_ident!("{}", name).into());
    path
}

fn callable_path(krate: &Ident, route: &[String], module: &[String], name: &str) -> syn::Path {
    match route.split_last() {
        Some((name, module)) => item_path(krate, module, name),
        None => item_path(krate, module, name),
    }
}

fn symbol_ident(name: &str) -> Result<Ident, String> {
    syn::parse_str::<Ident>(name)
        .map_err(|_| skip_reason::detailed(skip_reason::UNSUPPORTED_RETURN, name))
}

fn field_abi_of(rust_type: &str) -> &'static str {
    match syn::parse_str::<Type>(rust_type) {
        Ok(ty) => field_abi(&ty),
        Err(_) => "",
    }
}
