<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../../en/reference/compilation.md. -->
# [利用者向けの入口：`rust"""..."""`、`@rust`](@id Front-doors:-rust"""...""",-@rust)

利用者が記述するマクロです。背後の `rustc` 実行と [FFI マニフェスト](manifest.md)からの `ccall` 生成は[コンパイラとコード生成](codegen.md)を参照してください。

## [`rust"""..."""`（`src/macros/ruststr.jl`）](@id rust"""..."""-(src/macros/ruststr.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "macros", "ruststr.jl")]
```

## [`@rust`（`src/macros/rustmacro.jl`）](@id @rust-(src/macros/rustmacro.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "macros", "rustmacro.jl")]
```
