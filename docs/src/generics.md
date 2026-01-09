# Generics Support in LastCall.jl

LastCall.jl now supports calling generic Rust functions from Julia. This document explains how to use this feature.

```@setup generics
using LastCall
```

## Overview

Generic functions in Rust use type parameters (e.g., `fn identity<T>(x: T) -> T`). LastCall.jl automatically:

1. **Detects** generic functions in `rust""` blocks
2. **Monomorphizes** them with specific type parameters when called
3. **Caches** the monomorphized instances for reuse

## Basic Usage

### Automatic Detection

When you define a generic function in a `rust""` block, LastCall.jl automatically detects and registers it:

```@example generics

rust"""
#[no_mangle]
pub extern "C" fn identity<T>(x: T) -> T {
    x
}
"""

# The function is automatically registered as generic
# When you call it, it's automatically monomorphized
result = @rust identity(Int32(42))::Int32  # => 42
result = @rust identity(Float64(3.14))::Float64  # => 3.14
```

### Manual Registration

You can also manually register generic functions:

```@example generics
using LastCall

code = """
#[no_mangle]
pub extern "C" fn add<T>(a: T, b: T) -> T {
    a + b
}
"""

register_generic_function("add", code, [:T])

# Call with different types
result = call_generic_function("add", Int32(10), Int32(20))  # => 30
```

## How It Works

### 1. Type Parameter Inference

When you call a generic function, LastCall.jl infers type parameters from the argument types:

```@example generics
# For function: fn identity<T>(x: T) -> T
# Called with: identity(Int32(42))
# Type parameter T is inferred as Int32
```

### 2. Monomorphization

The generic function is specialized (monomorphized) with the inferred types:

```rust
// Original: fn identity<T>(x: T) -> T { x }
// Specialized: fn identity_i32(x: i32) -> i32 { x }
```

### 3. Compilation and Caching

The specialized function is compiled and cached. Subsequent calls with the same type parameters reuse the cached version.

## Advanced Usage

### Multiple Type Parameters

```@example generics
rust"""
#[no_mangle]
pub extern "C" fn first<T, U>(a: T, b: U) -> T {
    a
}
"""

# Type parameters are inferred from arguments
result = @rust first(Int32(10), Float64(3.14))::Int32  # => 10
```

### Explicit Type Parameters

You can also explicitly specify type parameters:

```@example generics
# Define the code
code = """
#[no_mangle]
pub extern "C" fn identity<T>(x: T) -> T {
    x
}
"""

# Register generic function
register_generic_function("identity", code, [:T])

# Explicitly monomorphize
type_params = Dict(:T => Int32)
info = monomorphize_function("identity", type_params)

# Call using @rust macro (recommended way)
# Note: After monomorphization, you can call it directly
result = @rust identity(Int32(42))::Int32  # => 42
```

## Limitations

### Trait Bounds

Currently, trait bounds are not fully parsed. For functions requiring trait bounds, you may need to:

1. Use concrete types in the function signature
2. Manually specify trait bounds in the Rust code

Example:
```rust
// This might not work automatically:
// fn add<T: Copy + Add<Output = T>>(a: T, b: T) -> T { a + b }

// Instead, use concrete types or register manually:
#[no_mangle]
pub extern "C" fn add_i32(a: i32, b: i32) -> i32 { a + b }
```

### Complex Type Inference

Type parameter inference is currently simplified:
- One type parameter maps to one argument (for single-parameter functions)
- Multiple type parameters map to multiple arguments in order

More complex inference (e.g., inferring from return type) is not yet supported.

## API Reference

### Functions

- `register_generic_function(func_name, code, type_params, constraints=Dict())` - Register a generic function
- `is_generic_function(func_name)` - Check if a function is generic
- `call_generic_function(func_name, args...)` - Call a generic function (auto-monomorphizes)
- `monomorphize_function(func_name, type_params)` - Explicitly monomorphize a function
- `specialize_generic_code(code, type_params)` - Specialize generic code with type parameters
- `infer_type_parameters(func_name, arg_types)` - Infer type parameters from argument types

### Registries

- `GENERIC_FUNCTION_REGISTRY` - Maps function names to `GenericFunctionInfo`
- `MONOMORPHIZED_FUNCTIONS` - Maps `(function_name, type_params_tuple)` to `FunctionInfo`

## Examples

### Example 1: Simple Generic Function

```@example generics
using LastCall

rust"""
#[no_mangle]
pub extern "C" fn identity<T>(x: T) -> T {
    x
}
"""

# Automatically monomorphized and called
@test @rust identity(Int32(42))::Int32 == 42
@test @rust identity(Float64(3.14))::Float64 ≈ 3.14
```

### Example 2: Multiple Type Parameters

```@example generics
rust"""
#[no_mangle]
pub extern "C" fn first<T, U>(a: T, b: U) -> T {
    a
}
"""

result = @rust first(Int32(10), Float64(20.0))::Int32  # => 10
```

### Example 3: Manual Registration and Monomorphization

```@example generics
using LastCall

code = """
#[no_mangle]
pub extern "C" fn multiply<T>(a: T, b: T) -> T {
    a * b
}
"""

register_generic_function("multiply", code, [:T])

# Call with automatic monomorphization
result = call_generic_function("multiply", Int32(5), Int32(6))  # => 30
```

## Implementation Details

### Code Specialization

The `specialize_generic_code` function:
1. Replaces type parameters (`T`, `U`, etc.) with concrete Rust types (`i32`, `f64`, etc.)
2. Removes generic parameter lists (`<T>`)
3. Preserves function structure and attributes

### Monomorphization Process

1. Check cache for existing monomorphized instance
2. If not cached, specialize the code
3. Replace function name with specialized name (e.g., `identity_i32`)
4. Ensure `#[no_mangle]` and `extern "C"` are present
5. Compile the specialized function
6. Load and cache the compiled library
7. Return `FunctionInfo` for the monomorphized function

### Caching Strategy

Monomorphized functions are cached by:
- Function name
- Type parameters tuple (sorted for consistency)

This ensures that calling the same generic function with the same types reuses the compiled instance.

## See Also

- [Tutorial](@ref "tutorial.md") - General tutorial
- [Examples](@ref "examples.md") - More examples
- `test/test_generics.jl` - Test suite with examples
