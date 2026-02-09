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

# Global code generator instance - initialized with default values
const DEFAULT_CODEGEN = Ref{LLVMCodeGenerator}(LLVMCodeGenerator())

function get_default_codegen()
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
    arg_list = join(["$(llvm_args[i]) %$(i-1)" for i in 1:length(arg_types)], ", ")
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
Supports basic types, pointers, tuples, and structs.
"""
function julia_type_to_llvm_ir_string end

# Basic integer types
julia_type_to_llvm_ir_string(::Type{Bool}) = "i1"
julia_type_to_llvm_ir_string(::Type{Int8}) = "i8"
julia_type_to_llvm_ir_string(::Type{UInt8}) = "i8"
julia_type_to_llvm_ir_string(::Type{Int16}) = "i16"
julia_type_to_llvm_ir_string(::Type{UInt16}) = "i16"
julia_type_to_llvm_ir_string(::Type{Int32}) = "i32"
julia_type_to_llvm_ir_string(::Type{UInt32}) = "i32"
julia_type_to_llvm_ir_string(::Type{Int64}) = "i64"
julia_type_to_llvm_ir_string(::Type{UInt64}) = "i64"
julia_type_to_llvm_ir_string(::Type{Int128}) = "i128"
julia_type_to_llvm_ir_string(::Type{UInt128}) = "i128"

# Floating point types
julia_type_to_llvm_ir_string(::Type{Float32}) = "float"
julia_type_to_llvm_ir_string(::Type{Float64}) = "double"

# Void type (Cvoid === Nothing in Julia, so this handles both)
julia_type_to_llvm_ir_string(::Type{Nothing}) = "void"

# Pointer types (opaque pointer in modern LLVM)
julia_type_to_llvm_ir_string(::Type{<:Ptr}) = "ptr"

# Tuple types
julia_type_to_llvm_ir_string(t::Type{<:Tuple}) = _tuple_type_to_llvm_ir(t)

# Struct types fallback (immutable structs)
function julia_type_to_llvm_ir_string(t::Type)
    if isstructtype(t) && !isabstracttype(t) && !isprimitivetype(t)
        return _struct_type_to_llvm_ir(t)
    else
        error("Unsupported Julia type for LLVM IR: $t. Supported types: basic numeric types, Ptr, Tuple, and immutable structs.")
    end
end

"""
    _tuple_type_to_llvm_ir(t::Type{<:Tuple}) -> String

Convert a Julia Tuple type to LLVM IR struct representation.
"""
function _tuple_type_to_llvm_ir(t::Type{<:Tuple})
    if t == Tuple{}
        return "{}"
    end

    param_types = t.parameters
    llvm_types = [julia_type_to_llvm_ir_string(param) for param in param_types]
    return "{$(join(llvm_types, ", "))}"
end

"""
    _struct_type_to_llvm_ir(t::Type) -> String

Convert a Julia struct type to LLVM IR struct representation.
Extracts field types from the struct definition.
"""
function _struct_type_to_llvm_ir(t::Type)
    if !isstructtype(t) || isabstracttype(t) || isprimitivetype(t)
        error("Type $t is not a concrete struct type")
    end

    # Get field types
    field_types = fieldtypes(t)
    if isempty(field_types)
        return "{}"
    end

    llvm_types = [julia_type_to_llvm_ir_string(ft) for ft in field_types]
    return "{$(join(llvm_types, ", "))}"
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
    existing = lock(LLVM_REGISTRY_LOCK) do
        get(LLVM_FUNCTION_REGISTRY, func_name, nothing)
    end
    if existing !== nothing
        return existing
    end

    # Wrap and compile (outside lock — compilation is slow)
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

    # Register under lock
    info = RustFunctionInfo(func_name, ret_type, arg_types, llvm_ir, func_ptr)
    lock(LLVM_REGISTRY_LOCK) do
        LLVM_FUNCTION_REGISTRY[func_name] = info
    end

    return info
end

"""
    get_registered_function(func_name::String) -> Union{RustFunctionInfo, Nothing}

Get a registered Rust function's information.
"""
function get_registered_function(func_name::String)
    return lock(LLVM_REGISTRY_LOCK) do
        get(LLVM_FUNCTION_REGISTRY, func_name, nothing)
    end
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

# Errors
- `ArgumentError`: If function is not registered and cannot be found in current library
- `TypeError`: If argument types don't match expected signature
"""
function _rust_llvm_call(func_name::String, args...)
    # Get function info
    info = get_registered_function(func_name)

    if info === nothing
        # Try to find it in the current library
        try
            lib_name = get_current_library()
            func_ptr = get_function_pointer(lib_name, func_name)
            # Fall back to ccall-based approach
            return call_rust_function_infer(func_ptr, args...)
        catch e
            # Provide detailed error message
            error("""
            Function '$func_name' is not registered for @rust_llvm and could not be found in the current library.

            To use @rust_llvm, you need to register the function first:
            ```julia
            compile_and_register_rust_function(\"\"\"
            #[no_mangle]
            pub extern "C" fn $func_name(...) -> ... {
                ...
            }
            \"\"\", "$func_name")
            ```

            Alternatively, use @rust macro which doesn't require registration:
            ```julia
            @rust $func_name(args...)::ReturnType
            ```

            Original error: $e
            """)
        end
    end

    # Validate argument count
    expected_arg_count = length(info.arg_types)
    actual_arg_count = length(args)
    if actual_arg_count != expected_arg_count
        error("""
        Argument count mismatch for function '$func_name':
        Expected $expected_arg_count arguments (types: $(info.arg_types))
        Got $actual_arg_count arguments (types: $(typeof.(args)))
        """)
    end

    # Use the cached function pointer for now
    # Direct llvmcall integration requires more complex setup
    if info.func_ptr !== nothing
        try
            if !isempty(info.arg_types)
                return call_rust_function(info.func_ptr, info.return_type, info.arg_types, args...)
            end
            return call_rust_function(info.func_ptr, info.return_type, args...)
        catch e
            error("""
            Error calling function '$func_name' via @rust_llvm:
            Return type: $(info.return_type)
            Expected argument types: $(info.arg_types)
            Actual argument types: $(typeof.(args))

            Original error: $e
            """)
        end
    end

    error("""
    Function '$func_name' is registered but has no function pointer.
    This indicates a registration error. Try re-registering the function:
    ```julia
    compile_and_register_rust_function(rust_code, "$func_name")
    ```
    """)
end

# ============================================================================
# Generated function wrappers for registered Rust calls
# ============================================================================

"""
    @generated function rust_call_generated(::Val{name}, args...) where {name}

A generated function that emits a typed call for registered Rust functions.
The function name is encoded as a type parameter for compile-time dispatch.
"""
@generated function rust_call_generated(::Val{name}, args...) where {name}
    func_name = string(name)
    n = length(args)

    # Try to get function info at compile time
    info = get_registered_function(func_name)

    if info !== nothing && info.func_ptr !== nothing
        expected_arg_types = info.arg_types
        expected_len = length(expected_arg_types)
        if n != expected_len
            return :(error("Argument count mismatch: expected $expected_len, got $n"))
        end
        argt = Core.apply_type(Tuple, expected_arg_types...)
        return :(call_rust_function($(info.func_ptr), $(info.return_type), $argt, args...))
    end

    # Fallback to runtime dispatch
    return quote
        _rust_llvm_call($func_name, args...)
    end
end

# Note: isexpr is already defined in rustmacro.jl
