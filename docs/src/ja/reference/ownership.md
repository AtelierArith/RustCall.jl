<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../../en/reference/ownership.md. -->
# [型・メモリ・所有権](@id Types,-memory-and-ownership)

Julia のラッパー型（`RustResult`、`RustOption`、`RustBox`、`RustRc`、`RustArc`、`RustVec`、`RustSlice`、`RustPtr`、`RustRef`、`RustString`、`RustStr`）と操作、Rust ヘルパー（`deps/rustcall_helpers/`）による所有権操作、`#[julia]` 構造体の生成型を扱います。使い方は[構造体の対応付け](../struct_mapping.md)を参照してください。

## [ラッパー型（`src/ffi/types.jl`）](@id Wrapper-types-(src/ffi/types.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "ffi", "types.jl")]
```

## [メモリと所有権（`src/ffi/memory.jl`）](@id Memory-and-ownership-(src/ffi/memory.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "ffi", "memory.jl")]
```

## [`#[julia]` 構造体（`src/ffi/structs.jl`）](@id [julia]-structs-(src/ffi/structs.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "ffi", "structs.jl")]
```
