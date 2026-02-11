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

# Shared library handle registry for crate bindings (used by hot reload)
# Maps canonical lib_path → Ptr{Cvoid} so that old module references
# can find the new library handle after hot reload.
const CRATE_LIB_HANDLES = Dict{String, Ptr{Cvoid}}()

"""
    _normalize_crate_lib_path(path::String) -> String

Return a canonical key for CRATE_LIB_HANDLES so lookups match across
path variants (e.g. Windows short vs long path, or different separators).
"""
function _normalize_crate_lib_path(path::String)
    p = normpath(path)
    Sys.iswindows() && (p = lowercase(p))
    return p
end

# Phase 6: External crate bindings (Maturin-like feature)
include("crate_bindings.jl")

# Hot reload support
include("hot_reload.jl")

# Export public API — only macros/string literals are exported.
# All other identifiers are accessible via RustCall.XXX or import RustCall: XXX.
export @rust, @rust_str, @irust, @irust_str
export @rust_llvm
export @rust_crate

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
