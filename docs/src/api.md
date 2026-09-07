# API Reference

The reference is split into one page per group of source files (#288); every
docstring in the package is rendered on exactly one of them. This page is the
index. Only the macros are exported; everything else is reached as
`RustCall.name`.

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "RustCall.jl")]
```

## Macros

- [`@rust_str`](@ref) — `rust"""..."""`: compile a Rust snippet and register its functions.
- [`@rust`](@ref) — call a registered Rust function.
- [`@irust`](@ref) / [`@irust_str`](@ref) — inline Rust with `$var` binding.
- [`@rust_crate`](@ref) — bind an external crate.

`@rust_llvm` and the LLVM IR integration path were removed in 0.3.0
([#265](https://github.com/AtelierArith/RustCall.jl/issues/265)); use `@rust`.

## Pages

- [Artifact identity and caching](reference/artifacts.md) — `ArtifactId` and
  `artifact_key`, the one place an artifact is named, and the Scratch.jl cache
  that stores what it names (`artifact_id.jl`, `cache.jl`).
- [The FFI type contract](reference/ffi_contract.md) — the Rust ↔ Julia type
  table every code path consults, and the type translation shims over it
  (`ffi_contract.jl`, `typetranslation.jl`).
- [Compilation and codegen](reference/compilation.md) — `rust"""..."""`,
  `@rust` and `@irust`, the `rustc` invocation and the generated `ccall`s
  (`ruststr.jl`, `rustmacro.jl`, `compiler.jl`, `codegen.jl`).
- [The FFI manifest](reference/manifest.md) — the `rustcall-extract` interface:
  manifests, inline expansion, specialization and the toolchain fingerprint
  (`manifest.jl`).
- [Cargo projects and dependencies](reference/cargo.md) — `// cargo-deps:`,
  dependency resolution, and the generated Cargo projects and their build cache
  (`dependencies.jl`, `dependency_resolution.jl`, `cargoproject.jl`,
  `cargobuild.jl`).
- [External crates and hot reload](reference/crates.md) — `@rust_crate`
  bindings and hot reload (`crate_bindings.jl`, `hot_reload.jl`).
- [PyO3 crates](reference/pyo3.md) — the wrapper crate built around a PyO3
  extension module, its link plan and skip reasons (`pyo3.jl`).
- [Types, memory and ownership](reference/ownership.md) — `RustResult`,
  `RustOption`, the ownership wrappers, the Rust helpers library and the Julia
  types generated for `#[julia]` structs (`types.jl`, `memory.jl`, `structs.jl`).
- [Generics and `#[julia]` functions](reference/generics.md) — the generic
  function registry, monomorphization, and the wrappers for `#[julia]` free
  functions (`generics.jl`, `julia_functions.jl`).
- [Errors and load policy](reference/loading.md) — the exception types and the
  one load/unload path (`exceptions.jl`, `loadpolicy.jl`).

Internal registries and constants (`RustCall.RUST_LIBRARIES`,
`RustCall.CURRENT_LIB`, `RustCall.GENERIC_FUNCTION_REGISTRY`, …) are rendered on
the page of the file that defines them. They are implementation details,
documented for completeness, and should not be accessed directly by users.
