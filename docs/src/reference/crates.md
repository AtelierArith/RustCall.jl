# External crates and hot reload

`@rust_crate` bindings to an existing crate, and hot reload of a crate's
library while it is in use. See [External Crate Bindings](../crate_bindings.md)
for the user-facing guide; PyO3 extension modules are on [PyO3 crates](pyo3.md).

## Crate bindings (`src/crate_bindings.jl`)

The explicit-binding runtime contract is:

- `@rust_crate` and `RustCall.load_crate_bindings` return a `RustCall.CrateBindings` value.
- Property access preserves non-function bindings such as types and constants.
- Callable exported functions remain proxy-backed so calls stay world-age-safe.

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "crate_bindings.jl")]
```

## Hot reload (`src/hot_reload.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "hot_reload.jl")]
```
