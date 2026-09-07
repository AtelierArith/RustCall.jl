//! Manifest extraction.
//!
//! * `extract_crate(source)`: manifest for a crate source file, following the
//!   proc-macro's rules (what `juliacall_macros` would actually generate).
//! * `extract_inline(source)`: manifest for a `rust"""` block; delegates to
//!   [`crate::expand::expand`] so the manifest and the expanded code cannot
//!   disagree.

use syn::spanned::Spanned;
use syn::{FnArg, Item, ItemFn, ItemImpl, Pat, ReturnType};

use crate::attrs::{has_no_mangle, rustcall_attribute};
use crate::cfg::{body_has_cfg, predicate_string, CfgSet};
use crate::codegen::{returns_boxed_struct, symbol_stem};

use crate::manifest::{
    Arg, Attribute, Field, Function, Manifest, Method, Mode, ReturnKind, Struct,
};
use crate::model::{impl_has_julia, wrapped_methods, StructModel};
use crate::paths::{imports_of_use, locate, ImplHeader, Located, ScannedImport, Unresolved};
use crate::types::{
    extract_option_type, extract_result_type, generics_to_type_params, has_impl_trait,
    has_type_params, is_ffi_compatible_type, is_str_ref_type, is_string_type,
    needs_clone_for_getter, return_type_to_string, type_to_string,
};

pub fn extract(source: &str, mode: Mode) -> Result<Manifest, ExtractError> {
    extract_with_cfg(source, mode, None)
}

/// Like [`extract`], but items disabled under `cfg` are dropped first
/// (see [`crate::cfg::CfgSet::prune_items`]).
pub fn extract_with_cfg(
    source: &str,
    mode: Mode,
    cfg: Option<&CfgSet>,
) -> Result<Manifest, ExtractError> {
    match mode {
        Mode::Inline => Ok(crate::expand::expand_with_cfg(source, cfg)?.manifest),
        Mode::Crate => extract_crate_with_cfg(source, cfg),
    }
}

pub fn fn_args(sig: &syn::Signature) -> Vec<Arg> {
    sig.inputs
        .iter()
        .filter_map(|a| match a {
            FnArg::Typed(pt) => Some(Arg {
                name: match pt.pat.as_ref() {
                    Pat::Ident(pi) => pi.ident.to_string(),
                    other => quote::quote!(#other).to_string(),
                },
                rust_type: type_to_string(&pt.ty),
                abi: arg_abi(&pt.ty).to_string(),
            }),
            FnArg::Receiver(_) => None,
        })
        .collect()
}

/// The return kind of a wrapper that does no `Result`/`Option` lowering:
/// `Unit` for `()` or no return type, `Plain` otherwise. Struct method
/// wrappers are in that category (`generate_method_wrapper*` never wraps a
/// `Result`), so their manifest entry says so explicitly rather than leaving a
/// consumer to infer it from the type spelling (#275, #276).
pub fn plain_return_kind(output: &ReturnType) -> ReturnKind {
    match output {
        ReturnType::Default => ReturnKind::Unit,
        ReturnType::Type(..) => {
            if return_type_to_string(output) == "()" {
                ReturnKind::Unit
            } else {
                ReturnKind::Plain
            }
        }
    }
}

/// The manifest return shape of a `#[julia]` struct method (#268).
///
/// Before #268 a method wrapper never wrapped `Result` / `Option`, so this was
/// always `Plain` / `Unit` and the payload columns were empty. Both wrapper
/// flavours now lower them exactly like a free function, and this is the one
/// place that says so, shared by inline expansion and crate extraction so the
/// manifest cannot disagree with the code that was generated.
#[derive(Debug, Default, Clone)]
pub struct MethodReturnShape {
    pub kind: ReturnKind,
    pub ok_type: String,
    pub err_type: String,
    pub inner_type: String,
    pub ok_abi: String,
    pub err_abi: String,
    pub inner_abi: String,
}

/// `wrapped` is false for the methods of a **generic** struct: those wrappers
/// are registered for monomorphization (`inline_generic_wrappers`) and return
/// the type as written, so their manifest entry must keep saying `Plain`.
pub fn method_return_shape(
    struct_name: &syn::Ident,
    func: &syn::ImplItemFn,
    wrapped: bool,
) -> MethodReturnShape {
    let output = &func.sig.output;
    let mut shape = MethodReturnShape {
        kind: plain_return_kind(output),
        ..Default::default()
    };
    // A constructor (`new`, or anything returning `Self`) is boxed before the
    // `Result` lowering is ever consulted, exactly as in `method_spec`.
    if !wrapped || returns_boxed_struct(struct_name, func) {
        return shape;
    }
    let ReturnType::Type(_, ty) = output else {
        return shape;
    };
    if crate::codegen::method_wraps_result(ty) {
        if let Some(r) = extract_result_type(ty) {
            shape.kind = ReturnKind::Result;
            shape.ok_type = type_to_string(&r.ok_type);
            shape.err_type = type_to_string(&r.err_type);
            shape.ok_abi = crate::codegen::payload_abi(&r.ok_type).to_string();
            shape.err_abi = crate::codegen::payload_abi(&r.err_type).to_string();
        }
    } else if crate::codegen::method_wraps_option(ty) {
        if let Some(o) = extract_option_type(ty) {
            shape.kind = ReturnKind::Option;
            shape.inner_type = type_to_string(&o.inner_type);
            shape.inner_abi = crate::codegen::payload_abi(&o.inner_type).to_string();
        }
    }
    shape
}

/// The manifest `abi` column of an argument type (see [`Arg::abi`]).
pub fn arg_abi(ty: &syn::Type) -> &'static str {
    if is_string_type(ty) {
        "string"
    } else if is_str_ref_type(ty) {
        "str"
    } else {
        ""
    }
}

