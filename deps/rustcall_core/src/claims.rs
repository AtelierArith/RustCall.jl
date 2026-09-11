//! Every name the code generated for one manifest entry defines (#338).
//!
//! Two independent scans need this list and used to derive it separately:
//!
//! * [`crate::manifest::Manifest::symbol_owners`], the crate-wide duplicate
//!   check of `#[julia]` items (`rustcall-extract`, and inline expansion
//!   through [`crate::manifest::Manifest::duplicate_symbols`]);
//! * `crate::pyo3::mark_symbol_collisions`, which decides whether a scanned
//!   PyO3 entry may keep its symbol or has to be skipped.
//!
//! Two lists mean a derived name added to the codegen has to be remembered
//! twice, and the `#[julia]` side had in fact forgotten the panic readers
//! (#338), the private panic slots and the owned-`Vec` field helpers. There is
//! one list now, and the two places where the scans genuinely differ are
//! spelled as a [`Policy`] rather than as a second implementation.
//!
//! # Exported and private names both matter
//!
//! A duplicate `#[no_mangle]` symbol fails at link time; a duplicate
//! `thread_local!` static or `#[repr(C)] struct` in one module fails at
//! compile time. Both are defects of the same shape — two generated items
//! wanting one name — so a [`Claim`] carries the name and whether it is
//! exported, and callers that care (a Julia-facing diagnostic, say) filter.

use crate::codegen::{panic_symbol, struct_free_symbol};
use crate::manifest::{Function, Struct};

/// One name the generated code defines.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Claim {
    pub name: String,
    /// `true` for a `#[no_mangle]` item (a link-time clash), `false` for a
    /// module-private one: a panic slot or a helper type (a compile-time
    /// clash in the module the wrapper is emitted into).
    pub exported: bool,
}

impl Claim {
    fn exported(name: String) -> Claim {
        Claim {
            name,
            exported: true,
        }
    }

    fn private(name: String) -> Claim {
        Claim {
            name,
            exported: false,
        }
    }
}

/// Which string helpers an entry is credited with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StringHelpers {
    /// Exactly the ones the manifest says the wrapper declares. This is the
    /// answer for a `#[julia]` item, whose wrapper has already been decided:
    /// an owned `String` result declares the buffer type and its release
    /// function, a borrowed `&str` result declares only the view type.
    AsDeclared,
    /// All three names, whenever the entry's types say it *may* declare any.
    /// This is the answer for a PyO3 entry during the scan: the wrapper crate
    /// is generated later (`crate::wrap`), so which of the three it will
    /// declare is not known yet and reserving too much is the safe direction
    /// (#307 review).
    Reserved,
}

/// How a particular scan reads the generated code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Policy {
    /// Include module-private names — the `__RUSTCALL_PANIC_<SYMBOL>` slot and
    /// the string / vector helper types. They are real clashes, not exports.
    pub include_private: bool,
    pub strings: StringHelpers,
}

impl Policy {
    /// The `#[julia]` crate-wide duplicate check.
    ///
    /// Exported names only, for now. Both diagnostics built on it say
    /// "duplicate exported symbol" and name the item that claims it; a clash
    /// on a private name — two wrappers whose symbols differ only in case
    /// share one `__RUSTCALL_PANIC_<SYMBOL>` slot — is a real defect but needs
    /// a message that does not call an internal item an export. Adding that
    /// vocabulary is the remainder of #338.
    pub const JULIA: Policy = Policy {
        include_private: false,
        strings: StringHelpers::AsDeclared,
    };

    /// The PyO3 scan's collision analysis.
    pub const PYO3_SCAN: Policy = Policy {
        include_private: true,
        strings: StringHelpers::Reserved,
    };
}

/// The private thread-local slot a wrapper's panic channel writes. The symbol
/// is upper-cased, so `foo` and `FOO` would share one slot — a duplicate
/// `thread_local!` in the same module.
pub fn panic_slot(symbol: &str) -> String {
    format!("__RUSTCALL_PANIC_{}", symbol.to_uppercase())
}

/// The owned string buffer of `owner`: the `#[repr(C)]` type and the
/// `#[no_mangle]` function that releases it.
pub fn owned_string_names(owner: &str) -> [String; 2] {
    [
        format!("{owner}_RustCallOwnedString"),
        format!("{owner}_free_rust_string"),
    ]
}

/// The borrowed string view of `owner`. A view owns nothing, so it is a type
/// and no export.
pub fn borrowed_string_name(owner: &str) -> String {
    format!("{owner}_RustCallBorrowedString")
}

/// The owned vector buffer a `Vec` field getter returns: the type, and the
/// allocator-matched release function the manifest names.
pub fn owned_vec_names(getter: &str) -> String {
    format!("{getter}_RustCallOwnedVec")
}

/// The entry point exported as `symbol`, the reader of its panic channel and
/// the slot that reader drains.
pub fn wrapper_claims(symbol: &str, include_private: bool) -> Vec<Claim> {
    let mut out = vec![
        Claim::exported(symbol.to_string()),
        Claim::exported(panic_symbol(symbol)),
    ];
    if include_private {
        out.push(Claim::private(panic_slot(symbol)));
    }
    out
}

pub fn string_claims(owner: &str, owned: bool, borrowed: bool, policy: Policy) -> Vec<Claim> {
    let (owned, borrowed) = match policy.strings {
        StringHelpers::AsDeclared => (owned, borrowed),
        StringHelpers::Reserved => {
            let any = owned || borrowed;
            (any, any)
        }
    };
    let mut out = Vec::new();
    if owned {
        let [ty, free] = owned_string_names(owner);
        if policy.include_private {
            out.push(Claim::private(ty));
        }
        out.push(Claim::exported(free));
    }
    if borrowed && policy.include_private {
        out.push(Claim::private(borrowed_string_name(owner)));
    }
    out
}

