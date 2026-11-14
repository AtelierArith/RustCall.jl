<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/crate_bindings.md. -->
# [外部クレートのバインディング](@id External-Crate-Bindings)

短いコードには `rust"""` が便利ですが、大きくなったらマニフェスト・ソース・テストを持つ**クレート**に分けます。`#[julia]` を付けた関数や型を `@rust_crate` でビルドし、Julia モジュールを生成できます。Python の [maturin](https://www.maturin.rs) に似た役割です。

まず Rust 初心者向けの手順を示し、パッケージへの同梱、`#[julia]` の詳細を説明します。

| 目的 | 参照先 |
|------|--------|
| 最初のクレートを使う | [最初のクレート](#Your-first-crate) |
| Julia での対応を知る | [Julia で得られるもの](#What-you-get-in-Julia) |
| Julia パッケージに同梱 | [プリコンパイル](#Precompilation-Support) |
| 再起動せず編集を反映 | [ホットリロード](hot_reload.md) |
| 規則や診断を調べる | [`#[julia]` の詳細](#The-#[julia]-attribute-in-detail)以降 |

## [インラインブロックとクレートの選択](@id Inline-block-or-crate?)

| | `rust"""` | クレートと `@rust_crate` |
|-|-----------|------------------------|
| Rust の置き場所 | Julia の文字列 | `.rs` と `Cargo.toml` |
| rust-analyzer、`cargo test`、`cargo doc` | 非対応 | 対応 |
| 依存関係 | `// cargo-deps:` | `[dependencies]` |
| 複数ソース・モジュール | 非対応 | 対応 |
| 必要時に具体化するジェネリクス | 対応 | 具体型のみ |
| Python や Rust からも利用 | 非対応 | 対応 |

同じ Julia モジュールで併用できます。

## [最初のクレート](@id Your-first-crate)

### [1. クレートを作る](@id 1.-Create-the-crate)

ライブラリは `Cargo.toml` と `src/lib.rs` を持ちます。

```
my_math/
├── Cargo.toml
└── src/
    └── lib.rs
```

Rust があれば `cargo new --lib my_math` で作れます。なければこの2ファイルを手で作れば十分です。

### [2. `Cargo.toml`](@id 2.-Cargo.toml)

Julia の `Project.toml` に相当します。

```toml
[package]
name = "my_math"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
rustcall_julia_macros = "0.7"
```

- `[package]` は名前など、`edition` は言語エディションです。通常は `2021` を選べます。
- `crate-type = ["cdylib"]` は Julia が読める C 互換共有ライブラリ（`.so` / `.dylib` / `.dll`）です。省略するとラッパークレートを生成しますが、[ホットリロード](hot_reload.md)には `cdylib` が必要です。
- `rustcall_julia_macros` が `#[julia]` を提供します。[crates.io](https://crates.io/crates/rustcall_julia_macros) から取得するか、ソース開発時は `rustcall_julia_macros = { path = "/path/to/RustCall.jl/deps/rustcall_julia_macros" }` と指定します。

### [3. `src/lib.rs`](@id 3.-src/lib.rs)

```rust
use rustcall_julia_macros::julia;

#[julia]
fn factorial(n: u64) -> u64 {
    (1..=n).product()
}

#[julia]
fn mean(xs: &[f64]) -> Option<f64> {
    if xs.is_empty() {
        None
    } else {
        Some(xs.iter().sum::<f64>() / xs.len() as f64)
    }
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

    #[julia]
    pub fn describe(&self) -> String {
        format!("({}, {})", self.x, self.y)
    }
}
```

- `use rustcall_julia_macros::julia;` で属性を読み込みます。
- 公開する項目に `#[julia]` を付けます。メソッドには **`impl` と各メソッドの両方**に付けます。
- 通常の Rust のままなので `#[test]` や他の Rust コードからも呼べます。

### [4. Julia から読み込む](@id 4.-Load-it-from-Julia)

```julia
using RustCall

const MyMath = @rust_crate "/path/to/my_math"

MyMath.factorial(10)                # => 0x0000000000375f00  (3628800 as a UInt64)
MyMath.mean([1.0, 2.0, 3.0])        # => RustCall.RustOption{Float64}(true, 2.0)

p = MyMath.Point(3.0, 4.0)          # calls Point::new
MyMath.distance(p)                  # => 5.0
MyMath.describe(p)                  # => "(3, 4)"
p.x                                 # => 3.0
p.x = 6.0                           # fields are assignable
propertynames(p)                    # => (:x, :y)
```

初回は Cargo が依存関係を取得するため1分ほどかかる場合があります。同じソースは次のセッションでもキャッシュを使い、編集後は再ビルドします。出力は RustCall のキャッシュ内で、`my_math/target/` の通常の `cargo build` / `cargo test` を妨げません。

関数などローカルスコープではマクロの戻り値を使います。

```julia
function load_my_math(crate_path)
    bindings = @rust_crate crate_path
    return bindings.factorial(5)
end
```

### [5. ビルドせず境界を確認](@id 5.-Check-the-interface-without-building)

`boundary_report` は検査した位置とバインドできない理由を列挙します。ビルド前の確認や項目が見つからない場合に使います。

```julia
RustCall.boundary_report("/path/to/my_math")
# RustCall boundary report for crate /path/to/my_math: no unsupported positions (10 checked).
```

`RustCall.scan_crate(path)` は同じ情報をデータとして返します。

## [Julia で得られるもの](@id What-you-get-in-Julia)

戻り値のバインディングオブジェクトに、元の Rust 名で関数や型が定義されます。

| クレート側 | Julia 側 |
|------------|----------|
| `#[julia] fn f(a: i32) -> i32` | 引数を変換する `MyMath.f(a)` |
| `#[julia] pub struct Point` | Rust 値のハンドル型 `MyMath.Point` |
| `#[julia] impl` 内の `fn new(...) -> Self` | `MyMath.Point(...)` |
| `&self` / `&mut self` メソッド | `MyMath.method(obj, args...)` |
| `self` のない関数 | 型を先頭に渡す `MyMath.name(MyMath.Point, args...)`（[静的メソッド](#Static-methods)） |
| 対応型の `pub` フィールド | 読み書きできる `obj.field` |
| `#[julia] mod geometry` 内の関数 | `MyMath.geometry.f(...)` |
| `Result<T, E>` / `Option<T>` | `RustCall.RustResult{T, E}` / `RustCall.RustOption{T}` |

対応型はインラインと共通で、整数、浮動小数、`bool`、`char`、`&str`、`String`、数値スライス、`Result`、`Option`、C 関数ポインタ、生ポインタ、`#[julia]` 構造体の参照です。[FFI の型契約](type_contract.md)が正式な一覧です。その他は `boundary_report` で報告し、生成時に拒否します（[未対応型](#Unsupported-types-in-a-crate)）。渡された Rust 値は Julia ラッパーが所有し、GC で破棄します。パニックは `RustCall.RustPanicError` です。

### [`@rust_crate` のオプション](@id Options-of-@rust_crate)

```julia
const B = @rust_crate "/path/to/crate" release=false features=["simd"]
```

| オプション | 既定値 | 意味 |
|------------|--------|------|
| `release=true/false` | `true` | 最適化ビルド。`false` はビルドが速く実行が遅い debug |
| `features=["a", "b"]` | なし | `Cargo.toml` の `[features]` にある機能を有効化 |
| `default_features=false` | `true` | 既定の feature を無効化 |
| `cache=true/false` | `true` | ビルド済みライブラリを再利用 |
| `name="Mod"` | クレート名 | 生成モジュール名。呼び出し元に名前は定義しない |
| `submodule="Mod"` | なし | 呼び出し元にモジュールを定義し `using .Mod: f` を可能にする。パッケージ向け |
| `pyo3_host=true` | `false` | Python インタープリター経由（[PyO3](pyo3.md)） |

## [`#[julia]` 属性の詳細](@id The-#[julia]-attribute-in-detail)

ここからは規則を詳しく説明します。最初からすべて読む必要はありません。

### [属性が生成するもの](@id What-the-attribute-generates)

`#[julia]` は**追加的**です。元の関数や `impl` はそのまま残し、隣に派生名の C ABI ラッパーを生成します。Rust のテストや別の属性マクロも元の項目を使えます。

```rust
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}

// …is kept as written, and this is added beside it (simplified):
#[no_mangle]
pub extern "C" fn rustcall_add(a: i32, b: i32) -> i32 {
    /* call add(a, b) inside a panic boundary */
}
```

[`#[no_mangle]` と `extern "C"` の説明](rust_primer.md#What-makes-a-Rust-function-callable-from-another-language)、[生成コードの詳細](internals.md)も参照してください。

構造体の場合は、

```rust
#[julia]
pub struct Point {
    pub x: f64,
    pub y: f64,
}
```

`pub` と `#[repr(C)]` を付け、`Point_free(ptr)`、`Point_get_x(ptr)` / `Point_set_x(ptr, value)` と `y` のアクセサーを生成します。Julia の finalizer と `p.x` の読み書きに使います。構造体とフィールドそれぞれの `#[cfg]` も適用するため、Linux 専用フィールドのアクセサーは他環境では生成しません。

### [ジェネリック項目は拒否](@id Generic-items-are-refused)

C ABI には具体型が必要で、属性だけでは必要な具体化が分かりません。型・`const` パラメーターやシグネチャの `impl Trait` がある関数・構造体・impl・メソッドはコンパイルエラーです。

```text
error: #[julia] function `identity` is generic over `T`: an `extern "C"` entry point
       needs concrete types, ...
```

具体型の窓口（`#[julia] fn identity_i32(x: i32) -> i32 { identity(x) }`）を作るか、必要時に単相化できるインラインの[ジェネリクス](generics.md)を使います。ライフタイム引数は可能で、`fn echo<'a>(s: &'a str) -> &'a str` は通常どおりラップします。

### [impl ブロック](@id For-Impl-Blocks)

```rust
#[julia]
impl Counter {
    #[julia]
    pub fn new(initial: i32) -> Self {
        Self { value: initial }
    }

    #[julia]
    pub fn get(&self) -> i32 {
        self.value
    }
}
```

元の `Counter::new` / `Counter::get` は変更せず、`rustcall_Counter_new(initial)`（`*mut Counter` を返す）と `rustcall_Counter_get(ptr)`（`*const Counter` を取り `i32` を返す）を隣に生成します（#279）。Julia 名は `Counter(1)` / `get(c)` のままで、シンボルはマニフェストから得ます。

ラッパーの私的な引数・一時変数は元の関数や入力を隠さない名前にします。`fn callback(callback: extern "C" fn() -> i32)` も元の名前とメタデータを保ち、私的な変数だけを変更します。ポインタ・長さ変換やパニックガードも同様です。関数内の注釈付き項目や外部の修飾対象も、強制的な `self::` ではなく字句的な名前解決を保ちます。

`impl` は構造体と別モジュールにも置けます（#315）。`impl crate::Counter`、`impl super::Counter`、明示的な `use` などが使えます。ただしシンボルは impl の場所ではなく対象構造体に従います。ヘッダーは手続きマクロが読むパスと一致する必要があり、注釈付き構造体を指さない場合や、裸の `impl Counter` が異なる修飾名を生成する場合は、修正すべきヘッダーを示して走査を拒否します。同名でもローカルの未注釈型を無視して別の型へ結び付けることはありません。

リテラルの `include!("api.rs")` も走査し、取り込み先の `#[julia] mod` の階層で項目を定義します。非リテラルのパスや、項目一覧でない断片はコンパイラに任せます。断片内の外部ファイルモジュールも追跡し、ファイルは**断片のディレクトリ**から解決します（#343）。`include!("frag/api.rs")` の `mod nested;` は `src/frag/nested.rs` です。見つからないファイルは記録してスキップします。

!!! note "インラインのラッパーは impl の場所に生成"
    インラインも同じで、impl のモジュール内に生成するため、その場所だけから見える型をシグネチャに使えます（#342）。シンボルは対象構造体に従います。文字列バッファはメソッド専用（例：`Counter_label_RustCallOwnedString`）で、解放シンボルはマニフェストが指定します。ただし Julia へのバインドには型対応が必要なので、ローカルの型エイリアスを返す場合は対応する型を直接書いてください。

### [モジュールの glob で取り込む借用対象](@id Borrowed-owners-imported-through-module-globs)

必須の `&Owner` / `&mut Owner` は、具体的な `#[julia]` 型だと証明できれば検査付きハンドルを受け取ります。インラインの `#[derive(JuliaStruct)]` も同様です。別 impl モジュールの曖昧でない `use super::*` も追跡します。

```rust
// src/operations.rs; Counter and Destination are annotated in the parent.
use super::*;
#[julia]
impl Destination {
    #[julia]
    pub fn read(&mut self, source: &Counter) -> i32 {
        self.value = source.value;
        self.value
    }
}
```

マニフェストは `Arg.handle` に所有対象の識別情報、`Arg.abi` に `"handle"` / `"handle_mut"` を記録します。メモリ上・保存済みの両バインディングが同じ情報を使い、型・生存・ライブラリイメージ・GC 保護・可変借用の重複を検査します。

名前解決はスコープに従い保守的に行います。ローカル宣言と明示的 import が型名前空間で優先し、関数・定数・static だけの import は glob の型を隠しません。各 glob の実際のモジュール、再公開、`crate` / `self` / `super` の別名、後続 glob、通常の型やエイリアスも考慮します。非公開候補も定義スコープで競合してから可視性を適用します。Rust が値と型を別々の glob から解決できても、隠れた曖昧性は拒否するので、明確な修飾パスを使います。

クレート全体で同名の注釈型が1つというだけでは選びません。候補の競合、不明スコープ、一意に証明できない循環は未対応です。生成する公開文字列バッファや Result/Option 集成型も実際の可視性を持ち、不透明な所有対象とは扱いません。生識別子と Unicode NFC の[識別規則](https://doc.rust-lang.org/reference/identifiers.html#normalization)も適用します。型エイリアスは、対象が注釈型でも展開して証明しません。診断にその制約を示すので具体型のパスを書きます。

未展開マクロ、include、兄弟項目を追加し得る属性・derive があると推論を制限します。モジュールやファイルを書き換える不透明な属性は、配下・外部からの import・修飾参照・`Self` も証明不能にします。別の import で回避せず、境界を証明できる展開済みソースを使います。ビルドで解決済みの `cfg` は無効宣言を除外できますが、不明な条件は証明を拒否する理由です。無修飾 import の起点はエディションに従い、2015 はクレートルート、2018 以降は字句スコープです。通常の型パスは字句的に解決します。

証明できない借用は `Arg.abi = "borrow_unresolved"` と `borrow_reason` を記録します。ハンドルを渡すとその理由を示し、値渡し登録を勧めることはありません。明示的 import か修飾パスを使います。

```rust
use super::{Counter, Destination};
use rustcall_julia_macros::julia;
// Alternatively spell the argument as `source: &crate::Counter`.
```

借用を直すために不透明型を値渡し登録してはいけません。必須位置だけは、未解決でも `Ptr{Cvoid}` を明示的に渡せますが、配置・生存・ライブラリ世代・別名参照・GC 保護はすべて利用者の責任です。一意に証明できる通常のハンドルには不要です。

省略可能な借用と `rustcall_owned_return` も同じスコープ内の証明を使います。ただし各 ABI、生存期間、生成側マーカーの規則は別途適用します。省略可能な位置は正しい型のハンドルか `nothing` だけで、未解決でも生ポインタへの回避はできません。

### [省略可能な借用対象](@id Optional-borrowed-owners)

非ジェネリックな関数・メソッドは、具体的な注釈型のハンドルか `nothing` を受け取れます。

```rust
#[julia]
pub fn compute(
    source: &Matrix,
    scratch: &mut Scratch,
    team: Option<&Team>,
) -> Result<(), String> {
    // Application-specific work; None can select the sequential path.
    Ok(())
}
```


```julia
bindings.compute(source, scratch, nothing)
bindings.compute(source, scratch, team)
```

`Option<&mut Owner>` も排他的借用の検査付きで使えます。独立関数・静的・インスタンスメソッド、および注釈型自身への `Option<&Self>` が対象です。値がない場合の意味はアプリ側で決めます。

マニフェストは `Arg.handle` と `Arg.abi = "handle_optional"` / `"handle_optional_mut"` を記録します。C 側は nullable な1本の `*const Owner` / `*mut Owner` で、null を `None`、それ以外を呼び出し中だけの `Some(&Owner)` / `Some(&mut Owner)` に再構成します。Rust 固有の Option 配置は使いません。`<symbol>_optional_owner_ptr_v1` マーカーを呼び出し前に要求するため、欠ける古いライブラリは再ビルドし、バインディングも再生成します。

欠如は **`nothing` だけ**です。解放済み・閉じたイメージ・別の型・不正値はエラーであり `None` にはなりません。`Ptr`（`C_NULL` 含む）、`Some(handle)`、`missing` も拒否します。必須借用の生ポインタ経路とは異なります。

存在する全ハンドルを、レシーバーや必須引数も含め呼び出し先のイメージと比較します。旧ハンドル同士が一致しても、置換後のイメージを呼ぶことはできません。`nothing` はイメージも領域も持ちません。全ハンドルを GC から保護し、可変借用が他のレシーバー・必須・省略可能な借用と重なる場合は拒否します。共有同士は可能です。数値スライスとの併用では両方の生成側マーカーを同じ取得済みイメージで検査します。

同期呼び出しで終わる借用だけに対応します。static や外へ逃げる参照、ネストした Option、未注釈型、型・const ジェネリクス、非同期関数は拒否します。省略可能な所有対象を取るラッパーは、名前付き・省略形を問わず非 static な `&str` も返せません。`String` か明示的 `&'static str` にします。対象の識別には前述の完全かつ一意なスコープ証明が必要です。

GC 保護はロックでも `Send` / `Sync` の保証でもありません。他タスク・スレッド・コールバック・再入呼び出しとの競合を防ぎ、Rust は参照を保持しないでください。可変借用は実体を直接変えるため、エラー・パニック・コールバック例外でも変更が残る場合があり、ロールバックはありません。

### [トレイトの impl](@id Trait-impls)

トレイトメソッドにも対応します（#506）。`<Buf as tr::A>::m(..)` で呼び、シンボルには長さ付きのトレイト名を含めるため、固有メソッドや別トレイトと衝突しません。

```rust
#[julia]
impl Buf {
    #[julia]
    pub fn m(&self) -> i32 { self.n }           // rustcall_Buf_m
}

#[julia]
impl tr::A for Buf {
    #[julia]
    fn m(&self) -> i32 { self.n * 10 }          // rustcall_Buf_1A_m
    #[julia]
    fn build(n: i32) -> Self { Buf { n } }      // rustcall_Buf_1A_build
}

#[julia]
impl B for Buf {
    #[julia]
    fn m(&mut self, by: i32) -> i32 { by }      // rustcall_Buf_1B_m
}
```

Julia 名は同名がなければそのままです。同名なら固有メソッドが裸の名前を保ち、トレイト側は `<Trait>_<name>` になります。

```julia
m(b)          # Buf::m
A_m(b)        # <Buf as tr::A>::m
B_m(b, 2)     # <Buf as B>::m
build(Buf, 1) # <Buf as tr::A>::build
```

トレイト名はパスの末尾です。`Self` を返す関数も `build(Buf, 1)` と元の名前で呼び、コンストラクタを上書きしません。末尾名が同じ2トレイト（`a::Tr` と `b::Tr`、`From<u8>` と `From<i32>`）が同名メソッドを生成する場合や、`A_m` が既に使われている場合は拒否します。

未注釈型、外部型、基本型のトレイト impl は変更しません。型エイリアス経由の `impl Tr for Alias` は対象を判別できないため拒否します。構造体自身の名前を使ってください。

### [静的メソッド](@id Static-methods)

コンストラクタ以外の `self` がない関数は、型を第1引数にして呼びます。

```julia
shout(Labeler, "hi")     # Labeler::shout
parse_scale(Divider, "7") # Divider::parse_scale
```

`shout("hi")` も生成しますが、同名の独立関数や別構造体の静的メソッドがある場合は型付きの形式だけになります。裸の関数を重複生成するとメモリ上では上書き、保存済みモジュールのプリコンパイルではエラーになるためです（#323）。

### [モジュール](@id Modules)

シンボルは**FFI 名**から決まります。ルートなら元の名前、それ以外はモジュールパスを含めます（`symbol_stem`、#300）。手続きマクロは所属モジュールを見られないため、モジュールにも属性を付けます。

```rust
#[julia]
pub mod a {
    use rustcall_julia_macros::julia;

    #[julia]
    pub fn run() -> i32 { 1 }          // exported as `rustcall_a__run`

    #[julia]
    pub struct C { pub v: i32 }        // `a__C_free`, `a__C_get_v`, `a__C_set_v`

    #[julia]
    impl C {
        #[julia]
        pub fn new(v: i32) -> Self { Self { v } }   // `rustcall_a__C_new`
    }
}

#[julia]
pub mod b {
    use rustcall_julia_macros::julia;

    #[julia]
    pub fn run() -> i32 { 2 }          // exported as `rustcall_b__run`
}

#[julia]
pub fn run() -> i32 { 0 }              // crate root: `rustcall_run`, as before
```

入れ子の注釈付きモジュールはパスを累積し、`a::deep::run` は `rustcall_a__deep__run` になります。区切りは `__`、要素内の `_` は `_0` なので、`a_b::c` と `a::b_c` は衝突しません。ルートの名前はそのままです。

Julia でも同じモジュール階層になります。

```julia
bindings = @rust_crate "/path/to/two_modules"
bindings.run()              # 0
bindings.a.run()            # 1
bindings.b.run()            # 2
c = bindings.a.C(Int32(4))  # a distinct type from bindings.b.C
bindings.a.get(c)
```

保存済みファイルも同じで、静的メソッドの衝突判定はモジュールごとです。

- モジュールの `#[cfg]` は配下全体に適用されます。
- Julia は関数・型・モジュールが同じ名前空間なので、同じ階層の `fn a()` と `mod a` は両方を示して拒否します。
- 注釈のないインラインモジュール内の `#[julia]` は、マクロとマニフェストのシンボルが食い違うため拒否します。
- 外部ファイルの `mod a;` に属性マクロは付けられません（E0658）。その中身はルートと同じシンボルになります。同名の `run` が複数ファイルにあれば、両方の場所を示して拒否します。ファイル内で `#[julia] pub mod` に包むか名前を変えます。

### [Julia の予約語](@id Names-Julia-reserves)

Rust の `fn function`、`struct end`、`fn quote(&self)`、フィールド `begin` や、`r#for` などは Julia の予約語と衝突します。全項目・全生成経路で `RustCall.julia_binding_name` により次の規則を適用します（#514）。

- 生識別子の `r#` を除去（`r#match` → `match`）。
- Julia の `Meta.parse` が単独の識別子と読めない名前に `_` を追加（`r#for` → `for_`、`end` → `end_`、`r#true` → `true_`）。

```rust
#[julia]
pub fn r#for(x: i32) -> i32 { x + 1 }          // rustcall_for

#[julia]
pub struct end { pub r#let: i32 }               // end_free, end_get_let

#[julia]
impl end {
    #[julia]
    pub fn new(v: i32) -> Self { end { r#let: v } }
    #[julia]
    pub fn quote(&self) -> i32 { self.r#let }   // rustcall_end_quote
}

#[julia]
pub mod r#do { /* #[julia] pub fn r#try ... */ }
```


```julia
bindings.for_(1)          # 2
e = bindings.end_(3)
bindings.quote_(e)        # 3
e.let_                    # 3; the accessors are get_let_ / set_let_!
bindings.do_.try_(4)
```

引数も `julia_parameter_names` で変換します（#516）。`fn f(end: i32, r#for: &str)` は `f(end_, for_)` です。位置引数なので主に保存済みソースと診断に現れます。既存の `end_` を優先し、`end` は `end__` にするなど重複を避けます。パターンや `_` は `arg1` のような位置名です。ラッパーが使う `pointer` や `Int64` も隠さないよう変更します（#526）。

公開シンボルは `r#` を除く Rust 名のままです。変換後に `r#for` と `for_` などが衝突すれば、どの項目種別でも上書きせず拒否します。`julia_definitions` は独立関数、型とコンストラクタ、静的・インスタンスメソッド、プロパティ、`get_<f>` / `set_<f>!`、サブモジュールを実際のディスパッチキーで比較します。同じ名前・同じキーの定義は不可ですが、別構造体のインスタンスメソッドは多重ディスパッチできます。型・サブモジュール名は、その型自身のコンストラクタやメソッド以外の関数が使えません。

PyO3 ホストも同じ検査をしますが、静的メソッドが型引数なしの関数なので独立関数との衝突に注意します。実際のビルドの `cfg` を適用して検査するため、相互排他的な feature の項目は衝突しません。

## [プロパティアクセス](@id Property-Access-Syntax)

生成構造体は Julia の自然なフィールドアクセスを使えます。

```julia
# Instead of calling accessor functions directly:
get_x(p)
set_x(p, 5.0)

# You can use dot notation:
p.x        # Get field value
p.x = 5.0  # Set field value
```

FFI 対応フィールド型（`i8`～`i64`、`u8`～`u64`、`f32`、`f64`、`bool`、`usize`、`isize`）で利用できます。`propertynames()` で一覧を得ます。

```julia
p = MyModule.Point(1.0, 2.0)
propertynames(p)  # => (:x, :y)
```

## [API リファレンス](@id API-Reference)

### [`scan_crate(path)`](@id scan_crate(path))

クレートを走査して `#[julia]` 項目を抽出します。

```julia
info = RustCall.scan_crate("/path/to/crate")

println("Crate: ", info.name)
println("Functions: ", length(info.julia_functions))
println("Structs: ", length(info.julia_structs))
```

### [`generate_bindings(path; kwargs...)`](@id generate_bindings(path;-kwargs...))

外部クレートの Julia バインディングを生成します。

```julia
bindings = RustCall.generate_bindings("/path/to/crate",
    output_module_name = "MyBindings",
    build_release = true,
    cache_enabled = true
)

eval(bindings)

# Now MyBindings module is available
MyBindings.add(1, 2)
```

### [`@rust_crate`](@id @rust_crate)

走査・ビルド・生成・読み込みを一度に行い、バインディングを返します。

```julia
# Basic usage
const MyCrate = @rust_crate "/path/to/crate"

# With options
const MyBindings = @rust_crate "/path/to/crate" name="CustomName" release=true cache=true
```

全オプションは[一覧](#Options-of-@rust_crate)を参照してください。

## [型定義](@id Type-Definitions)

### [`CrateInfo`](@id CrateInfo)

走査したクレートの情報です。

| フィールド | 型 | 内容 |
|------------|----|------|
| `name` | `String` | クレート名 |
| `path` | `String` | 絶対パス |
| `version` | `String` | バージョン |
| `dependencies` | `Vector{DependencySpec}` | 依存関係 |
| `julia_functions` | `Vector{RustFunctionSignature}` | 注釈付き関数 |
| `julia_structs` | `Vector{RustStructInfo}` | 注釈付き構造体 |
| `source_files` | `Vector{String}` | `.rs` のパス |

### [`CrateBindingOptions`](@id CrateBindingOptions)

生成オプションです。

| フィールド | 型 | 既定値 | 内容 |
|------------|----|--------|------|
| `output_module_name` | `Union{String, Nothing}` | `nothing` | モジュール名 |
| `output_path` | `Union{String, Nothing}` | `nothing` | ファイル出力先 |
| `use_wrapper_crate` | `Bool` | `true` | ラッパークレート生成 |
| `build_release` | `Bool` | `true` | release ビルド |
| `cache_enabled` | `Bool` | `true` | キャッシュ利用 |

## [ビルドの流れ](@id Build-Process)

1. Rust 側の extractor が `src/lib.rs` からモジュール階層を走査し、注釈付き項目を記録します。
2. 一致するハッシュのキャッシュを探します。
3. なければ `cdylib` を直接ビルドし、それ以外はラッパーを作ります。
4. Julia の関数・構造体を生成します。
5. `.so` / `.dylib` / `.dll` を読み込みます。

## [キャッシュ](@id Caching)

ソースのハッシュに基づき保存します。

```julia
# Clear the cache
RustCall.clear_cargo_cache()

# Check cache size
RustCall.get_cargo_cache_size()
```

## [対応型](@id Supported-Types)

[概要](#What-you-get-in-Julia)と [FFI の型契約](type_contract.md)を参照してください。

## [プリコンパイル](@id Precompilation-Support)

トップレベルの `@rust_crate` と、`write_bindings_to_file` のファイルを `include` する方法の両方に対応します。

### [パッケージ内で `@rust_crate` を使う](@id Using-@rust_crate-inside-a-package)

```julia
module MyPackage
using RustCall

# Build the crate and generate its bindings; define them as `MyPackage.Bindings`.
@rust_crate joinpath(@__DIR__, "..", "deps", "my_rust_crate") submodule="Bindings"
using .Bindings: add, multiply, MyStruct

export add, multiply, MyStruct
end
```

生成モジュールは**マクロを展開するモジュール内**で評価し、通常のサブモジュールと同じく `MyPackage` のキャッシュへ収めます（#339）。

- **プリコンパイル時**：走査・ビルド・生成を行い、depot の scratch 内の RustCall キャッシュへ保存します。パッケージには書きません。まだライブラリを開かず、生成モジュールの `__init__` は読み込み時まで延期します。したがってパッケージのトップレベルからは呼ばず、`MyPackage.__init__` 後に呼びます。
- **キャッシュからの読み込み時**：生成側の `__init__` がプロセス専用コピーを開きます。Cargo 出力やキャッシュ本体を再ビルド可能に保ちます（#309）。走査や Cargo は不要です。
- **編集やキャッシュ削除後**：ライブラリと全入力（path 依存、ワークスペースルートも含む）を `Base.include_dependency` で追跡するので、次の `using` で再プリコンパイルします。

環境変数はファイル追跡では検出できません。生成モジュールは `RUSTFLAGS`、`PYO3_PYTHON`、`PYO3_CONFIG_FILE` などの値を記録し、`__init__` で不一致を拒否します。`@rust_crate` なら目的の環境で `Pkg.precompile(; force = true)`、保存済みファイルなら `write_bindings_to_file` で**再生成**します。診断が適切な対処を示します（#531）。ツールチェーン情報には extractor のソースも含み、変更後は同様に拒否します。

開始時に取得する1つの環境スナップショットを、cfg probe、キー、登録名、Cargo/Python 子プロセス、記録へ共通して使います。途中の別タスクの `ENV` 変更で記録と実体を食い違わせません。PyO3 が選んだインタープリターもビルド後に再確認し、途中で置換された場合は保存・読み込み前に拒否します。

パッケージでは `cache=false` を避けます。直接の `cdylib` は RustCall の Cargo 出力を参照し、次のビルドで上書きされます。生成ラッパーは別プロセスの読み込みにも残る専用コピーを Cargo キャッシュ内に作り、通常の検索では再利用せず `clear_cache()` まで残ります。

**`submodule="Bindings"` が `MyPackage.Bindings` を定義**します。省略時は隠れた呼び出しごとのモジュールを戻り値からだけ参照します。`name="Bindings"` は名前を選ぶだけで呼び出し元に定義しません。`const MyBindings = @rust_crate path name="MyBindings"` は引き続き使えます。

同じ `submodule` で再度呼ぶと置換警告が出ますが、旧値は元のモジュールを保持します。`const Bindings = @rust_crate path submodule="Bindings"` は定義したモジュールを戻り値で上書きするため避けます。どの位置でも戻り値は `CrateBindings` で、`const B = @rust_crate path` も world age に安全です。依存には `RustCall` だけが必要で、`Libdl` はそこから参照します。

利用先で Rust が使え、初回ビルドできるならこの方式でソースと同期できます。Rust なしで配布したい場合や、生成結果を検査・同梱したい場合は次の保存方式を選びます。

### [バインディングをファイルへ生成](@id Generating-Bindings-to-a-File)

```julia
using RustCall

# Generate bindings and write to a file
RustCall.write_bindings_to_file(
    "deps/my_rust_crate",              # Path to Rust crate
    "src/generated/MyRustBindings.jl", # Output file
    output_module_name = "MyRust",
    relative_lib_path = "../deps/lib"  # Path relative to the output file
)
```

### [パッケージ開発の流れ](@id Package-Development-Workflow)

1. **構成を準備**します。

```
MyPackage/
├── Project.toml
├── src/
│   ├── MyPackage.jl
│   └── generated/
│       └── MyRustBindings.jl  # Generated bindings
├── deps/
│   ├── my_rust_crate/         # Your Rust crate
│   └── lib/                   # Compiled library
└── test/
```

2. **開発中に生成**します。

```julia
using RustCall
RustCall.write_bindings_to_file(
    "deps/my_rust_crate",
    "src/generated/MyRustBindings.jl",
    output_module_name = "MyRust",
    relative_lib_path = "../deps/lib"
)
```

3. **パッケージに読み込み**ます。

```julia
# In src/MyPackage.jl
module MyPackage

include("generated/MyRustBindings.jl")
using .MyRust

# Re-export functions if desired
export add, multiply

end
```

4. パスには生成側の **`@__DIR__`** を使い、別の場所へのインストールに対応します。

保存済みファイルも `RustCall` のみを依存とし、`import RustCall.Libdl` を使います。`relative_lib_path` を省略すると、ライブラリは RustCall の Cargo キャッシュ内のコピーです。`clear_cache()` で消えますが、一時ラッパープロジェクト内のファイルは参照しません。

### [`@rust_crate` モジュールのホットリロード](@id Hot-reload-of-a-@rust_crate-module)

独自 `cdylib` のソース変更を検出して再ビルドし、同じ登録名のライブラリを置換します。マクロの戻り値を `enable_hot_reload_for_crate` に渡してください。

全生成モジュールは `_BUILD_RECORD`（不変の `CrateBuildRecord`）に、ディレクトリ、登録名（`_LIB_NAME`）、プロファイル、features、default_features、ビルド種別、環境、Cargo 設定、ツールチェーンを記録します。再ビルドはこの記録だけから行い、ラッパーと `#[cfg]` を一致させます。

```julia
B = @rust_crate "deps/my_rust_crate" release=false features=["simd"]
RustCall.enable_hot_reload_for_crate(B)  # rebuilds debug, with "simd"
```

追加引数は記録を変更せず照合します。パスを省略でき、指定するなら相対・シンボリックリンクでも同じディレクトリが必要です。`lib_name`、`release`、`features`、`default_features` も一致が必要です。環境は有効化時と各ビルド前に比較し、不一致なら有効化時は `ArgumentError`、再ビルド時は旧ライブラリを保ってコールバックに失敗を報告します。環境を戻すか、新環境で読み込み直します。

パスだけの形式も、引数と現在の環境から同じ記録を作り、既存ビルドを推測しません。独自 `cdylib` のないクレートと生成ラッパー経由のモジュールは有効化時に拒否します。再ビルドは RustToolChain の Cargo、RustCall 専用出力先、`[lib] name`、`RUSTCALL_OFFLINE=1` の `--offline` を使います。詳細は[ホットリロード](hot_reload.md)を参照してください。

### [API リファレンス](@id API-Reference)

#### [`write_bindings_to_file`](@id write_bindings_to_file)

```julia
RustCall.write_bindings_to_file(
    crate_path::String,
    output_path::String;
    output_module_name = nothing,
    build_release = true,
    relative_lib_path = nothing,
    strict = RustCall.FFI_STRICT[]
) -> String
```

| 引数 | 型 | 内容 |
|------|----|------|
| `crate_path` | `String` | Rust クレートの場所 |
| `output_path` | `String` | Julia ファイルの出力先 |
| `output_module_name` | `String` | モジュール名 |
| `build_release` | `Bool` | release ビルド |
| `relative_lib_path` | `String` | 出力ファイルからの相対ライブラリパス |
| `strict` | `Symbol` | 型契約で戻り値を表せない場合の動作：`:error`（既定）、`:warn`、`:none` |

#### [クレート内の未対応型](@id Unsupported-types-in-a-crate)

全戻り値を型契約で解決します。値渡しの `Vec<T>` などは、未定義な `ccall` スロットの `Any` にせず、シグネチャを示して拒否します。

```
the FFI contract cannot describe the return type of `mycrate::histogram(u32) -> Vec<f64>`
```

対応するシグネチャ（`*mut` やアクセサー）に変更します。修正中だけ残りを生成するには次を使えます。

```julia
RustCall.write_bindings_to_file(crate_path, output_path; strict = :warn)
```

`:warn` は旧動作の一度の警告と `Any` を一時的に復活させます（#276）。旧生成結果との差分では、`usize` が `Csize_t`、`*mut i32` が `Ptr{Cvoid}` から `Ptr{Int32}`、`String` フィールドが `Any` から所有バッファになった点にも注意してください。

#### [`emit_crate_module_code`](@id emit_crate_module_code)

```julia
RustCall.emit_crate_module_code(
    info::RustCall.CrateInfo,
    lib_path::String;
    module_name = nothing,
    use_relative_path = false
) -> String
```

生成する Julia モジュールのコードを文字列で返します。

## [トラブルシューティング](@id Troubleshooting)

### [クレートをビルドできない](@id The-crate-does-not-build)

診断に Rust コンパイラの出力を含みます。単独の `cargo build`、`[dependencies]` の `rustcall_julia_macros`、`use rustcall_julia_macros::julia;` を確認します。`cannot find attribute julia in this scope` は import 不足です。初回の依存取得にはネットワークが必要です。

### [関数やメソッドが見つからない](@id A-function-or-method-is-missing-from-the-bindings)

- 項目に `#[julia]`、メソッドなら impl とメソッドの両方に付けます。
- `boundary_report` で拒否理由を調べます。
- クレートのジェネリクスは非対応です。
- `#[cfg(feature = "…")]` は `features=[…]` で有効にします。

### [`InexactError` / `ArgumentError`](@id A-call-raises-InexactError-or-ArgumentError)

`i32` に入らない `2^40` や、`&[f64]` に対する `Vector{Int}` は呼び出し前に拒否します。Julia 側で変換してください。

### [編集が反映されない](@id The-bindings-do-not-reflect-an-edit)

新たな `@rust_crate` は再ビルドしますが、旧戻り値は元のモジュールを保持します。新しい値を使うかホットリロードを利用します。

### [プリコンパイルの問題](@id Precompilation-issues)

ライブラリパス（可搬性には `relative_lib_path`）、コピー先、生成構文を確認します。トップレベルの `@rust_crate` は依存に `RustCall` が必要で、そのマシンでビルドできなければなりません。呼び出しはパッケージの `__init__` 後に行います。`Base.isprecompiled(Base.identify_package("MyPackage"))` で有効性を確認でき、キャッシュ削除後は次の `using` まで `false` です。

## [オブジェクトの生存期間](@id Object-lifetime)

Julia ラッパーが所有し、finalizer が Rust デストラクタを呼びます。インライン構造体も同様です。生成時にデストラクタポインタとライブラリの生存フラグを捕捉するため、finalizer 内でロックやシンボル検索をしません。

- 解放後のメソッド・フィールド操作は `RustError` です。インラインメソッドは他引数の準備や対象解決の前にレシーバーを検査し、解放済みを静的呼び出しと解釈しません。正当な静的メソッド・コンストラクタはインスタンスなしで使えます。
- アンロードされたイメージへの解放呼び出しは行わず、意図的にリークさせて無効なコードへのジャンプを避けます。

生ポインタを使う間はラッパーへの参照か `GC.@preserve` を保ちます。明示的な生ポインタの有効性・生存期間・別名参照は検査しません。割り当てたライブラリ自身で解放してください（[詳細](panics.md)）。

## [更新後のバインディング再生成](@id Regenerating-bindings-after-an-upgrade)

保存ファイルの形式は RustCall の **`MAJOR.MINOR`** です（#489）。例：`# Bindings format: 0.10`、`const _BINDINGS_FORMAT = RustCall.check_bindings_format("0.10")`。読み込み時と `__init__` で検査します。

- 同じ `MAJOR.MINOR` なら patch が違っても読み込めます。
- 異なる minor / major なら、ヘッダーに示すクレートから `write_bindings_to_file` で再生成します。
- v0.6.6 以前の整数形式（13以下）は同様に拒否します。

以下は旧形式の履歴です。

- **13（#474）**：全ビルド入力を `_BUILD_RECORD` に記録し、再ビルド元と環境照合を共有しました。記録のない旧モジュールはモジュール指定の再読み込みを拒否します。
- **12（#460）**：コールバックを戻り値型付き `CallbackSlot{k, R}` にし、呼び出し外では Rust 越しに例外を投げずエラーを保存してゼロを返します。4引数 `_guard_panic(value, channel, name, free_ptr)` でコールバック例外時の所有文字列も解放します。
- **11（#253）**：呼び出しごとの `CrateTargetCache` で世代スナップショットを再利用。約1.0 µs・14割り当てから22 ns・割り当てなしとなり、複数スレッドの待ちも減りました。いずれも新しい名前を持たない旧 RustCall では使えません。
- **7（#300）**：シンボルのモジュール修飾と Julia サブモジュールを導入。以前の名前は現在のライブラリと一致しません。
- **6（#309）**：`__init__` が専用世代コピーを開き、Windows のロックで Cargo 出力や保存ライブラリを上書きできない問題を防ぎます。
- **3 / 4**：`ffi_string_argument` / `FFIByValue` を参照するため旧 RustCall と互換ではありませんでした。2以下は当時の API では読めても、アンロード・パニック・生存・UTF-8・値渡しの保証がありません。現在はいずれも再生成が必要です。

## [数値スライスの借用](@id Borrowing-numeric-slices)

非ジェネリックな `#[julia]` の `&[T]` / `&mut [T]` は、検査付きでコピーせず渡します。

```rust
#[julia]
pub fn transform(input: &[f64], output: &mut [f64]) -> Result<(), String> {
    if input.len() != output.len() {
        return Err("length mismatch".into());
    }
    for (x, y) in input.iter().zip(output) {
        *y = x * 2.0;
    }
    Ok(())
}
```


```julia
input = [1.0, 2.0, 3.0]
output = zeros(3)
bindings.transform(input, output)  # output now contains [2.0, 4.0, 6.0]
```

生成 Julia 関数を使ってください。生の `@rust` / `ccall` は検査や長さスロットを自動生成しません。

マニフェストは `abi = "slice"` / `"slice_mut"`、`slice_element`、`slice_length = "usize"` を記録します。Julia は実際の要素型と照合し、C ラッパーが基本型ポインタと `usize`（`size_t`）からパニック境界内でスライスを再構成します。Rust のファットポインタ ABI は渡しません。全戻り値形式やコンストラクタで `<symbol>_slice_ptr_len_v1` を取得済みイメージ上に要求します。古い生成側は `rustcall_julia_macros` を `0.7.0` 以降へ更新して再ビルド・再生成します。スライスなしの関数は不要です。

| Rust 要素 | Julia 要素 |
|:--|:--|
| `f32`, `f64` | `Float32`, `Float64` |
| `i8`, `i16`, `i32`, `i64` | `Int8`, `Int16`, `Int32`, `Int64` |
| `u8`, `u16`, `u32`, `u64` | `UInt8`, `UInt16`, `UInt32`, `UInt64` |
| `isize`, `usize` | `Int`, `UInt` |
| `num_complex::Complex<f32>`, `num_complex::Complex32` | `ComplexF32` |
| `num_complex::Complex<f64>`, `num_complex::Complex64` | `ComplexF64` |

複素数は実部・虚部の順の C 配置で、表の完全修飾名を使います。エイリアス、`bool`、`char`、入れ子スライス、任意構造体は非対応で、型変換はしません。

ストライド1の組み込み `StridedVector{T}`（密ベクター、行列の列などの連続ビュー、互換な reinterpret）だけを直接借用します。多次元・独自 `AbstractVector`・逆順・間引きビューはコピーせず拒否します。型表現・長さの乗算・アドレス範囲・整列を検査し、配列と所有者を GC 保護します。出力も含め全要素の初期化が必要です。`zeros` などを使い、`undef` を書き込み専用の契約とみなさないでください。空スライスは非 null の整列済みダングリングポインタを使い、要素は読みません。Rust 側も参照構築前に演算を検査します。

全スライス範囲をまとめて比較し、共有同士以外の重複（部分重複や reinterpret も含む）を拒否します。借用レシーバー・必須ハンドル・存在する省略可能ハンドルのインライン領域も Rust 側で比較します。ただしオブジェクト内部の別割り当てや `unsafe_wrap` による隠れた別名参照は検出できず、利用者が防ぎます。アドレスから割り当ての由来や手作り unsafe 配列の正当性は証明できません。

同期呼び出しだけに対応し、static・保持するライフタイム、スライスを借用する戻り値、ジェネリックシグネチャは拒否します。Rust は保持・非同期利用をせず、Julia 側も他タスク・スレッド・再入コールバックの競合、変更、長さ変更、解放を防ぎます。GC 保護はロックではありません。

可変借用は直接書き込むため `Err`・パニック・コールバック例外でも変更が残ります。成功時だけ反映したい場合は `with_numeric_buffer(...; write=true)` で一時領域を使い、エラー時はコールバック内で例外を投げます。所有する `Vec` の戻り値や多次元ストライド記述は別のインターフェースです。

## [スコープ付き数値バッファ](@id Scoped-numeric-buffers)

`with_numeric_buffer` は基本型ポインタと長さを取る既存 API 向けのコピー用ヘルパーです。スライス変換や Rust 所有 `Vec` の返却は行いません。

```julia
value = RustCall.with_numeric_buffer(array; element_type=Float64) do ptr, len
    bindings.sum(ptr, len)
end
```

非連続ビューも `eachindex` 順に整列済み連続領域へコピーし、コールバック中は保持します。空配列も非 null です。ポインタを保持・非同期使用してはいけません。対応型は `Bool`、8/16/32/64ビット整数、`Float32` / `Float64`、`ComplexF32` / `ComplexF64` です。`element_type` は Julia 配列との一致だけを検査し、Rust ポインタとの表現一致は利用者が保証します。型変換はありません。

`write=true` は正常終了後だけ反映します。エラー状態を値として返すだけでは正常終了なので、反映を避けるには例外を投げます。Rust が有効な Julia 値を書くことと、元配列への同時アクセスを利用者が防ぎます。コピー先が不変、または `setindex!` が例外を投げる場合は部分更新になることがあります。Rust 所有の大量出力には別途所有権と解放が必要です。

Rust がポインタ・長さと**対応する解放関数**を渡すなら、`copy_owned_numeric_buffer` がコピーし、Julia 側の検査失敗時も `finally` で解放します。

```julia
values = RustCall.copy_owned_numeric_buffer(ptr, len) do p, n
    bindings.free_values(p, n)  # the allocator's own release function
end
```

ポインタは生存し、互換配置の初期化済み `len` 要素を指し、指定の解放関数に属する必要があります。由来・実際の長さは検証できず、不正長の解放もコールバック側の責任です。コピー中の他タスクのアクセスは禁止です。null は長さ0だけで、空でも解放コールバックを呼びます。`Vec` の所有権や capacity を自動推定しません。

## [ジェネリック型の明示的な具体化](@id Explicit-instances-of-generic-types)

クレートの `#[julia]` 自体はジェネリックにできません。依存先の公開ジェネリック型には `generate_crate_instances` で具体型とメソッドを明示し、窓口ソースを生成できます。

```julia
instances = [(
    name = "FloatCell",
    rust_type = "generic_crate::Cell<f32>",
    constructor = (name = "new", args = ["value" => "f32"]),
    methods = [
        (name = "get", args = Pair{String,String}[], return_type = "f32", mutable = false),
        (name = "set", args = ["value" => "f32"], return_type = "()", mutable = true),
    ],
)]
write("facade/src/lib.rs", RustCall.generate_crate_instances(instances))
# Supply a Cargo.toml for the facade with dependencies on generic_crate and
# rustcall_julia_macros, then load that facade with @rust_crate.
```

別の宣言済みラッパーを借用する引数も指定できます。

```julia
(name = "combine", args = ["other" => (wrapper = :FloatCell, mutable = false)],
 return_wrapper = :FloatCell, mutable = false)
```

生成引数は `other: &FloatCell` となり、既定では `&other.inner` を渡します。`mutable = true` なら `&mut`、既定は `false` です。メソッド自身の `mutable` は `self` に適用します。コンストラクタにも同じマッピングを使え、明示的な所有戻り値の証明とマーカーを生成します。1引数のマッピング付きコンストラクタを `Ptr` / `C_NULL` で回避することはできません。従来の宣言は元の ABI を保ちます。

型・生存・イメージ・GC 保護・別名参照は通常どおり検査します。共有の重複は可能、可変レシーバーや引数の重複は不可です。`return_wrapper` は結果を所有するラッパー（自分自身や後で宣言する別型も可能）、`error_type = "String"` は `Result<Wrapper, String>` を指定します。

```julia
(name = "factor", args = Pair{String,String}[],
 return_wrapper = :Factor, mutable = false)
(name = "checked_factor", args = ["other" => (wrapper = :FloatCell,)],
 return_wrapper = :Factor, error_type = "String", mutable = false,
 expression = "self.inner.checked_factor(&other.inner)")
```

信頼済みの `expression` はラッパー変数のスコープへ**そのまま**出力します。`self` とマッピング引数はラッパーなので、式では `.inner` を明示し、実体または `Result` を返します。既定転送は `.inner` を自動で使います。Julia は式の解析や置換をしません。

先に全ラッパー名を収集し、重複名・引数・メソッド、不明な型やフィールド、非 Bool の可変性、`return_type` / `return_wrapper` / `error_type` の不正な組み合わせを生成前に拒否します。具体的な Rust シグネチャ・境界条件・式は Cargo/rustc が検査します。

所有マッピングは `#[julia]` の直後に `#[rustcall_owned_return(Wrapper)]` を付け、実際の結果が sized・`'static` な注釈型だと証明します。生のレシーバー・スライス・省略可能ポインタから再構成した参照は呼び出しローカルの証拠に結び付け、C ポインタ由来という理由だけで `'static` にしません。`nothing` は借用を作りません。所有者のマーカートレイト全体に `'static` を課すのではなく、この戻り値だけを検査します。

マニフェストは選んだ所有者を記録し、`<symbol>_owned_return_v1` を要求します。スライス・省略可能な借用・従来の boxed `Result<Self, E>` のマーカーも独立に必要です。成功値は生成元イメージの、その所有者のデストラクタ・パニックチャネル・生存フラグを捕捉します。Julia への取り込みに失敗すれば解放し、`Err` / パニック時の一時値は Rust が破棄します。再読み込み後のイメージに所有権を移しません。

通常の finalizer で実体を破棄しますが、ロック・同期・数値方針は提供しません。別名参照や型のスレッド要件を利用者が守ります。順序付き仕様から決定的なソースを生成し、ファイル更新には通常の Cargo/RustCall の無効化が適用されます。依存先のメソッド・境界・型変換・ライフタイム・非公開配置は推論しません。

失敗し得るコンストラクタには `error_type` を指定すると成功時に所有する `RustResult` を返します。任意の信頼済み `expression` でポインタ・長さから `Vec` を組み立てることもできますが、有効性と GC 保護は利用者の責任です。必要ならスコープ付きバッファを使います。未対応 ABI、借用戻り値、追加 import が必要なトレイトメソッドには手書きの窓口を使います。`Cargo.toml` は生成しません。

```@docs
RustCall.with_numeric_buffer
RustCall.copy_owned_numeric_buffer
RustCall.generate_crate_instances
```
