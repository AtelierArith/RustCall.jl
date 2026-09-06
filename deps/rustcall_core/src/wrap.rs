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
    field_abi, generate_wrapper, owned_string_helper_items, CallTarget, WrapperReceiver,
    WrapperReturn, WrapperSpec,
};
use crate::manifest::{skip_reason, Arg, Manifest, Method, ReturnKind, Struct};
use crate::types::{is_ffi_compatible_type, is_str_ref_type, is_string_type};

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
        match function_wrapper(&krate, &entry) {
            Ok((tokens, updated)) => {
                items.extend(tokens);
                out.functions.push(updated);
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
            }
            out.structs.push(entry);
            continue;
        }
        items.extend(class_wrappers(&krate, &mut entry));
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
    let owner = format_ident!("{}", f.name);
    let plan = return_plan(
        &owner,
        &f.return_type,
        f.return_kind,
        &f.ok_type,
        &f.err_type,
        &f.inner_type,
        None,
    )?;
    let tokens = generate_wrapper(WrapperSpec {
        symbol,
        cfg_attrs: Vec::new(),
        receiver: None,
        args,
        lower_strings: true,
        ret: plan.ret,
        target: CallTarget::Free(item_path(krate, &f.module_path, &f.name)),
        call_suffix: plan.call_suffix,
    });

    let mut updated = f.clone();
    updated.exported = true;
    updated.return_abi = plan.return_abi.to_string();
    updated.has_owned_string_helper = plan.return_abi == "string";
    updated.has_borrowed_string_helper = plan.return_abi == "str";
    if plan.err_slot {
        updated.err_type = PYERR_SLOT.to_string();
    }
    Ok((tokens, updated))
}

// ============================================================================
// `#[pyclass]` handles
// ============================================================================

/// The destructor, the field accessors and the method wrappers of one class.
///
/// The class is an **opaque handle**: a `#[pyclass]` is never `#[repr(C)]`
/// (pyo3 owns its layout), so Julia only ever holds a `*mut Class` and reaches
/// the fields through the accessors pyo3's own `#[pyo3(get, set)]` declared.
fn class_wrappers(krate: &Ident, s: &mut Struct) -> TokenStream2 {
    let class = item_path(krate, &s.module_path, &s.name);
    let mut out = TokenStream2::new();

    // `<Struct>_free`, the destructor `RustCall.ffi_struct_free_symbol` names.
    let free = format_ident!("{}_free", s.name);
    out.extend(quote! {
        #[no_mangle]
        pub extern "C" fn #free(ptr: *mut #class) {
            if !ptr.is_null() {
                unsafe { drop(Box::from_raw(ptr)); }
            }
        }
    });

    // The struct-level owned-string buffer, shared by every `String` field
    // getter (`RustCall._ffi_field_return` names it after the struct).
    let owned_helper = format_ident!("{}_RustCallOwnedString", s.name);
    let owned_free = format_ident!("{}_free_rust_string", s.name);
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
        if !f.ffi_compatible || f.getter.is_empty() {
            continue;
        }
        let Ok(field) = syn::parse_str::<Ident>(&f.name) else {
            f.ffi_compatible = false;
            f.getter.clear();
            f.setter.clear();
            continue;
        };
        let Ok(ty) = syn::parse_str::<Type>(&f.rust_type) else {
            f.ffi_compatible = false;
            f.getter.clear();
            f.setter.clear();
            continue;
        };
        let getter = format_ident!("{}", f.getter);
        if is_string_type(&ty) {
            out.extend(quote! {
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
            });
            // A `String` field is read by copying it out; writing one would
            // need the byte-pair ABI on a setter, which no accessor shape
            // covers yet (#303).
            f.setter.clear();
        } else {
            out.extend(quote! {
                #[no_mangle]
                pub extern "C" fn #getter(ptr: *const #class) -> #ty {
                    unsafe { (*ptr).#field }
                }
            });
            if !f.setter.is_empty() {
                let setter = format_ident!("{}", f.setter);
                out.extend(quote! {
                    #[no_mangle]
                    pub extern "C" fn #setter(ptr: *mut #class, value: #ty) {
                        unsafe { (*ptr).#field = value; }
                    }
                });
            }
        }
    }

    let class_name = s.name.clone();
    for m in &mut s.methods {
        if !m.skip_reason.is_empty() {
            continue;
        }
        match method_wrapper(&class, &class_name, m) {
            Ok(tokens) => out.extend(tokens),
            Err(reason) => m.skip_reason = reason,
        }
    }
    out
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
    let owner = format_ident!("{}_{}", class_name, m.name);
    let boxed = m.returns_boxed_struct.then(|| class.clone());
    let plan = return_plan(
        &owner,
        &m.return_type,
        m.return_kind,
        &m.ok_type,
        &m.err_type,
        &m.inner_type,
        boxed,
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
        lower_strings: true,
        ret: plan.ret,
        target,
        call_suffix: plan.call_suffix,
    });
    m.return_abi = plan.return_abi.to_string();
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
    /// Whether the manifest entry's `err_type` becomes [`PYERR_SLOT`].
    err_slot: bool,
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

