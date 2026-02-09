# Memory management for Rust ownership types
# Phase 2: Automatic integration with Rust memory management

using Libdl

# Registry for Rust helper library
const RUST_HELPERS_LIB = Ref{Union{Ptr{Cvoid}, Nothing}}(nothing)

"""
    safe_dlsym(lib::Ptr{Cvoid}, sym::Symbol) -> Ptr{Cvoid}

Look up a symbol in a shared library, raising a clear error instead of returning
NULL (which would cause a segfault when passed to `ccall`).
"""
function safe_dlsym(lib::Ptr{Cvoid}, sym::Symbol)
    ptr = Libdl.dlsym(lib, sym; throw_error=false)
    if ptr === nothing || ptr == C_NULL
        error("Symbol :$sym not found in Rust helpers library. " *
              "Try rebuilding with: using Pkg; Pkg.build(\"RustCall\")")
    end
    return ptr
end

# Flag to track if we've already warned about missing library
const DROP_WARNING_SHOWN = Ref{Bool}(false)

# Deferred pointer tracking for cleanup when library becomes available
struct DeferredDrop
    ptr::Ptr{Cvoid}
    type_name::String      # e.g. "RustBox{Int32}"
    drop_symbol::Symbol    # e.g. :rust_box_drop_i32
    # For RustVec, we need len/cap to reconstruct CRustVec
    vec_len::UInt
    vec_cap::UInt
    is_vec::Bool
end

# Convenience constructor for non-vec types
DeferredDrop(ptr::Ptr{Cvoid}, type_name::String, drop_symbol::Symbol) =
    DeferredDrop(ptr, type_name, drop_symbol, UInt(0), UInt(0), false)

const DEFERRED_DROPS = DeferredDrop[]
const DEFERRED_DROPS_LOCK = ReentrantLock()

"""
    _defer_drop(ptr::Ptr{Cvoid}, type_name::String, drop_symbol::Symbol)

Record a pointer for deferred deallocation when the Rust helpers library becomes available.
"""
function _defer_drop(ptr::Ptr{Cvoid}, type_name::String, drop_symbol::Symbol)
    lock(DEFERRED_DROPS_LOCK) do
        push!(DEFERRED_DROPS, DeferredDrop(ptr, type_name, drop_symbol))
    end
    @warn "Deferring drop for $type_name at $ptr — Rust helpers library unavailable. " *
          "Build with: using Pkg; Pkg.build(\"RustCall\")" maxlog=10
end

"""
    _defer_vec_drop(ptr::Ptr{Cvoid}, len::UInt, cap::UInt, type_name::String, drop_symbol::Symbol)

Record a RustVec pointer for deferred deallocation (needs len/cap for CRustVec reconstruction).
"""
function _defer_vec_drop(ptr::Ptr{Cvoid}, len::UInt, cap::UInt, type_name::String, drop_symbol::Symbol)
    lock(DEFERRED_DROPS_LOCK) do
        push!(DEFERRED_DROPS, DeferredDrop(ptr, type_name, drop_symbol, len, cap, true))
    end
    @warn "Deferring drop for $type_name at $ptr — Rust helpers library unavailable. " *
          "Build with: using Pkg; Pkg.build(\"RustCall\")" maxlog=10
end

"""
    flush_deferred_drops() -> Int

Attempt to free all deferred pointers using the Rust helpers library.
Returns the number of successfully freed pointers.
Call this after rebuilding/reloading the helpers library.
"""
function flush_deferred_drops()
    lib = get_rust_helpers_lib()
    if lib === nothing
        return 0
    end

    drops = lock(DEFERRED_DROPS_LOCK) do
        d = copy(DEFERRED_DROPS)
        empty!(DEFERRED_DROPS)
        d
    end

    freed = 0
    failed = DeferredDrop[]
    for dd in drops
        fn_ptr = Libdl.dlsym(lib, dd.drop_symbol; throw_error=false)
        if fn_ptr !== nothing && fn_ptr != C_NULL
            try
                if dd.is_vec
                    cvec = CRustVec(dd.ptr, dd.vec_len, dd.vec_cap)
                    ccall(fn_ptr, Cvoid, (CRustVec,), cvec)
                else
                    ccall(fn_ptr, Cvoid, (Ptr{Cvoid},), dd.ptr)
                end
                freed += 1
            catch
                push!(failed, dd)
            end
        else
            push!(failed, dd)
        end
    end

    if !isempty(failed)
        lock(DEFERRED_DROPS_LOCK) do
            prepend!(DEFERRED_DROPS, failed)
        end
    end

    if freed > 0
        @info "Flushed $freed deferred drops" remaining=length(failed)
    end

    return freed
