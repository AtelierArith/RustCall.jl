# API Reference

This page provides the API documentation for LastCall.jl.

## Macros

```@docs
@rust
@rust_str
@irust
@irust_str
@rust_llvm
```

## Types

### Result and Option Types

```@docs
RustResult
RustOption
```

### Ownership Types

```@docs
RustBox
RustRc
RustArc
RustVec
RustSlice
```

### Pointer Types

```@docs
RustPtr
RustRef
```

### String Types

```@docs
RustString
RustStr
```

### Error Types

```@docs
RustError
CompilationError
RuntimeError
```

## Type Conversion Functions

```@docs
rusttype_to_julia
juliatype_to_rust
```

## Result/Option Operations

```@docs
unwrap
unwrap_or
is_ok
is_err
is_some
is_none
result_to_exception
unwrap_or_throw
```

## String Conversion Functions

```@docs
rust_string_to_julia
rust_str_to_julia
julia_string_to_rust
julia_string_to_cstring
cstring_to_julia_string
```

## Error Handling

```@docs
format_rustc_error
```

## Compiler Functions

```@docs
RustCompiler
compile_with_recovery
check_rustc_available
get_rustc_version
get_default_compiler
set_default_compiler
compile_rust_to_shared_lib
```

## Ownership Type Operations

```@docs
drop!
is_dropped
is_valid
clone
is_rust_helpers_available
```

## RustVec Operations

```@docs
create_rust_vec
rust_vec_get
rust_vec_set!
copy_to_julia!
to_julia_vector
```

## Cache Management

```@docs
clear_cache
get_cache_size
list_cached_libraries
cleanup_old_cache
```

## LLVM Optimization

```@docs
OptimizationConfig
optimize_module!
optimize_for_speed!
optimize_for_size!
```

## Function Registration (Phase 2)

```@docs
RustFunctionInfo
compile_and_register_rust_function
```

## Generics Support (Phase 2)

```@docs
register_generic_function
call_generic_function
is_generic_function
monomorphize_function
specialize_generic_code
infer_type_parameters
```

## Internal Constants

### Type Mapping

The following constant defines the mapping between Rust types and Julia types:

```julia
const RUST_JULIA_TYPE_MAP = Dict(
    "i8" => Int8,
    "i16" => Int16,
    "i32" => Int32,
    "i64" => Int64,
    "u8" => UInt8,
    "u16" => UInt16,
    "u32" => UInt32,
    "u64" => UInt64,
    "f32" => Float32,
    "f64" => Float64,
    "bool" => Bool,
    "usize" => Csize_t,
    "isize" => Cssize_t,
    "()" => Cvoid,
)
```

### Registries

```@docs
GENERIC_FUNCTION_REGISTRY
MONOMORPHIZED_FUNCTIONS
```

## Internal Functions

The following functions are internal implementation details and are not part of the public API:

```@autodocs
Modules = [LastCall]
Private = true
```
