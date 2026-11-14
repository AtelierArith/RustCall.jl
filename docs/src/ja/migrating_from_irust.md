<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/migrating_from_irust.md. -->
# [`@irust` からの移行](@id Migrating-from-@irust)

!!! note "0.9.0 で削除"
    `@irust` と `irust"..."` は 0.8.0 で非推奨となり、0.9.0 で削除されました（[#538](https://github.com/AtelierArith/RustCall.jl/issues/538)）。使用すると ``UndefVarError: `@irust` not defined`` が発生します。

以前の計算はすべて `rust"""..."""` 内の `#[julia]` 関数に書き換えられます。

1. 断片を関数の**本体**にします。末尾の式が戻り値となり、文・ループ・`return` はそのまま使えます。
2. `$name`（または `arg1`、`arg2` など）を**型付き引数**にします。`Int64` → `i64`、`Int32` → `i32`、`Float64` → `f64`、`Bool` → `bool` など、渡した値に対応する Rust 型を書きます。
3. 計算結果の型を**戻り値型**として書きます。
4. トップレベルで一度定義し、以前の断片の位置から生成された Julia 関数を呼びます。

`@irust` は新しい断片ごとに何度も `rustc` を実行して戻り値型を実行時に決めていました。そのためスカラーしか扱えず、呼び出し元の型推論を妨げ、`$name` のテキスト置換が Rust 文字列内にも及びました。`#[julia]` 関数は一度コンパイルすれば型安定な呼び出しができ、`String`、スライス、`Result` / `Option`、`#[julia]` 構造体にも対応します。

以下では旧形式をコメントで示し、その後に置き換えを示します。`test/test_irust_migration.jl` が全置き換えを実行して結果を検証します。

**変数を取り込む式**。

```julia
# before (0.8 and earlier)
# compute_irust(x, y) = @irust("\$x * \$y + 10")
# compute_irust(Int32(3), Int32(4))   # 22

# after
rust"""
#[julia]
fn compute(x: i32, y: i32) -> i32 {
    x * y + 10
}
"""
compute(Int32(3), Int32(4))         # => 22
```

**変数を取り込まない式**（`irust"..."`）と**明示的な引数**（`arg1` など）。

```julia
# before (0.8 and earlier)
# irust"40 + 2"                     # 42
# @irust("arg1 * 2", x)             # 42

# after
rust"""
#[julia]
fn answer() -> i64 {
    40 + 2
}

#[julia]
fn twice(arg1: i64) -> i64 {
    arg1 * 2
}
"""
x = Int64(21)
answer()                            # => 42
twice(x)                            # => 42
```

**文とループ**。本体は変更不要です。

```julia
# before (0.8 and earlier)
# @irust("let mut s = 0i64; for i in 0..\$k { s += i; } s")   # 45

# after
rust"""
#[julia]
fn sum_below(k: i64) -> i64 {
    let mut s = 0i64;
    for i in 0..k {
        s += i;
    }
    s
}
"""
k = Int64(10)
sum_below(k)                        # => 45
```

**戻り値型**。以前は `rustc` に問い合わせていましたが、今は明示します。これが Julia の結果型になります。

```julia
# before (0.8 and earlier)
# @irust("\$x as f64")                       # 7.0  :: Float64
# @irust("if \$x > 0 { 1 } else { -1 }")     # 1    :: Int64
# @irust("\$f.is_finite()")                  # true :: Bool
# @irust("(\$f * \$f).sqrt()")               # 3.5  :: Float64

# after
rust"""
#[julia]
fn as_float(x: i64) -> f64 {
    x as f64
}

#[julia]
fn sign_of(x: i64) -> i64 {
    if x > 0 { 1 } else { -1 }
}

#[julia]
fn finite(f: f64) -> bool {
    f.is_finite()
}

#[julia]
fn magnitude(f: f64) -> f64 {
    (f * f).sqrt()
}
"""
x = Int64(7); f = 3.5
as_float(x)                         # => 7.0  :: Float64
sign_of(x)                          # => 1    :: Int64
finite(f)                           # => true :: Bool
magnitude(f)                        # => 3.5  :: Float64
```

断片内の補助関数 `fn` は同じブロックのトップレベル関数にします。`macro_rules!` のメタ変数用の `$$` は、置換しない `rust"""` では `$` と直接書きます。パニックは引き続き捕捉可能な `RustCall.RustPanicError` です（[パニック・可視性・生存期間](panics.md)）。

C ABI を直接使う場合は `#[julia]` の代わりに `#[no_mangle] pub extern "C"` と書き、`@rust name(args...)::T` で呼びます。
