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

# ============================================================================
# Phase 2: Extended Ownership Types
# ============================================================================

"""
    RustBox{T}

Represents Rust's `Box<T>` type - a heap-allocated value with single ownership.
The memory is owned by this wrapper and should be dropped when no longer needed.

# Memory Management
- `RustBox` owns its data and is responsible for calling drop
- Use `drop!` to explicitly release the memory
- Finalizers can be attached for automatic cleanup

# Example
```julia
# Create a Box (typically from Rust)
box = RustBox{Int32}(ptr)

# Access the value
value = deref(box)

# Drop when done
drop!(box)
```
"""
mutable struct RustBox{T}
    ptr::Ptr{Cvoid}
    dropped::Bool

    function RustBox{T}(ptr::Ptr{Cvoid}) where {T}
        box = new{T}(ptr, false)
        # Attach finalizer for automatic cleanup
        # The actual drop will be handled by memory.jl if available
        finalizer(box) do b
            if !b.dropped && b.ptr != C_NULL
                # Try to call Rust drop function if memory.jl is loaded
                try
                    if isdefined(LastCall, :drop_rust_box)
                        LastCall.drop_rust_box(b)
                    else
                        b.dropped = true
                    end
                catch e
                    @warn "Error dropping RustBox in finalizer: $e"
                    b.dropped = true
                end
            end
        end
        return box
    end
end

Base.unsafe_convert(::Type{Ptr{Cvoid}}, b::RustBox) = b.ptr
Base.cconvert(::Type{Ptr{Cvoid}}, b::RustBox) = b

"""
    is_valid(box::RustBox) -> Bool

Check if a RustBox is still valid (not dropped and not null).
"""
is_valid(box::RustBox) = !box.dropped && box.ptr != C_NULL

"""
    RustRc{T}

Represents Rust's `Rc<T>` type - a reference-counted pointer (single-threaded).
Multiple `RustRc` instances can share ownership of the same data.

# Memory Management
- Reference counting is managed by Rust
- Julia side should call `clone` to create new references
- Call `drop!` to decrement reference count

# Note
`Rc<T>` is not thread-safe. For multi-threaded scenarios, use `RustArc{T}`.
"""
mutable struct RustRc{T}
    ptr::Ptr{Cvoid}
    dropped::Bool

    function RustRc{T}(ptr::Ptr{Cvoid}) where {T}
        rc = new{T}(ptr, false)
        finalizer(rc) do r
            if !r.dropped && r.ptr != C_NULL
                try
                    if isdefined(LastCall, :drop_rust_rc)
                        LastCall.drop_rust_rc(r)
                    else
                        r.dropped = true
                    end
                catch e
                    @warn "Error dropping RustRc in finalizer: $e"
                    r.dropped = true
                end
            end
        end
        return rc
    end
end

Base.unsafe_convert(::Type{Ptr{Cvoid}}, r::RustRc) = r.ptr
Base.cconvert(::Type{Ptr{Cvoid}}, r::RustRc) = r

"""
    RustArc{T}

Represents Rust's `Arc<T>` type - an atomically reference-counted pointer (thread-safe).
Multiple `RustArc` instances can share ownership across threads.

# Memory Management
- Atomic reference counting is managed by Rust
- Safe to share across Julia tasks/threads
- Call `drop!` to decrement reference count

# Example
```julia
# Create an Arc (from Rust)
arc = RustArc{MyData}(ptr)

# Clone for another owner
arc2 = clone(arc)

# Safe to use in different tasks
@spawn begin
    # Use arc2
end
```
"""
mutable struct RustArc{T}
    ptr::Ptr{Cvoid}
    dropped::Bool

    function RustArc{T}(ptr::Ptr{Cvoid}) where {T}
        arc = new{T}(ptr, false)
        finalizer(arc) do a
            if !a.dropped && a.ptr != C_NULL
                try
                    if isdefined(LastCall, :drop_rust_arc)
                        LastCall.drop_rust_arc(a)
                    else
                        a.dropped = true
                    end
                catch e
                    @warn "Error dropping RustArc in finalizer: $e"
                    a.dropped = true
                end
            end
        end
        return arc
    end
