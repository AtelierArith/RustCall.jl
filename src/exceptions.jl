# Error handling for Rust FFI

"""
    RustError <: Exception

Exception type for Rust-related errors.

# Fields
- `message::String`: Error message
- `code::Int32`: Optional error code (default: 0)
"""
struct RustError <: Exception
    message::String
    code::Int32

    function RustError(message::String, code::Int32=Int32(0))
        new(message, code)
    end
end

"""
    Base.showerror(io::IO, e::RustError)

Display a RustError in a user-friendly format.
"""
function Base.showerror(io::IO, e::RustError)
    if e.code == 0
        print(io, "RustError: $(e.message)")
    else
        print(io, "RustError: $(e.message) (code: $(e.code))")
    end
end

"""
    result_to_exception(result::RustResult{T, E}) where {T, E}

Convert a RustResult to either return the Ok value or throw a RustError.

# Arguments
- `result::RustResult{T, E}`: The Rust result to convert

# Returns
- The Ok value of type `T` if the result is Ok

# Throws
- `RustError` if the result is Err

# Example
```julia
result = RustResult{Int32, String}(false, "division by zero")
try
    value = result_to_exception(result)
catch e
    @assert e isa RustError
    println(e.message)  # => "division by zero"
end
```
"""
function result_to_exception(result::RustResult{T, E}) where {T, E}
    if result.is_ok
        return result.value::T
    else
        error_value = result.value::E
        error_msg = string(error_value)
        throw(RustError(error_msg, Int32(0)))
    end
end

"""
    result_to_exception(result::RustResult{T, E}, code::Int32) where {T, E}

Convert a RustResult to either return the Ok value or throw a RustError with a specific error code.

# Arguments
- `result::RustResult{T, E}`: The Rust result to convert
- `code::Int32`: Error code to use if the result is Err

# Returns
- The Ok value of type `T` if the result is Ok

# Throws
- `RustError` with the specified code if the result is Err
"""
function result_to_exception(result::RustResult{T, E}, code::Int32) where {T, E}
    if result.is_ok
        return result.value::T
    else
        error_value = result.value::E
        error_msg = string(error_value)
        throw(RustError(error_msg, code))
    end
end

"""
    unwrap_or_throw(result::RustResult{T, E}) where {T, E}

Alias for `result_to_exception` that throws a RustError on Err.

This is a convenience function that provides a more Rust-like naming convention.
"""
unwrap_or_throw(result::RustResult{T, E}) where {T, E} = result_to_exception(result)

"""
    unwrap_or_throw(result::RustResult{T, E}, code::Int32) where {T, E}

Alias for `result_to_exception` with error code.
"""
unwrap_or_throw(result::RustResult{T, E}, code::Int32) where {T, E} = result_to_exception(result, code)