fn item_fn_source(func: &ItemFn) -> String {
    let file = syn::File {
        shebang: None,
        attrs: Vec::new(),
        items: vec![Item::Fn(func.clone())],
    };
    prettyplease::unparse(&file)
}

/// Build the manifest entry of a free function.
///
/// `wrapped` says whether RustCall codegen (`transform_function`) is applied,
/// which decides the `Result`/`Option` return kinds and the exported flag.
///
/// `enclosing_cfg` is the `#[cfg]` of every enclosing inline module: the
/// entry's `cfg` / `cfg_features` describe when the item exists, not only
/// what it wrote on itself (#300 review).
pub fn function_entry(
    func: &ItemFn,
    attribute: Attribute,
    wrapped: bool,
    module_path: &[String],
    enclosing_cfg: &[syn::Attribute],
) -> Function {
    let effective_cfg = crate::cfg::effective_cfg_attrs(enclosing_cfg, &func.attrs);
    let is_generic = has_type_params(&func.sig.generics) || has_impl_trait(&func.sig);
    let return_type = return_type_to_string(&func.sig.output);
    let mut ok_type = String::new();
    let mut err_type = String::new();
    let mut inner_type = String::new();
    // Schema 6 (#268): a `String` / `&str` payload travels as the function's
    // own owned-string buffer, so the manifest states it rather than leaving
    // Julia to re-derive it from the payload spelling.
    let mut ok_abi = String::new();
    let mut err_abi = String::new();
    let mut inner_abi = String::new();
    let return_kind = match &func.sig.output {
        ReturnType::Default => ReturnKind::Unit,
        ReturnType::Type(_, ty) => {
            if let (true, Some(r)) = (wrapped, extract_result_type(ty)) {
                ok_type = type_to_string(&r.ok_type);
                err_type = type_to_string(&r.err_type);
                ok_abi = crate::codegen::payload_abi(&r.ok_type).to_string();
                err_abi = crate::codegen::payload_abi(&r.err_type).to_string();
                ReturnKind::Result
            } else if let (true, Some(o)) = (wrapped, extract_option_type(ty)) {
                inner_type = type_to_string(&o.inner_type);
                inner_abi = crate::codegen::payload_abi(&o.inner_type).to_string();
                ReturnKind::Option
            } else if return_type == "()" {
                ReturnKind::Unit
            } else {
                ReturnKind::Plain
            }
        }
    };
    let exported = if is_generic {
        false
    } else if wrapped {
        true
    } else {
        has_no_mangle(&func.attrs)
            && func
                .sig
                .abi
                .as_ref()
                .and_then(|abi| abi.name.as_ref())
                .map(|n| n.value() == "C")
                .unwrap_or(false)
    };
    let name = func.sig.ident.to_string();
    let ffi_name = crate::codegen::symbol_stem(module_path, &name);
    // `#[julia]` is additive: the item keeps its name and the exported entry
    // point is the wrapper next to it (#279), qualified by the module path
    // (#300). A plain `#[no_mangle] extern "C"` function is exported under
    // its own name.
    let symbol = match attribute {
        Attribute::Julia if !is_generic => crate::codegen::function_symbol(module_path, &name),
        _ => name.clone(),
    };
    // The wrapper only lowers strings when it is actually generated; a generic
    // item is wrapped per instantiation (see `specialize`), not here.
    let return_abi = if wrapped && !is_generic {
        crate::codegen::return_abi(&func.sig)
    } else {
        ""
    };
    Function {
        name,
        ffi_name,
        symbol,
        attribute,
        vis: crate::attrs::visibility_string(&func.vis),
        skip_reason: String::new(),
        python_name: String::new(),
        exported,
        cfg: predicate_string(&effective_cfg),
        cfg_features: crate::cfg::predicate_features(&effective_cfg),
        is_generic,
        type_params: generics_to_type_params(&func.sig.generics),
        args: fn_args(&func.sig),
        return_type,
        return_kind,
        return_abi: return_abi.to_string(),
        ok_type,
        err_type,
        inner_type,
        ok_abi,
        err_abi,
        inner_abi,
        // Derived from the normative `return_abi` column since schema 4 (#276).
        has_owned_string_helper: return_abi == "string",
        has_borrowed_string_helper: return_abi == "str",
        source: if is_generic {
            let mut stripped = func.clone();
            crate::attrs::strip_rustcall_attrs(&mut stripped.attrs);
            item_fn_source(&stripped)
        } else {
            String::new()
        },
        body_has_cfg: body_has_cfg(&func.block),
        line: func.span().start().line,
        module_path: module_path.to_vec(),
    }
}