end

Base.unsafe_convert(::Type{Ptr{Cvoid}}, a::RustArc) = a.ptr
Base.cconvert(::Type{Ptr{Cvoid}}, a::RustArc) = a

# is_valid for reference-counted types
is_valid(rc::RustRc) = !rc.dropped && rc.ptr != C_NULL
is_valid(arc::RustArc) = !arc.dropped && arc.ptr != C_NULL

"""
    RustVec{T}

Represents Rust's `Vec<T>` type - a growable array.

# Fields
- `ptr`: Pointer to the data
- `len`: Number of elements
- `cap`: Capacity (number of elements that can be stored without reallocation)

# Memory Management
- The vector owns its data
- Use `drop!` to release memory when done

# Example
```julia
# Create from Rust
vec = RustVec{Int32}(ptr, len, cap)

# Access length
length(vec)  # => len

# Convert to Julia array (copies data)
julia_arr = collect(vec)
```
"""
mutable struct RustVec{T}
    ptr::Ptr{Cvoid}
    len::UInt
    cap::UInt
    dropped::Bool

    function RustVec{T}(ptr::Ptr{Cvoid}, len::UInt, cap::UInt) where {T}
        vec = new{T}(ptr, len, cap, false)
        finalizer(vec) do v
            if !v.dropped && v.ptr != C_NULL
                v.dropped = true
            end
        end
        return vec
    end
end

Base.unsafe_convert(::Type{Ptr{Cvoid}}, v::RustVec) = v.ptr
Base.cconvert(::Type{Ptr{Cvoid}}, v::RustVec) = v

# Implement length for RustVec
Base.length(v::RustVec) = Int(v.len)

"""
    RustSlice{T}

Represents Rust's slice type `&[T]` - a borrowed view into a contiguous sequence.

# Fields
- `ptr`: Pointer to the first element
- `len`: Number of elements

# Note
This is a borrowed reference; the underlying data must outlive the slice.
"""
struct RustSlice{T}
    ptr::Ptr{T}
    len::UInt
end

Base.length(s::RustSlice) = Int(s.len)

# C-compatible representation for Vec (for FFI)
# This matches the layout that Rust uses with #[repr(C)]
struct CRustVec
    ptr::Ptr{Cvoid}
    len::UInt
    cap::UInt
end

# C-compatible representation for slice (for FFI)
struct CRustSlice
    ptr::Ptr{Cvoid}
    len::UInt
end

# ============================================================================
# Indexing and array operations for RustVec
# ============================================================================

"""
    getindex(vec::RustVec{T}, i::Int) -> T

Get the element at index `i` in a RustVec.

# Arguments
- `vec`: The RustVec to index into
- `i`: The index (1-based, like Julia arrays)

# Example
```julia
vec = RustVec{Int32}(ptr, 10, 20)
value = vec[1]  # Get first element
```

# Note
This performs bounds checking. The index must be between 1 and `length(vec)`.
"""
function Base.getindex(vec::RustVec{T}, i::Int) where {T}
    if vec.dropped || vec.ptr == C_NULL
        error("Cannot index into a dropped RustVec")
    end
    
    if i < 1 || i > length(vec)
        throw(BoundsError(vec, i))
    end
    
    # Convert to 0-based index for pointer arithmetic
    idx = i - 1
    # Get pointer to the element
    elem_ptr = vec.ptr + idx * sizeof(T)
    # Read the value
    unsafe_load(Ptr{T}(elem_ptr))
end

