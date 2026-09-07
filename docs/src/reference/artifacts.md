# Artifact identity and caching

Every compiled artifact — a direct `rustc` build, a generated Cargo project, a
monomorphized generic, a `@rust_crate` library — is named by an
[`RustCall.ArtifactId`](@ref) and looked up by its [`RustCall.artifact_key`](@ref).
Identity is computed in exactly one place, `src/artifact_id.jl`; the cache in
`src/cache.jl` stores what that identity names, in a Scratch.jl space (#252,
#278).

## Artifact identity (`src/artifact_id.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "artifact_id.jl")]
```

## Cache (`src/cache.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "cache.jl")]
```
