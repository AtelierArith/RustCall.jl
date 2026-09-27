# Errors

The exception types RustCall raises. `RustCall.RustPanicError` is a Rust
`panic!` caught at the FFI boundary; see
[Panics, Visibility and Lifetime](../panics.md) for which panics are caught.

## Errors (`src/ffi/exceptions.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "ffi", "exceptions.jl")]
```
