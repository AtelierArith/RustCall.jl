# LastCall.jl プロジェクト進行状況

最終更新: 2025年1月

## プロジェクト概要

LastCall.jlは、JuliaからRustコードを直接呼び出すためのFFI（Foreign Function Interface）パッケージです。Cxx.jlを参考に、RustとJuliaの相互運用性を実現します。

## 現在のフェーズ

**Phase 1: C互換ABI統合** ✅ **完了**

- 目標: `extern "C"`を使った基本的なRust-Julia連携
- 実装アプローチ: 共有ライブラリ（`.so`/`.dylib`/`.dll`）経由の`ccall`
- 進捗: **基本機能実装完了** ✅

**Phase 2: LLVM IR統合** ✅ **完了**

- 目標: LLVM IRレベルでの直接統合と最適化
- 実装アプローチ: LLVM.jlによるIR操作、`llvmcall`埋め込み（実験的）
- 進捗: **主要機能実装完了** ✅

## 実装状況

### ✅ Phase 1: 実装済み機能

#### 1. プロジェクト基盤
- [x] プロジェクト構造のセットアップ
- [x] `Project.toml`の設定（LLVM.jl依存関係）
- [x] モジュール構造の構築

#### 2. 型システム（基本）
- [x] 基本型マッピング（`i32` ↔ `Int32`, `f64` ↔ `Float64`等）
- [x] ポインタ型のサポート（`*const T`, `*mut T` → `Ptr{T}`）
- [x] `RustResult<T, E>`型の実装
- [x] `RustOption<T>`型の実装
- [x] 型変換関数（`rusttype_to_julia`, `juliatype_to_rust`）

#### 3. Rustコンパイラ統合
- [x] `rustc`ラッパー（`compiler.jl`）
- [x] LLVM IR生成（`--emit llvm-ir`）
- [x] 共有ライブラリ生成（`--crate-type cdylib`）
- [x] プラットフォーム別ターゲット検出
- [x] コンパイルオプション設定（最適化レベル、デバッグ情報）

#### 4. `rust""` 文字列リテラル
- [x] Rustコードのコンパイルとロード
- [x] ライブラリ管理（複数ライブラリのサポート）
- [x] 関数ポインタのキャッシング
- [x] LLVM IR分析（オプション）

#### 5. `@rust` マクロ
- [x] 基本的な関数呼び出し
- [x] 明示的な戻り値型指定（`@rust func(args...)::Type`）
- [x] ライブラリ修飾呼び出し（`@rust lib::func(args...)`）
- [x] 型推論（引数の型から戻り値型を推論）

#### 6. `@irust` マクロ（関数スコープ実行）
- [x] 基本的な実装
- [x] 引数の明示的受け渡し
- [x] 型推論（引数の型から戻り値型を推論）
- [x] コンパイル済み関数のキャッシング

#### 7. コード生成
- [x] `ccall`式の生成
- [x] 型に応じた専用関数（Int32, Int64, Float32, Float64, Bool, Cvoid, UInt32）
- [x] 文字列型のサポート（String引数、Cstring引数）
- [x] 動的ディスパッチ

#### 8. 文字列型のサポート
- [x] C文字列（`*const u8`）入力のサポート
- [x] Juliaの`String`引数の自動変換
- [x] `RustString`, `RustStr`型の定義
- [x] 型マッピング（`String` ↔ `*const u8`）
- [x] 文字列変換関数

### ✅ Phase 2: 実装済み機能

#### 1. エラーハンドリング
- [x] `RustError`例外型の実装
- [x] `result_to_exception`関数（`Result<T, E>` → 例外変換）
- [x] `unwrap_or_throw`エイリアス
- [x] エラーコードサポート

#### 2. LLVM最適化パス
- [x] `OptimizationConfig`構造体
- [x] `optimize_module!`関数（モジュールレベル最適化）
- [x] `optimize_function!`関数（関数レベル最適化）
- [x] `optimize_for_speed!` / `optimize_for_size!`便利関数
- [x] 最適化レベル0-3のサポート
- [x] ベクトル化、ループ展開、LICMオプション

#### 3. LLVM IRコード生成
- [x] `LLVMCodeGenerator`構造体
- [x] `@rust_llvm`マクロ（実験的）
- [x] `@generated`関数による最適化コード生成
- [x] 関数登録システム（`RustFunctionInfo`）
- [x] LLVM IRからの型推論

