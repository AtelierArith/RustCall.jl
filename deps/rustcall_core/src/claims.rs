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

/// Which of Rust's two name spaces a generated item occupies. `struct Foo`
/// and `fn Foo` may coexist in one module, so two claims of one spelling are
/// a clash only when they are in the same one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Namespace {
    /// A function or a `thread_local!` static.
    Value,
    /// A generated `#[repr(C)]` buffer type.
    Type,
}

/// Where a generated name has to be unique.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Scope {
    /// The whole `cdylib`: a `#[no_mangle]` symbol, which the linker sees
    /// once however many modules it is written across.
    Global,
    /// One Rust module of the crate, by path. A private item is emitted next
    /// to its wrapper, so `mod a { fn foo }` and `mod A { fn FOO }` may spell
    /// one slot name and still compile.
    Module(Vec<String>),
    /// Emitted in a module this scan cannot name — a method wrapped at a
    /// `#[julia] impl` block in another module than its struct, whose path
    /// the manifest does not record (#342). Never compared: rustc still
    /// reports such a clash, and a false duplicate would refuse a crate that
    /// builds.
    Unknown,
}

impl Scope {
    /// Whether two claims in these scopes can meet. `Unknown` meets nothing.
    pub fn meets(&self, other: &Scope) -> bool {
        match (self, other) {
            (Scope::Global, Scope::Global) => true,
            (Scope::Module(a), Scope::Module(b)) => a == b,
            _ => false,
        }
    }
}

/// One name the generated code defines.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Claim {
    pub name: String,
    /// `true` for a `#[no_mangle]` item (a link-time clash), `false` for a
    /// module-private one: a panic slot or a helper type (a compile-time
    /// clash in the module the wrapper is emitted into).
    pub exported: bool,
    pub namespace: Namespace,
    pub scope: Scope,
}

impl Claim {
    /// Whether these two claims are the same name in the same place — the
    /// question both duplicate checks ask.
    pub fn clashes_with(&self, other: &Claim) -> bool {
        self.name == other.name
            && self.namespace == other.namespace
            && self.scope.meets(&other.scope)
    }

    fn exported(name: String) -> Claim {
        Claim {
            name,
            exported: true,
            namespace: Namespace::Value,
            scope: Scope::Global,
        }
    }

    fn private(name: String, namespace: Namespace) -> Claim {
        Claim {
            name,
            exported: false,
            namespace,
            scope: Scope::Unknown,
        }
    }

    fn in_scope(mut self, scope: &Scope) -> Claim {
        if !self.exported {
            self.scope = scope.clone();
        }
        self
    }
}

/// Put every private claim of a list in `scope`; exported ones stay global.
fn scoped(claims: Vec<Claim>, scope: &Scope) -> Vec<Claim> {
    claims
        .into_iter()
        .map(|claim| claim.in_scope(scope))
        .collect()
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
    pub strings: StringHelpers,
    /// Drop an entry whose `#[cfg]` the scan could not decide.
    ///
    /// The `#[julia]` duplicate check does: two variants of one function under
    /// mutually exclusive predicates are the normal shape of a portable crate,
    /// and it has nowhere to record the predicate. The PyO3 scan keeps them —
    /// it carries each claim's predicate alongside and asks `cfg_exclusive`
    /// whether two claimants can ever be compiled together, so a gated
    /// `#[julia] fn run` and a gated `#[pyfunction] fn run_take_panic` under
    /// the same feature still collide.
    pub skip_cfg_gated: bool,
}

impl Policy {
    /// The `#[julia]` crate-wide duplicate check.
    ///
    /// Both scans count module-private names, so this differs from
    /// [`Policy::PYO3_SCAN`] only in the two fields above. Two wrappers whose
    /// symbols differ only in case share one `__RUSTCALL_PANIC_<SYMBOL>` slot,
    /// and two items with one string-buffer owner declare one
    /// `<owner>_RustCallOwnedString` twice; neither is an export, and both are
    /// a duplicate definition rustc would report inside generated code, so the
    /// diagnostics distinguish the two kinds rather than calling an internal
    /// item an export (#338).
    pub const JULIA: Policy = Policy {
        strings: StringHelpers::AsDeclared,
        skip_cfg_gated: true,
    };

    /// The PyO3 scan's collision analysis.
    pub const PYO3_SCAN: Policy = Policy {
        strings: StringHelpers::Reserved,
        skip_cfg_gated: false,
    };
}

/// The private thread-local slot the panic channel of a **function or method
/// wrapper** writes (`codegen::function_wrapper`). The symbol is upper-cased,
/// so `foo` and `FOO` would share one slot — a duplicate `thread_local!` in
/// the same module, which their differing exported symbols would not catch.
pub fn panic_slot(symbol: &str) -> String {
    format!("__RUSTCALL_PANIC_{}", symbol.to_uppercase())
}

