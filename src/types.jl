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