end

"""
    deferred_drop_count() -> Int

Return the number of pointers awaiting deferred deallocation.
"""
function deferred_drop_count()
    return lock(DEFERRED_DROPS_LOCK) do
        length(DEFERRED_DROPS)
    end
end

"""
    get_rust_helpers_lib() -> Union{Ptr{Cvoid}, Nothing}

Get or load the Rust helpers library.
This library provides FFI functions for Box, Rc, Arc operations.
Returns nothing if the library is not available.
"""
function get_rust_helpers_lib()
    return RUST_HELPERS_LIB[]
end

"""
    is_rust_helpers_available() -> Bool

Check if the Rust helpers library is available.
"""
function is_rust_helpers_available()
    return RUST_HELPERS_LIB[] !== nothing
end

"""
    load_rust_helpers_lib(lib_path::String)

Load the Rust helpers library from a file path.
"""
function load_rust_helpers_lib(lib_path::String)
    if !isfile(lib_path)
        error("Rust helpers library not found at: $lib_path")
    end

    try
        lib_handle = Libdl.dlopen(lib_path, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
        if lib_handle == C_NULL
            error("Failed to load Rust helpers library: $lib_path (dlopen returned NULL)")
        end
        RUST_HELPERS_LIB[] = lib_handle
        return lib_handle
    catch e
        error("Failed to load Rust helpers library from $lib_path: $e")
    end
end

"""
    get_rust_helpers_lib_path() -> Union{String, Nothing}

Get the path to the Rust helpers library if it exists (either built or in a standard location).
Returns nothing if the library is not found.
"""
function get_rust_helpers_lib_path()
    # Try to find the library relative to the package directory
    # @__DIR__ points to src/, so dirname(@__DIR__) gives package root
    pkg_dir = dirname(@__DIR__)  # Go up from src/ to package root
    deps_dir = joinpath(pkg_dir, "deps")
    helpers_dir = joinpath(deps_dir, "rust_helpers")
    lib_ext = get_library_extension()
    target_dir = joinpath(helpers_dir, "target", "release")

    # Library name
    if Sys.iswindows()
        lib_name = "rust_helpers.dll"
    else
        lib_name = "librust_helpers$(lib_ext)"
    end

    lib_path = joinpath(target_dir, lib_name)

    if isfile(lib_path)
        return lib_path
    end

    # Also try in the deps directory directly (for development)
    alt_path = joinpath(deps_dir, lib_name)
    if isfile(alt_path)
        return alt_path
    end

    return nothing
end

"""
    verify_rust_helpers_functions(lib::Ptr{Cvoid}) -> Bool

Verify that required functions are available in the loaded library.
Returns true if all required functions are found, false otherwise.
"""
function verify_rust_helpers_functions(lib::Ptr{Cvoid})
    # List of required functions (subset of most commonly used ones)
    required_functions = [
        :rust_box_new_i32,
        :rust_box_drop_i32,
        :rust_rc_new_i32,
        :rust_rc_clone_i32,
        :rust_rc_drop_i32,
        :rust_arc_new_i32,
        :rust_arc_clone_i32,
        :rust_arc_drop_i32,
        :rust_vec_new_from_array_i32,
        :rust_vec_drop_i32,
    ]

    missing_functions = String[]
    for func_name in required_functions
        func_ptr = Libdl.dlsym(lib, func_name; throw_error=false)
        if func_ptr === nothing || func_ptr == C_NULL
            push!(missing_functions, string(func_name))
        end
    end

    if !isempty(missing_functions)
        @debug "Missing functions in Rust helpers library: $(join(missing_functions, ", "))"
        return false
    end

    return true
end

"""
    try_load_rust_helpers() -> Bool

Try to load the Rust helpers library. Returns true if successful, false otherwise.
This function will not throw errors, making it safe to call during module initialization.
"""
function try_load_rust_helpers()
    if is_rust_helpers_available()
        return true  # Already loaded
    end

    lib_path = get_rust_helpers_lib_path()
    if lib_path === nothing
        return false  # Library not found
    end

    if !isfile(lib_path)
        return false  # Library file doesn't exist
    end

    try
        lib_handle = Libdl.dlopen(lib_path, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
        if lib_handle == C_NULL
            @debug "Failed to load Rust helpers library: dlopen returned NULL for $lib_path"
            return false
        end

        # Verify that required functions are available
        if !verify_rust_helpers_functions(lib_handle)
            @debug "Rust helpers library loaded but required functions are missing"
            # Don't fail completely - some functions might still work
            # But log the issue for debugging
        end

        RUST_HELPERS_LIB[] = lib_handle
        DROP_WARNING_SHOWN[] = false  # Reset warning flag when library is loaded
        # Flush any deferred drops now that the library is available
        flush_deferred_drops()
        return true
    catch e
        @debug "Failed to load Rust helpers library from $lib_path: $e"
        return false
    end
end

# ============================================================================
# Box<T> creation and management
# ============================================================================

"""
    create_rust_box(value::T) -> RustBox{T} where T

Create a RustBox from a Julia value.
Automatically calls the appropriate Rust Box::new function.
"""
function create_rust_box(value::T) where T
    if !is_rust_helpers_available()
        error("Rust helpers library not loaded. Cannot create RustBox. Please compile deps/rust_helpers.")
    end

    lib = get_rust_helpers_lib()

    # Dispatch based on type - use dlsym to get function pointer
    if T == Int32
        fn_ptr = safe_dlsym(lib, :rust_box_new_i32)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Int32,), value)
        return RustBox{Int32}(ptr)
    elseif T == Int64
        fn_ptr = safe_dlsym(lib, :rust_box_new_i64)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Int64,), value)
        return RustBox{Int64}(ptr)
    elseif T == Float32
        fn_ptr = safe_dlsym(lib, :rust_box_new_f32)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Float32,), value)
        return RustBox{Float32}(ptr)
    elseif T == Float64
        fn_ptr = safe_dlsym(lib, :rust_box_new_f64)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Float64,), value)
        return RustBox{Float64}(ptr)
    elseif T == Bool
        fn_ptr = safe_dlsym(lib, :rust_box_new_bool)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Bool,), value)
        return RustBox{Bool}(ptr)
    else
        error("Unsupported type for RustBox: $T")
    end
