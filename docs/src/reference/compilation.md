# Front doors: `rust"""..."""`, `@rust`, `@irust`

The front doors a user writes. The pipeline behind them — the `rustc`
invocation and the `ccall` expressions generated from the
[FFI manifest](manifest.md) — is on [Compiler and codegen](codegen.md).

## `rust"""..."""` and `@irust` (`src/ruststr.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "ruststr.jl")]
```

## `@rust` (`src/rustmacro.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "rustmacro.jl")]
```
