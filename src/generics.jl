# Generic function support for LastCall.jl
# Phase 2: Monomorphization and type parameter inference

# Import required functions and constants from other modules
# These will be available when this file is included after ruststr.jl and codegen.jl

"""
    GenericFunctionInfo

Information about a generic Rust function that needs monomorphization.
"""
struct GenericFunctionInfo
    name::String
    code::String
    type_params::Vector{Symbol}  # e.g., [:T, :U]
    constraints::Dict{Symbol, String}  # e.g., :T => "Copy" (trait bounds)
    context::String  # Additional code (e.g., struct definitions) needed for compilation
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

"""
    parse_generic_function(code::String, func_name::String) -> Union{GenericFunctionInfo, Nothing}

Parse a Rust function to detect if it's generic and extract type parameters.

# Example
```rust
pub fn identity<T>(x: T) -> T { x }
```
This would be parsed as:
- name: "identity"
- type_params: [:T]
- constraints: Dict()
"""
function parse_generic_function(code::String, func_name::String)
    # Simple regex-based parser for generic functions
    # Pattern: fn func_name<T, U, ...>(args...) -> ret_type { ... }

    # Check if function has type parameters
    generic_pattern = Regex("fn\\s+$func_name\\s*<([^>]+)>\\s*\\(")
    m = match(generic_pattern, code)

    if m === nothing
        return nothing  # Not a generic function
    end

    # Extract type parameters
    type_params_str = m.captures[1]
    type_params = Symbol[]
    for param in split(type_params_str, ',', keepempty=false)
        param = strip(param)
        # Handle trait bounds: T: Copy + Clone -> just T
        if occursin(':', param)
            param = split(param, ':')[1]
        end
        push!(type_params, Symbol(strip(param)))
    end

    # Extract constraints (trait bounds) - simplified for now
    constraints = Dict{Symbol, String}()
    # TODO: Parse trait bounds more thoroughly

    return GenericFunctionInfo(func_name, code, type_params, constraints, "")
end

"""
    specialize_generic_code(code::String, type_params::Dict{Symbol, Type}) -> String

Specialize a generic Rust function by replacing type parameters with concrete types.

# Arguments
- `code`: The generic Rust function code
- `type_params`: Mapping from type parameter symbols to concrete Julia types

# Example
```julia
code = "pub fn identity<T>(x: T) -> T { x }"
type_params = Dict(:T => Int32)
specialize_generic_code(code, type_params)
# Returns: "pub fn identity(x: i32) -> i32 { x }"
```
"""
function specialize_generic_code(code::String, type_params::Dict{Symbol, <:Type})
    specialized = code

    # 1. First, remove the generic parameter list from function signature(s) and impl blocks
    # Pattern: fn name<T, U>( -> fn name(
    specialized = replace(specialized, Regex("(fn\\s+\\w+)\\s*<.+?>\\s*\\(", "s") => s"\1(")

    # Pattern: impl<T> -> impl
    specialized = replace(specialized, Regex("impl\\s*<.+?>", "s") => "impl")

    # Convert Julia types to Rust types
    julia_to_rust_map = Dict(
        Int32 => "i32",
        Int64 => "i64",
        UInt32 => "u32",
        UInt64 => "u64",
        Float32 => "f32",
        Float64 => "f64",
        Bool => "bool",
        String => "*const u8",
        Cstring => "*const u8",
    )

    # Helper to convert Julia type to Rust type string
    function to_rust_type_str(jt::Type)
        if haskey(julia_to_rust_map, jt)
            return julia_to_rust_map[jt]
        end

        # Handle parametric types: Point{Float64} -> Point<f64>
        type_str = string(jt)
        if occursin('{', type_str)
            m = match(r"^([^{]+)", type_str)
            if m !== nothing
                base_name = m.captures[1]
                params = jt.parameters
                rust_params = join([to_rust_type_str(p) for p in params], ", ")
                return "$base_name<$rust_params>"
            end
        end

        error("Unsupported type for generic specialization: $jt")
    end

    # 2. Replace type parameters in the rest of the code
    for (param, julia_type) in type_params
        rust_type = to_rust_type_str(julia_type)
        param_str = string(param)

        # Replace whole words only: T -> f64
        specialized = replace(specialized, Regex("\\b$param_str\\b") => rust_type)
    end

    return specialized
