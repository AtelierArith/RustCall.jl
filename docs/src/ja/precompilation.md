<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/precompilation.md. -->
# [プリコンパイルのサポート](@id Precompilation-Support)

RustCall.jl は Julia のプリコンパイルに対応し、Rust バインディングを使うパッケージの起動を高速化します。

## [概要](@id Overview)

`@rust_crate` のバインディングをパッケージと一緒にプリコンパイルすると、実行時のコンパイルを避けて起動時間を短縮できます。

### [利点](@id Benefits)

- **起動の高速化**：コンパイル済みバインディングを素早く読み込みます。
- **配布への対応**：実行時コンパイルを省けます。
- **再現可能なビルド**：同じバインディングを使えます。
- **PackageCompiler.jl との互換性**：独立したアプリを作れます。

## [仕組み](@id How-It-Works)

### [実行時とプリコンパイル時](@id Runtime-vs-Precompile-Time)

どちらの方法もバインディングをプリコンパイルできます。

**パッケージのトップレベルの `@rust_crate`**（`@rust_crate path submodule="Bindings"` と `using .Bindings: ...`。詳細は[クレートのバインディング](crate_bindings.md)）：

1. プリコンパイル中に走査・キャッシュへのビルド・モジュール生成を行い、パッケージのコンパイル済みイメージへ収めます。パッケージのディレクトリには書き込みません。
2. 実行時にモジュールの `__init__` がキャッシュのライブラリを開きます。
3. `RustCall.clear_cache()` やクレートの再ビルド後はキャッシュが無効になり、次の `using` で再プリコンパイルします。

**`write_bindings_to_file`**（`deps/build.jl` でバインディングを書き、ライブラリをパッケージへコピー）：

1. 開発中にバインディングファイルを生成します。
2. プリコンパイル時に Julia がモジュールをコンパイルします。
3. 実行時は同梱ライブラリを読み込むだけで、読み込み先のマシンに Rust ツールチェーンは不要です。

### [生成の流れ](@id The-Generation-Process)

```
Rust Crate               Julia Bindings File
    │                           │
    ├── Cargo.toml              │
    ├── src/                    │
    │   └── lib.rs ──────────►  MyBindings.jl
    │                           │
    └── target/                 │
        └── release/            │
            └── lib*.so ◄───────┘
```

## [利用手順](@id Usage-Guide)

### [ステップ1：プロジェクトの構成](@id Step-1:-Project-Structure)

次の構成を用意します。

```
MyPackage/
├── Project.toml
├── src/
│   ├── MyPackage.jl          # Main module
│   └── generated/
│       └── RustBindings.jl   # Generated bindings (gitignore this)
├── deps/
│   ├── my_rust_crate/        # Your Rust crate
│   │   ├── Cargo.toml
│   │   └── src/lib.rs
│   └── lib/                  # Compiled library location
│       └── libmy_rust_crate.{so,dylib,dll}
└── build.jl                  # Build script
```

### [ステップ2：ビルドスクリプト](@id Step-2:-Build-Script)

`build.jl` でバインディングを生成します。

```julia
# deps/build.jl
using RustCall

# Path to Rust crate
crate_path = joinpath(@__DIR__, "my_rust_crate")

# Output path for generated bindings
bindings_path = joinpath(dirname(@__DIR__), "src", "generated", "RustBindings.jl")

# Generate bindings
RustCall.write_bindings_to_file(
    crate_path,
    bindings_path,
    output_module_name = "RustBindings",
    build_release = true,
    relative_lib_path = "../../deps/lib"
)
```

### [ステップ3：パッケージのモジュール](@id Step-3:-Package-Module)

生成済みバインディングを読み込みます。

```julia
# src/MyPackage.jl
module MyPackage

# Include generated bindings
include("generated/RustBindings.jl")
using .RustBindings

# Re-export functions
export add, multiply, MyStruct

# Your Julia code here...

end
```

### [ステップ4：開発中のビルド](@id Step-4:-Build-During-Development)

開発中にビルドスクリプトを実行します。

```julia
using Pkg
Pkg.build("MyPackage")
```

手動でも実行できます。

```julia
include("deps/build.jl")
```

## [PackageCompiler.jl との連携](@id PackageCompiler.jl-Integration)

独立したアプリの生成にも利用できます。

### [システムイメージの作成](@id Creating-a-System-Image)

```julia
using PackageCompiler

create_sysimage(
    :MyPackage,
    sysimage_path = "my_sysimage.so",
    precompile_execution_file = "precompile_script.jl"
)
```

### [アプリの作成](@id Creating-an-App)

```julia
using PackageCompiler

create_app(
    ".",                    # Package directory
    "build",               # Output directory
    executables = ["main" => "main.jl"]
)
```

### [注意点](@id Important-Considerations)

1. **ライブラリの場所**：`relative_lib_path` でバインディングファイルからの相対位置を指定します。
2. **同梱**：コンパイルした `.so` / `.dylib` / `.dll` をアプリに含めます。
3. **プリコンパイルスクリプト**：Rust 関数の呼び出しも含めます。

スクリプトの例です。

```julia
# precompile_script.jl
using MyPackage

# Warm up the functions
MyPackage.add(Int32(1), Int32(2))
MyPackage.multiply(1.0, 2.0)
```

