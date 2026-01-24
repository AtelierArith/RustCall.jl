# External Crate Bindings (Phase 6)

LastCall.jl provides a Maturin-like feature for generating Julia bindings from external Rust crates. This allows you to develop Rust libraries with the `#[julia]` attribute and automatically generate Julia bindings.

## Overview

The feature consists of two components:

1. **`lastcall_macros`** - A Rust proc-macro crate that provides the `#[julia]` attribute
2. **`@rust_crate`** - A Julia macro that scans external crates and generates bindings

## Quick Start

### Rust Side

Create a Rust crate with `lastcall_macros`:

```toml
# Cargo.toml
[package]
name = "my_library"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
lastcall_macros = { path = "/path/to/LastCall.jl/deps/lastcall_macros" }
# Or from crates.io (when published):
# lastcall_macros = "0.1"
```

```rust
// src/lib.rs
use lastcall_macros::julia;

#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[julia]
pub struct Counter {
    pub value: i32,
}

#[julia]
impl Counter {
    #[julia]
    pub fn new(initial: i32) -> Self {
        Self { value: initial }
    }

    #[julia]
    pub fn increment(&mut self) {
        self.value += 1;
    }

    #[julia]
    pub fn get(&self) -> i32 {
        self.value
    }
}
```

### Julia Side

```julia
using LastCall

# Generate and load bindings
@rust_crate "/path/to/my_library"

# Use the generated module
result = MyLibrary.add(1, 2)  # => 3

c = MyLibrary.Counter(0)
MyLibrary.increment(c)
MyLibrary.get(c)  # => 1
```

## The `#[julia]` Attribute

The `#[julia]` attribute simplifies FFI function definitions.

### For Functions

```rust
// Before: verbose FFI declaration
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}

// After: simple #[julia] attribute
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
```

The `#[julia]` attribute automatically:
- Adds `#[no_mangle]`
- Makes the function `pub extern "C"`

### For Structs

```rust
#[julia]
pub struct Point {
    pub x: f64,
    pub y: f64,
}
```

This generates:
- `#[repr(C)]` for C-compatible layout
- `Point_free(ptr)` - Free function
- `Point_get_x(ptr)` / `Point_set_x(ptr, value)` - Field accessors
- `Point_get_y(ptr)` / `Point_set_y(ptr, value)` - Field accessors

### For Impl Blocks

```rust
#[julia]
impl Counter {
    #[julia]
    pub fn new(initial: i32) -> Self {
        Self { value: initial }
    }

    #[julia]
    pub fn get(&self) -> i32 {
        self.value
    }
}
```

This generates FFI wrappers:
- `Counter_new(initial)` - Returns `*mut Counter`
- `Counter_get(ptr)` - Takes `*const Counter`, returns `i32`

## API Reference

### `scan_crate(path)`

Scan a Rust crate and extract `#[julia]` marked items.

```julia
info = scan_crate("/path/to/crate")

println("Crate: ", info.name)
println("Functions: ", length(info.julia_functions))
println("Structs: ", length(info.julia_structs))
```

### `generate_bindings(path; kwargs...)`

Generate Julia bindings for an external crate.

```julia
bindings = generate_bindings("/path/to/crate",
    output_module_name = "MyBindings",
    build_release = true,
    cache_enabled = true
)

eval(bindings)

# Now MyBindings module is available
MyBindings.add(1, 2)
```

### `@rust_crate`

Macro form for easy one-line usage.

```julia
# Basic usage
@rust_crate "/path/to/crate"

# With options
@rust_crate "/path/to/crate" name="CustomName" release=true cache=true
```

## Type Definitions

### `CrateInfo`

Information about a scanned Rust crate.

| Field | Type | Description |
|-------|------|-------------|
| `name` | `String` | Crate name |
| `path` | `String` | Absolute path |
| `version` | `String` | Crate version |
| `dependencies` | `Vector{DependencySpec}` | Dependencies |
| `julia_functions` | `Vector{RustFunctionSignature}` | `#[julia]` functions |
| `julia_structs` | `Vector{RustStructInfo}` | `#[julia]` structs |
| `source_files` | `Vector{String}` | .rs file paths |

### `CrateBindingOptions`

Options for binding generation.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `output_module_name` | `Union{String, Nothing}` | `nothing` | Override module name |
| `output_path` | `Union{String, Nothing}` | `nothing` | Write generated code to file |
| `use_wrapper_crate` | `Bool` | `true` | Create wrapper crate |
| `build_release` | `Bool` | `true` | Build in release mode |
| `cache_enabled` | `Bool` | `true` | Enable library caching |

## Build Process

When you call `@rust_crate`, LastCall.jl:

1. **Scans the crate** - Parses all `.rs` files for `#[julia]` attributes
2. **Checks cache** - If a cached library exists with matching hash, uses it
3. **Builds the crate** - If the crate already has `cdylib` crate-type, builds directly; otherwise creates a wrapper crate
4. **Generates Julia module** - Creates wrapper functions and struct definitions
5. **Loads the library** - Loads the compiled `.so`/`.dylib`/`.dll`

## Caching

Compiled libraries are cached based on source code hash:

```julia
# Clear the cache
clear_cargo_cache()

# Check cache size
get_cargo_cache_size()
```

## Supported Types

The following Rust types are supported in `#[julia]` functions:

| Rust Type | Julia Type |
|-----------|------------|
| `i8`, `i16`, `i32`, `i64` | `Int8`, `Int16`, `Int32`, `Int64` |
| `u8`, `u16`, `u32`, `u64` | `UInt8`, `UInt16`, `UInt32`, `UInt64` |
| `f32`, `f64` | `Float32`, `Float64` |
| `bool` | `Bool` |
| `usize`, `isize` | `UInt`, `Int` |
| `()` | `Cvoid` |
| `*const T`, `*mut T` | `Ptr{T}` |

## Example: Complete Workflow

### 1. Create Rust Crate

```bash
cargo new --lib my_math
cd my_math
```

### 2. Configure Cargo.toml

```toml
[package]
name = "my_math"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
lastcall_macros = { path = "/path/to/LastCall.jl/deps/lastcall_macros" }
```

### 3. Write Rust Code

```rust
// src/lib.rs
use lastcall_macros::julia;

#[julia]
fn factorial(n: u64) -> u64 {
    (1..=n).product()
}

#[julia]
fn fibonacci(n: u32) -> u64 {
    match n {
        0 => 0,
        1 => 1,
        _ => {
            let mut a = 0u64;
            let mut b = 1u64;
            for _ in 2..=n {
                let c = a + b;
                a = b;
                b = c;
            }
            b
        }
    }
}
```

### 4. Use in Julia

```julia
using LastCall

@rust_crate "/path/to/my_math"

factorial(UInt64(10))  # => 3628800
fibonacci(UInt32(20))  # => 6765
```

## Troubleshooting

### Crate not building

Ensure your crate has:
- `crate-type = ["cdylib"]` in `[lib]` section
- `lastcall_macros` as a dependency
- Valid Rust code that compiles

### Functions not found

Check that:
- Functions have the `#[julia]` attribute
- Function signatures use FFI-compatible types
- The crate builds without errors

### Type errors

Ensure you're using the correct Julia types that match the Rust function signatures.
