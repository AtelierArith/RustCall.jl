<!-- Translation source: dd84d124; English counterpart: ../en/tutorial.md. This is an introductory adaptation. -->
# [チュートリアル](@id tutorial)

Julia から Rust の関数を呼び出してみましょう。Rust の経験は必要ありません。
このページの実行例はドキュメントのビルド時にも検証されます。

## 準備

Julia 1.12 以降で `Pkg.add("RustCall")` を実行してください。
Rust は必要に応じて自動取得されます。Windows では
[MSVC ビルドツール](platforms/windows.md)も必要です。

```@example ja_tutorial
using RustCall
RustCall.check_toolchain().ok
```

`false` の場合は `RustCall.check_toolchain().problems` を確認し、
[トラブルシューティング](troubleshooting.md)を参照してください。

## 最初の Rust 関数

```@example ja_tutorial
rust"""
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""
add(10, 20)
```

`rust"""..."""` が Rust のコードをコンパイルし、共有ライブラリを読み込みます。
`#[julia]` を付けた関数は、Julia から通常の関数として呼び出せます。
引数は Rust の `i32` に変換され、戻り値は Julia の `Int32` になります。

Rust の `fn` は関数定義、`a: i32` は引数の型、`-> i32` は戻り値の型です。
末尾の式をセミコロンなしで書くと、その値が返ります。
最初の実行ではコンパイルが必要ですが、結果はディスクにキャッシュされます。

## 文字列を返す

```@example ja_tutorial
rust"""
#[julia]
fn greet(name: &str) -> String {
    format!("Hello, {}!", name)
}
"""
greet("Julia")
```

`&str` は借用した文字列、`String` は所有権を持つ文字列です。
RustCall が Julia と Rust の間の変換を処理します。

## [オブジェクト](@id Objects)

`#[julia]` を付けた構造体を公開すると、Julia から Rust 側のオブジェクトを
扱えます。公開するメソッドや所有権については[構造体のガイド](struct_mapping.md)を
参照してください。英語版チュートリアルには構築・更新・解放の実行例もあります。

## 次のステップ

このページは最初の操作に絞った日本語の入門です。
配列、エラー、構造体を含む詳しい解説は、上部の English リンクから
英語版チュートリアルを参照してください。
[ジェネリクス](generics.md)、[外部クレート](crate_bindings.md)、
[コールバック](callbacks.md)のガイドも利用できます（現在は英語原文）。