#### 4. LLVM統合の改善
- [x] LLVM.jl 9.x API互換性の修正
- [x] `llvm_type_to_julia`の更新（具体型ベース）
- [x] `julia_type_to_llvm`の更新
- [x] LLVM IR解析の改善

#### 5. 拡張された所有権型システム
- [x] `RustBox<T>` - ヒープ割り当て値（単一所有権）
- [x] `RustRc<T>` - 参照カウント（シングルスレッド）
- [x] `RustArc<T>` - アトミック参照カウント（マルチスレッド）
- [x] `RustVec<T>` - 可変長配列
- [x] `RustSlice<T>` - スライス（借用ビュー）
- [x] `drop!`関数（明示的なメモリ解放）
- [x] `is_dropped` / `is_valid`関数（状態チェック）
- [x] ファイナライザーによる自動クリーンアップ

#### 6. テストスイート拡充
- [x] エラーハンドリングテスト（15テスト）
- [x] LLVM最適化設定テスト（5テスト）
- [x] LLVM型変換テスト（6テスト）
- [x] LLVMモジュールロードテスト（8テスト）
- [x] LLVMコードジェネレータテスト（4テスト）
- [x] 拡張所有権型テスト（21テスト）
- **合計: 120テスト、すべてパス** ✅

### ⏳ 未実装・部分実装機能

#### Phase 2 の残りタスク

1. **`@rust_llvm`の実用化**
   - [x] 基本的な実装完了
   - [ ] 実際の`llvmcall`埋め込みの完全実装
   - [ ] パフォーマンステストとベンチマーク
   - [ ] エラーハンドリングの改善

2. **所有権型の実用化**
   - [x] 型定義と基本機能完了
   - [ ] Rust側での実際のメモリ管理との統合
   - [ ] `Box::new`, `Arc::new`等のRust関数との連携
   - [ ] 実際のドロップ関数の呼び出し

3. **配列・コレクション型の実用化**
   - [x] `RustVec<T>`, `RustSlice<T>`型定義完了
   - [ ] Julia配列との相互変換
   - [ ] メモリ管理の統合
   - [ ] インデックスアクセスの実装

4. **ジェネリクス対応**
   - [ ] 単相化（monomorphization）
   - [ ] 型パラメータの推論
   - [ ] ジェネリック関数のコンパイル

### 🔮 Phase 3 の計画（実験的・未着手）

1. **rustc内部API統合**（実験的）
   - [ ] rustcの内部APIを使用した型システム統合
   - [ ] Lifetimeの完全サポート
   - [ ] Borrow checkerとの統合
   - [ ] マクロシステムの完全サポート

2. **高度な型システム**
   - [ ] Lifetimeの基本サポート
   - [ ] Traitの基本サポート
   - [ ] 関連型（Associated Types）のサポート

## ファイル構成

```
LastCall.jl/
├── Project.toml          # ✅ 依存関係設定済み
├── README.md              # ✅ プロジェクト説明
├── src/
│   ├── LastCall.jl       # ✅ メインモジュール
│   ├── types.jl          # ✅ Rust型のJulia表現（拡張）
│   ├── typetranslation.jl # ✅ 型変換ロジック
│   ├── compiler.jl       # ✅ rustcラッパー
│   ├── llvmintegration.jl # ✅ LLVM.jl統合（Phase 2対応）
│   ├── llvmoptimization.jl # ✅ LLVM最適化パス（新規）
│   ├── llvmcodegen.jl   # ✅ LLVM IRコード生成（新規）
│   ├── codegen.jl        # ✅ ccall生成ロジック
│   ├── exceptions.jl    # ✅ エラーハンドリング（新規）
│   ├── rustmacro.jl      # ✅ @rustマクロ
│   └── ruststr.jl        # ✅ rust""と@irust実装
├── test/
│   └── runtests.jl       # ✅ 120テスト（全パス）
└── docs/
    ├── design/           # ✅ 設計ドキュメント
    │   ├── Phase1.md
    │   ├── Phase2.md
    │   ├── INTERNAL.md
    │   └── ...
    └── STATUS.md         # ✅ このファイル
```

## テスト状況

### テストカバレッジ

