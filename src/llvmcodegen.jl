# LLVM IR code generation using llvmcall
# Phase 2: Direct LLVM IR integration

using LLVM

"""
    LLVMCodeGenerator

Configuration for LLVM-based code generation.
"""
struct LLVMCodeGenerator
    optimization_level::Int
    inline_threshold::Int
    enable_vectorization::Bool
end

"""
    LLVMCodeGenerator(; kwargs...)

Create an LLVMCodeGenerator with specified settings.
"""
function LLVMCodeGenerator(;
    optimization_level::Int = 2,
    inline_threshold::Int = 225,
    enable_vectorization::Bool = true
)
    LLVMCodeGenerator(optimization_level, inline_threshold, enable_vectorization)
end

# Global code generator instance
const DEFAULT_CODEGEN = Ref{LLVMCodeGenerator}()

function get_default_codegen()
    if !isassigned(DEFAULT_CODEGEN)
        DEFAULT_CODEGEN[] = LLVMCodeGenerator()
    end
    return DEFAULT_CODEGEN[]
end

"""
    RustFunctionInfo

Information about a compiled Rust function for llvmcall.
"""
struct RustFunctionInfo
    name::String
    return_type::Type
    arg_types::Vector{Type}
    llvm_ir::String
    func_ptr::Union{Ptr{Cvoid}, Nothing}
end

# Registry for compiled Rust functions with LLVM IR
const LLVM_FUNCTION_REGISTRY = Dict{String, RustFunctionInfo}()

"""
    extract_function_ir(mod::RustModule, func_name::String) -> String

Extract the LLVM IR for a specific function from a RustModule.
"""
function extract_function_ir(mod::RustModule, func_name::String)
    fn = get_function(mod, func_name)
    if fn === nothing
        error("Function '$func_name' not found in module")
    end

    # Get the IR string representation
    ir_buffer = IOBuffer()
    print(ir_buffer, fn)
    return String(take!(ir_buffer))
end

"""
    generate_llvmcall_ir(func_name::String, ret_type::Type, arg_types::Vector{Type}) -> String

Generate LLVM IR string suitable for llvmcall based on function signature.
This creates a simple wrapper that calls the actual function.
"""
function generate_llvmcall_ir(func_name::String, ret_type::Type, arg_types::Vector{Type})
    # Map Julia types to LLVM IR types
    llvm_ret = julia_type_to_llvm_ir_string(ret_type)
    llvm_args = [julia_type_to_llvm_ir_string(t) for t in arg_types]

    # Build argument list
    arg_list = join(["$llvm_args[$i] %$(i-1)" for i in 1:length(arg_types)], ", ")
    arg_refs = join(["%$(i-1)" for i in 1:length(arg_types)], ", ")

    if ret_type == Cvoid || ret_type == Nothing
        return """
        call void @$func_name($arg_list)
        ret void
        """
    else
        return """
        %result = call $llvm_ret @$func_name($arg_list)
        ret $llvm_ret %result
        """
    end
end

"""
    julia_type_to_llvm_ir_string(t::Type) -> String

Convert a Julia type to its LLVM IR string representation.
"""
function julia_type_to_llvm_ir_string(t::Type)
    if t == Bool
        return "i1"
    elseif t == Int8 || t == UInt8
        return "i8"
    elseif t == Int16 || t == UInt16
        return "i16"
    elseif t == Int32 || t == UInt32
        return "i32"
    elseif t == Int64 || t == UInt64
        return "i64"
    elseif t == Int128 || t == UInt128
        return "i128"
    elseif t == Float32
        return "float"
    elseif t == Float64
        return "double"
    elseif t == Cvoid || t == Nothing
        return "void"
    elseif t <: Ptr
        return "ptr"
    else
        error("Unsupported Julia type for LLVM IR: $t")
    end
end

"""
    build_llvmcall_expr(func_ptr::Ptr{Cvoid}, ret_type::Type, arg_types::Tuple, args::Tuple)

Build an expression that uses llvmcall to invoke a function.
This is used internally by @generated functions.
"""
function build_llvmcall_expr(func_ptr::Ptr{Cvoid}, ret_type::Type, arg_types, args)
    # For pointer-form llvmcall, we pass the function pointer directly
    return Expr(:call, Core.Intrinsics.llvmcall,
        func_ptr,
        ret_type,
        arg_types,
        args...)
end