end

"""
    drop_rust_box(box::RustBox{T}) where T

Drop a RustBox, calling the appropriate Rust drop function.
"""
function drop_rust_box(box::RustBox{T}) where T
    if box.dropped
        @debug "Attempted to drop an already-dropped RustBox{$T}"
        return nothing
    end
    if box.ptr == C_NULL
        return nothing
    end

    # Determine the drop symbol for this type
    drop_sym = if T == Int32
        :rust_box_drop_i32
    elseif T == Int64
        :rust_box_drop_i64
    elseif T == Float32
        :rust_box_drop_f32
    elseif T == Float64
        :rust_box_drop_f64
    elseif T == Bool
        :rust_box_drop_bool
    else
        :rust_box_drop
    end

    lib = get_rust_helpers_lib()
    if lib === nothing
        _defer_drop(box.ptr, "RustBox{$T}", drop_sym)
        box.dropped = true
        return nothing
    end

    fn_ptr = safe_dlsym(lib, drop_sym)
    ccall(fn_ptr, Cvoid, (Ptr{Cvoid},), box.ptr)

    box.dropped = true
    box.ptr = C_NULL
    return nothing
end

# Override drop! for RustBox to call Rust drop
function drop!(box::RustBox{T}) where T
    drop_rust_box(box)
end

# ============================================================================
# Rc<T> creation and management
# ============================================================================

"""
    create_rust_rc(value::T) -> RustRc{T} where T

Create a RustRc from a Julia value.
Automatically calls the appropriate Rust Rc::new function.
"""
function create_rust_rc(value::T) where T
    if !is_rust_helpers_available()
        error("Rust helpers library not loaded. Cannot create RustRc. Please compile deps/rust_helpers.")
    end

    lib = get_rust_helpers_lib()

    if T == Int32
        fn_ptr = safe_dlsym(lib, :rust_rc_new_i32)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Int32,), value)
        return RustRc{Int32}(ptr)
    elseif T == Int64
        fn_ptr = safe_dlsym(lib, :rust_rc_new_i64)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Int64,), value)
        return RustRc{Int64}(ptr)
    elseif T == Float32
        fn_ptr = safe_dlsym(lib, :rust_rc_new_f32)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Float32,), value)
        return RustRc{Float32}(ptr)
    elseif T == Float64
        fn_ptr = safe_dlsym(lib, :rust_rc_new_f64)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Float64,), value)
        return RustRc{Float64}(ptr)
    else
        error("Unsupported type for RustRc: $T")
    end
