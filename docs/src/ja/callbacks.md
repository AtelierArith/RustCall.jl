<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/callbacks.md. -->
# [コールバック：Julia 関数を Rust に渡す](@id Callbacks:-passing-a-Julia-function-to-Rust)

`#[julia]` 関数やメソッドの **C ABI 関数ポインタ**引数には、クロージャを含む Julia 関数を渡せます（[#296](https://github.com/AtelierArith/RustCall.jl/issues/296)）。

```julia
rust"""
#[julia]
pub fn apply(f: extern "C" fn(i64) -> i64, x: i64) -> i64 { f(x) + 1 }

#[julia]
pub fn each(n: u32, visit: extern "C" fn(u32, f64)) {
    for i in 0..n { visit(i, i as f64 * 0.5) }
}
"""

apply(x -> 2x, 20)                 # 41
k = 10
apply(x -> x + k, 1)               # 12 — a closure over a local works
seen = Float64[]
each(4, (i, v) -> push!(seen, v))  # seen == [0.0, 0.5, 1.0, 1.5]
```

マニフェストがポインタのシグネチャ（`Arg.abi = "callback"`、`Arg.callback_args`、`Arg.callback_return`）を記録し、Julia 側は Rust 構文を解析せず、これに基づいて `@cfunction` を生成します（[#264](https://github.com/AtelierArith/RustCall.jl/issues/264)）。

引数・戻り値として使える型はラッパー生成時に決定します。各位置は、**単一スロットで値渡しまたは生ポインタとして渡せ、スロット型と Julia 型が一致する型**に限ります。数値基本型、`bool`、`usize` / `isize`、`*const T` / `*mut T`、戻り値の `()` が該当します。`&str`、`String`、スロットが `UInt32` である `char`、集成型、表にない型は、引数名を含む `RustError` で拒否します。

Rust ABI の `fn(..)` は Julia 関数を受け取れません。`extern "C"` または `unsafe extern "C"` を使います。コールバックは引数位置だけで対応し、戻り値やジェネリック関数では使えません。

次の3つの規則があります。

- **同期的な借用**：Rust は渡した呼び出しが戻るまでだけポインタを呼べます。ポインタはコールバック位置ごとの固定関数で、対応する Julia 関数は呼び出し中だけタスクローカルのスタックに保持します。これは全プラットフォームでクロージャ版 `@cfunction` が使えるわけではないためです。呼び出し後の実行は Rust 側のバグです。その場で例外を投げると Rust を越えて巻き戻すため、`RustError` を記録して戻り値のゼロ（ポインタなら `C_NULL`）を返し、同じタスクの次の保護された Rust 呼び出しで再送出します。登録ハンドラーや構造体内の `Box<dyn Fn>` として保持する用途には使わず、Julia オブジェクトの生存を自分で管理し、不透明なハンドルを渡してください。
- **同一スレッド**：呼び出し元と同じスレッドで実行してください。Rust が生成した Julia ランタイムに未登録のスレッドから `@cfunction` に入るとプロセスが異常終了します。型では区別できないため、Rust 実装者が守る必要があります。
- **Julia 例外を Rust のスタック越しに巻き戻さない**：生成トランポリンが例外を捕捉してタスクに保存し、戻り値のゼロを返します。Rust のフレームがなくなってから、ラッパーが同じ例外オブジェクトを呼び出し箇所で再送出します。ゼロ値が原因で Rust が起こしたパニックは消費し、原因である Julia 例外を優先します。1呼び出しでは最初の例外だけを保持します。[パニック](panics.md)の逆方向ですが、経路は分離されており、Rust パニックは `RustPanicError`、Julia 例外は元の例外として報告します。

`@rust_crate` と `write_bindings_to_file` も、クレートの `#[julia]` 項目に同じ `@cfunction` を生成します。Rust ラッパーはポインタをそのまま渡します。
