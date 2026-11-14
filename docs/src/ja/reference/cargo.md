<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../../en/reference/cargo.md. -->
# [Cargo プロジェクトと依存関係](@id Cargo-projects-and-dependencies)

`// cargo-deps:` コメントまたは `` //! ```cargo `` ブロックを含むインラインコードの処理です。依存宣言と解決、RustCall が生成・ビルド・保存する一時 Cargo プロジェクトを扱います。外部クレートは[外部クレート](crates.md)を参照してください。

## [依存関係（`src/build/dependencies.jl`）](@id Dependencies-(src/build/dependencies.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "build", "dependencies.jl")]
```

## [依存関係の解決（`src/build/dependency_resolution.jl`）](@id Dependency-resolution-(src/build/dependency_resolution.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "build", "dependency_resolution.jl")]
```

## [Cargo プロジェクト（`src/build/cargoproject.jl`）](@id Cargo-projects-(src/build/cargoproject.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "build", "cargoproject.jl")]
```

## [Cargo ビルド（`src/build/cargobuild.jl`）](@id Cargo-builds-(src/build/cargobuild.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "build", "cargobuild.jl")]
```