/// The slot of a **struct helper** — a destructor, `clone`, or a field
/// accessor (`codegen::guard_struct_helper`). Unlike [`panic_slot`] it hex-
/// encodes the symbol rather than upper-casing it, so it is injective: two
/// helpers share a slot only when they already share their exported symbol.
/// Nothing claims it for that reason; this exists so the difference is
/// written down rather than rediscovered.
pub fn helper_panic_slot(symbol: &str) -> String {
    let suffix: String = symbol.bytes().map(|b| format!("{b:02X}")).collect();
    format!("__RUSTCALL_HELPER_PANIC_{suffix}")
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

/// Stable partition: exported names first.
///
/// A clash is usually visible on both an export and the private item derived
/// from it — a duplicated wrapper symbol duplicates its panic slot too — and
/// the diagnostics report the first one they meet. The exported name is the
/// one the user can look up in the naming scheme, so it goes first.
fn exported_first(mut claims: Vec<Claim>) -> Vec<Claim> {
    claims.sort_by_key(|claim| !claim.exported);
    claims
}

/// The entry point exported as `symbol`, the reader of its panic channel and
/// the slot that reader drains.
pub fn wrapper_claims(symbol: &str) -> Vec<Claim> {
    let mut out = helper_claims(symbol);
    out.push(Claim::private(panic_slot(symbol), Namespace::Value));
    out
}

/// The same for a struct helper — destructor, `clone`, field accessor — whose
/// slot is [`helper_panic_slot`] and therefore needs no claim of its own.
pub fn helper_claims(symbol: &str) -> Vec<Claim> {
    vec![
        Claim::exported(symbol.to_string()),
        Claim::exported(panic_symbol(symbol)),
    ]
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
        out.push(Claim::private(ty, Namespace::Type));
        out.push(Claim::exported(free));
    }
    if borrowed {
        out.push(Claim::private(borrowed_string_name(owner), Namespace::Type));
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
    if !f.exported || f.symbol.is_empty() || (policy.skip_cfg_gated && !f.cfg.is_empty()) {
        return Vec::new();
    }
    if !f.attribute.generates_wrapper() {
        return vec![Claim::exported(f.symbol.clone())];
    }
    let mut out = wrapper_claims(&f.symbol);
    if !f.ffi_name.is_empty() {
        out.extend(string_claims(
            &f.ffi_name,
            f.has_owned_string_helper,
            f.has_borrowed_string_helper,
            policy,
        ));
    }
    // The wrapper and its private items are emitted next to the function.
    exported_first(scoped(out, &Scope::Module(f.module_path.clone())))
}

/// The same for a PyO3-scanned function, whose ABI columns are not filled in
/// yet: the wrapper crate decides them later (`crate::wrap`), so the string
/// helpers are reserved from the declared types instead.
pub fn scanned_function_claims(f: &Function, owned: bool, borrowed: bool) -> Vec<Claim> {
    if f.symbol.is_empty() {
        return Vec::new();
    }
    let policy = Policy::PYO3_SCAN;
    let mut out = wrapper_claims(&f.symbol);
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
    if (policy.skip_cfg_gated && !s.cfg.is_empty()) || s.ffi_name.is_empty() {
        return Vec::new();
    }
    // Everything a struct's own wrappers define is emitted next to the
    // struct; a method wrapped at a `#[julia] impl` block in another module
    // is the exception, handled below.
    let here = Scope::Module(s.module_path.clone());
    let mut out = Vec::new();
    // A generic struct exports nothing itself.
    if s.type_params.is_empty() {
        out.extend(helper_claims(&struct_free_symbol(&s.ffi_name)));
    }
    if s.has_clone {
        out.extend(helper_claims(&format!("{}_clone", s.ffi_name)));
    }
    for field in &s.fields {
        for accessor in [&field.getter, &field.setter] {
            if !accessor.is_empty() {
                out.extend(helper_claims(accessor));
            }
        }
        if field.abi == "vec" && !field.getter.is_empty() {
            out.push(
                Claim::private(owned_vec_names(&field.getter), Namespace::Type).in_scope(&here),
            );
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
        if policy.skip_cfg_gated && !m.cfg.is_empty() {
            continue;
        }
        if !m.symbol.is_empty() {
            // A method wrapped next to its struct shares the struct's module
            // (`string_owner == ffi_name`, #342); one wrapped at a block
            // elsewhere is emitted in a module the manifest does not record.
            let where_ = if m.string_owner == s.ffi_name || m.string_owner.is_empty() {
                here.clone()
            } else {
                Scope::Unknown
            };
            out.extend(scoped(wrapper_claims(&m.symbol), &where_));
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
        let where_ = if owner == s.ffi_name {
            here.clone()
        } else {
            Scope::Unknown
        };
        out.extend(scoped(
            string_claims(&owner, owned, borrowed, policy),
            &where_,
        ));
    }
    exported_first(out)
}

/// What kind of clash a duplicate [`Claim`] is, as a sentence a user-facing
/// diagnostic can build on.
///
/// The two are different failures: two `#[no_mangle]` items of one name cannot
/// be exported by one `cdylib`, while two internal items of one name cannot
/// even be defined in one module. Saying "exported symbol" for the second
/// would be wrong, and the internal names are not ones the user wrote, so the
/// message has to say where they come from (#338).
pub fn clash_kind(claim: &Claim) -> &'static str {
    if claim.exported {
        "exported symbol"
    } else {
        "generated item"
    }
}

/// Why an internal name exists, for a diagnostic that has to explain a name
/// the user never wrote. Empty for an exported symbol, whose name the user can
/// read off the scheme.
pub fn internal_origin(claim: &Claim) -> &'static str {
    if claim.exported {
        return "";
    }
    if claim.name.starts_with("__RUSTCALL_PANIC_") {
        "the thread-local slot of a wrapper's panic channel, named by \
         upper-casing the wrapper's symbol — so two wrappers whose symbols \
         differ only in case meet here"
    } else if claim.name.ends_with("_RustCallOwnedString")
        || claim.name.ends_with("_RustCallBorrowedString")
    {
        "the string buffer type a wrapper returns, named after the item that \
         owns the buffer"
    } else if claim.name.ends_with("_RustCallOwnedVec") {
        "the owned-vector buffer type a field getter returns"
    } else {
        "an item RustCall generates next to the wrapper"
    }
}
