# Compiler and codegen

What the [front doors](compilation.md) run: the `rustc` invocation, the
compiler's diagnostics read as data, and the `ccall` expressions generated from
the [FFI manifest](manifest.md).

## Compiler (`src/compiler.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "compiler.jl")]
```

## rustc diagnostics (`src/rustc_json.jl`)

`rustc --error-format=json` output, read as data. This is what lets `@irust`
ask the compiler for a snippet's type instead of guessing it from the source
([#348](https://github.com/AtelierArith/RustCall.jl/issues/348)).

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "rustc_json.jl")]
```

## Code generation (`src/codegen.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "codegen.jl")]
```