end

"""
    clone(rc::RustRc{T}) -> RustRc{T} where T

Clone a RustRc, incrementing the reference count.
"""
function clone(rc::RustRc{T}) where T
    if rc.dropped || rc.ptr == C_NULL
        error("Cannot clone a dropped RustRc")
    end

    if !is_rust_helpers_available()
        error("Rust helpers library not loaded. Cannot clone RustRc.")
    end

    lib = get_rust_helpers_lib()

    # Use type-specific clone functions
    if T == Int32
        fn_ptr = safe_dlsym(lib, :rust_rc_clone_i32)
        new_ptr = ccall(fn_ptr, Ptr{Cvoid}, (Ptr{Cvoid},), rc.ptr)
        return RustRc{Int32}(new_ptr)
    elseif T == Int64
        fn_ptr = safe_dlsym(lib, :rust_rc_clone_i64)
        new_ptr = ccall(fn_ptr, Ptr{Cvoid}, (Ptr{Cvoid},), rc.ptr)
        return RustRc{Int64}(new_ptr)
    elseif T == Float32
        fn_ptr = safe_dlsym(lib, :rust_rc_clone_f32)
        new_ptr = ccall(fn_ptr, Ptr{Cvoid}, (Ptr{Cvoid},), rc.ptr)
        return RustRc{Float32}(new_ptr)
    elseif T == Float64
        fn_ptr = safe_dlsym(lib, :rust_rc_clone_f64)
        new_ptr = ccall(fn_ptr, Ptr{Cvoid}, (Ptr{Cvoid},), rc.ptr)
        return RustRc{Float64}(new_ptr)
    else
        error("Unsupported type for RustRc clone: $T")
    end
end

"""
    drop_rust_rc(rc::RustRc{T}) where T

Drop a RustRc, decrementing the reference count.
"""
function drop_rust_rc(rc::RustRc{T}) where T
    if rc.dropped
        @debug "Attempted to drop an already-dropped RustRc{$T}"
        return nothing
    end
    if rc.ptr == C_NULL
        return nothing
    end

    drop_sym = if T == Int32
        :rust_rc_drop_i32
    elseif T == Int64
        :rust_rc_drop_i64
    elseif T == Float32
        :rust_rc_drop_f32
    elseif T == Float64
        :rust_rc_drop_f64
    else
        error("Unsupported type for RustRc drop: $T")
    end

    lib = get_rust_helpers_lib()
    if lib === nothing
        _defer_drop(rc.ptr, "RustRc{$T}", drop_sym)
        rc.dropped = true
        return nothing
    end

    fn_ptr = safe_dlsym(lib, drop_sym)
    ccall(fn_ptr, Cvoid, (Ptr{Cvoid},), rc.ptr)

    rc.dropped = true
    rc.ptr = C_NULL
    return nothing
end

# Override drop! for RustRc
function drop!(rc::RustRc{T}) where T
    drop_rust_rc(rc)
end

# ============================================================================
# Arc<T> creation and management
# ============================================================================

"""
    create_rust_arc(value::T) -> RustArc{T} where T

Create a RustArc from a Julia value.
Automatically calls the appropriate Rust Arc::new function.
"""
function create_rust_arc(value::T) where T
    if !is_rust_helpers_available()
        error("Rust helpers library not loaded. Cannot create RustArc. Please compile deps/rust_helpers.")
    end

    lib = get_rust_helpers_lib()

    if T == Int32
        fn_ptr = safe_dlsym(lib, :rust_arc_new_i32)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Int32,), value)
        return RustArc{Int32}(ptr)
    elseif T == Int64
        fn_ptr = safe_dlsym(lib, :rust_arc_new_i64)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Int64,), value)
        return RustArc{Int64}(ptr)
    elseif T == Float32
        fn_ptr = safe_dlsym(lib, :rust_arc_new_f32)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Float32,), value)
        return RustArc{Float32}(ptr)
    elseif T == Float64
        fn_ptr = safe_dlsym(lib, :rust_arc_new_f64)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Float64,), value)
        return RustArc{Float64}(ptr)
    else
        error("Unsupported type for RustArc: $T")
    end
end

