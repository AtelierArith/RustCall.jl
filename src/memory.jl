# Memory management for Rust ownership types
# Phase 2: Automatic integration with Rust memory management

using Libdl

# Registry for Rust helper library
const RUST_HELPERS_LIB = Ref{Union{Ptr{Cvoid}, Nothing}}(nothing)

# Flag to track if we've already warned about missing library
const DROP_WARNING_SHOWN = Ref{Bool}(false)

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
        lib_handle = Libdl.dlopen(lib_path, Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW)
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
        lib_handle = Libdl.dlopen(lib_path, Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW)
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
        fn_ptr = Libdl.dlsym(lib, :rust_box_new_i32)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Int32,), value)
        return RustBox{Int32}(ptr)
    elseif T == Int64
        fn_ptr = Libdl.dlsym(lib, :rust_box_new_i64)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Int64,), value)
        return RustBox{Int64}(ptr)
    elseif T == Float32
        fn_ptr = Libdl.dlsym(lib, :rust_box_new_f32)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Float32,), value)
        return RustBox{Float32}(ptr)
    elseif T == Float64
        fn_ptr = Libdl.dlsym(lib, :rust_box_new_f64)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Float64,), value)
        return RustBox{Float64}(ptr)
    elseif T == Bool
        fn_ptr = Libdl.dlsym(lib, :rust_box_new_bool)
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
    if box.dropped || box.ptr == C_NULL
        return nothing
    end

    lib = get_rust_helpers_lib()
    if lib === nothing
        # Only warn once per session to avoid spam
        if !DROP_WARNING_SHOWN[] && !haskey(ENV, "LASTCALL_SUPPRESS_DROP_WARNING")
            @warn "Rust helpers library not loaded. Ownership types (Box, Rc, Arc) will not work properly. Build with: using Pkg; Pkg.build(\"LastCall\")"
            DROP_WARNING_SHOWN[] = true
        end
        box.dropped = true
        return nothing
    end

    # Dispatch based on type
    if T == Int32
        fn_ptr = Libdl.dlsym(lib, :rust_box_drop_i32)
        ccall(fn_ptr, Cvoid, (Ptr{Cvoid},), box.ptr)
    elseif T == Int64
        fn_ptr = Libdl.dlsym(lib, :rust_box_drop_i64)
        ccall(fn_ptr, Cvoid, (Ptr{Cvoid},), box.ptr)
    elseif T == Float32
        fn_ptr = Libdl.dlsym(lib, :rust_box_drop_f32)
        ccall(fn_ptr, Cvoid, (Ptr{Cvoid},), box.ptr)
    elseif T == Float64
        fn_ptr = Libdl.dlsym(lib, :rust_box_drop_f64)
        ccall(fn_ptr, Cvoid, (Ptr{Cvoid},), box.ptr)
    elseif T == Bool
        fn_ptr = Libdl.dlsym(lib, :rust_box_drop_bool)
        ccall(fn_ptr, Cvoid, (Ptr{Cvoid},), box.ptr)
    else
        # Fallback to generic drop (unsafe)
        fn_ptr = Libdl.dlsym(lib, :rust_box_drop)
        ccall(fn_ptr, Cvoid, (Ptr{Cvoid},), box.ptr)
    end

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
        fn_ptr = Libdl.dlsym(lib, :rust_rc_new_i32)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Int32,), value)
        return RustRc{Int32}(ptr)
    elseif T == Int64
        fn_ptr = Libdl.dlsym(lib, :rust_rc_new_i64)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Int64,), value)
        return RustRc{Int64}(ptr)
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
        fn_ptr = Libdl.dlsym(lib, :rust_rc_clone_i32)
        new_ptr = ccall(fn_ptr, Ptr{Cvoid}, (Ptr{Cvoid},), rc.ptr)
        return RustRc{Int32}(new_ptr)
    elseif T == Int64
        fn_ptr = Libdl.dlsym(lib, :rust_rc_clone_i64)
        new_ptr = ccall(fn_ptr, Ptr{Cvoid}, (Ptr{Cvoid},), rc.ptr)
        return RustRc{Int64}(new_ptr)
    else
        error("Unsupported type for RustRc clone: $T")
    end
end

