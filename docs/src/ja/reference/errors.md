<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../../en/reference/errors.md. -->
# [エラー](@id Errors)

RustCall が送出する例外型です。`RustCall.RustPanicError` は FFI 境界で捕捉した Rust の `panic!` を表します。捕捉範囲は[パニック・可視性・生存期間](../panics.md)を参照してください。

## [エラー（`src/ffi/exceptions.jl`）](@id Errors-(src/ffi/exceptions.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "ffi", "exceptions.jl")]
```