"""
    setindex!(vec::RustVec{T}, value, i::Int) -> value

Set the element at index `i` in a RustVec to `value`.

# Arguments
- `vec`: The RustVec to modify
- `value`: The value to set (must be convertible to type T)
- `i`: The index (1-based, like Julia arrays)

# Example
```julia
vec = RustVec{Int32}(ptr, 10, 20)
vec[1] = 42  # Set first element to 42
```

# Note
This performs bounds checking. The index must be between 1 and `length(vec)`.
"""
function Base.setindex!(vec::RustVec{T}, value, i::Int) where {T}
    if vec.dropped || vec.ptr == C_NULL
        error("Cannot set index in a dropped RustVec")
    end
    
    if i < 1 || i > length(vec)
        throw(BoundsError(vec, i))
    end
    
    # Convert value to type T
    typed_value = convert(T, value)
    
    # Convert to 0-based index for pointer arithmetic
    idx = i - 1
    # Get pointer to the element
    elem_ptr = vec.ptr + idx * sizeof(T)
    # Write the value
    unsafe_store!(Ptr{T}(elem_ptr), typed_value)
    return value
end

"""
    getindex(slice::RustSlice{T}, i::Int) -> T

Get the element at index `i` in a RustSlice.

# Arguments
- `slice`: The RustSlice to index into
- `i`: The index (1-based, like Julia arrays)

# Example
```julia
slice = RustSlice{Int32}(ptr, 10)
value = slice[1]  # Get first element
```

# Note
This performs bounds checking. The index must be between 1 and `length(slice)`.
"""
function Base.getindex(slice::RustSlice{T}, i::Int) where {T}
    if i < 1 || i > length(slice)
        throw(BoundsError(slice, i))
    end
    
    # Convert to 0-based index for pointer arithmetic
    idx = i - 1
    # Get pointer to the element
    elem_ptr = slice.ptr + idx * sizeof(T)
    # Read the value
    unsafe_load(elem_ptr)
end

# ============================================================================
# Iterator support for RustVec and RustSlice
# ============================================================================

"""
    iterate(vec::RustVec{T}, state=1) -> Union{Tuple{T, Int}, Nothing}

Iterate over elements in a RustVec.

# Example
```julia
vec = RustVec{Int32}(ptr, 10, 20)
for x in vec
    println(x)
end
```
"""
function Base.iterate(vec::RustVec{T}, state::Int=1) where {T}
    if vec.dropped || vec.ptr == C_NULL || state > length(vec)
        return nothing
    end
    
    value = vec[state]
    return (value, state + 1)
end

"""
    iterate(slice::RustSlice{T}, state=1) -> Union{Tuple{T, Int}, Nothing}

Iterate over elements in a RustSlice.

# Example
```julia
slice = RustSlice{Int32}(ptr, 10)
for x in slice
    println(x)
end
```
"""
function Base.iterate(slice::RustSlice{T}, state::Int=1) where {T}
    if state > length(slice)
        return nothing
    end
    
    value = slice[state]
    return (value, state + 1)
end

# Iterator traits
Base.IteratorSize(::Type{<:RustVec}) = Base.HasLength()
Base.IteratorSize(::Type{<:RustSlice}) = Base.HasLength()
Base.IteratorEltype(::Type{RustVec{T}}) where {T} = Base.HasEltype()
Base.IteratorEltype(::Type{RustSlice{T}}) where {T} = Base.HasEltype()
Base.eltype(::Type{RustVec{T}}) where {T} = T
Base.eltype(::Type{RustSlice{T}}) where {T} = T

# ============================================================================
# Conversion between Julia arrays and RustVec
# ============================================================================

"""
    Vector(vec::RustVec{T}) -> Vector{T}

Convert a RustVec to a Julia Vector by copying the data.

# Example
```julia
vec = RustVec{Int32}(ptr, 10, 20)
julia_vec = Vector(vec)  # Creates a new Julia array
```

# Note
This creates a copy of the data. Modifications to the returned Vector
will not affect the original RustVec.
"""
function Base.Vector(vec::RustVec{T}) where {T}
    if vec.dropped || vec.ptr == C_NULL
        error("Cannot convert a dropped RustVec to a Vector")
    end
    
    len = length(vec)
    result = Vector{T}(undef, len)
    
    # Copy elements
    for i in 1:len
        result[i] = vec[i]
    end
    
    return result
end

