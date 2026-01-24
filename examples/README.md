# LastCall.jl Examples

This directory contains example projects demonstrating how to use LastCall.jl for Julia-Rust interoperability.

## Prerequisites

Before running the examples, ensure you have:

1. **Julia 1.12+** installed
2. **Rust** (stable) with `cargo` installed
   ```bash
   # Check Rust installation
   rustc --version
   cargo --version
   ```
3. **LastCall.jl** available (either installed or developed locally)

## Available Examples

| Example | Description | Difficulty | Key Features |
|---------|-------------|------------|--------------|
| [MyExample.jl](./MyExample.jl/) | Julia package using `rust""` string literal | Beginner | Inline Rust code, basic FFI |
| [sample_crate](./sample_crate/) | Rust crate using `#[julia]` attribute | Intermediate | External crate, `@rust_crate` macro |

## Quick Start Guide

### For Julia Users (Start Here)

If you're a Julia user who wants to call Rust code, start with **MyExample.jl**:

```julia
using Pkg

# Navigate to the example
cd("examples/MyExample.jl")

# Activate and set up the environment
Pkg.activate(".")
Pkg.develop(path="../../")  # Add LastCall.jl
Pkg.instantiate()

# Use the example
using MyExample
add_numbers(Int32(10), Int32(20))  # => 30
```

### For Rust Developers

If you're a Rust developer who wants to expose your code to Julia, start with **sample_crate**:

```julia
using LastCall

# Load the sample crate
sample_crate_path = joinpath(dirname(dirname(pathof(LastCall))), "examples", "sample_crate")
@rust_crate sample_crate_path

# Call Rust functions
Samplecrate.add(Int32(2), Int32(3))  # => 5
Samplecrate.fibonacci(UInt32(10))    # => 55
```

## Example Descriptions

### MyExample.jl

A Julia package that demonstrates using the `rust""` string literal to write Rust code directly in Julia.

**Features demonstrated:**
- Inline Rust code with `rust"..."` string literals
- Basic numerical operations (add, multiply, fibonacci)
- String processing (word count, reverse)
- Array operations (sum, max)

**How to run:**
```bash
cd examples/MyExample.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../../"); Pkg.instantiate()'
julia --project=. test/runtests.jl
```

### sample_crate

A standalone Rust crate demonstrating the `#[julia]` attribute from `lastcall_macros`.

**Features demonstrated:**
- `#[julia]` attribute for automatic FFI generation
- `Result<T, E>` and `Option<T>` type handling
- Struct definitions with methods
- Property access syntax for struct fields

**How to build:**
```bash
cd examples/sample_crate
cargo build --release
```

**How to use from Julia:**
```julia
using LastCall
@rust_crate "/path/to/examples/sample_crate"

# Functions
Samplecrate.add(Int32(1), Int32(2))

# Structs with property access
p = Samplecrate.Point(3.0, 4.0)
p.x  # => 3.0
p.y  # => 4.0
Samplecrate.distance_from_origin(p)  # => 5.0
```

## Learning Progression

We recommend learning LastCall.jl in this order:

1. **Start with MyExample.jl**
   - Learn how to write inline Rust code
   - Understand basic type mappings (Int32 ↔ i32, Float64 ↔ f64)
   - Practice calling Rust functions from Julia

2. **Move to sample_crate**
   - Learn about the `#[julia]` attribute
   - Understand `@rust_crate` for external crates
   - Explore struct handling and property access
   - Learn about `Result<T, E>` and `Option<T>` support

3. **Read the documentation**
   - [Tutorial](../docs/src/tutorial.md)
   - [Crate Bindings (Phase 6)](../docs/src/crate_bindings.md)
   - [Troubleshooting](../docs/src/troubleshooting.md)

## Troubleshooting

### Rust not found

If you see "rustc not found in PATH", install Rust from [rustup.rs](https://rustup.rs/).

### Library build fails

Try clearing the cache and rebuilding:
```julia
using LastCall
clear_cache()
```

### Module name confusion

When using `@rust_crate`, the generated module name is the crate name with:
- Underscores removed
- First letter capitalized

Example: `sample_crate` → `Samplecrate`

You can specify a custom name:
```julia
@rust_crate "/path/to/crate" name="MyCustomName"
```

## Additional Resources

- [LastCall.jl Documentation](https://atelierarith.github.io/LastCall.jl/)
- [Rust FFI Guide](https://doc.rust-lang.org/nomicon/ffi.html)
- [Julia ccall Documentation](https://docs.julialang.org/en/v1/manual/calling-c-and-fortran-code/)
