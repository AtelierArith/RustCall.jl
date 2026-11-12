<!-- Translation source: dd84d124; English counterpart: ../en/troubleshooting.md. This is a localized quick guide. -->
# [トラブルシューティング](@id troubleshooting)

## ツールチェーンを確認する

```julia
using RustCall
report = RustCall.check_toolchain()
report.ok
report.problems
```

RustCall は RustToolChain.jl にコンパイラの解決を依頼します。
`PATH` 上の Rust または自動ダウンロードしたツールチェーンのどちらも
実行できない場合は、診断結果の原因を確認してください。
初回ダウンロードではネットワーク接続と Julia depot への書き込み権限が必要です。
Windows のリンカーについては [Windows ガイド](platforms/windows.md)を参照してください。

## ネイティブライブラリのビルドに失敗する

```julia
using Pkg
Pkg.build("RustCall")
```

再ビルドしてエラーを確認します。Julia は 1.12 以降が必要です。

## 型や戻り値のエラー

Rust の引数・戻り値と Julia 側の型を確認してください。
[型対応表](type_contract.md)にない型は推測されません。
手動の FFI 呼び出しでは、たとえば `@rust f(x)::Int32` のように戻り値を指定できます。
通常は `#[julia]` を付けた関数を直接呼び出す方法から始めてください。

## メモリと所有権

所有権を持つラッパーを早期に解放する場合は `RustCall.drop!` を使用します。
同じ割り当てを複数の所有者へ渡してはいけません。
`RustCall.is_valid` はラッパーの状態を調べるだけで、任意のポインタの安全性を保証しません。

## 詳しいログを表示する

```sh
JULIA_DEBUG=RustCall julia
```

通常、キャッシュの手動削除は不要です。破損の調査や容量の回収が必要な場合は
`RustCall.clear_cache()` を利用できます。

このページは主な問題への日本語の案内です。詳しいエラーメッセージ別の対処は、
上部の English リンクから英語原文を参照してください。
