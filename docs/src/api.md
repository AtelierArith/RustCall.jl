# API Reference

This page provides the API documentation for RustCall.jl.

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
RustCall.RustResult
RustCall.RustOption
```

### Ownership Types

```@docs
RustCall.RustBox
RustCall.RustRc
RustCall.RustArc
RustCall.RustVec
RustCall.RustSlice
```

### Pointer Types

```@docs
RustCall.RustPtr
RustCall.RustRef
```

### String Types

```@docs
RustCall.RustString
RustCall.RustStr
```

### Error Types

```@docs
RustCall.RustError
RustCall.CompilationError
RustCall.RuntimeError
RustCall.CargoBuildError
RustCall.DependencyResolutionError
```

## Type Conversion Functions

```@docs
RustCall.rusttype_to_julia
RustCall.juliatype_to_rust
```

## Result/Option Operations

```@docs
RustCall.unwrap
RustCall.unwrap_or
RustCall.is_ok
RustCall.is_err
RustCall.is_some
RustCall.is_none
RustCall.result_to_exception
RustCall.unwrap_or_throw
```

## String Conversion Functions

```@docs
RustCall.rust_string_to_julia
RustCall.rust_str_to_julia
RustCall.julia_string_to_rust
RustCall.julia_string_to_cstring
RustCall.cstring_to_julia_string
```

## Error Handling

```@docs
RustCall.format_rustc_error
RustCall.suggest_fix_for_error
```

## Compiler Functions

```@docs
RustCall.RustCompiler
RustCall.compile_with_recovery
RustCall.check_rustc_available
RustCall.get_rustc_version
RustCall.get_default_compiler
RustCall.set_default_compiler
RustCall.compile_rust_to_shared_lib
RustCall.compile_rust_to_llvm_ir
RustCall.load_llvm_ir
RustCall.wrap_rust_code
```

## Ownership Type Operations

```@docs
RustCall.drop!
RustCall.is_dropped
RustCall.is_valid
RustCall.clone
RustCall.is_rust_helpers_available
RustCall.get_rust_helpers_lib
RustCall.get_rust_helpers_lib_path
```

## RustVec Operations

```@docs
RustCall.create_rust_vec
RustCall.rust_vec_get
RustCall.rust_vec_set!
RustCall.copy_to_julia!
RustCall.to_julia_vector
```

## Cache Management

```@docs
RustCall.clear_cache
RustCall.get_cache_size
RustCall.list_cached_libraries
RustCall.cleanup_old_cache
```

## LLVM Optimization

```@docs
RustCall.OptimizationConfig
RustCall.optimize_module!
RustCall.optimize_for_speed!
RustCall.optimize_for_size!
```

## LLVM Function Registration

```@docs
RustCall.RustFunctionInfo
RustCall.compile_and_register_rust_function
RustCall.julia_type_to_llvm_ir_string
```

## Generics Support

```@docs
RustCall.register_generic_function
RustCall.call_generic_function
RustCall.is_generic_function
RustCall.monomorphize_function
RustCall.specialize_generic_code
RustCall.infer_type_parameters
```

## Generic Constraints

```@docs
RustCall.TraitBound
RustCall.TypeConstraints
RustCall.GenericFunctionInfo
RustCall.parse_trait_bounds
RustCall.parse_single_trait
RustCall.parse_where_clause
RustCall.parse_inline_constraints
RustCall.parse_generic_function
RustCall.constraints_to_rust_string
RustCall.merge_constraints
```

## External Library Integration

### Dependency Management

```@docs
RustCall.DependencySpec
RustCall.parse_dependencies_from_code
RustCall.has_dependencies
```

### Cargo Project Management

```@docs
RustCall.CargoProject
RustCall.create_cargo_project
RustCall.build_cargo_project
RustCall.clear_cargo_cache
RustCall.get_cargo_cache_size
```

## Crate Bindings

```@docs
RustCall.CrateInfo
RustCall.CrateBindingOptions
RustCall.scan_crate
RustCall.generate_bindings
RustCall.write_bindings_to_file
@rust_crate
```

## Hot Reload

```@docs
RustCall.HotReloadState
RustCall.enable_hot_reload
RustCall.disable_hot_reload
RustCall.disable_all_hot_reload
RustCall.is_hot_reload_enabled
RustCall.list_hot_reload_crates
RustCall.trigger_reload
RustCall.set_hot_reload_global
RustCall.enable_hot_reload_for_crate
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

The following registries are used internally by RustCall.jl:

```@docs
RustCall.GENERIC_FUNCTION_REGISTRY
RustCall.MONOMORPHIZED_FUNCTIONS
```

The following registries and constants are not exported but are available for advanced usage.

Note: These constants are internal implementation details. They are documented here for completeness but should not be accessed directly by users.

```@autodocs
Modules = [RustCall]
Private = true
Filter = t -> begin
    name = try
        nameof(t)
    catch
        return false
    end
    target_names = [
        :RUST_LIBRARIES, :RUST_MODULE_REGISTRY, :FUNCTION_REGISTRY, :IRUST_FUNCTIONS,
        :CURRENT_LIB, :RUST_TO_JULIA_TYPE_MAP, :JULIA_TO_RUST_TYPE_MAP
    ]
    return name in target_names
end
```

## Utility Functions

### Testing and Debugging

These functions are exported for testing purposes but are considered internal.
They are wrappers around internal implementation functions.

## Internal Functions and Types

The following functions and types are internal implementation details and are not part of the public API.
They are documented here for completeness but should not be used directly by users.

```@autodocs
Modules = [RustCall]
Filter = t -> begin
    # Exclude items already documented in @docs blocks above
    excluded_names = [
        # Types (documented in @docs blocks)
        :RustResult, :RustOption, :RustBox, :RustRc, :RustArc, :RustVec, :RustSlice,
        :RustPtr, :RustRef, :RustString, :RustStr,
        :RustError, :CompilationError, :RuntimeError, :CargoBuildError, :DependencyResolutionError,
        :RustCompiler, :OptimizationConfig, :RustFunctionInfo,
        :DependencySpec, :CargoProject,
        # Constants/Registries (documented in @docs blocks)
        :GENERIC_FUNCTION_REGISTRY, :MONOMORPHIZED_FUNCTIONS,
        :RUST_LIBRARIES, :RUST_MODULE_REGISTRY, :FUNCTION_REGISTRY, :IRUST_FUNCTIONS,
        # Public functions already documented
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
        :julia_type_to_llvm_ir_string,
        :TraitBound, :TypeConstraints, :GenericFunctionInfo,
        :parse_trait_bounds, :parse_single_trait, :parse_where_clause,
        :parse_inline_constraints, :parse_generic_function,
        :constraints_to_rust_string, :merge_constraints,
        :CrateInfo, :CrateBindingOptions,
        :scan_crate, :generate_bindings, :write_bindings_to_file,
        :HotReloadState,
        :enable_hot_reload, :disable_hot_reload, :disable_all_hot_reload,
        :is_hot_reload_enabled, :list_hot_reload_crates,
        :trigger_reload, :set_hot_reload_global, :enable_hot_reload_for_crate,
        # Macros (documented separately)
        Symbol("@rust"), Symbol("@rust_str"), Symbol("@irust"), Symbol("@irust_str"),
        Symbol("@rust_llvm"), Symbol("@rust_crate"),
    ]
    # Get the binding name
    name = try
        nameof(t)
    catch
        return false
    end
    # Include all documented items that are not in the excluded list
    # This includes internal functions, types, and Base method extensions
    return !(name in excluded_names)
end
```