/// Whether a wrapper for an item with these ABI columns hands back an owned
/// string buffer — as the result or as a `Result` / `Option` payload.
pub fn declares_owned_string(abis: [&str; 4]) -> bool {
    abis.contains(&"string")
}

/// The same question for a borrowed `&str`.
pub fn declares_borrowed_string(abis: [&str; 4]) -> bool {
    abis.contains(&"str")
}

/// Every name the wrapper of this `#[julia]` or PyO3 function defines.
///
/// Empty when the entry defines nothing: a generic or unexported item, one
/// whose `#[cfg]` the scan could not decide (two variants under mutually
/// exclusive predicates are the normal shape of a portable crate, not a
/// clash), or a plain `#[no_mangle] extern "C"` function, which is reported so
/// Julia can register its return type but for which RustCall generates no
/// wrapper at all — a hand-written `release` / `release_take_panic` pair is
/// two unrelated exports, not a collision (#338).
pub fn function_claims(f: &Function, policy: Policy) -> Vec<Claim> {
    if !f.exported || f.symbol.is_empty() || !f.cfg.is_empty() {
        return Vec::new();
    }
    if !f.attribute.generates_wrapper() {
        return vec![Claim::exported(f.symbol.clone())];
    }
    let mut out = wrapper_claims(&f.symbol, policy.include_private);
    if !f.ffi_name.is_empty() {
        out.extend(string_claims(
            &f.ffi_name,
            f.has_owned_string_helper,
            f.has_borrowed_string_helper,
            policy,
        ));
    }
    out
}

/// The same for a PyO3-scanned function, whose ABI columns are not filled in
/// yet: the wrapper crate decides them later (`crate::wrap`), so the string
/// helpers are reserved from the declared types instead.
pub fn scanned_function_claims(f: &Function, owned: bool, borrowed: bool) -> Vec<Claim> {
    if f.symbol.is_empty() {
        return Vec::new();
    }
    let policy = Policy::PYO3_SCAN;
    let mut out = wrapper_claims(&f.symbol, policy.include_private);
    if !f.ffi_name.is_empty() {
        out.extend(string_claims(&f.ffi_name, owned, borrowed, policy));
    }
    out
}

/// Every name the wrappers of this struct define: the destructor, `clone`,
/// the field accessors and their owned-buffer helpers, the method wrappers,
/// and the owned-string buffers those methods share.
///
/// A buffer is claimed once however many items share it: an inline method
/// wrapped next to its struct uses the struct's (`string_owner == ffi_name`),
/// one wrapped at a `#[julia] impl` block in another module declares its own
/// (#342).
pub fn struct_claims(s: &Struct, policy: Policy) -> Vec<Claim> {
    if !s.cfg.is_empty() || s.ffi_name.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    // A generic struct exports nothing itself.
    if s.type_params.is_empty() {
        out.extend(wrapper_claims(
            &struct_free_symbol(&s.ffi_name),
            policy.include_private,
        ));
    }
    if s.has_clone {
        out.extend(wrapper_claims(
            &format!("{}_clone", s.ffi_name),
            policy.include_private,
        ));
    }
    for field in &s.fields {
        for accessor in [&field.getter, &field.setter] {
            if !accessor.is_empty() {
                out.extend(wrapper_claims(accessor, policy.include_private));
            }
        }
        if field.abi == "vec" && !field.getter.is_empty() {
            if policy.include_private {
                out.push(Claim::private(owned_vec_names(&field.getter)));
            }
            if !field.free_symbol.is_empty() {
                out.push(Claim::exported(field.free_symbol.clone()));
            }
        }
    }

    let mut buffers: Vec<(String, bool, bool)> = Vec::new();
    let note = |owner: &str, owned: bool, borrowed: bool, buffers: &mut Vec<_>| {
        if owner.is_empty() || (!owned && !borrowed) {
            return;
        }
        match buffers
            .iter_mut()
            .find(|(o, _, _): &&mut (String, bool, bool)| o == owner)
        {
            Some(entry) => {
                entry.1 |= owned;
                entry.2 |= borrowed;
            }
            None => buffers.push((owner.to_string(), owned, borrowed)),
        }
    };
    note(
        &s.ffi_name,
        s.has_owned_string_helper,
        s.has_borrowed_string_helper,
        &mut buffers,
    );
    for m in &s.methods {
        if !m.cfg.is_empty() {
            continue;
        }
        if !m.symbol.is_empty() {
            out.extend(wrapper_claims(&m.symbol, policy.include_private));
        }
        let abis = [
            m.return_abi.as_str(),
            m.ok_abi.as_str(),
            m.err_abi.as_str(),
            m.inner_abi.as_str(),
        ];
        // Schema 8 records which buffer a method uses; fall back to the
        // per-method stem for an entry written before that column existed or
        // by a scan that has not decided yet (`crate::wrap`).
        let owner = if m.string_owner.is_empty() {
            crate::codegen::method_string_owner(&s.ffi_name, &m.name)
        } else {
            m.string_owner.clone()
        };
        note(
            &owner,
            declares_owned_string(abis),
            declares_borrowed_string(abis),
            &mut buffers,
        );
    }
    for (owner, owned, borrowed) in buffers {
        out.extend(string_claims(&owner, owned, borrowed, policy));
    }
    out
}
