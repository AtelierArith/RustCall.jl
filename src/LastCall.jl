"""
    LastCall.jl

A Foreign Function Interface (FFI) package for calling Rust code from Julia
using LLVM IR integration.

# Exported Macros
- `@rust`: Call a registered Rust function
- `@rust_str`: Compile and register Rust code (rust"" string literal)

# Example
```julia
using LastCall

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
module LastCall

using LLVM
using Libdl

# Include submodules in order of dependency
include("types.jl")
include("typetranslation.jl")
include("compiler.jl")
include("llvmintegration.jl")
include("codegen.jl")
include("exceptions.jl")
include("ruststr.jl")
include("rustmacro.jl")

# Phase 2: LLVM IR integration
include("llvmoptimization.jl")
include("llvmcodegen.jl")

# Export public API
export @rust, @rust_str, @irust, @irust_str
export RustPtr, RustRef, RustResult, RustOption
export RustString, RustStr
export rusttype_to_julia, juliatype_to_rust
export unwrap, unwrap_or, is_ok, is_err, is_some, is_none
export rust_string_to_julia, rust_str_to_julia
export julia_string_to_rust, julia_string_to_cstring, cstring_to_julia_string
export RustError, result_to_exception, unwrap_or_throw

# Phase 2 exports
export @rust_llvm
export OptimizationConfig, optimize_module!, optimize_for_speed!, optimize_for_size!
export RustFunctionInfo, compile_and_register_rust_function

# Extended ownership types (Phase 2)
export RustBox, RustRc, RustArc, RustVec, RustSlice
export drop!, is_dropped, is_valid

# Module initialization
function __init__()
    # Check for rustc availability
    if !check_rustc_available()
        @warn "rustc not found in PATH. LastCall.jl requires Rust to be installed."
    end
end

end # module LastCall
