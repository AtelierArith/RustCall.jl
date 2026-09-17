# Pyo3HostImport.jl

Two front doors to RustCall.jl's **Python-host path**
([#424](https://github.com/AtelierArith/RustCall.jl/issues/424)) for a
**PyO3-only** crate, side by side in one package:

| front door | crate | why |
| --- | --- | --- |
| `@rust_crate ... pyo3_host=true` | `deps/macro_crate` | the normal, generated-bindings path |
| `RustCall.pyo3_host_import` | `deps/direct_crate` | a `#[new]` the macro cannot bind today |

Both crates are real extension modules — no RustCall attribute, no
`rustcall_julia_macros` dependency, no `pub`, just `#[pyfunction]`,
`#[pyclass]`, `#[pymethods]` and `#[pymodule]`, with `cdylib` and pyo3's
`extension-module`. RustCall builds each **as the Python extension it already
is** and imports it through [PythonCall](https://github.com/JuliaPy/PythonCall.jl).

Read it next to [`../RustCrateMacroPyO3Only.jl`](../RustCrateMacroPyO3Only.jl)
(the macro, on its own) and
[`../SampleCratePyO3Only.jl`](../SampleCratePyO3Only.jl) (the same host path,
different source layout).

## Front door 1 — the macro

```julia
@rust_crate joinpath(@__DIR__, "..", "deps", "macro_crate") submodule="MacroBindings" pyo3_host=true

using .MacroBindings: scale, Accumulator, add, total

scale(Int32(3), Int32(4))     # 12
a = Accumulator(Int64(10))
add(a, Int64(5))              # 15 — mutates `a`
total(a)                      # 15
```

`deps/macro_crate`'s `#[new]` takes one **scalar** argument:

```rust
#[new]
fn new(start: i64) -> Self { Accumulator { total: start } }
```

The host path types an `i64` argument as Julia `Integer`, so the generated
constructor is `Accumulator(start::Integer)` — no collision, precompiles
cleanly. This is the front door to use whenever it works: the bindings are
generated for you, with one definition per PyO3 item.

## Front door 2 — `RustCall.pyo3_host_import`

`deps/direct_crate` differs in exactly one thing: its `#[new]` takes a single
**`Py<PyAny>`**:

```rust
#[new]
fn new(obj: Py<PyAny>) -> PyResult<Self> { ... }
```

A `Py<PyAny>` argument maps to the untyped Julia argument `Any`, so the macro's
generated public constructor would be `function Sized(obj::Any)`. Julia also
generates an untyped single-field constructor for the host handle struct itself,
and the two occupy the same method slot — precompilation rejects the overwrite
([RustCall.jl#433](https://github.com/AtelierArith/RustCall.jl/issues/433)):

```
WARNING: Method definition (::Type{Pkg.Bindings.Sized})(Any) ... overwritten ...
ERROR: Method overwriting is not permitted during Module precompilation.
```

So this half uses the build/import the macro is built on, directly:

```julia
const _DIRECT_CRATE = joinpath(@__DIR__, "..", "deps", "direct_crate")
const _DIRECT_MODULE = Base.RefValue{Any}(nothing)

function _direct_module()
    m = _DIRECT_MODULE[]
    m === nothing || return m
    m = RustCall.pyo3_host_import(_DIRECT_CRATE)   # build + import, lazily
    _DIRECT_MODULE[] = m
    return m
end
```

`RustCall.pyo3_host_import(crate_path)` is
`RustCall.build_pyo3_extension(crate; python = PythonCall.python_executable_path(), ...)`
followed by an import; it returns the imported Python module and generates no
Julia definitions. The crate's classes are wrapped by hand:

```julia
struct Sized
    py::PythonCall.Py

    # An explicit inner constructor suppresses Julia's default single-field
    # constructors (`Sized(::Py)` and the untyped `Sized(x)`) — the untyped one
    # is the collision above. `Val{:host}` keeps the raw-handle path distinct.
    Sized(py::PythonCall.Py, ::Val{:host}) = new(py)
end

function Sized(obj)
    cls = PythonCall.pygetattr(_direct_module(), "Sized")
    return Sized(PythonCall.pycall(cls, obj), Val(:host))
end

item_count(s::Sized)::Int =
    PythonCall.pyconvert(Int, PythonCall.pycall(PythonCall.pygetattr(s.py, "item_count")))
```

```julia
item_count(Sized(Dict("a" => 1, "b" => 2, "c" => 3)))   # 3
item_count(Sized([10, 20, 30, 40]))                     # 4
```

The explicit inner constructor is the key part of the workaround, not just a
detail: without it, *any* `Sized(obj)` you define collides with Julia's
default constructor exactly as the generated one did. Defining one inner
constructor suppresses both defaults, and the data-taking constructor is then
an ordinary `::Any` method.

## Running it

```bash
cd examples/Pyo3HostImport.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.test()'
```

With a registered RustCall, `Pkg.instantiate()` is enough. The host path needs
PythonCall; CondaPkg provides its interpreter, and RustCall pins pyo3's build to
that same interpreter. Each crate is built on the first call, never while the
package is precompiled.
