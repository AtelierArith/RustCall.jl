# Compilation and codegen

The front doors — `rust"""..."""`, `@rust`, `@irust` — and the pipeline behind
them: the `rustc` invocation and the `ccall` expressions generated from the
[FFI manifest](manifest.md).

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

## Compiler (`src/compiler.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "compiler.jl")]
```

## Code generation (`src/codegen.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "codegen.jl")]
```
