# Code generation for Rust function calls

"""
    FunctionInfo

Information about a registered Rust function.
"""
struct FunctionInfo
    name::String
    lib_name::String
    return_type::Type
    arg_types::Vector{Type}
    func_ptr::Ptr{Cvoid}
end

"""
Registry for function information.
Maps function name to FunctionInfo.
"""
const FUNCTION_REGISTRY = Dict{String, FunctionInfo}()

"""
    register_function(name::String, lib_name::String, ret_type::Type, arg_types::Vector{Type})

Register a function with its type signature for later calling.
"""
function register_function(name::String, lib_name::String, ret_type::Type, arg_types::Vector{Type})
    func_ptr = get_function_pointer(lib_name, name)
    info = FunctionInfo(name, lib_name, ret_type, arg_types, func_ptr)
    FUNCTION_REGISTRY[name] = info
    return info
end

"""
    get_function_info(name::String) -> Union{FunctionInfo, Nothing}

Get the registered function info for a function name.
"""
function get_function_info(name::String)
    return get(FUNCTION_REGISTRY, name, nothing)
end

"""
    infer_function_types(lib_name::String, func_name::String) -> Tuple{Type, Vector{Type}}

Try to infer the return type and argument types for a function.
Uses LLVM IR analysis if available.
"""
function infer_function_types(lib_name::String, func_name::String)
    # Try to find the RustModule for this library
    for (hash, mod) in RUST_MODULE_REGISTRY
        mod_lib_name = "rust_$(string(hash, base=16))"
        if mod_lib_name == lib_name
            fn = get_function(mod, func_name)
            if fn !== nothing
                return get_function_signature(fn)
            end
        end
    end

    # If we can't infer, return generic types
    error("Cannot infer types for function '$func_name'. Please provide explicit type annotations.")
end

"""
    julia_to_c_type(t::Type) -> Type

Convert a Julia type to its C-compatible equivalent for ccall.
"""
function julia_to_c_type(t::Type)
    if t <: Integer
        return t
    elseif t <: AbstractFloat
        return t
    elseif t <: Bool
        return Bool
    elseif t <: Ptr
        return Ptr{Cvoid}
    elseif t == String || t == Cstring || t == RustString || t == RustStr
        return Cstring
    elseif t <: AbstractString
        return Cstring
    else
        return Ptr{Cvoid}
    end
end

# Specialized call functions for common type combinations
# Using concrete types and literal tuple syntax to satisfy ccall's requirements

# Int32 functions
_call_rust_i32_0(ptr::Ptr{Cvoid}) = ccall(ptr, Int32, ())
_call_rust_i32_1(ptr::Ptr{Cvoid}, a1::Int32) = ccall(ptr, Int32, (Int32,), a1)
_call_rust_i32_2(ptr::Ptr{Cvoid}, a1::Int32, a2::Int32) = ccall(ptr, Int32, (Int32, Int32), a1, a2)
_call_rust_i32_3(ptr::Ptr{Cvoid}, a1::Int32, a2::Int32, a3::Int32) = ccall(ptr, Int32, (Int32, Int32, Int32), a1, a2, a3)

# Int64 functions
_call_rust_i64_0(ptr::Ptr{Cvoid}) = ccall(ptr, Int64, ())
_call_rust_i64_1(ptr::Ptr{Cvoid}, a1::Int64) = ccall(ptr, Int64, (Int64,), a1)
_call_rust_i64_2(ptr::Ptr{Cvoid}, a1::Int64, a2::Int64) = ccall(ptr, Int64, (Int64, Int64), a1, a2)
_call_rust_i64_3(ptr::Ptr{Cvoid}, a1::Int64, a2::Int64, a3::Int64) = ccall(ptr, Int64, (Int64, Int64, Int64), a1, a2, a3)

# Float32 functions
_call_rust_f32_0(ptr::Ptr{Cvoid}) = ccall(ptr, Float32, ())
_call_rust_f32_1(ptr::Ptr{Cvoid}, a1::Float32) = ccall(ptr, Float32, (Float32,), a1)
_call_rust_f32_2(ptr::Ptr{Cvoid}, a1::Float32, a2::Float32) = ccall(ptr, Float32, (Float32, Float32), a1, a2)
_call_rust_f32_3(ptr::Ptr{Cvoid}, a1::Float32, a2::Float32, a3::Float32) = ccall(ptr, Float32, (Float32, Float32, Float32), a1, a2, a3)