| カテゴリ | テスト数 | ステータス |
|---------|---------|-----------|
| 型マッピング | 23 | ✅ 全パス |
| RustResult | 8 | ✅ 全パス |
| RustOption | 8 | ✅ 全パス |
| エラーハンドリング | 15 | ✅ 全パス |
| 文字列変換 | 4 | ✅ 全パス |
| コンパイラ設定 | 6 | ✅ 全パス |
| Rustコンパイル | 4 | ✅ 全パス |
| `@irust` | 3 | ✅ 全パス |
| 文字列引数 | 3 | ✅ 全パス |
| ライブラリ管理 | 1 | ✅ 全パス |
| Phase 2: LLVM統合 | 25 | ✅ 全パス |
| - 最適化設定 | 5 | ✅ 全パス |
| - LLVM型変換 | 6 | ✅ 全パス |
| - LLVMモジュールロード | 8 | ✅ 全パス |
| - LLVMコードジェネレータ | 4 | ✅ 全パス |
| - 関数登録 | 1 | ✅ 全パス |
| - 拡張所有権型 | 21 | ✅ 全パス |
| **合計** | **120** | **✅ 全パス** |

### テスト実行コマンド

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

**最新結果**: 120テスト、すべてパス ✅

## 既知の制限事項

### Phase 1 の制限

1. **型システム**
   - `extern "C"`関数のみサポート
   - ジェネリクス非対応
   - Lifetime非対応
   - Trait非対応

2. **`@irust`マクロ**
   - 引数は明示的に渡す必要がある（`@irust("code", args...)`）
   - Julia変数の自動バインディング（`$var`構文）は未実装
   - 戻り値型は引数の型から推論（簡易的）

3. **文字列・配列**
   - C文字列（`*const u8`）入力はサポート済み ✅
   - Rust `String`戻り値のメモリ管理は未実装
   - `Vec<T>`の型定義は完了、実用化は未完了

### Phase 2 の制限

1. **`@rust_llvm`マクロ**
   - 実験的実装（基本的な機能のみ）
   - 実際の`llvmcall`埋め込みは部分的
   - パフォーマンステスト未実施

2. **所有権型**
   - 型定義と基本機能は完了
   - Rust側での実際のメモリ管理との統合は未完了
   - 実際のドロップ関数の呼び出しは未実装

3. **LLVM最適化**
   - 最適化パスは実装済み
   - 実際のパフォーマンス改善の検証は未実施

### 技術的制約

1. **ccallの制約**
   - Juliaの`ccall`はリテラル型タプルを要求
   - 動的な型タプル生成が困難
   - 解決策: 型ごとに専用関数を定義

2. **rustc API**
   - rustcの内部APIは不安定
   - Phase 1-2では`extern "C"`とLLVM IRを使用
   - Phase 3でrustc内部API統合を検討（実験的）

3. **LLVM.jl API**
   - LLVM.jl 9.xのAPI変更に対応済み ✅
   - 今後のバージョンアップに対応が必要な可能性

## パフォーマンス

### 現在の実装

- **コンパイル**: 各`rust""`呼び出しでrustcを実行（キャッシュなし）
- **関数呼び出し**: `ccall`経由（標準的なFFIオーバーヘッド）
- **型推論**: 実行時（コンパイル時ではない）

### Phase 2での改善

- **LLVM最適化**: 最適化パス実装済み（効果は未検証）
- **`@rust_llvm`**: 実験的実装（パフォーマンステスト未実施）

### 最適化の機会

1. **コンパイルキャッシング**
   - [ ] コードハッシュベースのキャッシュ
   - [ ] 永続化キャッシュ（ディスク保存）

2. **型推論の改善**
   - [x] LLVM IR分析による型推論（実装済み）
   - [ ] コンパイル時の型確定の改善

3. **Phase 2での改善**
   - [x] LLVM最適化パスの実装完了
   - [ ] `llvmcall`によるインライン化の実用化
   - [ ] パフォーマンスベンチマーク

## 次のステップ

### 短期（Phase 2 完了後の改善）

1. **`@rust_llvm`の実用化**（優先度: 高）
   - 実際の`llvmcall`埋め込みの完全実装
   - パフォーマンステストとベンチマーク
   - エラーハンドリングの改善
   - ドキュメントの充実

2. **所有権型の実用化**（優先度: 高）
   - Rust側での実際のメモリ管理との統合
   - `Box::new`, `Arc::new`等のRust関数との連携
   - 実際のドロップ関数の呼び出し
   - メモリリークのテスト

