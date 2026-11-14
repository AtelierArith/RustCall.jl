<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../../en/reference/ffi_contract.md. -->
# [FFI の型契約](@id The-FFI-type-contract)

Rust → Julia の型対応は `src/ffi/ffi_contract.jl` に一元化されています。生成済みの対応表を含む説明は [FFI の型契約](../type_contract.md)を参照してください。

`rusttype_to_julia` はこの表を参照する薄い層です。独自の表を廃止した際（#276）、`"str"` は `Cstring` から `RustStr` へ、`"*const u8"` は `Cstring` から `Ptr{UInt8}` へ変更されました。Rust の `str` は `(ptr, len)` のファットポインタで参照する動的サイズの UTF-8 スライス、`*const u8` は単なるバイトポインタです。どちらも NUL 終端の C 文字列ではありません。

Julia 型から Rust 表記は一意に決まらないため、逆方向には独自の表が残っています。

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

## [契約の表と検索（`src/ffi/ffi_contract.jl`）](@id Contract-table-and-lookups-(src/ffi/ffi_contract.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "ffi", "ffi_contract.jl")]
```

## [型変換（`src/ffi/typetranslation.jl`）](@id Type-translation-(src/ffi/typetranslation.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "ffi", "typetranslation.jl")]
```
