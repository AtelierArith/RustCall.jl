# Changelog

All notable changes to RustCall.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Added
- CI/CD pipeline with GitHub Actions
- Support for multiple Julia versions (1.10, 1.11, nightly)
- Cross-platform testing (Linux, macOS, Windows)
- CompatHelper integration for dependency updates
- TagBot integration for automated version tagging

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
