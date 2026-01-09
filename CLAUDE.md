Read also AGENTS.md

# CLAUDE.md - LastCall.jl 開発ガイド

このドキュメントは、Cxx.jlをベースにした**LastCall.jl**の開発を進めるためのガイドです。

## プロジェクト目標

JuliaからRustコードを直接呼び出せるFFI（Foreign Function Interface）パッケージ「**LastCall.jl**」を開発する。

### 提供する機能

- `@rust` マクロ: Rust関数をJuliaから直接呼び出し
- `rust""` 文字列リテラル: Rustコードをグローバルスコープで評価
- `irust""` 文字列リテラル: Rustコードを関数スコープで評価
- Rustの型システムとの統合
- LLVM IR経由での最適化

## 関連ドキュメント

| ファイル | 内容 | 優先度 |
|----------|------|--------|
| `PLAN.md` | 全体計画・技術課題・解決策 | ★★★ 必読 |
| `Phase1.md` | Phase 1 詳細実装プラン（C互換ABI） | ★★★ 必読 |
| `Phase2.md` | Phase 2 詳細実装プラン（LLVM IR統合） | ★★☆ 重要 |
| `INTERNAL.md` | Cxx.jlの内部実装詳細 | ★★☆ 参考 |
| `LLVMCALL.md` | Julia `llvmcall` の詳細 | ★★☆ 参考 |
| `DESCRIPTION.md` | Cxx.jl概要 | ★☆☆ 背景知識 |

## 開発フェーズ

### Phase 1: C互換ABI統合（2-3ヶ月）

**目標**: `extern "C"` を使った基本的なRust-Julia連携

```
Julia (@rust マクロ)
    ↓
ccall ラッパー生成
    ↓
Rust共有ライブラリ (.so/.dylib/.dll)
    ↓
Rust関数呼び出し
```

**主要タスク**:
1. プロジェクト構造の作成
2. 基本型マッピング（`i32` ↔ `Int32` 等）
3. `@rust` マクロの実装（`ccall`ラッパー）
4. `rust""` 文字列リテラル（コンパイル・ロード）
5. `Result<T, E>` → Julia例外の変換
6. テストスイートの構築

**成果物**: 基本的なRust関数呼び出しが動作

### Phase 2: LLVM IR統合（4-6ヶ月）

**目標**: LLVM IRレベルでの直接統合

```
Julia (@rust マクロ)
    ↓
@generated 関数
    ↓
rustc (LLVM IR生成)
    ↓
LLVM.jl (IR操作)
    ↓
llvmcall 埋め込み
    ↓
Julia JIT実行
```

**主要タスク**:
1. LLVM.jl統合
2. rustc → LLVM IR パイプライン
3. IR最適化・変換
4. `llvmcall` への埋め込み
5. 所有権型のサポート（`Box<T>`、`Arc<T>`）
6. ジェネリクス対応

**成果物**: LLVM IRレベルでの最適化された統合

### Phase 3: rustc内部API統合（実験的）

**目標**: 完全なRust型システムサポート

- rustcの内部APIを使用
- 型推論・trait解決との連携
- 完全なジェネリクスサポート

**注意**: rustc APIは不安定。研究目的のみ推奨。

## 技術的な要点

### Cxx.jlから学ぶべきパターン

Cxx.jlの以下のコードは、LastCall.jlでも同様のパターンで実装する：

1. **`llvmcall`のポインタ形式**（`src/codegen.jl`）
```julia
# Cxx.jlの核心部分
Expr(:call, Core.Intrinsics.llvmcall,
     convert(Ptr{Cvoid}, f),  # LLVM関数ポインタ
     rett,                     # 戻り値の型
     Tuple{argt...},           # 引数の型
     args2...)                 # 実引数
```

2. **ステージド関数（@generated）**: 型情報に基づいてコンパイル時にコード生成

3. **型マッピング**: Julia型 ↔ ターゲット言語型の双方向変換

### Rust固有の課題

| 課題 | Cxx.jl | LastCall.jl |
|------|--------|---------|
| コンパイラAPI | Clang（安定） | rustc（不安定） |
| 型システム | C++型 | 所有権・lifetime |
| エラー処理 | 例外 | `Result<T, E>` |
| メモリ管理 | 手動/RAII | 所有権システム |

