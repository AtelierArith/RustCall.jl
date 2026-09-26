# External crates

`@rust_crate` bindings to an existing crate. See
[External Crate Bindings](../crate_bindings.md) for the user-facing guide; hot
reload of a crate's library is on [Hot reload API](hot_reload.md) (guide:
[Hot Reload](../hot_reload.md)), and PyO3
extension modules are on [PyO3 crates](pyo3.md).

## Crate bindings

`src/crate_bindings.jl` includes the components below into the `RustCall`
module. Public names and the written-bindings format are shared across them.

The explicit-binding runtime contract is:

- `@rust_crate` and `RustCall.load_crate_bindings` return a `RustCall.CrateBindings` value.
- Property access preserves non-function bindings such as types and constants.
- Callable exported functions remain proxy-backed so calls stay world-age-safe.

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", file) for file in (
    "crate_scan.jl", "crate_build_env.jl", "crate_module_expr.jl",
    "crate_layout.jl", "crate_wrappers_expr.jl", "crate_build.jl",
    "crate_runtime.jl", "crate_write.jl", "crate_module_source.jl",
)]
```

## One environment per build (`src/build_env_snapshot.jl`)

Every crate build — `@rust_crate`, `write_bindings_to_file`, the PyO3 wrapper
and host paths, a hot reload — reads the environment through one
`RustCall.BuildEnvSnapshot` taken at its start (#481).

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "build_env_snapshot.jl")]
```