"""
    compile_and_register_rust_function(code::String, func_name::String)

Compile Rust code and register the function for llvmcall usage.
"""
function compile_and_register_rust_function(code::String, func_name::String)
    # Check if already registered
    if haskey(LLVM_FUNCTION_REGISTRY, func_name)
        return LLVM_FUNCTION_REGISTRY[func_name]
    end

    # Wrap and compile
    wrapped_code = wrap_rust_code(code)
    compiler = get_default_compiler()

    # Compile to LLVM IR for analysis
    ir_path = compile_rust_to_llvm_ir(wrapped_code; compiler=compiler)
    rust_mod = load_llvm_ir(ir_path; source_code=wrapped_code)

    # Get function signature
    fn = get_function(rust_mod, func_name)
    if fn === nothing
        error("Function '$func_name' not found in compiled code")
    end

    ret_type, arg_types = get_function_signature(fn)

    # Also compile to shared library for function pointer
    lib_path = compile_rust_to_shared_lib(wrapped_code; compiler=compiler)
    lib_handle = Libdl.dlopen(lib_path, Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW)
    func_ptr = Libdl.dlsym(lib_handle, func_name)

    # Extract the function IR
    llvm_ir = extract_function_ir(rust_mod, func_name)

    # Register
    info = RustFunctionInfo(func_name, ret_type, arg_types, llvm_ir, func_ptr)
    LLVM_FUNCTION_REGISTRY[func_name] = info

    return info
end

"""
    get_registered_function(func_name::String) -> Union{RustFunctionInfo, Nothing}

Get a registered Rust function's information.
"""
function get_registered_function(func_name::String)
    return get(LLVM_FUNCTION_REGISTRY, func_name, nothing)
end

# ============================================================================
# Generated function for optimized Rust calls
# ============================================================================

"""
    @rust_llvm func_name(args...)

Call a Rust function using LLVM IR integration (Phase 2).
This uses @generated functions to produce optimized code at compile time.

# Example
```julia
rust\"\"\"
#[no_mangle]
pub extern "C" fn add_optimized(a: i32, b: i32) -> i32 {
    a + b
}
\"\"\"

# Use llvmcall path (experimental)
result = @rust_llvm add_optimized(10, 20)
```
"""
macro rust_llvm(expr)
    if !isexpr(expr, :call)
        error("@rust_llvm requires a function call expression")
    end

    func_name = expr.args[1]
    args = expr.args[2:end]
    func_name_str = string(func_name)

    escaped_args = map(esc, args)

    return quote
        _rust_llvm_call($func_name_str, $(escaped_args...))
    end
end

"""
    _rust_llvm_call(func_name::String, args...)

Internal function to call a Rust function via LLVM integration.
Falls back to ccall if llvmcall is not available.
"""
function _rust_llvm_call(func_name::String, args...)
    # Get function info
    info = get_registered_function(func_name)

    if info === nothing
        # Try to find it in the current library
        lib_name = get_current_library()
        func_ptr = get_function_pointer(lib_name, func_name)

        # Fall back to ccall-based approach
        return call_rust_function_infer(func_ptr, args...)
    end

    # Use the cached function pointer for now
    # Direct llvmcall integration requires more complex setup
    if info.func_ptr !== nothing
        return call_rust_function(info.func_ptr, info.return_type, args...)
    end

    error("Function '$func_name' is registered but has no function pointer")
end

# ============================================================================
# Optimized generated functions for specific type combinations
# ============================================================================

"""
    @generated function rust_call_generated(::Val{name}, args...) where {name}

A generated function that produces optimized code for Rust function calls.
The function name is encoded as a type parameter for compile-time dispatch.
"""
@generated function rust_call_generated(::Val{name}, args...) where {name}
    func_name = string(name)
    arg_types = collect(args)
    n = length(arg_types)

    # Try to get function info at compile time
    info = get_registered_function(func_name)

    if info !== nothing && info.func_ptr !== nothing
        # We have function info, generate optimized code
        ret_type = info.return_type
        expected_arg_types = info.arg_types

        # Validate argument count
        if n != length(expected_arg_types)
            return :(error("Argument count mismatch: expected $(length($expected_arg_types)), got $n"))
        end

        # Generate ccall with exact types (most compatible approach)
        func_ptr_val = info.func_ptr

        if ret_type == Int32 && n == 2 && expected_arg_types == [Int32, Int32]
            return :(ccall($func_ptr_val, Int32, (Int32, Int32),
                         Int32(args[1]), Int32(args[2])))
        elseif ret_type == Int64 && n == 2 && expected_arg_types == [Int64, Int64]
            return :(ccall($func_ptr_val, Int64, (Int64, Int64),
                         Int64(args[1]), Int64(args[2])))
        elseif ret_type == Float64 && n == 2 && expected_arg_types == [Float64, Float64]
            return :(ccall($func_ptr_val, Float64, (Float64, Float64),
                         Float64(args[1]), Float64(args[2])))
        elseif ret_type == Float32 && n == 2 && expected_arg_types == [Float32, Float32]
            return :(ccall($func_ptr_val, Float32, (Float32, Float32),
                         Float32(args[1]), Float32(args[2])))
        elseif ret_type == Bool && n == 1
            return :(ccall($func_ptr_val, Bool, (Int32,), Int32(args[1])))
        end
    end

    # Fallback to runtime dispatch
    return quote
        _rust_llvm_call($func_name, args...)
    end
end

# Note: isexpr is already defined in rustmacro.jl
