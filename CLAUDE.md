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

# Rust crates (deps/rustcall_core, deps/rustcall_extract, deps/juliacall_macros)
cd deps/rustcall_core && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
UPDATE_GOLDEN=1 cargo test          # in deps/rustcall_core: regenerate tests/corpus/*.toml and *.expanded.rs
cd deps/rustcall_extract && cargo build --release   # the CLI Julia calls; also built by Pkg.build
cd deps/juliacall_macros && cargo test --all-features

# Lints run in CI
bash scripts/lint_interpolation.sh src
bash scripts/lint_rust_syntax_regex.sh src   # Julia must not parse Rust syntax with regexes
bash scripts/lint_artifact_identity.sh src  # artifact identity only via src/artifact_id.jl
bash scripts/lint_load_path.sh src          # dlopen/dlclose/RUST_LIBRARIES only via src/loadpolicy.jl
```

## Architecture

### Rust syntax is parsed only on the Rust side (issue #264)

- `deps/rustcall_core` — `syn`-based core: FFI manifest model (`manifest.rs`), extraction (`extract.rs`), inline expansion of `#[julia]` items (`expand.rs`), wrapper codegen for both the proc-macro and inline flavours (`codegen.rs`), AST-level generic instantiation (`specialize.rs`). Golden tests in `tests/corpus/`.
- `deps/rustcall_extract` — the `rustcall-extract` CLI (`manifest`, `expand`, `specialize` subcommands; `--cfg-file` takes `rustc --print cfg` so `#[cfg]`-disabled items are dropped). Built by `Pkg.build("RustCall")`; located by `RustCall.extractor_path()` (override with `RUSTCALL_EXTRACT`).
- `deps/juliacall_macros` — thin proc-macro wrapper over `rustcall_core::codegen` for `@rust_crate` crates.
- `src/manifest.jl` — runs the CLI, validates `schema_version`, converts the TOML manifest into `RustFunctionSignature` / `RustStructInfo` / `RustMethod`, and computes `toolchain_fingerprint()` (extractor digest + core sources + `artifact_compiler_identity()`) that is part of every cache key.
- Do not add regexes over Rust source in `src/`; `scripts/lint_rust_syntax_regex.sh` fails CI. Allowlisted: `$var` interpolation in `@irust` (`ruststr.jl`), the `// cargo-deps:` DSL (`dependencies.jl`), and the brace-count hint in `exceptions.jl` (diagnostics only).

### Compilation pipeline

