# Generic function support for RustCall.jl
# Phase 2: Monomorphization and type parameter inference

# Import required functions and constants from other modules
# These will be available when this file is included after ruststr.jl and codegen.jl

"""
    TraitBound

Represents a single trait bound with optional type parameters.

# Fields
- `trait_name::String`: Name of the trait (e.g., "Copy", "Add")
- `type_params::Vector{String}`: Type parameters for the trait (e.g., ["Output = T"] for Add<Output = T>)
"""
struct TraitBound
    trait_name::String
    type_params::Vector{String}
end

function Base.show(io::IO, tb::TraitBound)
    if isempty(tb.type_params)
        print(io, tb.trait_name)
    else
        print(io, tb.trait_name, "<", join(tb.type_params, ", "), ">")
    end
end

function Base.:(==)(a::TraitBound, b::TraitBound)
    a.trait_name == b.trait_name && a.type_params == b.type_params
end

"""
    TypeConstraints

Represents all trait bounds for a type parameter.

# Fields
- `bounds::Vector{TraitBound}`: List of trait bounds (e.g., [Copy, Clone, Add<Output = T>])
"""
struct TypeConstraints
    bounds::Vector{TraitBound}
end

TypeConstraints() = TypeConstraints(TraitBound[])

function Base.show(io::IO, tc::TypeConstraints)
    print(io, join(string.(tc.bounds), " + "))
end

function Base.isempty(tc::TypeConstraints)
    isempty(tc.bounds)
end

function Base.:(==)(a::TypeConstraints, b::TypeConstraints)
    a.bounds == b.bounds
end

"""
    GenericFunctionInfo

Information about a generic Rust function that needs monomorphization.
"""
struct GenericFunctionInfo
    name::String
    code::String
    type_params::Vector{Symbol}  # e.g., [:T, :U]
    constraints::Dict{Symbol, TypeConstraints}  # e.g., :T => TypeConstraints([Copy, Clone])
    context::String  # Additional code (e.g., struct definitions) needed for compilation
    arg_types::Vector{String}  # Rust argument types as recorded in the manifest (e.g. ["T", "i32"])
    return_type::String  # Rust return type as recorded in the manifest
    path::String  # Qualified name inside `code` (`api::deep::f`); equals `name` at the file root
    compiler::Union{Nothing, RustCompiler}  # compiler the block was expanded for (nothing: default)
end

"""
Registry for generic functions.
Maps function name to GenericFunctionInfo.
"""
const GENERIC_FUNCTION_REGISTRY = Dict{String, GenericFunctionInfo}()

"""
Registry for monomorphized function instances.
Maps (function_name, type_params_tuple) to FunctionInfo.
"""
const MONOMORPHIZED_FUNCTIONS = Dict{Tuple{String, Tuple}, FunctionInfo}()

# ============================================================================
# Julia -> Rust type names for monomorphization
# ============================================================================

const _JULIA_TO_RUST_TYPE = Dict{Type, String}(
    Int8 => "i8", Int16 => "i16", Int32 => "i32", Int64 => "i64",
    UInt8 => "u8", UInt16 => "u16", UInt32 => "u32", UInt64 => "u64",
    Float32 => "f32", Float64 => "f64",
    Bool => "bool",
    String => "*const u8",
    Cstring => "*const u8",
)

"""
    julia_type_to_rust_string(jt::Type) -> String

Rust spelling of a Julia type used to instantiate a generic parameter
(`Int32 -> "i32"`, `Point{Float64} -> "Point<f64>"`). Throws for unsupported types.
"""
function julia_type_to_rust_string(jt::Type)
    haskey(_JULIA_TO_RUST_TYPE, jt) && return _JULIA_TO_RUST_TYPE[jt]
    if jt isa DataType && !isempty(jt.parameters) && all(p -> p isa Type, jt.parameters)
        base = String(nameof(jt))
        params = join((julia_type_to_rust_string(p) for p in jt.parameters), ", ")
        return "$base<$params>"
    end
    error("Unsupported type for generic specialization: $jt")
end

