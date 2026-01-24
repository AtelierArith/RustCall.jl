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

# クレートをバインド (絶対パスを推奨)
# プロジェクトルートから実行する場合:
sample_crate_path = joinpath(dirname(dirname(pathof(LastCall))), "examples", "sample_crate")
@rust_crate sample_crate_path

# または直接パスを指定:
# @rust_crate "/full/path/to/LastCall.jl/examples/sample_crate"

# カスタムモジュール名を使用する場合:
# @rust_crate sample_crate_path name="SC"

# 生成されたモジュール (Samplecrate) を通じて関数を呼び出す
Samplecrate.add(Int32(2), Int32(3))           # => 5
Samplecrate.multiply(2.0, 3.0)                # => 6.0
Samplecrate.fibonacci(UInt32(10))             # => 55
Samplecrate.is_prime(UInt32(7))               # => true

# Result型を返す関数
Samplecrate.safe_divide(10.0, 2.0)  # => 5.0 (成功時)
Samplecrate.safe_divide(10.0, 0.0)  # => エラー (DivisionByZero)

# Option型を返す関数
Samplecrate.safe_sqrt(4.0)   # => 2.0 (Some)
Samplecrate.safe_sqrt(-1.0)  # => nothing (None)

# 構造体の使用
p = Samplecrate.Point(3.0, 4.0)
Samplecrate.distance_from_origin(p)  # => 5.0

# プロパティアクセス構文でフィールドにアクセス
p.x  # => 3.0
p.y  # => 4.0

c = Samplecrate.Counter(Int32(0))
Samplecrate.increment(c)
Samplecrate.get(c)  # => 1
c.value             # => 1 (プロパティアクセス)

r = Samplecrate.Rectangle(3.0, 4.0)
Samplecrate.area(r)       # => 12.0
Samplecrate.is_square(r)  # => false
```

**注意事項:**
- `@rust_crate` は絶対パスまたは `joinpath` を使用したパス指定を推奨します
- 生成されるモジュール名はクレート名のアンダースコアを除いた `titlecase` 形式です（例: `sample_crate` → `Samplecrate`）
- `name="CustomName"` オプションでカスタムモジュール名を指定できます
- 整数型は `Int32` や `UInt32` などの具体的な型を使用してください

## テスト

Rustテストの実行:

```bash
cargo test
```

## 依存関係

- `lastcall_macros`: `#[julia]` 属性マクロを提供（ローカルパス参照）
