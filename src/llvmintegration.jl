# LLVM.jl integration for RustCall.jl

using LLVM

"""
    RustModule

A wrapper around an LLVM module containing compiled Rust code.
"""
mutable struct RustModule
    ctx::LLVM.Context
    mod::LLVM.Module
    source_code::String
    functions::Dict{String, LLVM.Function}
    ir_file::String
end

# Registry of loaded Rust modules
const RUST_MODULES = Dict{UInt64, RustModule}()

# Cache for compiled functions
const FUNCTION_CACHE = Dict{String, Ptr{Cvoid}}()

"""
    load_llvm_ir(ir_file::String) -> RustModule

Load an LLVM IR file and create a RustModule.
"""
function load_llvm_ir(ir_file::String; source_code::String = "")
    # Read the IR file
    ir_content = read(ir_file, String)

    # Get or create the LLVM context
    # Note: LLVM.jl 9.x uses module-level contexts
    ctx = LLVM.Context()

    # Parse the IR using LLVM.jl's API
    # In LLVM.jl 9.x, parse doesn't take a ctx argument for string parsing
    mod = try
        parse(LLVM.Module, ir_content)
    catch e
        try
            dispose(ctx)
        catch
        end
        error("Failed to parse LLVM IR: $e")
    end

    # Extract functions
    functions = Dict{String, LLVM.Function}()
    for fn in LLVM.functions(mod)
        fn_name = LLVM.name(fn)
        # Skip internal/intrinsic functions
        if !isempty(fn_name) && !startswith(fn_name, "llvm.")
            functions[fn_name] = fn
        end
    end

    rust_mod = RustModule(ctx, mod, source_code, functions, ir_file)

    # Register in the global registry
    mod_hash = hash(ir_content)
    RUST_MODULES[mod_hash] = rust_mod

    return rust_mod
end

"""
    get_function(mod::RustModule, name::String) -> Union{LLVM.Function, Nothing}

Get a function by name from the RustModule.
"""
function get_function(mod::RustModule, name::String)
    return get(mod.functions, name, nothing)
end

"""
    list_functions(mod::RustModule) -> Vector{String}

List all exported function names in the module.
"""
function list_functions(mod::RustModule)
    return collect(keys(mod.functions))
end

"""
    get_function_signature(fn::LLVM.Function) -> Tuple{Type, Vector{Type}}

Get the Julia return type and argument types for an LLVM function.
"""
function get_function_signature(fn::LLVM.Function)
    fn_type = LLVM.function_type(fn)

    # Get return type
    ret_llvm_type = LLVM.return_type(fn_type)
    ret_julia_type = llvm_type_to_julia(ret_llvm_type)

    # Get argument types
    arg_julia_types = Type[]
    for param_type in LLVM.parameters(fn_type)
        push!(arg_julia_types, llvm_type_to_julia(param_type))
    end

    return (ret_julia_type, arg_julia_types)
end

"""
    llvm_type_to_julia(llvm_type::LLVM.LLVMType) -> Type

Convert an LLVM type to the corresponding Julia type.
Uses LLVM.jl 9.x API which uses concrete types for different LLVM types.
"""
function llvm_type_to_julia(llvm_type::LLVM.LLVMType)
    # Check type using isa (LLVM.jl 9.x uses concrete types)
    if llvm_type isa LLVM.VoidType
        return Cvoid
    elseif llvm_type isa LLVM.IntegerType
        width = LLVM.width(llvm_type)
        if width == 1
            return Bool
        elseif width == 8
            return Int8
        elseif width == 16
            return Int16
        elseif width == 32
            return Int32
        elseif width == 64
            return Int64
        elseif width == 128
            return Int128
        else
            error("Unsupported integer width: $width")
        end
    elseif llvm_type isa LLVM.LLVMFloat
        return Float32
    elseif llvm_type isa LLVM.LLVMDouble
        return Float64
    elseif llvm_type isa LLVM.PointerType
        return Ptr{Cvoid}
    elseif llvm_type isa LLVM.StructType
        # For structs, return a generic pointer for now
        return Ptr{Cvoid}
    elseif llvm_type isa LLVM.ArrayType
        return Ptr{Cvoid}
    else
        # Fallback: try to determine from type name
        type_str = string(typeof(llvm_type))
        error("Unsupported LLVM type: $type_str")
    end
end

"""
    julia_type_to_llvm(julia_type::Type) -> LLVM.LLVMType

Convert a Julia type to the corresponding LLVM type.
Note: Must be called within an active LLVM context (use LLVM.Context() do ... end).
"""
function julia_type_to_llvm(julia_type::Type)
    if julia_type == Cvoid || julia_type == Nothing
        return LLVM.VoidType()
    elseif julia_type == Bool
        return LLVM.IntType(1)
    elseif julia_type == Int8 || julia_type == UInt8
        return LLVM.IntType(8)
    elseif julia_type == Int16 || julia_type == UInt16
        return LLVM.IntType(16)
    elseif julia_type == Int32 || julia_type == UInt32
        return LLVM.IntType(32)
    elseif julia_type == Int64 || julia_type == UInt64
        return LLVM.IntType(64)
    elseif julia_type == Int128 || julia_type == UInt128
        return LLVM.IntType(128)
    elseif julia_type == Float32
        return LLVM.FloatType()
    elseif julia_type == Float64
        return LLVM.DoubleType()
    elseif julia_type <: Ptr
        return LLVM.PointerType(LLVM.IntType(8))
    else
        error("Unsupported Julia type for LLVM: $julia_type")
    end
end

# Keep the old signature for backward compatibility (ignore ctx)
julia_type_to_llvm(ctx::LLVM.Context, julia_type::Type) = julia_type_to_llvm(julia_type)

"""
    dispose_module(mod::RustModule)

Dispose of the LLVM resources associated with a RustModule.
"""
function dispose_module(mod::RustModule)
    # Remove from cache
    for (k, v) in RUST_MODULES
        if v === mod
            delete!(RUST_MODULES, k)
            break
        end
    end

    # Clean up temporary files
    if isfile(mod.ir_file)
        try
            rm(dirname(mod.ir_file), recursive=true, force=true)
        catch
        end
    end

    # Dispose LLVM resources
    dispose(mod.mod)
    dispose(mod.ctx)
end

"""
    get_or_compile_function(mod::RustModule, name::String) -> Ptr{Cvoid}

Get a compiled function pointer, compiling if necessary using Julia's JIT.

# Arguments
- `mod::RustModule`: The Rust module containing the function
- `name::String`: Name of the function to compile

# Returns
- `Ptr{Cvoid}`: Function pointer to the compiled function

# Note
This function is a placeholder for future LLVM JIT compilation support.
Currently, it raises an error indicating that direct LLVM JIT compilation
is not yet implemented. Use the shared library approach instead.

# Example
```julia
mod = load_llvm_ir("path/to/file.ll")
# Note: This will raise an error until JIT compilation is implemented
# func_ptr = get_or_compile_function(mod, "my_function")
```
"""
function get_or_compile_function(mod::RustModule, name::String)
    cache_key = "$(objectid(mod))_$name"

    if haskey(FUNCTION_CACHE, cache_key)
        return FUNCTION_CACHE[cache_key]
    end

    fn = get_function(mod, name)
    if fn === nothing
        error("Function '$name' not found in module")
    end

    # For now, we'll use the shared library approach
    # LLVM IR -> llvmcall integration requires more work
    # This is a placeholder for future LLVM JIT compilation
    error("Direct LLVM JIT compilation not yet implemented. Use shared library approach.")
end