"""
    infer_type_parameters(func_name::String, arg_types::Vector{Type}) -> Dict{Symbol, Type}

Infer type parameters for a generic function from argument types.

Each Rust argument type recorded in the manifest that is exactly a type
parameter name (`x: T`) binds that parameter to the Julia type of the
corresponding argument. Parameters that never appear as a bare argument type
cannot be inferred and must be supplied explicitly.

# Example
```julia
# For function: fn identity<T>(x: T) -> T
# Called with: identity(Int32(42))
# Returns: Dict(:T => Int32)
```
"""
function infer_type_parameters(func_name::String, arg_types::Vector{<:Type})
    generic_info = lock(REGISTRY_LOCK) do
        get(GENERIC_FUNCTION_REGISTRY, func_name, nothing)
    end
    if generic_info === nothing
        error("Function '$func_name' is not registered as a generic function")
    end

    type_params = Dict{Symbol, Type}()
    sig_arg_types = generic_info.arg_types
    type_param_set = Set(generic_info.type_params)

    if length(sig_arg_types) != length(arg_types)
        error("Generic function '$func_name' takes $(length(sig_arg_types)) argument(s) but $(length(arg_types)) were given")
    end

    for (rust_type, jt) in zip(sig_arg_types, arg_types)
        param = Symbol(strip(rust_type))
        param in type_param_set || continue
        if haskey(type_params, param) && type_params[param] != jt
            error("Conflicting types for parameter $param in '$func_name': $(type_params[param]) vs $jt")
        end
        type_params[param] = jt
    end

    missing_params = [p for p in generic_info.type_params if !haskey(type_params, p)]
    if !isempty(missing_params)
        error("Cannot infer type parameter(s) $(join(string.(missing_params), ", ")) of '$func_name' from argument types $(arg_types); the parameter does not appear as a bare argument type")
    end

    return type_params
end

"""
    monomorphize_function(func_name::String, type_params::Dict{Symbol, Type}) -> FunctionInfo

Monomorphize a generic function with specific type parameters.

# Arguments
- `func_name`: Name of the generic function
- `type_params`: Mapping from type parameter symbols to concrete types

# Returns
- FunctionInfo for the monomorphized function

# Example
```julia
# Register generic function
register_generic_function("identity", "pub fn identity<T>(x: T) -> T { x }", [:T])

# Monomorphize with Int32
info = monomorphize_function("identity", Dict{Symbol, Type}(:T => Int32))
# Returns FunctionInfo for identity_i32
```
"""
function monomorphize_function(func_name::String, type_params::Dict{Symbol, <:Type})
    # Check if already monomorphized
    # Sort by type name (string representation) to ensure consistent ordering
    sorted_types = sort(collect(values(type_params)), by=string)
    type_params_tuple = tuple(sorted_types...)
    cache_key = (func_name, type_params_tuple)

    lock(REGISTRY_LOCK) do
        if haskey(MONOMORPHIZED_FUNCTIONS, cache_key)
            return MONOMORPHIZED_FUNCTIONS[cache_key]
        end

        # Get generic function info
        generic_info = get(GENERIC_FUNCTION_REGISTRY, func_name, nothing)
        if generic_info === nothing
            error("Function '$func_name' is not registered as a generic function")
        end

        # Generate a unique name for the monomorphized function
        # Create a type suffix from the type parameters
        type_suffix_parts = String[]
        for t in sort(collect(values(type_params)), by=string)
            type_str = string(t)
            # Convert Julia type names to short identifiers
            type_map = Dict(
                "Int32" => "i32",
                "Int64" => "i64",
                "UInt32" => "u32",
                "UInt64" => "u64",
                "Float32" => "f32",
                "Float64" => "f64",
                "Bool" => "bool",
            )
            suffix = get(type_map, type_str, replace(type_str, "Int" => "i", "UInt" => "u", "Float" => "f"))
            push!(type_suffix_parts, suffix)
        end
        type_suffix = join(type_suffix_parts, "_")
        specialized_name = "$(func_name)_$(type_suffix)"

        # Instantiate through the extractor: the specialized function is added to
        # the registered source (context + generic code) with the concrete types
        # substituted at the AST level and exported as `#[no_mangle] extern "C"`.
        bindings = Pair{String, String}[string(p) => julia_type_to_rust_string(type_params[p])
                                        for p in generic_info.type_params]
        full_source = isempty(generic_info.context) ? generic_info.code :
                      generic_info.context * "\n" * generic_info.code
        specialized = specialize_generic(full_source, generic_info.path, bindings, specialized_name)
        specialized_code = specialized.source

        # Compile the specialized function with the compiler the block was
        # expanded for (its #[cfg] snapshot), falling back to the default.
        compiler = something(generic_info.compiler, get_default_compiler())
        wrapped_code = wrap_rust_code(specialized_code)
        lib_path = compile_rust_to_shared_lib(wrapped_code; compiler=compiler)

        # Load the library
        lib_handle = Libdl.dlopen(lib_path, Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW)
        if lib_handle == C_NULL
            error("Failed to load monomorphized function library: $lib_path")
        end

        # Register the library (so it can be managed)
        lib_name = basename(lib_path)
        lock(REGISTRY_LOCK) do
            if !haskey(RUST_LIBRARIES, lib_name)
                RUST_LIBRARIES[lib_name] = (lib_handle, Dict{String, Ptr{Cvoid}}())
            end
        end

        func_ptr = Libdl.dlsym(lib_handle, specialized_name; throw_error=false)
        if func_ptr === nothing || func_ptr == C_NULL
            error("""
            Function '$specialized_name' not found in library '$lib_path'.

            Specialized code was:
            $specialized_code
            """)
        end

        lock(REGISTRY_LOCK) do
            _, func_cache = RUST_LIBRARIES[lib_name]
            func_cache[specialized_name] = func_ptr
        end

        # Return and argument types come from the manifest of the specialized
        # function, never from scanning the generated source.
        ret_type = _specialized_return_type(specialized.return_type)
        arg_types = Type[_specialized_arg_type(t, type_params) for t in specialized.arg_types]

        # Create FunctionInfo
        info = FunctionInfo(specialized_name, lib_name, ret_type, arg_types, func_ptr)

        # Cache the monomorphized function
        MONOMORPHIZED_FUNCTIONS[cache_key] = info

        return info
    end
