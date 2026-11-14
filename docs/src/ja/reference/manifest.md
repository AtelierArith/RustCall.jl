<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../../en/reference/manifest.md. -->
# [FFI マニフェスト](@id The-FFI-manifest)

Julia 側は Rust ソースを解析しません。シグネチャ、構造体の配置、型パラメーターは `rustcall-extract` CLI（`deps/rustcall_extract`）の FFI マニフェストから得ます。CLI は `syn` ベースのコア（`deps/rustcall_julia_core`）を `rustcall_julia_macros` と共有します。

`#[cfg(...)]` で無効な項目はマニフェストと展開結果から除外します。`--cfg-file` で渡す `rustc --print cfg` に対して条件を評価します。直接ビルドは実際のフラグ（`cfg = :strict`）、生成 Cargo プロジェクトは probe クレートで得た Cargo の有効設定（`cfg = :cargo`）を使います。外部クレートだけは feature と build script を制御できないため、ターゲット条件だけを評価します（`cfg = :lenient`、`--cfg-lenient`）。各項目の条件は `cfg` フィールドに記録します。

## [extractor インターフェース（`src/macros/manifest.jl`）](@id Extractor-interface-(src/macros/manifest.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "macros", "manifest.jl")]
```

## [ツールチェーンの確認（`src/artifacts/toolchain_check.jl`）](@id Toolchain-check-(src/artifacts/toolchain_check.jl))

`RustCall.check_toolchain()` はビルドせずに、RustToolChain が選ぶ `rustc` / `cargo`、最低対応バージョン、extractor の状態を報告します（#490）。

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "artifacts", "toolchain_check.jl")]
```
