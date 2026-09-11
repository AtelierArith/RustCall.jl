# SampleCratePyO3.jl

A Julia **package** with the Rust crate [`deps/sample_crate_pyo3`](./deps/sample_crate_pyo3/)
embedded in it: a crate with **dual bindings**, `#[julia]` for Julia and PyO3's
own attributes for Python, on one definition of each item. This package is the
Julia consumer; the Python consumer is `deps/sample_crate_pyo3/main.py`, built
with maturin. Both call the same Rust and get the same results.

The example is **self-contained**: everything it builds and tests is inside
this directory. The one reference outside it is the `rustcall_julia_macros` path
dependency in `deps/sample_crate_pyo3/Cargo.toml`
(`../../../../deps/rustcall_julia_macros`, the proc-macro crate of this checkout),
because `rustcall_julia_macros` is not on crates.io yet.

## Layout: Rust and Julia in separate files

```
SampleCratePyO3.jl/
├── Project.toml
├── deps/
│   ├── build.jl                  # Pkg.build: cargo build (no `python` feature) + write the bindings
│   ├── sample_crate_pyo3/        # Rust: one implementation, two bindings
│   │   ├── Cargo.toml            #   pyo3 behind the optional `python` feature
│   │   ├── src/lib.rs            #   #[julia] + #[cfg_attr(feature = "python", pyo3::...)]
│   │   ├── main.py               #   the Python consumer (maturin develop --features python)
│   │   └── README.md             #   the pattern, and the migration from #[julia_pyo3]
│   └── lib/                      # the compiled library (git-ignored)
├── src/
│   ├── SampleCratePyO3.jl        # hand-written Julia
│   └── generated/Bindings.jl     # written by deps/build.jl (git-ignored)
└── test/runtests.jl              # Pkg.test — the same checks as main.py
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

and, from Python, after `maturin develop --features python` in `deps/sample_crate_pyo3`:

```python
import sample_crate_pyo3 as m
m.add(2, 3)                  # 5
p = m.Point(3.0, 4.0)
p.distance_from_origin()     # 5.0
```

Same names, same results; `test/runtests.jl` and `main.py` make the same
assertions.

## Notes

- How the two attribute sets compose on one item is documented in [`deps/sample_crate_pyo3/README.md`](./deps/sample_crate_pyo3/README.md) and in RustCall's `docs/src/pyo3.md`.
- `deps/build.jl` is `RustCall.write_bindings_to_file(crate, "src/generated/Bindings.jl"; relative_lib_path = "../../deps/lib")`; see `../SampleCrate.jl/README.md` for the workflow.
- RustCall's test suite uses its own copy of this crate, `test/fixtures/sample_crate_pyo3`; this example does not depend on it.
