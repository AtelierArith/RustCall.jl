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
    # Non-empty when the function cannot be specialized lazily: the reason,
    # raised as a `RustError` by `monomorphize_function`. Set for generics of a
    # Cargo-backed block whose body contains `#[cfg]`/`cfg!`, because the
    # lazy specialization is a direct `rustc` build under another
    # configuration than the Cargo build the block was expanded for.
    blocked::String
end

"""
Registry for generic functions.
Maps function name to GenericFunctionInfo.
"""
const GENERIC_FUNCTION_REGISTRY = Dict{String, GenericFunctionInfo}()

"""
Registry for monomorphized function instances.

Keyed by `artifact_key` of the monomorphization `ArtifactId`
(`_monomorphization_id`), which records the parameter bindings in **declaration
order** together with the source, the compiler snapshot and the toolchain. The
previous key was `(func_name, tuple(sort(values(type_params))...))`: sorting the
*values* discarded which parameter got which type, so `pair<T=i32, U=i64>` and
`pair<T=i64, U=i32>` shared one entry and the second call ran the first one's
machine code (#247).
"""
const MONOMORPHIZED_FUNCTIONS = Dict{String, FunctionInfo}()

"""
    _monomorphization_id(generic_info, func_name, type_params, compiler) -> ArtifactId

The identity of one instantiation of a generic function: the registered source
(context plus generic code), the parameter bindings **in declaration order**,
and the compiler snapshot the instantiation is built under. `dependencies` and
`build_env` are left empty here — the lazy specialization is a direct `rustc`
build — but they are fields of the record, so a future Cargo-backed
specialization (#277) needs no new key formula.

Throws `ArgumentError` when `type_params` does not bind every declared
parameter.
"""
function _monomorphization_id(generic_info, func_name::AbstractString, type_params, compiler)
    return ArtifactId(
        kind = "monomorphization",
        source = isempty(generic_info.context) ? generic_info.code :
                 generic_info.context * "\n" * generic_info.code,
        type_params = artifact_type_params(generic_info.type_params, type_params),
        target_triple = compiler.target_triple,
        codegen = artifact_codegen_options(compiler),
        extra = Pair{String, String}["function" => String(func_name)],
    )
end

# Julia type name -> short Rust-flavoured identifier, for the human-readable
# part of a monomorphized symbol. Never load-bearing: the artifact key decides
# identity, this only decides how the symbol reads.
const _MONOMORPHIZATION_TYPE_SUFFIX = Dict{String, String}(
    "Int32" => "i32",
    "Int64" => "i64",
    "UInt32" => "u32",
    "UInt64" => "u64",
    "Float32" => "f32",
    "Float64" => "f64",
    "Bool" => "bool",
)

function _rust_type_suffix(t)::String
    type_str = string(t)
    return get(_MONOMORPHIZATION_TYPE_SUFFIX, type_str,
               replace(type_str, "Int" => "i", "UInt" => "u", "Float" => "f"))