## [キャッシュの動作](@id Cache-Behavior)

### [開発中](@id During-Development)

- コンパイル済みライブラリは Scratch.jl の `<depot>/scratchspaces/<RustCall UUID>/cache-v2/` に保存します（[性能](performance.md)を参照）。
- ソースのハッシュをキーにします。
- ソースが変わると再ビルドします。

### [プリコンパイル中](@id During-Precompilation)

- 生成バインディングは固定のライブラリパスを参照します。
- 指定先にライブラリが必要です。
- 実行時のコンパイルは行いません。

### [キャッシュ操作](@id Cache-Functions)

```julia
# Clear the cache
RustCall.clear_cache()

# Check cache size
RustCall.get_cache_size()

# List cached libraries
RustCall.list_cached_libraries()

# Clean up old cache entries
RustCall.cleanup_old_cache(30)
```

## [トラブルシューティング](@id Troubleshooting)

### [ライブラリが見つからない](@id Library-Not-Found)

実行時の `could not load library "..."` は次を確認します。

1. `relative_lib_path` が正しいか。
2. ビルド時にコピーしたか。
3. ファイルの権限が正しいか。

```julia
# Debug: Check the library path
bindings_dir = dirname(pathof(MyPackage))
lib_path = joinpath(bindings_dir, "..", "deps", "lib", "libmy_crate.so")
@info "Library exists?" isfile(lib_path)
```

### [プリコンパイルの失敗](@id Precompilation-Fails)

プリコンパイル中の `LoadError` は次を確認します。

1. `__init__()` が正しくライブラリを読み込むか。
2. 可搬性のためパスに `@__DIR__` を使っているか。
3. 生成コードの構文が正しいか。

### [バージョンの不一致](@id Version-Mismatch)

Rust 更新後に動作が変わった場合はバインディングを再生成します。

```julia
Pkg.build("MyPackage")
```

### [プラットフォーム固有の問題](@id Platform-Specific-Issues)

- **macOS**：拡張子は `.dylib`。コード署名への対応が必要な場合があります。
- **Linux**：拡張子は `.so`。必要に応じて `LD_LIBRARY_PATH` を確認します。
- **Windows**：拡張子は `.dll`。依存 DLL を Julia プロセスと同じディレクトリか `PATH` に置きます。

## [推奨事項](@id Best-Practices)

1. 生成する `src/generated/` を `.gitignore` に追加します。
2. Rust クレートをバージョン管理します。
3. CI で `Pkg.build()` を実行し、新しいバインディングを生成します。
4. テストにプリコンパイルの検証を含めます。
5. README に Rust ツールチェーン要件を書きます。

## [完全なパッケージの例](@id Example:-Complete-Package)

プリコンパイル可能なパッケージの例です。

```julia
# Project.toml
name = "MyRustPackage"
uuid = "..."
version = "0.1.0"

[deps]
RustCall = "..."

[extras]
Test = "..."

[targets]
test = ["Test"]
```


```julia
# deps/build.jl
using RustCall

RustCall.write_bindings_to_file(
    joinpath(@__DIR__, "rust_crate"),
    joinpath(dirname(@__DIR__), "src", "generated", "Bindings.jl"),
    output_module_name = "Bindings",
    relative_lib_path = "../../deps/lib"
)
```


```julia
# src/MyRustPackage.jl
module MyRustPackage

include("generated/Bindings.jl")
using .Bindings

export rust_add, rust_multiply

rust_add(a, b) = Bindings.add(Int32(a), Int32(b))
rust_multiply(a, b) = Bindings.multiply(Float64(a), Float64(b))

end
```

## [Python ホスト経路](@id The-Python-host-path)

`@rust_crate ... pyo3_host=true` と `RustCall.pyo3_host_import` はプリコンパイル中にビルドしません。成果物のキーには PythonCall のインタープリターが必要ですが、それが分かるのは PythonCall の `__init__` 後であり、プリコンパイル中に起動してはいけないためです。バインディング自体はイメージへ収め、ビルドと import は最初の呼び出しで行います。

その初回に RustCall 自体のコードを新規コンパイルする必要はありません（[#449](https://github.com/AtelierArith/RustCall.jl/issues/449)）。走査・キー計算・検索は RustCall のイメージ、import は `RustCallPyO3HostExt` に入っています。残るのは extractor、ツールチェーンの確認、`cargo tree`、インタープリター起動、キャッシュがなければ Cargo ビルドという実作業です。

先にビルドを済ませるには、PythonCall と同じインタープリターを指定して `RustCall.build_pyo3_extension` を実行します。import 時に一致を確認します。`__init__` で成果物を保持すれば、最初の呼び出しは `RustCall.pyo3_host_import(artifact)` だけになります。別プロセスの `deps/build.jl` はキャッシュを準備するだけなので、実行時の `pyo3_host_import(crate)` は走査と確認を行いますが、再ビルドはしません。[PyO3 クレート](pyo3.md)も参照してください。

## [関連情報](@id See-Also)

- [外部クレートのバインディング](crate_bindings.md)：API の詳細。
- [Julia のプリコンパイル](https://docs.julialang.org/en/v1/manual/modules/#Module-initialization-and-precompilation)：Julia 公式マニュアル。
- [PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl)：独立したアプリの生成。
