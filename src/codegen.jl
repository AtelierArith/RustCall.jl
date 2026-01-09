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
    julia_to_c_type(::Type{T}) -> Type

Convert a Julia type to its C-compatible equivalent for ccall.
Uses multiple dispatch for efficient type-specific conversions.
"""
# Default fallback for unknown types
julia_to_c_type(::Type{T}) where {T} = isbitstype(T) ? T : Ptr{Cvoid}

# Specific type conversions using multiple dispatch
julia_to_c_type(::Type{T}) where {T<:Integer} = T
julia_to_c_type(::Type{T}) where {T<:AbstractFloat} = T
julia_to_c_type(::Type{Bool}) = Bool
julia_to_c_type(::Type{T}) where {T<:Ptr} = Ptr{Cvoid}
julia_to_c_type(::Type{String}) = Cstring
julia_to_c_type(::Type{Cstring}) = Cstring
julia_to_c_type(::Type{RustString}) = Cstring
julia_to_c_type(::Type{RustStr}) = Cstring
julia_to_c_type(::Type{T}) where {T<:AbstractString} = Cstring

# Helper functions for ccall type handling (using multiple dispatch)
# Note: Cvoid === Nothing in Julia, so we only define for Cvoid
ccall_return_type(::Type{Cvoid}) = Cvoid
ccall_return_type(::Type{Cstring}) = Cstring
ccall_return_type(::Type{String}) = Cstring
ccall_return_type(::Type{T}) where {T} = T

convert_return(::Type{Cvoid}, _) = nothing
convert_return(::Type{Cstring}, value) = cstring_to_julia_string(value)
convert_return(::Type{String}, value) = cstring_to_julia_string(value)
convert_return(::Type{T}, value) where {T} = value

default_numeric_arg_type(::Type{Bool}) = Int32
default_numeric_arg_type(::Type{UInt32}) = Int32
default_numeric_arg_type(::Type{Cstring}) = Int32
default_numeric_arg_type(::Type{String}) = Int32
default_numeric_arg_type(::Type{Cvoid}) = Int64
default_numeric_arg_type(::Type{T}) where {T} = T

normalize_arg_type(::Type{R}, ::Type{T}) where {R,T} = T
normalize_arg_type(::Type{R}, ::Type{T}) where {R,T<:AbstractString} = String
normalize_arg_type(::Type{R}, ::Type{Cstring}) where {R} = Cstring
normalize_arg_type(::Type{R}, ::Type{T}) where {R,T<:Integer} = T  # Preserve integer types
normalize_arg_type(::Type{R}, ::Type{T}) where {R,T<:AbstractFloat} = T  # Preserve float types
normalize_arg_type(::Type{R}, ::Type{Ptr{T}}) where {R,T} = Ptr{T}  # Preserve pointer types
normalize_arg_type(::Type{R}, ::Type{Ref{T}}) where {R,T} = Ref{T}  # Preserve Ref types

function normalize_arg_types(::Type{R}, argt::Type{<:Tuple}) where {R}
    normalized = map(t -> normalize_arg_type(R, t), argt.parameters)
    return Core.apply_type(Tuple, normalized...)
end

is_supported_arg_type(::Type{T}) where {T<:Integer} = true
is_supported_arg_type(::Type{T}) where {T<:AbstractFloat} = true
is_supported_arg_type(::Type{Bool}) = true
is_supported_arg_type(::Type{T}) where {T<:Ptr} = true
is_supported_arg_type(::Type{T}) where {T<:Ref} = true
is_supported_arg_type(::Type{T}) where {T<:AbstractString} = true
is_supported_arg_type(::Type{Cstring}) = true
is_supported_arg_type(::Type{T}) where {T} = isbitstype(T)

is_supported_return_type(::Type{T}) where {T<:Integer} = true
is_supported_return_type(::Type{T}) where {T<:AbstractFloat} = true
is_supported_return_type(::Type{Bool}) = true
is_supported_return_type(::Type{Cvoid}) = true  # Note: Cvoid === Nothing
is_supported_return_type(::Type{String}) = true
is_supported_return_type(::Type{Cstring}) = true
is_supported_return_type(::Type{T}) where {T<:Ptr} = true
is_supported_return_type(::Type{T}) where {T} = isbitstype(T)

ccall_arg_type(::Type{T}) where {T<:AbstractString} = Cstring
ccall_arg_type(::Type{Cstring}) = Cstring
ccall_arg_type(::Type{T}) where {T<:Integer} = T
ccall_arg_type(::Type{T}) where {T<:AbstractFloat} = T
ccall_arg_type(::Type{Bool}) = Bool
ccall_arg_type(::Type{Ptr{T}}) where {T} = Ptr{T}
ccall_arg_type(::Type{Ref{T}}) where {T} = Ref{T}
ccall_arg_type(::Type{T}) where {T} = T # Pass structs by value

convert_arg(::Type{T}, x) where {T<:AbstractString} = julia_string_to_cstring(String(x))
convert_arg(::Type{Cstring}, x) = x
convert_arg(::Type{T}, x) where {T<:Integer} = convert(T, x)
convert_arg(::Type{T}, x) where {T<:AbstractFloat} = convert(T, x)
convert_arg(::Type{Bool}, x) = Bool(x)
convert_arg(::Type{Ptr{T}}, x) where {T} = convert(Ptr{T}, x)
convert_arg(::Type{Ref{T}}, x) where {T} = convert(Ref{T}, x)
convert_arg(::Type{T}, x) where {T} = x

@generated function _call_rust_function(func_ptr::Ptr{Cvoid}, ::Type{R}, ::Type{A}, args...) where {R,A<:Tuple}
    if !is_supported_return_type(R)
        return :(error("Unsupported return type ($($(QuoteNode(R)))). Use @rust_ccall for custom types."))
    end
    arg_types = A.parameters
    for T in arg_types
        if !is_supported_arg_type(T)
            return :(error("Unsupported argument type ($($(QuoteNode(T)))). Use @rust_ccall for custom types."))
        end
    end
    ret_ccall = ccall_return_type(R)
    ccall_arg_types = map(ccall_arg_type, arg_types)
    arg_exprs = Any[]
    for (i, T) in enumerate(arg_types)
        push!(arg_exprs, :(convert_arg($T, args[$i])))
    end
    ccall_expr = Expr(:call, :ccall, :func_ptr, ret_ccall, Expr(:tuple, ccall_arg_types...), arg_exprs...)
    if R == String || R == Cstring
        return :(convert_return($R, $ccall_expr))
    end
    return ccall_expr
end

"""
    call_rust_function(func_ptr::Ptr{Cvoid}, ret_type::Type, args...)

