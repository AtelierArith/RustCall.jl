# Project Status

Last updated: 2026-09-07

## Summary

| Item | Current State |
|------|---------------|
| Core FFI (`rust"""`, `@rust`, `@irust`) | ✅ Implemented |
| Cargo dependency integration | ✅ Implemented |
| Struct/object mapping | ✅ Implemented |
| `#[julia]` attribute support | ✅ Implemented |
| External crate bindings (`@rust_crate`) | ✅ Implemented |
| Hot reload support | ✅ Implemented |
| Julia General registry | ✅ Registered (`Pkg.add("RustCall")`) |
| Root Julia tests | ✅ Present (`test/runtests.jl`, `ParallelTestRunner.jl` over `test/test_*.jl`) |
| CI (Julia + Rust proc-macro checks) | ✅ Configured (`julia-actions/julia-runtest@v1` with per-platform `test_args`) |

## Codebase Snapshot

File and line counts are not maintained by hand in this page (a hand-kept table drifted; see [#261](https://github.com/AtelierArith/RustCall.jl/issues/261)). Measure the current tree instead:

```bash
git ls-files 'src/*.jl' 'test/test_*.jl' 'benchmark/*.jl' 'deps/*/src/*.rs' | xargs wc -l
```

## Architecture Map

### Julia entry points
- `src/RustCall.jl`: module entrypoint, exports, initialization.
- `src/ruststr.jl`: `rust"""` processing, compilation/load integration.
- `src/rustmacro.jl`: `@rust`, `@irust`, call expansion.

### Compilation and code generation
- `src/compiler.jl`: rustc invocation and compile orchestration.
- `src/codegen.jl`: `ccall` generation utilities.

### Type and runtime layer
- `src/types.jl`: Rust wrapper types (`RustResult`, `RustOption`, ownership types).
- `src/ffi_contract.jl`: the single source of truth for Rust/Julia type mapping — ABI form, `ccall` slots, surface type, ownership and release symbol (#276).
- `src/typetranslation.jl`: `rusttype_to_julia` (a shim over the contract) and the Julia-to-Rust direction.
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
- Coverage includes cache, ownership, arrays, generics, error handling, external crates, `#[julia]`, crate bindings, hot reload, and regressions.

### Rust proc-macro tests
- Location: `deps/rustcall_julia_macros/tests/`
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
- Ownership helpers such as `RustBox`, `RustRc`, `RustArc`, `RustVec`, and `RustSlice` depend on the helper library built during package installation.
- Generic structs and more advanced trait patterns still need explicit handling in some cases, especially for external bindings.
- Cargo-backed workflows are cached, but first builds can be slow and some crates may still need platform-specific build configuration.

## Delivered Milestones

- Phase 1: direct `rust"""..."""`, `@rust`, `@irust`, type mapping, string support, and cache-backed compilation.
- Phase 2: ownership/runtime helpers and generics support. (The experimental LLVM IR path of this phase was deprecated in 0.2.0 and removed in 0.3.0, [#265](https://github.com/AtelierArith/RustCall.jl/issues/265).)
- Phase 3: Cargo dependency parsing and external crate use inside inline Rust code.
- Phase 4: Rust struct and method mapping into Julia-facing objects.
- Phase 5: `#[julia]`-driven wrapper generation.
- Phase 6: external crate binding generation with `@rust_crate` and the `rustcall_julia_macros` proc-macro crate.
- Phase 7: manifest schema 4 and the FFI type contract — one table decides every Rust/Julia type mapping, unknown types fail closed instead of becoming `Any`, and an owned value always names the symbol that releases it (#276, #245, #246, #249).

## Near-Term Priorities

- Unify finalizers on the contract's ownership column and re-enable struct finalizers (#277, Phase B).
- Retire `RustCall.FFI_STRICT[] = :warn` after one minor release.
- Continue regression hardening for crate binding and hot reload workflows.
- Prepare distribution tasks for crates.io publication of proc-macro tooling.
