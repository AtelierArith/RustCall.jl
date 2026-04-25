# Project Status

Last updated: 2026-04-22

## Summary

| Item | Current State |
|------|---------------|
| Core FFI (`rust"""`, `@rust`, `@irust`) | ✅ Implemented |
| LLVM integration (`@rust_llvm`) | ✅ Implemented (experimental path) |
| Cargo dependency integration | ✅ Implemented |
| Struct/object mapping | ✅ Implemented |
| `#[julia]` attribute support | ✅ Implemented |
| External crate bindings (`@rust_crate`) | ✅ Implemented |
| Hot reload support | ✅ Implemented |
| Julia General registry | ✅ Registered (`Pkg.add("RustCall")`) |
| Root Julia tests | ✅ Present (`test/runtests.jl`, `ParallelTestRunner.jl` over `test/test_*.jl`) |
| CI (Julia + Rust proc-macro checks) | ✅ Configured (`julia-actions/julia-runtest@v1` with per-platform `test_args`) |

## Codebase Snapshot

Based on the repository state on 2026-02-07. Only the summary/test runner status above was refreshed on 2026-04-17; these inventory counts were not recomputed:

| Area | Files | Approx. Lines |
|------|-------|---------------|
| Julia source (`src/*.jl`) | 22 | 12,750 |
| Julia tests (`test/*.jl`) | 28 | 5,769 |
| Benchmarks (`benchmark/*.jl`) | 5 | 1,455 |
| Rust helpers (`deps/rust_helpers/src/lib.rs`) | 1 | 626 |
| Proc-macro crate (`deps/juliacall_macros`) | 5 Rust files | 1,256 |

## Architecture Map

### Julia entry points
- `src/RustCall.jl`: module entrypoint, exports, initialization.
- `src/ruststr.jl`: `rust"""` processing, compilation/load integration.
- `src/rustmacro.jl`: `@rust`, `@irust`, call expansion.

### Compilation and code generation
- `src/compiler.jl`: rustc invocation and compile orchestration.
- `src/codegen.jl`: `ccall` generation utilities.
- `src/llvmintegration.jl`, `src/llvmcodegen.jl`, `src/llvmoptimization.jl`: LLVM path.

### Type and runtime layer
- `src/types.jl`: Rust wrapper types (`RustResult`, `RustOption`, ownership types).
- `src/typetranslation.jl`: Rust/Julia type mapping.
- `src/exceptions.jl`: error conversion and diagnostics.
- `src/memory.jl`: ownership helper interop.

### Cargo/crate workflows
- `src/dependencies.jl`, `src/dependency_resolution.jl`: dependency parsing/resolution.
- `src/cargoproject.jl`, `src/cargobuild.jl`: Cargo project/build flow.
- `src/julia_functions.jl`: `#[julia]` parsing/transform/wrapper support.
- `src/crate_bindings.jl`: crate scanning, binding generation, `@rust_crate`.
- `src/hot_reload.jl`: crate hot reload support.

### Caching and generics
- `src/cache.jl`: compiled artifact cache.
- `src/generics.jl`: monomorphization and generic function support.

## Test and CI Status

### Julia tests
- Root entry point: `test/runtests.jl`
- Runner: `ParallelTestRunner.jl`, which discovers files matching `test/test_*.jl`
- Coverage includes cache, ownership, arrays, generics, error handling, LLVM path, external crates, `#[julia]`, crate bindings, hot reload, and regressions.

### Rust proc-macro tests
- Location: `deps/juliacall_macros/tests/`
- CI runs `cargo fmt --check`, `cargo clippy --all-targets --all-features -- -D warnings`, and `cargo test --all-features`.

### GitHub Actions
- Workflow: `.github/workflows/CI.yml`
- Matrix includes Julia tests across Linux/macOS/Windows and Rust proc-macro checks across toolchains/OSes.

## Tooling Requirements

- Julia `1.12+` (see `Project.toml` compat)
- Rust toolchain (`rustc`, `cargo`)

`Pkg.add("RustCall")` installs RustCall.jl from Julia's General registry and builds the ownership/runtime helper library. If the helper library needs to be rebuilt, run:

```julia
using Pkg
Pkg.build("RustCall")
```

## Current Limitations

- The direct FFI path is centered on `extern "C"` entry points; it does not model Rust lifetimes or borrow-checker guarantees on the Julia side.
- `@rust_llvm` is available but remains an experimental path compared with standard `@rust` calls.
- Ownership helpers such as `RustBox`, `RustRc`, `RustArc`, `RustVec`, and `RustSlice` depend on the helper library built during package installation.
- Generic structs and more advanced trait patterns still need explicit handling in some cases, especially for external bindings.
- Cargo-backed workflows are cached, but first builds can be slow and some crates may still need platform-specific build configuration.

## Delivered Milestones

- Phase 1: direct `rust"""..."""`, `@rust`, `@irust`, type mapping, string support, and cache-backed compilation.
- Phase 2: ownership/runtime helpers, generics support, and the experimental LLVM path.
- Phase 3: Cargo dependency parsing and external crate use inside inline Rust code.
- Phase 4: Rust struct and method mapping into Julia-facing objects.
- Phase 5: `#[julia]`-driven wrapper generation.
- Phase 6: external crate binding generation with `@rust_crate` and the `juliacall_macros` proc-macro crate.

## Near-Term Priorities

- Stabilize and document `@rust_llvm` behavior across more type patterns.
- Continue regression hardening for crate binding and hot reload workflows.
- Prepare distribution tasks for crates.io publication of proc-macro tooling.
