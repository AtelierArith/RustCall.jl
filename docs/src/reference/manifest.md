# The FFI manifest

Julia never parses Rust source. Signatures, struct layouts and generic
parameters come from the FFI manifest produced by the `rustcall-extract` CLI
(`deps/rustcall_extract`), which shares its `syn`-based core
(`deps/rustcall_core`) with the `juliacall_macros` proc-macro.

Items disabled by `#[cfg(...)]` are dropped from manifests and expanded
sources: the extractor evaluates the predicates against `rustc --print cfg`
(passed as `--cfg-file`). Direct `rustc` builds query it with the real
compilation flags (`cfg = :strict`); Cargo projects RustCall generates itself
(`// cargo-deps:` blocks) evaluate the same way against Cargo's effective
configuration, obtained from a probe crate (`cfg = :cargo`). Only an external
crate (`@rust_crate`), whose features and build script RustCall does not
control, decides target predicates alone (`cfg = :lenient`, `--cfg-lenient`).
The predicate of every reported item is recorded in its `cfg` field.

## Extractor interface (`src/manifest.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "manifest.jl")]
```
