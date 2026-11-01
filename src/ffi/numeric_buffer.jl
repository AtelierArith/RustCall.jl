const _NumericBufferElement = Union{Bool, Int8, Int16, Int32, Int64,
    UInt8, UInt16, UInt32, UInt64, Float32, Float64, ComplexF32, ComplexF64}

"""
    RustCall.with_numeric_buffer(f, array; write=false, element_type=eltype(array))

Call `f(pointer, length)` with a scoped, contiguous copy of a Julia numeric
array. The pointer is valid only until `f` returns and must not be retained.
`f` must use it synchronously and must use a Rust element type with the same
representation as Julia's `eltype(array)`. No conversion of element type or
byte order is performed.

When `write=true`, values are copied back to `array` only after `f` returns
normally; if `f` throws, the original array is unchanged. The caller must
prevent concurrent access to `array` during the call and ensure any values
written by foreign code are valid Julia values of the element type. A returned
error status is a normal return: throw in `f` to prevent copy-back. Empty
arrays are passed with length zero and a valid aligned non-null pointer.

This helper supports `Bool`, 8/16/32/64-bit signed and unsigned integers,
`Float32`, `Float64`, `ComplexF32` and `ComplexF64`. The `element_type` keyword
checks the declared Julia element type against the array. The caller must still
ensure the callback uses the matching Rust representation; a raw pointer cannot
carry or validate a Rust type. The helper does not keep pointers
returned or captured by `f` alive after the call. It copies views in `eachindex`
order; arbitrary user-defined array indexing and copy-back methods
may throw. It is not an owned Rust `Vec` conversion.
"""
function with_numeric_buffer(f, array::AbstractArray{T}; write::Bool=false, element_type::Type=T) where {T}
    T <: _NumericBufferElement ||
        throw(ArgumentError("unsupported numeric buffer element type: $T"))
    element_type === T || throw(ArgumentError("declared element type $element_type does not match array element type $T"))
    len = length(array)
    buffer = Vector{T}(undef, max(1, len))
    for (index, source) in enumerate(eachindex(array))
        buffer[index] = array[source]
    end
    result = GC.@preserve buffer f(pointer(buffer), Csize_t(len))
    if write
        for (index, destination) in enumerate(eachindex(array))
            array[destination] = buffer[index]
        end
    end
    return result
end

"""
    RustCall.copy_owned_numeric_buffer(release, pointer::Ptr{T}, length)

Copy `length` elements from a Rust-owned contiguous buffer into a Julia
`Vector{T}` and call `release(pointer, length)` exactly once in a `finally`
block, including if validation or copying fails. `release` must invoke the
destructor supplied by the *same Rust library* that allocated the buffer.
This is an unsafe FFI boundary: the caller must supply a live, aligned pointer
valid for reads of `length` initialized `T` values, with compatible Rust/Julia
layout, and must ensure no other thread accesses or releases it. A nonempty
buffer may not have a null pointer. Pointer provenance and allocation length
cannot be verified by this function. Zero-length buffers are not dereferenced.

Use only with an API whose ownership has actually been transferred to Julia;
never release borrowed pointers or assume a Rust `Vec` layout.
"""
function copy_owned_numeric_buffer(release, ptr::Ptr{T}, n::Integer) where {T}
    try
        T <: _NumericBufferElement ||
            throw(ArgumentError("unsupported numeric buffer element type: $T"))
        0 <= n <= typemax(Int) || throw(ArgumentError("invalid buffer length"))
        len = Int(n)
        len > 0 && ptr == C_NULL && throw(ArgumentError("nonempty buffer has null pointer"))
        len > 0 && UInt(ptr) % Base.datatype_alignment(T) != 0 &&
            throw(ArgumentError("buffer pointer is not aligned for $T"))
        result = Vector{T}(undef, len)
        for i in eachindex(result)
            result[i] = unsafe_load(ptr, i)
        end
        return result
    finally
        release(ptr, n)
    end
end
