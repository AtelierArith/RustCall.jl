<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../../en/reference/artifacts.md. -->
# [成果物の識別とキャッシュ](@id Artifact-identity-and-caching)

直接の `rustc` ビルド、生成 Cargo プロジェクト、ジェネリクスの特殊化、`@rust_crate` ライブラリなど、各成果物は [`RustCall.ArtifactId`](@ref) で識別し、[`RustCall.artifact_key`](@ref) で検索します。識別子の計算は `src/artifacts/artifact_id.jl` に一元化され、`src/artifacts/cache.jl` が Scratch.jl 領域に成果物を保存します（#252、#278）。

## [成果物の識別（`src/artifacts/artifact_id.jl`）](@id Artifact-identity-(src/artifacts/artifact_id.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "artifacts", "artifact_id.jl")]
```

## [完全なキーが所有する短い名前（`src/artifacts/short_name.jl`）](@id Short-names-owned-by-the-full-key-(src/artifacts/short_name.jl))

Windows のパス長制限に対応する短い ID の表記と所有権を管理します。対象はクレートの Cargo 出力先、PyO3 ラッパーの Cargo パッケージ、Python ホスト拡張のキャッシュ、デバッグビルドのファイルです。永続名は完全なキーに固定し、ビルド開始からコピー完了まで名前のロックを保持します（#504）。所有者記録なしでファイルだけある場所は、流用せず空にするか拒否します。ファイルロック非対応の環境では排他を保証できず削除も拒否するため、手動削除が必要です（#507 のレビュー）。

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "artifacts", "short_name.jl")]
```

## [キャッシュ（`src/artifacts/cache.jl`）](@id Cache-(src/artifacts/cache.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "artifacts", "cache.jl")]
```
