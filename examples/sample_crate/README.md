# sample_crate

`lastcall_macros` の `#[julia]` 属性を使用したデモ用Rustクレートです。

## 概要

このクレートは、LastCall.jl の `@rust_crate` マクロを使って外部Rustクレートをバインドする機能のテスト・デモンストレーション用に作成されています。

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

## ビルド方法

```bash
cd examples/sample_crate
cargo build --release
```

## Juliaからの使用例

```julia
using LastCall

# クレートをバインド
@rust_crate "examples/sample_crate"

# 関数の呼び出し
add(2, 3)           # => 5
multiply(2.0, 3.0)  # => 6.0
fibonacci(10)       # => 55
is_prime(7)         # => true

# Result型を返す関数
safe_divide(10.0, 2.0)  # => 5.0 (成功時)
safe_divide(10.0, 0.0)  # => エラー

# Option型を返す関数
safe_sqrt(4.0)   # => 2.0 (Some)
safe_sqrt(-1.0)  # => nothing (None)

# 構造体の使用
p = Point_new(3.0, 4.0)
Point_distance_from_origin(p)  # => 5.0

c = Counter_new(0)
Counter_increment(c)
Counter_get(c)  # => 1

r = Rectangle_new(3.0, 4.0)
Rectangle_area(r)       # => 12.0
Rectangle_is_square(r)  # => false
```

## テスト

Rustテストの実行:

```bash
cargo test
```

## 依存関係

- `lastcall_macros`: `#[julia]` 属性マクロを提供（ローカルパス参照）