/// Why crate extraction refuses a file (#300).
///
/// A parse failure is one thing — the CLI's `--skip-unparsable` skips such a
/// file, since an `include!()` fragment is not a module — and a `#[julia]` item
/// the proc-macro would export under a symbol the manifest cannot describe is
/// another: that must fail the scan, not be skipped.
#[derive(Debug)]
pub enum ExtractError {
    /// The source is not a complete Rust module.
    Parse(syn::Error),
    /// The source is valid but describes something RustCall refuses; the
    /// message names the item and the fix.
    Unsupported(String),
}

impl std::fmt::Display for ExtractError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ExtractError::Parse(e) => write!(f, "{e}"),
            ExtractError::Unsupported(msg) => f.write_str(msg),
        }
    }
}

impl std::error::Error for ExtractError {}

impl From<syn::Error> for ExtractError {
    fn from(e: syn::Error) -> Self {
        ExtractError::Parse(e)
    }
}

/// Manifest for a crate source file (proc-macro semantics).
pub fn extract_crate(source: &str) -> Result<Manifest, ExtractError> {
    extract_crate_with_cfg(source, None)
}

pub fn extract_crate_with_cfg(
    source: &str,
    cfg: Option<&CfgSet>,
) -> Result<Manifest, ExtractError> {
    extract_crate_with_cfg_scan(source, cfg, true)
}

/// Like [`extract_crate_with_cfg`], with the PyO3 scan (#275) switchable.
///
/// The scan is on by default: one file, treated as its own root. A caller that
/// can read files instead walks the crate's module tree with [`TreeScan`] —
/// which records the real `module_path` and the reachability of every
/// enclosing `mod` — and then passes `false` here so the per-file pass does
/// not report the same items a second time under the wrong path.
pub fn extract_crate_with_cfg_scan(
    source: &str,
    cfg: Option<&CfgSet>,
    pyo3_scan: bool,
) -> Result<Manifest, ExtractError> {
    let mut file = syn::parse_file(source)?;
    if let Some(set) = cfg {
        crate::cfg::prune_file_or_error(set, &mut file)?;
    }
    let mut manifest = Manifest::new(Mode::Crate);
    let mut scan = CrateScan::new();
    scan.file(&file.items, &[], &[], &mut manifest, "")?;
    scan.finish(&mut manifest)?;
    // Items that carry only PyO3 attributes (#275). Reported with a PyO3
    // origin, `exported = false` and the symbol a Phase-2 wrapper crate will
    // emit; an item that also carries `#[julia]` is owned by `#[julia]` and is
    // skipped by the scan (see `crate::pyo3`).
    if pyo3_scan {
        crate::pyo3::extract_pyo3_items(&file.items, &mut manifest);
    }
    Ok(manifest)
}

/// Both crate-wide scans of one crate — `#[julia]` items (#315) and PyO3 items
/// (#275) — fed one file of the module tree at a time.
///
/// A struct and its impl blocks may live in different files, so the structs
/// are only written to the manifest by [`TreeScan::finish`], once every file
/// has been seen. The caller — `rustcall-extract` — owns the walk: it resolves
/// each returned [`crate::pyo3::PendingModule`] to a file and calls
/// [`TreeScan::file`] again; only it can touch the filesystem. Without a crate
/// root every file is fed as its own root (an empty `module_path`).
#[derive(Debug, Default)]
pub struct TreeScan {
    julia: CrateScan,
    pyo3: crate::pyo3::Pyo3Scan,
}

impl TreeScan {
    pub fn new() -> Self {
        TreeScan::default()
    }

    /// Scan one file. `module_path` is where it sits in the tree (empty for
    /// the crate root), `reachable` whether every `mod` on the way to it is
    /// `pub`, `enclosing_cfg` the `#[cfg]` of every `mod` declaration on the
    /// way (which every item in the file inherits, #300 review), and `file`
    /// labels it in diagnostics. `#[julia]` and PyO3 functions go straight
    /// into `manifest`; the out-of-line `mod` declarations found are returned
    /// for the caller to follow.
    #[allow(clippy::too_many_arguments)]
    pub fn file(
        &mut self,
        source: &str,
        cfg: Option<&CfgSet>,
        module_path: &[String],
        reachable: bool,
        enclosing_cfg: &[syn::Attribute],
        manifest: &mut Manifest,
        file: &str,
    ) -> Result<Vec<crate::pyo3::PendingModule>, ExtractError> {
        let mut parsed = syn::parse_file(source)?;
        if let Some(set) = cfg {
            crate::cfg::prune_file_or_error(set, &mut parsed)?;
        }
        self.julia
            .file(&parsed.items, module_path, enclosing_cfg, manifest, file)?;
        Ok(self.pyo3.file(
            &parsed.items,
            module_path,
            reachable,
            enclosing_cfg,
            manifest,
        ))
    }

