# RustCall.jl

[![CI](https://github.com/atelierarith/RustCall.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/atelierarith/RustCall.jl/actions/workflows/CI.yml)

RustCall.jl is a Julia package for calling Rust code directly. It covers the common paths from this repository: inline Rust via `rust"""..."""`, explicit FFI calls with `@rust`, lightweight inline expressions with `@irust`, `#[julia]`-based wrapper generation, and external crate loading with `@rust_crate`.

It is inspired by [Cxx.jl](https://github.com/JuliaInterop/Cxx.jl), but targets Rust.

## Installation

Requirements:

- Julia 1.12 or later
- Rust toolchain (`rustc` and `cargo`) available in `PATH`

```julia
using Pkg
Pkg.add(url="https://github.com/atelierarith/RustCall.jl")
Pkg.build("RustCall")
```

`Pkg.build("RustCall")` builds the helper library used by ownership-related features such as `RustBox`, `RustRc`, `RustArc`, `RustVec`, and `RustSlice`.

## Quick Start

The simplest path is to annotate Rust functions with `#[julia]` and call the generated Julia wrapper directly.

```julia
using RustCall

rust"""
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

add(10, 20) # 30
```

If you want explicit C-ABI style calls, use `@rust`.

```julia
using RustCall

rust"""
#[no_mangle]
pub extern "C" fn multiply(a: i32, b: i32) -> i32 {
    a * b
}
"""

@rust multiply(Int32(6), Int32(7))::Int32 # 42
```

For small expressions inside Julia functions, `@irust` captures Julia variables with `$var`.

```julia
using RustCall

function affine(a, x, b)
    @irust("\$a * \$x + \$b")
end

affine(Int32(2), Int32(10), Int32(3)) # 23
```

## Main APIs

- `rust"""..."""` / `@rust_str`: compile Rust code, cache the build artifact, and make it available in the current Julia module
- `#[julia]`: generate Julia-callable wrappers for Rust functions and structs
- `@rust`: call exported functions through a C-compatible ABI
- `@irust`: compile a small Rust expression with Julia variable capture
- `@rust_crate`: build and load an external crate annotated with `#[julia]`
- `@rust_llvm`: experimental LLVM-based call path

Rust dependencies can be declared inline with `// cargo-deps:` or fenced `cargo` blocks. The first build may need network access.

## External Crates

`@rust_crate` loads a Rust crate and returns a Julia module-like binding object.

```julia
using RustCall

const MyCrate = @rust_crate "/path/to/my_crate"
MyCrate.add(Int32(1), Int32(2)) # 3
```

For crate-side bindings, use the companion `juliacall_macros` crate and mark exported items with `#[julia]`.

## Documentation And Examples

- Documentation: <https://atelierarith.github.io/RustCall.jl>
- Examples: [`examples/`](examples)
- Tutorial source: [`docs/src/tutorial.md`](docs/src/tutorial.md)
- API reference source: [`docs/src/api.md`](docs/src/api.md)
- Troubleshooting source: [`docs/src/troubleshooting.md`](docs/src/troubleshooting.md)

## Development

For a local checkout:

```bash
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project -e 'using Pkg; Pkg.build("RustCall")'
julia --project -e 'using Pkg; Pkg.test()'
julia --project=docs docs/make.jl
```

The main package entry point is `src/RustCall.jl`. Runnable examples live in `examples/`.

## Acknowledgments

RustCall.jl has been implemented with support from AI coding tools and agents including Codex, Claude Code, and Cursor.
