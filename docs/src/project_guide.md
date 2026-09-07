# Project Guide

This page collects repository-oriented information that no longer lives in the top-level README. Use it when you are working from a source checkout, browsing the codebase, or looking for runnable material in the repository.

## Repository Layout

- `src/`: main implementation. `src/RustCall.jl` is the package entry point.
- `test/`: package test suite. `test/runtests.jl` is the main entry point.
- `docs/`: Documenter sources and generated-site configuration.
- `deps/`: Rust helper/runtime code and the `juliacall_macros` proc-macro crate.
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
reference it makes outside its directory is the `juliacall_macros` path
dependency (the proc-macro crate is not on crates.io yet; the PyO3-only crate
has none, its generated wrapper being what depends on `juliacall_macros`). Run
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
- The proc-macro crate has its own tests in `deps/juliacall_macros/tests/`.

Useful commands:

```bash
julia --project -e 'using Pkg; Pkg.test()'
julia --project test/test_cache.jl
cd deps/juliacall_macros && cargo fmt --check
cd deps/juliacall_macros && cargo clippy --all-targets --all-features -- -D warnings
cd deps/juliacall_macros && cargo test --all-features
```

## Benchmarks

The repository includes benchmark scripts comparing native Julia paths with `@rust`.

```bash
julia --project benchmark/benchmarks.jl
julia --project benchmark/benchmarks_arrays.jl
julia --project benchmark/benchmarks_generics.jl
julia --project benchmark/benchmarks_ownership.jl
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
