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
CargoBuildError
DependencyResolutionError
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
suggest_fix_for_error
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
compile_rust_to_llvm_ir
load_llvm_ir
wrap_rust_code
```

## Ownership Type Operations

```@docs
drop!
is_dropped
is_valid
clone
is_rust_helpers_available
get_rust_helpers_lib
get_rust_helpers_lib_path
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

## External Library Integration (Phase 3)

### Dependency Management

```@docs
DependencySpec
parse_dependencies_from_code
has_dependencies
```

### Cargo Project Management

```@docs
CargoProject
create_cargo_project
build_cargo_project
clear_cargo_cache
get_cargo_cache_size
```

## Type System

### Type Mapping Constants

The following constants define the mapping between Rust types and Julia types:

```julia
# Rust to Julia type mapping
const RUST_TO_JULIA_TYPE_MAP = Dict{Symbol, Type}(
    :i8 => Int8,
    :i16 => Int16,
    :i32 => Int32,
    :i64 => Int64,
    :u8 => UInt8,
    :u16 => UInt16,
    :u32 => UInt32,
    :u64 => UInt64,
    :f32 => Float32,
    :f64 => Float64,
    :bool => Bool,
    :usize => UInt,
    :isize => Int,
    Symbol("()") => Cvoid,
)

# Julia to Rust type mapping
const JULIA_TO_RUST_TYPE_MAP = Dict{Type, String}(
    Int8 => "i8",
    Int16 => "i16",
    Int32 => "i32",
    Int64 => "i64",
    UInt8 => "u8",
    UInt16 => "u16",
    UInt32 => "u32",
    UInt64 => "u64",
    Float32 => "f32",
    Float64 => "f64",
    Bool => "bool",
    Cvoid => "()",
)
```

### Internal Registries

```@docs
GENERIC_FUNCTION_REGISTRY
MONOMORPHIZED_FUNCTIONS
RUST_LIBRARIES
RUST_MODULE_REGISTRY
FUNCTION_REGISTRY
IRUST_FUNCTIONS
```

## Utility Functions

### Testing and Debugging

These functions are exported for testing purposes but are considered internal.
They are wrappers around internal implementation functions.

## Internal Functions

The following functions are internal implementation details and are not part of the public API.
They are documented here for completeness but should not be used directly by users.

```@autodocs
Modules = [LastCall]
Private = true
Filter = t -> begin
    # Exclude items already documented in @docs blocks above
    excluded_names = [
        :RustResult, :RustOption, :RustBox, :RustRc, :RustArc, :RustVec, :RustSlice,
        :RustPtr, :RustRef, :RustString, :RustStr,
        :RustError, :CompilationError, :RuntimeError, :CargoBuildError, :DependencyResolutionError,
        :RustCompiler, :OptimizationConfig, :RustFunctionInfo,
        :DependencySpec, :CargoProject,
        :GENERIC_FUNCTION_REGISTRY, :MONOMORPHIZED_FUNCTIONS,
        # Exclude public functions already documented
        :unwrap, :unwrap_or, :is_ok, :is_err, :is_some, :is_none,
        :result_to_exception, :unwrap_or_throw,
        :rusttype_to_julia, :juliatype_to_rust,
        :rust_string_to_julia, :rust_str_to_julia,
        :julia_string_to_rust, :julia_string_to_cstring, :cstring_to_julia_string,
        :format_rustc_error, :suggest_fix_for_error,
        :compile_with_recovery, :check_rustc_available, :get_rustc_version,
        :get_default_compiler, :set_default_compiler, :compile_rust_to_shared_lib,
        :compile_rust_to_llvm_ir, :load_llvm_ir, :wrap_rust_code,
        :drop!, :is_dropped, :is_valid, :clone, :is_rust_helpers_available,
        :get_rust_helpers_lib, :get_rust_helpers_lib_path,
        :create_rust_vec, :rust_vec_get, :rust_vec_set!, :copy_to_julia!, :to_julia_vector,
        :clear_cache, :get_cache_size, :list_cached_libraries, :cleanup_old_cache,
        :optimize_module!, :optimize_for_speed!, :optimize_for_size!,
        :compile_and_register_rust_function,
        :register_generic_function, :call_generic_function, :is_generic_function,
        :monomorphize_function, :specialize_generic_code, :infer_type_parameters,
        :parse_dependencies_from_code, :has_dependencies,
        :create_cargo_project, :build_cargo_project,
        :clear_cargo_cache, :get_cargo_cache_size,
    ]
    # Get the binding name
    name = try
        nameof(t)
    catch
        return true
    end
    # Exclude if in excluded list
    return !(name in excluded_names)
end
```
