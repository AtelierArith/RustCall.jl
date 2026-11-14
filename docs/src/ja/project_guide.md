<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/project_guide.md. -->
# [プロジェクトガイド](@id Project-Guide)

ソースチェックアウト、コード調査、実行可能な資料の案内です。実行時の仕組みは[内部構造](internals.md)を参照してください。

## [リポジトリの構成](@id Repository-Layout)

- `src/`：実装。入口は `src/RustCall.jl`。
- `test/`：テスト。入口は `test/runtests.jl`。
- `docs/`：Documenter の原稿と設定。
- `deps/`：Rust の core、extractor、属性マクロ、所有権 helper。
- `examples/`：インライン、クレート、Pluto、パッケージの実例。
- `benchmark/`：呼び出し、配列、ジェネリクス、所有権の測定。

## [ソースのディレクトリ](@id Source-directories)

入口が include 順を管理し、全ファイルは同じ `RustCall` モジュールに定義します。ディレクトリは名前空間を増やしません。

- `artifacts/`：識別・キャッシュ・環境スナップショット。
- `build/`：rustc / Cargo・依存・診断。
- `ffi/`：型・変換・所有権・生成。
- `loading/`：ライブラリ・状態・再読み込み。
- `macros/`：文字列・呼び出し・ジェネリクス・マニフェスト・プリコンパイル。
- `crate_bindings/`：外部クレートの各部品の統合。
- `pyo3/`：ラッパー計画・Python ホスト。
- `native_layout.jl`：本体と build.jl が共有する配置規則。

ソース検査は `test/source_helpers.jl` で統合元から literal include を追い、部品移動で対象を狭めません。

## [クレートバインディングの部品](@id Crate-binding-components)

`crate_bindings.jl` が依存順にまとめます。分割しても公開モジュール・署名・保存形式は変えません。

| 部品 | 役割 |
|------|------|
| crate_scan.jl | メタデータ・抽出・ラッパープロジェクト |
| crate_build_env.jl | ビルド記録・追跡依存・環境と Python 照合 |
| crate_module_expr.jl | モジュール式と共通初期化 |
| crate_layout.jl | 階層・衝突・生成名・走査 |
| crate_wrappers_expr.jl | 関数式と共通フィールド・ペイロード計画 |
| crate_build.jl | ビルド・キー・保存形式 |
| crate_runtime.jl | プロキシ・動的ロード・マクロ |
| crate_write.jl | 保存ビルド・ライブラリ配置 |
| crate_module_source.jl | 保存用のソース生成 |

式とソースの両生成器で判断を共有し、ソース検査はこの配下を include から追います。

## [同梱の例](@id Bundled-Examples)

`MyExample.jl` はインライン、`SampleCrate.jl` は同梱クレートと build.jl の保存バインディング、`RustCrateMacro.jl` はトップレベルの `submodule="Bindings"` とインラインの併用です。複数の入口の共存もテストします。

`SampleCratePyO3.jl` は Julia/Python 両用、`SampleCratePyO3Only.jl` は RustCall 属性なしのラッパー経由で、必須 pyo3 のため libpython が必要です。`RustCrateMacroPyO3Only.jl` と `Pyo3HostImport.jl` はマクロ・ホストの別例、`SafeLedger.jl` は[安全な連携](integration_guide.md)の例です。`pluto/hello.jl` は CI で headless 実行し、セルのエラーを検出します。

各ディレクトリは独立した Julia パッケージで、Rust クレートは専用 deps にあります。ソース開発と同じ属性を検証するため、マクロ依存だけチェックアウトを指します（PyO3 専用では生成ラッパー側が依存します）。ルートから次のようにテストします。

```bash
julia --project=examples/MyExample.jl -e 'using Pkg; Pkg.develop(path="."); Pkg.test()'
julia --project=examples/SampleCrate.jl -e 'using Pkg; Pkg.develop(path="."); Pkg.test()'
julia --project=examples/SampleCratePyO3.jl -e 'using Pkg; Pkg.develop(path="."); Pkg.test()'
julia --project=examples/SampleCratePyO3Only.jl -e 'using Pkg; Pkg.develop(path="."); Pkg.test()'
```

