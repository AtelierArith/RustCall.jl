<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../../en/reference/codegen.md. -->
# [コンパイラとコード生成](@id Compiler-and-codegen)

[利用者向けの入口](compilation.md)から実行する `rustc`、Cargo の機械可読 JSON 出力の解析、[FFI マニフェスト](manifest.md)からの `ccall` 生成を扱います。

## [コンパイラ（`src/build/compiler.jl`）](@id Compiler-(src/build/compiler.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "build", "compiler.jl")]
```

## [Cargo の JSON の読み取り（`src/build/json.jl`）](@id Reading-Cargo's-JSON-(src/build/json.jl))

`cargo metadata` と `--message-format=json` の出力をデータとして読み取ります。

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "build", "json.jl")]
```

## [コード生成（`src/ffi/codegen.jl`）](@id Code-generation-(src/ffi/codegen.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "ffi", "codegen.jl")]
```

## [生成コードが使う名前（`src/ffi/emitted_names.jl`）](@id Names-the-generated-code-uses-(src/ffi/emitted_names.jl))

生成モジュールは Rust 項目を元の名前で定義するため、Base、Core、RustCall、PythonCall への参照には Rust の識別子では表現できない名前を使います。`@rust_crate` と PyO3 ホストは `GlobalRef`、保存済みバインディングは `rustcall′Base` / `rustcall′RustCall` エイリアスを使います（#528）。

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "ffi", "emitted_names.jl")]
```