"""
    clone(arc::RustArc{T}) -> RustArc{T} where T

Clone a RustArc, incrementing the atomic reference count.
"""
function clone(arc::RustArc{T}) where T
    if arc.dropped || arc.ptr == C_NULL
        error("Cannot clone a dropped RustArc")
    end

    if !is_rust_helpers_available()
        error("Rust helpers library not loaded. Cannot clone RustArc.")
    end

    lib = get_rust_helpers_lib()

    # Use type-specific clone functions
    if T == Int32
        fn_ptr = safe_dlsym(lib, :rust_arc_clone_i32)
        new_ptr = ccall(fn_ptr, Ptr{Cvoid}, (Ptr{Cvoid},), arc.ptr)
        return RustArc{Int32}(new_ptr)
    elseif T == Int64
        fn_ptr = safe_dlsym(lib, :rust_arc_clone_i64)
        new_ptr = ccall(fn_ptr, Ptr{Cvoid}, (Ptr{Cvoid},), arc.ptr)
        return RustArc{Int64}(new_ptr)
    elseif T == Float32
        fn_ptr = safe_dlsym(lib, :rust_arc_clone_f32)
        new_ptr = ccall(fn_ptr, Ptr{Cvoid}, (Ptr{Cvoid},), arc.ptr)
        return RustArc{Float32}(new_ptr)
    elseif T == Float64
        fn_ptr = safe_dlsym(lib, :rust_arc_clone_f64)
        new_ptr = ccall(fn_ptr, Ptr{Cvoid}, (Ptr{Cvoid},), arc.ptr)
        return RustArc{Float64}(new_ptr)
    else
        error("Unsupported type for RustArc clone: $T")
    end
end

"""
    drop_rust_arc(arc::RustArc{T}) where T

Drop a RustArc, decrementing the atomic reference count.
"""
function drop_rust_arc(arc::RustArc{T}) where T
    if arc.dropped
        @debug "Attempted to drop an already-dropped RustArc{$T}"
        return nothing
    end
    if arc.ptr == C_NULL
        return nothing
    end

    drop_sym = if T == Int32
        :rust_arc_drop_i32
    elseif T == Int64
        :rust_arc_drop_i64
    elseif T == Float32
        :rust_arc_drop_f32
    elseif T == Float64
        :rust_arc_drop_f64
    else
        error("Unsupported type for RustArc drop: $T")
    end

    lib = get_rust_helpers_lib()
    if lib === nothing
        _defer_drop(arc.ptr, "RustArc{$T}", drop_sym)
        arc.dropped = true
        return nothing
    end

    fn_ptr = safe_dlsym(lib, drop_sym)
    ccall(fn_ptr, Cvoid, (Ptr{Cvoid},), arc.ptr)

    arc.dropped = true
    arc.ptr = C_NULL
    return nothing
end

# Override drop! for RustArc
function drop!(arc::RustArc{T}) where T
    drop_rust_arc(arc)
end

# ============================================================================
# Convenience constructors
# ============================================================================

# RustBox constructors
RustBox(value::Int32) = create_rust_box(value)
RustBox(value::Int64) = create_rust_box(value)
RustBox(value::Float32) = create_rust_box(value)
RustBox(value::Float64) = create_rust_box(value)
RustBox(value::Bool) = create_rust_box(value)

# RustRc constructors
RustRc(value::Int32) = create_rust_rc(value)
RustRc(value::Int64) = create_rust_rc(value)
RustRc(value::Float32) = create_rust_rc(value)
RustRc(value::Float64) = create_rust_rc(value)

# RustArc constructors
RustArc(value::Int32) = create_rust_arc(value)
RustArc(value::Int64) = create_rust_arc(value)
RustArc(value::Float32) = create_rust_arc(value)
RustArc(value::Float64) = create_rust_arc(value)

# ============================================================================
# RustVec drop functions
# ============================================================================

"""
    drop_rust_vec(vec::RustVec{T}) -> Nothing

Drop a RustVec by calling the Rust-side drop function.
"""
function drop_rust_vec(vec::RustVec{T}) where {T}
    if vec.dropped
        @debug "Attempted to drop an already-dropped RustVec{$T}"
        return nothing
    end
    if vec.ptr == C_NULL
        return nothing
    end

    drop_sym = if T == Int32
        :rust_vec_drop_i32
    elseif T == Int64
        :rust_vec_drop_i64
    elseif T == Float32
        :rust_vec_drop_f32
    elseif T == Float64
        :rust_vec_drop_f64
    else
        error("Unsupported type for RustVec drop: $T. Supported types: Int32, Int64, Float32, Float64")
    end

    lib = get_rust_helpers_lib()
    if lib === nothing
        _defer_vec_drop(vec.ptr, UInt(vec.len), UInt(vec.cap), "RustVec{$T}", drop_sym)
        vec.dropped = true
        return nothing
    end

    cvec = CRustVec(vec.ptr, vec.len, vec.cap)
    fn_ptr = safe_dlsym(lib, drop_sym)
    ccall(fn_ptr, Cvoid, (CRustVec,), cvec)

    vec.dropped = true
    vec.ptr = C_NULL
    return nothing
