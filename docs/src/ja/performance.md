<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/performance.md. -->
# [性能ガイド](@id Performance-Guide)

コンパイル、呼び出し、メモリの費用を説明します。

## [目次](@id Table-of-Contents)

1. [コンパイル結果の保存](#Compilation-Caching)
2. [削除済み LLVM 最適化](#LLVM-Optimization-(removed))
3. [呼び出しの最適化](#Function-Call-Optimization)
4. [メモリ管理](#Memory-Management)
5. [ベンチマーク](#Benchmark-Results)
6. [調整のヒント](#Performance-Tuning-Tips)

## [コンパイル結果の保存](@id Compilation-Caching)

同じコードを再コンパイルせず、保存した共有ライブラリを再利用します。

### [キャッシュの仕組み](@id How-Caching-Works)

- **キー**：`ArtifactId` の `artifact_key` が唯一の識別関数です。展開ソース、宣言順の型引数、ターゲット、生成設定、cfg、依存（path は場所でなく内容）、features、追跡環境、extractor と実際の rustc / cargo の識別を含め、netstring で曖昧なく区切ります。
- **場所**：[Scratch.jl](https://github.com/JuliaPackaging/Scratch.jl) の `<depot>/scratchspaces/<RustCall UUID>/cache-v\$(CACHE_FORMAT_VERSION)/`。書き込み可能な最初の depot を使い、`RUSTCALL_CACHE_DIR` で上書きできます。Julia 自身の `compiled/` には書きません（#252）。形式更新は別領域とし、`sweep_stale_cache_formats()` が旧形式を可能な範囲で削除します。
- **計算費用**：毎回全入力バイトを読みます。mtime とサイズだけでは内容を区別できないためメモ化しません。高価な Cargo 依存グラフだけを保持し、各クレートとワークスペースのマニフェスト内容変更で無効化します。
- **短縮**：完全なキーは短縮しません。`artifact_short_id` は名前や一時パス、ログ用です。
- **検証**：読み込み前に SHA-256 を照合します。

### [キーに含めきれないもの](@id What-is-not-in-the-key)

環境は許可リスト（`RUSTFLAGS`、`CARGO_PROFILE_*`、`PYO3_*`、`CC`、`PKG_CONFIG_PATH` 等。資格情報は除外）です。build script が任意に読む変数や、クレート外の `#[path]` / `include_str!` などは完全には追跡できません。必要なら一元管理する `ARTIFACT_BUILD_ENV_*` を拡張します。追跡済み入力に変更があれば再ビルドしますが、変化がないだけで全入力不変を証明するものではありません。

### [ツールチェーン不明はエラー](@id A-missing-toolchain-is-an-error)

実際に実行する `RustToolChain.rustc()` / `cargo()` を識別します。識別できなければ `unknown` という共通キーに保存せず `RustError` にします。

### [lockfile による依存の固定](@id Pinned,-lockfile-driven-dependency-builds)

インラインのバージョン範囲を実際の解決と区別し、依存集合ごとに lockfile を保存します（#256）。

- `lockfile_path(deps)` / `lockfile_path(source)` は `<cache>/lockfiles/<key>.lock` です。キーと生成 package 名は依存集合だけから決め、ツールチェーンを含めません。旧名や手編集で対象 package のない lockfile は再解決します。
- 初回だけ `cargo generate-lockfile`、以後はコピーして `cargo build --locked` を使います。
- 内容を `cargo-lock` として成果物キーへ含め、別解決と混同しません。
- 他マシンへコピー・コミットして再現できます。再解決はファイル削除、全削除は `clear_lockfiles()` です。`clear_cache()` は入力である lockfile を残します。
- 同時解決は排他的 `.claim` で最初の1つを公開し、他は待ちます。時間だけで期限切れにはしません。死んだプロセスの claim は、他に解決中がないことを確認して削除します。
- `RUSTCALL_OFFLINE=1` は全 Cargo に `--offline` を付け、レジストリ不足なら `CargoBuildError` です。

通常の外部ラッパーは別 Cargo ルートです。PyO3 ラッパーは元の lockfile と patch を引き継ぎます（[詳細](pyo3.md)）。

### [キャッシュ操作](@id Cache-Management)

```julia
using RustCall

# Check cache size
size = RustCall.get_cache_size()
println("Cache size: $(size / 1024 / 1024) MB")

# List cached libraries
libraries = RustCall.list_cached_libraries()
println("Cached libraries: $(length(libraries))")

# Cleanup old cache (older than 30 days)
RustCall.cleanup_old_cache(30)

# Clear cache completely
RustCall.clear_cache()

# Also remove the tree the pre-#252 layout left in `~/.julia/compiled/`. Off by
# default: that directory is Julia's own precompile directory for RustCall, so
# RustCall only ever deletes entries it can prove it wrote, and never the
# directory itself.
RustCall.clear_cache(sweep_legacy = true)
```

### [推奨する使い方](@id Cache-Best-Practices)

開発中は有効のまま、配布前は事前に準備し、CI では保存・復元します。

## [LLVM 最適化（削除済み）](@id LLVM-Optimization-(removed))

`@rust_llvm`、IR 読み込み、`OptimizationConfig` などは0.2.0で非推奨、0.3.0で削除しました（[#265](https://github.com/AtelierArith/RustCall.jl/issues/265)）。LLVM.jl に依存せず `@rust` を使います。

旧実装も通常の関数ポインタ `ccall` で、Julia への IR インライン化はなく性能差がありませんでした。また Julia と rustc は LLVM 版が違い、新しいテキスト IR を古い LLVM で安定して解析できません。Rust 自体の最適化は `rustc` の opt-level（`RustCompiler`）で設定します。

## [関数呼び出しの最適化](@id Function-Call-Optimization)

### [呼び出し方式は1つ](@id One-call-mechanism)

どの `@rust` もライブラリのハンドルから得たポインタへ `ccall` します。別の高速経路はありません。

```julia
# Standard call (recommended)
result = @rust add(Int32(10), Int32(20))::Int32
```

### [呼び出しの費用](@id What-a-call-costs)

`benchmarks_dispatch.jl` が手動で一度解決した `ccall` を下限として測定します（macOS、Julia 1.12、短い Rust 本体）。

| 経路 | #253 以前 | 現在 | 生の ccall 比 |
|------|----------:|-----:|--------------:|
| 生の `ccall` | 5.2 ns | 5.4 ns | 1.0 |
| 生成関数 | 9891 ns | 10.0 ns | 1.9 |
| 型注釈付き `@rust` | 8940 ns | 11.9 ns | 2.2 |
| 注釈なし | 9945 ns | 360 ns | 68 |
| `@rust_crate` | 1029 ns | 21.8 ns | 3.3 |

クレートの行だけは別測定で下限6.5 ns、割り当ては14から0になりました。

| タスク | 生 ccall | 旧生成関数 | 現在 | 旧クレート | 現在 |
|--------|---------:|-----------:|-----:|-----------:|-----:|
| 1 | 1.00× | 1.00× | 1.00× | 1.00× | 1.00× |
| 2 | 2.06× | 0.94× | 2.24× | 0.87× | 1.99× |
| 4 | 4.01× | 0.85× | 5.18× | 0.70× | 3.89× |

以前はブロック探索、ロック、シンボル文字列、ハンドル・ポインタ・チャネル・ABI の解決を毎回行い、約9.9 µs と約100割り当て、スレッド競合がありました。#253 以降は呼び出し箇所で世代スナップショットを保持し、状態更新で増える `ARTIFACT_EPOCH` が同じ間は再利用します。高速経路は原子的読み取り・比較・呼び出しです。全体を1つのスナップショットとして保持するため世代を混ぜません。

保存可能なクレートのコードでは各ラッパーの隣に `CrateTargetCache` を定義します。生成ファイルの形式は当時11となり、v0.6.6では13、現在はリリースの MAJOR.MINOR です。

### [戻り値注釈か julia 属性を使う](@id Annotate-the-return-type,-or-use-#[julia])

注釈なしでは実行時に戻り値型を取り出す動的ディスパッチとなり、呼び出し元も推論できません。明示すると直接呼べます。

```julia
result = @rust add(Int32(10), Int32(20))::Int32   # 2.2× a raw ccall
```

または既知の署名を持つ `#[julia]` 生成関数を使います。

```julia
rust"""
#[julia]
pub fn add(a: i32, b: i32) -> i32 { a + b }
"""

result = add(Int32(10), Int32(20))                # 1.9× a raw ccall
```

この測定では注釈なしは約30倍遅くなります。

### [事前登録は不要](@id No-registration-step)

ライブラリ読み込み時にマニフェストがシンボルと戻り値型を登録します。削除済み LLVM 経路の登録関数は不要です。引数と戻り値の型を明確にしてください。

## [メモリ管理](@id Memory-Management)

### [所有権型の使い方](@id Efficient-Use-of-Ownership-Types)

RustBox / Rc / Arc / Vec を適切に解放します。

```julia
# Temporary allocations are automatically cleaned up
box = RustCall.RustBox(Int32(42))
# Automatically dropped after use

# Explicit drop (when early release is needed)
RustCall.drop!(box)
```

### [RustVec の効率的な利用](@id Efficient-Use-of-RustVec)

```julia
# Create RustVec from Julia array
julia_vec = Int32[1, 2, 3, 4, 5]
rust_vec = RustCall.create_rust_vec(julia_vec)

# Efficient bulk copy (recommended)
result = Vector{Int32}(undef, length(rust_vec))
RustCall.copy_to_julia!(rust_vec, result)

# Or use to_julia_vector
result = RustCall.to_julia_vector(rust_vec)

# Element-by-element access (not recommended for large data)
for i in 1:length(rust_vec)
    value = rust_vec[i]  # FFI call occurs
end

# Explicitly drop after use
RustCall.drop!(rust_vec)
```

### [Julia 配列との選択](@id RustVec-vs-Julia-Array-Selection)

| 用途 | 選択 |
|------|------|
| Julia 内の計算 | Julia 配列 |
| Rust 所有データの受け渡し | RustVec、必要なら Julia へコピー |
| 大きな一時領域 | GC 管理の Julia 配列 |
| Rust 内の操作 | RustVec |

### [リークの回避](@id Avoiding-Memory-Leaks)

```julia
# Pattern 1: Use try-finally
box = RustCall.RustBox(Int32(42))
try
    # Use
    value = box.ptr
finally
    RustCall.drop!(box)  # Ensure cleanup
end

# Pattern 2: Leverage local scope
function compute()
    box = RustCall.RustBox(Int32(42))
    # Use
    return result
    # box is automatically dropped
end
```

## [ベンチマーク結果](@id Benchmark-Results)

### [基本演算](@id Basic-Operations)

Julia 1.12、Rust 1.92.0、macOS の測定です。

| 演算 | Julia | @rust |
|------|------:|------:|
| i32 加算 | 1.0x | 1.2x |
| i64 加算 | 1.0x | 1.2x |
| f64 加算 | 1.0x | 1.3x |
| i32 乗算 | 1.0x | 1.2x |
| f64 乗算 | 1.0x | 1.3x |

### [複合計算](@id Complex-Computations)

| 計算 | Julia | @rust |
|------|------:|------:|
| フィボナッチ n=30 | 1.0x | 1.1x |
| 1..1000 の合計 | 1.0x | 1.2x |

### [所有権型の操作](@id Ownership-Type-Operations)

| 操作 | 平均 |
|------|-----:|
| RustBox 生成・解放 | 約170 ns |
| RustRc 生成・解放 | 約180 ns |
| RustRc 複製・解放 | 約180 ns |
| RustArc 生成・解放 | 約190 ns |
| RustArc 複製・解放 | 約200 ns |

### [RustVec の操作](@id RustVec-Operations)

| 操作 | 平均 |
|------|-----:|
| 1000要素の生成 | 約1 µs |
| 1000要素の一括コピー | 約500 ns |
| 要素アクセス（FFI 含む） | 約50 ns/要素 |
| 再割り当てなしの push! | 約100 ns |

実際の値はハードウェア・OS・Julia/Rust の版で変わります。

### [ベンチマークの実行](@id Running-Benchmarks)

```bash
# Extractor + rustc compile-time benchmark (cold and warm)
RUSTCALL_EXTRACT=/path/to/rustcall-extract \
  julia --project=benchmark benchmark/benchmarks_compile.jl

# Basic benchmarks
julia --project=benchmark benchmark/benchmarks.jl

# Ownership type benchmarks
julia --threads=4 --project=benchmark benchmark/benchmarks_ownership.jl

# Array operation benchmarks
julia --project=benchmark benchmark/benchmarks_arrays.jl

# Generics benchmarks
julia --project=benchmark benchmark/benchmarks_generics.jl
```

### [インラインコンパイル測定（#271）](@id Inline-compilation-benchmark-(#271))

`benchmarks_compile.jl` はサンプルごとに1 cdylib を使います。cold は新しいソース識別で抽出と rustc、warm はアンロード後の同じソースでディスクキャッシュとメモ化した展開を測り、FFI 呼び出しは含みません。

Darwin x86_64 / Julia 1.12.7 / rustc 1.98.0 の初回記録は cold 406.56 ms、warm 1.63 ms でした。2026-09-09、コミット `f6e84bd`、Julia 1.12.7 / rustc 1.98.1、cold 3回・warm 5回の CI 中央値は以下です。

| 環境 | cold | warm |
|------|-----:|-----:|
| [Linux x86_64](https://github.com/AtelierArith/RustCall.jl/actions/runs/34303413582/job/102314990683) | 140.06 ms | 35.08 ms |
| [macOS aarch64](https://github.com/AtelierArith/RustCall.jl/actions/runs/34303413582/job/102314990577) | 264.79 ms | 3.62 ms |
| [Windows x86_64](https://github.com/AtelierArith/RustCall.jl/actions/runs/34303413582/job/102314990769) | 256.59 ms | 1.18 ms |

ランナー固有の値であり、OS の統制比較ではありません。スクリプトは環境・版・中央値も出力します。

## [調整のヒント](@id Performance-Tuning-Tips)

### [1. コンパイル時間](@id 1.-Reducing-Compilation-Time)

キャッシュを使い、開発時は opt-level 1～2、本番は3、必要なら `emit_debug_info=false` にします。

```julia
compiler = RustCall.RustCompiler(
    optimization_level=2,  # 2 is sufficient during development
    emit_debug_info=false
)
RustCall.set_default_compiler(compiler)
```

### [2. 実行時間](@id 2.-Improving-Runtime-Performance)

型を明示し、小さな呼び出しを一括処理へまとめます。

```julia
# Inefficient: Type inference every time in loop
for i in 1:1000
    result = @rust add(i, i+1)  # Type inference runs every time
end

# Efficient: Explicit types
for i in 1:1000
    result = @rust add(Int32(i), Int32(i+1))::Int32
end
```

### [3. メモリ使用量](@id 3.-Optimizing-Memory-Usage)

不要になったら drop し、単一スレッドは Rc、共有は Arc を選び、古いキャッシュを整理します。

### [4. 並列処理](@id 4.-Parallel-Processing-Optimization)

```julia
using Base.Threads

# Use Arc to share data between threads
shared_data = RustCall.RustArc(Int32(0))

# Work on multiple threads
@threads for i in 1:1000
    local_arc = RustCall.clone(shared_data)
    # Work
    RustCall.drop!(local_arc)
end
```

### [5. プロファイリング](@id 5.-Profiling)

Julia のツールでボトルネックを測ります。

```julia
using Profile

# Start profiling
Profile.clear()
@profile for i in 1:1000
    @rust add(Int32(i), Int32(i+1))
end

# Display results
Profile.print()
```

## [トラブルシューティング](@id Troubleshooting)

### [期待より遅い場合](@id When-Performance-is-Lower-Than-Expected)

キャッシュ、最適化レベル、型注釈を確認し、プロファイルで原因を調べます。

### [メモリが多い場合](@id When-Memory-Usage-is-High)

所有値の解放、古いキャッシュ、不要な Rc/Arc の複製を確認します。

## [まとめ](@id Summary)

キャッシュ、目的に合う最適化、明示的な型、所有権管理を使い、推測でなくプロファイルで調整します。
