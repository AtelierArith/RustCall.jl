# Project Guide

This page collects repository-oriented information that no longer lives in the top-level README. Use it when you are working from a source checkout, browsing the codebase, or looking for runnable material in the repository.

## Repository Layout

- `src/`: main implementation. `src/RustCall.jl` is the package entry point.
- `test/`: package test suite. `test/runtests.jl` is the main entry point.
- `docs/`: Documenter sources and generated-site configuration.
- `deps/`: Rust helper/runtime code and the `juliacall_macros` proc-macro crate.
- `examples/`: runnable examples covering inline Rust, crate bindings, Pluto, and package-style usage.
- `benchmark/`: benchmark scripts for core calls, LLVM integration, arrays, generics, and ownership helpers.

## Bundled Examples

- `examples/MyExample.jl`: package-style example using inline `rust"""..."""` blocks.
- `examples/sample_crate`: external Rust crate using `#[julia]` and `@rust_crate`.
- `examples/sample_crate_pyo3`: dual Julia/Python bindings example.
- `examples/pluto/hello.jl`: Pluto-oriented walkthrough.

Run the bundled examples from the repository root:

```bash
julia --project examples/sample_crate/example.jl
julia --project examples/sample_crate_pyo3/main.jl
julia --project=examples/MyExample.jl -e 'using Pkg; Pkg.test()'
julia --project examples/pluto/hello.jl
```

## Test Suite

- Root entry point: `test/runtests.jl`
- Coverage includes cache behavior, ownership types, arrays, generics, LLVM integration, cargo dependencies, external crates, `#[julia]`, crate bindings, hot reload, and regressions.
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

The repository includes benchmark scripts comparing native Julia paths with `@rust` and, where applicable, `@rust_llvm`.

```bash
julia --project benchmark/benchmarks.jl
julia --project benchmark/benchmarks_llvm.jl
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
- Built on top of [LLVM.jl](https://github.com/maleadt/LLVM.jl).
- Development has been supported by AI coding tools and agents including Codex, Claude Code, and Cursor.

## Related Projects

- [Cxx.jl](https://github.com/JuliaInterop/Cxx.jl): C++ FFI for Julia.
- [CxxWrap.jl](https://github.com/JuliaInterop/CxxWrap.jl): C++ wrapper generation for Julia.
