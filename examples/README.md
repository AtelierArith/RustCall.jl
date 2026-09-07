# RustCall.jl Examples

This directory contains example projects demonstrating how to use RustCall.jl for Julia-Rust interoperability.

## Prerequisites

Before running the examples, ensure you have:

1. **Julia 1.12+** installed
2. **Rust** (stable) with `cargo` installed
   ```bash
   # Check Rust installation
   rustc --version
   cargo --version
   ```
3. **RustCall.jl** installed with `Pkg.add("RustCall")` or developed locally from this checkout

## Available Examples

| Example | Description | Difficulty | Key Features |
|---------|-------------|------------|--------------|
| [MyExample.jl](./MyExample.jl/) | Julia package using `rust""` string literal | Beginner | Inline Rust code, basic FFI |
| [SampleCrate.jl](./SampleCrate.jl/) | Julia package with a Rust crate using `#[julia]` embedded under `deps/sample_crate/` | Intermediate | `#[julia]`, `@rust_crate`, `write_bindings_to_file`, Rust and Julia in separate files |
| [SampleCratePyO3.jl](./SampleCratePyO3.jl/) | Julia package with a dual Julia/Python crate embedded under `deps/sample_crate_pyo3/` | Advanced | PyO3 integration, feature flags |
| [pluto/hello.jl](./pluto/hello.jl) | Pluto notebook with a `// cargo-deps:` block | Beginner | Inline Rust in Pluto, run headlessly in CI |

Every `*.jl` directory is a Julia package: `Pkg.test()` runs its tests, and the
`Examples` GitHub workflow runs them for every push. Each package is
**self-contained**: the Rust crate it binds is a plain Cargo crate under its own
`deps/<crate>/` (the layout the [Precompilation Support](../docs/src/precompilation.md)
guide prescribes), and no Julia file contains Rust source. The only reference an
example makes outside its own directory is the `juliacall_macros` path
dependency in its `Cargo.toml`, because the proc-macro crate is not on crates.io
yet. (RustCall's own test suite uses separate fixture crates under
`test/fixtures/`, not the examples.)

```bash
# any of MyExample.jl, SampleCrate.jl, SampleCratePyO3.jl
cd examples/SampleCrate.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.test()'
```

(`Pkg.develop(path="../..")` uses the RustCall of this checkout; with a
registered RustCall, `Pkg.instantiate()` is enough.)

## Quick Start Guide

### For Julia Users (Start Here)

If you're a Julia user who wants to call Rust code, start with **MyExample.jl**:

```julia
using Pkg

# Navigate to the example
cd("examples/MyExample.jl")

# Activate and set up the environment
Pkg.activate(".")
Pkg.instantiate()

# Use the example
using MyExample
add_numbers(Int32(10), Int32(20))  # => 30
```

### For Rust Developers

If you're a Rust developer who wants to expose your code to Julia, start with
**SampleCrate.jl** and its embedded crate `deps/sample_crate`:

```julia
using RustCall

# Load the sample crate and keep the returned bindings value
sample_crate_path = joinpath(pkgdir(RustCall), "examples", "SampleCrate.jl", "deps", "sample_crate")
const SampleCrate = @rust_crate sample_crate_path

# Call Rust functions
SampleCrate.add(Int32(2), Int32(3))  # => 5
SampleCrate.fibonacci(UInt32(10))    # => 55
```

## Example Descriptions

### MyExample.jl

A Julia package that demonstrates using the `rust""` string literal to write Rust code directly in Julia.

**Features demonstrated:**
- Inline Rust code with `rust"..."` string literals
- Basic numerical operations (add, multiply, fibonacci)
- String processing (word count, reverse)
- Array operations (sum, max)

**How to run:**
```bash
cd examples/MyExample.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. test/runtests.jl
```

For normal use, `Pkg.instantiate()` resolves RustCall.jl from Julia's General registry. Use `Pkg.develop(path="../../")` only when testing local changes from this checkout.

### SampleCrate.jl

A Julia package with a Rust crate embedded under `deps/sample_crate/`, demonstrating the `#[julia]` attribute from `juliacall_macros` and the package workflow around it.

**Features demonstrated:**
- `#[julia]` attribute for automatic FFI generation
- `Result<T, E>` and `Option<T>` type handling, and idiomatic Julia wrappers over them
- Struct definitions with methods
- Property access syntax for struct fields
- The package workflow: `deps/build.jl` writes the bindings with `write_bindings_to_file`, `Pkg.test()` tests them; Rust in `deps/sample_crate/src/lib.rs`, Julia in `src/`

**How to build the crate alone:**
```bash
cd examples/SampleCrate.jl/deps/sample_crate
cargo build --release
```

