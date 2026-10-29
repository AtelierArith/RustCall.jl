# Compiler and codegen

What the [front doors](compilation.md) run: the `rustc` invocation, the JSON
reader for Cargo's machine-readable output, and the `ccall` expressions
generated from the [FFI manifest](manifest.md).

## Compiler (`src/build/compiler.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "build", "compiler.jl")]
```

## Reading Cargo's JSON (`src/build/json.jl`)

`cargo metadata` and `--message-format=json` output, read as data.

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "build", "json.jl")]
```

## Code generation (`src/ffi/codegen.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "ffi", "codegen.jl")]
```

## Names the generated code uses (`src/ffi/emitted_names.jl`)

A generated module binds the crate's items under their own names, so the code
it emits reaches Base, Core, RustCall and PythonCall only through names no Rust
identifier can spell: a `GlobalRef` in `@rust_crate` and the PyO3 host, a
`rustcall′Base` / `rustcall′RustCall` alias in a file written by
`write_bindings_to_file` (#528).

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "ffi", "emitted_names.jl")]
```