    /// Attach every impl block to its struct and write the structs of both
    /// scans to `manifest`.
    pub fn finish(self, manifest: &mut Manifest) -> Result<(), ExtractError> {
        self.julia.finish(manifest)?;
        self.pyo3.finish(manifest);
        Ok(())
    }
}

/// The error for a `#[julia]` item inside an inline module that is not itself
/// marked `#[julia]` (#300): the proc-macro would export it under the
/// crate-root symbol, and the manifest cannot describe that honestly.
fn unmarked_module_error(kind: &str, name: &str, full_path: &[String]) -> ExtractError {
    let module = full_path.last().map(String::as_str).unwrap_or("");
    ExtractError::Unsupported(format!(
        "#[julia] {kind} `{name}` sits in the inline module `{}`, which is not marked \
         `#[julia]`. The proc-macro cannot see the module an item is in, so it would \
         export `{name}` under the crate-root symbol; mark the module — `#[julia] pub mod \
         {module} {{ ... }}` — so the items inside it get module-qualified symbols (#300).",
        full_path.join("::")
    ))
}

/// `crate::a::b` for a module path, `crate` for the root.
fn crate_path(path: &[String]) -> String {
    if path.is_empty() {
        "crate".to_string()
    } else {
        format!("crate::{}", path.join("::"))
    }
}

/// Where an item is, for a diagnostic: `(line 3 in src/ops.rs)`, or just the
/// line for an in-memory source.
/// The error for a `#[julia] impl` whose target resolves to a struct that
/// carries no `#[julia]` (#315 review). The proc-macro wrapped the methods
/// with *that* type as the receiver, so attaching them to a same-named
/// annotated struct elsewhere would describe a wrapper that dereferences a
/// pointer to the wrong type.
fn plain_target_error(imp: &ScannedImpl, target: &Candidate) -> ExtractError {
    let header = imp.header.display();
    let where_ = location(imp.line, &imp.file);
    let name = &target.name;
    let module = if target.module_path.is_empty() {
        "the crate root".to_string()
    } else {
        format!("module `{}`", target.module_path.join("::"))
    };
    let declared = if target.file.is_empty() {
        String::new()
    } else {
        format!(" (in {})", target.file)
    };
    ExtractError::Unsupported(format!(
        "`{header}` {where_} names `{name}` in {module}{declared}, which is not a \
         `#[julia]` struct. Mark that struct with `#[julia]`, or point the block at the \
         annotated one with an explicit path (`impl crate::path::to::{name}`)."
    ))
}

fn location(line: usize, file: &str) -> String {
    if file.is_empty() {
        format!("(line {line})")
    } else {
        format!("(line {line} in {file})")
    }
}

/// Crate-wide state of the `#[julia]` scan (#315).
///
/// A `#[julia] struct` and its `#[julia] impl` blocks need not live together:
/// `impl C` is legal in any module that has `C` in scope, and in a multi-file
/// crate the two are routinely in different files (`struct Gauge` in `lib.rs`,
/// `impl crate::Gauge` in `ops.rs`). Matching them per file, or per module
/// level, silently dropped the methods of every such struct — the proc-macro
/// had emitted the wrappers, the manifest did not list them, and the Julia
/// module had no method. So the structs and the impl blocks of the whole tree
/// are collected first and married in [`CrateScan::finish`], the block's
/// header resolved through the same resolver the PyO3 scan uses
/// (`crate::paths`): `impl crate::Gauge`, `impl super::Gauge`, `impl Gauge`
/// next to a `use crate::Gauge;`, or a bare `impl Gauge` when the crate has
/// one.
///
/// Two paths are tracked for every item. Its **module path** is where it really
/// is — every module on the way, file (`mod ops;`) and inline — and is what
/// headers are resolved against. Its **symbol path** is the chain of `#[julia]`
/// inline modules the proc-macro folds into its symbols (#300); file modules
/// and unmarked inline modules are transparent to it, and an unmarked module
/// cuts the chain, because whatever is inside it is expanded by the item-level
/// macro, which sees no module at all. The manifest records the symbol path as
/// `module_path`, since that is what the symbols and the Julia layout follow.
///
/// Nothing is dropped silently: a block whose header names no `#[julia]`
/// struct, or an ambiguous one, fails the scan with the unresolved path, and so
/// does a block the proc-macro would give symbols other than the struct's own
/// (`impl_target_module_path` versus the struct's symbol path) — the macro
/// cannot see where the struct is declared, so the header has to spell it.
#[derive(Debug, Default)]
pub struct CrateScan {
    structs: Vec<ScannedStruct>,
    /// Every struct the crate declares **without** `#[julia]`, by name and
    /// module. Rust resolves an `impl` header by scope, not by attribute, so a
    /// plain `struct C` in the block's own module is its target even when a
    /// `#[julia] struct C` exists elsewhere; without these the resolver would
    /// fall back to the annotated one and the manifest would name a wrapper
    /// whose receiver is the *other* type (#315 review).
    plain_structs: Vec<PlainStruct>,
    impls: Vec<ScannedImpl>,
    imports: Vec<ScannedImport>,
    /// Every exported symbol seen so far and the item that claims it, so a
    /// second claimant is reported with both locations (#300).
    claimed: Vec<(String, String)>,
}

