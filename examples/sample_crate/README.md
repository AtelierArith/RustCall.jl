# sample_crate

A demo Rust crate using the `#[julia]` attribute from `lastcall_macros`.

## Overview

This crate was created for testing and demonstrating the functionality of binding external Rust crates using RustCall.jl's `@rust_crate` macro.

## Usage Examples from Julia

### Basic Usage (REPL)

```julia
using RustCall

sample_crate_path = joinpath(pkgdir(RustCall), "examples", "sample_crate")
@rust_crate sample_crate_path

# Call functions through the generated module (SampleCrate)
SampleCrate.add(Int32(2), Int32(3))  # => 5

# Using structs
p = SampleCrate.Point(3.0, 4.0)
SampleCrate.distance_from_origin(p)  # => 5.0

# Property access
p.x  # => 3.0
p.y  # => 4.0
```

### Usage in Tests

```julia
using Test
using Pkg

Pkg.activate(joinpath(@__DIR__, "..", ".."))

using RustCall

sample_crate_path = joinpath(pkgdir(RustCall), "examples", "sample_crate")
@rust_crate sample_crate_path

@testset "SampleCrate" begin
    @testset "Point" begin
        p = SampleCrate.Point(3.0, 4.0)
        @test SampleCrate.distance_from_origin(p) == 5.0
        @test p.x == 3.0
        @test p.y == 4.0
    end

    @testset "Basic functions" begin
        @test SampleCrate.add(Int32(2), Int32(3)) == Int32(5)
        @test SampleCrate.multiply(2.0, 3.0) == 6.0
        @test SampleCrate.fibonacci(UInt32(10)) == UInt64(55)
        @test SampleCrate.is_prime(UInt32(7)) == true
    end
end
```

## Included Features

### Simple Functions

| Function Name | Signature | Description |
|--------------|-----------|-------------|
| `add` | `(i32, i32) -> i32` | Add two integers |
| `multiply` | `(f64, f64) -> f64` | Multiply two floating point numbers |
| `fibonacci` | `(u32) -> u64` | Calculate the nth Fibonacci number |
| `is_prime` | `(u32) -> bool` | Prime number check |

### Functions Returning Result<T, E>

| Function Name | Signature | Description |
|--------------|-----------|-------------|
| `safe_divide` | `(f64, f64) -> Result<f64, i32>` | Division that safely handles division by zero |
| `parse_positive` | `(i32) -> Result<u32, i32>` | Only accepts positive integers |

### Functions Returning Option<T>

| Function Name | Signature | Description |
|--------------|-----------|-------------|
| `safe_sqrt` | `(f64) -> Option<f64>` | Calculate square root of non-negative numbers |
| `find_positive` | `(i32, i32) -> Option<i32>` | Return the first positive number from two inputs |

### Structs

#### Point

A struct representing 2D coordinates.

```rust
pub struct Point { pub x: f64, pub y: f64 }
```

Methods:
- `new(x, y)` - Create a new point
- `distance_from_origin(&self)` - Distance from origin
- `distance_to(&self, other_x, other_y)` - Distance to another point
- `translate(&mut self, dx, dy)` - Move the point

#### Counter

A counter with mutable state.

```rust
pub struct Counter { pub value: i32 }
```

Methods:
- `new(initial)` - Create with initial value
- `increment(&mut self)` - Increment
- `decrement(&mut self)` - Decrement
- `add(&mut self, amount)` - Add value
- `get(&self)` - Get current value
- `reset(&mut self)` - Reset to zero

#### Rectangle

A struct representing a rectangle.

```rust
pub struct Rectangle { pub width: f64, pub height: f64 }
```

Methods:
- `new(width, height)` - Create a new rectangle
- `area(&self)` - Calculate area
- `perimeter(&self)` - Calculate perimeter
- `is_square(&self)` - Check if it's a square
- `scale(&mut self, factor)` - Scale

## Notes

- `@rust_crate` recommends using absolute paths or paths specified with `joinpath`
- `pkgdir(RustCall)` can be used to get the package root directory
- Generated modules are directly defined in the caller's scope
- Module names are converted from crate names to PascalCase (e.g., `sample_crate` → `SampleCrate`)
- Custom module names can be specified with the `name="CustomName"` option
- Use specific types like `Int32` or `UInt32` for integer types

## Build

```bash
cd examples/sample_crate
cargo build --release
```

## Rust Tests

```bash
cargo test
```

## Dependencies

- `lastcall_macros`: Provides the `#[julia]` attribute macro (local path reference)
