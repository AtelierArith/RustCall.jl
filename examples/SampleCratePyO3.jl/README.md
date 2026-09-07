# SampleCratePyO3.jl

A Julia **package** around [`../sample_crate_pyo3`](../sample_crate_pyo3/), the
Rust crate with **dual bindings**: `#[julia]` for Julia and PyO3's own
attributes for Python, on one definition of each item. This package is the
Julia consumer; the Python consumer is `../sample_crate_pyo3/main.py`, built
with maturin. Both call the same Rust and get the same results.

## Layout: Rust and Julia in separate files

```
examples/
├── sample_crate_pyo3/            # Rust: one implementation, two bindings
│   ├── Cargo.toml                #   pyo3 behind the optional `python` feature
│   ├── src/lib.rs                #   #[julia] + #[cfg_attr(feature = "python", pyo3::...)]
│   └── main.py                   #   the Python consumer (maturin develop --features python)
└── SampleCratePyO3.jl/           # Julia: the package
    ├── Project.toml
    ├── deps/build.jl             #   Pkg.build: cargo build (no `python` feature) + write the bindings
    ├── src/
    │   ├── SampleCratePyO3.jl    #   hand-written Julia
    │   └── generated/Bindings.jl #   written by deps/build.jl (git-ignored)
    └── test/runtests.jl          #   Pkg.test — the same checks as main.py
```

The Julia build never enables the crate's `python` feature: pyo3 is not in the
dependency graph, and the library RustCall loads links no Python.

## Run the tests

```bash
cd examples/SampleCratePyO3.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.test()'
```

`Pkg.develop(path="../..")` uses the RustCall of this checkout; with a
registered RustCall, `Pkg.instantiate()` is enough. A fresh checkout needs no
manual build step: loading the package generates `src/generated/Bindings.jl`
once. After editing the crate, `Pkg.build("SampleCratePyO3")` regenerates it.

The same tests run in CI (the `Examples` workflow).

## Usage

```julia
using SampleCratePyO3

add(Int32(2), Int32(3))      # 5
fibonacci(UInt32(10))        # 55
shout("hello")               # "HELLO"
shout_twice("hi")            # "HI HI"

p = Point(3.0, 4.0)
p.x, p.y                     # 3.0, 4.0
distance_from_origin(p)      # 5.0
translate(p, 1.0, 2.0)       # mutates p → (4.0, 6.0)
q = scaled(p, 2.0)           # a new Point (8.0, 12.0)
p.x = 10.0                   # setter
```

and, from Python, after `maturin develop --features python` in the crate:

```python
import sample_crate_pyo3 as m
m.add(2, 3)                  # 5
p = m.Point(3.0, 4.0)
p.distance_from_origin()     # 5.0
```

Same names, same results; `test/runtests.jl` and `main.py` make the same
assertions.

## Notes

- How the two attribute sets compose on one item is documented in [`../sample_crate_pyo3/README.md`](../sample_crate_pyo3/README.md) and in RustCall's `docs/src/pyo3.md`.
- `deps/build.jl` is `RustCall.write_bindings_to_file(crate, "src/generated/Bindings.jl"; relative_lib_path = "../../deps/lib")`; see `../SampleCrate.jl/README.md` for the workflow.