# Float64 functions
_call_rust_f64_0(ptr::Ptr{Cvoid}) = ccall(ptr, Float64, ())
_call_rust_f64_1(ptr::Ptr{Cvoid}, a1::Float64) = ccall(ptr, Float64, (Float64,), a1)
_call_rust_f64_2(ptr::Ptr{Cvoid}, a1::Float64, a2::Float64) = ccall(ptr, Float64, (Float64, Float64), a1, a2)
_call_rust_f64_3(ptr::Ptr{Cvoid}, a1::Float64, a2::Float64, a3::Float64) = ccall(ptr, Float64, (Float64, Float64, Float64), a1, a2, a3)

# Bool functions
_call_rust_bool_0(ptr::Ptr{Cvoid}) = ccall(ptr, Bool, ())
_call_rust_bool_1(ptr::Ptr{Cvoid}, a1::Int32) = ccall(ptr, Bool, (Int32,), a1)
_call_rust_bool_2(ptr::Ptr{Cvoid}, a1::Int32, a2::Int32) = ccall(ptr, Bool, (Int32, Int32), a1, a2)

# UInt32 functions
_call_rust_u32_0(ptr::Ptr{Cvoid}) = ccall(ptr, UInt32, ())
_call_rust_u32_1_str(ptr::Ptr{Cvoid}, a1::String) = ccall(ptr, UInt32, (Cstring,), a1)
_call_rust_u32_1_i32(ptr::Ptr{Cvoid}, a1::Int32) = ccall(ptr, UInt32, (Int32,), a1)
_call_rust_u32_2_str(ptr::Ptr{Cvoid}, a1::String, a2::String) = ccall(ptr, UInt32, (Cstring, Cstring), a1, a2)

# Void functions
_call_rust_void_0(ptr::Ptr{Cvoid}) = ccall(ptr, Cvoid, ())
_call_rust_void_1(ptr::Ptr{Cvoid}, a1::Int64) = ccall(ptr, Cvoid, (Int64,), a1)
_call_rust_void_2(ptr::Ptr{Cvoid}, a1::Int64, a2::Int64) = ccall(ptr, Cvoid, (Int64, Int64), a1, a2)

# Cstring (string) functions - use String and let ccall handle conversion
_call_rust_cstring_0(ptr::Ptr{Cvoid}) = ccall(ptr, Cstring, ())
_call_rust_cstring_1_str(ptr::Ptr{Cvoid}, a1::String) = ccall(ptr, Cstring, (Cstring,), a1)
_call_rust_cstring_2_str(ptr::Ptr{Cvoid}, a1::String, a2::String) = ccall(ptr, Cstring, (Cstring, Cstring), a1, a2)
_call_rust_cstring_1_i32(ptr::Ptr{Cvoid}, a1::Int32) = ccall(ptr, Cstring, (Int32,), a1)
_call_rust_cstring_2_str_i32(ptr::Ptr{Cvoid}, a1::String, a2::Int32) = ccall(ptr, Cstring, (Cstring, Int32), a1, a2)
_call_rust_cstring_2_i32_str(ptr::Ptr{Cvoid}, a1::Int32, a2::String) = ccall(ptr, Cstring, (Int32, Cstring), a1, a2)

