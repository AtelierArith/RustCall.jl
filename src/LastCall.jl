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
include("ruststr.jl")
include("rustmacro.jl")

# Export public API
export @rust, @rust_str
export RustPtr, RustRef, RustResult, RustOption
export rusttype_to_julia, juliatype_to_rust
export unwrap, unwrap_or, is_ok, is_err, is_some, is_none

# Module initialization
function __init__()
    # Check for rustc availability
    if !check_rustc_available()
        @warn "rustc not found in PATH. LastCall.jl requires Rust to be installed."
    end
end

end # module LastCall