### 型マッピング（Phase 1）

```julia
# Rust → Julia
const RUST_JULIA_TYPE_MAP = Dict(
    "i8"    => Int8,
    "i16"   => Int16,
    "i32"   => Int32,
    "i64"   => Int64,
    "u8"    => UInt8,
    "u16"   => UInt16,
    "u32"   => UInt32,
    "u64"   => UInt64,
    "f32"   => Float32,
    "f64"   => Float64,
    "bool"  => Bool,
    "usize" => Csize_t,
    "isize" => Cssize_t,
    "()"    => Cvoid,
)
```

## Cxx.jlソースコード参照

LastCall.jl実装時に参考にすべきファイル：

| Cxx.jlファイル | 役割 | LastCall.jlでの対応 |
|----------------|------|-----------------|
| `src/cxxmacro.jl` | `@cxx`マクロ | `@rust`マクロ |
| `src/cxxstr.jl` | `cxx""`リテラル | `rust""`リテラル |
| `src/codegen.jl` | LLVM IR生成 | LLVM IR統合 |
| `src/typetranslation.jl` | 型変換 | Rust型変換 |
| `src/clangwrapper.jl` | Clangラッパー | rustc/cbindgen連携 |
| `src/cxxtypes.jl` | C++型定義 | Rust型定義 |

## 開発環境セットアップ

### 必要なツール

```bash
# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup component add rustfmt clippy

# Julia
julia --version  # 1.6以上推奨

# cbindgen（Phase 1で使用）
cargo install cbindgen
```

### プロジェクト作成

```bash
# 新しいJuliaパッケージを作成
julia -e 'using Pkg; Pkg.generate("Rust")'
cd Rust

# Rustライブラリを作成
cargo new --lib deps/rustlib
```

## 実装のヒント

### Phase 1: @rustマクロの基本形

```julia
macro rust(lib, expr)
    # 関数呼び出しの解析
    func_name, args = parse_rust_call(expr)

    # ccallの生成
    quote
        ccall(
            ($(QuoteNode(func_name)), $lib),
            $(return_type),
            $(Tuple{arg_types...}),
            $(args...)
        )
    end
end
```

### Phase 2: llvmcallへの埋め込み

```julia
@generated function rust_call(::Type{Val{func_name}}, args...)
    # 1. Rustコードをコンパイル（キャッシュ済みなら再利用）
    llvm_ir = compile_rust_to_llvm(func_name)

    # 2. LLVM関数を取得
    fn_ptr = get_function_pointer(llvm_ir, func_name)

    # 3. llvmcall式を生成
    quote
        $(Expr(:call, Core.Intrinsics.llvmcall,
               fn_ptr, ret_type, Tuple{arg_types...}, args...))
    end
end
```

## 注意事項

1. **Cxx.jlはJulia 1.3までサポート**: 参考にはなるが、最新Juliaでは動かない
2. **rustc APIは不安定**: Phase 3は実験的と位置づける
3. **所有権の扱い**: Phase 1では`extern "C"`で単純化、Phase 2で本格対応
4. **テストを先に書く**: TDDで進めると安全
5. 多重ディスパッチ (multiple dispatch) を積極的に使うこと．Juliaらしいコードを書くように心がけて．

## 参考リソース

- [Cxx.jl GitHub](https://github.com/JuliaInterop/Cxx.jl)
- [LLVM.jl](https://github.com/maleadt/LLVM.jl)
- [Rust FFI ガイド](https://doc.rust-lang.org/nomicon/ffi.html)
- [cbindgen](https://github.com/mozilla/cbindgen)
- [Julia llvmcall ドキュメント](https://docs.julialang.org/en/v1/devdocs/llvm/)

## 次のステップ

1. **PLAN.md を読む**: 全体像の把握
2. **Phase1.md を読む**: 具体的な実装タスクの確認
3. **INTERNAL.md を読む**: Cxx.jlの実装パターンを理解
4. **プロジェクト構造を作成**: Phase 1 開始

