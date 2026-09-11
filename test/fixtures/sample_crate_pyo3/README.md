# sample_crate_pyo3 (test fixture)

A test fixture of RustCall.jl: the dual-binding crate (`#[julia]` for Julia,
PyO3's own attributes for Python, pyo3 behind an optional `python` feature)
that `test/test_crate_bindings.jl` and `test/test_pyo3_link_plan.jl` scan,
build and load. It is **not** the example to copy: the runnable example is the
package [`examples/SampleCratePyO3.jl`](../../../examples/SampleCratePyO3.jl/),
which embeds its own copy of this crate under `deps/sample_crate_pyo3/` together
with the Python consumer `main.py` and the README that walks through the
pattern and the migration from the deprecated `#[julia_pyo3]`.

## Build and test the Rust alone

```bash
cd test/fixtures/sample_crate_pyo3
cargo build --release      # the Julia build: no `python` feature, no pyo3 in the graph
cargo test
```

## Dependencies

- `rustcall_julia_macros` (the `#[julia]` attribute), as a path dependency on
  `../../../deps/rustcall_julia_macros`.
- `pyo3`, optional, enabled only by the `python` feature.
