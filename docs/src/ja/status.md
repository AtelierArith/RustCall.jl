<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/status.md. -->
# [プロジェクトの状況](@id Project-Status)

最終更新：2026-09-07（英語原稿の更新日）

## [概要](@id Summary)

| 項目 | 状況 |
|------|------|
| 基本 FFI（`rust"""`、`@rust`） | 実装済み |
| `@irust` / `irust"..."` | 0.8で非推奨、0.9で削除（#538） |
| Cargo 依存・構造体・julia 属性 | 実装済み |
| 外部クレート・ホットリロード | 実装済み |
| Julia General | 登録済み。`Pkg.add("RustCall")` |
| Julia テスト | runtests.jl と ParallelTestRunner |
| Julia / Rust CI | OS 別の test_args を含め設定済み |

## [コード規模](@id Codebase-Snapshot)

手集計は古くなるため維持しません（[#261](https://github.com/AtelierArith/RustCall.jl/issues/261)）。現在のツリーを測定してください。

```bash
git ls-files 'src/*.jl' 'src/**/*.jl' 'test/test_*.jl' 'benchmark/*.jl' 'deps/*/src/*.rs' | xargs wc -l
```

## [構造の案内](@id Architecture-Map)

### [Julia の入口](@id Julia-entry-points)

RustCall.jl がモジュール・export・初期化、ruststr.jl が文字列処理とビルド・読み込み、rustmacro.jl が呼び出し展開を担当します。

### [コンパイルと生成](@id Compilation-and-code-generation)

build/compiler.jl が rustc、ffi/codegen.jl が ccall を生成します。

### [型と実行時処理](@id Type-and-runtime-layer)

ffi/types.jl がラッパー、ffi_contract.jl が唯一の ABI・型・所有権・解放表、typetranslation.jl が変換、exceptions.jl が診断、memory.jl が所有権 helper を担当します。

### [Cargo とクレート](@id Cargo/crate-workflows)

build/dependencies.jl と dependency_resolution.jl が依存、cargoproject.jl と cargobuild.jl がビルド、macros/julia_functions.jl が属性、crate_bindings が[各部品](project_guide.md#Crate-binding-components)、loading/hot_reload.jl が再読み込みを扱います。

### [キャッシュとジェネリクス](@id Caching-and-generics)

artifacts/cache.jl が保存、macros/generics.jl が単相化を担当します。

## [テストと CI](@id Test-and-CI-Status)

### [Julia テスト](@id Julia-tests)

test/runtests.jl が test/test_*.jl を自動発見し、キャッシュ・所有権・配列・ジェネリクス・エラー・外部クレート・属性・再読み込み・回帰を検証します。

### [Rust の手続きマクロテスト](@id Rust-proc-macro-tests)

deps/rustcall_julia_macros/tests/ にあり、属性本体は macros_impl にあります。CI は fmt、全ターゲット・feature の clippy（警告もエラー）、cargo test を実行します。

### [GitHub Actions](@id GitHub-Actions)

CI.yml が Linux/macOS/Windows と複数 Rust ツールチェーンを検証します。

## [必要なツール](@id Tooling-Requirements)

Julia 1.12 以降と Rust ツールチェーンが必要です。Pkg.add が General から導入して helper を作ります。必要なら再ビルドします。

```julia
using Pkg
Pkg.build("RustCall")
```

## [現在の制約](@id Current-Limitations)

C ABI を中心とし、Julia 側で Rust のライフタイムや借用検査全体を再現しません。所有権型はインストール時の helper が必要です。複雑なジェネリクス・トレイト・外部バインディングは明示的な処理が必要な場合があります。初回の Cargo ビルドやプラットフォーム別設定にも費用があります。

推奨設計は[安全な連携](integration_guide.md)、実例は SafeLedger.jl、早期診断の改善は [#441](https://github.com/AtelierArith/RustCall.jl/issues/441) を参照してください。

## [達成した段階](@id Delivered-Milestones)

1. インライン、呼び出し、型・文字列・キャッシュ（irust は後に削除）。
2. 所有権 helper とジェネリクス。実験的 LLVM は0.3で削除（[#265](https://github.com/AtelierArith/RustCall.jl/issues/265)）。
3. Cargo 依存の宣言と利用。
4. 構造体とメソッドの対応。
5. julia 属性による生成。
6. 外部クレートとマクロクレート。
7. 当時の schema 4 と唯一の型契約、未知型の拒否、解放シンボルの必須化（#276、#245、#246、#249）。

## [近い将来の優先事項](@id Near-Term-Priorities)

原稿更新時点では、finalizer の統一と再有効化（#277 Phase B）、一時的な :warn の廃止、クレートと再読み込みの回帰強化、crates.io 配布準備を挙げています。