end

# Override drop! for RustVec
function drop!(vec::RustVec{T}) where {T}
    drop_rust_vec(vec)
end

# ============================================================================
# RustVec creation from Julia arrays
# ============================================================================

"""
    create_rust_vec(v::Vector{T}) -> RustVec{T}

Create a `RustVec` from a Julia `Vector` by copying data to Rust-managed memory.

# Arguments
- `v::Vector{T}`: A Julia Vector to convert. Supported types: `Int32`, `Int64`, `Float32`, `Float64`

# Returns
- `RustVec{T}`: A new RustVec containing a copy of the data

# Throws
- `ErrorException`: If the Rust helpers library is not loaded
- `ErrorException`: If the element type is not supported

# Example
```julia
julia_vec = Int32[1, 2, 3, 4, 5]
rust_vec = create_rust_vec(julia_vec)
@assert length(rust_vec) == 5
drop!(rust_vec)  # Clean up when done
```

# Note
The data is copied to Rust-managed memory. The original Julia array is not modified.
Remember to call `drop!(rust_vec)` when done to free Rust memory.

See also: [`to_julia_vector`](@ref), [`drop!`](@ref)
"""
function create_rust_vec(v::Vector{T}) where T
    if !is_rust_helpers_available()
        error("Rust helpers library not loaded. Cannot create RustVec. Please compile deps/rust_helpers.")
    end

    lib = get_rust_helpers_lib()
    data_ptr = pointer(v)
    len = length(v)

    if T == Int32
        fn_ptr = safe_dlsym(lib, :rust_vec_new_from_array_i32)
        cvec = ccall(fn_ptr, CRustVec, (Ptr{Int32}, UInt), data_ptr, len)
    elseif T == Int64
        fn_ptr = safe_dlsym(lib, :rust_vec_new_from_array_i64)
        cvec = ccall(fn_ptr, CRustVec, (Ptr{Int64}, UInt), data_ptr, len)
    elseif T == Float32
        fn_ptr = safe_dlsym(lib, :rust_vec_new_from_array_f32)
        cvec = ccall(fn_ptr, CRustVec, (Ptr{Float32}, UInt), data_ptr, len)
    elseif T == Float64
        fn_ptr = safe_dlsym(lib, :rust_vec_new_from_array_f64)
        cvec = ccall(fn_ptr, CRustVec, (Ptr{Float64}, UInt), data_ptr, len)
    else
        error("Unsupported type for RustVec: $T. Supported types: Int32, Int64, Float32, Float64")
    end

    return RustVec{T}(cvec.ptr, UInt(cvec.len), UInt(cvec.cap))
end

# ============================================================================
# RustVec element access via Rust FFI
# ============================================================================

"""
    rust_vec_get(vec::RustVec{T}, index::Integer) -> T

Get an element from `RustVec` using Rust FFI with **0-based indexing**.

# Arguments
- `vec::RustVec{T}`: The RustVec to access
- `index::Integer`: 0-based index of the element to retrieve

# Returns
- `T`: The element at the specified index

# Throws
- `ErrorException`: If the vec has been dropped
- `BoundsError`: If index is out of bounds
- `ErrorException`: If the Rust helpers library is not loaded

# Example
```julia
rust_vec = create_rust_vec(Int32[10, 20, 30])
value = rust_vec_get(rust_vec, 0)  # Returns 10
value = rust_vec_get(rust_vec, 2)  # Returns 30
drop!(rust_vec)
```

# Note
This function uses **0-based indexing** to match Rust's convention.
For 1-based indexing, use `vec[i]` syntax instead.

See also: [`rust_vec_set!`](@ref), `getindex`
"""
function rust_vec_get(vec::RustVec{T}, index::Integer) where T
    if vec.dropped || vec.ptr == C_NULL
        error("Cannot access a dropped RustVec")
    end
    if index < 0 || index >= vec.len
        throw(BoundsError(vec, index + 1))  # Convert to 1-indexed for error
    end

    if !is_rust_helpers_available()
        error("Rust helpers library not loaded")
    end

    lib = get_rust_helpers_lib()
    cvec = CRustVec(vec.ptr, vec.len, vec.cap)

    if T == Int32
        fn_ptr = safe_dlsym(lib, :rust_vec_get_i32)
        return ccall(fn_ptr, Int32, (CRustVec, UInt), cvec, index)
    elseif T == Int64
        fn_ptr = safe_dlsym(lib, :rust_vec_get_i64)
        return ccall(fn_ptr, Int64, (CRustVec, UInt), cvec, index)
    elseif T == Float32
        fn_ptr = safe_dlsym(lib, :rust_vec_get_f32)
        return ccall(fn_ptr, Float32, (CRustVec, UInt), cvec, index)
    elseif T == Float64
        fn_ptr = safe_dlsym(lib, :rust_vec_get_f64)
        return ccall(fn_ptr, Float64, (CRustVec, UInt), cvec, index)
    else
        error("Unsupported type for RustVec get: $T")
    end
