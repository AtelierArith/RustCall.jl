# SampleCratePyO3Only.jl

A Julia **package** with the Rust crate [`deps/sample_crate_pyo3_only`](./deps/sample_crate_pyo3_only/)
embedded in it: a crate **written for PyO3 only**. There is no RustCall
attribute anywhere in it — no `#[julia]`, no `rustcall_julia_macros` dependency —
just `#[pyfunction]`, `#[pyclass]` and `#[pymethods]`, the way its author
wrote it for Python. RustCall binds it as is
([#275](https://github.com/AtelierArith/RustCall.jl/issues/275) Phase 2): the
build step scans the `pub` items PyO3 exposes, generates a **wrapper crate**
that depends on the crate and exports one `extern "C"` entry point per item,
builds that wrapper, and writes its bindings. This package is that binding.

The two other example packages show the other shapes: `../SampleCrate.jl` is a
crate with `#[julia]`, `../SampleCratePyO3.jl` a crate with `#[julia]` *and*
PyO3 attributes on one definition. This one is what you have when the crate is
not yours to annotate.

The example is **self-contained**: everything it builds and tests is inside
this directory. The crate itself refers to nothing outside it; the wrapper
crate RustCall generates depends on `rustcall_julia_macros` from this checkout, and
is written under the crate's own `target/`.

## Layout: Rust and Julia in separate files

```
SampleCratePyO3Only.jl/
├── Project.toml
├── deps/
│   ├── build.jl                      # Pkg.build: generate + build the wrapper crate, write the bindings
│   ├── sample_crate_pyo3_only/       # Rust: a PyO3 crate, untouched
│   │   ├── Cargo.toml                #   pyo3 mandatory, `crate-type = ["rlib"]`, no RustCall dependency
│   │   └── src/lib.rs                #   #[pyfunction], #[pyclass], #[pymethods], #[pymodule] — no #[julia]
│   └── lib/                          # the compiled wrapper library (git-ignored)
├── src/
│   ├── SampleCratePyO3Only.jl        # hand-written Julia
│   └── generated/Bindings.jl         # written by deps/build.jl (git-ignored)
└── test/runtests.jl                  # Pkg.test
```

## The Python requirement

pyo3 is a plain **mandatory** dependency of the crate
(`default-features = false, features = ["macros"]`), which is what most PyO3
crates look like: pyo3's inner attributes (`#[new]`, `#[staticmethod]`,
`#[pyo3(get, set)]`, ...) cannot be put behind `#[cfg_attr(feature = ...)]`, so
a class always needs pyo3 in the graph. Any build whose graph contains pyo3
links libpython, so RustCall's link plan for this crate is **`:link_libpython`**
(`RustCall.pyo3_link_plan("deps/sample_crate_pyo3_only").mode`), and building
this package needs a **Python interpreter** whose library directory RustCall
can find:

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
plan modes (`:python_free`, `:unlinkable`), are in RustCall's `docs/src/pyo3.md`.

No Python is *called*: the wrapper never initializes an interpreter, it only
links the library pyo3 refers to. The `Examples` workflow installs one with
`actions/setup-python` before Julia runs.

## Run the tests

```bash
cd examples/SampleCratePyO3Only.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.test()'
```

`Pkg.develop(path="../..")` uses the RustCall of this checkout; with a
registered RustCall, `Pkg.instantiate()` is enough. A fresh checkout needs no
manual build step: loading the package generates `src/generated/Bindings.jl`
once. After editing the crate, `Pkg.build("SampleCratePyO3Only")` regenerates
it.

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
origin()                     # Point(0, 0) — a #[staticmethod]; also origin(Point)
distance(p, origin())        # a Julia-side convenience
```

### What `PyResult<T>` becomes

`parse(s) -> PyResult<i32>` in Rust is `RustResult{Int32, String}` in Julia,
and the `Err` payload is always the same fixed sentence:

```julia
r = SampleCratePyO3Only.Bindings.parse("42")          # RustResult{Int32, String}(true, 42)
bad = SampleCratePyO3Only.Bindings.parse("forty-two")
RustCall.is_err(bad)                                  # true
bad.value == RustCall.PYO3_OPAQUE_ERROR               # true
# "PyErr (Python-side error; message unavailable without an interpreter)"
```

That is deliberate: creating and dropping a `PyErr` needs no interpreter, but
*rendering* one does, so the generated code never looks at it. The Julia layer
in `src/SampleCratePyO3Only.jl` turns it into something idiomatic:

```julia
parse_int("42")              # 42::Int32
parse_int("forty-two")       # throws ArgumentError
```

(`parse` itself is not re-exported, because that would shadow `Base.parse`;
reach it as `SampleCratePyO3Only.Bindings.parse`.) The same lowering applies to
a `PyResult` *method*: `scaled(p, 2.0)` is `RustResult{Float64, String}`.

## Notes

- **`rustcall_julia_macros` is not needed by the crate.** `deps/sample_crate_pyo3_only/Cargo.toml`
  depends on pyo3 and nothing else. The wrapper crate RustCall generates does
  depend on `rustcall_julia_macros`, from this checkout — that is where the
  `extern "C"` entry points, the string ABI and the panic channel come from —
  but that is RustCall's business, not the crate's.
- **What a PyO3 crate needs to be wrappable**: every item Julia should see must
  be `pub` (pyo3 does not need that; a wrapper crate compiled outside the crate
  does), the `[lib]` must offer an `rlib` target (`["cdylib", "rlib"]` for a
  real extension module), and pyo3's `extension-module` feature must not be on
  unconditionally (that build cannot be loaded outside Python: link plan
  `:unlinkable`). `RustCall.scan_report("deps/sample_crate_pyo3_only")` lists
  what the wrapper exports and, for what it skips, why — here only the
  `#[pymodule]` initializer.
- `deps/build.jl` is `RustCall.write_bindings_to_file(crate, "src/generated/Bindings.jl"; relative_lib_path = "../../deps/lib")`,
  the same call as in `../SampleCrate.jl`; the wrapper path is chosen by the
  crate's contents, not by an option.
- RustCall's test suite uses its own, larger copy of this crate,
  `test/fixtures/sample_crate_pyo3_only`; this example does not depend on it.
