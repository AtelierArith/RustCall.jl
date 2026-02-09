# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RustCall.jl is a Julia FFI package for calling Rust code directly from Julia, inspired by Cxx.jl. It provides `rust"""..."""` string literals for compiling Rust snippets, `@rust` for FFI calls, `@irust` for inline Rust with `$var` binding, `@rust_crate` for external crate bindings, and a `#[julia]` proc-macro attribute. Requires Julia 1.12+ and Rust toolchain (rustc, cargo).

## Common Commands

```bash
# Setup and build
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project -e 'using Pkg; Pkg.build("RustCall")'   # builds deps/rust_helpers

# Run all tests
julia --project -e 'using Pkg; Pkg.test()'

# Run a single test file
julia --project test/test_cache.jl

# Build documentation
julia --project=docs docs/make.jl

# Proc-macro crate (deps/juliacall_macros)
cd deps/juliacall_macros && cargo fmt --check
cd deps/juliacall_macros && cargo clippy --all-targets --all-features -- -D warnings
cd deps/juliacall_macros && cargo test --all-features
```

## Architecture

### Compilation pipeline

1. `rust"""..."""` (`src/ruststr.jl`) parses Rust code, wraps it, and hands off to the compiler
2. `src/compiler.jl` invokes `rustc` to produce shared libraries or LLVM IR
3. `src/codegen.jl` generates `ccall` expressions; `src/llvmcodegen.jl` / `src/llvmintegration.jl` handle the LLVM IR path
4. `src/rustmacro.jl` expands `@rust` and `@irust` into the appropriate call mechanism
5. `src/cache.jl` provides SHA256-based caching of compiled artifacts to avoid recompilation

### Type system and runtime

- `src/types.jl` — Rust/Julia wrapper types: `RustPtr`, `RustRef`, `RustResult`, `RustOption`, ownership types (`RustBox`, `RustRc`, `RustArc`, `RustVec`, `RustSlice`)
- `src/typetranslation.jl` — bidirectional Rust ↔ Julia type mapping
- `src/memory.jl` — ownership operations backed by the Rust helpers library (`deps/rust_helpers/`)
- `src/exceptions.jl` — `RustError`, `CompilationError`, `RuntimeError`

### External crate integration

- `src/dependencies.jl` + `src/dependency_resolution.jl` — parse `// cargo-deps:` and `` //! ```cargo ``` `` formats
- `src/cargoproject.jl` + `src/cargobuild.jl` — generate and build Cargo projects
- `src/julia_functions.jl` — parse/transform `#[julia]` attributes into C-ABI wrappers
- `src/crate_bindings.jl` — crate scanning, Julia wrapper generation, `@rust_crate` macro

### Other modules

- `src/generics.jl` — generic function monomorphization and registry
- `src/structs.jl` — automatic `pub struct` detection and Julia type generation
- `src/hot_reload.jl` — file watching and reload for crate workflows

### Include order

`src/RustCall.jl` defines the include order, which reflects module dependencies. New modules must be added respecting this order.

## Thread Safety

Global state is protected by `REGISTRY_LOCK` (ReentrantLock) in `src/RustCall.jl`. This guards `RUST_LIBRARIES`, `RUST_MODULE_REGISTRY`, and `GENERIC_FUNCTION_REGISTRY`. A separate `LLVM_REGISTRY_LOCK` protects LLVM operations.

## Testing

- Entry point: `test/runtests.jl` (includes 30+ test files)
- Tests are organized by feature: ownership, arrays, generics, cargo, crate bindings, hot reload, etc.
- `test/test_regressions.jl` holds regression tests for fixed issues
- Proc-macro tests: `deps/juliacall_macros/tests/`
- Many tests require `rustc` and skip gracefully if unavailable

## CI

Two jobs in `.github/workflows/CI.yml`:
- **Rust tests**: `cargo fmt --check`, `cargo clippy`, `cargo test` in `deps/juliacall_macros` (stable + beta, Linux/macOS/Windows)
- **Julia tests**: `Pkg.test()` on Julia 1.x (Ubuntu x64, Windows x64, macOS aarch64)

## Known Pitfalls

- **String interpolation**: `"$var[i]"` interpolates only `var`, not `var[i]`. Always use `"$(var[i])"` for complex expressions. CI lint checks for this pattern.
- **Julia type aliases**: `Cvoid === Nothing` and `Cstring === Ptr{UInt8}`. Defining methods for both causes "method overwritten" warnings. Define for the canonical type only.
- **Platform-dependent types**: `Clong`/`Culong` size varies by OS and architecture.

## Conventions

- 4-space indentation, no tabs
- `CamelCase` for modules/types; `snake_case` for functions/variables
- Extend existing modules rather than introducing parallel pipelines
- Keep generated/binding code deterministic and cache-aware
- Add tests alongside new functionality; include regression coverage for macro/parsing changes
- `Cxx.jl/` and `julia/` are vendored upstream trees — do not edit for RustCall features
