# [syn による Rust AST の解析と変換](@id Rust-ASTs-with-syn)

RustCall.jl は Rust の構文を **AST（Abstract Syntax Tree：抽象構文木）** に変換する
Rust クレート、[syn](https://docs.rs/syn/latest/syn/) を利用しています。
[quote](https://docs.rs/quote/latest/quote/) や
[proc-macro2](https://docs.rs/proc-macro2/latest/proc_macro2/) と組み合わせることで、
手続きマクロ（procedural macro）、ソースコード解析、コード生成の基盤になります。

このページでは小さな Rust プログラムを使って基本を学び、RustCall の FFI パイプラインとの関係を説明します。
Julia 側の内部構造については [RustCall が Rust を呼ぶ仕組み](internals.md) を参照してください。

## [ソースコードから AST へ](@id From-source-to-AST)

パーサーはソース文字列を構造化されたデータに変換します。
例えば `#[julia]` 属性のある Rust 関数は、属性、可視性、署名、本体を持つ `syn::ItemFn` で表現されます。

```text
ItemFn
├── attrs: [#[julia]]
├── vis: pub
├── sig: Signature
│   ├── ident: add
│   ├── inputs
│   │   ├── FnArg::Typed: a: i32
│   │   └── FnArg::Typed: b: i32
│   ├── generics: (none)
│   └── output: ReturnType::Type → i32
└── block
    └── a + b
```

図は簡略化した木構造であり、Debug の出力そのものではありません。
正規表現による文字列処理とは異なり、関数名、引数パターン、型、ライフタイム、属性を区別でき、
ネストした構文も Rust の文法に従って扱えます。

まず小さな Cargo プロジェクトを作ります。

```bash
cargo new syn-demo
cd syn-demo
```

`Cargo.toml` の空の `[dependencies]` セクションを次のように置き換えます。

```toml
[dependencies]
syn = { version = "2", features = ["full", "extra-traits", "visit", "visit-mut"] }
quote = "1"
proc-macro2 = "1"
prettyplease = "0.2"
```

次のコードを `src/main.rs` に保存してください。

```rust
use syn::ItemFn;

fn main() {
    let source = r#"
        #[julia]
        pub fn add(a: i32, b: i32) -> i32 {
            a + b
        }
    "#;

    let ast: ItemFn = syn::parse_str(source).unwrap();
    println!("{:#?}", ast);
}
```

`cargo run` で AST 全体を確認できます。
`full` はこの例で扱うファイルや項目の構文を有効にし、`extra-traits` は Debug 実装を有効にします。
文字列中の属性はあくまで構文なので、解析のために RustCall の手続きマクロをインストールする必要はありません。

## [主な AST の型](@id The-principal-AST-types)

| 型 | 対応する構文 |
|---|---|
| `syn::File` | ソースファイル |
| `syn::Item` | トップレベルやモジュール内の項目（enum） |
| `syn::ItemFn` | 関数定義 |
| `syn::ItemStruct`、`ItemEnum` | 構造体・列挙型の定義 |
| `syn::ItemImpl`、`ItemTrait` | impl ブロック・trait 定義 |
| `syn::ItemMod` | モジュール宣言・インラインモジュール |
| `syn::Signature` | 関数シグネチャ |
| `syn::FnArg`、`ReturnType` | 引数・戻り値の構文 |
| `syn::Expr`、`Type`、`Pat` | 式・型・パターン |
| `syn::Attribute`、`Generics` | 属性・ジェネリックパラメータ |

`ItemFn` の公開フィールドは `attrs: Vec<Attribute>`、`vis: Visibility`、
`sig: Signature`、`block: Box<Block>` の 4 つです。
`Signature` には識別子、ジェネリクス、引数、戻り値型、ABI、
`async`、`const`、`unsafe` などの修飾子が含まれます。
引数リストは `Punctuated<FnArg, Token![,]>` であり、区切りのトークンも表現されます。

## [関数シグネチャの抽出](@id Extracting-signatures)

次の例で `src/main.rs` を置き換えます（このページの各プログラムは独立しています）。
関数本体を調べることなく署名を走査できます。

```rust
use quote::ToTokens;
use syn::{FnArg, ItemFn, ReturnType};

fn main() {
    let f: ItemFn = syn::parse_str(
        "fn add(a: i32, b: i32) -> i32 { a + b }"
    ).unwrap();

    println!("Function: {}", f.sig.ident);

    for arg in &f.sig.inputs {
        match arg {
            FnArg::Typed(arg) => {
                println!("Argument: {} : {}",
                    arg.pat.to_token_stream(),
                    arg.ty.to_token_stream());
            }
            FnArg::Receiver(_) => println!("Receiver"),
        }
    }

    match &f.sig.output {
        ReturnType::Default => println!("Return: ()"),
        ReturnType::Type(_, ty) =>
            println!("Return: {}", ty.to_token_stream()),
    }
}
```

期待される出力：

```text
Function: add
Argument: a : i32
Argument: b : i32
Return: i32
```

`ToTokens` は構文上の表現を出力します。
実際の FFI ジェネレーターでは、出力された型名が名前解決後の型そのものであると仮定せず、
AST の構造を照合して明示的な ABI の型契約を適用する必要があります。

## [属性を持つ項目の抽出](@id Finding-annotated-items)

単一の関数ではなくソースファイル全体を調べるには `syn::parse_file` を使います。
この例ではルート階層にある、単純な `#[julia]` 属性付きの関数を抽出します。

```rust
use syn::Item;

fn main() {
    let source = r#"
        #[julia]
        fn add(a: i32, b: i32) -> i32 { a + b }

        fn internal_function() {}

        #[julia]
        fn square(x: f64) -> f64 { x * x }
    "#;

    let file = syn::parse_file(source).unwrap();
    for item in &file.items {
        if let Item::Fn(f) = item {
            if f.attrs.iter().any(|a| a.path().is_ident("julia")) {
                println!("{}", f.sig.ident);
            }
        }
    }
}
```

期待される出力：

```text
add
square
```

簡単な例なので、外部ファイルを指す `mod foo;` の探索、修飾された属性名や別名の解決、
`#[cfg]` の評価は行いません。RustCall はクレート解析において、
これらを扱うためのモジュールツリー走査と構成解決の処理を持っています。

## [syn、quote、proc-macro2 の役割](@id The-roles-of-syn-quote-and-proc-macro2)

| クレート | 役割 |
|---|---|
| `proc-macro2` | 手続きマクロの外でも使えるトークン列、識別子、Span |
| `syn` | トークンや文字列から AST を生成し、走査・変換する |
| `quote` | 補間（`#value`）を使ってトークン列を構築する |
| `prettyplease` | `syn::File` を読みやすい Rust ソースに整形する |

```text
Rust source string                 Compiler-provided tokens
        │                                     │
        ▼                                     │
proc_macro2::TokenStream ◄─────────────────────┘
        │
        │ syn: parse_str / parse2 (or parse_file for a file)
        ▼
Typed Rust AST
        │
        ├── inspect → metadata / TOML manifest
        │
        └── transform / quote! → TokenStream
                                     │
                                     ├── procedural macro output
                                     └── syn::parse2::<syn::File>
                                              → prettyplease::unparse
                                              → Rust source text
```

`syn::parse_str::<T>` は文字列を指定した構文型として解析し、
`syn::parse2::<T>` は `proc_macro2::TokenStream` を受け取ります。
`syn::parse::<T>` は手続きマクロ内でコンパイラの `proc_macro::TokenStream` を解析します。
Span はトークンとソース上の位置を関連付けて診断に役立ちますが、意味解析を行うものではありません。

`proc-macro2` を利用すると通常の実行可能プログラムと手続きマクロで同じトークンベースの実装を共有できます。
extractor は CLI であり、クレート向け属性はコンパイラ内で動く RustCall にとって特に重要な性質です。

## [AST の変更とコード生成](@id Transforming-an-AST-and-generating-code)

AST の各ノードは Rust の値です。関数の識別子を書き換え、変更したノードをトークン列に戻し、
整形することができます。

```rust
use quote::{format_ident, quote};
use syn::ItemFn;

fn main() {
    let mut f: ItemFn = syn::parse_str(
        "fn add(a: i32, b: i32) -> i32 { a + b }"
    ).unwrap();
    f.sig.ident = format_ident!("renamed_add");

    let tokens = quote! { #f };
    let file: syn::File = syn::parse2(tokens).unwrap();
    println!("{}", prettyplease::unparse(&file));
}
```

期待される出力：

```rust
fn renamed_add(a: i32, b: i32) -> i32 {
    a + b
}
```

`quote!` 内の `#f` は AST ノードのトークン列を補間します。
概念的には Julia の `quote` 内で式を補間する操作に似ています。
逆に、引用されたトークンから AST ノードを構築する `syn::parse_quote!` も便利です。

### [最小限の FFI ラッパー生成](@id A-minimal-FFI-wrapper-generator)

より RustCall に近い例として、元の Rust 関数をそのまま残し、C ABI の公開関数を追加します。
簡単のため、ここで示す 2 引数の `i32` 関数の署名に限定しています。

```rust
use quote::{format_ident, quote};
use syn::ItemFn;

fn main() {
    let f: ItemFn = syn::parse_str(
        "fn add(a: i32, b: i32) -> i32 { a + b }"
    ).unwrap();

    let name = &f.sig.ident;
    let wrapper = format_ident!("rustcall_{}", name);

    let generated = quote! {
        #f

        #[unsafe(no_mangle)]
        pub extern "C" fn #wrapper(a: i32, b: i32) -> i32 {
            #name(a, b)
        }
    };

    let file: syn::File = syn::parse2(generated).unwrap();
    println!("{}", prettyplease::unparse(&file));
}
```

期待される生成コード（整形は異なる場合があります）：

```rust
fn add(a: i32, b: i32) -> i32 {
    a + b
}
#[unsafe(no_mangle)]
pub extern "C" fn rustcall_add(a: i32, b: i32) -> i32 {
    add(a, b)
}
```

公開属性には現代の Rust の構文（Rust 1.82 以降）を用いています。
このプログラムはソースコードを出力するだけで、ラッパーのコンパイルやロードは行いません。
教育用の例であり、RustCall の実際のラッパーとは異なります。
panic の境界、任意の署名に対する検証、借用や所有権の管理、複数スロットの戻り値処理などはありません。
RustCall は共通の FFI 型契約とコード生成によってこれらの処理を追加します。

## [AST の走査・変換 API](@id Traversal-and-transformation-APIs)

| Cargo feature | 用途 |
|---|---|
| `full` | ファイルや項目の AST |
| `parsing` | トークンや文字列の構文解析 |
| `printing` | AST ノードからトークン列への変換 |
| `extra-traits` | Debug、等値比較、ハッシュなどの追加実装 |
| `clone-impls` | Clone の実装 |
| `visit` | 共有参照による再帰的な走査 |
| `visit-mut` | AST の再帰的なインプレース変更 |
| `fold` | 所有権を受け取る AST 変換 |

既定で有効な feature もありますが、最初の例では必要な追加機能を明示しています。
`visit` を使うと、関心のあるノードだけの処理を実装し、既定の走査に委譲して子ノードを再帰的に処理できます。

```rust
use syn::{visit::Visit, ItemFn};

#[derive(Default)]
struct FunctionCollector {
    names: Vec<String>,
}

impl<'ast> Visit<'ast> for FunctionCollector {
    fn visit_item_fn(&mut self, node: &'ast ItemFn) {
        self.names.push(node.sig.ident.to_string());
        // Delegate to the default visitor to recurse into children.
        syn::visit::visit_item_fn(self, node);
    }
}

fn main() {
    let file = syn::parse_file(
        "fn top() {} mod nested { fn inner() {} }"
    ).unwrap();
    let mut collector = FunctionCollector::default();
    collector.visit_file(&file);

    assert_eq!(collector.names, vec!["top", "inner"]);
}
```

この例はインラインモジュールを走査します。別ファイルのモジュールを読み込んだり、
マクロを展開したりするには visitor 以外の処理が必要です。

## [RustCall における syn の利用](@id How-RustCall-uses-syn)

共通の Rust コアの
[Cargo.toml](https://github.com/AtelierArith/RustCall.jl/blob/main/deps/rustcall_julia_core/Cargo.toml)
は次のような依存関係を宣言しています（関係する項目を抜粋）。

```toml
syn = { version = "2.0", features = [
    "full", "parsing", "printing", "extra-traits",
    "visit", "visit-mut", "clone-impls"
] }
proc-macro2 = { version = "1.0", features = ["span-locations"] }
quote = "1.0"
prettyplease = "0.2"
```

さらにマニフェスト用の Serde と TOML なども利用しています。
インライン Rust と外部クレートの属性は共通のコアを使うため、
Rust 側のラッパー生成規則と署名の記述は同じ実装を基盤としています。

```text
rust"""..."""                   #[julia] in a Cargo crate
      │                                  │
      ▼                                  ▼
rustcall-extract (CLI)           rustcall_julia_macros_impl
      │                          (procedural macro)
      └──────────────┬───────────────────┘
                     ▼
           rustcall_julia_core
           syn-based AST / shared codegen
              ├── extract.rs
              ├── expand.rs
              ├── codegen.rs
              └── specialize.rs
                     │
      ┌──────────────┴──────────────┐
      ▼                             ▼
FFI manifest (extractor)      C-ABI wrapper code
      │                             │
Julia wrapper generation         rustc / Cargo
      │                             │
      └───────── ccall ─────────────┘
```

`deps/` 以下の主なソースファイルは次の通りです。

| ファイル | 役割 |
|---|---|
| [rustcall_julia_core/src/extract.rs](https://github.com/AtelierArith/RustCall.jl/blob/main/deps/rustcall_julia_core/src/extract.rs) | Rust 構文やクレートのモジュールツリーから FFI メタデータを抽出 |
| [rustcall_julia_core/src/expand.rs](https://github.com/AtelierArith/RustCall.jl/blob/main/deps/rustcall_julia_core/src/expand.rs) | インラインの `#[julia]` 項目を展開 |
| [rustcall_julia_core/src/codegen.rs](https://github.com/AtelierArith/RustCall.jl/blob/main/deps/rustcall_julia_core/src/codegen.rs) | C ABI ラッパーと関連ヘルパーを生成 |
| [rustcall_julia_core/src/specialize.rs](https://github.com/AtelierArith/RustCall.jl/blob/main/deps/rustcall_julia_core/src/specialize.rs) | 対応するインラインジェネリック項目を AST レベルで具体化 |
| [rustcall_julia_macros_impl/src/lib.rs](https://github.com/AtelierArith/RustCall.jl/blob/main/deps/rustcall_julia_macros_impl/src/lib.rs) | 手続きマクロの入口として共通コアに委譲 |

extractor は `syn::parse_file(source)?` を使ってソースファイルを解析します。
一方、手続きマクロはコンパイラからトークン列を受け取り、
例えば `syn::parse::<ItemFn>(item.clone())` で解析します。
通常の外部クレートの場合、extractor が別途ソースを走査してマニフェストを取得し、
実際のラッパーはコンパイル時に手続きマクロが生成します。

Julia は別の Rust パーサーを実装するのではなく、TOML マニフェストを利用します。
Rust 構文を Rust 側だけで解析することは意図的な設計上の不変条件であり、
Julia 側での正規表現による Rust 構文解析を lint で検査しています。

## [Julia のメタプログラミングとの比較](@id Comparison-with-Julia-metaprogramming)

| Julia | Rust エコシステム（概念上の対応） |
|---|---|
| `Meta.parse` | `syn::parse_str` |
| `Expr` | `syn::Expr`、`syn::Item` などの型付き AST |
| 識別子としての `Symbol` | `syn::Ident` / `proc_macro2::Ident` |
| `quote ... end` | `quote! { ... }`（トークン列）、`syn::parse_quote!`（AST） |
| 引用した式内でのドル記号による補間 | `quote!` の `#value` 補間 |
| MacroTools.jl の走査 | `syn::visit`、`visit_mut`、`fold` と Rust のパターンマッチ |
| Julia マクロ | Rust の手続きマクロ |

厳密に同じ仕組みというわけではありません。
Julia は通常の表層構文を汎用的な `Expr` で表現する一方、syn は Rust の文法に対応する型付き AST を定義します。
Rust の手続きマクロがコンパイラとやり取りするのは syn の AST そのものではなく、トークン列です。

## [syn だけでは分からないこと](@id What-syn-cannot-tell-you)

syn は **構文解析器であり、Rust コンパイラではありません**。

| 機能 | syn 単体 |
|---|---|
| Rust の構文解析と属性の取得 | 可能 |
| AST の構築・変換 | 可能 |
| 記述された型・ライフタイム・ジェネリック構文の取得 | 可能 |
| 一般的な名前解決・型推論 | 不可 |
| trait の解決・借用検査 | 不可 |
| 任意のマクロの展開・ビルド構成の評価 | 不可 |
| 一般的な型レイアウトや ABI 互換性の判定 | 不可 |
| 機械語の生成 | 不可 |

例えば次のコードを考えます。

```rust
type MyFloat = f64;

fn compute(x: MyFloat) -> MyFloat {
    x * x
}
```

syn は `MyFloat` を型のパスとして取得し、型エイリアスの宣言を認識できます。
しかし、クレートグラフ全体にわたるエイリアス、import、関連型、実際の型レイアウトを一般的に解決するわけではありません。
利用側で限定的な名前解決や構成解析を実装することはできますが、コンパイルの最終的な判断は rustc が行います。
関数の構文を解析できても、任意の C ABI で安全に呼び出せるということにはなりません。

この違いが、RustCall が任意の Rust 型の自動バインディングを約束するのではなく、
対応する FFI 型契約を定めている理由です。
[FFI の型契約](type_contract.md) と [外部クレートのバインディング](crate_bindings.md) も参照してください。

## [参考資料](@id Further-reading)

これらの技術は FFI ジェネレーターのほか、構文ベースの静的解析、リファクタリング、
ドキュメント情報の抽出、DSL などにも利用できます。意味解析が必要な場合はコンパイラと連携するツールを使います。

- [syn API ドキュメント](https://docs.rs/syn/latest/syn/)
- [syn リポジトリ](https://github.com/dtolnay/syn)
- [quote API ドキュメント](https://docs.rs/quote/latest/quote/)
- [proc-macro2 API ドキュメント](https://docs.rs/proc-macro2/latest/proc_macro2/)
- [prettyplease API ドキュメント](https://docs.rs/prettyplease/latest/prettyplease/)
- [Rust Reference: procedural macros](https://doc.rust-lang.org/reference/procedural-macros.html)
