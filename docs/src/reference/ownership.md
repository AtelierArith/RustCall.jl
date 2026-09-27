# Types, memory and ownership

The Julia-side wrapper types (`RustResult`, `RustOption`, `RustBox`, `RustRc`,
`RustArc`, `RustVec`, `RustSlice`, `RustPtr`, `RustRef`, `RustString`,
`RustStr`) and their operations, the ownership operations backed by the Rust
helpers library (`deps/rustcall_helpers/`), and the Julia types generated for
`#[julia]` structs. See [Struct Mapping](../struct_mapping.md) for the
user-facing guide.

## Wrapper types (`src/ffi/types.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "ffi", "types.jl")]
```

## Memory and ownership (`src/ffi/memory.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "ffi", "memory.jl")]
```

## `#[julia]` structs (`src/ffi/structs.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "ffi", "structs.jl")]
```