#[derive(Debug)]
struct ScannedStruct {
    model: StructModel,
    name: String,
    module_path: Vec<String>,
    symbol_path: Vec<String>,
    /// The `#[cfg]` of every module enclosing the struct (#300 review).
    cfg: Vec<syn::Attribute>,
    file: String,
}

impl Located for ScannedStruct {
    fn name(&self) -> &str {
        &self.name
    }

    fn module_path(&self) -> &[String] {
        &self.module_path
    }
}

/// A struct with no `#[julia]`: a resolution candidate, never a target.
#[derive(Debug)]
struct PlainStruct {
    name: String,
    module_path: Vec<String>,
    file: String,
}

/// A struct an `impl` header may name, annotated or not: `julia` is its index
/// in [`CrateScan::structs`] when it carries `#[julia]`, and `None` when it is
/// a [`PlainStruct`] (#315 review).
#[derive(Debug)]
struct Candidate {
    name: String,
    module_path: Vec<String>,
    julia: Option<usize>,
    file: String,
}

impl Located for Candidate {
    fn name(&self) -> &str {
        &self.name
    }

    fn module_path(&self) -> &[String] {
        &self.module_path
    }
}

#[derive(Debug)]
struct ScannedImpl {
    item: ItemImpl,
    header: ImplHeader,
    symbol_path: Vec<String>,
    /// The `#[cfg]` of the block itself and of every module enclosing it: the
    /// block may sit in a gated module far from its struct, and its methods
    /// exist only under that predicate (#300 review).
    cfg: Vec<syn::Attribute>,
    line: usize,
    file: String,
}

impl CrateScan {
    pub fn new() -> Self {
        CrateScan::default()
    }

    /// Scan one file. `module_path` is where the file sits in the module tree
    /// (empty for the crate root, or for a file scanned as its own root),
    /// `enclosing_cfg` the `#[cfg]` of every `mod` declaration on the way to
    /// it, and `file` labels it in diagnostics.
    ///
    /// `#[julia]` functions go straight into `manifest`; structs and impl
    /// blocks are held until [`CrateScan::finish`].
    pub fn file(
        &mut self,
        items: &[Item],
        module_path: &[String],
        enclosing_cfg: &[syn::Attribute],
        manifest: &mut Manifest,
        file: &str,
    ) -> Result<(), ExtractError> {
        let mut path = module_path.to_vec();
        // A file's items are expanded by the item-level macro, which sees no
        // module: their symbol path starts empty whatever the file's position.
        self.level(items, &mut path, &[], enclosing_cfg, true, manifest, file)
    }

