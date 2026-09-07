# LLVM integration (deprecated)

The LLVM IR integration path is deprecated
([#265](https://github.com/AtelierArith/RustCall.jl/issues/265)). Every
function on this page, together with `compile_rust_to_llvm_ir` and
`load_llvm_ir`, emits a deprecation warning and will be removed in a future
release. `@rust_llvm` is deprecated as well; use `@rust` instead.

## LLVM modules (`src/llvmintegration.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "llvmintegration.jl")]
```

## LLVM optimization (`src/llvmoptimization.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "llvmoptimization.jl")]
```

## LLVM function registration (`src/llvmcodegen.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "llvmcodegen.jl")]
```
