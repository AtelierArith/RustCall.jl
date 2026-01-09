# CLAUDE.md - プロジェクトガイド

このドキュメントは、Claudeがこのプロジェクトを理解し、効果的に支援するためのガイドです。

## プロジェクト概要

**Cxx.jl** は、JuliaからC++コードを直接呼び出すためのFFI（Foreign Function Interface）パッケージです。

### 主要な機能

- `@cxx` マクロ: C++関数をJuliaから直接呼び出し
- `cxx""` 文字列リテラル: C++コードをグローバルスコープで評価
- `icxx""` 文字列リテラル: C++コードを関数スコープで評価
- C++ REPL: Julia REPLにC++ REPLパネルを追加

### 現在の状態

- **対応バージョン**: Julia 1.1.x ～ 1.3.x（現在は非サポート）
- 新しいJuliaバージョンでは [CxxWrap.jl](https://github.com/JuliaInterop/CxxWrap.jl) を推奨

## ディレクトリ構造

```
Cxx.jl/
├── src/                    # メインソースコード
│   ├── Cxx.jl              # メインモジュール
│   ├── cxxmacro.jl         # @cxx マクロの実装
│   ├── cxxstr.jl           # cxx"" と icxx"" の実装
│   ├── cxxtypes.jl         # C++型のJulia表現
│   ├── typetranslation.jl  # 型変換ロジック
│   ├── codegen.jl          # LLVM IRコード生成
│   ├── clangwrapper.jl     # Clang APIのラッパー
│   ├── clanginstances.jl   # Clangインスタンス管理
│   ├── initialization.jl   # 初期化処理
│   ├── exceptions.jl       # C++例外の処理
│   └── CxxREPL/            # C++ REPL機能
├── deps/                   # ビルドスクリプトとLLVMパッチ
├── docs/                   # ドキュメント
├── test/                   # テストスイート
└── ドキュメント（.md）
```

## 重要なドキュメント

| ファイル | 内容 |
|----------|------|
| `DESCRIPTION.md` | プロジェクト概要 |
| `INTERNAL.md` | 内部実装の詳細（C++コードの処理フロー） |
| `LLVMCALL.md` | Juliaの`llvmcall`についての詳細 |
| `PLAN.md` | LastCall.jl実装計画書 |
| `Phase1.md` | Phase 1（C互換ABI）の詳細実装プラン |
| `Phase2.md` | Phase 2（LLVM IR統合）の詳細実装プラン |

## 技術的な仕組み

### 処理フロー

```
Juliaコード (@cxx マクロ)
    ↓
構文解析・型情報抽出 (cxxmacro.jl)
    ↓
ステージド関数 (@generated)
    ↓
Clang AST生成 (codegen.jl)
    ↓
LLVM IR生成 (Clang CodeGen)
    ↓
llvmcall埋め込み
    ↓
Julia実行時
```

### 重要な概念

1. **llvmcall**: LLVM IRを直接Juliaコードに埋め込む機能
2. **ステージド関数（@generated）**: コンパイル時に型情報に基づいてコードを生成
3. **Clang統合**: C++コードの解析とAST生成
4. **型変換**: Julia型とC++型の双方向変換

## 開発ガイドライン

### コードスタイル

- Juliaのコーディング規約に従う
- 関数名はスネークケース（例: `build_cpp_call`）
- 型名はパスカルケース（例: `CppValue`）
- コメントは英語で記述（既存のスタイルに合わせる）

### テスト

```bash
# テストの実行
julia --project -e 'using Pkg; Pkg.test()'
```

### ビルド

```bash
# ビルド
julia --project -e 'using Pkg; Pkg.build()'
```

## LastCall.jl 計画

Cxx.jlをベースに、Rust実装を呼び出す版（LastCall.jl）を計画中：

### Phase 1: C互換ABI（2-3ヶ月）
- `@rust` マクロ: `ccall`のラッパー
- 基本的な型マッピング
- `rust""` 文字列リテラル

### Phase 2: LLVM IR統合（4-6ヶ月）
- RustコードをLLVM IRにコンパイル
- `llvmcall`に埋め込む
- 所有権型のサポート

### Phase 3: rustc内部API（実験的）
- rustcの内部APIを使用
- 完全な型システムサポート

## よくある質問

### Q: Cxx.jlはなぜ最新のJuliaで動かないのか？

A: Cxx.jlは内部的にClangのAPIと密接に統合されており、JuliaのLLVMバージョンとの互換性が必要です。新しいJuliaバージョンではLLVMのバージョンが変わっており、対応が追いついていません。

### Q: LastCall.jlのPhase 1とPhase 2の違いは？

A: Phase 1はC互換ABI（`extern "C"`）を使用し、シンプルだがRustの高度な機能は使えません。Phase 2はLLVM IRを直接操作し、より柔軟な統合を実現しますが、実装が複雑です。

### Q: llvmcallの2つの形式の違いは？

A: 文字列形式はLLVM IRを文字列で渡し、Juliaがラップします。ポインタ形式は既存のLLVM関数へのポインタを渡し、ラップをスキップします。Cxx.jlはポインタ形式を使用しています。

## 関連リソース

- [Cxx.jl GitHub](https://github.com/JuliaInterop/Cxx.jl)
- [CxxWrap.jl](https://github.com/JuliaInterop/CxxWrap.jl)（新しいJuliaバージョン向け）
- [Julia Manual: llvmcall](https://docs.julialang.org/en/v1/manual/performance-tips/#man-llvm-call)
- [LLVM Language Reference](https://llvm.org/docs/LangRef.html)

## 注意事項

- このプロジェクトは学習・研究目的で使用してください
- 本番環境では CxxWrap.jl を推奨します
- LastCall.jlは計画段階であり、まだ実装されていません