end

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
    lock(REGISTRY_LOCK) do
        # Get generic function info. The declared parameter order lives here,
        # and the key cannot be computed without it (#247).
        generic_info = get(GENERIC_FUNCTION_REGISTRY, func_name, nothing)
        if generic_info === nothing
            error("Function '$func_name' is not registered as a generic function")
        end

        # Compile the specialized function with the compiler the block was
        # expanded for (its #[cfg] snapshot), falling back to the default.
        compiler = something(generic_info.compiler, get_default_compiler())
        id = _monomorphization_id(generic_info, func_name, type_params, compiler)
        cache_key = artifact_key(id)

        if haskey(MONOMORPHIZED_FUNCTIONS, cache_key)
            return MONOMORPHIZED_FUNCTIONS[cache_key]
        end

        isempty(generic_info.blocked) || throw(RustError(generic_info.blocked))

        # A human-readable name for the instantiation, built from the type
        # parameters in *declaration* order, plus a short id so that a permuted
        # instantiation with the same type set cannot claim the same symbol
        # (`pair<i32,i64>` and `pair<i64,i32>` both read `pair_i32_i64`, #247).
        type_suffix = join([_rust_type_suffix(t) for (_, t) in id.type_params], "_")
        specialized_name = "$(func_name)_$(type_suffix)_$(artifact_short_id(cache_key, 8))"

        # Instantiate through the extractor: the specialized function is added to
        # the registered source (context + generic code) with the concrete types
        # substituted at the AST level and exported as `#[no_mangle] extern "C"`.
        bindings = Pair{String, String}[string(p) => julia_type_to_rust_string(type_params[p])
                                        for p in generic_info.type_params]
        full_source = isempty(generic_info.context) ? generic_info.code :
                      generic_info.context * "\n" * generic_info.code
        specialized = specialize_generic(full_source, generic_info.path, bindings, specialized_name)
        specialized_code = specialized.source

        wrapped_code = wrap_rust_code(specialized_code)
        lib_path = compile_rust_to_shared_lib(wrapped_code; compiler=compiler)

        # Load and register the instantiation under its artifact identity.
        # `basename(lib_path)` used to be the key, but `_unique_source_name`
        # returns the constant "rust_code" outside debug mode, so *every*
        # instantiation collided on one RUST_LIBRARIES entry (the
        # `:lib_basename` divergence recorded in src/loadpolicy.jl).
        #
        # `generics_policy()` registers `:insert_only`: two tasks racing on the
        # same instantiation both compile and both `dlopen`, and the loser's
        # duplicate handle is closed by `load_artifact!` rather than replacing
        # a live entry and discarding its function-pointer cache. The exported
        # symbol is the additive wrapper the extractor emitted next to the
        # instantiation, never the instantiation's own name (#279); resolving
        # it eagerly puts it in the winner's cache inside the same transaction.
        lib_name = "rust_generic_$(artifact_short_id(cache_key))"
        specialized_symbol = specialized.symbol
        artifact = load_artifact!(generics_policy(), lib_path;
                                  lib_name, eager = (specialized_symbol,))

        func_ptr = Libdl.dlsym(artifact.handle, specialized_symbol; throw_error=false)
        if func_ptr === nothing || func_ptr == C_NULL
            error("""
            Function '$(specialized_symbol)' not found in library '$lib_path'.

            Specialized code was:
            $specialized_code
            """)
        end

        # Return and argument types come from the manifest of the specialized
        # function, never from scanning the generated source.
        arg_types = Type[_specialized_arg_type(t, type_params) for t in specialized.arg_types]

        # Fixed `String` / `&str` parameters and returns use the string ABI
        # (#242): the specialized wrapper takes `(ptr, len)` pairs and returns
        # an owned buffer (released through `<name>_free_rust_string`) or a
        # borrowed view; see `_call_monomorphized`. A lowered string return is
        # decided here, *before* the plain return type is resolved: the buffer
        # is not a single C slot and asking the contract for one would fail
        # closed on a return the wrapper handles perfectly well.
        string_return = :none
        free_ptr = C_NULL
        if specialized.has_owned_string_helper
            string_return = :owned
            # The string helpers keep the instantiation's own name (#279).
            free_name = ffi_free_symbol(specialized.name)
            free_ptr = Libdl.dlsym(artifact.handle, free_name; throw_error=false)
            if free_ptr === nothing || free_ptr == C_NULL
                error("Function '$free_name' not found in library '$lib_path'")
            end
        elseif specialized.has_borrowed_string_helper
            string_return = :borrowed
        end

        # Return type from the manifest of the specialized function, never from
        # scanning the generated source. A fixed type the contract does not
        # cover goes through `FFI_STRICT[]` like every other return site.
        ret_type = if string_return === :none
            _specialized_return_type(specialized.return_type,
                                     ffi_signature_context(specialized.name,
                                                           specialized.arg_types,
                                                           specialized.return_type))
        else
            String
        end

        # Create FunctionInfo. It is a *snapshot*: it is cached and used long
        # after this lookup, so everything the call needs — the panic channel
        # included — is resolved here, against the handle the pointer came
        # from. Looking the channel up later by library name could find no
        # library (an unload between the cache hit and the call) and answer
        # `C_NULL`, while `func_ptr` still enters the mapped retired image; a
        # panic would then be read as a successful zero (#244, #277).
        channel = Libdl.dlsym(artifact.handle, ffi_panic_symbol(specialized_symbol);
                              throw_error = false)
        channel = (channel === nothing) ? C_NULL : channel
        info = FunctionInfo(specialized_symbol, lib_name, ret_type, arg_types, func_ptr,
                            specialized.arg_abis, string_return, free_ptr,
                            channel, artifact.handle, artifact.generation)

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
    compiler::Union{Nothing, RustCompiler}=nothing,
    blocked::String=""
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
        info = GenericFunctionInfo(func_name, code, type_params, constraints, context, arg_types, return_type, path, compiler, blocked)
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
    _specialized_return_type(rust_type::String, ctx::AbstractString) -> Type

Julia return type of a monomorphized function, from the FFI contract
(`src/ffi_contract.jl`). A raw pointer keeps its pointee (`*mut i32` is
`Ptr{Int32}`, an opaque pointee degrades to `Ptr{Cvoid}`), and `char` is the
surface `Char`, which `call_rust_function` reads out of its `UInt32` slot.

