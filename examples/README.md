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
| [SampleCrate.jl](./SampleCrate.jl/) | Julia package with a Rust crate using `#[julia]` embedded under `deps/sample_crate/`, plus a `rust"""` block in `src/inline.jl` | Intermediate | `#[julia]`, `@rust_crate`, `write_bindings_to_file`, coexistence of the crate bindings with `@rust_str`, Rust and Julia in separate files |
| [RustCrateMacro.jl](./RustCrateMacro.jl/) | Julia package that binds a `#[julia]` crate with the `@rust_crate` macro at its top level and adds a `rust"""` block in the same module | Intermediate | `@rust_crate ... submodule=`, `#[julia]`, inline `rust"""`, all three front doors coexisting and composing |
| [SampleCratePyO3.jl](./SampleCratePyO3.jl/) | Julia package with a dual Julia/Python crate embedded under `deps/sample_crate_pyo3/` | Advanced | PyO3 integration, feature flags |
| [SampleCratePyO3Only.jl](./SampleCratePyO3Only.jl/) | Julia package with a **PyO3-only** crate (no RustCall attribute, no `pub`) embedded under `deps/sample_crate_pyo3_only/`, bound through RustCall's Python-host path | Advanced | `#[pyfunction]` / `#[pyclass]` without `#[julia]`, the crate built as the Python extension it is and imported through PythonCall, `PyResult` → `RustResult` with the real message |
| [RustCrateMacroPyO3Only.jl](./RustCrateMacroPyO3Only.jl/) | The same **PyO3-only** shape, embedded under `deps/macro_pyo3_only/`, bound with the **`@rust_crate` macro** at the package's top level | Advanced | `@rust_crate ... submodule="Bindings" pyo3_host=true` in a package, bindings generated while the package is precompiled, the crate built and imported lazily on first call, nothing generated in the repository |
| [Pyo3HostImport.jl](./Pyo3HostImport.jl/) | Two **PyO3-only** crates under `deps/macro_crate/` and `deps/direct_crate/`, bound through the host path with the **`@rust_crate` macro** and with **`RustCall.pyo3_host_import`** respectively | Advanced | The two host-path front doors side by side; the direct import plus an explicit inner constructor work around a one-argument `#[new]` the macro cannot bind ([#433](https://github.com/AtelierArith/RustCall.jl/issues/433)) |
| [SafeLedger.jl](./SafeLedger.jl/) | The safe integration pattern of the [integration guide](../docs/src/integration_guide.md): a facade crate under `deps/safe_ledger/` exposes one opaque, Rust-owned `#[julia]` struct, bound with `@rust_crate`, behind a small Julia API | Intermediate | Opaque handle, `Result` → Julia exception, explicit `close` and do-block release, unload behaviour |
| [pluto/hello.jl](./pluto/hello.jl) | Pluto notebook with a `// cargo-deps:` block | Beginner | Inline Rust in Pluto, run headlessly in CI |

Every `*.jl` directory is a Julia package: `Pkg.test()` runs its tests, and the
`Examples` GitHub workflow runs them for every push. Each package is
**self-contained**: the Rust crate it binds is a plain Cargo crate under its own
`deps/<crate>/` (the layout the [Precompilation Support](../docs/src/precompilation.md)
guide prescribes). Most keep Rust and Julia in separate files; the inline
`rust"""` (the `@rust_str` macro) is the subject of `MyExample.jl`, and
`SampleCrate.jl` and `RustCrateMacro.jl` use it deliberately beside a crate to
show the two front doors coexisting. The only reference an example makes outside
its own directory is the `rustcall_julia_macros` path dependency in its
`Cargo.toml`. The crate is published on crates.io; the examples take it by path
from this checkout so that they test the `#[julia]` attribute of the same tree
as the RustCall they run against, and a crate of your own can depend on the
release (`rustcall_julia_macros = "0.1"`). The PyO3-only packages,
`SampleCratePyO3Only.jl`, `RustCrateMacroPyO3Only.jl` and `Pyo3HostImport.jl`,
make none at all: their crates depend on pyo3 alone, and RustCall generates no
wrapper crate for them — it builds each crate as the Python extension it is and
imports it through PythonCall
([#424](https://github.com/AtelierArith/RustCall.jl/issues/424)).
(RustCall's own test suite uses separate fixture crates under `test/fixtures/`,
not the examples.)

```bash
# any of MyExample.jl, SampleCrate.jl, RustCrateMacro.jl, SampleCratePyO3.jl,
# SampleCratePyO3Only.jl, RustCrateMacroPyO3Only.jl, Pyo3HostImport.jl,
# SafeLedger.jl
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

A Julia package with a Rust crate embedded under `deps/sample_crate/`, demonstrating the `#[julia]` attribute from `rustcall_julia_macros` and the package workflow around it.

**Features demonstrated:**
- `#[julia]` attribute for automatic FFI generation
- `Result<T, E>` and `Option<T>` type handling, and idiomatic Julia wrappers over them
- Struct definitions with methods
- Property access syntax for struct fields
- The package workflow: `deps/build.jl` writes the bindings with `write_bindings_to_file`, `Pkg.test()` tests them; Rust in `deps/sample_crate/src/lib.rs`, Julia in `src/`
- Coexistence with the `rust"""` (`@rust_str`) macro: `src/inline.jl` carries an inline block next to the crate bindings, and `test/runtests.jl` checks that a name shared by both libraries resolves per library

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
inline_hypot(3.0, 4.0)  # 5.0 — from the package's own rust""" block
```

The package carries both the crate bound by `deps/build.jl` and an inline
`rust"""` block in `src/inline.jl`; the two libraries coexist, and
`inline_distance(Point(0.0, 0.0), Point(3.0, 4.0))` composes them. See the
"Coexistence with `rust\"\"\"`" section of the
[package README](./SampleCrate.jl/README.md).

### RustCrateMacro.jl

A Julia package that binds a `#[julia]` crate with the **`@rust_crate` macro**
at its top level (`@rust_crate ... submodule="Bindings"`) and carries an inline
`rust"""` block in the same module. It is the `#[julia]` counterpart of
`RustCrateMacroPyO3Only.jl` (whose crate is PyO3-only) and the macro counterpart
of `SampleCrate.jl` (which binds its crate with `write_bindings_to_file`).

**Features demonstrated:**
- `@rust_crate ... submodule="Bindings"` in a package's `src/`, with the
  bindings generated while the package is precompiled and nothing written into
  the repository
- A crate that carries `#[julia]` from `rustcall_julia_macros`, bound by the
  macro instead of a `deps/build.jl`
- All three front doors — `#[julia]`, `@rust_crate`, and inline `rust"""` —
  coexisting in one package, with `inline_norm(Point(...))` composing the crate
  bindings and the inline library
- A shared name across two libraries resolving per module (#250)

**How to use from Julia:**
```bash
cd examples/RustCrateMacro.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.test()'
```
```julia
using RustCrateMacro
add(Int32(2), Int32(3))          # 5      — from the crate, through @rust_crate
inline_hypot(3.0, 4.0)           # 5.0    — from the inline rust""" block
inline_norm(Point(3.0, 4.0))     # 5.0    — the two joined
```

### SampleCratePyO3.jl

A Julia package with a Rust crate embedded under `deps/sample_crate_pyo3/` that has **dual bindings** for both Julia and Python using feature flags (`test/runtests.jl` makes the same assertions as the crate's `main.py`). Nothing is `pub`: `#[julia]` emits its entry points and PyO3 registers its own inside the crate, which is how a real crate of either kind is written.

**Features demonstrated:**
- Coexistence of `#[julia]` and PyO3 in a single crate, with no `pub` needed for either
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
that was **written for PyO3 only**: no `#[julia]`, no `rustcall_julia_macros`
dependency, no `pub` anywhere, just `#[pyfunction]`, `#[pyclass]`,
`#[pymethods]` and a `#[pymodule]`. It is a real extension module
(`crate-type = ["cdylib"]`, pyo3's `extension-module`). RustCall binds it
without changing it ([#424](https://github.com/AtelierArith/RustCall.jl/issues/424)):
`@rust_crate ... pyo3_host=true` builds the crate **as the Python extension it
already is** and calls the imported module, so the private `#[pyfunction]`s and
the `Python<'_>`/numpy/callable signatures the older C-ABI wrapper path cannot
bind are all reachable. This is the shape you have when the crate is not yours
to annotate.

**Features demonstrated:**
- Binding a PyO3 crate with no RustCall attribute anywhere, by building it as an extension and importing it through PythonCall
- `PyResult<T>` → `RustResult{T, String}` carrying the **real** exception message (there is an interpreter), and a Julia layer (`parse_int`) that turns `Err` into an `ArgumentError`
- `#[new]` as the constructor, `#[staticmethod]` as a function (`origin()`), `#[pyclass(get_all, set_all)]` fields as properties, `&self` / `&mut self` / `String` / `PyResult` methods
- Python owning object lifetime: no generated `Point_free`, no `finalize`

**The Python requirement** is PythonCall's interpreter: PythonCall provides one
through CondaPkg, and RustCall pins pyo3's build to that same interpreter. The
build happens lazily, on the first call, not while the package is precompiled.

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
occursin("invalid digit", SampleCratePyO3Only.Bindings.parse("x").value)  # true
```

`RustCall.scan_report("examples/SampleCratePyO3Only.jl/deps/sample_crate_pyo3_only")`
still reports what the C-ABI wrapper path *would* export and skip — here only
the `#[pymodule]` — but the host path binds what the crate's `#[pymodule]`
registers, `pub` or not.

### RustCrateMacroPyO3Only.jl

The same PyO3-only crate shape as above — `deps/macro_pyo3_only/` carries no
RustCall attribute, no `rustcall_julia_macros` dependency and no `pub` — bound
through the **other front door**: `@rust_crate ... submodule="Bindings"
pyo3_host=true` at the package's top level, which
[#339](https://github.com/AtelierArith/RustCall.jl/issues/339) made
precompilable. Read it next to `SampleCratePyO3Only.jl`: the two crates are
interchangeable, and the whole difference is in `src/`.

**Features demonstrated:**
- `@rust_crate` in a package's `src/`, with `submodule="Bindings"` defining the generated module as `RustCrateMacroPyO3Only.Bindings` so `using .Bindings: ...` works (`name=` only renames the otherwise hidden module and defines nothing)
- No `deps/build.jl`, no `src/generated/` and no wrapper crate: the bindings module is compiled into the package's precompile image, and the crate's build and import happen lazily on the first call
- `RustCall.clear_cache()` or an edit to the crate rebuilds: the artifact key digests the crate's sources
- The package needs `RustCall` and `PythonCall`; `Libdl` is not involved — the host path never `dlopen`s the crate
- The same `PyResult` → `RustResult` lowering with the real exception message, and a Julia layer (`safe_div`) that turns any `Err` into a `DivideError`

**The Python requirement** is the same as `SampleCratePyO3Only.jl`'s:
PythonCall's interpreter, provided through CondaPkg, pinned as pyo3's
`PYO3_PYTHON` at build time.

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

### Pyo3HostImport.jl

The two host-path **front doors** side by side, each over its own PyO3-only
crate. `deps/macro_crate/` is bound with the **`@rust_crate` macro**
(`@rust_crate ... submodule="MacroBindings" pyo3_host=true`) and
`deps/direct_crate/` with **`RustCall.pyo3_host_import`** — the build/import the
macro is built on, called directly. The two crates are otherwise the same shape
(no RustCall attribute, no `rustcall_julia_macros`, no `pub`, `cdylib` +
`extension-module`); the difference that decides the front door is one line:

```rust
#[new] fn new(start: i64) -> Self        // macro_crate: scalar -> Julia `Integer`, works
#[new] fn new(obj: Py<PyAny>) -> ...     // direct_crate: -> Julia `Any`, macro cannot bind it
```

A single `Py<PyAny>` argument makes the macro generate `Sized(obj::Any)`, which
overwrites Julia's default untyped single-field constructor of the host handle
struct, and precompilation rejects that
([#433](https://github.com/AtelierArith/RustCall.jl/issues/433)).
`RustCall.pyo3_host_import` generates nothing, so the class is wrapped by hand —
and the wrapper defines an explicit inner constructor, which suppresses the
default constructors that caused the collision.

**Features demonstrated:**
- `@rust_crate ... submodule=... pyo3_host=true` and `RustCall.pyo3_host_import`
  as the two front doors to the same host path
- A `#[new]` shape the macro cannot currently bind, and the direct-import
  workaround for it
- Why an explicit inner constructor matters: without it, a hand-written
  `Sized(obj)` collides exactly as the generated one did
- Lazy build/import on the first call for both front doors

**How to use from Julia:**
```bash
cd examples/Pyo3HostImport.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.test()'
```
```julia
using Pyo3HostImport
# macro front door
scale(Int32(3), Int32(4))                    # 12
a = Accumulator(Int64(10)); add(a, Int64(5)) # 15, mutates `a`
# direct-import front door
item_count(Sized(Dict("a" => 1, "b" => 2)))  # 2
item_count(Sized([10, 20, 30, 40]))          # 4
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
   - See the crate bindings coexist with an inline `rust"""` block (`@rust_str`)

3. **Explore RustCrateMacro.jl**
   - Bind a `#[julia]` crate with `@rust_crate ... submodule="Bindings"` at a
     package's top level, instead of `write_bindings_to_file` in `deps/build.jl`
   - See all three front doors — `#[julia]`, `@rust_crate` and inline
     `rust"""` — coexist in one package, and compose in `inline_norm`

4. **Explore SampleCratePyO3.jl** (optional)
   - Learn how to create dual Julia/Python bindings
   - Understand feature flags for conditional compilation
   - See how to share core logic between languages

5. **Explore SampleCratePyO3Only.jl** (optional)
   - Bind a PyO3 crate you cannot annotate: build it as the extension it is and
     import it through PythonCall (`pyo3_host=true`)
   - See what `PyResult<T>` becomes when there *is* an interpreter: a
     `RustResult` carrying the real message
   - Understand why no `pub` is needed and who owns object lifetime (Python)

6. **Compare RustCrateMacroPyO3Only.jl** (optional)
   - The same crate shape bound with `@rust_crate ... submodule="Bindings"
     pyo3_host=true` in a package's `src/`
   - See what a package that generates nothing looks like: bindings in the
     precompile image, the crate built and imported lazily on the first call

7. **Compare the two front doors with Pyo3HostImport.jl** (optional)
   - `@rust_crate ... pyo3_host=true` and `RustCall.pyo3_host_import` over two
     PyO3-only crates, in one package
   - A `#[new]` shape the macro cannot bind, and the direct-import workaround
     plus explicit inner constructor that binds it
     ([#433](https://github.com/AtelierArith/RustCall.jl/issues/433))

8. **Read the documentation**
   - [Tutorial](../docs/src/tutorial.md)
   - [Crate Bindings (Phase 6)](../docs/src/crate_bindings.md)
   - [Troubleshooting](../docs/src/troubleshooting.md)

## Troubleshooting

### Rust not found

RustCall resolves `rustc`/`cargo` through RustToolChain.jl: a system Rust on
`PATH` when there is one, otherwise the toolchain it installs through Julia's
Artifacts system — so a system Rust is optional. If `using RustCall` reports
"No working rustc found", it names both routes and how to see the underlying
error:

```julia
using RustToolChain; run(`$(RustToolChain.rustc()) --version`)
```

Remedies: make the artifact download possible (network access, a writable
depot) and retry; or install Rust yourself from [rustup.rs](https://rustup.rs/)
so a `rustc` is on `PATH` (it then takes precedence). On Windows the MSVC
target — RustCall's default, and the only one the artifact toolchain
provides — also needs the MSVC build tools; the GNU route that avoids them is
described in `docs/src/platforms/windows.md`.

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
