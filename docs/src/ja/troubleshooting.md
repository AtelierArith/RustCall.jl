<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/troubleshooting.md. -->
# [トラブルシューティング](@id troubleshooting)

RustCall.jl でよくある問題と対処方法を説明します。

```@setup troubleshooting
using RustCall
```

## [インストールと設定](@id Installation-and-Setup)

### [問題：動作する rustc がない](@id Problem:-no-working-rustc)

**診断例**：

```
No working rustc found. RustCall.jl resolves the compiler through RustToolChain.jl, ...
```

RustCall は [RustToolChain.jl](https://github.com/AtelierArith/RustToolChain.jl) にツールチェーンの選択を任せます。`PATH` の `rustc` を優先し、なければ Artifacts から取得します。この警告はどちらも実行できなかったという意味で、`PATH` にないことだけが原因ではありません。

**対処**：

1. 選択結果と元のエラーを確認します。

```julia
RustCall.check_toolchain()   # raises nothing; lists every problem it finds
```

選択した `rustc` / `cargo`、最低対応バージョン（`RustCall.minimum_supported_rustc()`、extractor の `rust-version`）、extractor の有無とスキーマを確認します。RustToolChain 自体の診断は ``using RustToolChain; run(`$(RustToolChain.rustc()) --version`)`` で確認できます。

2. システムの Rust を使うなら [rustup.rs](https://rustup.rs/) などから導入し、Julia を起動するシェルで `rustc --version` が動くことを確認します。`PATH` の `rustc` が Artifacts より優先されます。
3. Artifacts を使う場合、初回取得時のネットワーク接続や depot の書き込み権限を確認します。Windows では別途 MSVC のリンカーも必要です。
4. `VERSION` で Julia 1.12 以降か確認します。

### [問題：Rust ヘルパーのビルド失敗](@id Problem:-Rust-helpers-library-build-fails)

**診断例**：

```
Rust helpers library not found. Ownership types (Box, Rc, Arc) will not work...
```

**対処**：

1. ビルドを実行します。

```julia
using Pkg
Pkg.build("RustCall")
```

2. Cargo を確認します。

```bash
cargo --version
```

3. ビルドログを確認します。

```bash
cat deps/build.log
```

4. 手動でビルドします。

```bash
cd deps/rustcall_helpers
cargo build --release
```

## [コンパイルエラー](@id Compilation-Errors)

### [問題：Rust の構文エラー](@id Problem:-Rust-code-syntax-errors)

**診断例**：

```
error: expected one of ...
```

**対処**：

1. 手動の C ABI 関数では `#[no_mangle]`、`pub extern "C"`、シグネチャを確認します。
2. 正しい例です。

```rust
#[no_mangle]
pub extern "C" fn my_function(x: i32) -> i32 {
    x * 2
}
```

3. 診断の詳細を確認します。

```julia
# Clear cache and recompile
RustCall.clear_cache()
rust"""
// Fixed code
"""
```

### [問題：リンクエラー](@id Problem:-Linking-errors)

**診断例**：

```
undefined symbol: ...
```

**対処**：

1. 関数名と `#[no_mangle]` を確認します。
2. ライブラリの読み込みを確認します。
3. macOS は `.dylib`、Linux は `.so`、Windows は `.dll` があるか確認します。

### [問題：型の不一致](@id Problem:-Type-mismatch-errors)

**診断例**：

```
ERROR: type mismatch
```

**対処**：

1. Rust のシグネチャを確認します。

```rust
pub extern "C" fn add(a: i32, b: i32) -> i32
```

2. Julia 側で正しい型を使います。

```julia
# Correct
# @rust add(Int32(10), Int32(20))::Int32
```

3. 型の対応表を確認します。

## [実行時エラー](@id Runtime-Errors)

### [問題：関数が見つからない](@id Problem:-Function-not-found)

**診断例**：

```
Function 'my_function' not found in library
```

**対処**：

1. 関数名のつづりを確認します。
2. `#[no_mangle]` を確認します。
3. ライブラリのコンパイル結果を確認します。

```julia
RustCall.clear_cache()
rust"""
#[no_mangle]
pub extern "C" fn my_test_function() -> i32 { 42 }
"""
```

### [問題：セグメンテーション違反](@id Problem:-Segmentation-fault)

**診断例**：

```
signal (11): Segmentation fault
```

**対処**：

1. ポインタの有効性を確認します。

```julia
# Warning: Don't use invalid or Julia-managed pointers with Rust ownership types
```

2. 配列の範囲を確認します。
3. 所有権型を使う場合はメモリ管理を確認します。

## [メモリ管理](@id Memory-Management-Problems)

### [問題：メモリリーク](@id Problem:-Memory-leak)

所有権ラッパー（`RustBox`、`RustRc`、`RustArc`、`RustVec`）は finalizer が解放しますが、その時期は GC に依存します。早く解放したい場合は `RustCall.drop!` を使います。

```julia
box = RustCall.RustBox(Int32(42))
try
    # use box
finally
    RustCall.drop!(box)
end
```

`RustCall.drop!` は冪等で、2回目は何もしません。明示的解放と finalizer は競合しません。

### [問題：二重解放](@id Problem:-Double-free)

**診断例**：

```
double free or corruption
```

ラッパー自身の `drop!` は二重解放しません。同じポインタから所有権を持つラッパーを2つ作ったか、Julia が所有する値を Rust 側も解放した可能性があります。各割り当ての所有者を1つにします。Rust は `Box::into_raw` で所有権を渡したら、その値を再度解放してはいけません。

### [問題：無効なポインタへのアクセス](@id Problem:-Invalid-pointer-access)

`RustCall.is_valid` / `RustCall.is_dropped` は**ラッパーの状態だけ**を示します。解放済みや null なら無効ですが、ポインタの由来や Rust 側で既に解放されたかは分かりません。任意・ダングリングポインタから作ったラッパーは検査を通っても異常終了や二重解放を起こします。RustCall が割り当てた値や、Rust が `Box::into_raw` で渡して以後解放しない値など、所有権を確認したものの `drop!` 後使用を検出するために使います。

```julia
if RustCall.is_valid(box)
    # not dropped on the Julia side; ownership is still your guarantee
end
RustCall.is_dropped(box)  # true after drop!
```

## [よくある質問](@id FAQ)

### [キャッシュはいつ削除するか](@id Q:-When-should-I-clear-the-cache?)

通常は不要です。ソース・ツールチェーン・ビルド環境がキーに入るので、変更があれば再コンパイルします。`RustCall.clear_cache()` は成果物の破損が疑われる場合やディスク領域の回収に使います。

### [Windows でも使えるか](@id Q:-Does-it-work-on-Windows?)

はい。動作する Rust ツールチェーンがあれば Windows・macOS・Linux で使えます。Windows には MSVC ビルドツールも必要です（[Windows ガイド](platforms/windows.md)）。

### [複数の Rust ライブラリを同時に使えるか](@id Q:-Can-I-use-multiple-Rust-libraries-simultaneously?)

はい。1ブロックに複数関数を定義するか、複数ブロックを使えます。

```@example troubleshooting
# Multiple functions in one block
rust"""
#[no_mangle]
pub extern "C" fn calc_add(a: i32, b: i32) -> i32 { a + b }

#[no_mangle]
pub extern "C" fn calc_mul(a: i32, b: i32) -> i32 { a * b }
"""

result1 = @rust calc_add(Int32(10), Int32(20))::Int32
result2 = @rust calc_mul(Int32(3), Int32(4))::Int32
println("add result = $result1, mul result = $result2")
```

!!! note "関数名の一意性"
    全 `rust""` ブロックで名前を一意にしてください。複数のライブラリが同名を公開すると曖昧性エラーになります。

### [Rust のジェネリクスを使えるか](@id Q:-Can-I-use-Rust-generics?)

自動単相化に対応します。[ジェネリクス](generics.md)を参照してください。

### [エラー処理の推奨方法は](@id Q:-Best-practices-for-error-handling?)

1. Rust 側で `Result` を返す。
2. Julia 側で `result_to_exception` により例外へ変換する。
3. または `unwrap_or` で既定値を選ぶ。

## [デバッグのヒント](@id Debugging-Tips)

### [1. デバッグログ](@id 1.-Enable-debug-logging)

Julia 標準の Logging と `@debug`、`@info`、`@warn`、`@error` を使います。

**方法A：環境変数（推奨）**

`JULIA_DEBUG` を設定して起動します。

```bash
JULIA_DEBUG=RustCall julia -e 'using RustCall; ...'
```

読み込み前に Julia 内で設定することもできます。

```julia
ENV["JULIA_DEBUG"] = "RustCall"
using RustCall
```

**方法B：グローバルロガー**

```julia
using Logging
global_logger(ConsoleLogger(stderr, Logging.Debug))
using RustCall
```

Rust のコンパイル、ライブラリの読み込みとキャッシュ、ジェネリック関数の登録と単相化、関数ポインタの解決、エラー回復の試行を詳しく表示します。

### [2. キャッシュ削除](@id 2.-Clear-cache)

```julia
RustCall.clear_cache()
```

### [3. ライブラリの状態](@id 3.-Check-library-status)

```julia
# List cached libraries
RustCall.list_cached_libraries()

# Check cache size
RustCall.get_cache_size()
```

### [4. 型情報](@id 4.-Check-type-information)

```julia
# Check type mapping
RustCall.rusttype_to_julia(:i32)  # => Int32
RustCall.juliatype_to_rust(Int32)  # => "i32"

# What the FFI contract says about a position, including its ABI, its ccall
# slots and who releases it
RustCall.ffi_describe("String"; direction = :return, abi = "string")
```

### [5. "The FFI contract cannot describe the return type of ..."](@id 5.-"The-FFI-contract-cannot-describe-the-return-type-of-...")

導出できない戻り値型を推測することはありません。診断にシグネチャと既知の型情報を示します。[FFI の型契約](type_contract.md)を確認し、次の順に検討してください。

1. Rust のシグネチャを対応型へ変更します。集成型は値渡しではなく `*mut MyType` などにします。
2. `@rust f(x)::T` と明示して型推論を不要にします。
3. 保存済みバインディングでは一時的に `strict = :warn` で `Any` にし、残りをビルドしながら未対応型を修正できます。ただし `ccall` の `Any` は動作が明確に定義されないため、恒久対策にはしません。

### [6. "cannot call a Rust function without a return type"](@id 6.-"cannot-call-a-Rust-function-without-a-return-type")

`::T` のない `@rust f(x)` はマニフェストの戻り値型が必要です。`rust"""` 外でコンパイルした通常の `#[no_mangle] extern "C"` にはその情報がありません。`@rust f(x)::Int32` と書くか、`#[julia]` でシグネチャを記録させます。

以前は第1引数の型（なければ `Int64`）を戻り値と推測していましたが、引数からは導けず、幅を間違えると未定義動作となるため削除しました（#245、#246）。