"""
    collect(vec::RustVec{T}) -> Vector{T}

Alias for `Vector(vec::RustVec{T})`. Convert a RustVec to a Julia Vector.

# Example
```julia
vec = RustVec{Int32}(ptr, 10, 20)
julia_vec = collect(vec)  # Creates a new Julia array
```
"""
Base.collect(vec::RustVec{T}) where {T} = Vector(vec)

"""
    RustVec(v::Vector{T}) -> RustVec{T}

Create a RustVec from a Julia Vector by copying the data to Rust memory.

# Arguments
- `v`: A Julia Vector to convert

# Example
```julia
julia_vec = [1, 2, 3, 4, 5]
rust_vec = RustVec(julia_vec)  # Creates a RustVec{Int32}
```

# Note
This function requires the Rust helpers library to be built.
The data is copied to Rust-managed memory.
"""
function RustVec(v::Vector{T}) where T
    # Check if Rust helpers library is available
    if !is_rust_helpers_available()
        error("""
        RustVec creation from Julia Vector requires the Rust helpers library.
        Build it with: using Pkg; Pkg.build("LastCall")
        """)
    end
    
    lib = get_rust_helpers_lib()
    if lib === nothing
        error("Rust helpers library not loaded")
    end
    
    # Get pointer to data and length
    data_ptr = pointer(v)
    len = length(v)
    
    # Call appropriate FFI function based on type
    if T == Int32
        fn_ptr = Libdl.dlsym(lib, :rust_vec_new_from_array_i32)
        cvec = ccall(fn_ptr, CRustVec, (Ptr{Int32}, UInt), data_ptr, len)
    elseif T == Int64
        fn_ptr = Libdl.dlsym(lib, :rust_vec_new_from_array_i64)
        cvec = ccall(fn_ptr, CRustVec, (Ptr{Int64}, UInt), data_ptr, len)
    elseif T == Float32
        fn_ptr = Libdl.dlsym(lib, :rust_vec_new_from_array_f32)
        cvec = ccall(fn_ptr, CRustVec, (Ptr{Float32}, UInt), data_ptr, len)
    elseif T == Float64
        fn_ptr = Libdl.dlsym(lib, :rust_vec_new_from_array_f64)
        cvec = ccall(fn_ptr, CRustVec, (Ptr{Float64}, UInt), data_ptr, len)
    else
        error("Unsupported type for RustVec creation: $T. Supported types: Int32, Int64, Float32, Float64")
    end
    
    # Create RustVec from CVec
    vec = RustVec{T}(cvec.ptr, UInt(cvec.len), UInt(cvec.cap))
    
    # Set up finalizer to call Rust drop function
    # drop_rust_vec is defined in memory.jl, which is loaded after types.jl
    # We use Base.invokelatest to resolve the function at runtime
    finalizer(vec) do v
        if !v.dropped && v.ptr != C_NULL
            try
                # Use Base.invokelatest to call drop_rust_vec at runtime
                # This ensures memory.jl is loaded when this runs
                Base.invokelatest(drop_rust_vec, v)
            catch e
                # If drop_rust_vec is not available or fails, just mark as dropped
                @warn "Error dropping RustVec in finalizer: $e"
                v.dropped = true
                v.ptr = C_NULL
            end
        end
    end
    
    return vec
end

# Note: Type-specific constructors are not needed because 
# the generic RustVec(v::Vector{T}) handles type inference automatically

# ============================================================================
# Utility functions for ownership types
# ============================================================================

"""
    drop!(x::Union{RustBox, RustRc, RustArc, RustVec})

Mark an ownership type as dropped. The actual memory deallocation
should be handled by Rust-side drop functions.

Note: This sets the dropped flag to prevent double-drop but does not
actually free memory. Call the appropriate Rust drop function for that.
"""
function drop!(x::Union{RustBox, RustRc, RustArc, RustVec})
    x.dropped = true
    x.ptr = C_NULL
    return nothing
end

"""
    is_dropped(x::Union{RustBox, RustRc, RustArc, RustVec}) -> Bool

Check if an ownership type has been dropped.
"""
is_dropped(x::Union{RustBox, RustRc, RustArc, RustVec}) = x.dropped
