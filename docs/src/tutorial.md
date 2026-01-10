# LastCall.jl Tutorial

This tutorial walks you through using LastCall.jl to call Rust code from Julia step by step.

## Table of Contents

1. [Getting Started](#getting-started)
2. [Basic Usage](#basic-usage)
3. [Understanding the Type System](#understanding-the-type-system)
4. [String Handling](#string-handling)
5. [Error Handling](#error-handling)
6. [Using Ownership Types](#using-ownership-types)
7. [LLVM IR Integration (Advanced)](#llvm-ir-integration-advanced)
8. [Performance Optimization](#performance-optimization)

## Getting Started

### Installation

```julia
using Pkg
Pkg.add("LastCall")
```

### Requirements

- Julia 1.10 or later
- Rust toolchain (`rustc` and `cargo`) installed and available in PATH

To install Rust, visit [rustup.rs](https://rustup.rs/).

### Building Rust Helpers Library (Optional)

To use ownership types (Box, Rc, Arc), you need to build the Rust helpers library:

```julia
using Pkg
Pkg.build("LastCall")
```

## Basic Usage

```@setup tutorial
using LastCall
```

### Step 1: Define and Compile Rust Code

Use the `rust""` string literal to define and compile Rust code:

```@example tutorial
rust"""
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""
```

This code is automatically compiled and loaded as a shared library.

### Step 2: Call Rust Functions

Use the `@rust` macro to call functions:

```@example tutorial
# With type inference
result = @rust add(Int32(10), Int32(20))::Int32
println(result)  # => 30
```

### Step 3: Define Multiple Functions

You can define multiple functions in the same `rust""` block:

```@example tutorial
rust"""
#[no_mangle]
pub extern "C" fn multiply(x: f64, y: f64) -> f64 {
    x * y
}

#[no_mangle]
pub extern "C" fn subtract(a: i64, b: i64) -> i64 {
    a - b
}
"""

# Usage
product = @rust multiply(3.0, 4.0)::Float64  # => 12.0
difference = @rust subtract(100, 30)::Int64  # => 70
```

## Understanding the Type System

### Basic Type Mapping

LastCall.jl automatically maps Rust types to Julia types:

| Rust Type | Julia Type | Example |
|-----------|------------|---------|
| `i8`      | `Int8`     | `10i8`  |
| `i16`     | `Int16`    | `100i16` |
| `i32`     | `Int32`    | `1000i32` |
| `i64`     | `Int64`    | `10000i64` |
| `u8`      | `UInt8`    | `10u8`  |
| `u32`     | `UInt32`   | `1000u32` |
| `u64`     | `UInt64`   | `10000u64` |
| `f32`     | `Float32`  | `3.14f0` |
| `f64`     | `Float64`  | `3.14159` |
| `bool`    | `Bool`     | `true`  |
| `usize`   | `UInt`     | `100u`  |
| `isize`   | `Int`      | `100`   |
| `()`      | `Cvoid`    | -       |

### Type Inference

LastCall.jl tries to infer return types from argument types, but explicit specification is recommended:

```julia
# Not recommended - relies on inference (works but not recommended)
result = @rust add(Int32(10), Int32(20))

# Recommended - explicit type specification
result = @rust add(Int32(10), Int32(20))::Int32
```

### Boolean Values

```@example tutorial
rust"""
#[no_mangle]
pub extern "C" fn is_positive(x: i32) -> bool {
    x > 0
}
"""

@rust is_positive(Int32(5))::Bool   # => true
@rust is_positive(Int32(-5))::Bool  # => false
```

## String Handling

### Passing as C Strings

When Rust functions expect `*const u8` (C strings), you can pass Julia `String` directly:

```@example tutorial
rust"""
#[no_mangle]
pub extern "C" fn string_length(s: *const u8) -> u32 {
    let c_str = unsafe { std::ffi::CStr::from_ptr(s as *const i8) };
    c_str.to_bytes().len() as u32
}
"""

# Julia String is automatically converted to Cstring
len = @rust string_length("hello")::UInt32  # => 5
len = @rust string_length("世界")::UInt32   # => 6 (UTF-8 bytes)
```

### UTF-8 String Handling

```@example tutorial
rust"""
#[no_mangle]
pub extern "C" fn count_chars(s: *const u8) -> u32 {
    let c_str = unsafe { std::ffi::CStr::from_ptr(s as *const i8) };
    let utf8_str = std::str::from_utf8(c_str.to_bytes()).unwrap();
    utf8_str.chars().count() as u32
}
"""

# Count UTF-8 characters
count = @rust count_chars("hello")::UInt32    # => 5
count = @rust count_chars("世界")::UInt32     # => 2 (characters, not bytes)
```

## Error Handling

### Using Result Type

Rust's `Result<T, E>` type is represented as `RustResult{T, E}` in Julia:

```@example tutorial
rust"""
#[no_mangle]
pub extern "C" fn divide(a: i32, b: i32) -> i32 {
    if b == 0 {
        return -1;  // Return -1 as error code
    }
    a / b
}
"""

# Error checking
result = @rust divide(Int32(10), Int32(2))::Int32
if result == -1
    println("Division by zero!")
end
```

### Explicit Use of RustResult

For a more Rust-like approach, you can define functions that return `Result` types:

```julia
# Create RustResult manually
ok_result = RustResult{Int32, String}(true, Int32(42))
is_ok(ok_result)  # => true
unwrap(ok_result)  # => 42

err_result = RustResult{Int32, String}(false, "error message")
is_err(err_result)  # => true
unwrap_or(err_result, Int32(0))  # => 0
```

### Converting to Exceptions

Use `result_to_exception` to convert `Result` to Julia exceptions:

```julia
err_result = RustResult{Int32, String}(false, "division by zero")
try
    value = result_to_exception(err_result)
catch e
    if e isa RustError
        println("Rust error: $(e.message)")
    end
end
```

## Using Ownership Types

### RustBox (Single Ownership)

`RustBox<T>` is a heap-allocated value with single ownership:

```julia
# Rust helpers library required
if is_rust_helpers_available()
    # Create Box (usually returned from Rust functions)
    # Here as an example, actual usage is from Rust function return values
    box = RustBox{Int32}(ptr)  # ptr obtained from Rust function

    # Explicitly drop after use
    drop!(box)
end
```

### RustRc (Reference Counting, Single-threaded)

```julia
if is_rust_helpers_available()
    # Create Rc
    rc1 = RustRc{Int32}(ptr)

    # Clone to increment reference count
    rc2 = clone(rc1)

    # Dropping one keeps the other valid
    drop!(rc1)
    @assert is_valid(rc2)  # Still valid

    # Drop last reference
    drop!(rc2)
end
```

### RustArc (Atomic Reference Counting, Thread-safe)

```julia
if is_rust_helpers_available()
    # Create Arc
    arc1 = RustArc{Int32}(ptr)

    # Thread-safe clone
    arc2 = clone(arc1)

    # Can be used from different tasks
    @sync begin
        @async begin
            # Use arc2
        end
    end

    drop!(arc1)
    drop!(arc2)
end
```

## LLVM IR Integration (Advanced)

### Using @rust_llvm Macro

The `@rust_llvm` macro enables optimized calls via LLVM IR integration (experimental):

```julia
rust"""
#[no_mangle]
pub extern "C" fn fast_add(a: i32, b: i32) -> i32 {
    a + b
}
"""

# Register function
info = compile_and_register_rust_function("""
#[no_mangle]
pub extern "C" fn fast_add(a: i32, b: i32) -> i32 { a + b }
""", "fast_add")

# Call with @rust_llvm (potentially optimized)
result = @rust_llvm fast_add(Int32(10), Int32(20))  # => 30
```

### LLVM Optimization Settings

```julia
using LastCall

# Create optimization configuration
config = OptimizationConfig(
    level=3,  # Optimization level 0-3
    enable_vectorization=true,
    inline_threshold=300
)

# Optimize module
# optimize_module!(module, config)

# Convenience functions
# optimize_for_speed!(module)  # Level 3, aggressive optimization
# optimize_for_size!(module)   # Level 2, size optimization
```

## Performance Optimization

### Using Compilation Cache

LastCall.jl automatically caches compilation results. No need to recompile the same code:

```julia
# First compilation (takes time)
rust"""
#[no_mangle]
pub extern "C" fn compute(x: i32) -> i32 {
    x * 2
}
"""

# Same code again (fast load from cache)
rust"""
#[no_mangle]
pub extern "C" fn compute(x: i32) -> i32 {
    x * 2
}
"""
```

### Cache Management

```julia
# Check cache size
size = get_cache_size()
println("Cache size: $size bytes")

# List cached libraries
libs = list_cached_libraries()
println("Cached libraries: $libs")

# Cleanup old cache (older than 30 days)
cleanup_old_cache(30)

# Clear all cache
clear_cache()
```

### Running Benchmarks

To measure performance:

```bash
julia --project benchmark/benchmarks.jl
```

This compares performance of Julia native, `@rust`, and `@rust_llvm`.

## Best Practices

### 1. Always Specify Types Explicitly

```julia
# Recommended
result = @rust add(Int32(10), Int32(20))::Int32

# Not recommended (relies on type inference)
result = @rust add(Int32(10), Int32(20))
```

### 2. Proper Error Handling

```julia
# Use Result type
result = some_rust_function()
if is_err(result)
    # Handle error
    return
end
value = unwrap(result)
```

### 3. Be Careful with Memory Management

When using ownership types, always call `drop!` appropriately:

```julia
box = RustBox{Int32}(ptr)
try
    # Use box
finally
    drop!(box)  # Always cleanup
end
```

### 4. Leverage Caching

When using the same Rust code multiple times, caching is automatically leveraged.

### 5. Clear Cache When Debugging

If issues occur, try clearing the cache and recompiling:

```julia
clear_cache()
```

## Next Steps

- See [Examples](examples.md) for more advanced usage examples
- Check [Troubleshooting](troubleshooting.md) to solve problems
- Review [API Reference](api.md) for all features
