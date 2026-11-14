<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/rust_primer.md. -->
# [Julia 利用者のための Rust 入門](@id Rust-for-Julia-Users)

Julia に慣れていて Rust は初めてという方のために、このマニュアルを読み、最初の関数を書くのに必要な構文を Julia の概念と対応させて説明します。Rust 全般を学ぶには、無料の公式書籍 [The Rust Programming Language](https://doc.rust-lang.org/book/) を参照してください。

## [Julia と対応させた用語](@id The-vocabulary,-in-Julia-terms)

| Rust | Julia で近いもの | 意味 |
|------|-----------------|------|
| `rustc` | `julia` のコンパイラ部分 | `.rs` ソースを事前にバイナリへコンパイルするコンパイラ |
| `cargo` | `Pkg` | 依存関係を取得し、`rustc` を実行するビルドツール兼パッケージマネージャー |
| クレート | パッケージ | ライブラリまたは実行ファイルとなるコンパイル単位 |
| `Cargo.toml` | `Project.toml` | 名前・バージョン・依存関係の宣言 |
| `Cargo.lock` | `Manifest.toml` | 解決済みの正確な依存バージョン |
| [crates.io](https://crates.io) | General レジストリ | 公開クレートの配布場所 |
| モジュール (`mod`) | `module` | クレート内の名前空間。パスは `a::b::c` と表記 |
| `cdylib` | `ccall` で呼ぶ `.so` / `.dylib` / `.dll` | C 互換の共有ライブラリ。RustCall がビルドして読み込む形式 |

自分でインストールする必要はありません。[RustToolChain.jl](https://github.com/AtelierArith/RustToolChain.jl) が `PATH` 上の `rustc` / `cargo` を使い、なければツールチェーンを取得します。

## [Rust 関数の読み方](@id Reading-a-Rust-function)

```rust
fn scaled_sum(xs: &[f64], factor: f64) -> f64 {
    let mut total = 0.0;
    for x in xs {
        total += x * factor;
    }
    total
}
```

Julia と比べながら読み解きます。

- `fn name(arg: Type, ...) -> ReturnType { ... }` が関数定義です。**各引数と戻り値の型を宣言**します。型指定のない Julia 引数や多重ディスパッチに相当する仕組みはなく、1つの名前が1つの関数を表します。
- `let total = 0.0;` は変数宣言です。**再代入には `let mut` が必要**で、通常の `let` への再代入はコンパイルエラーです。
- 文は `;` で終わります。**ブロック末尾のセミコロンなしの式が値**になります。最後の `total` を `total;` にすると値を返さなくなり、この関数はコンパイルに失敗します。
- `for x in xs { ... }` は反復です。`0..n` は `n` を含まず、`0..=n` は含みます。**添字は0始まり**で、先頭は `xs[0]` です。
- `//` はコメント、`#[...]` は直後の項目に付ける属性です。Julia 関数の前に置く `@inline` に似ています。
- `println!`、`format!`、`vec!`、`panic!` の `!` はマクロを表します。Julia の「引数を変更する」という慣習とは異なります。

Rust は事前コンパイルされるため、型エラーは実行前に検出されます。RustCall では `rust"""..."""` の評価時にコンパイルし、診断を `RustCall.CompilationError` として表示します。

## [型](@id Types)

Rust の基本型は固定サイズで、Julia の型に対応します。

| Rust | Julia | 備考 |
|------|-------|------|
| `i8`, `i16`, `i32`, `i64` | `Int8`, `Int16`, `Int32`, `Int64` | |
| `u8`, `u16`, `u32`, `u64` | `UInt8`, `UInt16`, `UInt32`, `UInt64` | |
| `isize`, `usize` | `Int`, `UInt` | ポインタ幅。長さと添字は `usize` |
| `f32`, `f64` | `Float32`, `Float64` | |
| `bool` | `Bool` | |
| `char` | `Char` | 4バイトの Unicode スカラー値 |
| `()` | `Nothing` | 値を返さない関数のユニット型 |
| `&str`（引数） | `String` | 借用した UTF-8 文字列 |
| `String`（戻り値） | `String` | 所有する UTF-8 文字列。Julia 側へコピー |
| `&[T]`, `&mut [T]` | `Vector{T}` | Julia 配列のメモリをコピーせず借用 |
| `Result<T, E>` | `RustCall.RustResult{T, E}` | [エラー](#Errors-are-values)を参照 |
| `Option<T>` | `RustCall.RustOption{T}` | |

特に次の違いに注意してください。

- **整数リテラルの既定型は `Int64` ではなく `i32`** です。周囲から型が決まらなければ `let n = 1;` は `i32` になります。型を指定するには `1i64` や `1_u64` と書きます。
- **数値型の暗黙変換はありません**。`x` が `f64` なら `x + 1` はコンパイルできず、`x + 1.0` と書きます。明示的変換は `n as f64`、`x as i32` です。

境界を通せる型の完全な一覧は、パッケージから生成する [FFI の型契約](type_contract.md)にあります。

## [所有権と借用](@id Ownership-and-borrowing)

Julia では参照がなくなると GC が値を回収します。Rust には GC がなく、**各値にはただ1つの所有者**がいます。所有者がスコープを抜けた瞬間に値を破棄（drop）し、コンパイラが後処理を挿入します。

所有権を渡さずに値を使わせる仕組みが借用です。

| 表記 | 読み方 | 意味 |
|------|--------|------|
| `T` | `T` 型の値 | 値渡しで所有権を呼び出し先へ**移動** |
| `&T` | `T` の共有参照 | 読み取り専用。同時に複数存在可能 |
| `&mut T` | `T` の可変参照 | 読み書き可能。同時に1つだけで、`&T` とも共存不可 |

コンパイラがこれらを検査します。`unsafe` を使わない Rust で解放後使用やデータ競合を防げるのはこのためです。値を変えるメソッドは `fn increment(&mut self)`、読み取りだけなら `fn get(&self)` と宣言します。

RustCall 利用時には次を意味します。

- **`&[f64]` や `&str` は呼び出し中だけ Julia の値を借用**します。`&mut [f64]` は配列を直接変更します。Rust は呼び出し後にポインタを保持してはいけません。
- **`#[julia]` 構造体の実体は Rust が所有し、Julia はハンドルを保持**します。Julia オブジェクトの finalizer が Rust の値を破棄するため、手動解放は不要です。
- **`Vec<T>` など所有権を持つヒープ型を直接境界へ渡しません**。引数には `&[T]` を使い、Rust で所有する `Vec` は `#[julia]` 構造体の内部に置きます。

`Box<T>` はヒープ値を所有するポインタ、`Rc<T>` / `Arc<T>` は参照カウント付きポインタです（`Arc` はスレッドセーフ）。Julia のラッパー `RustBox` / `RustRc` / `RustArc` は [API リファレンス](reference/ownership.md)を参照してください。通常は直接使う必要はありません。

## [構造体とメソッド](@id Structs-and-methods)

Julia はデータと振る舞いを分離し、多重ディスパッチでメソッドを選びます。Rust は `impl` ブロックで型に関数を関連付けます。

```rust
pub struct Counter {
    value: i32,
}

impl Counter {
    // No `self`: an "associated function", called as `Counter::new(0)`.
    pub fn new(initial: i32) -> Self {
        Self { value: initial }
    }

    // `&mut self`: may modify the object.
    pub fn increment(&mut self) {
        self.value += 1;
    }

    // `&self`: reads the object.
    pub fn get(&self) -> i32 {
        self.value
    }
}
```

- `Self` は `impl` の対象型で、この例では `Counter` です。
- `new` はキーワードではなく慣習です。Rust にコンストラクタ構文はなく、`Self` を返す関数がその役割を担います。
- Rust の `counter.increment()` は Julia では通常の関数 `increment(counter)` になります。生成されたコンストラクタは `Counter(0)` です。
- `pub` はモジュール外への公開を表します。既定では非公開です。

## [エラーも値](@id Errors-are-values)

Julia は例外を投げますが、Rust では通常、失敗も値として返します。

```rust
fn safe_div(a: i32, b: i32) -> Result<i32, String> {
    if b == 0 {
        Err("division by zero".to_string())
    } else {
        Ok(a / b)
    }
}
```

- `Result<T, E>` は `Ok(value)` または `Err(error)` で、呼び出し側が結果を確認します。
- `Option<T>` は `Some(value)` または `None` です。Julia の `Union{T, Nothing}` に近く、任意の型に null が紛れ込む仕組みではありません。
- Rust の `?` は「`Err` なら現在の関数から直ちに返し、成功なら `Ok` の中身を取り出す」という演算子です。

Julia では `RustCall.RustResult` / `RustCall.RustOption` となります。`RustCall.is_ok`、`RustCall.unwrap`、`RustCall.unwrap_or` などで調べ、`RustCall.result_to_exception` で例外に変換できます。[チュートリアル](tutorial.md)に例があります。

### [パニック](@id Panics)

パニックは範囲外添字、`None` への `unwrap()`、明示的な `panic!("...")` などによる回復不能エラーです。Julia の例外に近いものの、通常の Rust コードは捕捉を前提としません。

`#[julia]` 関数内のパニックは境界で捕捉され、メッセージ付きの `RustCall.RustPanicError` となります。[パニック・可視性・生存期間](panics.md)で保証範囲を説明します。

## [ジェネリクス](@id Generics)

Rust のジェネリック関数は Julia のパラメトリックメソッドに似ています。

```rust
fn identity<T>(x: T) -> T { x }
```

使われる具体的な `T` ごとに専用のコピーをコンパイルします。これを**単相化**と呼びます。Julia と違い Rust は事前に行うため、ライブラリにはビルド時に要求された特殊化だけが含まれます。

**トレイト**は型が提供するメソッドをまとめた名前付きインターフェースです。`fn largest<T: PartialOrd>(...)` は「比較できる任意の `T`」を意味します。RustCall は新しい型で初めて呼ぶ際に必要な特殊化をコンパイルします。[ジェネリクス](generics.md)を参照してください。

## [他言語から Rust 関数を呼ぶ条件](@id What-makes-a-Rust-function-callable-from-another-language)

通常の Rust 関数は Rust からしか呼べません。次の2点を指定する必要があります。

1. **呼び出し規約**：Rust は引数の渡し方を固定していません。`extern "C"` で Julia の `ccall` と同じプラットフォームの C 規約を使います。
2. **シンボル名**：通常は `_ZN4demo3add17h0f2a...E` のようにマングルされます。`#[no_mangle]` で元の名前を残し、ライブラリから検索可能にします。

手書きの公開関数は次の形です。

```rust
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}
```

このシグネチャに置けるのは C 互換型だけです。`String`、スライス、`Result` はポインタや長さへ手作業で分解する必要があり、`unsafe` コードを伴います。

`#[julia]` はこの作業を自動化します。

```rust
#[julia]
fn greet(name: &str) -> String {
    format!("Hello, {name}!")
}
```

通常の Rust 関数を書けば、隣に `extern "C"` ラッパーを生成し、対応する Julia 関数と引数・戻り値の変換を生成します。**特別な理由がなければ `#[julia]` を使ってください**。生成内容は [RustCall が Rust を呼ぶ仕組み](internals.md)で説明します。

### [`unsafe`](@id unsafe)

`unsafe { ... }` は生ポインタ（`*const T` / `*mut T`）の参照外しや C 関数呼び出しなど、プログラマーが正当性を保証する領域を表します。手書きの `extern "C"` の例に登場しますが、`#[julia]` なら通常は不要です。

## [最初によく出会うエラー](@id Common-first-errors)

| コンパイラの診断 | よくある原因と対処 |
|------------------|--------------------|
| `mismatched types: expected f64, found integer` | 暗黙変換はありません。`2` を `2.0` にするか `n as f64` と変換 |
| ``cannot add `{float}` to `i32` `` | 演算の両辺を同じ型にする |
| `cannot assign twice to immutable variable` | `let mut` で宣言 |
| `expected i32, found ()` | 最後の式の `;` を削除して値を返す |
| `borrow of moved value` | 移動後の値を再使用した。`&value` を渡すか `.clone()` する |
| `cannot borrow as mutable` | 変数の `mut` またはレシーバーの `&mut` が必要 |
| `index out of bounds`（実行時パニック） | 添字は0始まり。末尾は `xs[xs.len() - 1]` |

長い診断には修正案も含まれています。`help:` で始まる行を確認してください。

## [用語集](@id Glossary)

- **ABI**：コンパイル済みコードの引数・戻り値の受け渡し規則。C ABI は `ccall` と `extern "C"` の共通規則です。
- **属性**：項目の前の `#[...]`。`#[julia]`、`#[no_mangle]`、`#[derive(Clone)]`、`#[repr(C)]` など。
- **借用**：別の所有者の値への `&T` / `&mut T` 参照。
- **クレート**：Rust のパッケージであり、`rustc` のコンパイル単位。
- **Drop**：値とその所有物の破棄。スコープ終了時に自動で行われます。
- **FFI**：他言語で書かれたコードを呼ぶためのインターフェース。
- **ライフタイム**（`'a`）：参照が有効な期間に付ける名前。多くは推論されます。
- **マクロ**：コンパイル時に展開する `name!(...)`。
- **単相化**：具体型ごとにジェネリック関数をコンパイルすること。
- **パニック**：スタックを巻き戻す回復不能な実行時エラー。
- **手続きマクロ**：付与された項目を書き換えるコンパイラプラグイン。外部クレートの `#[julia]` が該当します。
- **`repr(C)`**：C と同じフィールド配置を構造体に与える属性。
- **トレイト**：型が実装する名前付きインターフェース。

## [次のステップ](@id Next)

ここで学んだ構文を使う [チュートリアル](tutorial.md)へ進んでください。