A fixed type the contract does not cover goes through the same
`ffi_return_type_or_throw` every other return site uses, so `FFI_STRICT[]`
governs it: `:error` raises naming the specialized signature, `:warn` warns once
and falls back to `Any`. It used to become `Any` silently, which is not a
well-defined `ccall` return slot (#276).
"""
function _specialized_return_type(rust_type::String, ctx::AbstractString)
    return ffi_return_type_or_throw(rust_type, "", ctx)
end

function _specialized_arg_type(rust_type::String, type_params::Dict{Symbol, <:Type})
    c = ffi_argument_contract(rust_type)
    c.known && c.abi === :void && return Cvoid
    if c.known && (c.abi === :by_value || c.abi === :pointer)
        return only(c.ccall_types)
    end
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

    return _call_monomorphized(info, args...)
end

"""
    _call_monomorphized(info::FunctionInfo, args...)

Call a monomorphized function through its `FunctionInfo`. String arguments
(`info.arg_abis`) are checked to be valid UTF-8 (`ffi_string_argument`, #246)
and passed as `(ptr, len)` byte pairs kept alive for the duration of the call,
and a string return (`info.string_return`) is copied out of the owned or
borrowed buffer, exactly as the generated wrappers of non-generic `#[julia]`
functions do.
"""
function _call_monomorphized(info::FunctionInfo, args...)
    # The channel was resolved when `info` was built, against the same handle
    # `func_ptr` came from — so it is the channel of the wrapper that is about
    # to run, whatever has happened to the library's *name* since (#244, #277).
    channel = info.channel
    if info.string_return === :none && !any(_is_string_abi, info.arg_abis)
        return guard_rust_panic_ptr(
            call_rust_function(info.func_ptr, info.return_type,
                               _monomorphized_call_args(info, args)...),
            channel, info.name)
    end
    if length(info.arg_abis) != length(args)
        error("Function '$(info.name)' takes $(length(info.arg_abis)) argument(s) but $(length(args)) were given")
    end
    # The converted strings are collected in a vector, which is what
    # GC.@preserve keeps alive (and, through it, every string).
    strings = String[]
    call_args = Any[]
    for (i, (arg, abi)) in enumerate(zip(args, info.arg_abis))
        if _is_string_abi(abi)
            # The same UTF-8 check the non-generic wrappers make (#246). A
            # `FunctionInfo` records ABIs, not parameter names, so the message
            # names the position; the specialization's exported symbol is the
            # context. Without it a generic `#[julia] fn f<T>(s: &str, x: T)`
            # was the one string path left where invalid bytes reached
            # `String::from_utf8_lossy` and were silently replaced.
            s = ffi_string_argument(arg, i, info.name)
            push!(strings, s)
            push!(call_args, pointer(s))
            push!(call_args, sizeof(s) % Csize_t)
        else
            push!(call_args, _monomorphized_arg(info, i, arg))
        end
    end
    # A specialization is a wrapper like any other, so its panic channel is
    # read after the call (#244). `info.name` is the exported symbol of the
    # instantiation, which is what the channel is named after.
    GC.@preserve strings begin
        result = if info.string_return === :owned
            _call_rust_owned_string_ptr(info.func_ptr, info.free_ptr, call_args...)
        elseif info.string_return === :borrowed
            _call_rust_borrowed_string_ptr(info.func_ptr, call_args...)
        else
            call_rust_function(info.func_ptr, info.return_type, call_args...)
        end
        guard_rust_panic_ptr(result, channel, info.name)
    end
end

"""
    _monomorphized_call_args(info, args) -> Tuple

Every argument converted to the C slot the manifest recorded for it
(`info.arg_types`, resolved through the FFI contract at specialization time).

Without this the `ccall` signature was derived from the *runtime* Julia types of
the arguments, so `fn f<T>(x: T, c: char)` called with a Julia `Char` passed
that `Char`'s left-aligned UTF-8 bit pattern where Rust expects a `UInt32` code
point (#245, #276). A count mismatch is left alone: the receiver-passing paths
build their own argument lists and the call itself reports the mismatch.
"""
function _monomorphized_call_args(info::FunctionInfo, args::Tuple)
    length(info.arg_types) == length(args) || return args
    return ntuple(i -> _monomorphized_arg(info, i, args[i]), length(args))
end

function _monomorphized_arg(info::FunctionInfo, i::Integer, arg)
    i <= length(info.arg_types) || return arg
    return ffi_slot_convert(info.arg_types[i], arg)
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

Computes the same key as `monomorphize_function` (`_monomorphization_id`), which
needs the declared parameter order — so an unregistered generic, an incomplete
set of bindings, or an unidentifiable toolchain all mean "not cached" rather
than an error.
"""
function get_monomorphized_function(func_name::String, type_params::Dict{Symbol, <:Type})
    lock(REGISTRY_LOCK) do
        generic_info = get(GENERIC_FUNCTION_REGISTRY, func_name, nothing)
        generic_info === nothing && return nothing
        compiler = something(generic_info.compiler, get_default_compiler())
        cache_key = try
            artifact_key(_monomorphization_id(generic_info, func_name, type_params, compiler))
        catch
            return nothing
        end
        return get(MONOMORPHIZED_FUNCTIONS, cache_key, nothing)
    end
end