end

"""
    infer_type_parameters(func_name::String, arg_types::Vector{Type}) -> Dict{Symbol, Type}

Infer type parameters for a generic function from argument types.

# Arguments
- `func_name`: Name of the generic function
- `arg_types`: Types of the arguments passed to the function

# Returns
- Dictionary mapping type parameter symbols to concrete types

# Example
```julia
# For function: fn identity<T>(x: T) -> T
# Called with: identity(Int32(42))
# Returns: Dict(:T => Int32)
```
"""
function infer_type_parameters(func_name::String, arg_types::Vector{<:Type})
    # Get generic function info
    generic_info = get(GENERIC_FUNCTION_REGISTRY, func_name, nothing)
    if generic_info === nothing
        error("Function '$func_name' is not registered as a generic function")
    end

    # Parse function signature to map parameters to type params
    # This is a simplified implementation
    # In practice, we'd need to parse the Rust function signature more carefully

    type_params = Dict{Symbol, Type}()

    # Simple inference: match by position if possible
    if length(generic_info.type_params) == 1 && !isempty(arg_types)
        type_params[generic_info.type_params[1]] = arg_types[1]
    elseif length(generic_info.type_params) == length(arg_types)
        for i in 1:length(arg_types)
            type_params[generic_info.type_params[i]] = arg_types[i]
        end
    else
        error("Cannot infer type parameters for '$func_name' with $(length(arg_types)) arguments and $(length(generic_info.type_params)) type parameters")
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

    # Specialize the code (this replaces type parameters with concrete types)
    specialized_code = specialize_generic_code(generic_info.code, type_params)

    # Extract the actual function name from the code (might differ from registered name)
    # Pattern: fn actual_name(
    actual_name_match = match(r"fn\s+(\w+)\s*\(", specialized_code)
    if actual_name_match === nothing
        println("DEBUG: Failed to find function name in specialized code:\n$specialized_code")
        error("Could not find function name in specialized code")
    end
    actual_func_name = actual_name_match.captures[1]

    # Replace function name in code with the specialized name
    # We use a literal replacement here to ensure $specialized_name is correctly interpolated
    specialized_code = replace(specialized_code, "fn $actual_func_name(" => "fn $specialized_name(")

    # Ensure #[no_mangle] and extern "C" are present (required for FFI)
    # Correct order is #[no_mangle] pub extern "C" fn ...

    # Normalize function signature for FFI
    # We need to ensure the function is exported, uses C ABI, and is not mangled.
    # The previous simple replacements were causing duplication of attributes.

    # Regex matches: (optional attributes) (optional pub) (optional extern "C") fn name (
    # We use a robust regex to replace the entire declaration line
    decl_regex = Regex("(?:#\\[[^\\]]+\\]\\s*)?(?:pub\\s+)?(?:extern\\s+\"C\"\\s+)?fn\\s+$specialized_name\\s*\\(")

    if occursin(decl_regex, specialized_code)
        specialized_code = replace(specialized_code, decl_regex => "#[no_mangle]\npub extern \"C\" fn $specialized_name(")
    else
        # Fallback if the strict regex fails (though it shouldn't if step 264 worked)
        # Just prepend to the simplest case
        specialized_code = replace(specialized_code, "fn $specialized_name(" => "#[no_mangle]\npub extern \"C\" fn $specialized_name(")
    end

    # Now prepend the specialized context
    if !isempty(generic_info.context)
        specialized_context = specialize_generic_code(generic_info.context, type_params)
        specialized_code = specialized_context * "\n" * specialized_code
    end

    # Compile the specialized function
    # Note: compile_rust_to_shared_lib and get_default_compiler are in compiler.jl
    # We need to ensure they're available when this runs
    compiler = get_default_compiler()

    # Wrap the code for compilation
    wrapped_code = wrap_rust_code(specialized_code)
    lib_path = compile_rust_to_shared_lib(wrapped_code; compiler=compiler)

    # Load the library
    lib_handle = Libdl.dlopen(lib_path, Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW)
    if lib_handle == C_NULL
        error("Failed to load monomorphized function library: $lib_path")
    end

    # Register the library (so it can be managed)
    lib_name = basename(lib_path)
    if !haskey(RUST_LIBRARIES, lib_name)
        RUST_LIBRARIES[lib_name] = (lib_handle, Dict{String, Ptr{Cvoid}}())
    end

    # Get function pointer
    # Try with throw_error=false first to get better error message
    func_ptr = Libdl.dlsym(lib_handle, specialized_name; throw_error=false)
    if func_ptr === nothing || func_ptr == C_NULL
        # Try to get available symbols for debugging
        error("""
        Function '$specialized_name' not found in library '$lib_path'.

        This might be because:
        1. The function name was not correctly replaced in the specialized code
        2. The #[no_mangle] attribute was not properly added
        3. The library was compiled with name mangling enabled

        Specialized code was:
        $specialized_code
        """)
    end

    # Cache the function pointer in the library's function cache
    _, func_cache = RUST_LIBRARIES[lib_name]
    func_cache[specialized_name] = func_ptr

    # Infer return type from specialized code
    # For now, use a simple heuristic: if return type is a type parameter, use the corresponding argument type
    # In a more sophisticated implementation, we'd parse the return type from the specialized code
    ret_type = length(type_params) > 0 ? first(values(type_params)) : Any
    arg_types = collect(values(type_params))

    # Try to infer return type from code (simplified)
    # Pattern: -> *mut... or -> *const...
    if occursin(r"->\s*\*(?:mut|const)", specialized_code)
         ret_type = Ptr{Cvoid}
    else
        # Pattern: -> T or -> i32
        ret_type_match = match(r"->\s*([\w:<>]+)", specialized_code)
        if ret_type_match !== nothing
            ret_type_str = ret_type_match.captures[1]
            # Map Rust type to Julia type
            rust_to_julia = Dict(
                "i32" => Int32, "i64" => Int64,
                "u32" => UInt32, "u64" => UInt64,
                "f32" => Float32, "f64" => Float64,
                "bool" => Bool,
            )
            if haskey(rust_to_julia, ret_type_str)
                ret_type = rust_to_julia[ret_type_str]
            elseif length(type_params) > 0
                 # Fallback to T if type string matches a type param?
                 # Actually, we should be careful.
                 # If no match, defaulting to first param is risky.
                 # Let's keep the fallback for now as it handles '-> i32' when T=i32.
            end
        end
    end

    # Create FunctionInfo
    info = FunctionInfo(specialized_name, lib_name, ret_type, arg_types, func_ptr)

    # Cache the monomorphized function
    MONOMORPHIZED_FUNCTIONS[cache_key] = info

    return info