Call a Rust function with the given return type.
Uses a generated ccall based on normalized argument types.

# Arguments
- `func_ptr::Ptr{Cvoid}`: Function pointer to the Rust function
- `ret_type::Type`: Expected return type of the function
- `args...`: Arguments to pass to the function

# Returns
- The return value of the Rust function, converted to the specified `ret_type`

# Example
```julia
func_ptr = get_function_pointer("mylib", "add")
result = call_rust_function(func_ptr, Int32, 10, 20)  # Returns Int32
```
"""
function call_rust_function(func_ptr::Ptr{Cvoid}, ret_type::Type, args...)
    argt = normalize_arg_types(ret_type, typeof(args))
    return _call_rust_function(func_ptr, ret_type, argt, args...)
end

"""
    call_rust_function(func_ptr::Ptr{Cvoid}, ret_type::Type, arg_types::Vector{Type}, args...)

Call a Rust function with explicit argument types.

# Arguments
- `func_ptr::Ptr{Cvoid}`: Function pointer to the Rust function
- `ret_type::Type`: Expected return type
- `arg_types::Vector{Type}`: Vector of argument types
- `args...`: Arguments to pass to the function

# Returns
- The return value of the Rust function

# Example
```julia
func_ptr = get_function_pointer("mylib", "multiply")
result = call_rust_function(func_ptr, Float64, [Float64, Float64], 3.14, 2.0)
```
"""
function call_rust_function(func_ptr::Ptr{Cvoid}, ret_type::Type, arg_types::Vector{Type}, args...)
    if length(arg_types) != length(args)
        error("Argument count mismatch: expected $(length(arg_types)), got $(length(args))")
    end
    argt = Core.apply_type(Tuple, arg_types...)
    return _call_rust_function(func_ptr, ret_type, argt, args...)
end

"""
    call_rust_function(func_ptr::Ptr{Cvoid}, ret_type::Type, argt::Type{<:Tuple}, args...)

Call a Rust function with a tuple type for arguments.

# Arguments
- `func_ptr::Ptr{Cvoid}`: Function pointer to the Rust function
- `ret_type::Type`: Expected return type
- `argt::Type{<:Tuple}`: Tuple type containing argument types
- `args...`: Arguments to pass to the function

# Returns
- The return value of the Rust function
"""
function call_rust_function(func_ptr::Ptr{Cvoid}, ret_type::Type, argt::Type{<:Tuple}, args...)
    if length(argt.parameters) != length(args)
        error("Argument count mismatch: expected $(length(argt.parameters)), got $(length(args))")
    end
    return _call_rust_function(func_ptr, ret_type, argt, args...)
end

"""
    call_rust_function_infer(func_ptr::Ptr{Cvoid}, args...)

Call a Rust function, inferring the return type from the first argument type.
Uses @generated function for compile-time optimization based on argument types.
"""
@generated function call_rust_function_infer(func_ptr::Ptr{Cvoid}, args...)
    if length(args) == 0
        return :(call_rust_function(func_ptr, Cvoid))
    end

    # Infer return type from first argument type at compile time
    ret_type = if args[1] <: Integer
        args[1]
    elseif args[1] <: AbstractFloat
        args[1]
    elseif args[1] === Bool
        Bool
    elseif args[1] <: AbstractString || args[1] === Cstring
        Cstring
    else
        Int64  # Default fallback
    end

    return :(call_rust_function(func_ptr, $ret_type, args...))
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
