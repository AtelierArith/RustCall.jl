# RustCrateMacroPyO3Only.jl

A Julia **package** that binds a **PyO3-only** Rust crate with the
**`@rust_crate` macro**, at the package's top level. The crate
[`deps/macro_pyo3_only`](./deps/macro_pyo3_only/) carries no RustCall attribute
— no `#[julia]`, no `juliacall_macros` dependency — just `#[pyfunction]`,
`#[pyclass]` and `#[pymethods]`, the way its author wrote it for Python.
RustCall binds it as is
([#275](https://github.com/AtelierArith/RustCall.jl/issues/275) Phase 2) by
generating a **wrapper crate** that depends on it and exports one `extern "C"`
entry point per item.

## What is different from `SampleCratePyO3Only.jl`

Nothing about the Rust side, and that is the point. `../SampleCratePyO3Only.jl`
binds a crate of the same shape; the two examples differ only in **how the
bindings are obtained**:

| | `SampleCratePyO3Only.jl` | this package |
|---|---|---|
| front door | `RustCall.write_bindings_to_file` in `deps/build.jl` | `@rust_crate ... submodule="Bindings"` in `src/` |
| when the crate is built | `Pkg.build("SampleCratePyO3Only")` | when the package is **precompiled** |
| generated Julia code | a file, `src/generated/Bindings.jl`, `include`d | in memory, straight into the package's precompile image |
| in the repository | a `.gitignore`d generated file and library | nothing generated at all |
| needs Rust to load | no, once built — the package carries the library | yes: precompilation builds the crate |

Use the written-file form when the package is to be shipped to machines that
have no Rust toolchain, or when you want to read the generated bindings. Use
`@rust_crate`, as here, when the crate is developed alongside the package and
the extra build step is not worth it.

The macro at a package's top level is what
[#339](https://github.com/AtelierArith/RustCall.jl/issues/339) made possible:
the generated module is defined **inside** the module that expands the macro,
so it is part of the package's module tree and Julia can serialize it.

## Layout: Rust and Julia in separate files

```
RustCrateMacroPyO3Only.jl/
├── Project.toml
├── deps/
│   └── macro_pyo3_only/              # Rust: a PyO3 crate, untouched
│       ├── Cargo.toml                #   pyo3 mandatory, `crate-type = ["rlib"]`, no RustCall dependency
│       └── src/lib.rs                #   #[pyfunction], #[pyclass], #[pymethods], #[pymodule] — no #[julia]
├── src/
│   └── RustCrateMacroPyO3Only.jl     # hand-written Julia; @rust_crate is one line of it
└── test/runtests.jl                  # Pkg.test
```

There is no `deps/build.jl` and no `src/generated/`.

The example is **self-contained**: everything it builds and tests is inside
this directory. The crate itself refers to nothing outside it; the wrapper
crate RustCall generates depends on `juliacall_macros` from this checkout, and
is written under the crate's own `target/`.

## The one line

```julia
module RustCrateMacroPyO3Only
using RustCall
@rust_crate joinpath(@__DIR__, "..", "deps", "macro_pyo3_only") submodule="Bindings"
using .Bindings: scale, join_words, checked_div, Counter, zeroed, bump, current, describe, advance
export scale, join_words, checked_div, Counter, zeroed, bump, current, describe, advance
end
```

`submodule="Bindings"` **defines** the generated module in this module, as
`RustCrateMacroPyO3Only.Bindings`, which is what makes the `using .Bindings`
line possible. It is the option a *package* wants.

Without it the module still exists — hidden inside the calling module, in a
namespace nothing else can name — and is reached only through the value the
macro returns:

```julia
const B = @rust_crate joinpath(@__DIR__, "..", "deps", "macro_pyo3_only")
B.scale(Int32(3), Int32(4))
```

which is the shape to use at the REPL or inside a function. `name="X"` is a
separate option and does a separate job: it chooses what that hidden module is
*called* (the default is the crate name in PascalCase) and still defines
nothing in the caller, which is why `const B = @rust_crate path name="B"` keeps
working — the constant is the only binding the caller gets. Never write
`const Bindings = @rust_crate path submodule="Bindings"`: the constant would be
bound over the module the macro just defined.

### What happens when

1. **Precompilation** (the first `using`, or `Pkg.precompile()`): `@rust_crate`
   scans the crate, generates and builds the PyO3 wrapper crate, and defines
   the bindings module — which Julia compiles into the package's cache. This is
   the step that needs `cargo` and a Python interpreter.
2. **Load** (`using RustCrateMacroPyO3Only`, in any later session): nothing is
   built. The generated module's `__init__` copies the library out of RustCall's
   cache and opens the copy.
3. **After `RustCall.clear_cache()`, or a change to the crate**: the library is
   a precompile dependency of the package (`Base.include_dependency`), so Julia
   considers the cache stale and re-precompiles — step 1 again — rather than
   opening a path that is gone.

## The Python requirement

pyo3 is a plain **mandatory** dependency of the crate
(`default-features = false, features = ["macros"]`), which is what most PyO3
crates look like: pyo3's inner attributes (`#[new]`, `#[staticmethod]`,
`#[pyo3(get, set)]`, ...) cannot be put behind `#[cfg_attr(feature = ...)]`, so
a class always needs pyo3 in the graph. Any build whose graph contains pyo3
links libpython, so RustCall's link plan for this crate is **`:link_libpython`**
(`RustCall.pyo3_link_plan("deps/macro_pyo3_only").mode`), and **precompiling**
this package needs a **Python interpreter** whose library directory RustCall can
find:

- by default the `python3` (or `python`) on `PATH` is asked for its library
  directory, which becomes the linker search path and, on Unix, an rpath
  recorded in the wrapper library;
- `PYO3_PYTHON=/path/to/python3` pins a specific interpreter (a virtual
  environment, a Conda one); `RUSTCALL_PYTHON_LIBDIR` overrides the directory
  outright;
- on **Windows** there is no rpath: the generated module records the
  interpreter's `python3xy.dll` by full path and preloads it before the wrapper,
  so the DLL need not be on `PATH`.

The interpreter — its path and what it reports about itself — is part of the
wrapper's artifact identity, so switching Pythons rebuilds the wrapper rather
than reusing one configured for the other. The details, and the two other link
plan modes (`:python_free`, `:unlinkable`), are in RustCall's
[`docs/src/pyo3.md`](../../docs/src/pyo3.md).

No Python is *called*: the wrapper never initializes an interpreter, it only
links the library pyo3 refers to. The `Examples` workflow installs one with
`actions/setup-python` before Julia runs.

## Run the tests

```bash
cd examples/RustCrateMacroPyO3Only.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.test()'
```

`Pkg.develop(path="../..")` uses the RustCall of this checkout; with a
registered RustCall — **0.3.1 or later**, the first release whose `@rust_crate`
has `submodule=` — `Pkg.instantiate()` is enough. There is no build step to
run: the first `using` (which `Pkg.test()` performs) precompiles the package
and builds the crate.

The same tests run in CI (the `Examples` workflow, job
`Example - RustCrateMacroPyO3Only.jl`).

## Usage

```julia
using RustCrateMacroPyO3Only

scale(Int32(3), Int32(4))       # 12          — a #[pyfunction]
join_words("hello", "world")    # "hello world" — String in, String out

c = Counter(Int64(10), Int64(2))  # #[new]
c.value, c.step                 # 10, 2       — #[pyclass(get_all, set_all)]
current(c)                      # 10          — a &self method
bump(c)                         # 12; mutates c — a &mut self method
describe(c)                     # "12 (+2)"   — a String-returning method
zeroed()                        # Counter(0, 1) — a #[staticmethod]; also zeroed(Counter)
safe_div(7, 2)                  # 3           — a Julia-side convenience
```

### What `PyResult<T>` becomes

`checked_div(a, b) -> PyResult<i32>` in Rust is `RustResult{Int32, String}` in
Julia, and the `Err` payload is always the same fixed sentence:

```julia
r = checked_div(Int32(7), Int32(2))       # RustResult{Int32, String}(true, 3)
bad = checked_div(Int32(1), Int32(0))
RustCall.is_err(bad)                      # true
bad.value == RustCall.PYO3_OPAQUE_ERROR   # true
# "PyErr (Python-side error; message unavailable without an interpreter)"
```

That is deliberate: creating and dropping a `PyErr` needs no interpreter, but
*rendering* one does, so the generated code never looks at it. The Julia layer
in `src/RustCrateMacroPyO3Only.jl` turns it into something idiomatic:

```julia
safe_div(7, 2)                    # 3::Int32
safe_div(1, 0)                    # throws DivideError
safe_div(typemin(Int32), -1)      # throws DivideError too: the quotient does not fit
```

(The crate uses `i32::checked_div`, so that last case is an `Err` and not a
Rust panic — `/` panics on it even in release builds.)

The same lowering applies to a `PyResult` *method*: `advance(c, 3)` is
`RustResult{Int64, String}`.

## Notes

- **`juliacall_macros` is not needed by the crate.**
  `deps/macro_pyo3_only/Cargo.toml` depends on pyo3 and nothing else. The
  wrapper crate RustCall generates does depend on `juliacall_macros`, from this
  checkout — that is where the `extern "C"` entry points, the string ABI and
  the panic channel come from — but that is RustCall's business, not the
  crate's.
- **`Libdl` is not among this package's dependencies.** The generated module
  reaches it through RustCall (`import RustCall.Libdl`), so a package that uses
  `@rust_crate` needs RustCall alone.
- **What a PyO3 crate needs to be wrappable**: every item Julia should see must
  be `pub` (pyo3 does not need that; a wrapper crate compiled outside the crate
  does), the `[lib]` must offer an `rlib` target (`["cdylib", "rlib"]` for a
  real extension module), and pyo3's `extension-module` feature must not be on
  unconditionally — a build with it cannot be loaded outside an interpreter
  (link plan `:unlinkable`).
- **The `#[pymodule]` initializer is skipped.** It means nothing outside a
  Python interpreter, and the scan says so:
  `RustCall.scan_report("deps/macro_pyo3_only")` lists the ten items the
  wrapper exports, the one it skips and why, and the link plan.
- **Nothing this package exports shadows a `Base` name.** A PyO3 method called
  `peek` or `parse` would, and `using` the package would then make that name
  ambiguous at every call site; `../SampleCratePyO3Only.jl` shows what to do
  then — leave it out of the `using .Bindings` list and reach it as
  `Bindings.parse`.
