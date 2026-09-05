//! FFI manifest model.
//!
//! The manifest is the single source of truth that Julia consumes. It describes
//! every symbol the generated shared library exposes, plus the information
//! Julia needs for generic monomorphization. It is produced by the same `syn`
//! visitors that drive wrapper code generation, so it always reflects what was
//! actually generated.
//!
//! Serialized as TOML so that Julia can read it with the standard-library
//! `TOML` module without extra dependencies.

use serde::{Deserialize, Serialize};

/// Bump whenever a field is added, removed or changes meaning. Julia refuses to
/// load a manifest whose `schema_version` it does not understand.
pub const SCHEMA_VERSION: u32 = 1;

/// Which pipeline produced the manifest.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    /// `rust"""..."""` blocks: `#[julia]` items are expanded by the extractor CLI
    /// before `rustc` runs, all `pub fn` methods of `#[julia]` structs are wrapped,
    /// and generic items are reported for runtime monomorphization.
    Inline,
    /// `@rust_crate`: `#[julia]` items are expanded by the `juliacall_macros`
    /// proc-macro inside Cargo; only explicitly attributed methods are wrapped.
    Crate,
}

impl Mode {
    pub fn parse(s: &str) -> Option<Mode> {
        match s {
            "inline" => Some(Mode::Inline),
            "crate" => Some(Mode::Crate),
            _ => None,
        }
    }
}

/// Which attribute (if any) marked an item.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Attribute {
    Julia,
    JuliaPyo3,
    /// `#[derive(JuliaStruct)]` on a struct (inline mode only).
    DeriveJuliaStruct,
    /// No RustCall attribute: a plain function that is still reported so Julia
    /// can register return types for `@rust f(...)` calls without `::T`.
    None,
}

