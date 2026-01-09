# Cxx.jl プロジェクト概要

## プロジェクトの目的

**Cxx.jl** は、Julia言語からC++コードを直接呼び出すためのForeign Function Interface (FFI) パッケージです。JuliaとC++の相互運用性を実現し、C++のライブラリやコードをJuliaからシームレスに利用できるようにします。

## 主な特徴

### 1. C++ Foreign Function Interface (FFI)

- **直接的なC++呼び出し**: JuliaからC++の関数、クラス、名前空間を直接呼び出し可能
- **`@cxx` マクロ**: Juliaの構文を活用してC++コードを実行
  - 静的関数呼び出し: `@cxx mynamespace::func(args...)`
  - メンバー呼び出し: `@cxx m->foo(args...)`
  - 値参照: `@cxx foo`
- **文字列リテラル**:
  - `cxx""`: グローバルスコープでC++コードを評価（名前空間、クラス、関数、グローバル変数の宣言など）
  - `icxx""`: 関数スコープでC++コードを評価（関数呼び出しや計算の実行）

### 2. C++ REPL機能

- Julia REPLにC++ REPLパネルを追加
- `<` キーでC++ REPLモードに切り替え可能
- インタラクティブにC++コードを実行・テスト可能

### 3. 高度な機能

- **C++クラスのインスタンス化**: `@cxxnew` マクロでC++オブジェクトを作成
- **共有ライブラリのサポート**: 既存のC++共有ライブラリ（.so, .dylib, .dll）を読み込み可能
- **C++列挙型のサポート**: C++のenumをJuliaから直接アクセス
- **型変換**: JuliaとC++の型を自動的に変換

## 技術的な実装

### アーキテクチャ

Cxx.jlは以下のJuliaの高度な機能を活用しています:

1. **LLVM IR統合**
   - `llvmcall` を使用してLLVM IRを直接Juliaコードに埋め込み
   - Clangで生成したLLVM IRをJuliaのコンパイルパイプラインに統合
   - 最適化がJuliaとC++の両方のコードに適用される

2. **ステージド関数（Staged Functions）**
   - `@generated` 関数を使用して型情報を活用
   - コンパイル時に型に基づいて適切なC++関数を選択
   - 関数オーバーロードの解決を実行時ではなくコンパイル時に行う

3. **マクロとステージド関数の連携**
   - `@cxx` マクロが構文を解析し、ステージド関数に型情報を渡す
   - ステージド関数がClang ASTを生成し、LLVM IRにコンパイル
   - 最終的に`llvmcall`で実行

### 実装の詳細

- **Clang統合**: ClangのC++パーサーとセマンティック解析を使用
- **型システム**: Juliaの型システムとC++の型システムを橋渡し
- **メモリ管理**: C++オブジェクトのライフサイクル管理（`CppPtr`, `CppRef`, `CppValue`）

## プロジェクト構造

```
Cxx.jl/
├── src/
│   ├── Cxx.jl              # メインモジュール
│   ├── clangwrapper.jl     # Clang APIのラッパー
│   ├── clanginstances.jl   # Clangインスタンス管理
│   ├── codegen.jl          # LLVM IRコード生成
│   ├── cxxmacro.jl         # @cxx マクロの実装
│   ├── cxxstr.jl           # cxx"" と icxx"" 文字列リテラル
│   ├── cxxtypes.jl         # C++型のJulia表現
│   ├── typetranslation.jl  # 型変換ロジック
│   ├── initialization.jl   # 初期化処理
│   ├── exceptions.jl       # C++例外の処理
│   ├── utils.jl            # ユーティリティ関数
│   ├── show.jl             # 表示用の関数
│   ├── std.jl              # C++標準ライブラリのヘルパー
│   ├── autowrap.jl         # 自動ラッピング機能
│   └── CxxREPL/
│       └── replpane.jl     # C++ REPL実装
├── deps/
│   ├── build.jl            # ビルドスクリプト
│   ├── build_libcxxffi.jl  # libcxxffiのビルド
│   └── llvm_patches/       # LLVMへのパッチ
├── docs/                   # ドキュメント
└── test/                   # テストスイート
```

## 現在の状態と制限事項

### 対応バージョン

- **Julia**: 1.1.x ～ 1.3.x のみ（現在は非サポートバージョン）
- **新しいJuliaバージョン**: [CxxWrap.jl](https://github.com/JuliaInterop/CxxWrap.jl) の使用を推奨
- **プラットフォーム**: 64ビット Linux、macOS、Windows

### 既知の制限

- 関数の再定義ができない（新しいコンパイラインスタンスを作成することで回避可能）
- Windowsサポートは初期段階
- macOS Sonomaでは手動修正が必要な場合がある

## 使用例

### 基本的な使用

```julia
using Cxx

# C++コードを埋め込み
cxx"""
    void print_hello() {
        std::cout << "Hello from C++!" << std::endl;
    }
"""

# Julia関数として呼び出し
julia_function() = @cxx print_hello()
julia_function()  # "Hello from C++!" を出力
```

### クラスの使用

```julia
cxx"""
    class MyClass {
    public:
        int value;
        MyClass(int v) : value(v) {}
        int get_value() { return value; }
    };
"""

obj = @cxxnew MyClass(42)
result = @cxx obj->get_value()  # 42
```

### 共有ライブラリの使用

```julia
using Cxx
using Libdl

# 共有ライブラリを読み込み
Libdl.dlopen("path/to/libexample.so", Libdl.RTLD_GLOBAL)
addHeaderDir("path/to/headers", kind=C_System)
cxxinclude("example.h")

# C++クラスを使用
obj = @cxxnew ExampleClass()
```

## ビルド要件

### システム要件

Juliaのビルドに必要な[システム要件](https://github.com/JuliaLang/julia#required-build-tools-and-external-libraries)に加えて:

- **Debian/Ubuntu**: `libedit-dev`, `libncurses5-dev`
- **RedHat/CentOS**: `libedit-devel`

### ビルド方法

```julia
pkg> build Cxx
```

## 関連プロジェクト

- **[CxxWrap.jl](https://github.com/JuliaInterop/CxxWrap.jl)**: 新しいJuliaバージョン向けのC++相互運用パッケージ（推奨）

## 参考文献

- [公式ドキュメント](https://JuliaInterop.github.io/Cxx.jl/stable)
- [GitHub リポジトリ](https://github.com/JuliaInterop/Cxx.jl)