    /// One level of items; inline modules are visited recursively.
    ///
    /// `symbol_path` is the chain of `#[julia]`-marked inline modules leading
    /// here — the path the proc-macro folds into the symbols — and `marked`
    /// says whether *this* level is a marked one (a file's top level counts as
    /// marked): a `#[julia]` function or struct at an unmarked level is
    /// refused, see [`unmarked_module_error`]. An unmarked module cuts the
    /// chain: `codegen::transform_module` leaves it as written, so a marked
    /// module below it is expanded by the item-level macro and starts a chain
    /// of its own. `enclosing_cfg` is the `#[cfg]` of every enclosing module,
    /// which every entry below inherits (#300 review).
    #[allow(clippy::too_many_arguments)]
    fn level(
        &mut self,
        items: &[Item],
        module_path: &mut Vec<String>,
        symbol_path: &[String],
        enclosing_cfg: &[syn::Attribute],
        marked: bool,
        manifest: &mut Manifest,
        file: &str,
    ) -> Result<(), ExtractError> {
        for item in items {
            match item {
                Item::Fn(f) => {
                    let attribute = rustcall_attribute(&f.attrs);
                    if attribute != Attribute::None && !marked {
                        return Err(unmarked_module_error(
                            "function",
                            &f.sig.ident.to_string(),
                            module_path,
                        ));
                    }
                    if attribute == Attribute::Julia {
                        let entry = function_entry(f, attribute, true, symbol_path, enclosing_cfg);
                        for (symbol, owner) in entry.claimed_symbols() {
                            self.claim(symbol, owner, file)?;
                        }
                        manifest.functions.push(entry);
                    }
                }
                Item::Struct(s) => {
                    let Some(model) = StructModel::of(s, Mode::Crate) else {
                        // Not a `#[julia]` struct, but still a name an `impl`
                        // header can resolve to (#315 review).
                        self.plain_structs.push(PlainStruct {
                            name: s.ident.to_string(),
                            module_path: module_path.clone(),
                            file: file.to_string(),
                        });
                        continue;
                    };
                    if !marked {
                        return Err(unmarked_module_error("struct", &model.name(), module_path));
                    }
                    self.structs.push(ScannedStruct {
                        name: model.name(),
                        model,
                        module_path: module_path.clone(),
                        symbol_path: symbol_path.to_vec(),
                        cfg: enclosing_cfg.to_vec(),
                        file: file.to_string(),
                    });
                }
                Item::Impl(imp) => {
                    // A block without `#[julia]` wraps nothing in crate mode;
                    // one with it is attached in `finish`, wherever its struct
                    // is. An impl sits in an unmarked module legitimately: its
                    // symbols follow the struct, not the module.
                    if !impl_has_julia(imp) {
                        continue;
                    }
                    let Some(header) = ImplHeader::of(imp, module_path) else {
                        continue;
                    };
                    self.impls.push(ScannedImpl {
                        item: imp.clone(),
                        header,
                        symbol_path: symbol_path.to_vec(),
                        cfg: crate::cfg::effective_cfg_attrs(enclosing_cfg, &imp.attrs),
                        line: imp.span().start().line,
                        file: file.to_string(),
                    });
                }
                Item::Use(u) => {
                    self.imports.extend(imports_of_use(u, module_path));
                }
                Item::Macro(m) if m.mac.path.is_ident("include") => {
                    // `include!("api.rs")` compiles that file's items into
                    // *this* module — no `mod` declaration reaches it, so the
                    // tree walk has to follow it or the items it exports
                    // disappear from the manifest while the proc-macro still
                    // wraps them (#315 review). Only a literal path can be
                    // followed: `include!(concat!(env!("OUT_DIR"), …))` names a
                    // file the build writes later, and a fragment that is not a
                    // module (`include!("table.rs")` holding `[1, 2, 3]`) does
                    // not parse — both are left to the compiler.
                    let Ok(literal) = m.mac.parse_body::<syn::LitStr>() else {
                        continue;
                    };
                    let base = std::path::Path::new(file)
                        .parent()
                        .map(std::path::Path::to_path_buf)
                        .unwrap_or_default();
                    let included = base.join(literal.value());
                    let Ok(source) = std::fs::read_to_string(&included) else {
                        continue;
                    };
                    let Ok(parsed) = syn::parse_file(&source) else {
                        continue;
                    };
                    let label = included.display().to_string();
                    self.level(
                        &parsed.items,
                        module_path,
                        symbol_path,
                        enclosing_cfg,
                        marked,
                        manifest,
                        &label,
                    )?;
                }
                Item::Mod(m) => {
                    let Some((_, inner)) = &m.content else {
                        // `mod name;` lives in another file; the caller follows
                        // it (see `TreeScan`).
                        continue;
                    };
                    module_path.push(m.ident.to_string());
                    let cfg = crate::cfg::effective_cfg_attrs(enclosing_cfg, &m.attrs);
                    let result = if crate::codegen::is_marked_module(m) {
                        let mut inner_symbol = symbol_path.to_vec();
                        inner_symbol.push(m.ident.to_string());
                        self.level(
                            inner,
                            module_path,
                            &inner_symbol,
                            &cfg,
                            true,
                            manifest,
                            file,
                        )
                    } else {
                        self.level(inner, module_path, &[], &cfg, false, manifest, file)
                    };
                    module_path.pop();
                    result?;
                }
                _ => {}
            }
        }
        Ok(())
    }

    /// Record `symbol` as claimed by `owner`, failing on the second claimant
    /// (#300).
    ///
    /// The symbol scheme keeps items of different modules apart, so a
    /// duplicate here is either two file modules — transparent to the scheme
    /// — defining the same `#[julia]` item, or a crate-root name that spells a
    /// qualified one. The `cdylib` could not export both, and a wrong binding
    /// is worse than no binding, so the scan fails closed and names the fix.
    fn claim(&mut self, symbol: String, owner: String, file: &str) -> Result<(), ExtractError> {
        let here = if file.is_empty() {
            owner
        } else {
            format!("{owner} in {file}")
        };
        if let Some((_, first)) = self.claimed.iter().find(|(s, _)| *s == symbol) {
            return Err(ExtractError::Unsupported(format!(
                "duplicate exported symbol `{symbol}`: claimed by {first} and by {here}. \
                 Two #[julia] items of one crate export the same symbol; only inline modules \
                 marked `#[julia]` (`#[julia] pub mod name {{ ... }}`) qualify a symbol by \
                 their name, while file modules (`mod name;`) do not. Wrap one of the items in \
                 a `#[julia]` module block or rename it (#300)."
            )));
        }
        self.claimed.push((symbol, here));
        Ok(())
    }

