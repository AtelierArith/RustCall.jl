# SampleCratePyO3Only.jl

A Julia **package** with the Rust crate [`deps/sample_crate_pyo3_only`](./deps/sample_crate_pyo3_only/)
embedded in it: a crate **written for PyO3 only**. There is no RustCall
attribute anywhere in it — no `#[julia]`, no `rustcall_julia_macros` dependency —
and no `pub` on any item, because PyO3 does not need one: its macros expand the
wrapper *inside* the crate. It is a real extension module
(`crate-type = ["cdylib"]`, pyo3's `extension-module`).

RustCall binds it as is ([#424](https://github.com/AtelierArith/RustCall.jl/issues/424)):
it builds the crate **as the Python extension it already is**, imports it through
PythonCall, and calls the imported module. That reaches what the older C-ABI
wrapper path cannot — a private `#[pyfunction]` an outside crate could not name
(rustc E0603), and `Python<'_>` / `Py<T>` / numpy / callable signatures that need
a live interpreter.

The two other example packages show the other shapes: `../SampleCrate.jl` is a
crate with `#[julia]`, `../SampleCratePyO3.jl` a crate with `#[julia]` *and*
PyO3 attributes on one definition. This one is what you have when the crate is
not yours to annotate.

The example is **self-contained**: everything it builds and tests is inside this
directory.

## Layout: Rust and Julia in separate files

```
SampleCratePyO3Only.jl/
├── Project.toml
├── deps/
│   └── sample_crate_pyo3_only/       # Rust: a PyO3 extension crate, untouched
│       ├── Cargo.toml                #   pyo3, `crate-type = ["cdylib"]`, extension-module, no RustCall dependency
│       └── src/lib.rs                #   #[pyfunction], #[pyclass], #[pymethods], #[pymodule] — no pub, no #[julia]
├── src/
│   └── SampleCratePyO3Only.jl        # hand-written Julia; `@rust_crate ... pyo3_host=true` is the binding
└── test/runtests.jl                  # Pkg.test
```

There is no `deps/build.jl`, no `src/generated/`, and no wrapper crate: the
typed bindings are generated in memory and the crate is built in place.

## The Python requirement

RustCall's host path is **PythonCall's** interpreter: PythonCall starts it
(CondaPkg provides one by default, so `Pkg.instantiate()` downloads nothing you
have to arrange yourself), and RustCall pins pyo3's build to the very same
interpreter (`PYO3_PYTHON = PythonCall.python_executable_path()`). The
interpreter's path and fingerprint are part of the artifact cache key, so
switching interpreters rebuilds rather than reuses an extension configured for
another. The build happens lazily, on the first call, not while the package is
precompiled: a Python interpreter may not be started during precompilation.

The crate is `extension-module`, so its cdylib leaves libpython's symbols to the
interpreter that loads it — the build the C-ABI path calls `:unlinkable` and
this path requires.

## Run the tests

```bash
cd examples/SampleCratePyO3Only.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.test()'
```

`Pkg.develop(path="../..")` uses the RustCall of this checkout; with a
registered RustCall, `Pkg.instantiate()` is enough. Nothing is written into the
package: the build output lives under the crate's own `target/`, and the
extension module under RustCall's cache.

The same tests run in CI (the `Examples` workflow, job
`Example - SampleCratePyO3Only.jl`).

## Usage

```julia
using SampleCratePyO3Only

add(Int32(2), Int32(3))      # 5           — a #[pyfunction]
shout("hello")               # "HELLO!"    — String in, String out

p = Point(3.0, 4.0)          # #[new]
p.x, p.y                     # 3.0, 4.0    — #[pyclass(get_all, set_all)]
norm(p)                      # 5.0         — a &self method
translate(p, 1.0, 2.0)       # mutates p → (4.0, 6.0); a &mut self method
label(p)                     # "(4, 6)"    — a String-returning method
origin()                     # Point(0, 0) — a #[staticmethod]
distance(p, origin())        # a Julia-side convenience
```

### What `PyResult<T>` becomes

`parse(s) -> PyResult<i32>` in Rust is `RustResult{Int32, String}` in Julia. The
host path has an interpreter, so the `Err` payload is the **real exception
message**:

```julia
r = SampleCratePyO3Only.Bindings.parse("42")          # RustResult{Int32, String}(true, 42)
bad = SampleCratePyO3Only.Bindings.parse("forty-two")
RustCall.is_err(bad)                                  # true
occursin("invalid digit", bad.value)                  # true — pyo3's own message
```

The Julia layer in `src/SampleCratePyO3Only.jl` turns it into something
idiomatic:

```julia
parse_int("42")              # 42::Int32
parse_int("forty-two")       # throws ArgumentError
```

(`parse` itself is not re-exported, because that would shadow `Base.parse`;
reach it as `SampleCratePyO3Only.Bindings.parse`.) The same lowering applies to
a `PyResult` *method*: `scaled(p, 2.0)` is `RustResult{Float64, String}`.

## Notes

- **`rustcall_julia_macros` is not needed.** `deps/sample_crate_pyo3_only/Cargo.toml`
  depends on pyo3 and nothing else, and RustCall generates no wrapper crate: it
  builds the crate itself and imports the result. The `#[julia]` crate
  (`../SampleCrate.jl`) is the case that needs the helper crate.
- **What a PyO3 crate needs here**: a `#[pymodule]` initializer (that is what is
  imported, and only what it registers is reachable), and that is all — the
  crate's `crate-type` is overridden to `cdylib` if it is not one. No `pub`, no
  `rlib`, no `extension-module` workaround.
- **Object lifetime is Python's.** There is no generated `Point_free` and no
  `finalize(p)`: the Julia handle holds a Python object, so PythonCall's GC owns
  it.
- RustCall's test suite uses its own copy of this crate,
  `test/fixtures/sample_crate_pyo3_host`; this example does not depend on it.
