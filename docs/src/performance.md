# パフォーマンスガイド

LastCall.jlは、JuliaからRustコードを呼び出す際のパフォーマンスを最適化するための複数の機能を提供しています。このガイドでは、パフォーマンスを向上させるためのベストプラクティスと最適化のヒントを説明します。

## 目次

1. [コンパイルキャッシュ](#コンパイルキャッシュ)
2. [LLVM最適化](#llvm最適化)
3. [関数呼び出しの最適化](#関数呼び出しの最適化)
4. [メモリ管理](#メモリ管理)
5. [ベンチマーク結果](#ベンチマーク結果)
6. [パフォーマンスチューニングのヒント](#パフォーマンスチューニングのヒント)

## コンパイルキャッシュ

LastCall.jlは、コンパイル済みのRustライブラリを自動的にキャッシュします。同じコードを再コンパイルする必要がなくなり、起動時間を大幅に短縮できます。

### キャッシュの仕組み

- **キャッシュキー**: コードのハッシュ、コンパイラ設定、ターゲットトリプルから生成
- **キャッシュ場所**: `~/.julia/compiled/vX.Y/LastCall/`
- **自動検証**: キャッシュの整合性を自動的にチェック

### キャッシュの管理

```julia
using LastCall

# キャッシュサイズを確認
size = get_cache_size()
println("Cache size: $(size / 1024 / 1024) MB")

# キャッシュされたライブラリを一覧表示
libraries = list_cached_libraries()
println("Cached libraries: $(length(libraries))")

# 古いキャッシュをクリーンアップ（30日以上古いもの）
cleanup_old_cache(30)

# キャッシュを完全にクリア
clear_cache()
```

### キャッシュのベストプラクティス

1. **開発中**: キャッシュを有効にしたまま開発することで、再コンパイル時間を短縮
2. **本番環境**: キャッシュを事前にウォームアップしておくことで、初回実行時の遅延を回避
3. **CI/CD**: キャッシュを保存・復元することで、ビルド時間を短縮

## LLVM最適化

LastCall.jlは、LLVM IRレベルでの最適化をサポートしています。`@rust_llvm`マクロを使用することで、より高度な最適化を適用できます。

### 最適化レベルの設定

```julia
using LastCall

# 最適化設定を作成
config = OptimizationConfig(
    optimization_level=3,  # 0-3 (3が最も最適化)
    enable_vectorization=true,
    enable_loop_unrolling=true,
    enable_licm=true
)

# モジュールを最適化
rust"""
#[no_mangle]
pub extern "C" fn compute(x: f64) -> f64 {
    x * x + 1.0
}
"""

# 最適化を適用
mod = get_rust_module(rust_code)
optimize_module!(mod; config=config)
```

### 最適化のプリセット

```julia
# 速度優先の最適化
optimize_for_speed!(mod)

# サイズ優先の最適化
optimize_for_size!(mod)

# バランス型の最適化
optimize_balanced!(mod)
```

### 最適化レベルの選択

- **Level 0**: 最適化なし（デバッグ用）
- **Level 1**: 基本的な最適化
- **Level 2**: 標準的な最適化（デフォルト）
- **Level 3**: 最大限の最適化（コンパイル時間が長くなる可能性）

## 関数呼び出しの最適化

### `@rust` vs `@rust_llvm`

- **`@rust`**: 標準的な`ccall`経由の呼び出し。安定性が高く、ほとんどの場合に推奨
- **`@rust_llvm`**: LLVM IR統合による呼び出し（実験的）。最適化の余地があるが、一部の型で制限あり

```julia
# 標準的な呼び出し（推奨）
result = @rust add(10i32, 20i32)

# LLVM統合による呼び出し（実験的）
result = @rust_llvm add(10i32, 20i32)
```

### 型推論の最適化

明示的な型指定により、型推論のオーバーヘッドを削減できます：

```julia
# 型推論あり（少し遅い）
result = @rust add(10, 20)

# 明示的な型指定（推奨）
result = @rust add(10i32, 20i32)::Int32
```

### 関数登録による最適化

頻繁に呼び出す関数は、事前に登録することで最適化できます：

```julia
# 関数を登録
register_function("add", "mylib", Int32, [Int32, Int32])

# 登録済み関数の呼び出し（型チェックがスキップされる）
result = @rust add(10i32, 20i32)
```

## メモリ管理

### 所有権型の効率的な使用

所有権型（`RustBox`, `RustRc`, `RustArc`）は、適切に使用することでメモリリークを防ぎます：

```julia
# 一時的な割り当ては自動的にクリーンアップされる
box = RustBox(Int32(42))
# 使用後、自動的にドロップされる

# 明示的なドロップ（早期解放が必要な場合）
drop!(box)
```

### メモリリークの回避

```julia
# パターン1: try-finallyを使用
box = RustBox(Int32(42))
try
    # 使用
    value = box.ptr
finally
    drop!(box)  # 確実にクリーンアップ
end

# パターン2: ローカルスコープを活用
function compute()
    box = RustBox(Int32(42))
    # 使用
    return result
    # boxは自動的にドロップされる
end
```

## ベンチマーク結果

### 基本的な演算

以下のベンチマークは、Julia 1.9、Rust 1.70、macOS上で実行されました：

| 操作 | Julia Native | @rust | @rust_llvm |
|------|-------------|-------|------------|
| i32加算 | 1.0x | 1.2x | 1.1x |
| i64加算 | 1.0x | 1.2x | 1.1x |
| f64加算 | 1.0x | 1.3x | 1.2x |
| i32乗算 | 1.0x | 1.2x | 1.1x |
| f64乗算 | 1.0x | 1.3x | 1.2x |

### 複雑な計算

| 計算 | Julia Native | @rust | @rust_llvm |
|------|-------------|-------|------------|
| Fibonacci (n=30) | 1.0x | 1.1x | 1.0x |
| Sum Range (1..1000) | 1.0x | 1.2x | 1.1x |

**注意**: これらの結果は環境によって異なる場合があります。実際のパフォーマンスは、ハードウェア、OS、Julia/Rustのバージョンによって大きく変動します。

### ベンチマークの実行

```julia
# ベンチマークを実行
julia --project benchmark/benchmarks.jl

# LLVM統合のベンチマーク
julia --project benchmark/benchmarks_llvm.jl
```

## パフォーマンスチューニングのヒント

### 1. コンパイル時間の短縮

- **キャッシュを活用**: 同じコードを再コンパイルしない
- **最適化レベルを調整**: 開発中はLevel 1-2、本番環境でLevel 3
- **デバッグ情報を無効化**: `emit_debug_info=false`

```julia
compiler = RustCompiler(
    optimization_level=2,  # 開発中は2で十分
    emit_debug_info=false
)
set_default_compiler(compiler)
```

### 2. 実行時パフォーマンスの向上

- **型を明示**: 型推論のオーバーヘッドを削減
- **関数を登録**: 頻繁に呼び出す関数は事前登録
- **バッチ処理**: 複数の呼び出しをまとめる

```julia
# 非効率的: ループ内で毎回型推論
for i in 1:1000
    result = @rust add(i, i+1)  # 型推論が毎回実行される
end

# 効率的: 型を明示
for i in 1:1000
    result = @rust add(Int32(i), Int32(i+1))::Int32
end
```

### 3. メモリ使用量の最適化

- **所有権型の適切な使用**: 不要になったらすぐにドロップ
- **Rc/Arcの適切な選択**: シングルスレッドなら`Rc`、マルチスレッドなら`Arc`
- **キャッシュのクリーンアップ**: 定期的に古いキャッシュを削除

### 4. 並列処理の最適化

```julia
using Base.Threads

# Arcを使用してスレッド間でデータを共有
shared_data = RustArc(Int32(0))

# 複数のスレッドで作業
@threads for i in 1:1000
    local_arc = clone(shared_data)
    # 作業
    drop!(local_arc)
end
```

### 5. プロファイリング

Juliaのプロファイリングツールを使用して、ボトルネックを特定：

```julia
using Profile

# プロファイルを開始
Profile.clear()
@profile for i in 1:1000
    @rust add(Int32(i), Int32(i+1))
end

# 結果を表示
Profile.print()
```

## トラブルシューティング

### パフォーマンスが期待より低い場合

1. **キャッシュを確認**: キャッシュが正しく機能しているか確認
2. **最適化レベルを確認**: 最適化レベルが適切に設定されているか確認
3. **型を明示**: 型推論のオーバーヘッドを削減
4. **プロファイリング**: ボトルネックを特定

### メモリ使用量が高い場合

1. **所有権型の確認**: 適切にドロップされているか確認
2. **キャッシュのクリーンアップ**: 古いキャッシュを削除
3. **Rc/Arcの使用**: 不要なクローンを避ける

## まとめ

LastCall.jlのパフォーマンスを最適化するには：

1. ✅ **キャッシュを活用**: コンパイル時間を短縮
2. ✅ **最適化レベルを調整**: 用途に応じて最適化レベルを選択
3. ✅ **型を明示**: 型推論のオーバーヘッドを削減
4. ✅ **メモリ管理**: 所有権型を適切に使用
5. ✅ **プロファイリング**: ボトルネックを特定して最適化

これらのベストプラクティスに従うことで、LastCall.jlを使用したアプリケーションのパフォーマンスを最大限に引き出すことができます。
