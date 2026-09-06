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
bash scripts/lint_generation_snapshot.sh src  # FFI entry points resolve via a snapshot, never piecemeal
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
5. `src/cache.jl` provides caching of compiled artifacts in a **Scratch.jl space** (#252): `get_cache_dir()` is `<depot>/scratchspaces/<RustCall UUID>/cache-v$(CACHE_FORMAT_VERSION)`, with `metadata/` and `cargo/` under it. RustCall writes **nothing** under `~/.julia/compiled/` — that is Julia's own precompile directory, read-only for RustCall and never created by it; `_legacy_cache_root()` is read only by the opt-in legacy sweep (`clear_cache(sweep_legacy = true)`), which removes RustCall's own `v<n>`/`cargo`/`metadata` directories and loose files matching the exact pre-#278 naming, and nothing else. The depot is the first *writable* entry of `DEPOT_PATH`, so a read-only `DEPOT_PATH[1]` still works; `RUSTCALL_CACHE_DIR` overrides the location outright.

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

**One generation snapshot per call.** A library can be replaced under a running program (hot reload), so every FFI entry point resolves everything it needs — function pointer, panic channel, owned-`String` release function, struct destructor, liveness `Ref`, **and the return ABI** — in **one** locked step, and then uses only that snapshot. Nothing after the snapshot may look anything up by library name: a second lookup can land on the other side of a swap, and the call then enters the retired image while the channel, the `free`, or the return type belongs to its replacement — a lost panic, a buffer released through the wrong allocator, or a scalar read as a struct.

There are exactly four snapshot constructors, and `scripts/lint_generation_snapshot.sh` fails CI if anything else resolves a piece on its own:

| constructor | where | what it returns |
| --- | --- | --- |
| `resolve_call_target` | `src/ruststr.jl` | `CallTarget`: pointer, panic channel, owned-`String` release fn, handle, return type / `FunctionInfo`, generation |
| `artifact_generation_snapshot` | `src/structs.jl` | `ArtifactGeneration`: a struct's destructor + the flag of the image that exports it |
| `generic_struct_generation_snapshot` | `src/structs.jl` | the same, for a monomorphized generic destructor |
| `_call_target` / `_struct_generation` | the two `@rust_crate` templates | the same two, from **one deref** of the module's `_LIB_GEN` |

Two consequences worth knowing:

- **A constructor's snapshot includes the object's destructor.** `resolve_call_target(lib, ctor; free_symbol = "<Struct>_free")` returns the allocating wrapper *and* the `free_ptr` / `alive` the resulting object captures, so an object can never be bound to a generation other than the one that allocated it. `_call_rust_constructor` returns `(ptr, target)` for exactly this; the crate templates use `_ctor_target`.
- **A retired image keeps its identity.** An image is retired, not closed, so it stays mapped with live objects holding its flag; loading the same path again gets the same handle back and adopts that same flag (one mapped image, one flag), and a retirement closes exactly the number of owned opens it was retired with — never the live counter, which a concurrent reopen may have raised.
- **A cached record is a snapshot too.** `FunctionInfo` (a monomorphized generic, `register_function`) carries the channel, the handle and the generation it was built with, because it is called long after the lookup that produced it.
- **A generated `@rust_crate` module keeps one immutable record, not several `Ref`s.** `_LIB_GEN::Ref{CrateGeneration}` holds handle + liveness flag + generation, replaced wholesale by `_update_handle_mirrors!` inside the `REGISTRY_LOCK` transaction; wrappers read it once per call and take no lock. Two cells written under one lock and read under another are not a snapshot. `__init__` registers the mirror **before** loading and never assigns it afterwards — an assignment after `load_artifact!` would overwrite a newer generation a concurrent reload had already published.

A replaced image is **retired, not closed**, so a call already inside one stays valid; a cached pointer finds its own image's flag through `alive_ref_for_handle`, never through the name. `test/test_hot_reload_transaction.jl` asserts all of this adversarially: a reload loop against tasks that call, panic, allocate and drop — plus one that reads the crate-module record — checking that no call returns an unpublished generation, that no generation number is ever paired with two different results, that no panic is lost and that no finalizer fails.

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

## Pull Request Workflow

Every change goes through this loop; the definition of done is the issue's acceptance criteria, not "the cause is gone".

1. **Open a draft PR** from a topic branch off `origin/main`. Commit in logical steps, each leaving `Pkg.test()` green. Commit messages and the PR body carry the attribution trailers the session was given.
2. **Request review**: comment `@codex review` once CI is green. Codex re-reviews automatically on every later push, so keep the branch quiet until a round is answered.
3. **Monitor per head SHA**: CI results (`gh pr checks`) and Codex reviews are tracked against the current head; a green result on an older SHA means nothing.
4. **Answer every finding**: fix real ones (with a regression test), reply on the thread with the fixing SHA, resolve the thread. Never resolve a thread you did not act on.
5. **Scope decision**: when findings converge on one class that a tech-debt issue solves structurally, fix the current round, post a "scope decision" comment naming that issue, stop re-requesting review, and merge on green. Record the deferred items on the issue.
6. **`Closes #N` only when every acceptance criterion of #N has a named test** (list criterion → test in the PR body). Otherwise write `Advances #N` and list what remains. A tech-debt fix removes the *class* of bug; the bug issue's concrete deliverables still need their own work.
7. **Merge**: squash, subject `<PR title> (#PR)`, after CI is green, no unresolved threads, and the scope decision (if any) is recorded. Then pull `main` and rebase any open PR that overlaps.

Practical rules that CI enforces or that have bitten before:

- Docstrings in `src/*.jl` must not use `(@ref)` links to internal bindings — the Documentation job fails. Plain backticks.
- `test/runtests.jl` auto-discovers `test_*.jl`; never add an `include`.
- Rebuild the extractor (`cd deps/rustcall_extract && cargo build --release`) and export `RUSTCALL_EXTRACT` before running Julia tests; a stale binary is rejected by the manifest schema check.
- Golden corpus: run the plain `cargo test` in `deps/rustcall_core` first — a golden failure is the signal that the extractor's output changed. Only when that change is intended, regenerate with `UPDATE_GOLDEN=1 cargo test` (it overwrites without comparing) and review `git diff tests/corpus` before committing.
- Run every `scripts/lint_*.sh src` locally; they are all CI jobs.
- On Windows a loaded DLL cannot be deleted or overwritten: tests unload libraries before removing temp trees and clean up best-effort; hot reload opens a fresh generation path per rebuild.
- Finalizers must never take `REGISTRY_LOCK`, `dlsym`, or log; they use pointers captured at construction. Enforced by `test/test_finalizers.jl` from #277 Phase B (PR #289) onward; older finalizers in `src/types.jl` / `src/crate_bindings.jl` are migrated there.
- `docs/src/api.md` is close to Documenter's size threshold (#288); a new docstring can break the docs job — check `julia --project=docs docs/make.jl` locally.
- Verify tests pass before every commit; never commit red.
