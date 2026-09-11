# Project Guide

This page collects repository-oriented information that no longer lives in the top-level README. Use it when you are working from a source checkout, browsing the codebase, or looking for runnable material in the repository.

## Repository Layout

- `src/`: main implementation. `src/RustCall.jl` is the package entry point.
- `test/`: package test suite. `test/runtests.jl` is the main entry point.
- `docs/`: Documenter sources and generated-site configuration.
- `deps/`: Rust helper/runtime code and the `rustcall_julia_macros` proc-macro crate.
- `examples/`: runnable examples covering inline Rust, crate bindings, Pluto, and package-style usage.
- `benchmark/`: benchmark scripts for core calls, arrays, generics, and ownership helpers.

## Bundled Examples

- `examples/MyExample.jl`: package-style example using inline `rust"""..."""` blocks.
- `examples/SampleCrate.jl`: a Julia package with the Rust crate
  `deps/sample_crate` embedded in it, using `#[julia]` (Rust and Julia in
  separate files, bindings written by `deps/build.jl`, tested with `Pkg.test()`).
- `examples/SampleCratePyO3.jl`: a Julia package with the dual Julia/Python
  crate `deps/sample_crate_pyo3` embedded in it; `deps/sample_crate_pyo3/main.py`
  is its Python consumer.
