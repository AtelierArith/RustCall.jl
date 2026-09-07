# Cargo projects and dependencies

Everything an inline block with a `// cargo-deps:` comment (or a
`` //! ```cargo `` block) goes through instead of a bare `rustc`: the
dependency DSL and its resolution, and the temporary Cargo projects RustCall
generates, builds and caches. External crates are on
[External crates and hot reload](crates.md).

## Dependencies (`src/dependencies.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "dependencies.jl")]
```

## Dependency resolution (`src/dependency_resolution.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "dependency_resolution.jl")]
```

## Cargo projects (`src/cargoproject.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "cargoproject.jl")]
```

## Cargo builds (`src/cargobuild.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "cargobuild.jl")]
```
