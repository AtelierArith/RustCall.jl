<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../../en/reference/crates.md. -->
# [外部クレート](@id External-crates)

既存クレートへの `@rust_crate` バインディングです。利用方法は[外部クレートのバインディング](../crate_bindings.md)、再読み込みは[ホットリロード API](hot_reload.md)（[ガイド](../hot_reload.md)）、Python 拡張は [PyO3 クレート](pyo3.md)を参照してください。

## [クレートのバインディング](@id Crate-bindings)

`src/crate_bindings/crate_bindings.jl` が下記の部品を `RustCall` モジュールへ読み込みます。公開名と保存形式は共通です。

明示的なバインディングの実行時契約は次のとおりです。

- `@rust_crate` と `RustCall.load_crate_bindings` は `RustCall.CrateBindings` を返します。
- プロパティアクセスでは型や定数など関数以外の値も保持します。
- 公開関数はプロキシを介して呼び、world age に対する安全性を維持します。

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "crate_bindings", file) for file in (
    "crate_scan.jl", "crate_build_env.jl", "crate_module_expr.jl",
    "crate_layout.jl", "crate_wrappers_expr.jl", "crate_build.jl",
    "crate_runtime.jl", "crate_write.jl", "crate_module_source.jl",
)]
```

## [ビルドごとに1つの環境（`src/artifacts/build_env_snapshot.jl`）](@id One-environment-per-build-(src/artifacts/build_env_snapshot.jl))

`@rust_crate`、`write_bindings_to_file`、PyO3 ラッパー・ホスト、ホットリロードはすべて、開始時に取得した1つの `RustCall.BuildEnvSnapshot` を通して環境を読みます（#481）。

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "artifacts", "build_env_snapshot.jl")]
```
