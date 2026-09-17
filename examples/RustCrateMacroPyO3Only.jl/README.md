# RustCrateMacroPyO3Only.jl

A Julia **package** that binds a **PyO3-only** Rust crate with the
**`@rust_crate` macro**, at the package's top level. The crate
[`deps/macro_pyo3_only`](./deps/macro_pyo3_only/) carries no RustCall attribute
— no `#[julia]`, no `rustcall_julia_macros` dependency — and no `pub` on any
item, because a real extension module needs none. RustCall binds it as is
([#424](https://github.com/AtelierArith/RustCall.jl/issues/424)): it builds the
crate as the Python extension it already is, imports it, and calls the imported
module.

## What is different from `SampleCratePyO3Only.jl`

Nothing about the Rust side, and that is the point. `../SampleCratePyO3Only.jl`
binds a crate of the same shape through the same host path; the two examples
differ only in **how the bindings are obtained**:

| | `SampleCratePyO3Only.jl` | this package |
|---|---|---|
| front door | `@rust_crate ... submodule="Bindings" pyo3_host=true` in `src/` too | same macro, same options |
| when the crate is built | first call | first call |
| generated Julia code | in memory, into the package's precompile image | same |
| in the repository | nothing generated | nothing generated |

The two are now nearly identical: after #424 the difference is only that this
package's crate is the other one, and its `src/` docstring is written around the
macro. Keep reading if you want the `@rust_crate` **front door** explained.

The macro at a package's top level is what
[#339](https://github.com/AtelierArith/RustCall.jl/issues/339) made possible:
the generated module is defined **inside** the module that expands the macro,
so it is part of the package's module tree and Julia can serialize it.

## Layout: Rust and Julia in separate files

```
RustCrateMacroPyO3Only.jl/
├── Project.toml
├── deps/
│   └── macro_pyo3_only/              # Rust: a PyO3 extension crate, untouched
│       ├── Cargo.toml                #   pyo3, `crate-type = ["cdylib"]`, extension-module, no RustCall dependency
│       └── src/lib.rs                #   #[pyfunction], #[pyclass], #[pymethods], #[pymodule] — no pub, no #[julia]
├── src/
│   └── RustCrateMacroPyO3Only.jl     # hand-written Julia; @rust_crate is one line of it
└── test/runtests.jl                  # Pkg.test
```

There is no `deps/build.jl`, no `src/generated/`, and no wrapper crate.

The example is **self-contained**: everything it builds and tests is inside
this directory.

## The one line

```julia
module RustCrateMacroPyO3Only
using RustCall
import PythonCall   # loads RustCallPyO3HostExt, the host path's interpreter
@rust_crate joinpath(@__DIR__, "..", "deps", "macro_pyo3_only") submodule="Bindings" pyo3_host=true
using .Bindings: scale, join_words, checked_div, Counter, zeroed, bump, current, describe, advance
export scale, join_words, checked_div, Counter, zeroed, bump, current, describe, advance
end
```

`submodule="Bindings"` **defines** the generated module in this module, as
`RustCrateMacroPyO3Only.Bindings`, which is what makes the `using .Bindings`
line possible. `pyo3_host=true` selects the host path. Both are what a *package*
wants.

Without `submodule` the module still exists — hidden inside the calling module,
in a namespace nothing else can name — and is reached only through the value the
macro returns:

```julia
const B = @rust_crate joinpath(@__DIR__, "..", "deps", "macro_pyo3_only")
B.scale(Int32(3), Int32(4))
```

which is the shape to use at the REPL or inside a function. `name="X"` is a
separate option: it chooses what that hidden module is *called* (the default is
the crate name in PascalCase) and still defines nothing in the caller, which is
why `const B = @rust_crate path name="B"` keeps working. Never write
`const Bindings = @rust_crate path submodule="Bindings"`: the constant would be
bound over the module the macro just defined.

### What happens when

1. **Precompilation** (the first `using`, or `Pkg.precompile()`): `@rust_crate`
   scans the crate and defines the bindings module — which Julia compiles into
   the package's cache. Nothing is built and no Python starts.
2. **First call** (`scale(...)`, `Counter(...)`, …): the crate is built as an
   extension with PythonCall's interpreter, the module is imported, and the
   typed binding calls it. The result is cached, so later calls and later
   sessions reuse it.
3. **After `RustCall.clear_cache()`, or a change to the crate**: the artifact key
   digests the crate's sources, so the next call rebuilds.

## The Python requirement

The host path is **PythonCall's** interpreter. PythonCall provides one through
CondaPkg by default, and RustCall pins pyo3's build to the very same interpreter
(`PYO3_PYTHON = PythonCall.python_executable_path()`); its path and fingerprint
are part of the artifact cache key. The crate is `extension-module`, so its
cdylib leaves libpython's symbols to the interpreter that loads it — the build
the C-ABI path calls `:unlinkable` and this path requires.

The build is lazy, on the first call: a Python interpreter may not be started
during precompilation.

## Run the tests

```bash
cd examples/RustCrateMacroPyO3Only.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.test()'
```

`Pkg.develop(path="../..")` uses the RustCall of this checkout; with a
registered RustCall — **0.3.1 or later**, the first release whose `@rust_crate`
has `submodule=` — `Pkg.instantiate()` is enough. Nothing is written into the
package.

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
zeroed()                        # Counter(0, 1) — a #[staticmethod]
safe_div(7, 2)                  # 3           — a Julia-side convenience
```

### What `PyResult<T>` becomes

`checked_div(a, b) -> PyResult<i32>` in Rust is `RustResult{Int32, String}` in
Julia. The host path has an interpreter, so the `Err` payload is the **real
exception message**:

```julia
r = checked_div(Int32(7), Int32(2))       # RustResult{Int32, String}(true, 3)
bad = checked_div(Int32(1), Int32(0))
RustCall.is_err(bad)                      # true
occursin("division by zero", bad.value)   # true — pyo3's own message
```

The Julia layer in `src/RustCrateMacroPyO3Only.jl` turns any `Err` into
something idiomatic:

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

- **`rustcall_julia_macros` is not needed.** `deps/macro_pyo3_only/Cargo.toml`
  depends on pyo3 and nothing else, and RustCall generates no wrapper crate: it
  builds the crate itself and imports the result.
- **PythonCall is a dependency.** The generated module imports it, and
  `import PythonCall` in `src/` is what loads the `RustCallPyO3HostExt`
  extension. `Libdl` is not needed: the host path never `dlopen`s the crate.
- **What a PyO3 crate needs here**: a `#[pymodule]` initializer (that is what is
  imported, and only what it registers is reachable). No `pub`, no `rlib`, no
  `extension-module` workaround — and `Python<'_>`/numpy/callable signatures are
  fine, which is the whole point.
- **Object lifetime is Python's.** There is no generated `Counter_free` and no
  `finalize(c)`.
- **Nothing this package exports shadows a `Base` name.** A PyO3 method called
  `peek` or `parse` would, and `using` the package would then make that name
  ambiguous at every call site; `../SampleCratePyO3Only.jl` shows what to do
  then — leave it out of the `using .Bindings` list and reach it as
  `Bindings.parse`.