    /// Attach every `#[julia] impl` block to its struct and write the structs
    /// to `manifest`, in the order the structs were seen (the CLI sorts a
    /// multi-file manifest afterwards).
    ///
    /// Blocks are visited by (module path, line) so the result does not
    /// depend on the order the caller happened to visit files in.
    pub fn finish(mut self, manifest: &mut Manifest) -> Result<(), ExtractError> {
        let candidates: Vec<Candidate> = self
            .structs
            .iter()
            .enumerate()
            .map(|(i, s)| Candidate {
                name: s.name.clone(),
                module_path: s.module_path.clone(),
                julia: Some(i),
                file: s.file.clone(),
            })
            .chain(self.plain_structs.iter().map(|p| Candidate {
                name: p.name.clone(),
                module_path: p.module_path.clone(),
                julia: None,
                file: p.file.clone(),
            }))
            .collect();
        let mut impls = std::mem::take(&mut self.impls);
        impls.sort_by(|a, b| {
            a.header
                .module_path
                .cmp(&b.header.module_path)
                .then(a.line.cmp(&b.line))
                .then(a.file.cmp(&b.file))
        });

        for imp in &impls {
            // A block with no `#[julia]` method makes the proc-macro emit
            // nothing, whatever it names.
            if wrapped_methods(&imp.item, Mode::Crate, &imp.cfg).is_empty() {
                continue;
            }
            // Resolution follows Rust's own rules, so the plain structs are
            // candidates too; a header that lands on one names a type the
            // proc-macro wrapped as its receiver and RustCall cannot describe
            // (#315 review).
            let index = match locate(&candidates, &imp.header, &self.imports) {
                Ok(index) => match candidates[index].julia {
                    Some(julia) => julia,
                    None => return Err(plain_target_error(imp, &candidates[index])),
                },
                Err(why) => return Err(self.unresolved_impl(imp, why)),
            };
            self.check_symbol_path(imp, index)?;
            self.structs[index]
                .model
                .attach_impl(&imp.item, Mode::Crate, &imp.cfg);
        }

        for scanned in std::mem::take(&mut self.structs) {
            let entry = crate_struct_entry(&scanned.model, &scanned.symbol_path, &scanned.cfg);
            for (symbol, owner) in entry.claimed_symbols() {
                self.claim(symbol, owner, &scanned.file)?;
            }
            manifest.structs.push(entry);
        }
        Ok(())
    }

    fn unresolved_impl(&self, imp: &ScannedImpl, why: Unresolved) -> ExtractError {
        let header = imp.header.display();
        let where_ = location(imp.line, &imp.file);
        let name = &imp.header.target;
        ExtractError::Unsupported(match why {
            Unresolved::NotFound => {
                let looked = if imp.header.qualifier.is_uninformative() {
                    "anywhere in the crate".to_string()
                } else {
                    let places: Vec<String> = imp
                        .header
                        .qualifier
                        .candidates(&imp.header.module_path)
                        .iter()
                        .map(|p| format!("`{}`", crate_path(p)))
                        .collect();
                    if places.is_empty() {
                        "where the header points (it walks above the crate root)".to_string()
                    } else {
                        format!("at {}", places.join(" or "))
                    }
                };
                format!(
                    "#[julia] `{header}` {where_} names no #[julia] struct: no `struct {name}` \
                     marked `#[julia]` is declared {looked}. A `#[julia] impl` block wraps the \
                     methods of a `#[julia]` struct, so mark the struct, or point the header at \
                     one that is (#315)."
                )
            }
            Unresolved::Ambiguous(paths) => {
                let places: Vec<String> = paths
                    .iter()
                    .map(|p| format!("`{}`", crate_path(p)))
                    .collect();
                let first = paths.first().map(|p| crate_path(p)).unwrap_or_default();
                format!(
                    "#[julia] `{header}` {where_} is ambiguous: `#[julia] struct {name}` is \
                     declared in {}, and neither the header nor a `use` in `{}` picks one. Write \
                     the struct's path in the header (`impl {first}::{name}`) (#315).",
                    places.join(" and "),
                    crate_path(&imp.header.module_path)
                )
            }
        })
    }

    /// Refuse a block the proc-macro would give other symbols than the struct
    /// it names has (#315).
    ///
    /// The macro derives a method's symbol from the header and the `#[julia]`
    /// modules around the block ([`crate::codegen::impl_target_module_path`]);
    /// it cannot see where the struct is declared. When that path is not the
    /// struct's own symbol path the wrappers would be exported under one stem
    /// and the struct's `free` / accessors under another, and Julia — which
    /// derives every method symbol from the struct's FFI name — would look for
    /// symbols that do not exist. The manifest cannot describe that honestly,
    /// so the scan fails and names the header that would.
    fn check_symbol_path(&self, imp: &ScannedImpl, index: usize) -> Result<(), ExtractError> {
        let scanned = &self.structs[index];
        let name = scanned.model.name();
        let macro_path = imp.header.qualifier.macro_target_path(&imp.symbol_path);
        let macro_stem = symbol_stem(&macro_path, &name);
        let struct_stem = symbol_stem(&scanned.symbol_path, &name);
        if macro_stem == struct_stem {
            return Ok(());
        }
        let header = imp.header.display();
        let where_ = location(imp.line, &imp.file);
        let block_is = if imp.symbol_path.is_empty() {
            "outside any `#[julia]` module".to_string()
        } else {
            format!(
                "inside the `#[julia]` module `{}`",
                imp.symbol_path.join("::")
            )
        };
        let real = crate_path(&scanned.module_path);
        let fix = if scanned.module_path == scanned.symbol_path {
            format!("write the header as `impl {real}::{name}`")
        } else if scanned.symbol_path.is_empty() {
            format!(
                "bring the struct into scope (`use {real}::{name};`) and write `impl {name}` \
                 outside any `#[julia]` module — the modules in `{real}` are file modules or \
                 unmarked ones, transparent to the symbol scheme (#300), so a header naming \
                 them would qualify the symbols by them"
            )
        } else {
            format!(
                "bring the struct into scope (`use {real}::{name};`) and write `impl {name}` \
                 inside `#[julia] mod {}` (module path `{}`), or move the block next to the \
                 struct",
                scanned.symbol_path.last().map(String::as_str).unwrap_or(""),
                scanned.symbol_path.join("::")
            )
        };
        Err(ExtractError::Unsupported(format!(
            "#[julia] `{header}` {where_}, {block_is}, would export its methods as \
             `rustcall_{macro_stem}_<method>`, but the struct it names, `{real}::{name}`, has \
             the FFI name `{struct_stem}` (`{struct_stem}_free`, \
             `rustcall_{struct_stem}_<method>`). The proc-macro derives a method's symbol from \
             the impl header and the `#[julia]` modules around the block — it cannot see \
             where the struct is declared — so the header has to spell the struct's path: \
             {fix} (#315)."
        )))
    }
}

