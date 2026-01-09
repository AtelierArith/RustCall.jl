# Rust type representations in Julia

"""
    RustPtr{T}

A pointer to a Rust value of type T.
Corresponds to `*const T` or `*mut T` in Rust.
"""
struct RustPtr{T}
    ptr::Ptr{Cvoid}
end

Base.unsafe_convert(::Type{Ptr{Cvoid}}, p::RustPtr) = p.ptr
Base.cconvert(::Type{Ptr{Cvoid}}, p::RustPtr) = p

"""
    RustRef{T}

A reference to a Rust value of type T.
Corresponds to `&T` or `&mut T` in Rust.
Note: In C ABI, references are passed as pointers.
"""
struct RustRef{T}
    ptr::Ptr{Cvoid}
end

Base.unsafe_convert(::Type{Ptr{Cvoid}}, r::RustRef) = r.ptr
Base.cconvert(::Type{Ptr{Cvoid}}, r::RustRef) = r

"""
    RustResult{T, E}

Represents Rust's `Result<T, E>` type.
"""
struct RustResult{T, E}
    is_ok::Bool
    value::Union{T, E}

    function RustResult{T, E}(is_ok::Bool, value) where {T, E}
        new{T, E}(is_ok, value)
    end
end

"""
    unwrap(result::RustResult)

Unwrap a RustResult, returning the Ok value or throwing an error.
"""
function unwrap(result::RustResult{T, E}) where {T, E}
    if result.is_ok
        return result.value::T
    else
        error("Unwrap failed on Err: $(result.value)")
    end
end

"""
    unwrap_or(result::RustResult{T, E}, default::T)

Unwrap a RustResult, returning the Ok value or the provided default.
"""
function unwrap_or(result::RustResult{T, E}, default::T) where {T, E}
    result.is_ok ? result.value::T : default
end

"""
    is_ok(result::RustResult)

Check if a RustResult is Ok.
"""
is_ok(result::RustResult) = result.is_ok

"""
    is_err(result::RustResult)

Check if a RustResult is Err.
"""
is_err(result::RustResult) = !result.is_ok

"""
    RustOption{T}

Represents Rust's `Option<T>` type.
"""
struct RustOption{T}
    is_some::Bool
    value::Union{T, Nothing}

    function RustOption{T}(is_some::Bool, value) where {T}
        new{T}(is_some, value)
    end
end

"""
    unwrap(option::RustOption)

Unwrap a RustOption, returning the Some value or throwing an error.
"""
function unwrap(option::RustOption{T}) where {T}
    if option.is_some
        return option.value::T
    else
        error("Unwrap failed on None")
    end
end

"""
    unwrap_or(option::RustOption{T}, default::T)

Unwrap a RustOption, returning the Some value or the provided default.
"""
function unwrap_or(option::RustOption{T}, default::T) where {T}
    option.is_some ? option.value::T : default
end

"""
    is_some(option::RustOption)

Check if a RustOption is Some.
"""
is_some(option::RustOption) = option.is_some

"""
    is_none(option::RustOption)

Check if a RustOption is None.
"""
is_none(option::RustOption) = !option.is_some

# C-compatible representation for Result (for FFI)
# This matches the layout that Rust uses with #[repr(C)]
struct CRustResult
    is_ok::UInt8  # 0 = Err, 1 = Ok
    value::Ptr{Cvoid}
end

# C-compatible representation for Option (for FFI)
struct CRustOption
    is_some::UInt8  # 0 = None, 1 = Some
    value::Ptr{Cvoid}
end

# String types

"""
    RustString

Represents Rust's owned `String` type.
This is a wrapper around a pointer to a Rust String.
The memory is managed by Rust (via Box or similar).

# Memory Management
When a Rust function returns a `String`, it should be freed using
`drop_rust_string` or similar function provided by the Rust side.
"""
mutable struct RustString
    ptr::Ptr{Cvoid}  # Pointer to Rust String (Vec<u8>)
    len::UInt        # Length in bytes
    cap::UInt        # Capacity in bytes

    function RustString(ptr::Ptr{Cvoid}, len::UInt, cap::UInt)
        new(ptr, len, cap)
    end
end

"""
    RustStr

Represents Rust's string slice `&str`.
This is a borrowed reference, so the memory is managed elsewhere.
"""
struct RustStr
    ptr::Ptr{UInt8}  # Pointer to the string data
    len::UInt        # Length in bytes
end

# C-compatible representation for Rust String (for FFI)
# This matches the layout that Rust uses with #[repr(C)]
struct CRustString
    ptr::Ptr{UInt8}
    len::UInt
    cap::UInt
end

# C-compatible representation for Rust str slice (for FFI)
struct CRustStr
    ptr::Ptr{UInt8}
    len::UInt
end

# String conversion functions

"""
    rust_string_to_julia(rs::RustString) -> String

Convert a RustString to a Julia String.
This copies the data from Rust memory to Julia memory.
"""
function rust_string_to_julia(rs::RustString)
    if rs.ptr == C_NULL || rs.len == 0
        return ""
    end

    # Read the bytes from Rust memory
    bytes = Vector{UInt8}(undef, rs.len)
    unsafe_copyto!(pointer(bytes), convert(Ptr{UInt8}, rs.ptr), rs.len)

    # Convert to Julia String
    return String(bytes)
end

"""
    rust_str_to_julia(rs::RustStr) -> String

Convert a RustStr (string slice) to a Julia String.
This copies the data.
"""
function rust_str_to_julia(rs::RustStr)
    if rs.ptr == C_NULL || rs.len == 0
        return ""
    end

    # Read the bytes
    bytes = Vector{UInt8}(undef, rs.len)
    unsafe_copyto!(pointer(bytes), rs.ptr, rs.len)

    # Convert to Julia String
    return String(bytes)
end

"""
    julia_string_to_rust(s::String) -> RustStr

Convert a Julia String to a RustStr (borrowed reference).
Note: The returned RustStr is only valid while the Julia String exists.
For FFI, you typically want to use Cstring instead.
"""
function julia_string_to_rust(s::String)
    if isempty(s)
        return RustStr(C_NULL, UInt(0))
    end

    # Get pointer to the string data
    ptr = Base.unsafe_convert(Ptr{UInt8}, s)
    len = UInt(sizeof(s))

    return RustStr(ptr, len)
end

"""
    julia_string_to_cstring(s::String) -> String

Prepare a Julia String for FFI (to be converted to Cstring by ccall).
Note: The actual conversion happens at ccall time via cconvert/unsafe_convert.
"""
function julia_string_to_cstring(s::String)
    return s  # ccall handles String -> Cstring conversion
end

"""
    cstring_to_julia_string(cs::Cstring) -> String

Convert a Cstring (from Rust) to a Julia String.
This copies the data.
"""
function cstring_to_julia_string(cs::Cstring)
    if cs == C_NULL
        return ""
    end
    return unsafe_string(cs)
end
