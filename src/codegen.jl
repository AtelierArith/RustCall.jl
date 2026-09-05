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
    # String ABI of a monomorphized `#[julia]` function (#242): `arg_abis` is
    # the manifest `abi` per argument ("string" / "str" arguments travel as
    # `(ptr, len)` pairs), `string_return` is `:none`, `:owned` (released
    # through `free_ptr`) or `:borrowed`.
    arg_abis::Vector{String}
    string_return::Symbol
    free_ptr::Ptr{Cvoid}
end

FunctionInfo(name::String, lib_name::String, return_type::Type, arg_types::Vector{Type}, func_ptr::Ptr{Cvoid}) =
    FunctionInfo(name, lib_name, return_type, arg_types, func_ptr, String[], :none, C_NULL)

"""
Registry for function information.
Maps function name to FunctionInfo.
"""
const FUNCTION_REGISTRY = Dict{String, FunctionInfo}()

"""
Library-scoped registry for function information.
Maps (library name, function name) to FunctionInfo.
"""
const FUNCTION_REGISTRY_BY_LIB = Dict{Tuple{String, String}, FunctionInfo}()

"""
Registry for function return types (for functions without full signature
registration), keyed by `(library name, function name)`.

There is deliberately **no** name-only fallback table, and no cross-library
search. A name-keyed hint outlives the library that wrote it: clearing or
reloading that library would leave its return type answering for every other
library's function of the same name, and a rebuilt library that no longer
declares the function that way would be typed by the stale value (#279).
Lookups go through the library `_resolve_call` took the pointer from, so a
call's pointer and its ABI always come from the same build.

Guarded by `REGISTRY_LOCK`.
"""
const FUNCTION_RETURN_TYPES_BY_LIB = Dict{Tuple{String, String}, Type}()

"""
Rust item name to exported C symbol, keyed by `(library name, Rust name)`.

`#[julia]` is additive since #279: the annotated function keeps its own name
and the library exports the wrapper `rustcall_<name>` next to it. `@rust
add(1, 2)` names the *Rust function*, so the lookup has to go through this
mapping, which is filled from the manifest (`Function.symbol`) — never by
string surgery on the name.

The mapping is strictly **per library**, and identity mappings are recorded
too. One library exporting `#[julia] fn f` as `rustcall_f` must not decide how
`f` resolves in another library that exports a plain `#[no_mangle] fn f` under
its own name; a library with no entry for a name resolves it to the name
itself. Entries are dropped with the library (`clear_library_metadata!`), so an
unloaded library cannot leave a stale mapping behind.

Guarded by `REGISTRY_LOCK`.
"""
const FUNCTION_SYMBOLS_BY_LIB = Dict{Tuple{String, String}, String}()

"""
    register_function_symbol(lib_name, name, symbol)

Record that the Rust item `name` of `lib_name` is exported as `symbol`.
Identity mappings are recorded as well: a plain `#[no_mangle] extern "C" fn f`
is explicitly `f => f` for its own library, which is what keeps another
library's `f => rustcall_f` from leaking into it.
"""
function register_function_symbol(lib_name::AbstractString, name::AbstractString,
                                  symbol::AbstractString)
    isempty(symbol) && return nothing
    lock(REGISTRY_LOCK) do
        FUNCTION_SYMBOLS_BY_LIB[(String(lib_name), String(name))] = String(symbol)
    end
    return nothing
end

"""
    exported_symbol(lib_name, name) -> String

The exported C symbol of the Rust item `name` **in `lib_name`**, or `name`
itself when that library recorded nothing for it (a library loaded outside the
manifest pipeline, or a `name` that is already the exported symbol). Never
consults another library's mapping.
"""
function exported_symbol(lib_name::AbstractString, name::AbstractString)
    lock(REGISTRY_LOCK) do
        get(FUNCTION_SYMBOLS_BY_LIB, (String(lib_name), String(name)), String(name))
    end
end

"""
    clear_library_metadata!(lib_name)

Drop everything the registries record *about* one library: its name-to-symbol
mappings and its return-type hints.

Called wherever a library leaves `RUST_LIBRARIES` or is replaced under the same
name (unload, hot reload, re-registration of a `rust\"\"\"` block). A stale
mapping would redirect a later lookup to a symbol that is no longer loaded, and
a stale hint would type a call to a function the rebuilt library no longer
declares that way — so the two must go together, in the same transaction that
removes the handle (#279).

Both registries are keyed by library, so dropping a library's rows is all there
is to it: nothing it recorded can outlive it under a name-only key.
"""
function clear_library_metadata!(lib_name::AbstractString)
    name = String(lib_name)
    lock(REGISTRY_LOCK) do
        for key in collect(keys(FUNCTION_SYMBOLS_BY_LIB))
            first(key) == name && delete!(FUNCTION_SYMBOLS_BY_LIB, key)
        end
        for key in collect(keys(FUNCTION_RETURN_TYPES_BY_LIB))
            first(key) == name && delete!(FUNCTION_RETURN_TYPES_BY_LIB, key)
        end
    end
    return nothing