end

"""
    register_generic_function(func_name, code, type_params, constraints, context)

Register a generic Rust function for later monomorphization.

# Arguments
- `func_name`: Name of the function
- `code`: Rust function code (with generics)
- `type_params`: List of type parameter symbols
- `constraints`: Trait bounds for type parameters
- `context`: Additional code (e.g. struct definitions) needed for compilation
"""
function register_generic_function(func_name::String, code::String, type_params::Vector{Symbol}, constraints::Dict{Symbol, String}=Dict{Symbol, String}(), context::String="")
    # println("DEBUG: Registering generic function in GENERIC_FUNCTION_REGISTRY: $func_name")
    info = GenericFunctionInfo(func_name, code, type_params, constraints, context)
    GENERIC_FUNCTION_REGISTRY[func_name] = info
    return info
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
    # println("DEBUG: Checking if $func_name is generic. Registry keys: ", keys(GENERIC_FUNCTION_REGISTRY))
    return haskey(GENERIC_FUNCTION_REGISTRY, func_name)
end

"""
    get_monomorphized_function(func_name::String, type_params::Dict{Symbol, Type}) -> Union{FunctionInfo, Nothing}

Get a monomorphized function instance if it exists.
"""
function get_monomorphized_function(func_name::String, type_params::Dict{Symbol, <:Type})
    sorted_types = sort(collect(values(type_params)), by=string)
    type_params_tuple = tuple(sorted_types...)
    cache_key = (func_name, type_params_tuple)
    return get(MONOMORPHIZED_FUNCTIONS, cache_key, nothing)
end
