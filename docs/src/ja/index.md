<!-- Translation source: dd84d124; English counterpart: ../en/index.md. This is a localized introduction. -->
# [RustCall.jl 日本語ドキュメント](@id home)

RustCall.jl は、Julia から Rust の関数を呼び出すためのパッケージです。
Julia のコードに Rust を埋め込み、数値・文字列・配列・オブジェクトを扱えます。

## はじめる

Julia 1.12 以降が必要です。

```julia
using Pkg
Pkg.add("RustCall")
```

RustCall は RustToolChain.jl を通して Rust のコンパイラを取得します。
`PATH` に `rustc` と `cargo` があればそれらを使用し、なければツールチェーンを
ダウンロードします。Windows では MSVC のビルドツールも必要です。

[チュートリアル](tutorial.md)で最初の関数を実行してください。
問題が起きた場合は[トラブルシューティング](troubleshooting.md)を参照してください。

## 読み進める

- [Julia 利用者のための Rust 入門（英語）](rust_primer.md)
- [安全な Rust と Julia の連携（英語）](integration_guide.md)
- [型と FFI の契約（英語）](type_contract.md)
- [外部クレートの利用（英語）](crate_bindings.md)
- [API リファレンス](api.md)

## 翻訳について

英語版を原文として、日本語版を段階的に整備しています。
未翻訳ページは冒頭に案内を表示し、同じバージョンの英語原文を掲載します。
API の docstring は英語版と共通です。ページ上部のリンクで言語を切り替えられます。
