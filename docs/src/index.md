# RustCall.jl

**RustCall.jl** is a Foreign Function Interface (FFI) package for calling Rust code directly from Julia, inspired by [Cxx.jl](https://github.com/JuliaInterop/Cxx.jl).

> It's the last call for headache. 🦀

## Features

### Phase 1: C-Compatible ABI ✅
- **`@rust` macro**: Call Rust functions directly from Julia
- **`rust""` string literal**: Compile and load Rust code as shared libraries
- **`@irust` macro**: Execute Rust code at function scope
- **Type mapping**: Automatic conversion between Rust and Julia types
- **Result/Option support**: Handle Rust's `Result<T, E>` and `Option<T>` types
- **String support**: Pass Julia strings to Rust functions expecting C strings
- **Compilation caching**: SHA256-based caching system for compiled libraries

### Phase 2: LLVM IR Integration ✅
- **`@rust_llvm` macro**: Direct LLVM IR integration (experimental)
- **LLVM optimization**: Configurable optimization passes
- **Ownership types**: `RustBox`, `RustRc`, `RustArc`, `RustVec`, `RustSlice`
- **Array operations**: Indexing, iteration, Julia ↔ Rust conversion
- **Generics support**: Automatic monomorphization and type parameter inference
- **Error handling**: `RustError` exception type with `result_to_exception`
- **Function registration**: Register and cache compiled Rust functions

### Phase 6: External Crate Bindings (Maturin-like) ✅
- **`rustcall_macros` crate**: Proc-macro crate for `#[julia]` attribute
- **`@rust_crate` macro**: Generate Julia bindings for external Rust crates
- **Crate scanning**: Detect `#[julia]` marked functions and structs
- **Automatic building**: Build crates and generate Julia modules

## Installation

```julia
using Pkg
Pkg.add("RustCall")
```

**Requirements:**
- Julia 1.10 or later
- Rust toolchain (`rustc` and `cargo`) installed and available in PATH

To install Rust, visit [rustup.rs](https://rustup.rs/).

### Building Rust Helpers Library

For full functionality including ownership types (Box, Rc, Arc), you need to build the Rust helpers library:

```julia
using Pkg
Pkg.build("RustCall")
```

## Quick Start

```julia
using RustCall

# Define and compile Rust code with #[julia] attribute
rust"""
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

# Call the Rust function directly (wrapper auto-generated)
result = add(10, 20)
println(result)  # => 30
```

## Type Mapping

RustCall.jl automatically maps Rust types to Julia types:

| Rust Type | Julia Type |
|-----------|------------|
| `i8`      | `Int8`     |
| `i16`     | `Int16`    |
| `i32`     | `Int32`    |
| `i64`     | `Int64`    |
| `u8`      | `UInt8`    |
| `u16`     | `UInt16`   |
| `u32`     | `UInt32`   |
| `u64`     | `UInt64`   |
| `f32`     | `Float32`  |
| `f64`     | `Float64`  |
| `bool`    | `Bool`     |
| `usize`   | `UInt`     |
| `isize`   | `Int`      |
| `()`      | `Cvoid`    |
| `*const u8` | `Cstring` / `String` |
| `*mut u8` | `Ptr{UInt8}` |

## Contents

```@contents
Pages = [
    "tutorial.md",
    "examples.md",
    "struct_mapping.md",
    "crate_bindings.md",
    "generics.md",
    "performance.md",
    "troubleshooting.md",
    "api.md",
    "status.md",
]
Depth = 2
```
