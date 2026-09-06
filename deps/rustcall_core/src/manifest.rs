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
///
/// History:
/// * 1: initial manifest (#264).
/// * 2: string ABI (#242): `Arg.abi`, `Method.return_abi` and the
///   `has_owned_string_helper` / `has_borrowed_string_helper` flags decide
///   how a consumer must call the exported symbols (`(ptr, len)` pairs and
///   `<name>_RustCallOwnedString` buffers), so a version-1 consumer must not
///   load a version-2 manifest, nor the reverse.
/// * 3: additive `#[julia]` (#279): the annotated item keeps its name and the
///   exported entry point is a wrapper emitted next to it, so `Function.symbol`
///   and `Method.symbol` now differ from `name` for *every* wrapped item
///   (`rustcall_<fn>` / `rustcall_<Struct>_<method>`), not only for generic
///   instantiations. A version-2 consumer would `dlsym` the Rust name and find
///   nothing.
/// * 4: one vocabulary for the type contract (#276): `Function.return_abi`
///   replaces the pair of `has_*_string_helper` booleans as the *normative*
///   description of a free function's return (the booleans stay, derived, for
///   one release), `Field.abi` says how a field getter returns its value so
///   Julia never re-derives it from the type spelling, and
///   `Method.returns_boxed_struct` states explicitly what Julia used to infer
///   by comparing `return_type` against `"Self"`. A version-3 consumer would
///   read a `String` field getter as an opaque value.
/// * 5: PyO3 crate scan (#275 Phase 1): items carrying only PyO3 attributes are
///   reported alongside `#[julia]` ones with a PyO3 [`Attribute`] origin,
///   every function / struct / method carries [`Function::vis`] and
///   [`Function::skip_reason`], and a `PyResult<T>` return is reported as
///   [`ReturnKind::PyResult`]. A version-4 consumer would treat a
///   `#[pyfunction]` as an exported `#[julia]` function and `dlsym` a symbol
///   that no wrapper crate has emitted yet.
pub const SCHEMA_VERSION: u32 = 5;

/// Vocabulary of [`Function::skip_reason`] / [`Struct::skip_reason`] /
/// [`Method::skip_reason`]. An empty reason means the item is wrappable.
///
/// The values are a closed set so Julia can group and translate them; anything
/// carrying a detail appends it after a `:`.
pub mod skip_reason {
    /// The item is not `pub`, so a wrapper crate compiled outside the scanned
    /// crate cannot name it (`E0603`).
    pub const NOT_PUBLIC: &str = "not_public";
    /// The signature mentions a type that only exists with a live Python
    /// interpreter (`PyObject`, `Py<T>`, `Bound<'_, T>`, `Python<'_>`,
    /// `PyRef`, anything under `pyo3::`). The offending type follows the colon.
    pub const PYO3_TYPE: &str = "pyo3_type";
    /// A `#[pymodule]` initialiser: it exists to be called by the Python
    /// import machinery and has no meaning without an interpreter.
    pub const PYMODULE: &str = "pymodule";
    /// A generic item: monomorphization of PyO3 items is not part of #275.
    pub const GENERIC: &str = "generic";
    /// A method whose `#[pyclass]` is itself skipped (the reason follows the
    /// colon), so there is no handle type to hang it off.
    pub const OWNER_SKIPPED: &str = "owner_skipped";

    /// `"<kind>:<detail>"`, e.g. `"pyo3_type:Python<'_>"`.
    pub fn detailed(kind: &str, detail: &str) -> String {
        format!("{kind}:{detail}")
    }
}

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
    /// `#[pyfunction]` with no RustCall attribute (#275). The item is reported
    /// so a Phase-2 wrapper crate can generate an `extern "C"` entry point for
    /// it; nothing exports it yet.
    PyFunction,
    /// `#[pyclass]` with no RustCall attribute (#275): an opaque handle, never
    /// `repr(C)`.
    PyClass,
    /// A method collected from a `#[pymethods]` block of a [`Attribute::PyClass`]
    /// struct (#275).
    PyMethods,
    /// A `#[pymodule]` initialiser (#275). Always skipped, see
    /// [`skip_reason::PYMODULE`].
    PyModule,
    /// No RustCall attribute: a plain function that is still reported so Julia
    /// can register return types for `@rust f(...)` calls without `::T`.
    None,
}