fn crate_struct_entry(
    model: &StructModel,
    module_path: &[String],
    enclosing_cfg: &[syn::Attribute],
) -> Struct {
    let struct_name = &model.item.ident;
    let effective_cfg = crate::cfg::effective_cfg_attrs(enclosing_cfg, &model.item.attrs);
    let stem = crate::codegen::symbol_stem(module_path, &struct_name.to_string());
    let fields = model
        .named_fields()
        .iter()
        .map(|(name, ty)| {
            let ffi_compatible = is_ffi_compatible_type(ty) || needs_clone_for_getter(ty);
            Field {
                name: name.to_string(),
                rust_type: type_to_string(ty),
                abi: crate::codegen::field_abi(ty).to_string(),
                ffi_compatible,
                getter: if ffi_compatible {
                    crate::codegen::field_getter_symbol(&stem, &name.to_string())
                } else {
                    String::new()
                },
                setter: if ffi_compatible {
                    crate::codegen::field_setter_symbol(&stem, &name.to_string())
                } else {
                    String::new()
                },
                python_name: String::new(),
                vis: String::new(),
                cfg: String::new(),
            }
        })
        .collect();
    // The crate flavour wraps every reported method, so the `Result` / `Option`
    // lowering applies to all of them (#268).
    let shapes: Vec<MethodReturnShape> = model
        .methods
        .iter()
        .map(|m| method_return_shape(struct_name, &m.func, true))
        .collect();
    let methods = model
        .methods
        .iter()
        .enumerate()
        .map(|(i, m)| Method {
            name: m.name(),
            symbol: crate::codegen::method_symbol_of(&stem, &m.name()),
            is_static: m.is_static,
            is_mutable: m.is_mutable,
            is_constructor: returns_boxed_struct(struct_name, &m.func),
            vis: crate::attrs::visibility_string(&m.func.vis),
            skip_reason: String::new(),
            python_name: String::new(),
            accessor: String::new(),
            attribute: m.attribute,
            return_kind: shapes[i].kind,
            ok_type: shapes[i].ok_type.clone(),
            err_type: shapes[i].err_type.clone(),
            inner_type: shapes[i].inner_type.clone(),
            ok_abi: shapes[i].ok_abi.clone(),
            err_abi: shapes[i].err_abi.clone(),
            inner_abi: shapes[i].inner_abi.clone(),
            returns_boxed_struct: returns_boxed_struct(struct_name, &m.func),
            // The block's and its modules' predicates gate the method as much
            // as its own do (#300 review, #315).
            cfg: crate::cfg::predicate_string(&crate::cfg::effective_cfg_attrs(
                &m.enclosing_cfg,
                &m.func.attrs,
            )),
            args: fn_args(&m.func.sig),
            return_type: return_type_to_string(&m.func.sig.output),
            // Crate method wrappers (`generate_method_wrapper_crate`) use the
            // same string ABI as inline ones, with per-method buffer types
            // (`<Struct>_<method>_RustCallOwnedString` / `_free_rust_string`).
            return_abi: crate::codegen::return_abi(&m.func.sig).to_string(),
            generic_wrapper: String::new(),
        })
        .collect();
    Struct {
        cfg: predicate_string(&effective_cfg),
        cfg_features: crate::cfg::predicate_features(&effective_cfg),
        name: model.name(),
        ffi_name: stem,
        attribute: model.attribute,
        vis: crate::attrs::visibility_string(&model.item.vis),
        skip_reason: String::new(),
        python_name: String::new(),
        type_params: generics_to_type_params(&model.item.generics),
        fields,
        methods,
        derives: model.derives.clone(),
        has_clone: false,
        // A `String` field getter hands back an owned buffer, so the struct
        // carries `<Struct>_RustCallOwnedString` / `<Struct>_free_rust_string`
        // in crate mode too (#246).
        has_owned_string_helper: crate::codegen::crate_struct_needs_owned_string_helper(
            &model.item,
        ),
        has_borrowed_string_helper: false,
        context_source: String::new(),
        generic_wrappers: Vec::new(),
        line: model.line,
        module_path: module_path.to_vec(),
    }
}
