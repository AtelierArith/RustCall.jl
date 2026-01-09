# LastCall.jl チュートリアル

このチュートリアルでは、LastCall.jlを使ってJuliaからRustコードを呼び出す方法を段階的に学びます。

## 目次

1. [はじめに](#はじめに)
2. [基本的な使い方](#基本的な使い方)
3. [型システムの理解](#型システムの理解)
4. [文字列の扱い](#文字列の扱い)
5. [エラーハンドリング](#エラーハンドリング)
6. [所有権型の使用](#所有権型の使用)
7. [LLVM IR統合（上級）](#llvm-ir統合上級)
8. [パフォーマンス最適化](#パフォーマンス最適化)

## はじめに

### インストール

```julia
using Pkg
Pkg.add("LastCall")
```

### 要件

- Julia 1.10以上
- Rust toolchain（`rustc`と`cargo`）がPATHに含まれていること

Rustをインストールするには、[rustup.rs](https://rustup.rs/)を参照してください。

### Rust Helpersライブラリのビルド（オプション）

所有権型（Box, Rc, Arc）を使用する場合は、Rust helpersライブラリをビルドする必要があります：

```julia
using Pkg
Pkg.build("LastCall")
```

## 基本的な使い方

### ステップ1: Rustコードの定義とコンパイル

`rust""`文字列リテラルを使ってRustコードを定義し、コンパイルします：

```julia
using LastCall

rust"""
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""
```

このコードは自動的にコンパイルされ、共有ライブラリとしてロードされます。

### ステップ2: Rust関数の呼び出し

`@rust`マクロを使って関数を呼び出します：

```julia
# 型推論を使用
result = @rust add(Int32(10), Int32(20))::Int32
println(result)  # => 30

# または、明示的に戻り値型を指定
result = @rust add(10i32, 20i32)::Int32
```

### ステップ3: 複数の関数を定義

同じ`rust""`ブロック内で複数の関数を定義できます：

```julia
rust"""
#[no_mangle]
pub extern "C" fn multiply(x: f64, y: f64) -> f64 {
    x * y
}

#[no_mangle]
pub extern "C" fn subtract(a: i64, b: i64) -> i64 {
    a - b
}
"""

# 使用
product = @rust multiply(3.0, 4.0)::Float64  # => 12.0
difference = @rust subtract(100i64, 30i64)::Int64  # => 70
```

## 型システムの理解

### 基本型のマッピング

LastCall.jlはRust型とJulia型を自動的にマッピングします：

| Rust型 | Julia型 | 例 |
|--------|---------|-----|
| `i8` | `Int8` | `10i8` |
| `i16` | `Int16` | `100i16` |
| `i32` | `Int32` | `1000i32` |
| `i64` | `Int64` | `10000i64` |
| `u8` | `UInt8` | `10u8` |
| `u32` | `UInt32` | `1000u32` |
| `u64` | `UInt64` | `10000u64` |
| `f32` | `Float32` | `3.14f0` |
| `f64` | `Float64` | `3.14159` |
| `bool` | `Bool` | `true` |
| `usize` | `UInt` | `100u` |
| `isize` | `Int` | `100` |
| `()` | `Cvoid` | - |

### 型推論

LastCall.jlは引数の型から戻り値型を推論しようとしますが、明示的に指定することを推奨します：

```julia
# 推論に頼る（動作するが推奨しない）
result = @rust add(10i32, 20i32)

# 明示的に型を指定（推奨）
result = @rust add(10i32, 20i32)::Int32
```

### ブール値の扱い

```julia
rust"""
#[no_mangle]
pub extern "C" fn is_positive(x: i32) -> bool {
    x > 0
}
"""

@rust is_positive(Int32(5))::Bool   # => true
@rust is_positive(Int32(-5))::Bool  # => false
```

## 文字列の扱い

### C文字列として渡す

Rust関数が`*const u8`（C文字列）を受け取る場合、Juliaの`String`を直接渡せます：

```julia
rust"""
#[no_mangle]
pub extern "C" fn string_length(s: *const u8) -> u32 {
    let c_str = unsafe { std::ffi::CStr::from_ptr(s as *const i8) };
    c_str.to_bytes().len() as u32
}
"""

# Julia Stringは自動的にCstringに変換されます
len = @rust string_length("hello")::UInt32  # => 5
len = @rust string_length("世界")::UInt32   # => 6 (UTF-8 bytes)
```

### UTF-8文字列の扱い

```julia
rust"""
#[no_mangle]
pub extern "C" fn count_chars(s: *const u8) -> u32 {
    let c_str = unsafe { std::ffi::CStr::from_ptr(s as *const i8) };
    let utf8_str = std::str::from_utf8(c_str.to_bytes()).unwrap();
    utf8_str.chars().count() as u32
}
"""

# UTF-8文字数をカウント
count = @rust count_chars("hello")::UInt32    # => 5
count = @rust count_chars("世界")::UInt32     # => 2 (characters, not bytes)
```

## エラーハンドリング

### Result型の使用

Rustの`Result<T, E>`型は`RustResult{T, E}`としてJuliaで表現されます：

```julia
rust"""
#[no_mangle]
pub extern "C" fn divide(a: i32, b: i32) -> i32 {
    if b == 0 {
        return -1;  // エラーコードとして-1を返す
    }
    a / b
}
"""

# エラーチェック
result = @rust divide(Int32(10), Int32(2))::Int32
if result == -1
    println("Division by zero!")
end
```

### RustResultの明示的な使用

よりRustらしい方法では、`Result`型を返す関数を定義できます：

```julia
# RustResultを手動で作成
ok_result = RustResult{Int32, String}(true, Int32(42))
is_ok(ok_result)  # => true
unwrap(ok_result)  # => 42

err_result = RustResult{Int32, String}(false, "error message")
is_err(err_result)  # => true
unwrap_or(err_result, Int32(0))  # => 0
```

### 例外への変換

`result_to_exception`を使って`Result`をJulia例外に変換できます：

```julia
err_result = RustResult{Int32, String}(false, "division by zero")
try
    value = result_to_exception(err_result)
catch e
    if e isa RustError
        println("Rust error: $(e.message)")
    end
end
```

## 所有権型の使用

### RustBox（単一所有権）

`RustBox<T>`はヒープ割り当て値で、単一の所有者を持ちます：

```julia
# Rust helpersライブラリが必要
if is_rust_helpers_available()
    # Boxを作成（通常はRust関数から返される）
    # ここでは例として、実際の使用はRust関数の戻り値から
    box = RustBox{Int32}(ptr)  # ptrはRust関数から取得

    # 使用後、明示的にドロップ
    drop!(box)
end
```

### RustRc（参照カウント、シングルスレッド）

```julia
if is_rust_helpers_available()
    # Rcを作成
    rc1 = RustRc{Int32}(ptr)

    # クローンして参照カウントを増やす
    rc2 = clone(rc1)

    # 一方をドロップしても、もう一方は有効
    drop!(rc1)
    @assert is_valid(rc2)  # まだ有効

    # 最後の参照をドロップ
    drop!(rc2)
end
```

### RustArc（アトミック参照カウント、マルチスレッド）

```julia
if is_rust_helpers_available()
    # Arcを作成
    arc1 = RustArc{Int32}(ptr)

    # スレッドセーフなクローン
    arc2 = clone(arc1)

    # 異なるタスクで使用可能
    @sync begin
        @async begin
            # arc2を使用
        end
    end

    drop!(arc1)
    drop!(arc2)
end
```

## LLVM IR統合（上級）

### @rust_llvmマクロの使用

`@rust_llvm`マクロは、LLVM IRレベルでの最適化された呼び出しを可能にします（実験的）：

```julia
rust"""
#[no_mangle]
pub extern "C" fn fast_add(a: i32, b: i32) -> i32 {
    a + b
}
"""

# 関数を登録
info = compile_and_register_rust_function("""
#[no_mangle]
pub extern "C" fn fast_add(a: i32, b: i32) -> i32 { a + b }
""", "fast_add")

# @rust_llvmで呼び出し（最適化された可能性がある）
result = @rust_llvm fast_add(Int32(10), Int32(20))  # => 30
```

### LLVM最適化の設定

```julia
using LastCall

# 最適化設定を作成
config = OptimizationConfig(
    level=3,  # 最適化レベル 0-3
    enable_vectorization=true,
    inline_threshold=300
)

# モジュールを最適化
# optimize_module!(module, config)

# 便利関数
# optimize_for_speed!(module)  # レベル3、積極的最適化
# optimize_for_size!(module)    # レベル2、サイズ最適化
```

## パフォーマンス最適化

### コンパイルキャッシュの活用

LastCall.jlは自動的にコンパイル結果をキャッシュします。同じコードを再コンパイルする必要はありません：

```julia
# 最初のコンパイル（時間がかかる）
rust"""
#[no_mangle]
pub extern "C" fn compute(x: i32) -> i32 {
    x * 2
}
"""

# 同じコードの再コンパイル（キャッシュから高速にロード）
rust"""
#[no_mangle]
pub extern "C" fn compute(x: i32) -> i32 {
    x * 2
}
"""
```

### キャッシュの管理

```julia
# キャッシュサイズを確認
size = get_cache_size()
println("Cache size: $size bytes")

# キャッシュされたライブラリをリスト
libs = list_cached_libraries()
println("Cached libraries: $libs")

# 古いキャッシュをクリーンアップ（30日以上古いもの）
cleanup_old_cache(30)

# キャッシュをクリア
clear_cache()
```

### ベンチマークの実行

パフォーマンスを測定するには：

```bash
julia --project benchmark/benchmarks.jl
```

これにより、Julia native、`@rust`、`@rust_llvm`のパフォーマンスが比較されます。

## ベストプラクティス

### 1. 型を明示的に指定する

```julia
# 推奨
result = @rust add(10i32, 20i32)::Int32

# 非推奨（型推論に頼る）
result = @rust add(10i32, 20i32)
```

### 2. エラーハンドリングを適切に行う

```julia
# Result型を使用
result = some_rust_function()
if is_err(result)
    # エラー処理
    return
end
value = unwrap(result)
```

### 3. メモリ管理に注意する

所有権型を使用する場合は、適切に`drop!`を呼び出してください：

```julia
box = RustBox{Int32}(ptr)
try
    # boxを使用
finally
    drop!(box)  # 必ずクリーンアップ
end
```

### 4. キャッシュを活用する

同じRustコードを複数回使用する場合は、キャッシュが自動的に活用されます。

### 5. デバッグ時はキャッシュをクリア

問題が発生した場合は、キャッシュをクリアして再コンパイルを試してください：

```julia
clear_cache()
```

## 次のステップ

- [実用例](examples.md)を参照して、より高度な使用例を学ぶ
- [トラブルシューティングガイド](troubleshooting.md)で問題を解決する
- [APIドキュメント](../README.md)で全機能を確認する