3. **配列・コレクション型の実用化**（優先度: 中）
   - Julia配列との相互変換
   - メモリ管理の統合
   - インデックスアクセスの実装
   - パフォーマンステスト

4. **パフォーマンス最適化**（優先度: 中）
   - コンパイルキャッシングの実装
   - ベンチマークスイートの作成
   - プロファイリングとボトルネック特定

### 中期（Phase 2 機能の拡張）

1. **ジェネリクス対応**（優先度: 中）
   - 単相化（monomorphization）
   - 型パラメータの推論
   - ジェネリック関数のコンパイル

2. **`@irust`の改善**（優先度: 低）
   - Julia変数の自動バインディング（`$var`構文）
   - より良いエラーメッセージ
   - 型推論の改善

3. **エラーハンドリングの強化**（優先度: 低）
   - コンパイルエラーの詳細表示
   - 実行時エラーの詳細表示
   - デバッグモード

### 長期（Phase 3 実験的）

1. **rustc内部API統合**（実験的・優先度: 低）
   - rustcの内部APIを使用した型システム統合
   - Lifetimeの完全サポート
   - Borrow checkerとの統合
   - マクロシステムの完全サポート

2. **高度な型システム**
   - Lifetimeの基本サポート
   - Traitの基本サポート
   - 関連型（Associated Types）のサポート

## 技術的メモ

### 実装上の重要な決定

1. **ccallの型タプル問題**
   - 問題: `ccall`はリテラル型タプルを要求
   - 解決: 型ごとに専用関数を定義（`_call_rust_i32_0`, `_call_rust_i32_1`等）
   - 影響: 引数の数と型の組み合わせごとに関数が必要

2. **`@irust`の実装アプローチ**
   - Phase 1では簡易実装（引数を明示的に渡す）
   - Phase 2で`@generated`関数による改善を検討（部分的に実装）

3. **LLVM IR統合**
   - Phase 1では分析目的のみ使用
   - Phase 2で`llvmcall`埋め込みを実装（実験的）
   - LLVM.jl 9.x API互換性を確保

4. **所有権型の実装**
   - Julia側で型定義と基本機能を実装
   - 実際のメモリ管理はRust側で行う
   - ファイナライザーによる自動クリーンアップ

### 参考実装

- **Cxx.jl**: `llvmcall`のポインタ形式を使用
- **CxxWrap.jl**: より現代的なアプローチ（参考）
- **LLVM.jl**: LLVM IR操作のAPI

## 変更履歴

### 2025-01（Phase 2 実装完了）

- ✅ Phase 2: LLVM IR統合の主要機能実装
- ✅ エラーハンドリング（`RustError`, `result_to_exception`）
- ✅ LLVM最適化パス（`OptimizationConfig`, `optimize_module!`）
- ✅ LLVM IRコード生成（`@rust_llvm`マクロ、実験的）
- ✅ 拡張所有権型（`RustBox`, `RustRc`, `RustArc`, `RustVec`, `RustSlice`）
- ✅ LLVM.jl 9.x API互換性の修正
- ✅ テストスイート拡充（120テスト、全パス）
- ✅ PR #1 マージ完了

### 2025-01（文字列型サポート追加）

- ✅ 文字列型（`*const u8`、`Cstring`）のサポート追加
- ✅ `RustString`, `RustStr`型の定義
- ✅ 文字列引数の自動変換（Julia String → Cstring）
- ✅ `UInt32`戻り値型のサポート追加
- ✅ 文字列変換関数の追加
- ✅ テストスイート拡充（60テスト）

### 2025-01（初期実装）

- ✅ プロジェクト構造の作成
- ✅ 基本型システムの実装
- ✅ `rust""`文字列リテラルの実装
- ✅ `@rust`マクロの実装
- ✅ `@irust`マクロの基本実装
- ✅ README.mdの作成
- ✅ テストスイート（45テスト）

## 関連ドキュメント

- [README.md](../README.md) - プロジェクト概要と使用例
- [docs/design/Phase1.md](design/Phase1.md) - Phase 1詳細実装プラン
- [docs/design/Phase2.md](design/Phase2.md) - Phase 2詳細実装プラン
- [docs/design/INTERNAL.md](design/INTERNAL.md) - Cxx.jl内部実装の参考
- [docs/design/LLVMCALL.md](design/LLVMCALL.md) - Julia `llvmcall`の詳細
- [CLAUDE.md](../CLAUDE.md) - 開発ガイド