"""
    drop_rust_rc(rc::RustRc{T}) where T

Drop a RustRc, decrementing the reference count.
"""
function drop_rust_rc(rc::RustRc{T}) where T
    if rc.dropped || rc.ptr == C_NULL
        return nothing
    end

    lib = get_rust_helpers_lib()
    if lib === nothing
        # Only warn once per session to avoid spam
        if !DROP_WARNING_SHOWN[] && !haskey(ENV, "LASTCALL_SUPPRESS_DROP_WARNING")
            @warn "Rust helpers library not loaded. Ownership types (Box, Rc, Arc) will not work properly. Build with: using Pkg; Pkg.build(\"LastCall\")"
            DROP_WARNING_SHOWN[] = true
        end
        rc.dropped = true
        return nothing
    end

    if T == Int32
        fn_ptr = Libdl.dlsym(lib, :rust_rc_drop_i32)
        ccall(fn_ptr, Cvoid, (Ptr{Cvoid},), rc.ptr)
    elseif T == Int64
        fn_ptr = Libdl.dlsym(lib, :rust_rc_drop_i64)
        ccall(fn_ptr, Cvoid, (Ptr{Cvoid},), rc.ptr)
    else
        error("Unsupported type for RustRc drop: $T")
    end

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
        fn_ptr = Libdl.dlsym(lib, :rust_arc_new_i32)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Int32,), value)
        return RustArc{Int32}(ptr)
    elseif T == Int64
        fn_ptr = Libdl.dlsym(lib, :rust_arc_new_i64)
        ptr = ccall(fn_ptr, Ptr{Cvoid}, (Int64,), value)
        return RustArc{Int64}(ptr)
    elseif T == Float64
        fn_ptr = Libdl.dlsym(lib, :rust_arc_new_f64)
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
        fn_ptr = Libdl.dlsym(lib, :rust_arc_clone_i32)
        new_ptr = ccall(fn_ptr, Ptr{Cvoid}, (Ptr{Cvoid},), arc.ptr)
        return RustArc{Int32}(new_ptr)
    elseif T == Int64
        fn_ptr = Libdl.dlsym(lib, :rust_arc_clone_i64)
        new_ptr = ccall(fn_ptr, Ptr{Cvoid}, (Ptr{Cvoid},), arc.ptr)
        return RustArc{Int64}(new_ptr)
    elseif T == Float64
        fn_ptr = Libdl.dlsym(lib, :rust_arc_clone_f64)
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
    if arc.dropped || arc.ptr == C_NULL
        return nothing
    end

    lib = get_rust_helpers_lib()
    if lib === nothing
        # Only warn once per session to avoid spam
        if !DROP_WARNING_SHOWN[] && !haskey(ENV, "LASTCALL_SUPPRESS_DROP_WARNING")
            @warn "Rust helpers library not loaded. Ownership types (Box, Rc, Arc) will not work properly. Build with: using Pkg; Pkg.build(\"LastCall\")"
            DROP_WARNING_SHOWN[] = true
        end
        arc.dropped = true
        return nothing
    end

    if T == Int32
        fn_ptr = Libdl.dlsym(lib, :rust_arc_drop_i32)
        ccall(fn_ptr, Cvoid, (Ptr{Cvoid},), arc.ptr)
    elseif T == Int64
        fn_ptr = Libdl.dlsym(lib, :rust_arc_drop_i64)
        ccall(fn_ptr, Cvoid, (Ptr{Cvoid},), arc.ptr)
    elseif T == Float64
        fn_ptr = Libdl.dlsym(lib, :rust_arc_drop_f64)
        ccall(fn_ptr, Cvoid, (Ptr{Cvoid},), arc.ptr)
    else
        error("Unsupported type for RustArc drop: $T")
    end

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

# RustArc constructors
RustArc(value::Int32) = create_rust_arc(value)
RustArc(value::Int64) = create_rust_arc(value)
RustArc(value::Float64) = create_rust_arc(value)

# ============================================================================
# Update finalizers to call Rust drop functions
# ============================================================================

# Update RustBox finalizer
function update_box_finalizer(box::RustBox{T}) where T
    finalizer(box) do b
        if !b.dropped && b.ptr != C_NULL
            try
                drop_rust_box(b)
            catch e
                @warn "Error dropping RustBox in finalizer: $e"
            end
        end
    end
end

# Update RustRc finalizer
function update_rc_finalizer(rc::RustRc{T}) where T
    finalizer(rc) do r
        if !r.dropped && r.ptr != C_NULL
            try
                drop_rust_rc(r)
            catch e
                @warn "Error dropping RustRc in finalizer: $e"
            end
        end
    end
end

# Update RustArc finalizer
function update_arc_finalizer(arc::RustArc{T}) where T
    finalizer(arc) do a
        if !a.dropped && a.ptr != C_NULL
            try
                drop_rust_arc(a)
            catch e
                @warn "Error dropping RustArc in finalizer: $e"
            end
        end
    end
end

# ============================================================================
# RustVec drop functions
# ============================================================================

"""
    drop_rust_vec(vec::RustVec{T}) -> Nothing

Drop a RustVec by calling the Rust-side drop function.
"""
function drop_rust_vec(vec::RustVec{T}) where {T}
    if vec.dropped || vec.ptr == C_NULL
        return nothing
    end

    lib = get_rust_helpers_lib()
    if lib === nothing
        # Only warn once per session to avoid spam
        if !DROP_WARNING_SHOWN[] && !haskey(ENV, "LASTCALL_SUPPRESS_DROP_WARNING")
            @warn "Rust helpers library not loaded. Cannot properly drop RustVec. Build with: using Pkg; Pkg.build(\"LastCall\")"
            DROP_WARNING_SHOWN[] = true
        end
        vec.dropped = true
        return nothing
    end

    # Convert RustVec to CVec for FFI
    # CRustVec is defined in types.jl, which is loaded before memory.jl
    cvec = CRustVec(vec.ptr, vec.len, vec.cap)

    if T == Int32
        fn_ptr = Libdl.dlsym(lib, :rust_vec_drop_i32)
        ccall(fn_ptr, Cvoid, (CRustVec,), cvec)
    elseif T == Int64
        # Note: rust_vec_drop_i64 is not yet implemented in Rust helpers
        # For now, we'll just mark as dropped
        @warn "rust_vec_drop_i64 not yet implemented, just marking as dropped"
    elseif T == Float32
        # Note: rust_vec_drop_f32 is not yet implemented in Rust helpers
        @warn "rust_vec_drop_f32 not yet implemented, just marking as dropped"
    elseif T == Float64
        # Note: rust_vec_drop_f64 is not yet implemented in Rust helpers
        @warn "rust_vec_drop_f64 not yet implemented, just marking as dropped"
    else
        error("Unsupported type for RustVec drop: $T. Supported types: Int32, Int64, Float32, Float64")
    end

    vec.dropped = true
    vec.ptr = C_NULL
    return nothing
end

# Override drop! for RustVec
function drop!(vec::RustVec{T}) where {T}
    drop_rust_vec(vec)
end
