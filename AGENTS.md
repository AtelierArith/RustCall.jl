Read also CLAUDE.md

# Repository Guidelines

## Project Structure & Module Organization
- `src/RustCall.jl` defines the `RustCall` module and public API.
- `Project.toml` holds package metadata for the root Julia project.
- `docs/design/` contains design notes and planning documents.
- `Cxx.jl/` is the Julia C++ FFI subproject with its own `src/`, `test/`, `docs/`, and `deps/`.
- `julia/` is a full Julia source tree; build scripts live in `julia/Makefile`, tests in `julia/test/` and `julia/stdlib/*/test/`.

## Build, Test, and Development Commands
- `julia --project -e 'using Pkg; Pkg.instantiate()'` sets up the root environment.
- `julia --project -e 'using RustCall; RustCall.greet()'` runs a quick smoke check.
- `julia --project=Cxx.jl -e 'using Pkg; Pkg.test()'` runs the Cxx.jl test suite.
- `make -C julia` builds the Julia tree (see `julia/README.md` for prerequisites).
- `make -C julia testall` runs the Julia test suite.

## Coding Style & Naming Conventions
- Julia code uses 4-space indentation and no tabs.
- Modules and types use `CamelCase`; functions and variables use lowercase with underscores (`do_thing`).
- Prefer small, composable functions in `src/` and avoid editing vendored code unless required.

## Testing Guidelines
- Use the `Test` stdlib; root tests are currently absent, so add `test/runtests.jl` when introducing behavior.
- Cxx.jl tests live in `Cxx.jl/test/` and are driven by `runtests.jl`.
- Julia core tests live in `julia/test/` and `julia/stdlib/*/test/`; run only the minimal subset you touched when possible.

## Commit & Pull Request Guidelines
- Commit messages are short, imperative, and sentence-style (e.g., "Add Cxx.jl as submodule").
- PRs should describe scope, list commands run, and call out any changes under `Cxx.jl/` or `julia/`.
- If you update vendored trees, explain the upstream source or commit you aligned with.

## Agent Notes
- If you work inside the Julia subtree, also follow the additional guidance in `julia/AGENTS.md`.