end

"""
    rust_vec_set!(vec::RustVec{T}, index::Integer, value::T) -> Bool

Set an element in RustVec using Rust FFI (0-indexed).
Returns true if successful.
"""
function rust_vec_set!(vec::RustVec{T}, index::Integer, value::T) where T
    if vec.dropped || vec.ptr == C_NULL
        error("Cannot modify a dropped RustVec")
    end
    if index < 0 || index >= vec.len
        throw(BoundsError(vec, index + 1))
    end

    if !is_rust_helpers_available()
        error("Rust helpers library not loaded")
    end

    lib = get_rust_helpers_lib()
    cvec = CRustVec(vec.ptr, vec.len, vec.cap)

    if T == Int32
        fn_ptr = safe_dlsym(lib, :rust_vec_set_i32)
        result = ccall(fn_ptr, UInt8, (CRustVec, UInt, Int32), cvec, index, value)
        return Bool(result != 0x00)
    elseif T == Int64
        fn_ptr = safe_dlsym(lib, :rust_vec_set_i64)
        result = ccall(fn_ptr, UInt8, (CRustVec, UInt, Int64), cvec, index, value)
        return Bool(result != 0x00)
    elseif T == Float32
        fn_ptr = safe_dlsym(lib, :rust_vec_set_f32)
        result = ccall(fn_ptr, UInt8, (CRustVec, UInt, Float32), cvec, index, value)
        return Bool(result != 0x00)
    elseif T == Float64
        fn_ptr = safe_dlsym(lib, :rust_vec_set_f64)
        result = ccall(fn_ptr, UInt8, (CRustVec, UInt, Float64), cvec, index, value)
        return Bool(result != 0x00)
    else
        error("Unsupported type for RustVec set: $T")
    end
end

# ============================================================================
# RustVec push operations
# ============================================================================

"""
    push!(vec::RustVec{T}, value::T) -> RustVec{T}

Push a value to RustVec. Note: This modifies the vec in place by updating
its internal pointer, length, and capacity.
"""
function Base.push!(vec::RustVec{T}, value::T) where T
    if vec.dropped
        error("Cannot push to a dropped RustVec")
    end

    if !is_rust_helpers_available()
        error("Rust helpers library not loaded")
    end

    lib = get_rust_helpers_lib()
    cvec = CRustVec(vec.ptr, vec.len, vec.cap)

    if T == Int32
        fn_ptr = safe_dlsym(lib, :rust_vec_push_i32)
        new_cvec = ccall(fn_ptr, CRustVec, (CRustVec, Int32), cvec, value)
    elseif T == Int64
        fn_ptr = safe_dlsym(lib, :rust_vec_push_i64)
        new_cvec = ccall(fn_ptr, CRustVec, (CRustVec, Int64), cvec, value)
    elseif T == Float32
        fn_ptr = safe_dlsym(lib, :rust_vec_push_f32)
        new_cvec = ccall(fn_ptr, CRustVec, (CRustVec, Float32), cvec, value)
    elseif T == Float64
        fn_ptr = safe_dlsym(lib, :rust_vec_push_f64)
        new_cvec = ccall(fn_ptr, CRustVec, (CRustVec, Float64), cvec, value)
    else
        error("Unsupported type for RustVec push: $T")
    end

    # Update vec in place
    vec.ptr = new_cvec.ptr
    vec.len = UInt(new_cvec.len)
    vec.cap = UInt(new_cvec.cap)

    return vec
