# The FFI type contract

Rust-to-Julia type mapping lives in one place, `src/ffi_contract.jl`, and is
documented — with the generated supported-type matrix — under
[The FFI Type Contract](../type_contract.md).

`rusttype_to_julia` is a thin shim over that table. Two spellings changed
meaning when it stopped having a table of its own (#276): `"str"` is `RustStr`
rather than `Cstring`, and `"*const u8"` is `Ptr{UInt8}` rather than `Cstring`.
A Rust `str` is an unsized UTF-8 slice reached through a `(ptr, len)` fat
pointer and a `*const u8` is a plain byte pointer; neither is a NUL-terminated C
string.

The reverse direction still has a table of its own, since a Julia type does not
determine a Rust spelling:

```julia
# Julia to Rust type mapping
const JULIA_TO_RUST_TYPE_MAP = Dict{Type, String}(
    Int8 => "i8",
    Int16 => "i16",
    Int32 => "i32",
    Int64 => "i64",
    UInt8 => "u8",
    UInt16 => "u16",
    UInt32 => "u32",
    UInt64 => "u64",
    Float32 => "f32",
    Float64 => "f64",
    Bool => "bool",
    Cvoid => "()",
)
```

## Contract table and lookups (`src/ffi_contract.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "ffi_contract.jl")]
```

## Type translation (`src/typetranslation.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "typetranslation.jl")]
```
