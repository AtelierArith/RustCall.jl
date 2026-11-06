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

# One call's validated slice descriptor. The owner remains a separate local in
# every generated wrapper's GC.@preserve region; the descriptor never owns or
# releases foreign storage.
struct _FFISliceSpan{T}
    ptr::Ptr{T}
    len::Csize_t
    first::UInt
    stop::UInt
end

function ffi_slice_argument(
    array,
    ::Type{T},
    name::AbstractString,
    context::AbstractString,
) where {T}
    array isa StridedVector{T} || throw(
        ArgumentError(
            "argument `$name` of `$context` requires contiguous vector storage with exact element type $T; " *
            "use with_numeric_buffer explicitly when a copy is desired",
        ),
    )
    stride(array, 1) == 1 || throw(
        ArgumentError(
            "argument `$name` of `$context` must have stride 1; noncontiguous and reversed views cannot be borrowed",
        ),
    )
    n = length(array)
    bytes = _ffi_slice_byte_count(n, sizeof(T))
    alignment = UInt(Base.datatype_alignment(T))
    # Rust references require a non-null aligned address even when empty.
    # The aligned sentinel is never dereferenced and borrows no allocation.
    p = n == 0 ? Ptr{T}(alignment) : GC.@preserve array pointer(array)
    return _ffi_slice_span(p, n, bytes)
end

function _ffi_slice_span(
    p::Ptr{T},
    n::Integer,
    bytes::UInt = _ffi_slice_byte_count(n, sizeof(T)),
) where {T}
    first = UInt(p)
    first != 0 && first % UInt(Base.datatype_alignment(T)) == 0 ||
        throw(ArgumentError("null or misaligned slice pointer for $T"))
    bytes <= typemax(UInt) - first || throw(ArgumentError("slice address span overflows"))
    return _FFISliceSpan(p, Csize_t(n), first, first + bytes)
end

function _ffi_slice_byte_count(n::Integer, element_size::Integer)
    0 <= n <= typemax(Csize_t) || throw(ArgumentError("invalid slice length"))
    0 < element_size <= typemax(Int) || throw(ArgumentError("invalid slice element size"))
    n <= div(typemax(Int), element_size) ||
        throw(ArgumentError("slice byte length exceeds isize::MAX"))
    return UInt(n) * UInt(element_size)
end

function _ffi_string_span(value::String)
    first = GC.@preserve value UInt(pointer(value))
    bytes = UInt(sizeof(value))
    bytes <= typemax(UInt) - first || throw(ArgumentError("string address span overflows"))
    return _FFISliceSpan(Ptr{UInt8}(first), Csize_t(bytes), first, first + bytes)
end

function _ffi_check_slice_overlap(
    p::_FFISliceSpan,
    q::_FFISliceSpan,
    pname::AbstractString,
    qname::AbstractString,
    context::AbstractString,
)
    # Empty ranges borrow no bytes, including two identical empty arrays.
    if p.len != 0 && q.len != 0 && p.first < q.stop && q.first < p.stop
        throw(
            ArgumentError(
                "arguments `$pname` and `$qname` of `$context` overlap: a mutable slice may not alias another live borrow",
            ),
        )
    end
    return nothing
end

function _ffi_check_slice_handle_overlap(
    span::_FFISliceSpan,
    ptr::Ptr,
    name::AbstractString,
    context::AbstractString,
)
    if span.len != 0 && span.first <= UInt(ptr) < span.stop
        throw(
            ArgumentError(
                "slice argument `$name` of `$context` overlaps a borrowed Rust object",
            ),
        )
    end
    return nothing
end