end

"""
    register_generic_function(func_name, code, type_params, constraints, context)

Register a generic Rust function for later monomorphization.

# Arguments
- `func_name`: Name of the function
- `code`: Rust function code (with generics)
- `type_params`: List of type parameter symbols
- `constraints`: Trait bounds for type parameters (TypeConstraints or legacy Dict{Symbol, String})
- `context`: Additional code (e.g. struct definitions) needed for compilation

# Examples
```julia
# With TypeConstraints (recommended)
constraints = Dict(:T => TypeConstraints([TraitBound("Copy", []), TraitBound("Clone", [])]))
register_generic_function("identity", code, [:T], constraints)

# Legacy format (still supported)
register_generic_function("identity", code, [:T], Dict(:T => "Copy + Clone"))

# No constraints
register_generic_function("identity", code, [:T])
```
"""
function register_generic_function(
    func_name::String,
    code::String,
    type_params::Vector{Symbol},
    constraints::Dict{Symbol, TypeConstraints}=Dict{Symbol, TypeConstraints}(),
    context::String="";
    arg_types::Vector{String}=String[],
    return_type::String="",
    path::String=func_name,
    compiler::Union{Nothing, RustCompiler}=nothing
)
    # Manual registrations usually pass only the source. Recover the argument
    # and return types (and, when not given, the trait bounds) from the
    # extractor's manifest so that inference and monomorphization work exactly
    # as for functions loaded from a rust\"\"\" block.
    if isempty(arg_types) || isempty(return_type) || isempty(constraints)
        sig = _manifest_signature_for(func_name, code)
        if sig !== nothing
            isempty(arg_types) && (arg_types = sig.arg_types)
            isempty(return_type) && (return_type = sig.return_type)
            isempty(constraints) && (constraints = sig.constraints)
        end
    end
    lock(REGISTRY_LOCK) do
        info = GenericFunctionInfo(func_name, code, type_params, constraints, context, arg_types, return_type, path, compiler)
        GENERIC_FUNCTION_REGISTRY[func_name] = info
        return info
    end