"""
    call_rust_function(func_ptr::Ptr{Cvoid}, ret_type::Type, args...)

Call a Rust function with the given return type.
Dispatches to specialized ccall functions based on return type and argument count.
"""
function call_rust_function(func_ptr::Ptr{Cvoid}, ret_type::Type, args...)
    n = length(args)

    # Dispatch based on return type and argument count
    if ret_type == Int32 || ret_type <: Int32
        if n == 0
            return _call_rust_i32_0(func_ptr)
        elseif n == 1
            return _call_rust_i32_1(func_ptr, Int32(args[1]))
        elseif n == 2
            return _call_rust_i32_2(func_ptr, Int32(args[1]), Int32(args[2]))
        elseif n == 3
            return _call_rust_i32_3(func_ptr, Int32(args[1]), Int32(args[2]), Int32(args[3]))
        end
    elseif ret_type == Int64 || ret_type <: Int64
        if n == 0
            return _call_rust_i64_0(func_ptr)
        elseif n == 1
            return _call_rust_i64_1(func_ptr, Int64(args[1]))
        elseif n == 2
            return _call_rust_i64_2(func_ptr, Int64(args[1]), Int64(args[2]))
        elseif n == 3
            return _call_rust_i64_3(func_ptr, Int64(args[1]), Int64(args[2]), Int64(args[3]))
        end
    elseif ret_type == Float32 || ret_type <: Float32
        if n == 0
            return _call_rust_f32_0(func_ptr)
        elseif n == 1
            return _call_rust_f32_1(func_ptr, Float32(args[1]))
        elseif n == 2
            return _call_rust_f32_2(func_ptr, Float32(args[1]), Float32(args[2]))
        elseif n == 3
            return _call_rust_f32_3(func_ptr, Float32(args[1]), Float32(args[2]), Float32(args[3]))
        end
    elseif ret_type == Float64 || ret_type <: Float64
        if n == 0
            return _call_rust_f64_0(func_ptr)
        elseif n == 1
            return _call_rust_f64_1(func_ptr, Float64(args[1]))
        elseif n == 2
            return _call_rust_f64_2(func_ptr, Float64(args[1]), Float64(args[2]))
        elseif n == 3
            return _call_rust_f64_3(func_ptr, Float64(args[1]), Float64(args[2]), Float64(args[3]))
        end
    elseif ret_type == Bool
        if n == 0
            return _call_rust_bool_0(func_ptr)
        elseif n == 1
            return _call_rust_bool_1(func_ptr, Int32(args[1]))
        elseif n == 2
            return _call_rust_bool_2(func_ptr, Int32(args[1]), Int32(args[2]))
        end
    elseif ret_type == UInt32
        if n == 0
            return _call_rust_u32_0(func_ptr)
        elseif n == 1
            arg1 = args[1]
            arg1_type = typeof(arg1)
            if arg1_type == String
                return _call_rust_u32_1_str(func_ptr, arg1)
            else
                return _call_rust_u32_1_i32(func_ptr, Int32(arg1))
            end
        elseif n == 2
            arg1 = args[1]
            arg2 = args[2]
            if typeof(arg1) == String && typeof(arg2) == String
                return _call_rust_u32_2_str(func_ptr, arg1, arg2)
            end
        end
    elseif ret_type == Cvoid || ret_type == Nothing
        if n == 0
            return _call_rust_void_0(func_ptr)
        elseif n == 1
            return _call_rust_void_1(func_ptr, Int64(args[1]))
        elseif n == 2
            return _call_rust_void_2(func_ptr, Int64(args[1]), Int64(args[2]))
        end
    elseif ret_type == Cstring || ret_type == String
        # Handle string return types
        result = if n == 0
            _call_rust_cstring_0(func_ptr)
        elseif n == 1
            arg1 = args[1]
            if typeof(arg1) == String
                _call_rust_cstring_1_str(func_ptr, arg1)
            else
                _call_rust_cstring_1_i32(func_ptr, Int32(arg1))
            end
        elseif n == 2
            arg1, arg2 = args[1], args[2]
            t1, t2 = typeof(arg1), typeof(arg2)
            if t1 == String && t2 == String
                _call_rust_cstring_2_str(func_ptr, arg1, arg2)
            elseif t1 == String
                _call_rust_cstring_2_str_i32(func_ptr, arg1, Int32(arg2))
            elseif t2 == String
                _call_rust_cstring_2_i32_str(func_ptr, Int32(arg1), arg2)
            else
                error("Unsupported argument types for Cstring return")
            end
        else
            error("Unsupported argument count for Cstring return: $n")
        end

        # Convert Cstring to Julia String
        if result == C_NULL || convert(Ptr{Cvoid}, result) == C_NULL
            return ""
        else
            return unsafe_string(result)
        end
    end

    error("Unsupported return type ($ret_type) or argument count ($n). Use @rust_ccall for custom types.")
end

"""
    call_rust_function_infer(func_ptr::Ptr{Cvoid}, args...)

Call a Rust function, inferring the return type from the first argument.
"""
function call_rust_function_infer(func_ptr::Ptr{Cvoid}, args...)
    if isempty(args)
        return _call_rust_void_0(func_ptr)
    end

    first_type = typeof(first(args))
    if first_type == Int32
        return call_rust_function(func_ptr, Int32, args...)
    elseif first_type == Int64
        return call_rust_function(func_ptr, Int64, args...)
    elseif first_type == Float32
        return call_rust_function(func_ptr, Float32, args...)
    elseif first_type == Float64
        return call_rust_function(func_ptr, Float64, args...)
    elseif first_type == Bool
        return call_rust_function(func_ptr, Bool, args...)
    elseif first_type == String || first_type == Cstring
        return call_rust_function(func_ptr, Cstring, args...)
    else
        return call_rust_function(func_ptr, Int64, args...)
    end
end

"""
    @rust_ccall(func_name, ret_type, arg_types, args...)

Low-level macro for calling a Rust function with explicit types.

# Example
```julia
@rust_ccall(add, Int32, (Int32, Int32), 10, 20)
```
"""
macro rust_ccall(func_name, ret_type, arg_types, args...)
    func_name_str = string(func_name)
    return quote
        lib_name = get_current_library()
        func_ptr = get_function_pointer(lib_name, $func_name_str)
        ccall(func_ptr, $(esc(ret_type)), $(esc(arg_types)), $(map(esc, args)...))
    end
end
