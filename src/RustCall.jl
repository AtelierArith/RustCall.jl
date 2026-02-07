"""
    RustCall.jl

A Foreign Function Interface (FFI) package for calling Rust code from Julia
using LLVM IR integration.

# Exported Macros
- `@rust`: Call a registered Rust function
- `@rust_str`: Compile and register Rust code (rust"" string literal)

# Example
```julia
using RustCall

# Define Rust code
rust\"\"\"
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}
\"\"\"

# Call the function
result = @rust add(10i32, 20i32)
```
"""
module RustCall

using LLVM
using Libdl

# Thread-safety lock for global registries and LLVM operations
const REGISTRY_LOCK = ReentrantLock()

# Include submodules in order of dependency
include("types.jl")
include("typetranslation.jl")
include("compiler.jl")
include("llvmintegration.jl")
include("codegen.jl")
include("exceptions.jl")
include("cache.jl")
include("memory.jl")

# Phase 3: External library integration
include("dependencies.jl")
include("dependency_resolution.jl")
include("cargoproject.jl")
include("cargobuild.jl")

include("ruststr.jl")
include("rustmacro.jl")

# Phase 2: LLVM IR integration
include("llvmoptimization.jl")
include("llvmcodegen.jl")

# Phase 2: Generics support
include("generics.jl")

# Phase 4: Object mapping support
include("structs.jl")

# Phase 5: #[julia] attribute support
include("julia_functions.jl")

# Phase 6: External crate bindings (Maturin-like feature)
include("crate_bindings.jl")

# Hot reload support
include("hot_reload.jl")

# Export public API
export @rust, @rust_str, @irust, @irust_str
export RustPtr, RustRef, RustResult, RustOption
export RustString, RustStr
export rusttype_to_julia, juliatype_to_rust
export unwrap, unwrap_or, is_ok, is_err, is_some, is_none
export rust_string_to_julia, rust_str_to_julia
export julia_string_to_rust, julia_string_to_cstring, cstring_to_julia_string
export RustError, CompilationError, RuntimeError, result_to_exception, unwrap_or_throw
export CargoBuildError, DependencyResolutionError  # Phase 3
export format_rustc_error, suggest_fix_for_error
# Export internal functions for testing
export _extract_error_line_numbers, _extract_suggestions, _extract_error_line_numbers_impl

# Phase 2 exports
export @rust_llvm
export OptimizationConfig, optimize_module!, optimize_for_speed!, optimize_for_size!
export RustFunctionInfo, compile_and_register_rust_function
export julia_type_to_llvm_ir_string

# Compiler configuration and error recovery
export RustCompiler, compile_with_recovery
export check_rustc_available, get_rustc_version, get_default_compiler, set_default_compiler, compile_rust_to_shared_lib
export wrap_rust_code, compile_rust_to_llvm_ir, load_llvm_ir

# Extended ownership types (Phase 2)
export RustBox, RustRc, RustArc, RustVec, RustSlice
export drop!, is_dropped, is_valid
export clone  # For RustRc and RustArc
export is_rust_helpers_available  # Check if Rust helpers library is loaded
export get_rust_helpers_lib, get_rust_helpers_lib_path  # For testing and advanced usage

# RustVec operations (Phase 2)
export create_rust_vec, rust_vec_get, rust_vec_set!, copy_to_julia!, to_julia_vector

# Caching (Phase 2)
export clear_cache, get_cache_size, list_cached_libraries, cleanup_old_cache

# Generics support (Phase 2)
export register_generic_function, call_generic_function, is_generic_function
export monomorphize_function, specialize_generic_code, infer_type_parameters
export GENERIC_FUNCTION_REGISTRY, MONOMORPHIZED_FUNCTIONS  # For testing

# Trait bounds parsing (Phase 2 - Enhanced)
export TraitBound, TypeConstraints, GenericFunctionInfo
export parse_trait_bounds, parse_single_trait, parse_where_clause
export parse_inline_constraints, parse_generic_function
export constraints_to_rust_string, merge_constraints

# Phase 3: External library integration
export DependencySpec, parse_dependencies_from_code, has_dependencies
export CargoProject, create_cargo_project, build_cargo_project
export clear_cargo_cache, get_cargo_cache_size

# Phase 6: External crate bindings (Maturin-like feature)
export CrateInfo, CrateBindingOptions
export scan_crate, generate_bindings, @rust_crate
export write_bindings_to_file

# Hot reload support
export enable_hot_reload, disable_hot_reload, disable_all_hot_reload
export is_hot_reload_enabled, list_hot_reload_crates
export trigger_reload, set_hot_reload_global
export enable_hot_reload_for_crate
export HotReloadState

# Module initialization
function __init__()
    # Check for rustc availability
    if !check_rustc_available()
        @warn "rustc not found in PATH. RustCall.jl requires Rust to be installed."
    end

    # Try to load Rust helpers library
    if !try_load_rust_helpers()
        # Only show warning once, not on every test
        if !haskey(ENV, "RUSTCALL_SUPPRESS_HELPERS_WARNING")
            @warn """
            Rust helpers library not found. Ownership types (Box, Rc, Arc) will not work until the library is built.

            To build the library, run:
                using Pkg; Pkg.build("RustCall")
            Or from command line:
                julia --project -e 'using Pkg; Pkg.build("RustCall")'

            To suppress this warning, set:
                ENV["RUSTCALL_SUPPRESS_HELPERS_WARNING"] = "1"
            """
        end
    else
        @debug "Rust helpers library loaded successfully."
    end
end

end # module RustCall
