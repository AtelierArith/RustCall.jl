# sample_crate

`lastcall_macros` の `#[julia]` 属性を使用したデモ用Rustクレートです。

## 概要

このクレートは、LastCall.jl の `@rust_crate` マクロを使って外部Rustクレートをバインドする機能のテスト・デモンストレーション用に作成されています。

## Juliaからの使用例

### 基本的な使い方（REPL）

```julia
using LastCall

sample_crate_path = joinpath(pkgdir(LastCall), "examples", "sample_crate")
@rust_crate sample_crate_path

# 生成されたモジュール (SampleCrate) を通じて関数を呼び出す
SampleCrate.add(Int32(2), Int32(3))  # => 5

# 構造体の使用
p = SampleCrate.Point(3.0, 4.0)
SampleCrate.distance_from_origin(p)  # => 5.0

# プロパティアクセス
p.x  # => 3.0
p.y  # => 4.0
```

### テストでの使い方

```julia
using Test
using Pkg

Pkg.activate(joinpath(@__DIR__, "..", ".."))

using LastCall

sample_crate_path = joinpath(pkgdir(LastCall), "examples", "sample_crate")
@rust_crate sample_crate_path

@testset "SampleCrate" begin
    @testset "Point" begin
        p = SampleCrate.Point(3.0, 4.0)
        @test SampleCrate.distance_from_origin(p) == 5.0
        @test p.x == 3.0
        @test p.y == 4.0
    end

    @testset "基本関数" begin
        @test SampleCrate.add(Int32(2), Int32(3)) == Int32(5)
        @test SampleCrate.multiply(2.0, 3.0) == 6.0
        @test SampleCrate.fibonacci(UInt32(10)) == UInt64(55)
        @test SampleCrate.is_prime(UInt32(7)) == true
    end
end
```

## 含まれる機能

### 単純な関数

| 関数名 | シグネチャ | 説明 |
|--------|-----------|------|
| `add` | `(i32, i32) -> i32` | 二つの整数を加算 |
| `multiply` | `(f64, f64) -> f64` | 二つの浮動小数点数を乗算 |
| `fibonacci` | `(u32) -> u64` | n番目のフィボナッチ数を計算 |
| `is_prime` | `(u32) -> bool` | 素数判定 |

### Result<T, E> を返す関数

| 関数名 | シグネチャ | 説明 |
|--------|-----------|------|
| `safe_divide` | `(f64, f64) -> Result<f64, i32>` | 0除算を安全に処理する除算 |
| `parse_positive` | `(i32) -> Result<u32, i32>` | 正の整数のみを受け入れる |

### Option<T> を返す関数

| 関数名 | シグネチャ | 説明 |
|--------|-----------|------|
| `safe_sqrt` | `(f64) -> Option<f64>` | 負でない数値の平方根を計算 |
| `find_positive` | `(i32, i32) -> Option<i32>` | 二つの入力から最初の正の数を返す |

### 構造体

#### Point

2D座標を表す構造体。

```rust
pub struct Point { pub x: f64, pub y: f64 }
```

メソッド:
- `new(x, y)` - 新しい点を作成
- `distance_from_origin(&self)` - 原点からの距離
- `distance_to(&self, other_x, other_y)` - 別の点への距離
- `translate(&mut self, dx, dy)` - 点を移動

#### Counter

可変状態を持つカウンター。

```rust
pub struct Counter { pub value: i32 }
```

メソッド:
- `new(initial)` - 初期値を指定して作成
- `increment(&mut self)` - インクリメント
- `decrement(&mut self)` - デクリメント
- `add(&mut self, amount)` - 値を加算
- `get(&self)` - 現在値を取得
- `reset(&mut self)` - ゼロにリセット

#### Rectangle

長方形を表す構造体。

```rust
pub struct Rectangle { pub width: f64, pub height: f64 }
```

メソッド:
- `new(width, height)` - 新しい長方形を作成
- `area(&self)` - 面積を計算
- `perimeter(&self)` - 周囲長を計算
- `is_square(&self)` - 正方形かどうか判定
- `scale(&mut self, factor)` - スケーリング

## 注意事項

- `@rust_crate` は絶対パスまたは `joinpath` を使用したパス指定を推奨
- `pkgdir(LastCall)` でパッケージのルートディレクトリを取得可能
- 生成されたモジュールは呼び出し元のスコープに直接定義される
- モジュール名はクレート名をPascalCaseに変換（例: `sample_crate` → `SampleCrate`）
- `name="CustomName"` オプションでカスタムモジュール名を指定可能
- 整数型は `Int32` や `UInt32` などの具体的な型を使用

## ビルド

```bash
cd examples/sample_crate
cargo build --release
```

## Rustテスト

```bash
cargo test
```

## 依存関係

- `lastcall_macros`: `#[julia]` 属性マクロを提供（ローカルパス参照）
