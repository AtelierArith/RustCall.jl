<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/index.md. -->
# [RustCall.jl](@id home)

**RustCall.jl** は Julia の中に Rust を書き、Julia の関数のように呼べるパッケージです。Rust のコンパイル、実行中のセッションへの読み込み、引数と結果の変換を行います。[Cxx.jl](https://github.com/JuliaInterop/Cxx.jl) に着想を得ています。

> 面倒な言語間連携は、これでおしまい。🦀

```julia
using RustCall

rust"""
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

add(10, 20)  # => 30
```

Rust の予備知識や事前インストールは不要です。`PATH` にツールチェーンがなければ RustCall が取得します。

## [このマニュアルの対象読者](@id Who-this-manual-is-for)

Julia の知識を前提にしていますが、Rust の知識は必要ありません。

- **Rust が初めて**：[Julia 利用者のための Rust 入門](rust_primer.md)を約10分で読み、[チュートリアル](tutorial.md)へ進んでください。
- **Rust を知っている**：[チュートリアル](tutorial.md)から始めてください。
- **RustCall を使うパッケージを作る**：[安全な Rust/Julia 連携](integration_guide.md)と[外部クレートのバインディング](crate_bindings.md)を参照してください。
- **内部の仕組みや開発に関心がある**：[RustCall が Rust を呼ぶ仕組み](internals.md)を参照してください。

## [Julia から Rust を呼ぶ理由](@id Why-call-Rust-from-Julia)

- **Rust のエコシステムを再利用**：[crates.io](https://crates.io) のパーサー、コーデック、暗号、データ構造、数値カーネルを呼べます。
- **GC のない予測しやすい性能**：処理の中心となるループを Rust で実装し、コンパイラのメモリ安全性検査を利用できます。
- **ビルドシステムの保守が不要**：Makefile、手書きの `ccall` シグネチャ、別途のコンパイル操作は不要です。Rust ソースがインターフェースの基準になります。

## [インストール](@id Installation)

```julia
using Pkg
Pkg.add("RustCall")
```

必要なものは次のとおりです。

- Julia 1.12 以降。
- Rust ツールチェーン。**自分でインストールする必要はありません**。[RustToolChain.jl](https://github.com/AtelierArith/RustToolChain.jl) が `PATH` 上の `rustc` / `cargo` を使い、なければ Julia の Artifacts で独立したツールチェーンを取得します。Windows では別途 MSVC ビルドツールと Windows SDK が必要です。[Windows ガイド](platforms/windows.md)を参照してください。

[rustup.rs](https://rustup.rs/) での手動インストールも可能です。両方ある場合は `PATH` 上の `rustc` を優先します。

`Pkg.add` は必要な2つの小さなネイティブプログラムもビルドします。確認時や更新後に部品が見つからない場合は次を実行してください。

```julia
using RustCall
RustCall.check_toolchain()          # what was found, and any problems

using Pkg; Pkg.build("RustCall")    # rebuild the native components
```

## [3つの使い方](@id Three-ways-to-use-it)

同じモジュールで次の方法を併用できます。

| | 記述するもの | 呼び出し方 | 用途 |
|-|--------------|------------|------|
| **`rust"""` + `#[julia]`** | Julia ファイル内の通常の Rust 関数・構造体 | 自動生成された Julia 関数 | ほとんどの場合。まずはこちら |
| **`rust"""` + `@rust`** | 手書きの `#[no_mangle] extern "C"` 関数 | `@rust f(args...)::T` | 既存の C 形式の Rust や ABI の完全な制御 |
| **`@rust_crate`** | 独自のディレクトリと `Cargo.toml` を持ち、`#[julia]` を付けたクレート | 生成された Julia モジュール | 規模の大きい Rust コードやパッケージ |

### [1. `#[julia]` でインライン Rust を使う](@id 1.-Inline-Rust-with-#[julia])

関数や構造体に `#[julia]` を付けると、同名の Julia 関数や型が現在のモジュールに定義されます。

```julia
rust"""
#[julia]
fn greet(name: &str) -> String {
    format!("Hello, {name}!")
}

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

greet("Julia")        # => "Hello, Julia!"

counter = Counter(0)
increment(counter)
increment(counter)
current(counter)      # => 2
```

文字列、数値配列（Rust のスライス）、`Result`、`Option`、構造体を自動変換します。Rust のパニックは Julia の例外になります。[チュートリアル](tutorial.md)で順に説明します。

### [2. 手書きの `extern "C"` と `@rust`](@id 2.-Hand-written-extern-"C"-with-@rust)

従来の C ABI を使う場合は、自分で関数を公開し、`@rust` で呼びます。

```julia
rust"""
#[no_mangle]
pub extern "C" fn multiply(a: i32, b: i32) -> i32 {
    a * b
}
"""

@rust multiply(Int32(5), Int32(7))::Int32  # => 35
```

Julia 関数の生成や自動変換は行いません。Rust のシグネチャと正確に一致する型を渡してください。

### [3. `@rust_crate` で独立したクレートを使う](@id 3.-A-separate-crate-with-@rust_crate)

Rust コードが大きくなったら、専用のクレートに分けます。

```rust
// my_crate/src/lib.rs      (Cargo.toml depends on rustcall_julia_macros = "0.7")
use rustcall_julia_macros::julia;

#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[julia]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[julia]
impl Point {
    #[julia]
    pub fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }

    #[julia]
    pub fn distance(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
}
```


```julia
using RustCall

const MyCrate = @rust_crate "/path/to/my_crate"

MyCrate.add(1, 2)              # => 3
p = MyCrate.Point(3.0, 4.0)
MyCrate.distance(p)            # => 5.0
p.x                            # => 3.0
```

`@rust_crate` は Cargo でビルドし、バインディングの Julia モジュールを返します。[外部クレートのバインディング](crate_bindings.md)を参照してください。

### [インラインブロックで crates.io のクレートを使う](@id Crates-from-crates.io-in-an-inline-block)

`// cargo-deps:` コメントで依存関係を宣言すると、RustCall は Cargo を使ってビルドします。

```julia
rust"""
// cargo-deps: rand = "0.8"

use rand::Rng;

#[julia]
fn roll_die() -> i32 {
    rand::thread_rng().gen_range(1..=6)
}
"""

roll_die()  # => a number from 1 to 6
```

## [境界を通せる型](@id What-crosses-the-boundary)

| Rust | Julia |
|------|-------|
| `i8` … `i64`, `u8` … `u64` | `Int8` … `Int64`, `UInt8` … `UInt64` |
| `isize`, `usize` | `Int`, `UInt` |
| `f32`, `f64` | `Float32`, `Float64` |
| `bool`, `char` | `Bool`, `Char` |
| `()` | `Nothing` |
| `&str`, `String` | `String` |
| `&[T]`, `&mut [T]`（数値型 `T`） | `Vector{T}` をコピーせず借用 |
| `Result<T, E>` | `RustCall.RustResult{T, E}` |
| `Option<T>` | `RustCall.RustOption{T}` |
| `#[julia]` 構造体 | Rust 値のハンドルを保持する Julia 型 |
| `extern "C" fn(A...) -> R`（引数） | Julia 関数（[コールバック](callbacks.md)） |
| `*const T`, `*mut T` | `Ptr{T}` |

未対応型は配置を推測せず、型名を含むエラーで拒否します。正式な生成済み一覧は [FFI の型契約](type_contract.md)を参照してください。

## [マニュアルの案内](@id Finding-your-way-around)

**はじめに**

- [Julia 利用者のための Rust 入門](rust_primer.md)：必要な Rust の知識。
- [チュートリアル](tutorial.md)：数値・文字列・配列・エラー・オブジェクト。
- [v0.9 と v0.10 の新機能](tutorial_new_features.md)：オブジェクトの借用、失敗し得るコンストラクタ、スライス。
- [使用例](examples.md)：より長い実装例。

**利用ガイド**

- [安全な Rust/Julia 連携](integration_guide.md)：実際のプロジェクトの構成。
- [FFI の型契約](type_contract.md)、[構造体の対応付け](struct_mapping.md)、[ジェネリクス](generics.md)、[コールバック](callbacks.md)。
- [外部クレートのバインディング](crate_bindings.md)、[ホットリロード](hot_reload.md)、[PyO3 クレート](pyo3.md)、[プリコンパイル](precompilation.md)。
- [パニック・可視性・生存期間](panics.md)、[性能](performance.md)、[トラブルシューティング](troubleshooting.md)。
- [`@irust` からの移行](migrating_from_irust.md)：v0.8 以前のコードの更新。

**リファレンス**

- [API リファレンス](api.md)、[プロジェクトの状況](status.md)。

**開発者向け**

- [RustCall が Rust を呼ぶ仕組み](internals.md)：`rust"""` から `ccall` までの内部構造。
- [プロジェクトガイド](project_guide.md)：構成、テスト、リリース。
- [開発時の注意点](developer_pitfalls.md)、[Windows での開発](developer_windows.md)。

## [リポジトリ内の実行可能な例](@id Runnable-examples-in-the-repository)

[`examples/`](https://github.com/AtelierArith/RustCall.jl/tree/main/examples) の各ディレクトリは、独自のテストを持つ完全な Julia パッケージです。

- `MyExample.jl`：パッケージ内のインライン `rust"""`。
- `SampleCrate.jl`：同梱した Rust クレートと生成済みバインディングファイル。
- `RustCrateMacro.jl`：プリコンパイル中の `@rust_crate`。
- `SafeLedger.jl`：[安全な Rust/Julia 連携](integration_guide.md)の実装例。
- `SampleCratePyO3.jl`、`SampleCratePyO3Only.jl`、`Pyo3HostImport.jl`：Python 拡張でもあるクレート（[PyO3 クレート](pyo3.md)）。
- `pluto/hello.jl`：Pluto ノートブック。

実行方法は[プロジェクトガイド](project_guide.md)を参照してください。

説明ページは日本語で提供しています。API の docstring とコード例の出力は英語版と共通です。ページ上部で言語を切り替えられます。
