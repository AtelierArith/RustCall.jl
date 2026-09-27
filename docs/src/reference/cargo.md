# Cargo projects and dependencies

Everything an inline block with a `// cargo-deps:` comment (or a
`` //! ```cargo `` block) goes through instead of a bare `rustc`: the
dependency DSL and its resolution, and the temporary Cargo projects RustCall
generates, builds and caches. External crates are on
[External crates](crates.md).

## Dependencies (`src/build/dependencies.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "build", "dependencies.jl")]
```

## Dependency resolution (`src/build/dependency_resolution.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "build", "dependency_resolution.jl")]
```

## Cargo projects (`src/build/cargoproject.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "build", "cargoproject.jl")]
```

## Cargo builds (`src/build/cargobuild.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "build", "cargobuild.jl")]
```