impl Attribute {
    /// Whether this origin comes from the PyO3 scan (#275) rather than from a
    /// RustCall attribute.
    pub fn is_pyo3_scan(self) -> bool {
        matches!(
            self,
            Attribute::PyFunction | Attribute::PyClass | Attribute::PyMethods | Attribute::PyModule
        )
    }
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
    /// `PyResult<T>` (= `Result<T, PyErr>`) of a scanned PyO3 item (#275), with
    /// `T` in [`Function::ok_type`].
    ///
    /// Creating and dropping a `PyErr` without a Python interpreter is safe,
    /// but rendering one is not: `Display`/`Debug` on a `PyErr` panics inside
    /// pyo3 and the panic crossing `extern "C"` aborts the process. A Phase-2
    /// wrapper must therefore report the error as an opaque flag and never
    /// format it.
    PyResult,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Arg {
    pub name: String,
    pub rust_type: String,
    /// How the wrapper receives the argument: `""` as written (`rust_type`),
    /// `"string"` (`String`: `(ptr, len)` bytes copied into an owned String),
    /// `"str"` (`&str`, any lifetime: `(ptr, len)` bytes borrowed).
    #[serde(default)]
    pub abi: String,
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
    /// Exported C symbol. `#[julia]` is additive, so a wrapped function is
    /// exported as `rustcall_<name>` and never under `name` itself (#279); a
    /// plain `#[no_mangle] extern "C"` function keeps its own name.
    pub symbol: String,
    /// Which attribute the item was reported for. Since schema 5 this is also
    /// the *origin*: a `py_*` value means the entry came from the PyO3 scan of
    /// #275, not from a RustCall attribute.
    pub attribute: Attribute,
    /// Visibility as written: `"pub"`, `"pub(crate)"`, `"pub(super)"`,
    /// `"pub(in path)"`, or `""` for a private item. Only a `pub` item can be
    /// called from a wrapper crate compiled outside the scanned crate (#275).
    #[serde(default)]
    pub vis: String,
    /// Why this item cannot be wrapped, from the [`skip_reason`] vocabulary;
    /// empty when it can (#275). Always empty for `#[julia]` items, which are
    /// only reported when they are wrapped.
    #[serde(default)]
    pub skip_reason: String,
    /// The name the item is exposed under in Python (`#[pyo3(name = "...")]`),
    /// empty when it is the Rust name or the item is not a PyO3 one (#275).
    #[serde(default)]
    pub python_name: String,
    /// True when the generated code carries `#[no_mangle] extern "C"`.
    ///
    /// Always `false` for a PyO3-scanned item: [`Function::symbol`] names the
    /// wrapper a Phase-2 wrapper crate *will* emit, and nothing exports it yet.
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
    /// How the wrapper returns the value: `""` as written, `"string"` for an
    /// owned `<fn>_RustCallOwnedString` (a `String`, or a `&str` copied because
    /// it may borrow from a converted argument), `"str"` for a borrowed
    /// `<fn>_RustCallBorrowedString`. Same vocabulary as [`Arg::abi`] and
    /// [`Method::return_abi`]; this is the normative column since schema 4 and
    /// the `has_*_string_helper` booleans below are derived from it (#276).
    #[serde(default)]
    pub return_abi: String,
    /// `T` of `Result<T, E>`, empty otherwise.
    #[serde(default)]
    pub ok_type: String,
    /// `E` of `Result<T, E>`, empty otherwise.
    #[serde(default)]
    pub err_type: String,
    /// `T` of `Option<T>`, empty otherwise.
    #[serde(default)]
    pub inner_type: String,
    /// The function returns `String`: the wrapper returns
    /// `<fn>_RustCallOwnedString { ptr, len, cap }`, released through
    /// `<fn>_free_rust_string(ptr, len, cap)` (#242).
    ///
    /// Derived from [`Function::return_abi`] since schema 4 and kept for one
    /// release so a consumer that still reads the boolean keeps working (#276).
    #[serde(default)]
    pub has_owned_string_helper: bool,
    /// The function returns `&str`: the wrapper returns
    /// `<fn>_RustCallBorrowedString { ptr, len }` (#242). Derived from
    /// [`Function::return_abi`], see [`Function::has_owned_string_helper`].
    #[serde(default)]
    pub has_borrowed_string_helper: bool,
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
    /// How the generated getter returns the field: `""` as written
    /// (`rust_type`), `"string"` for an owned `<Struct>_RustCallOwnedString`
    /// released through `<Struct>_free_rust_string`. Same vocabulary as
    /// [`Arg::abi`] / [`Method::return_abi`], so Julia never has to re-derive
    /// the lowering from the type spelling (#276).
    #[serde(default)]
    pub abi: String,
    /// Whether Julia may read this field through an exported getter.
    pub ffi_compatible: bool,
    /// Exported symbol that reads the field. Usually `<Struct>_get_<field>`; in
    /// inline mode a same-named method wrapper takes precedence. Empty if none.
    #[serde(default)]
    pub getter: String,
    /// Exported symbol that writes the field (`<Struct>_set_<field>`). Empty if none.
    #[serde(default)]
    pub setter: String,
    /// The name the field is exposed under in Python
    /// (`#[pyo3(get, name = "...")]`), empty when it is the Rust name or the
    /// struct is not a `#[pyclass]` (#275).
    #[serde(default)]
    pub python_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Method {
    pub name: String,
    /// Exported C symbol of the wrapper (`rustcall_<Struct>_<method>`, #279).
    /// Empty for generic structs, whose wrappers are registered for
    /// monomorphization instead.
    pub symbol: String,
    pub is_static: bool,
    pub is_mutable: bool,
    pub is_constructor: bool,
    /// Visibility as written: `"pub"`, `"pub(crate)"`, `"pub(super)"`,
    /// `"pub(in path)"`, or `""` for a private item. Only a `pub` item can be
    /// called from a wrapper crate compiled outside the scanned crate (#275).
    #[serde(default)]
    pub vis: String,
    /// Why this item cannot be wrapped, from the [`skip_reason`] vocabulary;
    /// empty when it can (#275). Always empty for `#[julia]` items, which are
    /// only reported when they are wrapped.
    #[serde(default)]
    pub skip_reason: String,
    /// The name the item is exposed under in Python (`#[pyo3(name = "...")]`),
    /// empty when it is the Rust name or the item is not a PyO3 one (#275).
    #[serde(default)]
    pub python_name: String,
    /// `"getter"` / `"setter"` for a `#[getter]` / `#[setter]` method of a
    /// `#[pymethods]` block, empty otherwise (#275).
    #[serde(default)]
    pub accessor: String,
    /// Whether the wrapper boxes the result and returns `*mut Struct`
    /// (`crate::codegen::returns_boxed_struct`). Julia used to infer this by
    /// comparing `return_type` against `"Self"` and the struct name, which
    /// disagreed with codegen for a non-static method called `new` (#276).
    #[serde(default)]
    pub returns_boxed_struct: bool,
    #[serde(default)]
    pub args: Vec<Arg>,
    pub return_type: String,
    /// How the wrapper returns the value: `""` as written, `"string"` for an
    /// owned `<Struct>_RustCallOwnedString` (a `String`, or a `&str` copied
    /// because it may borrow from a converted argument), `"str"` for a
    /// borrowed `<Struct>_RustCallBorrowedString`.
    #[serde(default)]
    pub return_abi: String,
    /// For generic structs: the generic wrapper source registered for
    /// monomorphization. Empty otherwise.
    #[serde(default)]
    pub generic_wrapper: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Struct {
    pub name: String,
    pub attribute: Attribute,
    /// Visibility as written: `"pub"`, `"pub(crate)"`, `"pub(super)"`,
    /// `"pub(in path)"`, or `""` for a private item. Only a `pub` item can be
    /// called from a wrapper crate compiled outside the scanned crate (#275).
    #[serde(default)]
    pub vis: String,
    /// Why this item cannot be wrapped, from the [`skip_reason`] vocabulary;
    /// empty when it can (#275). Always empty for `#[julia]` items, which are
    /// only reported when they are wrapped.
    #[serde(default)]
    pub skip_reason: String,
    /// The name the item is exposed under in Python (`#[pyo3(name = "...")]`),
    /// empty when it is the Rust name or the item is not a PyO3 one (#275).
    #[serde(default)]
    pub python_name: String,

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
