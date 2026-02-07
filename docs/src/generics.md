# Generics Support in RustCall.jl

RustCall.jl now supports calling generic Rust functions from Julia. This document explains how to use this feature.

```@setup generics
using RustCall
```

## Overview

Generic functions in Rust use type parameters (e.g., `fn identity<T>(x: T) -> T`). RustCall.jl automatically:

1. **Detects** generic functions in `rust""` blocks
2. **Monomorphizes** them with specific type parameters when called
3. **Caches** the monomorphized instances for reuse

## Basic Usage

### Automatic Detection

When you define a generic function in a `rust""` block, RustCall.jl automatically detects and registers it:

```julia

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

```julia
using RustCall

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

When you call a generic function, RustCall.jl infers type parameters from the argument types:

```julia
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

```julia
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

```julia
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

## Trait Bounds Support

RustCall.jl now supports parsing trait bounds in generic functions. This includes:

1. **Inline bounds**: `fn foo<T: Copy + Clone, U: Debug>(x: T) -> U`
2. **Where clauses**: `fn foo<T, U>(x: T) -> U where T: Copy, U: Debug`
3. **Generic trait bounds**: `fn foo<T: Add<Output = T>>(x: T) -> T`
4. **Mixed format**: Combining inline bounds and where clauses

### Using Trait Bounds

When registering a generic function, trait bounds are automatically parsed and stored:

```julia
using RustCall

# Define a function with trait bounds
code = """
pub fn identity<T: Copy + Clone>(x: T) -> T {
    x
}
"""

# Parse the generic function (constraints are automatically extracted)
info = parse_generic_function(code, "identity")
println(info.constraints)  # Dict(:T => TypeConstraints([Copy, Clone]))
```

### Manually Specifying Constraints

You can also manually specify constraints when registering a generic function:

```julia
using RustCall

code = """
pub fn add<T>(a: T, b: T) -> T {
    a + b
}
"""

# Using TypeConstraints (recommended)
constraints = Dict(:T => TypeConstraints([
    TraitBound("Copy", String[]),
    TraitBound("Add", ["Output = T"])
]))
register_generic_function("add", code, [:T], constraints)

# Or using the legacy string format (backward compatible)
register_generic_function("add_legacy", code, [:T], Dict(:T => "Copy + Add<Output = T>"))
```

### Converting Constraints to Rust Syntax

You can convert parsed constraints back to Rust syntax:

```julia
using RustCall

constraints = Dict(:T => TypeConstraints([
    TraitBound("Copy", String[]),
    TraitBound("Clone", String[])
]))
rust_str = constraints_to_rust_string(constraints)
println(rust_str)  # "T: Copy + Clone"
```

## Limitations

### Trait Bounds Validation

While trait bounds are now properly parsed and stored, runtime validation (checking if a Julia type satisfies Rust trait bounds) is not yet implemented. The bounds are stored for:

1. Documentation and introspection
2. Future code generation improvements
3. Error reporting when trait bounds are not satisfied

### Complex Type Inference

Type parameter inference is currently simplified:
- One type parameter maps to one argument (for single-parameter functions)
- Multiple type parameters map to multiple arguments in order

More complex inference (e.g., inferring from return type) is not yet supported.

## API Reference

### Types

- `TraitBound(trait_name, type_params)` - Represents a single trait bound (e.g., `Copy`, `Add<Output = T>`)
- `TypeConstraints(bounds)` - Represents all trait bounds for a type parameter
- `GenericFunctionInfo` - Information about a generic Rust function

### Functions

#### Generic Function Management
- `register_generic_function(func_name, code, type_params, constraints=Dict())` - Register a generic function
- `is_generic_function(func_name)` - Check if a function is generic
- `call_generic_function(func_name, args...)` - Call a generic function (auto-monomorphizes)
- `monomorphize_function(func_name, type_params)` - Explicitly monomorphize a function
- `specialize_generic_code(code, type_params)` - Specialize generic code with type parameters
- `infer_type_parameters(func_name, arg_types)` - Infer type parameters from argument types

#### Trait Bounds Parsing
- `parse_single_trait(trait_str)` - Parse a single trait bound string (e.g., `"Copy"`, `"Add<Output = T>"`)
- `parse_trait_bounds(bounds_str)` - Parse multiple trait bounds (e.g., `"Copy + Clone"`)
- `parse_inline_constraints(type_params_str)` - Parse inline type parameters with constraints
- `parse_where_clause(code)` - Parse a where clause from Rust code
- `parse_generic_function(code, func_name)` - Parse a generic function and extract type parameters with constraints
- `merge_constraints(c1, c2)` - Merge two constraint dictionaries
- `constraints_to_rust_string(constraints)` - Convert constraints back to Rust syntax

### Registries

- `GENERIC_FUNCTION_REGISTRY` - Maps function names to `GenericFunctionInfo`
- `MONOMORPHIZED_FUNCTIONS` - Maps `(function_name, type_params_tuple)` to `FunctionInfo`

## Examples

### Example 1: Simple Generic Function

```@example generics
rust"""
#[no_mangle]
pub extern "C" fn identity<T>(x: T) -> T {
    x
}
"""

# Automatically monomorphized and called
result1 = @rust identity(Int32(42))::Int32  # => 42
result2 = @rust identity(Float64(3.14))::Float64  # => 3.14
println("Int32 result: $result1")
println("Float64 result: $result2")
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
println("Result: $result")
```

### Example 3: Manual Registration and Monomorphization

```@example generics
code = """
#[no_mangle]
pub extern "C" fn multiply<T>(a: T, b: T) -> T {
    a * b
}
"""

register_generic_function("multiply", code, [:T])

# Call with automatic monomorphization
result = call_generic_function("multiply", Int32(5), Int32(6))  # => 30
println("Result: $result")
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

- [Tutorial](tutorial.md) - General tutorial
- [Examples](examples.md) - More examples
- `test/test_generics.jl` - Test suite with examples