Pluto はルートを有効化するので、先にルートを instantiate / build します。

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.build("RustCall")'
julia --project=examples/pluto -e 'using Pkg; Pkg.instantiate()'
julia --project=examples/pluto examples/pluto/run_notebook.jl
```

Examples ワークフローも push ごとに同じパッケージテストを行います。

## [マニフェストのスキーマとリリース](@id Manifest-Schema-and-Releases)

v0.4.0 以降の `schema_version` はパッケージの **MAJOR.MINOR** です。Julia は Project.toml から読み、Rust の `manifest::SCHEMA_VERSION` は同じリテラルに手で更新し、schema テストが CLI 出力と比較します（#372、#451）。公開 Rust クレート自身の版とは独立です。v0.3.x までは整数で、最後は13でした。

patch は識別子を変えず、互換な extractor と成果物を保ちます。extractor は単なるバイナリではなく、Cargo が認識するビルドのソースダイジェストを、バイナリ SHA-256 に結び付けた隣の identity 記録で識別します（#409）。ただし外部フラグ・wrapper・linker・profile・source replacement や build/target/env/source 設定のない**通常ビルド**だけがソース同一性を主張できます（#413）。それ以外はバイナリのバイト列で正確に識別します。

自分自身の公開クレートの package version と、それを記録する path 依存の lockfile 行だけをキーから除きます。場所の由来で判定するため、同名 fork や他クレートの version は残します。版を実行時に読むクレートもあるためです。

minor は識別子を変え、extractor と全キャッシュキーを更新します。patch 内のマニフェスト変更は追加的・任意でなければなりません。

公開3クレートは共通の独自版を持ちます。更新時は Cargo.toml、相互依存の正確な `=x.y.z`、extractor・sample fixture・SafeLedger の lockfile を `cargo update -w --offline` で更新します。Project とスキーマはその更新だけでは動きません。パッケージのリリースは Project、内部 extractor の版と lockfile、MAJOR.MINOR 更新時のスキーマを揃えます。

v0.3.x からは `Pkg.build("RustCall")` が必要です。旧 `13` のマニフェストは拒否し、旧キーは再利用せず初回に作り直します。

## [ネイティブ成果物](@id Native-Build-Products)

Pkg.build は helper と extractor を作り、`native_layout.jl` で配置します（#258）。チェックアウト・develop・worktree は `deps/<crate>/target`、depot のインストール済みツリーは `<depot>/scratchspaces/<UUID>/native-v1/<slug>/<crate>` です。パッケージを読み取り専用にでき、Pkg の版ごとの slug で混同を防ぎます。Pkg 自身の build.log は別です。

両クレートの lockfile をコミットし `--locked` を使います。出力先を変えても lockfile はマニフェストの隣に作られるため、読み取り専用での暗黙更新を防ぎ、古ければ CI で失敗させます。cargo clean はせず、Cargo の増分判定を使います。変更なしの再ビルドは M 系 laptop で約31秒から Cargo 時間約0.1秒になりました。

検索順は環境 override（`RUSTCALL_EXTRACT` / `RUSTCALL_HELPERS`）、今ビルドする書き込み先、他 depot の scratch、旧パッケージ内配置です。読み取り専用の先頭 depot の古い成果物が後方の成功ビルドを隠しません。旧 alias と旧 helper 名は v0.5 で廃止しました（#417）。native_layout テストで固定します。

## [テスト](@id Test-Suite)

入口は runtests.jl、fixture は注釈付き sample_crate と各 PyO3 形式です。examples はそれぞれ独自のクレートを同梱します。キャッシュ・所有権・配列・ジェネリクス・Cargo・クレート・再読み込み・回帰を検証し、docs_examples は例、Rust 属性は独自の Cargo テストを持ちます。

CI では Rust ツールチェーンと helper はスキップ条件でなく**前提**です。ローカルも `RUSTCALL_REQUIRE_TOOLCHAIN=true` で同様になります。外部クレート・ndarray 等のネットワークテストは明示的な変数で有効化します。

```bash
RUSTCALL_RUN_SERDE_TESTS=true \
RUSTCALL_RUN_REGEX_TESTS=true \
RUSTCALL_RUN_UUID_TESTS=true \
RUSTCALL_RUN_CHRONO_TESTS=true \
RUSTCALL_RUN_HEAVY_INTEGRATION_TESTS=true \
  julia --project -e 'using Pkg; Pkg.test()'
