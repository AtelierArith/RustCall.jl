<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/tutorial_new_features.md. -->
# [チュートリアル：v0.9 と v0.10 の新機能](@id Tutorial:-What's-New-in-v0.9-and-v0.10)

v0.9.1 から v0.10.0 の新機能を実行可能な例で説明します。[チュートリアル](tutorial.md)で `rust"""..."""` 内の `#[julia]` 関数の使い方を学んでからお読みください。

| 機能 | 導入バージョン | 説明 |
|:--|:--|:--|
| 失敗し得るコンストラクタ（`fn new(..) -> Result<Self, E>`） | v0.9.1 | [コンストラクタ](#Fallible-constructors) |
| Rust オブジェクトの参照渡し（`&T`, `&mut T`） | v0.9.2 | [オブジェクトの借用](#Borrowing-Rust-objects) |
| 新しいオブジェクトを返すメソッド（`fn f(&self) -> Result<Self, E>`） | v0.9.2 | [新しいオブジェクトを返すメソッド](#Methods-that-return-a-new-object) |
| 省略可能な借用（`Option<&T>`, `Option<&mut T>`） | v0.10.0 | [省略可能な借用](#Optional-borrows) |
| Julia 配列のスライス渡し（`&[T]`, `&mut [T]`） | v0.10.0 | [配列の借用](#Julia-arrays-as-Rust-slices) |
| ポインタと長さの API 用の一時コピー（`with_numeric_buffer`） | v0.9.1 | [一時数値バッファ](#Staged-numeric-buffers) |
| 依存先のジェネリック型の具体化（`generate_crate_instances`） | v0.9.1、v0.10.0 で合成に対応 | [ジェネリック型の具体化](#Concrete-instances-of-a-generic-crate-type) |

最後の小さな Cargo ワークスペース以外はインラインブロックです。同じシグネチャは `@rust_crate` で読み込む `#[julia]` クレートと `write_bindings_to_file` でも使えます。

## [始める前に](@id Before-you-start)

- **更新後は再ビルド**：マイナー更新でマニフェストのスキーマが変わります（v0.10.x は `0.10`）。旧 extractor は拒否されるため `Pkg.build("RustCall")` を実行します。
- **マクロクレートも更新**：新しい引数・戻り値の形式には対応する生成側が必要です。v0.10.0 は `rustcall_julia_macros = "0.7"`（スライス、省略可能な借用、所有する戻り値の合成）、v0.9.2 は `"0.6"`（オブジェクトの借用と `Result<Self, E>` メソッド）、v0.9.1 は `"0.5"`（失敗し得るコンストラクタ）を使います。バインディングは生成側の公開マーカーを検査し、古いライブラリを呼ぶ前に再ビルドを案内します。インラインブロックでは RustCall 自身が生成するため不要です。
- **保存済みバインディングを再生成**：異なるマイナーバージョンで保存したファイルは再生成が必要です。

```@setup new_features
using RustCall
```

## [失敗し得るコンストラクタ](@id Fallible-constructors)

`Result<Self, E>` を返す静的メソッドは構造体のコンストラクタになります（v0.9.1、#559）。戻り値は `RustResult` で、`Ok` は新しい Julia オブジェクトを所有し、`Err` は割り当てをせずエラーを保持します。

```@example new_features
rust"""
#[julia]
pub struct Account { cents: i64 }

#[julia]
impl Account {
    pub fn new(cents: i64) -> Result<Self, String> {
        if cents < 0 {
            Err(format!("negative opening balance: {cents}"))
        } else {
            Ok(Self { cents })
        }
    }

    pub fn balance(&self) -> i64 { self.cents }
}
"""

opened = Account(100)
RustCall.is_ok(opened)
```


```@example new_features
acc = RustCall.unwrap(opened)
balance(acc)
```


```@example new_features
refused = Account(-5)
(RustCall.is_err(refused), refused.value)
```

コンストラクタ内のパニックも、通常の `#[julia]` 呼び出しと同じ `RustCall.RustPanicError` になります。

## [Rust オブジェクトの借用](@id Borrowing-Rust-objects)

`#[julia]` 構造体 `T` の `&T`、`&mut T`、`&Self` 引数には、その Julia ハンドルを渡します（v0.9.2、#565）。所有するポインタを渡すためコピーはありません。

```@example new_features
rust"""
#[julia]
pub struct Wallet { cents: i64 }

#[julia]
impl Wallet {
    pub fn new(cents: i64) -> Self { Self { cents } }
    pub fn cents(&self) -> i64 { self.cents }

    pub fn richer_than(&self, other: &Wallet) -> bool {
        self.cents > other.cents
    }

    pub fn take_from(&mut self, other: &mut Wallet, amount: i64) -> bool {
        if other.cents < amount {
            return false;
        }
        other.cents -= amount;
        self.cents += amount;
        true
    }
}

#[julia]
pub fn combined(a: &Wallet, b: &Wallet) -> i64 { a.cents + b.cents }
"""

alice, bob = Wallet(70), Wallet(30)
take_from(bob, alice, 10)
(cents(alice), cents(bob), richer_than(alice, bob), combined(alice, bob))
```

Rust を呼ぶ前に各ハンドルを検査します。

- シグネチャが指定する構造体のハンドルであること。他の構造体や整数は `ArgumentError` です。
- 生存していること。finalizer 実行済みの値は `RustError` です。
- 同じ呼び出しの他の借用と `&mut` が重複しないこと。`take_from(alice, alice, 1)` は `ArgumentError` ですが、共有借用だけの `combined(alice, alice)` は可能です。
- 呼び出し中は GC から保護するため、`combined(Wallet(1), Wallet(2))` の一時オブジェクトも安全です。

必須の `&T` / `&mut T` は `combined(alice, bob.ptr)` のような明示的 `Ptr{Cvoid}` も受け入れますが、**検査せず**渡します。配置・生存・別名参照は利用者の責任です。後述の省略可能な位置では生ポインタを受け入れません。

```@example new_features
try
    take_from(alice, alice, 1)
catch err
    sprint(showerror, err)
end
```

## [新しいオブジェクトを返すメソッド](@id Methods-that-return-a-new-object)

**レシーバーがある** `Result<Self, E>` メソッドは元の名前を保ち、独立した新しいオブジェクトを返します（v0.9.2、#564）。レシーバーは引き続き有効です。

```@example new_features
rust"""
#[julia]
pub struct Jar { beans: i64 }

#[julia]
impl Jar {
    pub fn new(beans: i64) -> Self { Self { beans } }
    pub fn beans(&self) -> i64 { self.beans }

    pub fn split_off(&mut self, amount: i64) -> Result<Self, String> {
        if amount > self.beans {
            return Err("not enough beans".to_string());
        }
        self.beans -= amount;
        Ok(Self { beans: amount })
    }
}

// Used in the next section, "Optional borrows".
#[julia]
pub fn total_beans(a: &Jar, b: Option<&Jar>) -> i64 {
    a.beans + b.map_or(0, |b| b.beans)
}

#[julia]
pub fn refill(target: &mut Jar, donor: Option<&mut Jar>) {
    if let Some(donor) = donor {
        target.beans += donor.beans;
        donor.beans = 0;
    }
}
"""

jar = Jar(100)
small = RustCall.unwrap(split_off(jar, 30))
(beans(jar), beans(small))
```


```@example new_features
split_off(jar, 1000).value
```

新しい値は独自の Rust 割り当てを所有し、`jar` とは独立して finalizer が解放します。

## [省略可能な借用](@id Optional-borrows)

`#[julia]` 構造体の `Option<&T>` / `Option<&mut T>` には、ハンドルか `nothing` を渡します（v0.10.0、#571）。ハンドルには必須の借用と同じ検査を行い、`nothing` だけが `None` を表します。

前の `Jar` ブロックにも次の2関数があります。

```rust
#[julia]
pub fn total_beans(a: &Jar, b: Option<&Jar>) -> i64 {
    a.beans + b.map_or(0, |b| b.beans)
}

#[julia]
pub fn refill(target: &mut Jar, donor: Option<&mut Jar>) {
    if let Some(donor) = donor {
        target.beans += donor.beans;
        donor.beans = 0;
    }
}
```


```@example new_features
(total_beans(jar, nothing), total_beans(jar, small))
```


```@example new_features
refill(jar, small)
(beans(jar), beans(small))
```

省略可能な位置では `C_NULL` を含め生ポインタは不可です。`nothing` を使ってください。

!!! note "借用する場所に構造体を宣言"
    各 `rust"""` は独立したライブラリなので、`Jar` を借用する関数は同じブロックに置きます。クレートでは型がどの `#[julia]` 構造体かを証明できる必要があります。`use`、`&crate::model::Jar` のような修飾パス、曖昧でない `use super::*` は使えますが、型エイリアスは使えません。詳しくは[モジュールの glob で取り込む借用対象](crate_bindings.md)を参照してください。

## [Julia 配列を Rust のスライスとして渡す](@id Julia-arrays-as-Rust-slices)

基本数値型 `T` の `&[T]` / `&mut [T]` は Julia 配列を直接借用します（v0.10.0、#570）。コピーはなく、可変スライスへの書き込みは元の配列に反映されます。

```@example new_features
rust"""
#[julia]
pub fn norm2(xs: &[f64]) -> f64 {
    xs.iter().map(|x| x * x).sum::<f64>().sqrt()
}

#[julia]
pub fn axpy(a: f64, x: &[f64], y: &mut [f64]) -> Result<(), String> {
    if x.len() != y.len() {
        return Err(format!("length mismatch: {} vs {}", x.len(), y.len()));
    }
    for (xi, yi) in x.iter().zip(y.iter_mut()) {
        *yi += a * xi;
    }
    Ok(())
}
"""

y = ones(3)
axpy(2.0, [1.0, 2.0, 3.0], y)
y
```


```@example new_features
norm2([3.0, 4.0])
```

行列の列のような連続ビューも借用できます。

```@example new_features
A = [1.0 2.0; 3.0 4.0]
norm2(@view A[:, 2])
```

呼び出し前に次を検査します。

- **要素型の完全一致**：`&[f64]` は `Float64` の領域だけを受け付けます。`norm2([1, 2])` は `ArgumentError` です。対応型は `f32`、`f64`、符号付き・符号なし8～64ビット整数、`isize` / `usize`（`Int` / `UInt`）、`num_complex::Complex<f32>` / `Complex<f64>`（`ComplexF32` / `ComplexF64`）です。
- **1次元の連続領域**：`Vector`、ストライド1のビュー、互換な `reinterpret` を受け付けます。行列、逆順・間引きビューは暗黙コピーせず拒否します。明示的にコピーするか[一時数値バッファ](#Staged-numeric-buffers)を使います。
- **可変な別名参照の禁止**：同じ呼び出しの別スライスと重なる `&mut [T]` は拒否します。

```@example new_features
try
    axpy(1.0, y, y)
catch err
    sprint(showerror, err)
end
```

利用者にも次の責任があります。

- 借用は Rust が戻るまでです。ポインタを保持せず、別タスクが同時に配列の長さや内容を変えないようにします。
- 可変領域を初期化してください。`Vector{T}(undef, n)` ではなく `zeros(T, n)` などを使います。
- ロールバックはありません。書き込み後に `Err` やパニックが発生しても変更は残ります。

検査を受けるには生成された Julia 関数 `axpy(...)` を呼びます。`@rust` / `ccall` によるシンボルの直接呼び出しは生の ABI で、これらを検査しません。

## [一時数値バッファ](@id Staged-numeric-buffers)

生ポインタと長さを取る API には `RustCall.with_numeric_buffer` を使えます（v0.9.1、#557）。非連続ビューを含む数値配列を整列した一時領域へコピーし、ポインタと長さをコールバックへ渡して、戻るまで保持します。

```@example new_features
rust"""
#[julia]
pub fn sum_raw(ptr: *const f64, len: usize) -> f64 {
    let xs = unsafe { std::slice::from_raw_parts(ptr, len) };
    xs.iter().sum()
}
"""

M = reshape(collect(1.0:6.0), 2, 3)
row = @view M[1, :]          # stride 2: not borrowable as a slice
RustCall.with_numeric_buffer(row; element_type = Float64) do ptr, len
    sum_raw(ptr, len)
end
```

書き込み時は `write = true` にすると正常終了後に元配列へコピーし直します。コールバックが例外を投げると反映しません。Rust 側を変更できるなら、コピーが不要で要素型も検査する `&[T]` / `&mut [T]` を優先します。ここでの `element_type` は Julia 配列との一致しか検査しないため、Rust のポインタ型との一致は利用者が保証します。

## [ジェネリックなクレート型の具体化](@id Concrete-instances-of-a-generic-crate-type)

クレート内の `#[julia]` はジェネリックにできません（インラインの[ジェネリクス](generics.md)とは異なります）。依存先の `Accumulator<T>` のような型は、`RustCall.generate_crate_instances` で指定した具体型を包む小さな窓口クレートを生成できます（v0.9.1、#558）。v0.10.0（#572）からは別のラッパーを引数で借用したり、戻り値にしたりできます。

`stats/` のクレートに次の型があるとします。

```rust
pub struct Accumulator<T> { total: T, count: u64 }

impl Accumulator<f64> {
    pub fn new(start: f64) -> Self { Self { total: start, count: 0 } }
    pub fn push(&mut self, x: f64) { self.total += x; self.count += 1; }
    pub fn mean(&self) -> f64 { self.total / self.count.max(1) as f64 }
    pub fn merge(&mut self, other: &Self) {
        self.total += other.total;
        self.count += other.count;
    }
    pub fn snapshot(&self) -> Summary {
        Summary { mean: self.mean(), count: self.count }
    }
    pub fn checked_snapshot(&self) -> Result<Summary, String> {
        if self.count == 0 { Err("no samples yet".into()) } else { Ok(self.snapshot()) }
    }
}

impl Accumulator<i64> {
    pub fn new(start: i64) -> Self { Self { total: start, count: 0 } }
    pub fn push(&mut self, x: i64) { self.total += x; self.count += 1; }
    pub fn total(&self) -> i64 { self.total }
}

pub struct Summary { pub mean: f64, pub count: u64 }

impl Summary {
    pub fn new(mean: f64, count: u64) -> Self { Self { mean, count } }
    pub fn mean(&self) -> f64 { self.mean }
    pub fn count(&self) -> u64 { self.count }
}
```

具体型とメソッドを宣言し、窓口のソースを書き出します。

```julia
using RustCall

empty = Pair{String,String}[]
instances = [
    (name = "FloatAcc", rust_type = "stats::Accumulator<f64>",
     constructor = (name = "new", args = ["start" => "f64"]),
     methods = [
        (name = "push", args = ["x" => "f64"], return_type = "()", mutable = true),
        (name = "mean", args = empty, return_type = "f64", mutable = false),
        # Borrow another declared wrapper (`other: &FloatAcc`).
        (name = "merge", args = ["other" => (wrapper = :FloatAcc,)],
         return_type = "()", mutable = true),
        # Return a value owned by another declared wrapper.
        (name = "snapshot", args = empty, return_wrapper = :Summary, mutable = false),
        (name = "checked_snapshot", args = empty, return_wrapper = :Summary,
         error_type = "String", mutable = false),
     ]),
    (name = "IntAcc", rust_type = "stats::Accumulator<i64>",
     constructor = (name = "new", args = ["start" => "i64"]),
     methods = [
        (name = "push", args = ["x" => "i64"], return_type = "()", mutable = true),
        (name = "total", args = empty, return_type = "i64", mutable = false),
     ]),
    (name = "Summary", rust_type = "stats::Summary",
     constructor = (name = "new", args = ["mean" => "f64", "count" => "u64"]),
     methods = [
        (name = "mean", args = empty, return_type = "f64", mutable = false),
        (name = "count", args = empty, return_type = "u64", mutable = false),
     ]),
]

mkpath("stats_facade/src")
write("stats_facade/src/lib.rs", RustCall.generate_crate_instances(instances))
```

生成結果は通常の `#[julia]` コードです。最初のラッパーは次のようになります。

```rust
#[julia]
pub struct FloatAcc { inner: stats::Accumulator<f64> }
#[julia]
impl FloatAcc {
    #[julia]
    pub fn new(start: f64) -> Self {
        Self { inner: <stats::Accumulator<f64>>::new(start) }
    }
    // ...
    #[julia]
    pub fn merge(&mut self, other: &FloatAcc) -> () {
        self.inner.merge(&other.inner)
    }
    #[julia]
    #[rustcall_owned_return(Summary)]
    pub fn snapshot(&self) -> Summary {
        Summary { inner: self.inner.snapshot() }
    }
    // ...
}
```

`Cargo.toml` は生成しないため自分で用意します。

```toml
# stats_facade/Cargo.toml
[package]
name = "stats_facade"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
stats = { path = "../stats" }
rustcall_julia_macros = "0.7"
```

通常の `#[julia]` クレートとして読み込みます。

```julia
S = @rust_crate "stats_facade"

a = S.FloatAcc(0.0)
S.push(a, 1.0); S.push(a, 3.0)
b = S.FloatAcc(0.0)
S.push(b, 5.0)
S.merge(a, b)
S.mean(a)                         # 3.0

s = S.snapshot(a)                 # a `Summary`, owned by Julia
(S.mean(s), S.count(s))           # (3.0, 0x0000000000000003)

S.checked_snapshot(S.FloatAcc(0.0)).value   # "no samples yet"

i = S.IntAcc(10)
S.push(i, 5)
S.total(i)                        # 15

S.merge(a, a)                     # ArgumentError: a `&mut` borrow may not alias
S.merge(a, i)                     # ArgumentError: expected a `FloatAcc` handle
```

注意点は次のとおりです。

- 全メソッドを明示的に宣言します。生成側は `stats` を調べず、型とシグネチャは Cargo が検査します。
- `return_wrapper` は戻り値の実体を所有するラッパー名（例では `stats::Summary` の `Summary`）です。`Result<Owner, E>` には `error_type` も指定します。ラッパーの前方参照も可能です。
- `expression = "self.inner.checked_snapshot()"` のような信頼済み式で Rust 呼び出しを置き換えられます。式はそのまま出力されます。
- `constructor = (name = "from_other", args = ["other" => (wrapper = :FloatAcc,)])` のように、コンストラクタでも他のラッパーを引数にできます。

## [関連ページ](@id Where-to-read-more)

- [外部クレートのバインディング](crate_bindings.md)：スライス、省略可能な所有対象、スコープ付きバッファ、具体化、マニフェストと生成側マーカーの詳細。
- [構造体の対応付け](struct_mapping.md)：`Result<Self, E>` のコンストラクタとメソッド。
- [パニック・可視性・生存期間](panics.md)：パニックや再読み込み中の借用。
- [変更履歴](https://github.com/AtelierArith/RustCall.jl/blob/main/CHANGELOG.md)：リリースごとの変更。
