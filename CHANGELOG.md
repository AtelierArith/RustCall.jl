# Changelog

All notable changes to RustCall.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking
- **One FFI type contract** ([#276](https://github.com/AtelierArith/RustCall.jl/issues/276)).
  Five independent tables decided "what does this Rust type mean at the C
  boundary?", and they disagreed with each other. Every call site now reads
  `src/ffi_contract.jl`; `_rust_type_to_julia_conversion_type`,
  `_rust_type_to_julia_type_symbol`, `_RUST_PRIMITIVE_TO_JULIA`,
  `rust_to_julia_type_sym`, `julia_sym_to_type` and `RUST_TO_JULIA_TYPE_MAP`
  are deleted. Four user-visible consequences:

  - **Manifest schema 3 → 4.** `Function.return_abi`, `Field.abi` and
    `Method.returns_boxed_struct` are new; the `has_*_string_helper` booleans
    stay for one release, derived from `return_abi`. Run
    `Pkg.build("RustCall")` to rebuild the extractor — a stale binary is
    refused with that hint. Every cache key includes the schema, so artifacts
    are rebuilt.
  - **`str` and `*const u8` are no longer `Cstring`.** `rusttype_to_julia("str")`
    is `RustStr` and `rusttype_to_julia("*const u8")` is `Ptr{UInt8}`. A Rust
    `str` is an unsized UTF-8 slice reached through a `(ptr, len)` fat pointer
    and a `*const u8` is a plain byte pointer; neither is a NUL-terminated C
    string, and treating them as one is
    [#246](https://github.com/AtelierArith/RustCall.jl/issues/246).
    `julia_to_c_type(::Type{RustString})` / `(::Type{RustStr})` are gone for the
    same reason.
  - **Unknown types raise instead of becoming `Any`.** A type the contract
    cannot describe now stops wrapper generation with a message naming the
    signature. `RustCall.FFI_STRICT[]` selects `:error` (default), `:warn` (one
    warning per signature, then `Any` — the pre-#276 behaviour, kept for one
    minor release) or `:none`; `write_bindings_to_file(...; strict = :warn)`
    binds it per call. Generated crate bindings also change text: `usize` is
    spelled `Csize_t`, `*mut i32` is `Ptr{Int32}`, and a `String` field is read
    as an owned buffer rather than `Any`.
  - **A `String` field on the crate path is lowered.** Its getter returns an
    owned `<Struct>_RustCallOwnedString` buffer released through
    `<Struct>_free_rust_string`, as the inline path already did; it used to be
    read as `Any` and leaked
    ([#246](https://github.com/AtelierArith/RustCall.jl/issues/246)).

### Deprecated
- `call_rust_function_infer` guessed the **return** type from the type of the
  **first argument** — `Float64` for `fn f(x: f64) -> i32`, `Cstring` for a
  string argument, `Int64` otherwise. None of that is derivable from an
  argument, and reading a return slot at the wrong width is undefined
  behaviour. It now emits a `Base.depwarn` and raises a `RustError` naming the
  fix ([#245](https://github.com/AtelierArith/RustCall.jl/issues/245),
  [#246](https://github.com/AtelierArith/RustCall.jl/issues/246)). Pass the
  return type: `call_rust_function(func_ptr, T, args...)`, or annotate the call
  site `@rust f(x)::T`. `@rust f(x)` on a function with no manifest-recorded
  return type raises with the same advice instead of guessing.

### Fixed
- `i128`, `u128`, `char`, the `std::os::raw` aliases and raw pointers cross the
  boundary correctly in every position — free functions, methods, struct fields
  and monomorphized generics. `char` travels as its `UInt32` code point and is
  converted, never reinterpreted from Julia's left-aligned UTF-8 `Char`
  ([#245](https://github.com/AtelierArith/RustCall.jl/issues/245)).
- Small-integer and platform-sized struct fields (`u16`, `usize`, …) resolve to
  their own type instead of `Any`
  ([#245](https://github.com/AtelierArith/RustCall.jl/issues/245)).
- Every owned string return names the symbol that releases it, and that symbol
  is resolved inside the library that allocated the buffer — so two libraries
  exporting the same `<owner>_free_rust_string` no longer free through each
  other's allocator
  ([#246](https://github.com/AtelierArith/RustCall.jl/issues/246),
  [#249](https://github.com/AtelierArith/RustCall.jl/issues/249)).

- `#[julia]` is **additive**: the annotated item is kept exactly as written
  (minus the attribute itself) and the `extern "C"` entry point is emitted
  *next to it* under a distinct symbol
  ([#279](https://github.com/AtelierArith/RustCall.jl/issues/279)).
  The export-symbol scheme, documented at the top of
  `deps/rustcall_core/src/codegen.rs`, is:

  | generated item | symbol |
  |---|---|
  | free function `f` | `rustcall_f` |
  | method / constructor `Struct::m` | `rustcall_Struct_m` |
  | specialized generic instantiation `f_i32` | `rustcall_f_i32` |
  | destructor / accessors / clone | `Struct_free`, `Struct_get_x`, `Struct_set_x`, `Struct_clone` (unchanged) |
  | `Result` / `Option` payloads | `CResult_f`, `COption_f` (unchanged) |
  | string buffers | `<owner>_RustCallOwnedString`, `<owner>_free_rust_string`, `<owner>_RustCallBorrowedString` (unchanged) |

  Nothing changes for Julia users: `add(1, 2)`, `@rust add(...)`, `@rust_crate`
  and `write_bindings_to_file` all go through the manifest's `symbol` field.
  What changes is that `fn shout(s: String) -> String` still *exists* in Rust
  after expansion, so `#[julia]` now composes with `#[pyfunction]`, with
  in-crate callers, with `#[test]`s and with `pub use` re-exports. Anyone who
  `dlsym`ed the Rust name directly must switch to the `rustcall_`-prefixed
  symbol, and any generated bindings (e.g. a `write_bindings_to_file` module)
  must be regenerated.
- The FFI manifest schema is now version 3
  ([#279](https://github.com/AtelierArith/RustCall.jl/issues/279)):
  `Function.symbol` and `Method.symbol` differ from `name` for *every* wrapped
  item, not only for generic instantiations. A RustCall.jl expecting schema 2
  refuses a version-3 manifest and vice versa. **Rebuild the extractor** with
  `Pkg.build("RustCall")` after updating.
- The FFI manifest schema was version 2 (`rustcall_core::manifest::SCHEMA_VERSION`,
  `RustCall.MANIFEST_SCHEMA_VERSION`): the string ABI columns `abi`,
  `return_abi` and the `has_owned_string_helper` / `has_borrowed_string_helper`
  flags change how the exported symbols must be called, so a RustCall.jl that
  expects schema 1 refuses a version-2 manifest and vice versa. Rebuild the
  extractor with `Pkg.build("RustCall")` after updating.

### Deprecated
- The LLVM IR integration path is deprecated and will be removed in a future
  breaking release ([#265](https://github.com/AtelierArith/RustCall.jl/issues/265)).
  Affected entry points emit `Base.depwarn` and keep working unchanged:
  `@rust_llvm`, `compile_and_register_rust_function`, `get_registered_function`,
  `compile_rust_to_llvm_ir`, `load_llvm_ir`, `get_function_signature`,
  `get_or_compile_function`, `OptimizationConfig`, `set_default_opt_config`,
  `optimize_module!`, `optimize_function!`, `optimize_for_speed!`,
  `optimize_for_size!`, `optimize_balanced!`.
  Reasons: `@rust_llvm` performs the same function-pointer `ccall` as `@rust`,
  and rustc tracks a newer LLVM than the one bundled with Julia, so the emitted
  IR cannot be parsed reliably. Use `@rust` instead.

### Added
- `#[julia]` functions accept `String` / `&str` arguments and return `String` /
  `&str` ([#242](https://github.com/AtelierArith/RustCall.jl/issues/242)):
  the wrapper uses the same `(ptr, len)` ABI and `<fn>_RustCallOwnedString` /
  `<fn>_free_rust_string` helpers as struct methods, the manifest records
  `has_owned_string_helper` / `has_borrowed_string_helper`, and the Julia
  wrappers (inline blocks and `@rust_crate`) convert transparently.
- CI/CD pipeline with GitHub Actions
- Support for multiple Julia versions (1.10, 1.11, nightly)
- Cross-platform testing (Linux, macOS, Windows)
- CompatHelper integration for dependency updates
- TagBot integration for automated version tagging

### Changed
- Rust syntax is no longer parsed on the Julia side. `rust"""` blocks,
  `@rust_crate` and generics go through the `rustcall-extract` CLI
  (`deps/rustcall_core`, `deps/rustcall_extract`), which emits a TOML FFI
  manifest ([#264](https://github.com/AtelierArith/RustCall.jl/issues/264),
  [#266](https://github.com/AtelierArith/RustCall.jl/pull/266)).
- `#[cfg(...)]`-disabled items are no longer reported by the FFI manifest:
  `rustcall-extract manifest`/`expand` take `--cfg-file` (the output of
  `rustc --print cfg`), evaluate `all`/`any`/`not`/`name`/`name = "value"`
  predicates on items, impl methods, struct fields and inline modules, and drop
  what rustc would not compile. Every reported item records its predicate in a
  new `cfg` field. For direct `rustc` builds Julia queries the configuration
  with the same target and codegen flags as the compilation (`:strict`); for
  the Cargo projects RustCall generates (`// cargo-deps:` blocks) it evaluates
  the same way against Cargo's effective configuration, probed with a throwaway
  crate (`:cargo`). Only external crates (`@rust_crate`), whose features and
  build script RustCall does not control, decide target predicates alone
  (`--cfg-lenient`, `:lenient`). The cfg set is part of the toolchain fingerprint (follow-up of #264).
- Function parameters carrying their own `#[cfg]`
  (`fn f(a: i32, #[cfg(any())] b: i32)`) are pruned like items, so the manifest
  and the generated wrapper match the C ABI rustc actually compiles
  (follow-up of #264).
- Crate-level `#![cfg(...)]` / `#![cfg_attr(...)]` is evaluated before the
  items: a block or crate disabled at file level compiles to nothing, so
  nothing is reported instead of emitting bindings for symbols that never
  exist (follow-up of #264).
- `cfg_attr` expansion runs until nothing changes, so any nesting depth
  reaches its `cfg`; the remaining safety limit (64 levels) is an error, never
  a partial expansion (follow-up of #264).
- Cargo-backed `rust"""` blocks record the tracked Cargo environment as a
  snapshot that is authoritative even when empty: a build or precompiled
  reload clears a `RUSTFLAGS` / profile override that was not set at
  expansion time instead of inheriting it. `CARGO_TARGET_<TRIPLE>_RUSTFLAGS`
  and `CARGO_TARGET_<TRIPLE>_LINKER` are now tracked as well (credential-like
  names stay excluded).
- The in-memory identity of a direct-`rustc` block (`rust_<hash>`) now covers
  the compiler snapshot (target, opt-level, debug info), the cfg text and the
  rustc environment (`RUSTFLAGS`, `RUSTUP_TOOLCHAIN`), through the same
  `_block_identity` helper Cargo-backed blocks use, so the same source built
  under two configurations is two libraries and a lookup never returns the
  other build.
- `#[cfg]`-disabled generic parameters (`fn f<#[cfg(any())] T, U>`, lifetimes
  and const generics, on functions, impls, structs, enums and traits) are
  pruned like items and function parameters (follow-up of #264).
- `--cfg-file` values are parsed as Rust string literals and unescaped exactly
  once, so `custom="\"quoted\""` is no longer conflated with
  `custom="quoted"`; a malformed value is an error.
- `CARGO_HOME` is part of the tracked Cargo environment, together with a
  digest of the effective `$CARGO_HOME/config.toml` (whose `[build] rustflags`
  the cfg probe observes), so a block precompiled under one Cargo home is
  rebuilt rather than reused under another.
- Generic functions of a `// cargo-deps:` block whose body contains `#[cfg]`
  or `cfg!` (reported by the new `body_has_cfg` manifest field) refuse lazy
  specialization with a `RustError`: the specialization is a direct `rustc`
  build under a different configuration than the Cargo build, so the body
  could take another branch. Move such code out of the generic body.
- After a reload that derives a new library name (toolchain or snapshot
  changed since precompilation), the loaded handle is aliased under the
  stored name and the module's active library is updated, so later calls no
  longer reload on every call or fall back to the global symbol search.
- The `CResult_<fn>` / `COption_<fn>` wrappers store the inactive payload as
  `MaybeUninit<T>`, so zero-filling it is no longer undefined behaviour for
  types with invalid zero bit patterns (`NonZeroU32`, references). The C
  layout is unchanged. Rust code reading the wrappers must use the new
  `ok()`, `err()` and `some()` accessors instead of the raw fields
  (follow-up of #264).
- `#[julia]` functions returning `Result`/`Option` keep their `#[cfg]`
  attributes on every generated item (wrapper struct, inner fn, extern fn),
  including the `#[cfg_attr(pred, cfg(...))]` form, which decides whether the
  function is compiled just like a direct `#[cfg]`.
- `rustcall-extract` reads its arguments as `OsString`, so non-UTF-8 file
  paths work on Windows (follow-up of #264).


## [0.1.0] - 2026-01-XX

### Added
- **Phase 1: C-Compatible ABI**
  - `@rust` macro for calling Rust functions
  - `rust""` string literal for compiling and loading Rust code
  - `@irust` macro for function-scope Rust execution
  - Type mapping between Rust and Julia types
  - `RustResult<T, E>` and `RustOption<T>` support
  - String type support (`*const u8`, `Cstring`)
  - Compilation caching system (SHA256-based)

- **Phase 2: LLVM IR Integration**
  - `@rust_llvm` macro (experimental)
  - LLVM optimization passes
  - Ownership types: `RustBox`, `RustRc`, `RustArc`, `RustVec`, `RustSlice`
  - Array operations (indexing, iteration, conversion)
  - Generics support with automatic monomorphization
  - Enhanced error handling with `RustError` exception type
  - Function registration and caching system

- **Phase 3: External Library Integration**
  - Cargo dependency management
  - Support for `//! ```cargo ... ``` ` and `// cargo-deps:` formats
  - Automatic crate downloading and building
  - Integration with popular crates (ndarray, serde, rand, etc.)

- **Phase 4: Rust Structs as Julia Objects**
  - Automatic struct detection and Julia wrapper generation
  - C-FFI wrapper generation for Rust methods
  - Dynamic Julia type generation at macro expansion time
  - Automatic memory management with finalizers
  - Managed lifecycle for Rust objects in Julia

### Documentation
- Comprehensive API documentation
- Design documents (Phase1-4)
- Usage examples and tutorials
- Performance benchmarks
- Troubleshooting guide

### Testing
- 750+ tests covering all major features
- Test suites for cache, ownership, arrays, generics, error handling
- Integration tests for Rust helpers library
- Documentation examples tests

[Unreleased]: https://github.com/atelierarith/RustCall.jl/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/atelierarith/RustCall.jl/releases/tag/v0.1.0
