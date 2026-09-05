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