end

# ============================================================================
# RustVec copy to Julia array
# ============================================================================

"""
    copy_to_julia!(vec::RustVec{T}, dest::Vector{T}) -> Int

Copy `RustVec` contents to a pre-allocated Julia `Vector` using efficient Rust FFI.

This is the most efficient way to transfer data from Rust to Julia when you already
have a destination buffer allocated.

# Arguments
- `vec::RustVec{T}`: Source RustVec to copy from
- `dest::Vector{T}`: Pre-allocated destination Julia Vector

# Returns
- `Int`: Number of elements actually copied (min of source and dest lengths)

# Throws
- `ErrorException`: If the vec has been dropped
- `ErrorException`: If the Rust helpers library is not loaded

# Example
```julia
rust_vec = create_rust_vec(Int32[1, 2, 3, 4, 5])

# Copy all elements
dest = Vector{Int32}(undef, 5)
n = copy_to_julia!(rust_vec, dest)
@assert n == 5 && dest == Int32[1, 2, 3, 4, 5]

# Copy to smaller buffer (partial copy)
small_dest = Vector{Int32}(undef, 3)
n = copy_to_julia!(rust_vec, small_dest)
@assert n == 3 && small_dest == Int32[1, 2, 3]

drop!(rust_vec)
```

# Performance
This function uses a single FFI call to copy all data, making it much more
efficient than element-by-element access for large vectors.

See also: [`to_julia_vector`](@ref), [`create_rust_vec`](@ref)
"""
function copy_to_julia!(vec::RustVec{T}, dest::Vector{T}) where T
    if vec.dropped || vec.ptr == C_NULL
        error("Cannot copy from a dropped RustVec")
    end

    if !is_rust_helpers_available()
        error("Rust helpers library not loaded")
    end

    lib = get_rust_helpers_lib()
    cvec = CRustVec(vec.ptr, vec.len, vec.cap)
    dest_ptr = pointer(dest)
    dest_len = length(dest)

    if T == Int32
        fn_ptr = safe_dlsym(lib, :rust_vec_copy_to_array_i32)
        return Int(ccall(fn_ptr, UInt, (CRustVec, Ptr{Int32}, UInt), cvec, dest_ptr, dest_len))
    elseif T == Int64
        fn_ptr = safe_dlsym(lib, :rust_vec_copy_to_array_i64)
        return Int(ccall(fn_ptr, UInt, (CRustVec, Ptr{Int64}, UInt), cvec, dest_ptr, dest_len))
    elseif T == Float32
        fn_ptr = safe_dlsym(lib, :rust_vec_copy_to_array_f32)
        return Int(ccall(fn_ptr, UInt, (CRustVec, Ptr{Float32}, UInt), cvec, dest_ptr, dest_len))
    elseif T == Float64
        fn_ptr = safe_dlsym(lib, :rust_vec_copy_to_array_f64)
        return Int(ccall(fn_ptr, UInt, (CRustVec, Ptr{Float64}, UInt), cvec, dest_ptr, dest_len))
    else
        error("Unsupported type for RustVec copy: $T")
    end
end

"""
    to_julia_vector(vec::RustVec{T}) -> Vector{T}

Convert a `RustVec` to a new Julia `Vector` using efficient Rust FFI copy.

This is the recommended way to convert `RustVec` data to Julia when you don't
have a pre-allocated buffer.

# Arguments
- `vec::RustVec{T}`: The RustVec to convert

# Returns
- `Vector{T}`: A new Julia Vector containing a copy of the data

# Throws
- `ErrorException`: If the vec has been dropped

# Example
```julia
rust_vec = create_rust_vec(Int32[1, 2, 3, 4, 5])
julia_vec = to_julia_vector(rust_vec)
@assert julia_vec == Int32[1, 2, 3, 4, 5]
drop!(rust_vec)
```

# Note
This function allocates a new Julia Vector. If you already have a buffer,
use `copy_to_julia!` instead for better performance.

See also: [`copy_to_julia!`](@ref), [`create_rust_vec`](@ref)
"""
function to_julia_vector(vec::RustVec{T}) where T
    if vec.dropped || vec.ptr == C_NULL
        error("Cannot convert a dropped RustVec to a Vector")
    end

    result = Vector{T}(undef, vec.len)
    if vec.len > 0
        copy_to_julia!(vec, result)
    end
    return result
end
