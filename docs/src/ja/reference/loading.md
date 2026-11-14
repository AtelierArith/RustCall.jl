<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../../en/reference/loading.md. -->
# [読み込みポリシー](@id Load-policy)

成果物を開く・登録する・退役させる・アンロードする唯一の経路です（`src/loading/loadpolicy.jl`、#277）。例外型は[エラー](errors.md)を参照してください。

## [読み込みと生存期間](@id Loading-and-lifetime)

利用者向け API は次のとおりです。

- `RustCall.unload_library(name; close = false)` / `RustCall.unload_all_libraries(; close = false)`：登録情報を削除します。実行中の呼び出しがあり得るため、既定ではイメージをマップしたままにします。`close = true` は実行中でないことを呼び出し側が保証して回収します。
- `RustCall.retired_handles()` / `RustCall.retired_handles(name)`：登録から外れ、まだマップされているイメージを調べます。
- `RustCall.list_loaded_libraries()`：`@rust_crate` を含む登録済みライブラリ名を返します。
- `RustCall.RustPanicError`：FFI 境界で捕捉した Rust の `panic!`（[エラー](errors.md)）。
- `RustCall.finalizer_failure_count()`：finalizer から呼んだ Rust デストラクタの失敗数です。0以外ならオブジェクトがリークしています。

保証の詳細は[パニック・可視性・生存期間](../panics.md)を参照してください。

## [読み込みポリシー（`src/loading/loadpolicy.jl`）](@id Load-policy-(src/loading/loadpolicy.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "loading", "loadpolicy.jl")]
```
