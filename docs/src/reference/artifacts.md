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

## Short names owned by the full key (`src/short_name.jl`)

Where Windows' path limit makes a short id a location — a crate's Cargo target
directory, the PyO3 wrapper's Cargo package, the PyO3 host extension's cache
directory, a debug build's files — the name is spelled and owned here: a
persistent name is claimed for good by the full key, and a build holds the
name's lock from build start through copy-out (#504).

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "short_name.jl")]
```

## Cache (`src/cache.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "cache.jl")]
```
