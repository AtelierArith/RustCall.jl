# PyO3 crates

The wrapper crate RustCall builds around a PyO3 extension module so that its
`#[pyfunction]`s and `#[pymethods]` can be called from Julia, the link plan
that finds the Python runtime, and the skip reasons a scan reports. See
[PyO3 Crates](../pyo3.md) for the user-facing guide.

## PyO3 wrapper crates (`src/pyo3.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "pyo3.jl")]
```