```

通常の Cargo テストの itoa と PyO3 の pyo3 は依然必要です。宣言済み依存は `offline_prefetch/Cargo.toml` と native クレートの閉包に揃え、空の CARGO_HOME に取得後、`CARGO_NET_OFFLINE=true` で全体をテストします。新しいレジストリ依存には manifest への追加が必要です。

これは宣言した閉包で十分という検証で、Cargo が index に全く問い合わせないという意味ではありません。新規プロジェクトの解決は index を読みます。再現方法です。

```bash
export CARGO_HOME=$(mktemp -d)
# A fresh first depot, so RustCall's artifact cache starts empty too: a
# library an earlier run compiled would otherwise satisfy a Cargo-backed
# test without Cargo being invoked at all.
export JULIA_DEPOT_PATH="$(mktemp -d):$HOME/.julia"
for m in deps/rustcall_extract deps/rustcall_helpers deps/rustcall_julia_macros; do
  cargo fetch --manifest-path "$m/Cargo.toml"
done
for lock in test/fixtures/*/Cargo.lock; do
  cargo fetch --locked --manifest-path "$(dirname "$lock")/Cargo.toml"
done
(cd deps/rustcall_extract && cargo build --release)
julia --project -e 'using Pkg; Pkg.build("RustCall")'
CARGO_NET_OFFLINE=true \
  RUSTCALL_EXTRACT=$PWD/deps/rustcall_extract/target/release/rustcall-extract \
  julia --project -e 'using Pkg; Pkg.test()'
```

よく使うコマンドです。

```bash
julia --project -e 'using Pkg; Pkg.test()'
julia --project test/test_cache.jl
cd deps/rustcall_julia_macros && cargo fmt --check
cd deps/rustcall_julia_macros && cargo clippy --all-targets --all-features -- -D warnings
cd deps/rustcall_julia_macros && cargo test --all-features
```

## [ベンチマーク](@id Benchmarks)

Julia と Rust の経路を比較します。

```bash
julia --project=benchmark benchmark/benchmarks.jl
julia --project=benchmark benchmark/benchmarks_arrays.jl
julia --project=benchmark benchmark/benchmarks_generics.jl
julia --project=benchmark benchmark/benchmarks_ownership.jl
```

## [開発環境](@id Development-Setup)

```bash
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project -e 'using Pkg; Pkg.build("RustCall")'
julia --project -e 'using Pkg; Pkg.test()'
julia --project=docs docs/make.jl
```

実装規約は CLAUDE.md にあります。Julia・Rust・拡張機能を含む `.devcontainer/` があり、VS Code Dev Container や Codespaces でも開けます。

## [貢献](@id Contributing)

PR で変更を提出します。環境を準備し、`Pkg.test()`、Rust 変更時は Cargo 検査も実行し、CLAUDE.md に従います。専用の CONTRIBUTING.md はなく、この節が案内です。

## [ライセンス](@id License)

MIT License です。ルートの LICENSE を参照してください。

## [謝辞](@id Credits)

[Cxx.jl](https://github.com/JuliaInterop/Cxx.jl) に着想を得て、ツールチェーンには [RustToolChain.jl](https://github.com/AtelierArith/RustToolChain.jl) を使います。開発には Codex、Claude Code、Cursor 等の支援も使われています。

## [関連プロジェクト](@id Related-Projects)

[Cxx.jl](https://github.com/JuliaInterop/Cxx.jl) は C++ FFI、[CxxWrap.jl](https://github.com/JuliaInterop/CxxWrap.jl) は C++ ラッパー生成です。