1. `rust"""..."""` (`src/ruststr.jl`) calls `expand_inline` (extractor) at macro-expansion time, emits Julia definitions from the manifest, and compiles the expanded source at run time (direct `rustc`, or a temporary Cargo project when `// cargo-deps:` is present)
2. `src/compiler.jl` invokes `rustc` to produce shared libraries or LLVM IR
3. `src/codegen.jl` generates `ccall` expressions; `src/llvmcodegen.jl` / `src/llvmintegration.jl` handle the LLVM IR path (deprecated, see #265)
4. `src/rustmacro.jl` expands `@rust` and `@irust` into the appropriate call mechanism
5. `src/cache.jl` provides caching of compiled artifacts, namespaced by `CACHE_FORMAT_VERSION` (`~/.julia/compiled/vX.Y/RustCall/v2`). That root is shared with **Julia's own precompile output** for RustCall (`<slug>.ji`, `<slug>.dylib`), so the cache sweep only ever removes RustCall's own version subdirectories, and legacy loose files only on explicit request and only by exact name match.

### Artifact identity is computed in exactly one place (issue #278)

- `src/artifact_id.jl` — `ArtifactId` (the exhaustive record) and `artifact_key` (its SHA-256 over a netstring-framed, injective encoding). Every cache key, library name and temporary project name in the package derives from it: `generate_cache_key` / `_rustc_block_identity` (direct rustc), `_cargo_block_id` / `_cargo_block_identity` / `build_cargo_project_cached` (Cargo), `_monomorphization_id` (generics), `compute_crate_hash` (`@rust_crate`), `@irust`.
- `artifact_short_id` is the **only** truncation, and only for names a human reads. Lookup keys are the full 64-hex digest.
- `artifact_compiler_identity()` names the `rustc`/`cargo` `RustToolChain` resolves — never a bare `rustc` on `PATH` — and raises when it cannot (#252). `toolchain_fingerprint()` stays total and folds it in.
- Path dependencies are hashed by content, re-read in full on every call (a `(mtime, size)` stamp can alias distinct contents). Only the resolved dependency graph is memoized — validated against the content digests of every manifest that decides it, including each crate's workspace root, found through an explicit `[package] workspace = "..."` before the ancestor search — and a block with no `path =` dependency never spawns `cargo tree`.
- Do not concatenate key material, truncate a digest, or name an artifact with Julia's randomized `hash()` outside `src/artifact_id.jl`; `scripts/lint_artifact_identity.sh` fails CI.

### Type system and runtime

- `src/types.jl` — Rust/Julia wrapper types: `RustPtr`, `RustRef`, `RustResult`, `RustOption`, ownership types (`RustBox`, `RustRc`, `RustArc`, `RustVec`, `RustSlice`)
- `src/typetranslation.jl` — bidirectional Rust ↔ Julia type mapping
- `src/memory.jl` — ownership operations backed by the Rust helpers library (`deps/rust_helpers/`)
- `src/exceptions.jl` — `RustError`, `CompilationError`, `RuntimeError`

### External crate integration

- `src/dependencies.jl` + `src/dependency_resolution.jl` — parse `// cargo-deps:` and `` //! ```cargo ``` `` formats
- `src/cargoproject.jl` + `src/cargobuild.jl` — generate and build Cargo projects
- `src/julia_functions.jl` — `RustFunctionSignature` and Julia wrappers for `#[julia]` functions (Result/Option aware)
- `src/crate_bindings.jl` — crate scanning via the extractor (crate mode), Julia wrapper generation, `@rust_crate` macro

### Loading, unloading and registration happen in exactly one place (issue #277)

- `src/loadpolicy.jl` — `LoadPolicy` (the four decisions a front door used to make for itself: `dlopen` flags, panic strategy, registration, finalizer policy) and the one load path: `load_artifact!` / `adopt_artifact!` / `register_artifact_metadata!` / `unload_artifact!` / `alias_artifact!`. Every door names its own policy (`inline_rustc_policy()`, `inline_cargo_policy()`, `irust_policy()`, `generics_policy()`, `hot_reload_policy()`, `crate_direct_policy()`, `crate_wrapper_policy()`, `helper_library_policy()`), so changing a policy is one edit.
- Every policy is `RTLD_LOCAL | RTLD_NOW`: nothing RustCall loads needs process-global symbols, because every call goes through `dlsym` on a specific handle. `RUSTCALL_DLOPEN_GLOBAL=1` is a deprecated escape hatch.
- Every policy RustCall builds is pinned to `panic = "unwind"` — on the `rustc` command line, in the generated `Cargo.toml`, and in `CARGO_PROFILE_<PROFILE>_PANIC` — because the generated `catch_unwind` boundary can only catch a panic that unwinds. See `docs/src/panics.md` for the semantics matrix.
- Do not call `Libdl.dlopen`/`dlclose` or write `RUST_LIBRARIES[...]` in `src/`; `scripts/lint_load_path.sh` fails CI (`src/llvmcodegen.jl` is the one allowlist, pending #265 Phase 2).

### Other modules

- `src/generics.jl` — generic function registry and monomorphization through `rustcall-extract specialize`
- `src/structs.jl` — `RustStructInfo` / `RustMethod` and Julia type generation for `#[julia]` structs
- `src/hot_reload.jl` — file watching and reload for crate workflows

### Include order

`src/RustCall.jl` defines the include order, which reflects module dependencies. New modules must be added respecting this order.

## Thread Safety

Global state is protected by `REGISTRY_LOCK` (ReentrantLock) in `src/RustCall.jl`. This guards `RUST_LIBRARIES`, `RUST_MODULE_REGISTRY`, `GENERIC_FUNCTION_REGISTRY`, the per-library metadata tables in `src/codegen.jl` and `ARTIFACT_ALIVE`. A separate `LLVM_REGISTRY_LOCK` protects LLVM operations.

**Finalizers must never take `REGISTRY_LOCK`, do a registry lookup, resolve a symbol, or log.** A finalizer runs at an arbitrary point on an arbitrary thread, possibly while that thread already holds the lock — taking it deadlocks, a `dlsym` plus method compilation inside a finalizer is a crash, and `@warn` allocates and can yield. Everything a finalizer needs is captured at construction: the destructor pointer and the library's liveness `Ref{Bool}` (`RustCall.artifact_alive_ref`). The shared body is `finalize_rust_object!` in `src/structs.jl`; a destructor that raises is counted (`finalizer_failure_count()`), not logged. `test/test_finalizers.jl` asserts this at the source level, so a new finalizer that breaks the rule fails CI.

**The panic channel is thread-local.** A generated wrapper records a panic in a `thread_local!` slot of its own library and returns a sentinel; Julia reads that slot with a second `ccall` immediately after the first. A Julia task may migrate to another OS thread at any yield point, so nothing that can yield — a lock, logging, I/O — may sit between the two `ccall`s; the channel pointer is resolved *before* the call (cached at load time). `test/test_panics.jl` stresses this with hundreds of tasks on the 4-thread CI job.

`load_artifact!` (`src/loadpolicy.jl`) is the one place a library is opened and registered. `dlopen` runs **outside** the lock — it executes arbitrary init code and is slow — and everything else (handle, function-pointer cache, symbol mappings, return-type hints, `CURRENT_LIB`, liveness flag) is installed in one locked block, so no task can observe a half-registered library. Two tasks racing on the same path both open it; the registration mode decides the winner and the loser's duplicate handle is closed.

## Testing

- Entry point: `test/runtests.jl` (includes 30+ test files)
- Tests are organized by feature: ownership, arrays, generics, cargo, crate bindings, hot reload, etc.
- `test/test_regressions.jl` holds regression tests for fixed issues
- Proc-macro tests: `deps/juliacall_macros/tests/`
- Many tests require `rustc` and skip gracefully if unavailable

## CI

`.github/workflows/CI.yml`:
- **Rust tests**: `cargo fmt --check`, `cargo clippy`, `cargo test` in `deps/rustcall_core`, `deps/rustcall_extract`, `deps/juliacall_macros` (stable + beta, Linux/macOS/Windows)
- **Julia tests**: `Pkg.test()` on Julia 1.x (Ubuntu x64, Windows x64, macOS aarch64) with `JULIA_NUM_THREADS=1`, plus **one Ubuntu job with `JULIA_NUM_THREADS=4`**
- **Code Lint**: every `scripts/lint_*.sh`

**Why the 4-thread job exists.** Three guarantees are only *exercised* with more than one thread, and their testsets skip themselves when `Threads.nthreads() < 2`, so without this job they would never run anywhere: (1) the panic channel is a thread-local — the rule that the wrapper `ccall` and the channel-read `ccall` happen on one thread with no yield point between them (#244) is invisible single-threaded; (2) `load_artifact!` racing two tasks on the same path (#277); (3) finalizers running on a thread other than the allocating one (#249). Keep the skip guards and this job together: a new thread-sensitive test must skip below 2 threads *and* be covered by the 4-thread job.

**Job names are load-bearing.** The repository ruleset for `main` lists `Julia 1 - ubuntu-latest - x64`, `Julia 1 - windows-latest - x64` and `Julia 1 - macos-latest - aarch64` as required status checks. The single-threaded jobs must keep exactly those names (the matrix `suffix` is empty for them); renaming them leaves the required checks unreported and blocks every merge. Add new variants with a suffix (` - 4 threads`) instead of renaming.

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
- **Minimal exports**: Only macros (`@rust`, `@rust_str`, `@irust`, `@irust_str`, `@rust_llvm`, `@rust_crate`) are exported. All other identifiers should be accessed via `RustCall.XXX` or `using RustCall: XXX`. Do not add new `export` statements unless the identifier is a macro intended for end-user use.

## Git Workflow

- Do not commit directly to `main` or `master`
- Create a topic branch for any implementation or documentation change
- Push the topic branch and open a draft PR for review-oriented sharing
- If work is accidentally committed on `main`, move it onto a topic branch and reset local `main` back to `origin/main`