end

# Backward compatibility: accept `Dict{Symbol, String}` bounds such as
# `Dict(:T => "Copy + Add<Output = T>")`. The strings are parsed by the Rust-side
# parser (through the extractor), never by Julia.
function register_generic_function(
    func_name::String,
    code::String,
    type_params::Vector{Symbol},
    constraints::Dict{Symbol, String},
    context::String="";
    kwargs...
)
    return register_generic_function(func_name, code, type_params,
                                     constraints_from_strings(constraints), context; kwargs...)
end

"""
    _manifest_signature_for(func_name, code) -> Union{RustFunctionSignature, Nothing}

Signature of the top-level function `func_name` in `code` according to the
extractor, or `nothing` when the code cannot be parsed or has no such function.
"""
function _manifest_signature_for(func_name::String, code::String)
    sigs = try
        manifest_function_signatures(extract_manifest(code; mode = "inline"); only_attributed = false)
    catch e
        @debug "Could not extract a manifest for generic function '$func_name'" exception = e
        return nothing
    end
    idx = findfirst(s -> s.name == func_name, sigs)
    return idx === nothing ? nothing : sigs[idx]
end

"""
    _specialized_return_type(rust_type::String) -> Type

Julia return type of a monomorphized function: raw pointers map to `Ptr{Cvoid}`,
primitives to their Julia counterpart, anything else to `Any`.
"""
function _specialized_return_type(rust_type::String)
    startswith(rust_type, "*") && return Ptr{Cvoid}
    t = _rust_primitive_to_julia_type(rust_type)
    return t === nothing ? Any : t
end

function _specialized_arg_type(rust_type::String, type_params::Dict{Symbol, <:Type})
    startswith(rust_type, "*") && return Ptr{Cvoid}
    t = _rust_primitive_to_julia_type(rust_type)
    t === nothing || return t
    p = Symbol(rust_type)
    return haskey(type_params, p) ? type_params[p] : Any
end

"""
    call_generic_function(func_name::String, args...)

Call a generic Rust function, automatically monomorphizing if needed.

# Arguments
- `func_name`: Name of the generic function
- `args...`: Arguments (types will be inferred from these)

# Example
```julia
# Assuming identity<T> is registered
result = call_generic_function("identity", Int32(42))
# Automatically monomorphizes to identity<Int32> and calls it
```
"""
function call_generic_function(func_name::String, args...)
    # Infer type parameters from arguments
    arg_types = map(typeof, args)
    type_params = infer_type_parameters(func_name, collect(arg_types))

    # Monomorphize (or get cached version)
    info = monomorphize_function(func_name, type_params)

    # Call the monomorphized function using the specialized name
    # The specialized function is in a new library, so we need to get its pointer
    func_ptr = info.func_ptr

    # Call using the standard call_rust_function
    return call_rust_function(func_ptr, info.return_type, args...)
end

"""
    is_generic_function(func_name::String) -> Bool

Check if a function is registered as a generic function.
"""
function is_generic_function(func_name::String)
    return lock(REGISTRY_LOCK) do
        @debug "Checking if function is generic" func_name registry_keys=collect(keys(GENERIC_FUNCTION_REGISTRY))
        haskey(GENERIC_FUNCTION_REGISTRY, func_name)
    end
end

"""
    get_monomorphized_function(func_name::String, type_params::Dict{Symbol, Type}) -> Union{FunctionInfo, Nothing}

Get a monomorphized function instance if it exists.
"""
function get_monomorphized_function(func_name::String, type_params::Dict{Symbol, <:Type})
    lock(REGISTRY_LOCK) do
        sorted_types = sort(collect(values(type_params)), by=string)
        type_params_tuple = tuple(sorted_types...)
        cache_key = (func_name, type_params_tuple)
        return get(MONOMORPHIZED_FUNCTIONS, cache_key, nothing)
    end
end
