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

## Names the generated code uses (`src/emitted_names.jl`)

A generated module binds the crate's items under their own names, so the code
it emits reaches Base, Core, RustCall and PythonCall only through names no Rust
identifier can spell: a `GlobalRef` in `@rust_crate` and the PyO3 host, a
`rustcall′Base` / `rustcall′RustCall` alias in a file written by
`write_bindings_to_file` (#528).

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "emitted_names.jl")]
```