end

"""
    copy_library_metadata!(from, to)

Give the library `to` the same name-to-symbol mappings and return-type hints as
`from`, replacing whatever it had.

Used when one loaded handle is registered under a second name (`@rust`'s reload
alias, `_alias_reloaded_library`): both registries are per library, so the alias
needs its own entries. Without the mappings a lookup through it would resolve
`f` to `f` and miss the `rustcall_f` the library actually exports; without the
hints an untyped `@rust f(...)` through the alias would fall back to the
unscoped table and pick up whatever *another* block last registered for that
name (#279).
"""
function copy_library_metadata!(from::AbstractString, to::AbstractString)
    source = String(from)
    target = String(to)
    source == target && return nothing
    lock(REGISTRY_LOCK) do
        clear_library_metadata!(target)
        for ((lib, name), symbol) in collect(FUNCTION_SYMBOLS_BY_LIB)
            lib == source && (FUNCTION_SYMBOLS_BY_LIB[(target, name)] = symbol)
        end
        for ((lib, name), ret_type) in collect(FUNCTION_RETURN_TYPES_BY_LIB)
            lib == source && (FUNCTION_RETURN_TYPES_BY_LIB[(target, name)] = ret_type)
        end
    end
    return nothing
end

"""
    register_function(name::String, lib_name::String, ret_type::Type, arg_types::Vector{Type})

Register a function with its type signature for later calling.
"""
function register_function(name::String, lib_name::String, ret_type::Type, arg_types::Vector{Type})
    func_ptr = get_function_pointer(lib_name, name)
    info = FunctionInfo(name, lib_name, ret_type, arg_types, func_ptr)
    FUNCTION_REGISTRY_BY_LIB[(lib_name, name)] = info
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
    get_function_info(lib_name::String, name::String) -> Union{FunctionInfo, Nothing}

Get registered function info scoped to a library. Falls back to name-only registry
for backward compatibility.
"""
function get_function_info(lib_name::String, name::String)
    return get(FUNCTION_REGISTRY_BY_LIB, (lib_name, name), get(FUNCTION_REGISTRY, name, nothing))
end

"""
    get_function_return_type(lib_name::String, func_name::String) -> Union{Type, Nothing}

The return type `lib_name` itself registered for `func_name`, or `nothing`.

**Only that library's own entry is consulted.** No name-only fallback, and no
search of the other libraries: a hint must never describe a function in a
library other than the one the call actually reaches. `lib_name` here is the
*owning* library — the one `_resolve_call` took the pointer from — so the
pointer and the ABI it is called with always come from the same build.

Borrowing would be worse than having no hint: a library whose `f` returns
`Result<i32, i32>` deliberately records nothing (the wrapper returns a
`CResult_f` struct, and `@rust` callers must be explicit), so any hint found
elsewhere for the name `f` is not merely unrelated but the wrong ABI. Absent a
hint the caller infers from the arguments or demands an explicit `::T` (#279).
"""
function get_function_return_type(lib_name::String, func_name::String)
    lock(REGISTRY_LOCK) do
        get(FUNCTION_RETURN_TYPES_BY_LIB, (lib_name, func_name), nothing)
    end
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
                return _get_function_signature(fn)
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
# `RustString` / `RustStr` deliberately have NO `Cstring` lowering: a Rust
# `String` is a `(ptr, len, cap)` buffer and a `&str` a `(ptr, len)` view,
# neither of which is a NUL-terminated C string. That coercion was the wrong
# shape #246 is about, and since #276 every string position is described by
# `ffi_return_contract` / `ffi_argument_contract` instead.
julia_to_c_type(::Type{T}) where {T<:AbstractString} = Cstring

# Helper functions for ccall type handling (using multiple dispatch)
# Note: Cvoid === Nothing in Julia, so we only define for Cvoid
ccall_return_type(::Type{Cvoid}) = Cvoid
ccall_return_type(::Type{Cstring}) = Cstring
ccall_return_type(::Type{String}) = Cstring
# Rust's bool type in C ABI is represented as UInt8 (1 byte)
ccall_return_type(::Type{Bool}) = UInt8
ccall_return_type(::Type{T}) where {T} = T

convert_return(::Type{Cvoid}, _) = nothing
convert_return(::Type{Cstring}, value) = cstring_to_julia_string(value)
convert_return(::Type{String}, value) = cstring_to_julia_string(value)
# Convert Rust bool (UInt8) to Julia Bool: 0 = false, non-zero = true
convert_return(::Type{Bool}, value::UInt8) = value != 0x00
convert_return(::Type{Bool}, value) = Bool(value != 0)
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
    if R == String || R == Cstring || R == Bool
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