**How to use from Julia, ad hoc (`@rust_crate`):**
```julia
using RustCall
const SampleCrate = @rust_crate "/path/to/examples/SampleCrate.jl/deps/sample_crate"

# Functions
SampleCrate.add(Int32(1), Int32(2))

# Structs with property access
p = SampleCrate.Point(3.0, 4.0)
p isa SampleCrate.Point  # => true
p.x  # => 3.0
p.y  # => 4.0
SampleCrate.distance_from_origin(p)  # => 5.0
```

**How to use from Julia, as a package:**
```bash
cd examples/SampleCrate.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.test()'
```
```julia
using SampleCrate
safe_divide(1.0, 0.0)   # throws DivideError — the Julia layer over Result<f64, i32>
```

### SampleCratePyO3.jl

A Julia package with a Rust crate embedded under `deps/sample_crate_pyo3/` that has **dual bindings** for both Julia and Python using feature flags (`test/runtests.jl` makes the same assertions as the crate's `main.py`).

**Features demonstrated:**
- Coexistence of `#[julia]` and PyO3 in a single crate
- Feature flags to separate Julia/Python builds
- Shared core logic between both languages
- Proper separation of concerns

**How to build for Julia:**
```bash
cd examples/SampleCratePyO3.jl/deps/sample_crate_pyo3
cargo build --release
```

**How to build for Python:**
```bash
cd examples/SampleCratePyO3.jl/deps/sample_crate_pyo3
pip install maturin
maturin build --features python
```

**How to use from Julia:**
```julia
using RustCall
const SampleCratePyo3 = @rust_crate "/path/to/examples/SampleCratePyO3.jl/deps/sample_crate_pyo3"

SampleCratePyo3.add(Int32(2), Int32(3))  # => 5
```
or as the package:
```bash
cd examples/SampleCratePyO3.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.test()'
```

**How to use from Python:**
```python
import sample_crate_pyo3 as m
m.add(2, 3)  # => 5
```

### pluto/hello.jl

A [Pluto](https://plutojl.org/) notebook that compiles a `rust"""..."""` block with a
`// cargo-deps:` dependency (`ndarray`) and calls it. Its first cell activates the
repository root, so it uses the RustCall of this checkout.

Pluto is not a dependency of RustCall; it lives in the driver environment
`examples/pluto/Project.toml`. Both recipes below run from the repository root and
start by instantiating the root checkout (the notebook's environment) and that driver
environment.

**How to run interactively:**
```bash
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.build("RustCall")'
julia --project=examples/pluto -e 'using Pkg; Pkg.instantiate()'
julia --project=examples/pluto -e 'using Pluto; Pluto.run(notebook = "examples/pluto/hello.jl")'
```

**How it is tested:** the `Pluto - hello.jl` job of `.github/workflows/Examples.yml`
runs the notebook headlessly with `examples/pluto/run_notebook.jl` and fails when any
cell errors. The same check locally:
```bash
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.build("RustCall")'
julia --project=examples/pluto -e 'using Pkg; Pkg.instantiate()'
julia --project=examples/pluto examples/pluto/run_notebook.jl
```

## Learning Progression

We recommend learning RustCall.jl in this order:

1. **Start with MyExample.jl**
   - Learn how to write inline Rust code
   - Understand basic type mappings (Int32 ↔ i32, Float64 ↔ f64)
   - Practice calling Rust functions from Julia

2. **Move to SampleCrate.jl**
   - Learn about the `#[julia]` attribute
   - Understand `@rust_crate` for external crates
   - Explore struct handling and property access
   - Learn about `Result<T, E>` and `Option<T>` support
   - See how a package keeps Rust and Julia in separate files and tests them with `Pkg.test()`

3. **Explore SampleCratePyO3.jl** (optional)
   - Learn how to create dual Julia/Python bindings
   - Understand feature flags for conditional compilation
   - See how to share core logic between languages

4. **Read the documentation**
   - [Tutorial](../docs/src/tutorial.md)
   - [Crate Bindings (Phase 6)](../docs/src/crate_bindings.md)
   - [Troubleshooting](../docs/src/troubleshooting.md)

## Troubleshooting

### Rust not found

If you see "rustc not found in PATH", install Rust from [rustup.rs](https://rustup.rs/).

### Library build fails

Try clearing the cache and rebuilding:
```julia
using RustCall
clear_cache()
```

### Module name confusion

When using `@rust_crate`, the returned bindings object wraps a generated runtime module whose default name is the crate name converted to PascalCase.

Example: `sample_crate` → `SampleCrate`

You can override that internal runtime module name with `name=`, while still using the value returned by `@rust_crate`:
```julia
const bindings = @rust_crate "/path/to/crate" name="MyCustomName"
```

## Additional Resources

- [RustCall.jl Documentation](https://atelierarith.github.io/RustCall.jl/)
- [Rust FFI Guide](https://doc.rust-lang.org/nomicon/ffi.html)
- [Julia ccall Documentation](https://docs.julialang.org/en/v1/manual/calling-c-and-fortran-code/)