/// Shape of a function's return value on the C ABI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReturnKind {
    /// Returned as-is.
    Plain,
    /// `()` / no return type.
    Unit,
    /// `Result<T, E>` wrapped into `CResult_<fn>` `{ is_ok: u8, ok_value: T, err_value: E }`.
    Result,
    /// `Option<T>` wrapped into `COption_<fn>` `{ is_some: u8, value: T }`.
    Option,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Arg {
    pub name: String,
    pub rust_type: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TraitBound {
    pub trait_name: String,
    #[serde(default)]
    pub type_params: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TypeParam {
    pub name: String,
    #[serde(default)]
    pub bounds: Vec<TraitBound>,
}

/// A free function.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Function {
    pub name: String,
    /// Exported C symbol. Equal to `name` for non-generic functions.
    pub symbol: String,
    pub attribute: Attribute,
    /// True when the generated code carries `#[no_mangle] extern "C"`.
    pub exported: bool,
    /// `#[cfg(...)]` predicate of the item (`unix`, `all(unix, feature = "x")`),
    /// empty when unconditional. Items whose predicate is false under the
    /// configuration given to the extractor are not reported at all.
    #[serde(default)]
    pub cfg: String,
    pub is_generic: bool,
    #[serde(default)]
    pub type_params: Vec<TypeParam>,
    #[serde(default)]
    pub args: Vec<Arg>,
    /// Return type as written in the source (`i32`, `Result<f64, i32>`, `()`).
    pub return_type: String,
    pub return_kind: ReturnKind,
    /// `T` of `Result<T, E>`, empty otherwise.
    #[serde(default)]
    pub ok_type: String,
    /// `E` of `Result<T, E>`, empty otherwise.
    #[serde(default)]
    pub err_type: String,
    /// `T` of `Option<T>`, empty otherwise.
    #[serde(default)]
    pub inner_type: String,
    /// Source of the function item (generic functions only), used for
    /// runtime monomorphization via `specialize`.
    #[serde(default)]
    pub source: String,
    /// Whether the body contains a `#[cfg(...)]` / `#[cfg_attr(...)]`
    /// attribute or a `cfg!(...)` macro. Item-level pruning never resolves
    /// those, so the body still depends on the configuration it is compiled
    /// under; a caller that later compiles the (specialized) source under
    /// another configuration than the one the item was extracted for must
    /// refuse rather than guess.
    #[serde(default)]
    pub body_has_cfg: bool,
    /// 1-based line of the item in the input file.
    pub line: usize,
    /// Enclosing inline modules (`mod api { mod deep { fn f } }` -> `["api", "deep"]`).
    /// `specialize` locates the function by `module_path::name` in the expanded source.
    #[serde(default)]
    pub module_path: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Field {
    pub name: String,
    pub rust_type: String,
    /// Whether Julia may read this field through an exported getter.
    pub ffi_compatible: bool,
    /// Exported symbol that reads the field. Usually `<Struct>_get_<field>`; in
    /// inline mode a same-named method wrapper takes precedence. Empty if none.
    #[serde(default)]
    pub getter: String,
    /// Exported symbol that writes the field (`<Struct>_set_<field>`). Empty if none.
    #[serde(default)]
    pub setter: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Method {
    pub name: String,
    /// Exported C symbol of the wrapper (`Struct_method`). Empty for generic
    /// structs, whose wrappers are registered for monomorphization instead.
    pub symbol: String,
    pub is_static: bool,
    pub is_mutable: bool,
    pub is_constructor: bool,
    #[serde(default)]
    pub args: Vec<Arg>,
    pub return_type: String,
    /// For generic structs: the generic wrapper source registered for
    /// monomorphization. Empty otherwise.
    #[serde(default)]
    pub generic_wrapper: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Struct {
    pub name: String,
    pub attribute: Attribute,
    /// `#[cfg(...)]` predicate of the struct item, see [`Function::cfg`].
    #[serde(default)]
    pub cfg: String,
    #[serde(default)]
    pub type_params: Vec<TypeParam>,
    #[serde(default)]
    pub fields: Vec<Field>,
    #[serde(default)]
    pub methods: Vec<Method>,
    /// Other derives seen alongside `JuliaStruct` (e.g. `Clone`).
    #[serde(default)]
    pub derives: Vec<String>,
    /// Whether a `<Struct>_clone` wrapper was generated.
    pub has_clone: bool,
    /// Whether the `<Struct>_RustCallOwnedString` / `<Struct>_free_rust_string`
    /// helpers were generated (inline mode).
    pub has_owned_string_helper: bool,
    /// Whether the `<Struct>_RustCallBorrowedString` helper was generated (inline mode).
    pub has_borrowed_string_helper: bool,
    /// Source of the struct and its impl blocks (generic structs only), used as
    /// context for runtime monomorphization.
    #[serde(default)]
    pub context_source: String,
    /// Generic accessor / free wrappers registered for monomorphization
    /// (generic structs only).
    #[serde(default)]
    pub generic_wrappers: Vec<GenericWrapper>,
    pub line: usize,
    /// Enclosing inline modules of the struct (see [`Function::module_path`]).
    #[serde(default)]
    pub module_path: Vec<String>,
}

/// A generic wrapper of a generic inline struct. In inline mode the wrapper is
/// also emitted (non-exported) into the expanded source next to the struct so
/// that `specialize` can instantiate it in place with all module-scoped names
/// available.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenericWrapper {
    pub name: String,
    pub source: String,
    /// Type parameter names as declared by the wrapper, in the order of the
    /// struct's own parameters (an `impl<U> Wrapper<U>` wrapper lists `U` where
    /// the struct declares `T`), followed by method-level parameters.
    #[serde(default)]
    pub type_params: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Manifest {
    pub schema_version: u32,
    pub mode: Mode,
    #[serde(default)]
    pub functions: Vec<Function>,
    #[serde(default)]
    pub structs: Vec<Struct>,
}

impl Manifest {
    pub fn new(mode: Mode) -> Self {
        Manifest {
            schema_version: SCHEMA_VERSION,
            mode,
            functions: Vec::new(),
            structs: Vec::new(),
        }
    }

    /// Merge another manifest (e.g. from a second source file) into this one.
    pub fn merge(&mut self, other: Manifest) {
        self.functions.extend(other.functions);
        self.structs.extend(other.structs);
    }

    /// Sort entries so output is deterministic regardless of file order.
    pub fn sort(&mut self) {
        self.functions
            .sort_by(|a, b| a.name.cmp(&b.name).then(a.line.cmp(&b.line)));
        self.structs
            .sort_by(|a, b| a.name.cmp(&b.name).then(a.line.cmp(&b.line)));
    }

    pub fn to_toml(&self) -> Result<String, toml::ser::Error> {
        toml::to_string(self)
    }

    pub fn from_toml(s: &str) -> Result<Manifest, toml::de::Error> {
        toml::from_str(s)
    }
}
