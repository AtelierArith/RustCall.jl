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
| [SampleCratePyO3Only.jl](./SampleCratePyO3Only.jl/) | Julia package with a **PyO3-only** crate (no RustCall attribute) embedded under `deps/sample_crate_pyo3_only/`, bound through RustCall's generated wrapper crate | Advanced | `#[pyfunction]` / `#[pyclass]` without `#[julia]`, `PyResult` → `RustResult`, `:link_libpython` (needs a Python interpreter to build) |
| [RustCrateMacroPyO3Only.jl](./RustCrateMacroPyO3Only.jl/) | The same **PyO3-only** shape, embedded under `deps/macro_pyo3_only/`, bound with the **`@rust_crate` macro** at the package's top level instead of a `deps/build.jl` | Advanced | `@rust_crate ... submodule="Bindings"` in a package, bindings generated while the package is precompiled, nothing generated in the repository, `:link_libpython` |
| [pluto/hello.jl](./pluto/hello.jl) | Pluto notebook with a `// cargo-deps:` block | Beginner | Inline Rust in Pluto, run headlessly in CI |

Every `*.jl` directory is a Julia package: `Pkg.test()` runs its tests, and the
`Examples` GitHub workflow runs them for every push. Each package is
**self-contained**: the Rust crate it binds is a plain Cargo crate under its own
`deps/<crate>/` (the layout the [Precompilation Support](../docs/src/precompilation.md)
guide prescribes), and no Julia file contains Rust source. The only reference an
example makes outside its own directory is the `juliacall_macros` path
dependency in its `Cargo.toml`, because the proc-macro crate is not on crates.io
yet — and the two PyO3-only packages, `SampleCratePyO3Only.jl` and
`RustCrateMacroPyO3Only.jl`, make none at all: their crates depend on pyo3
alone, and the wrapper crate RustCall generates for each is what depends on
`juliacall_macros`. (RustCall's own test suite uses separate fixture crates
under `test/fixtures/`, not the examples.)

