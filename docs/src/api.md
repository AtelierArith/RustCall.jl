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

`@rust_llvm` is deprecated and will be removed in a future release; use `@rust`
instead (see [#265](https://github.com/AtelierArith/RustCall.jl/issues/265)).

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

### Strings in `#[julia]` functions

`#[julia]` free functions may take `String` / `&str` arguments and return
`String` / `&str` (#242). The generated `extern "C"` wrapper — `rustcall_<fn>`,
emitted next to the function, which is itself left untouched (#279) —
receives every
string as a `(ptr, len)` UTF-8 byte pair (no NUL terminator, embedded NULs
allowed), returns `String` as an owned buffer that the Julia wrapper copies
and releases through `<fn>_free_rust_string`, and returns `&str` as a
borrowed view that is copied immediately. The Julia wrapper accepts any
`AbstractString` and returns a `String`; this works for inline `rust\"\"\"`
blocks and for `@rust_crate` alike. `String` inside `Result` / `Option` is
not supported yet.

```julia
rust\"\"\"
#[julia]
pub fn shout(input: String) -> String { input.to_uppercase() }
\"\"\"
shout("hello")  # "HELLO"
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

## LLVM Optimization (deprecated)

The LLVM IR integration path is deprecated ([#265](https://github.com/AtelierArith/RustCall.jl/issues/265)). Every function in
this section and the next, together with `compile_rust_to_llvm_ir` and
`load_llvm_ir` above, emits a deprecation warning and will be removed in a future
release.

```@docs
RustCall.OptimizationConfig
RustCall.optimize_module!
RustCall.optimize_for_speed!
RustCall.optimize_for_size!
```

## LLVM Function Registration (deprecated)

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
RustCall.infer_type_parameters
RustCall.julia_type_to_rust_string
```

## FFI Manifest

Julia never parses Rust source. Signatures, struct layouts and generic
parameters come from the FFI manifest produced by the `rustcall-extract` CLI
(`deps/rustcall_extract`), which shares its `syn`-based core
(`deps/rustcall_core`) with the `juliacall_macros` proc-macro.

Items disabled by `#[cfg(...)]` are dropped from manifests and expanded
sources: the extractor evaluates the predicates against `rustc --print cfg`
(passed as `--cfg-file`). Direct `rustc` builds query it with the real
compilation flags (`cfg = :strict`); Cargo projects RustCall generates itself
(`// cargo-deps:` blocks) evaluate the same way against Cargo's effective
configuration, obtained from a probe crate (`cfg = :cargo`). Only an external
crate (`@rust_crate`), whose features and build script RustCall does not
control, decides target predicates alone (`cfg = :lenient`, `--cfg-lenient`).
The predicate of every reported item is recorded in its `cfg` field.

```@docs
RustCall.extract_manifest
RustCall.expand_inline
RustCall.manifest_function_signatures
RustCall.manifest_struct_infos
RustCall.specialize_generic
RustCall.extractor_path
RustCall.toolchain_fingerprint
RustCall.ExtractorError
RustCall.MANIFEST_SCHEMA_VERSION
```

## Generic Constraints

```@docs
RustCall.TraitBound
RustCall.TypeConstraints
RustCall.GenericFunctionInfo
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

The explicit-binding runtime contract is:

- `@rust_crate` and `RustCall.load_crate_bindings` return a `RustCall.CrateBindings` value.
- Property access preserves non-function bindings such as types and constants.
- Callable exported functions remain proxy-backed so calls stay world-age-safe.

```@docs
RustCall.CrateBindings
RustCall.CrateInfo
RustCall.CrateBindingOptions
RustCall.load_crate_bindings
RustCall.scan_crate
RustCall.generate_bindings
RustCall.write_bindings_to_file
@rust_crate
```

## PyO3 Crates

```@docs
RustCall.scan_report
RustCall.PyO3LinkPlan
RustCall.pyo3_link_plan
RustCall.pyo3_link_rustflags
RustCall.pyo3_dependency_toml
RustCall.python_library_dir
RustCall.pyo3_skip_explanation
RustCall.PYO3_SKIP_REASONS
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

### The FFI type contract

Rust-to-Julia type mapping lives in one place, `src/ffi_contract.jl`, and is
documented — with the generated supported-type matrix — under
[The FFI Type Contract](type_contract.md).

```@docs
RustCall.FFI_ABI_KINDS
RustCall.FFI_OWNERSHIP_KINDS
RustCall.FFIType
RustCall.FFIContract
RustCall.FFI_TYPE_TABLE
RustCall.FFI_STRICT
RustCall.ffi_lookup
RustCall.ffi_argument_contract
RustCall.ffi_return_contract
RustCall.ffi_return_symbol_or_throw
RustCall.ffi_describe
```

`rusttype_to_julia` is a thin shim over that table. Two spellings changed
meaning when it stopped having a table of its own (#276): `"str"` is `RustStr`
rather than `Cstring`, and `"*const u8"` is `Ptr{UInt8}` rather than `Cstring`.
A Rust `str` is an unsized UTF-8 slice reached through a `(ptr, len)` fat
pointer and a `*const u8` is a plain byte pointer; neither is a NUL-terminated C
string.

The reverse direction still has a table of its own, since a Julia type does not
determine a Rust spelling:

```julia
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
        :CURRENT_LIB, :JULIA_TO_RUST_TYPE_MAP
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
        :FFIType, :FFIContract,
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
        :monomorphize_function, :specialize_generic, :infer_type_parameters, :julia_type_to_rust_string,
        :extract_manifest, :expand_inline, :manifest_function_signatures, :manifest_struct_infos,
        :extractor_path, :toolchain_fingerprint, :ExtractorError,
        :parse_dependencies_from_code, :has_dependencies,
        :create_cargo_project, :build_cargo_project,
        :clear_cargo_cache, :get_cargo_cache_size,
        :julia_type_to_llvm_ir_string,
        :TraitBound, :TypeConstraints, :GenericFunctionInfo,
        :CrateBindings, :CrateInfo, :CrateBindingOptions,
        :load_crate_bindings, :scan_crate, :generate_bindings, :write_bindings_to_file,
        :scan_report, :PyO3LinkPlan, :pyo3_link_plan, :pyo3_link_rustflags,
        :python_library_dir, :pyo3_skip_explanation,
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

## Loading and lifetime

Every compiled artifact is opened, registered and unloaded through one path
(`src/loadpolicy.jl`). The user-facing halves of it:

- `RustCall.unload_library(name; close = false)` /
  `RustCall.unload_all_libraries(; close = false)` — drop everything the
  registries record about a library. The image stays mapped by default, because
  a call may still be inside it; `close = true` reclaims it, and is the caller
  stating that none is.
- `RustCall.retired_handles()` / `RustCall.retired_handles(name)` — the images
  that have left the registry and are still mapped.
- `RustCall.list_loaded_libraries()` — the registered library names, which now
  include `@rust_crate` libraries.
- `RustCall.RustPanicError` — a Rust `panic!` caught at the FFI boundary.
- `RustCall.finalizer_failure_count()` — how many Rust destructors raised while
  being called from a finalizer (non-zero means objects leaked).

See [Panics, Visibility and Lifetime](panics.md) for the semantics these guarantee.
