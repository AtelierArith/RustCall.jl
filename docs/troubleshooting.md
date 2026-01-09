# LastCall.jl トラブルシューティングガイド

このガイドでは、LastCall.jlを使用する際によくある問題とその解決方法を説明します。

## 目次

1. [インストールとセットアップ](#インストールとセットアップ)
2. [コンパイルエラー](#コンパイルエラー)
3. [実行時エラー](#実行時エラー)
4. [型関連の問題](#型関連の問題)
5. [メモリ管理の問題](#メモリ管理の問題)
6. [パフォーマンスの問題](#パフォーマンスの問題)
7. [よくある質問](#よくある質問)

## インストールとセットアップ

### 問題: rustcが見つからない

**エラーメッセージ:**
```
rustc not found in PATH. LastCall.jl requires Rust to be installed.
```

**解決方法:**

1. Rustがインストールされているか確認：
   ```bash
   rustc --version
   ```

2. Rustがインストールされていない場合：
   - [rustup.rs](https://rustup.rs/)からインストール
   - または、パッケージマネージャーを使用：
     ```bash
     # macOS
     brew install rust

     # Ubuntu/Debian
     sudo apt-get install rustc cargo
     ```

3. PATHに追加されているか確認：
   ```bash
   echo $PATH | grep rust
   ```

### 問題: Rust helpersライブラリがビルドできない

**エラーメッセージ:**
```
Rust helpers library not found. Ownership types (Box, Rc, Arc) will not work...
```

**解決方法:**

1. ビルドを実行：
   ```julia
   using Pkg
   Pkg.build("LastCall")
   ```

2. Cargoが利用可能か確認：
   ```bash
   cargo --version
   ```

3. ビルドログを確認：
   ```bash
   cat deps/build.log
   ```

4. 手動でビルド：
   ```bash
   cd deps/rust_helpers
   cargo build --release
   ```

### 問題: 依存関係のインストールエラー

**解決方法:**

1. Juliaのバージョンを確認（1.10以上が必要）：
   ```julia
   VERSION
   ```

2. パッケージを再インストール：
   ```julia
   using Pkg
   Pkg.rm("LastCall")
   Pkg.add("LastCall")
   ```

## コンパイルエラー

### 問題: Rustコードのコンパイルエラー

**エラーメッセージ:**
```
error: expected one of ...
```

**解決方法:**

1. Rustコードの構文を確認：
   - `#[no_mangle]`属性が付いているか
   - `pub extern "C"`が正しく指定されているか
   - 関数シグネチャが正しいか

2. 正しい例：
   ```rust
   #[no_mangle]
   pub extern "C" fn my_function(x: i32) -> i32 {
       x * 2
   }
   ```

3. エラーメッセージを詳しく確認：
   ```julia
   # キャッシュをクリアして再コンパイル
   clear_cache()
   rust"""
   // 修正したコード
   """
   ```

### 問題: リンクエラー

**エラーメッセージ:**
```
undefined symbol: ...
```

**解決方法:**

1. 関数名が正しいか確認（`#[no_mangle]`が必要）
2. ライブラリが正しくロードされているか確認：
   ```julia
   using LastCall
   # ライブラリを再ロード
   ```

3. プラットフォーム固有の問題を確認：
   - macOS: `.dylib`ファイルが存在するか
   - Linux: `.so`ファイルが存在するか
   - Windows: `.dll`ファイルが存在するか

### 問題: 型の不一致エラー

**エラーメッセージ:**
```
ERROR: type mismatch
```

**解決方法:**

1. Rust関数のシグネチャを確認：
   ```rust
   pub extern "C" fn add(a: i32, b: i32) -> i32
   ```

2. Julia側で正しい型を使用：
   ```julia
   # 正しい
   @rust add(Int32(10), Int32(20))::Int32

   # 間違い
   @rust add(10, 20)  # 型が推論されない可能性
   ```

3. 型マッピング表を確認（[README.md](../README.md)参照）

## 実行時エラー

### 問題: 関数が見つからない

**エラーメッセージ:**
```
Function 'my_function' not found in library
```

**解決方法:**

1. 関数名のスペルを確認
2. `#[no_mangle]`属性が付いているか確認
3. ライブラリが正しくコンパイルされているか確認：
   ```julia
   clear_cache()
   rust"""
   #[no_mangle]
   pub extern "C" fn my_function() -> i32 { 42 }
   """
   ```

### 問題: セグメンテーションフォルト

**エラーメッセージ:**
```
signal (11): Segmentation fault
```

**解決方法:**

1. ポインタの有効性を確認：
   ```julia
   # 危険: 無効なポインタ
   ptr = Ptr{Cvoid}(0x1000)

   # 安全: 有効な配列から取得
   arr = [1, 2, 3]
   ptr = pointer(arr)
   GC.@preserve arr begin
       # ptrを使用
   end
   ```

2. 配列の境界を確認：
   ```julia
   arr = [1, 2, 3]
   len = length(arr)
   # lenを超えるインデックスにアクセスしない
   ```

3. メモリ管理を確認（所有権型を使用している場合）

### 問題: 文字列のエンコーディングエラー

**エラーメッセージ:**
```
invalid UTF-8 sequence
```

**解決方法:**

1. UTF-8文字列を正しく処理：
   ```rust
   let c_str = unsafe { std::ffi::CStr::from_ptr(s as *const i8) };
   let utf8_str = std::str::from_utf8(c_str.to_bytes())
       .unwrap_or("");  // エラーハンドリング
   ```

2. Julia側で文字列を正しく渡す：
   ```julia
   # UTF-8文字列は自動的に処理される
   @rust process_string("こんにちは")::UInt32
   ```

## 型関連の問題

### 問題: 型推論が失敗する

**解決方法:**

1. 明示的に型を指定：
   ```julia
   # 推奨
   result = @rust add(10i32, 20i32)::Int32

   # 非推奨
   result = @rust add(10i32, 20i32)
   ```

2. 引数の型を明示的に指定：
   ```julia
   a = Int32(10)
   b = Int32(20)
   result = @rust add(a, b)::Int32
   ```

### 問題: ポインタ型の変換エラー

**解決方法:**

1. 正しいポインタ型を使用：
   ```julia
   # Rust: *const i32
   # Julia: Ptr{Int32}

   arr = Int32[1, 2, 3]
   ptr = pointer(arr)
   ```

2. C文字列の場合は`String`を直接使用：
   ```julia
   # Rust: *const u8
   # Julia: String（自動変換）
   @rust process_string("hello")::UInt32
   ```

## メモリ管理の問題

### 問題: メモリリーク

**解決方法:**

1. 所有権型を使用している場合、適切に`drop!`を呼び出す：
   ```julia
   box = RustBox{Int32}(ptr)
   try
       # boxを使用
   finally
       drop!(box)  # 必ずクリーンアップ
   end
   ```

2. ファイナライザーが正しく動作しているか確認

### 問題: 二重解放エラー

**エラーメッセージ:**
```
double free or corruption
```

**解決方法:**

1. `drop!`を一度だけ呼び出す：
   ```julia
   box = RustBox{Int32}(ptr)
   drop!(box)
   # drop!(box)  # エラー: 二度呼ばない
   ```

2. `is_dropped`で状態を確認：
   ```julia
   if !is_dropped(box)
       drop!(box)
   end
   ```

### 問題: 無効なポインタアクセス

**解決方法:**

1. ポインタの有効性を確認：
   ```julia
   if box.ptr != C_NULL && !is_dropped(box)
       # 安全に使用
   end
   ```

2. `is_valid`を使用：
   ```julia
   if is_valid(box)
       # 安全に使用
   end
   ```

## パフォーマンスの問題

### 問題: コンパイルが遅い

**解決方法:**

1. キャッシュが機能しているか確認：
   ```julia
   # 最初のコンパイル（遅い）
   rust"""
   // コード
   """

   # 2回目以降（キャッシュから高速）
   rust"""
   // 同じコード
   """
   ```

2. キャッシュの状態を確認：
   ```julia
   get_cache_size()
   list_cached_libraries()
   ```

### 問題: 関数呼び出しが遅い

**解決方法:**

1. `@rust_llvm`を試す（実験的）：
   ```julia
   # 通常の呼び出し
   result = @rust add(10i32, 20i32)::Int32

   # LLVM IR統合（最適化の可能性）
   result = @rust_llvm add(Int32(10), Int32(20))
   ```

2. ベンチマークを実行して比較：
   ```bash
   julia --project benchmark/benchmarks.jl
   ```

3. 型推論を避けて明示的に型を指定

## よくある質問

### Q: 複数のRustライブラリを同時に使用できますか？

A: はい、可能です。各`rust""`ブロックは独立したライブラリとしてコンパイルされます：

```julia
rust"""
// ライブラリ1
#[no_mangle]
pub extern "C" fn func1() -> i32 { 1 }
"""

rust"""
// ライブラリ2
#[no_mangle]
pub extern "C" fn func2() -> i32 { 2 }
"""

# 両方を使用可能
result1 = @rust func1()::Int32
result2 = @rust func2()::Int32
```

### Q: Rustのジェネリクスは使用できますか？

A: 現在、ジェネリクスは直接サポートされていません。`extern "C"`関数では具体的な型を使用する必要があります。将来的にはサポートを検討しています。

### Q: Rustの構造体を返すことはできますか？

A: 現在、基本型とポインタ型のみサポートされています。構造体を返す場合は、`#[repr(C)]`を使用し、Julia側で対応する構造体を定義する必要があります（実験的）。

### Q: デバッグモードでコンパイルできますか？

A: はい、`RustCompiler`の設定を変更できます（内部実装）。通常は最適化レベル2でコンパイルされます。

### Q: キャッシュをクリアする必要があるのはいつですか？

A: 以下の場合にキャッシュをクリアしてください：
- Rustコードを変更した後
- コンパイルエラーが発生した後
- 予期しない動作が発生した後

```julia
clear_cache()
```

### Q: Windowsで動作しますか？

A: はい、Windows、macOS、Linuxで動作します。ただし、Rust toolchainが正しくインストールされている必要があります。

### Q: パフォーマンスはどうですか？

A: `@rust`マクロは標準的なFFIオーバーヘッドがあります。`@rust_llvm`（実験的）は最適化の可能性がありますが、すべてのケースで高速化されるわけではありません。ベンチマークを実行して確認してください。

### Q: エラーハンドリングのベストプラクティスは？

A:
1. Rust側で`Result`型を使用
2. Julia側で`result_to_exception`を使用して例外に変換
3. または、`unwrap_or`でデフォルト値を提供

```julia
result = some_rust_function()
value = unwrap_or(result, default_value)
```

## 追加のヘルプ

問題が解決しない場合は：

1. [GitHub Issues](https://github.com/your-repo/LastCall.jl/issues)で既存のIssueを検索
2. 新しいIssueを作成（エラーメッセージ、再現可能なコード、環境情報を含める）
3. [ドキュメント](../README.md)を確認
4. [チュートリアル](tutorial.md)を参照

## デバッグのヒント

### 1. 詳細なログを有効にする

```julia
using Logging
global_logger(ConsoleLogger(stderr, Logging.Debug))
```

### 2. キャッシュをクリア

```julia
clear_cache()
```

### 3. Rustコードを個別にテスト

```bash
cd /tmp
cat > test.rs << 'EOF'
#[no_mangle]
pub extern "C" fn test() -> i32 { 42 }
EOF
rustc --crate-type cdylib test.rs
```

### 4. ライブラリの状態を確認

```julia
# キャッシュされたライブラリをリスト
list_cached_libraries()

# キャッシュサイズを確認
get_cache_size()
```

### 5. 型情報を確認

```julia
# 型マッピングを確認
rusttype_to_julia(:i32)  # => Int32
juliatype_to_rust(Int32)  # => "i32"
```

## まとめ

このトラブルシューティングガイドで問題が解決しない場合は、GitHub Issuesで質問してください。問題を報告する際は、以下の情報を含めてください：

- Juliaのバージョン
- LastCall.jlのバージョン
- Rustのバージョン
- オペレーティングシステム
- エラーメッセージの全文
- 再現可能な最小限のコード例