#[allow(clippy::too_many_arguments)]
fn return_plan(
    owner: &Ident,
    return_type: &str,
    kind: ReturnKind,
    ok_type: &str,
    err_type: &str,
    inner_type: &str,
    boxed: Option<syn::Path>,
) -> Result<ReturnPlan, String> {
    let plain = |ret| ReturnPlan {
        ret,
        call_suffix: TokenStream2::new(),
        return_abi: "",
        err_slot: false,
    };

    match kind {
        ReturnKind::Unit => Ok(plain(WrapperReturn::Unit)),
        ReturnKind::PyResult => py_result_plan(owner, ok_type),
        ReturnKind::Result => {
            let ok = payload_type(ok_type)?;
            let err = payload_type(err_type)?;
            Ok(plain(WrapperReturn::CResult {
                name: format_ident!("CResult_{}", owner),
                ok,
                err,
            }))
        }
        ReturnKind::Option => {
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
                    err_slot: false,
                });
            }
            if is_str_ref_type(&ty) {
                return Ok(ReturnPlan {
                    ret: WrapperReturn::BorrowedStr {
                        helper: format_ident!("{}_RustCallBorrowedString", owner),
                        declare: true,
                    },
                    call_suffix: TokenStream2::new(),
                    return_abi: "str",
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
/// `T` must cross the C ABI as a single value: a `PyResult<String>` or a
/// `PyResult<Self>` would need a buffer or a box *inside* the aggregate, which
/// no `CResult` shape covers, so those are refused rather than mis-lowered
/// (#303 tracks widening this).
fn py_result_plan(owner: &Ident, ok_type: &str) -> Result<ReturnPlan, String> {
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
            ret: WrapperReturn::CResult { name, ok, err },
            call_suffix: quote! { .map(|_| 0u8) #drop_err },
            return_abi: "",
            err_slot: true,
        });
    }

    let ok = syn::parse_str::<Type>(ok_type)
        .map_err(|_| skip_reason::detailed(skip_reason::PY_RESULT_PAYLOAD, ok_type))?;
    if !is_ffi_compatible_type(&ok) {
        return Err(skip_reason::detailed(
            skip_reason::PY_RESULT_PAYLOAD,
            ok_type,
        ));
    }
    Ok(ReturnPlan {
        ret: WrapperReturn::CResult { name, ok, err },
        call_suffix: drop_err,
        return_abi: "",
        err_slot: true,
    })
}

/// A `Result` / `Option` payload, which sits **inside** a `#[repr(C)]`
/// aggregate and so must be a single FFI-compatible value.
fn payload_type(spelling: &str) -> Result<Type, String> {
    let ty = syn::parse_str::<Type>(spelling)
        .map_err(|_| skip_reason::detailed(skip_reason::UNSUPPORTED_RETURN, spelling))?;
    if !is_ffi_compatible_type(&ty) {
        return Err(skip_reason::detailed(
            skip_reason::UNSUPPORTED_RETURN,
            spelling,
        ));
    }
    Ok(ty)
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