- `examples/SampleCratePyO3Only.jl`: a Julia package with the **PyO3-only**
  crate `deps/sample_crate_pyo3_only` embedded in it — no RustCall attribute
  anywhere — bound through the wrapper crate RustCall generates
  (`write_bindings_to_file`, #275 Phase 2; see [PyO3 Crates](pyo3.md)). pyo3 is
  a mandatory dependency of that crate, so the wrapper links libpython and
  building the package needs a Python interpreter (`PYO3_PYTHON` pins one).
- `examples/pluto/hello.jl`: Pluto-oriented walkthrough. CI runs it headlessly with
  Pluto (`examples/pluto/run_notebook.jl`, the `Pluto - hello.jl` job of the
  `Examples` workflow) and fails when any cell errors.

Every `examples/*.jl` directory is a Julia package, and each is self-contained:
the crate it binds lives under its own `deps/<crate>/`, in the layout the
[Precompilation Support](precompilation.md) guide prescribes, and the only
reference it makes outside its directory is the `rustcall_julia_macros` path
dependency (the proc-macro crate is not on crates.io yet; the PyO3-only crate
has none, its generated wrapper being what depends on `rustcall_julia_macros`). Run
its tests against the RustCall of this checkout from the repository root:

```bash
julia --project=examples/MyExample.jl -e 'using Pkg; Pkg.develop(path="."); Pkg.test()'
julia --project=examples/SampleCrate.jl -e 'using Pkg; Pkg.develop(path="."); Pkg.test()'
julia --project=examples/SampleCratePyO3.jl -e 'using Pkg; Pkg.develop(path="."); Pkg.test()'
julia --project=examples/SampleCratePyO3Only.jl -e 'using Pkg; Pkg.develop(path="."); Pkg.test()'
```

The Pluto notebook activates the repository root itself, so instantiate and build
the root project before running it headlessly (Pluto comes from
`examples/pluto/Project.toml`):

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.build("RustCall")'
julia --project=examples/pluto -e 'using Pkg; Pkg.instantiate()'
julia --project=examples/pluto examples/pluto/run_notebook.jl
```

The `Examples` GitHub workflow runs the same `Pkg.test()` for each package on
every push.

## Native Build Products

`Pkg.build("RustCall")` compiles two crates: `deps/rust_helpers` (the ownership
helper cdylib behind `RustBox`/`RustRc`/`RustArc`/`RustVec`) and
`deps/rustcall_extract` (the `rustcall-extract` CLI). Since #258 there is one
place that decides where they go and where they are found again,
`src/native_layout.jl`, included by both `src/RustCall.jl` and `deps/build.jl`.

- **A checkout** — this repository, a `Pkg.develop`ed clone, a git worktree —
  builds into `deps/<crate>/target`, the same directory the documented
  developer commands write to. Nothing changes for local work.
- **An installed package** — a tree under a depot's `packages/` directory —
  builds into a scratch space,
  `<depot>/scratchspaces/<RustCall UUID>/native-v1/<slug>/<crate>`. The
  installed package directory is never written to, so a read-only package
  store (shared and HPC depots, baked container images, system images,
  `Distributed` workers on a read-only mount) works. `<slug>` is Pkg's own
  per-version directory name, so two installed RustCall versions in one depot
  cannot pick up each other's extractor. (Pkg still writes its own
  `deps/build.log` next to the build script when it can — that is Pkg's log of
  the build, not a product of it.)

Both crates commit their `Cargo.lock` and are built with `--locked`. Moving
`CARGO_TARGET_DIR` does not move the lockfile: Cargo writes it beside the
manifest, inside the package tree, and on a read-only tree that fails the build
before anything is compiled. `--locked` asserts the resolution instead of
writing it — and fails loudly, in CI, the moment a lockfile goes stale against
its `Cargo.toml`, which is the right moment to notice.

The build is incremental. Through v0.3.4 `deps/build.jl` ran `cargo clean`
first, so every build event — including the transitive ones Pkg triggers — paid
a full Rust compile; Cargo's own fingerprint, which already covers the sources,
the profile and the `rustc` identity, replaces it. Rebuilding both crates
unchanged went from ~31 s to ~0.1 s of Cargo time on an M-series laptop.

Lookup order for each product, most authoritative first: the environment
override (`RUSTCALL_EXTRACT`, `RUSTCALL_RUST_HELPERS`), this tree's own build
directory, the scratch space of every other depot on `DEPOT_PATH`, and finally
the pre-#258 in-package location, which a tree built by an older RustCall and
not rebuilt since still has. `test/test_native_layout.jl` pins all of it.

## Test Suite

- Root entry point: `test/runtests.jl`
- Fixture crates: `test/fixtures/sample_crate` (the `#[julia]` crate the crate-binding,
  hot-reload and static-method tests load, with test-only items such as `panicky_*`
  and `Divider`), `test/fixtures/sample_crate_pyo3` (dual bindings) and
  `test/fixtures/sample_crate_pyo3_only`, `_mixed`, `_optional` (crates carrying
  PyO3 attributes, used by the #275 scan and link-plan tests). They are test
  material, not examples; the examples under `examples/` embed their own crates.
- Coverage includes cache behavior, ownership types, arrays, generics, cargo dependencies, external crates, `#[julia]`, crate bindings, hot reload, and regressions.
- Documentation examples are checked by `test/test_docs_examples.jl`.
- The proc-macro crate has its own tests in `deps/rustcall_julia_macros/tests/`.
- The Rust toolchain is a **precondition, not a skip**, when `CI=true`:
  `test/test_toolchain.jl` asserts that rustc and cargo resolve and that
  `Pkg.build` produced the helpers library, so a provisioning failure fails the
  suite instead of letting sixty testsets step aside silently. Set
  `RUSTCALL_REQUIRE_TOOLCHAIN=true` to get the same behaviour locally.
- The **network-dependent tests are opt-in**. `test_external_crates.jl`,
  `test_ndarray.jl` and `test_phase4_ndarray.jl` build Cargo projects against
  serde_json, regex, uuid, chrono, libc and ndarray. Every registry-backed
  compilation in those three files sits behind a variable, so they reach
  crates.io only when asked to; the scheduled `Network integration` workflow
  sets all five:

  ```bash
  RUSTCALL_RUN_SERDE_TESTS=true \
  RUSTCALL_RUN_REGEX_TESTS=true \
  RUSTCALL_RUN_UUID_TESTS=true \
  RUSTCALL_RUN_CHRONO_TESTS=true \
  RUSTCALL_RUN_HEAVY_INTEGRATION_TESTS=true \
    julia --project -e 'using Pkg; Pkg.test()'
  ```

  Other files still build against the registry by design: `test_cargo.jl`
  exercises the `// cargo-deps:` path with `itoa`, and the PyO3 fixtures need
  pyo3.
- **The default run needs no crate from outside the declared closure.** Those
  two crates are listed in `test/fixtures/offline_prefetch/Cargo.toml`, and
  everything else the suite builds resolves through `path =` or through the
  dependency closure of `deps/rustcall_extract`, `deps/rust_helpers` and
  `deps/rustcall_julia_macros`. The `Offline tests` workflow fetches exactly
  those manifests into an empty `CARGO_HOME` and then runs the whole suite
  with `CARGO_NET_OFFLINE=true`, so a test that starts needing another
  registry crate fails until the crate is added to that manifest. The fixture
  crates carry a committed `Cargo.lock` so their resolution is pinned rather
  than being whatever crates.io offers today.

  What that job proves is that the declared closure is *sufficient*, not that
  Cargo makes no request at all: a test that builds a freshly generated Cargo
  project makes Cargo resolve a graph it has never seen, and resolving queries
  the index. Measured with a refusing proxy instead of offline mode, the
  testsets that still reach out are exactly those, and none of them wants an
  undeclared crate. To reproduce the job locally:

  ```bash
  export CARGO_HOME=$(mktemp -d)
  # A fresh first depot, so RustCall's artifact cache starts empty too: a
  # library an earlier run compiled would otherwise satisfy a Cargo-backed
  # test without Cargo being invoked at all.
  export JULIA_DEPOT_PATH="$(mktemp -d):$HOME/.julia"
  for m in deps/rustcall_extract deps/rust_helpers deps/rustcall_julia_macros; do
    cargo fetch --manifest-path "$m/Cargo.toml"
  done
  for lock in test/fixtures/*/Cargo.lock; do
    cargo fetch --locked --manifest-path "$(dirname "$lock")/Cargo.toml"
  done
  (cd deps/rustcall_extract && cargo build --release)
  julia --project -e 'using Pkg; Pkg.build("RustCall")'
  CARGO_NET_OFFLINE=true \
    RUSTCALL_EXTRACT=$PWD/deps/rustcall_extract/target/release/rustcall-extract \
    julia --project -e 'using Pkg; Pkg.test()'
  ```

Useful commands:

```bash
julia --project -e 'using Pkg; Pkg.test()'
julia --project test/test_cache.jl
cd deps/rustcall_julia_macros && cargo fmt --check
cd deps/rustcall_julia_macros && cargo clippy --all-targets --all-features -- -D warnings
cd deps/rustcall_julia_macros && cargo test --all-features
```

## Benchmarks

The repository includes benchmark scripts comparing native Julia paths with `@rust`.

```bash
julia --project=benchmark benchmark/benchmarks.jl
julia --project=benchmark benchmark/benchmarks_arrays.jl
julia --project=benchmark benchmark/benchmarks_generics.jl
julia --project=benchmark benchmark/benchmarks_ownership.jl
```

## Development Setup

For local development from a checkout:

```bash
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project -e 'using Pkg; Pkg.build("RustCall")'
julia --project -e 'using Pkg; Pkg.test()'
julia --project=docs docs/make.jl
```

The repository also includes a local `CLAUDE.md` file with implementation notes and conventions used by coding agents working in this tree.

This checkout does not currently include a `.devcontainer` configuration, so there is no repository-managed VS Code Dev Container workflow to document here.

## Contributing

Pull requests are the expected contribution path.

- Start from a local checkout and run the setup commands above.
- Run `julia --project -e 'using Pkg; Pkg.test()'` before sending changes.
- If you touch the proc-macro crate, also run the Cargo checks listed in the test section.
- Follow the repository conventions documented in `CLAUDE.md` when working on RustCall internals.

There is no dedicated `CONTRIBUTING.md` file in this checkout today, so this section is the current contributor-facing summary.

## License

This checkout does not currently include a top-level `LICENSE` file. If licensing terms need to be published or clarified, they should be added to the repository explicitly rather than inferred from older README text.

## Credits

- Inspired by [Cxx.jl](https://github.com/JuliaInterop/Cxx.jl).
- Built on [RustToolChain.jl](https://github.com/AtelierArith/RustToolChain.jl) for the Rust toolchain.
- Development has been supported by AI coding tools and agents including Codex, Claude Code, and Cursor.

## Related Projects

- [Cxx.jl](https://github.com/JuliaInterop/Cxx.jl): C++ FFI for Julia.
- [CxxWrap.jl](https://github.com/JuliaInterop/CxxWrap.jl): C++ wrapper generation for Julia.
