<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/tutorial.md. -->
# [チュートリアル](@id tutorial)

空の Julia セッションから、数値・文字列・配列・エラー・オブジェクトを扱う Rust 関数を呼ぶまでを説明します。Julia の知識だけで読み進められます。不明な Rust 構文は [Julia 利用者のための Rust 入門](rust_primer.md)を参照してください。

このページの例はドキュメントのビルド時に実行されます。掲載した出力は実際の結果です。

## [始める前に](@id Before-you-start)

```julia
using Pkg
Pkg.add("RustCall")
```

Julia 1.12 以降が必要です。Rust の事前インストールは不要で、`PATH` 上の `rustc` / `cargo` を使い、なければ [RustToolChain.jl](https://github.com/AtelierArith/RustToolChain.jl) が取得します。Windows では MSVC のリンカーも必要です（[Windows ガイド](platforms/windows.md)）。

準備ができているか確認します。

```@example tutorial
using RustCall
RustCall.check_toolchain().ok
```

`false` の場合は `RustCall.check_toolchain().problems` と[トラブルシューティング](troubleshooting.md)を確認してください。

## [最初の Rust 関数](@id Your-first-Rust-function)

```@example tutorial
rust"""
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

add(10, 20)
```

これだけで次の処理が完了します。

1. Julia の文字列マクロ `rust"""..."""` がソースを Rust コンパイラへ渡し、共有ライブラリを生成してセッションへ読み込みます。
2. `#[julia]` を付けた `add` と同名の Julia 関数を現在のモジュールに定義します。
3. 通常の Julia 呼び出し `add(10, 20)` の引数を `i32` に変換し、結果を `Int32` として受け取ります。

`fn` は関数定義、`a: i32` は32ビット整数の引数、`-> i32` は戻り値型です。末尾のセミコロンなしの式を返します。

最初は `rustc` の実行に1秒程度かかります。結果をディスクに保存するため、次のセッションでは同じブロックをほぼ即座に読み込めます。

### [引数は厳密に変換](@id Arguments-are-converted,-strictly)

生成関数は宣言された Rust 型へ正確に変換できる値だけを受け入れます。それ以外は Rust を呼ぶ前に Julia 側で拒否します。

```@example tutorial
typeof(add(10, 20))
```


```@example tutorial
try
    add(2^40, 1)          # does not fit in an i32
catch err
    sprint(showerror, err)
end
```

## [数値](@id Numbers)

固定幅の数値型が対応します。`i32` ↔ `Int32`、`i64` ↔ `Int64`、`u64` ↔ `UInt64`、`f64` ↔ `Float64`、`bool` ↔ `Bool`、長さと添字に使う `usize` ↔ `UInt` です。完全な表は[入門](rust_primer.md#Types)を参照してください。

1つのブロックに複数の関数を定義できます。

```@example tutorial
rust"""
#[julia]
fn sum_of_squares(n: u64) -> u64 {
    let mut total = 0;
    for i in 1..=n {
        total += i * i;
    }
    total
}

#[julia]
fn hypot2(x: f64, y: f64) -> f64 {
    (x * x + y * y).sqrt()
}

#[julia]
fn is_even(n: i64) -> bool {
    n % 2 == 0
}
"""

sum_of_squares(10), hypot2(3.0, 4.0), is_even(42)
```

この例の構文は次のとおりです。

- `let mut total = 0;` は再代入できる変数です。`mut` がなければ再代入できません。
- `1..=n` は Julia の `1:n` と同じ両端を含む範囲です。`1..n` は `n - 1` で終わります。
- `(…).sqrt()` は `f64` のメソッド呼び出しです。

`sum_of_squares` の戻り値 `UInt64` は16進数で表示されます（`0x0000000000000181` は385）。通常の `Int` にするには Rust の戻り値を `i64` にします。

## [文字列](@id Strings)

引数に借用した UTF-8 文字列 `&str`、戻り値に所有する `String` を使います。Julia 側はいずれも `String` です。

```@example tutorial
rust"""
#[julia]
fn greet(name: &str) -> String {
    format!("Hello, {name}!")
}

#[julia]
fn count_chars(s: &str) -> usize {
    s.chars().count()
}
"""

greet("Julia"), count_chars("世界")
```

`format!` は文字列生成・補間で、`{name}` が変数を挿入します。引数は再エンコードせず渡し、戻り値は新しい Julia `String` にコピーしてから Rust 側の領域を解放します。

## [配列](@id Arrays)

Rust のスライス `&[T]` は連続メモリのポインタと長さです。`#[julia]` 関数は Julia の `Vector` をコピーせず参照します。`&mut [T]` の書き込みは元の配列に反映されます。

```@example tutorial
rust"""
#[julia]
fn mean(xs: &[f64]) -> f64 {
    xs.iter().sum::<f64>() / xs.len() as f64
}

#[julia]
fn scale(xs: &mut [f64], factor: f64) {
    for x in xs.iter_mut() {
        *x *= factor;
    }
}
"""

v = [1.0, 2.0, 3.0]
m = mean(v)
scale(v, 10.0)
m, v
```

`xs.iter()` は要素の反復子、`xs.len()` は長さ（`usize` なので `as f64` で変換）、`*x` は可変参照先への書き込みです。

メモリを共有するため要素型の完全一致が必要です。`Vector{Int}` を `Float64` に暗黙変換しません。

```@example tutorial
try
    mean([1, 2, 3])
catch err
    sprint(showerror, err)
end
```

ビュー、別名参照、多次元データの規則は [Julia 配列を Rust のスライスとして渡す](tutorial_new_features.md#Julia-arrays-as-Rust-slices)を参照してください。

## [エラー](@id Errors)

Rust は通常、予想される失敗を例外にしません。`Result<T, E>` は `Ok(value)` または `Err(error)`、値がない場合の `Option<T>` は `Some(value)` または `None` です。

```@example tutorial
rust"""
#[julia]
fn safe_div(a: i32, b: i32) -> Result<i32, String> {
    if b == 0 {
        Err("division by zero".to_string())
    } else {
        Ok(a / b)
    }
}

#[julia]
fn first_positive(xs: &[i64]) -> Option<i64> {
    xs.iter().copied().find(|x| *x > 0)
}
"""

ok  = safe_div(10, 2)
err = safe_div(1, 0)
ok, err
```

Julia には `RustCall.RustResult` / `RustCall.RustOption` として届きます。マクロ以外は export しないため、補助関数には `RustCall.` を付けます（または `using RustCall: unwrap, is_ok` で読み込みます）。

```@example tutorial
RustCall.is_ok(ok), RustCall.unwrap(ok), RustCall.is_err(err), err.value
```


```@example tutorial
RustCall.unwrap_or(err, Int32(-1))     # a default instead of the error
```

Julia 流に扱うには `Err` を例外に変換できます。

```@example tutorial
try
    RustCall.result_to_exception(err)
catch e
    sprint(showerror, e)
end
```

`Option` も同様です。

```@example tutorial
some = first_positive([-1, 0, 7])
none = first_positive([-1])
RustCall.is_some(some), RustCall.unwrap(some), RustCall.is_none(none), RustCall.unwrap_or(none, 0)
```

Rust の `|x| *x > 0` は Julia の `x -> x > 0` に似たクロージャです。

### [パニック](@id Panics)

範囲外添字、整数のゼロ除算、`panic!` などはパニックを起こします。`#[julia]` 関数内なら境界で捕捉し、Julia の例外として報告します。

```@example tutorial
rust"""
#[julia]
fn checked_sqrt(x: f64) -> f64 {
    if x < 0.0 {
        panic!("sqrt of a negative number: {}", x);
    }
    x.sqrt()
}
"""

try
    checked_sqrt(-1.0)
catch e
    sprint(showerror, e)
end
```

呼び出し側が処理すべき失敗には `Result`、バグにはパニックを使います。詳細は[パニック・可視性・生存期間](panics.md)を参照してください。

## [オブジェクト](@id Objects)

`struct` に `#[julia]` を付けると Julia 型が生成され、`impl` 内の関数も Julia 関数になります。

```@example tutorial
rust"""
#[julia]
pub struct Counter {
    value: i32,
}

impl Counter {
    pub fn new(initial: i32) -> Self {
        Self { value: initial }
    }

    pub fn increment(&mut self) {
        self.value += 1;
    }

    pub fn current(&self) -> i32 {
        self.value
    }
}
"""

c = Counter(0)        # calls Counter::new
increment(c)
increment(c)
current(c)
```

対応は次のとおりです。

| Rust | Julia |
|------|-------|
| `Counter::new(0)`（`Self` を返す関数） | `Counter(0)` |
| `c.increment()`（`&mut self`） | `increment(c)` |
| `c.current()`（`&self`） | `current(c)` |
| フィールド `value` | 読み書きできる `c.value` |

```@example tutorial
c.value = 10
current(c)
```

データは Rust 側にあり、Julia の `Counter` はそのポインタを保持します。GC が Julia オブジェクトを回収すると Rust の値も破棄されるため、手動解放は不要です。

!!! note "メソッドは通常の Julia 関数"
    `increment` や `current` は現在のモジュールに定義されます。`get`、`length`、`show` という Rust メソッドも `Base` の拡張ではなく新しい関数になります。同じモジュールで使う `Base` の名前と衝突しない名前を選んでください。

静的メソッド、`Result` を返すメソッド、ジェネリック構造体、`Clone` は[構造体の対応付け](struct_mapping.md)を参照してください。

## [crates.io の利用](@id Using-crates-from-crates.io)

Rust のレジストリ [crates.io](https://crates.io) のクレートを使うには、先頭付近に `// cargo-deps:` を書きます。

```julia
rust"""
// cargo-deps: rand = "0.8"

use rand::Rng;

#[julia]
fn roll_die() -> i32 {
    rand::thread_rng().gen_range(1..=6)
}
"""

roll_die()
```

`rustc` の代わりに Cargo が依存関係を取得してビルドします。最初はネットワーク接続が必要で時間がかかりますが、結果は保存されます。

## [手動で使う `extern "C"` と `@rust`](@id The-manual-way:-extern-"C"-and-@rust)

`#[julia]` が自動化している従来の公開方法を直接使うこともできます。

```@example tutorial
rust"""
#[no_mangle]
pub extern "C" fn multiply(a: i32, b: i32) -> i32 {
    a * b
}
"""

@rust multiply(Int32(5), Int32(7))::Int32
```

- `extern "C"` で C 呼び出し規約を選び、`#[no_mangle]` で `multiply` の名前を残します（[両方が必要な理由](rust_primer.md#What-makes-a-Rust-function-callable-from-another-language)）。
- Julia 関数は生成しません。`@rust name(args...)::T` がライブラリ内のシンボルを検索して呼びます。
- 自動変換はありません。`5` ではなく `Int32(5)` のように正確な型を渡します。

`::Int32` は Rust ソースから得た型と照合し、不一致をエラーにします。

```@example tutorial
try
    @rust multiply(Int32(5), Int32(7))::Float64
catch e
    first(sprint(showerror, e), 110) * "…"
end
```

型注釈を省略すると動的解決となり大幅に遅くなるため、付けてください。

| | `#[julia]` | `#[no_mangle] extern "C"` + `@rust` |
|-|------------|-------------------------------------|
| Julia 関数の生成 | あり | なし。`@rust` で呼ぶ |
| 文字列・スライス・`Result`・`Option`・構造体 | 対応 | C 型と生ポインタのみ |
| 引数変換（`10` → `i32`） | あり | なし |
| パニックを Julia 例外に変換 | あり | **なし。プロセスが異常終了** |
| 用途 | 通常はこちら | 既存の C 形式の Rust または ABI の完全制御 |

手書きの `extern "C"` には C 互換型だけを使います。文字列なら NUL 終端バイト列のポインタを渡し、`unsafe` Rust で復号します。

```@example tutorial
rust"""
#[no_mangle]
pub extern "C" fn string_length(s: *const u8) -> u32 {
    let c_str = unsafe { std::ffi::CStr::from_ptr(s as *const i8) };
    c_str.to_bytes().len() as u32
}
"""

@rust string_length("世界")::UInt32      # bytes, not characters
```

こうした作業を `#[julia]` は自動で行います。

## [最初に知っておきたいこと](@id Things-worth-knowing-early)

**1ブロックが1ライブラリ**です。異なるブロックの Rust 関数同士は直接呼べません。`#[julia]` 構造体を取る関数も、その構造体と同じブロックに定義します。

**編集と再評価**：変更のないブロックは同じライブラリを再利用します。変更すると別ライブラリになり、古いライブラリと公開名が重複する場合は曖昧な解決をせず拒否します。

```@example tutorial
lib = rust"""
#[julia]
fn answer() -> i32 { 41 }
"""

try
    @eval rust"""
    #[julia]
    fn answer() -> i32 { 42 }
    """
catch e
    first(split(sprint(showerror, e), '\n'))
end
```

診断に削除すべきライブラリ名が出ます。`rust"""` の評価結果もその名前なので、上の `lib` のように保存できます。古いライブラリをアンロードして再評価します。

```@example tutorial
RustCall.unload_library(lib)
rust"""
#[julia]
fn answer() -> i32 { 42 }
"""

answer()
```

実際のクレートで編集・ビルド・実行を繰り返すには[ホットリロード](hot_reload.md)を使えます。

**置く場所**：ブロックはモジュールやスクリプトのトップレベルに置きます。関数本体内では定義がローカルになるため避けてください。

**Rust エディション**：`// cargo-deps:` がないブロックは `rustc` の既定エディションで直接コンパイルします。`panic!("{x}")` のような新しい構文には `panic!("{}", x)` と明示的に引数を書く必要があります。`format!("{x}")` はどちらでも使えます。

**キャッシュ**：Julia の scratch 領域に保存しセッション間で共有します。ソース、コンパイラ、依存関係が変わると再ビルドします。

```@example tutorial
RustCall.get_cache_size() > 0
```

`RustCall.clear_cache()` で削除できます。通常の問題解決の第一手ではありませんが、安全に実行できます。

**コンパイル失敗**：`RustCall.CompilationError` に Rust の診断を表示します。`help:` 行に修正案があります。[よくあるエラー](rust_primer.md#Common-first-errors)も参照してください。

## [パッケージで使う](@id Using-Rust-in-a-package)

パッケージのモジュール内でも同様に使え、プリコンパイルできます。大きなコードは `Cargo.toml` を持つクレートに分け、`#[julia]` を付けて Julia から読み込みます。

```julia
module MyPackage
using RustCall
@rust_crate joinpath(@__DIR__, "..", "deps", "my_crate") submodule = "Bindings"
end
```

[外部クレートのバインディング](crate_bindings.md)が手順、[プリコンパイル](precompilation.md)がパッケージでの動作、[安全な Rust/Julia 連携](integration_guide.md)がプロジェクト構成を説明します。

## [次に読むページ](@id Where-to-go-next)

- [v0.9 と v0.10 の新機能](tutorial_new_features.md)：失敗し得るコンストラクタ、オブジェクトと省略可能な引数の借用、スライス。
- [使用例](examples.md)：より長い実装例。
- [FFI の型契約](type_contract.md)：境界を通せる型。
- [ジェネリクス](generics.md)、[コールバック](callbacks.md)、[ホットリロード](hot_reload.md)。
- [RustCall が Rust を呼ぶ仕組み](internals.md)：内部構造と開発者向けの説明。