```bash
# any of MyExample.jl, SampleCrate.jl, SampleCratePyO3.jl, SampleCratePyO3Only.jl,
# RustCrateMacroPyO3Only.jl
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

### SampleCratePyO3Only.jl

A Julia package with a Rust crate embedded under `deps/sample_crate_pyo3_only/`
that was **written for PyO3 only**: no `#[julia]`, no `juliacall_macros`
dependency, just `#[pyfunction]`, `#[pyclass]`, `#[pymethods]` and a
`#[pymodule]`. RustCall binds it without changing it ([#275](https://github.com/AtelierArith/RustCall.jl/issues/275)
Phase 2): `write_bindings_to_file` scans the `pub` items PyO3 exposes,
generates a wrapper crate that depends on the crate, builds it and writes the
bindings of that wrapper. This is the shape you have when the crate is not
yours to annotate.

**Features demonstrated:**
- Binding a PyO3 crate with no RustCall attribute anywhere, through the generated wrapper crate
- `PyResult<T>` → `RustResult{T, String}` with the opaque error `RustCall.PYO3_OPAQUE_ERROR`, and a Julia layer (`parse_int`) that turns it into a value or an `ArgumentError`
- `#[new]` as the constructor, `#[staticmethod]` as a module-level function (`origin()` / `origin(Point)`), `#[pyclass(get_all, set_all)]` fields as properties, `&self` / `&mut self` / `String` / `PyResult` methods
- The link plan: pyo3 is a mandatory dependency, so the wrapper links libpython (`:link_libpython`)

**The Python requirement:** building this package needs a Python interpreter
whose library directory RustCall can find (`PYO3_PYTHON=/path/to/python3` pins
one; `RUSTCALL_PYTHON_LIBDIR` overrides the directory; on Windows the
interpreter's `python3xy.dll` is preloaded by full path). No Python code runs:
the wrapper only links the library pyo3 refers to. The `Examples` workflow
installs one with `actions/setup-python` before Julia runs.

**How to use from Julia:**
```bash
cd examples/SampleCratePyO3Only.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.test()'
```
```julia
using SampleCratePyO3Only
add(Int32(2), Int32(3))                      # 5
p = Point(3.0, 4.0); norm(p)                 # 5.0
parse_int("42")                              # 42; parse_int("x") throws ArgumentError
SampleCratePyO3Only.Bindings.parse("x").value == RustCall.PYO3_OPAQUE_ERROR   # true
```

`RustCall.scan_report("examples/SampleCratePyO3Only.jl/deps/sample_crate_pyo3_only")`
prints what the wrapper exports and what it skips (only the `#[pymodule]`
initializer), and the link plan.

### RustCrateMacroPyO3Only.jl

The same PyO3-only crate shape as above — `deps/macro_pyo3_only/` carries no
RustCall attribute and no `juliacall_macros` dependency — bound through the
**other front door**: `@rust_crate ... submodule="Bindings"` at the package's
top level, which
[#339](https://github.com/AtelierArith/RustCall.jl/issues/339) made
precompilable. Read it next to `SampleCratePyO3Only.jl`: the two crates are
interchangeable, and the whole difference is in `src/`.

**Features demonstrated:**
- `@rust_crate` in a package's `src/`, with `submodule="Bindings"` defining the generated module as `RustCrateMacroPyO3Only.Bindings` so `using .Bindings: ...` works (`name=` only renames the otherwise hidden module and defines nothing)
- No `deps/build.jl` and no `src/generated/`: the crate is built and the bindings module generated while the package is *precompiled*, straight into its precompile image
- The library is a `Base.include_dependency` of the package, so `RustCall.clear_cache()` or an edit to the crate makes the cache stale and the next `using` rebuilds
- The generated module reaches `Libdl` through RustCall, so the package needs `RustCall` alone among its dependencies
- The same `PyResult` → `RustResult` lowering with `RustCall.PYO3_OPAQUE_ERROR`, and a Julia layer (`safe_div`) that turns it into a `DivideError`

**The Python requirement** is the same as `SampleCratePyO3Only.jl`'s: pyo3 is a
mandatory dependency of the crate, so the wrapper links libpython
(`:link_libpython`) and *precompiling* the package needs an interpreter whose
library directory RustCall can find.

**How to use from Julia:**
```bash
cd examples/RustCrateMacroPyO3Only.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.test()'
```
```julia
using RustCrateMacroPyO3Only
scale(Int32(3), Int32(4))       # 12
c = Counter(Int64(10), Int64(2)); bump(c)   # 12
safe_div(7, 2)                  # 3; safe_div(1, 0) throws DivideError
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

4. **Explore SampleCratePyO3Only.jl** (optional)
   - Bind a PyO3 crate you cannot annotate: RustCall's generated wrapper crate
   - See what `PyResult<T>` becomes, and why its error is opaque
   - Understand the link plan and the Python requirement of `:link_libpython`

5. **Compare RustCrateMacroPyO3Only.jl** (optional)
   - The same crate shape bound with `@rust_crate ... submodule="Bindings"` in
     a package's `src/`, instead of `write_bindings_to_file` in a `deps/build.jl`
   - See what a package that generates nothing looks like, and when to prefer
     each of the two front doors

6. **Read the documentation**
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

When using `@rust_crate`, the returned bindings object wraps a generated module whose default name is the crate name converted to PascalCase.

Example: `sample_crate` → `SampleCrate`

By default that module is hidden inside the calling module and is reached only through the returned value; `name=` chooses its name, and `submodule=` is what defines it in the calling module so a package can `using` from it (#339):
```julia
const bindings = @rust_crate "/path/to/crate" name="MyCustomName"        # nothing new is defined here
@rust_crate "/path/to/crate" submodule="MyCustomName"                   # defines MyCustomName here
using .MyCustomName: add
```

## Additional Resources

- [RustCall.jl Documentation](https://atelierarith.github.io/RustCall.jl/)
- [Rust FFI Guide](https://doc.rust-lang.org/nomicon/ffi.html)
- [Julia ccall Documentation](https://docs.julialang.org/en/v1/manual/calling-c-and-fortran-code/)
