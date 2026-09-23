# External crates

`@rust_crate` bindings to an existing crate. See
[External Crate Bindings](../crate_bindings.md) for the user-facing guide; hot
reload of a crate's library is on [Hot reload API](hot_reload.md) (guide:
[Hot Reload](../hot_reload.md)), and PyO3
extension modules are on [PyO3 crates](pyo3.md).

## Crate bindings (`src/crate_bindings.jl`)

The explicit-binding runtime contract is:

- `@rust_crate` and `RustCall.load_crate_bindings` return a `RustCall.CrateBindings` value.
- Property access preserves non-function bindings such as types and constants.
- Callable exported functions remain proxy-backed so calls stay world-age-safe.

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "crate_bindings.jl")]
```
