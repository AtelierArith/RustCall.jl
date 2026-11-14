<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/api.md. -->
# [API リファレンス](@id API-Reference)

ソースファイルのグループごとにページを分け、各 docstring を1ページだけに表示します（#288）。ここはその索引です。export するのはマクロだけで、それ以外は `RustCall.name` と書きます。

!!! note "共有の API docstring"
    以下の API docstring は英語版と共通の原文です。説明ページとナビゲーションは日本語で提供しています。

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "RustCall.jl")]
```

## [マクロ](@id Macros)

- [`@rust_str`](@ref)：`rust"""..."""` で Rust をコンパイルして関数を登録します。
- [`@rust`](@ref)：登録済み Rust 関数を呼びます。
- [`@rust_crate`](@ref)：外部クレートをバインドします。

`@rust_llvm` と LLVM IR 経路は 0.3.0 で削除されました（[#265](https://github.com/AtelierArith/RustCall.jl/issues/265)）。`@rust` を使ってください。`@irust` と `irust"..."` は 0.9.0 で削除されました（[#538](https://github.com/AtelierArith/RustCall.jl/issues/538)）。`rust"""..."""` 内の `#[julia]` 関数に置き換えます（[移行ガイド](migrating_from_irust.md)）。

## [ページ一覧](@id Pages)

- [成果物の識別とキャッシュ](reference/artifacts.md)：`ArtifactId` / `artifact_key` による一元的な識別と Scratch.jl の保存領域（`artifact_id.jl`、`cache.jl`）。
- [FFI の型契約](reference/ffi_contract.md)：全経路が参照する Rust ↔ Julia の型表と変換層（`ffi_contract.jl`、`typetranslation.jl`）。
- [利用者向けの入口](reference/compilation.md)：`rust"""..."""` と `@rust`（`ruststr.jl`、`rustmacro.jl`）。
- [コンパイラとコード生成](reference/codegen.md)：`rustc`、Cargo の JSON 読み取り、`ccall` 生成（`compiler.jl`、`json.jl`、`codegen.jl`）。
- [FFI マニフェスト](reference/manifest.md)：`rustcall-extract` のマニフェスト・インライン展開・特殊化・ツールチェーン識別（`manifest.jl`）。
- [Cargo プロジェクトと依存関係](reference/cargo.md)：`// cargo-deps:`、依存解決、生成プロジェクトとビルドキャッシュ（`dependencies.jl`、`dependency_resolution.jl`、`cargoproject.jl`、`cargobuild.jl`）。
- [外部クレート](reference/crates.md)：`@rust_crate`（`crate_bindings.jl`）。
- [ホットリロード API](reference/hot_reload.md)：使用中のクレートの再読み込み（`hot_reload.jl`）。[ガイド](hot_reload.md)に実行例があります。
- [PyO3 クレート](reference/pyo3.md)：Python 拡張を包むラッパー、リンク計画、スキップ理由（`pyo3.jl`）。
- [型・メモリ・所有権](reference/ownership.md)：`RustResult`、`RustOption`、所有権ラッパー、Rust ヘルパー、`#[julia]` 構造体の Julia 型（`types.jl`、`memory.jl`、`structs.jl`）。
- [ジェネリクスと `#[julia]` 関数](reference/generics.md)：登録・単相化・独立関数のラッパー（`generics.jl`、`julia_functions.jl`）。手動操作は [`RustCall.register_generic_function`](@ref)、[`RustCall.monomorphize_function`](@ref)、[`RustCall.call_generic_function`](@ref)、[`RustCall.precompile_generics`](@ref)、[`RustCall.release_generics`](@ref) を参照してください。[ガイド](generics.md)に自動・手動の両方の例があります。
- [エラー](reference/errors.md)：例外型（`exceptions.jl`）。
- [読み込みポリシー](reference/loading.md)：唯一の読み込み・アンロード経路（`loadpolicy.jl`）。

内部レジストリや定数（`RustCall.RUST_LIBRARIES`、`RustCall.CURRENT_LIB`、`RustCall.GENERIC_FUNCTION_REGISTRY` など）は、定義したファイルのページに表示します。網羅性のための内部実装資料であり、利用者から直接アクセスしないでください。
