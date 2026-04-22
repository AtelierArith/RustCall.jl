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
- **`juliacall_macros` crate**: Proc-macro crate for `#[julia]` attribute
- **`@rust_crate` macro**: Generate Julia bindings for external Rust crates
- **Crate scanning**: Detect `#[julia]` marked functions and structs
- **Automatic building**: Build crates and generate Julia modules

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/atelierarith/RustCall.jl")
```

For contributor work or local edits:

```julia
using Pkg
Pkg.develop(path="/path/to/RustCall.jl")
```

**Requirements:**
- Julia 1.12 or later
- Rust toolchain (`rustc` and `cargo`) installed and available in PATH

To install Rust, visit [rustup.rs](https://rustup.rs/).

### Building Rust Helpers Library

For full functionality including ownership types (Box, Rc, Arc), you need to build the Rust helpers library:

```julia
using Pkg
Pkg.build("RustCall")
```

Or from the command line:

```bash
julia --project -e 'using Pkg; Pkg.build("RustCall")'
```

This will compile the Rust helpers library that provides FFI functions for ownership types.

## Project Structure

- `src/`: RustCall implementation (`src/RustCall.jl` is the entry point)
- `test/`: package tests (`test/runtests.jl` includes feature tests)
- `docs/`: Documenter project and design notes
- `deps/`: Rust helper/runtime and proc-macro crates used by build/runtime flows
- `examples/`: runnable integration examples

## Included Examples

- `examples/MyExample.jl`: Julia package using inline `rust"""..."""` blocks
- `examples/sample_crate`: external Rust crate using `#[julia]` and `@rust_crate`
- `examples/sample_crate_pyo3`: dual Julia/Python bindings example
- `examples/pluto/hello.jl`: Pluto notebook-style walkthrough

## Quick Start

If you are running these examples from a source checkout of this repository, instantiate the project first:

```julia
using Pkg
Pkg.instantiate()
```

### 1. Define and Call Rust Functions (Simple Way)

```julia
using RustCall

# Use #[julia] attribute - no boilerplate needed!
rust"""
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

# Call directly - wrapper is auto-generated
add(10, 20)  # => 30
```

### 2. Traditional FFI (Full Control)

```julia
using RustCall

# Traditional way with explicit FFI markers
rust"""
#[no_mangle]
pub extern "C" fn multiply(a: i32, b: i32) -> i32 {
    a * b
}
"""

# Call with @rust macro and explicit types
@rust multiply(Int32(5), Int32(7))::Int32  # => 35
```

### 3. Inline Rust with `@irust`

Execute Rust code directly with automatic variable binding:

```julia
function compute(x, y)
    @irust("\$x * \$y + 10")
end

compute(Int32(3), Int32(4))  # => 22
```

### 4. Use External Crates

Leverage the Rust ecosystem with automatic Cargo integration:

```julia
rust"""
// cargo-deps: rand = "0.8"

use rand::Rng;

#[no_mangle]
pub extern "C" fn random_number() -> i32 {
    rand::thread_rng().gen_range(1..=100)
}
"""

@rust random_number()::Int32  # => random number 1-100
```

### 5. Rust Structs as Julia Objects

Define Rust structs and use them as first-class Julia types:

```julia
rust"""
#[julia]
pub struct Counter {
    value: i32,
}

impl Counter {
    pub fn new(initial: i32) -> Self {
        Self { value: initial }
    }

    pub fn increment(&mut self) {
        self.value += 1;
    }

    pub fn get(&self) -> i32 {
        self.value
    }
}
"""

counter = Counter(0)
increment(counter)
increment(counter)
get(counter)  # => 2
```

### More Examples

```julia
# Float operations
rust"""
#[no_mangle]
pub extern "C" fn circle_area(radius: f64) -> f64 {
    std::f64::consts::PI * radius * radius
}
"""
@rust circle_area(2.0)::Float64  # => 12.566370614359172

# Boolean functions
rust"""
#[no_mangle]
pub extern "C" fn is_even(n: i32) -> bool {
    n % 2 == 0
}
"""
@rust is_even(Int32(42))::Bool  # => true

# Multiple variables with @irust
function quadratic(a, b, c, x)
    @irust("\$a * \$x * \$x + \$b * \$x + \$c")
end
quadratic(1.0, 2.0, 1.0, 3.0)  # => 16.0 (x² + 2x + 1 at x=3)
```

### 6. Image Processing with Rust

Process images using Rust for performance-critical operations:

If you want to run this example locally, install `Images` first:

```julia
using Pkg
Pkg.add("Images")
```

```julia
using RustCall
using Images

# Define Rust grayscale conversion
rust"""
#[no_mangle]
pub extern "C" fn grayscale_image(pixels: *mut u8, width: usize, height: usize) {
    let slice = unsafe { std::slice::from_raw_parts_mut(pixels, width * height * 3) };
    for i in 0..(width * height) {
        let r = slice[i * 3] as f32;
        let g = slice[i * 3 + 1] as f32;
        let b = slice[i * 3 + 2] as f32;
        let gray = (0.299 * r + 0.587 * g + 0.114 * b) as u8;
        slice[i * 3] = gray;
        slice[i * 3 + 1] = gray;
        slice[i * 3 + 2] = gray;
    }
}
"""

# Process image data
pixels = vec(rand(UInt8, 256 * 256 * 3))
@rust grayscale_image(pointer(pixels), UInt(256), UInt(256))::Cvoid
```

### 7. External Crate Bindings (Maturin-like)

Generate Julia bindings for external Rust crates using `@rust_crate`:

**Rust side (external crate):**
```rust
// Cargo.toml needs: juliacall_macros = "0.1"
use juliacall_macros::julia;

#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[julia]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[julia]
impl Point {
    #[julia]
    pub fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }

    #[julia]
    pub fn distance(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
}
```

**Julia side:**
```julia
using RustCall

const MyCrate = @rust_crate "/path/to/my_crate"

MyCrate.add(Int32(1), Int32(2))  # => 3
p = MyCrate.Point(3.0, 4.0)
MyCrate.distance(p)  # => 5.0
```

Inside a function or other local scope, capture the return value from `@rust_crate`
and call through that binding:

```julia
function load_my_crate(crate_path)
    bindings = @rust_crate crate_path name="MyCrate"
    p = bindings.Point(3.0, 4.0)
    return bindings.add(Int32(1), Int32(2)), bindings.distance(p), p.x
end
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

For repository layout, bundled examples, benchmark commands, and contributor-oriented notes, see [Project Guide](project_guide.md).

```@contents
Pages = [
    "tutorial.md",
    "examples.md",
    "struct_mapping.md",
    "crate_bindings.md",
    "generics.md",
    "performance.md",
    "troubleshooting.md",
    "project_guide.md",
    "api.md",
    "status.md",
]
Depth = 2
```
