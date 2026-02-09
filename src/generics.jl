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
# Rust Syntax Parsing — Angle Bracket Safety Rule
# ============================================================================
#
# IMPORTANT: Never use regex alone to match angle brackets (`< >`) in Rust code.
# Rust generics can nest arbitrarily deep:
#
#   Vec<Option<Result<T, String>>>
#   impl<T: Add<Output = T>>
#   HashMap<String, Vec<Option<i32>>>
#
# Patterns like `<[^>]+>`, `<.+?>`, or `<([^>]+(?:<[^>]*>)*)>` will fail
# because they cannot handle arbitrary nesting depth.
#
# Instead, use bracket-counting (depth tracking) via the helpers:
#   - `_find_matching_angle_bracket(s, open_pos)` — find matching `>` for `<`
#   - `_remove_generic_params_from_fns(code)` — strip `<...>` from fn signatures
#   - `_remove_generic_params_from_impls(code)` — strip `<...>` from impl blocks
#   - `parse_trait_type_params(params_str)` — split params respecting nesting
#   - `parse_trait_bounds(bounds_str)` — split `+`-separated bounds respecting nesting
#   - `parse_inline_constraints(type_params_str)` — split `,`-separated params respecting nesting
#
# When adding new Rust syntax parsing, always include test cases with deeply
# nested generics (2+ levels of angle brackets).
# ============================================================================

# ============================================================================
# Trait Bounds Parsing Functions
# ============================================================================

"""
    parse_single_trait(trait_str::String) -> TraitBound

Parse a single trait bound string like "Copy", "Add<Output = T>", or "Into<String>".

# Examples
```julia
parse_single_trait("Copy")
# => TraitBound("Copy", [])

parse_single_trait("Add<Output = T>")
# => TraitBound("Add", ["Output = T"])

parse_single_trait("Into<String>")
# => TraitBound("Into", ["String"])
```
"""
function parse_single_trait(trait_str::AbstractString)
    trait_str = strip(trait_str)

    # Check for generic trait: TraitName<...>
    m = match(r"^(\w+)\s*<(.+)>$", trait_str)
    if m !== nothing
        trait_name = String(m.captures[1])
        params_str = String(m.captures[2])
        # Split by comma, but be careful with nested generics
        type_params = parse_trait_type_params(params_str)
        return TraitBound(trait_name, type_params)
    end

    # Simple trait without generics
    return TraitBound(String(trait_str), String[])
end

"""
    parse_trait_type_params(params_str::AbstractString) -> Vector{String}

Parse type parameters inside trait angle brackets, handling nested generics.

# Example
```julia
parse_trait_type_params("Output = T, Error = E")
# => ["Output = T", "Error = E"]

parse_trait_type_params("Vec<T>")
# => ["Vec<T>"]
```
"""
function parse_trait_type_params(params_str::AbstractString)
    params = String[]
    current = IOBuffer()
    angle_depth = 0
    paren_depth = 0

    for c in params_str
        if c == '<'
            angle_depth += 1
            write(current, c)
        elseif c == '>'
            angle_depth -= 1
            write(current, c)
        elseif c == '('
            paren_depth += 1
            write(current, c)
        elseif c == ')'
            paren_depth -= 1
            write(current, c)
        elseif c == ',' && angle_depth == 0 && paren_depth == 0
            param = strip(String(take!(current)))
            if !isempty(param)
                push!(params, param)
            end
        else
            write(current, c)
        end
    end

    # Don't forget the last parameter
    param = strip(String(take!(current)))
    if !isempty(param)
        push!(params, param)
    end

    return params
end

"""
    parse_trait_bounds(bounds_str::AbstractString) -> TypeConstraints

Parse a trait bounds string like "Copy + Clone + Add<Output = T>".

# Examples
```julia
parse_trait_bounds("Copy + Clone")
# => TypeConstraints([TraitBound("Copy", []), TraitBound("Clone", [])])

parse_trait_bounds("Copy + Add<Output = T>")
# => TypeConstraints([TraitBound("Copy", []), TraitBound("Add", ["Output = T"])])
```
"""
function parse_trait_bounds(bounds_str::AbstractString)
    bounds_str = strip(bounds_str)
    if isempty(bounds_str)
        return TypeConstraints()
    end

    bounds = TraitBound[]
    current = IOBuffer()
    depth = 0

    for c in bounds_str
        if c == '<'
            depth += 1
            write(current, c)
        elseif c == '>'
            depth -= 1
            write(current, c)
        elseif c == '+' && depth == 0
            trait_str = strip(String(take!(current)))
            if !isempty(trait_str)
                push!(bounds, parse_single_trait(trait_str))
            end
        else
            write(current, c)
        end
    end

    # Don't forget the last trait
    trait_str = strip(String(take!(current)))
    if !isempty(trait_str)
        push!(bounds, parse_single_trait(trait_str))
    end

    return TypeConstraints(bounds)
end

"""
    parse_inline_constraints(type_params_str::AbstractString) -> Tuple{Vector{Symbol}, Dict{Symbol, TypeConstraints}}

Parse inline type parameters with constraints like "T: Copy + Clone, U: Debug".

# Returns
- Tuple of (type_params, constraints)

# Examples
```julia
parse_inline_constraints("T: Copy + Clone, U: Debug")
# => ([:T, :U], Dict(:T => TypeConstraints([Copy, Clone]), :U => TypeConstraints([Debug])))

parse_inline_constraints("T, U")
# => ([:T, :U], Dict())
```
"""
function parse_inline_constraints(type_params_str::AbstractString)
    type_params = Symbol[]
    constraints = Dict{Symbol, TypeConstraints}()

    # Split by comma, but handle nested angle brackets
    params = String[]
    current = IOBuffer()
    depth = 0

    for c in type_params_str
        if c == '<'
            depth += 1
            write(current, c)
        elseif c == '>'
            depth -= 1
            write(current, c)
        elseif c == ',' && depth == 0
            param = strip(String(take!(current)))
            if !isempty(param)
                push!(params, param)
            end
        else
            write(current, c)
        end
    end

    # Last parameter
    param = strip(String(take!(current)))
    if !isempty(param)
        push!(params, param)
    end

    # Parse each parameter
    for param in params
        param = strip(param)
        # Skip Rust lifetime parameters (e.g., 'a, 'static)
        if startswith(param, "'")
            continue
        end
        if occursin(':', param)
            # Has trait bounds: "T: Copy + Clone"
            parts = split(param, ':', limit=2)
            type_name = Symbol(strip(parts[1]))
            bounds_str = strip(parts[2])
            push!(type_params, type_name)
            constraints[type_name] = parse_trait_bounds(bounds_str)
        else
            # No trait bounds: just "T"
            push!(type_params, Symbol(param))
        end
    end

    return (type_params, constraints)
end

"""
    parse_where_clause(code::AbstractString) -> Dict{Symbol, TypeConstraints}

Parse a where clause from Rust code.

# Supported formats
- `where T: Copy + Clone, U: Debug`
- `where T: Copy + Clone`

# Returns
- Dictionary mapping type parameters to their constraints

# Examples
```julia
code = "fn foo<T, U>(x: T) -> U where T: Copy + Clone, U: Debug { ... }"
parse_where_clause(code)
# => Dict(:T => TypeConstraints([Copy, Clone]), :U => TypeConstraints([Debug]))
```
"""
function parse_where_clause(code::AbstractString)
    constraints = Dict{Symbol, TypeConstraints}()

    # Find where clause - it's between "where" and "{" (function body start)
    # Pattern: where ... {
    m = match(r"\bwhere\s+(.+?)\s*\{", code, 1)
    if m === nothing
        return constraints
    end

    where_content = m.captures[1]

    # Split by comma, handling nested angle brackets
    clauses = String[]
    current = IOBuffer()
    depth = 0

    for c in where_content
        if c == '<'
            depth += 1
            write(current, c)
        elseif c == '>'
            depth -= 1
            write(current, c)
        elseif c == ',' && depth == 0
            clause = strip(String(take!(current)))
            if !isempty(clause)
                push!(clauses, clause)
            end
        else
            write(current, c)
        end
    end

    # Last clause
    clause = strip(String(take!(current)))
    if !isempty(clause)
        push!(clauses, clause)
    end

    # Parse each clause: "T: Bound1 + Bound2"
    for clause in clauses
        if occursin(':', clause)
            parts = split(clause, ':', limit=2)
            type_name = Symbol(strip(parts[1]))
            bounds_str = strip(parts[2])
            constraints[type_name] = parse_trait_bounds(bounds_str)
        end
    end

    return constraints
end

"""
    merge_constraints(c1::Dict{Symbol, TypeConstraints}, c2::Dict{Symbol, TypeConstraints}) -> Dict{Symbol, TypeConstraints}

Merge two constraint dictionaries. If a type parameter exists in both, merge their bounds.
"""
function merge_constraints(c1::Dict{Symbol, TypeConstraints}, c2::Dict{Symbol, TypeConstraints})
    result = Dict{Symbol, TypeConstraints}()

    # Add all from c1
    for (k, v) in c1
        result[k] = v
    end

    # Merge c2
    for (k, v) in c2
        if haskey(result, k)
            # Merge bounds (avoiding duplicates)
            existing_bounds = result[k].bounds
            for bound in v.bounds
                if !(bound in existing_bounds)
                    push!(existing_bounds, bound)
                end
            end
        else
            result[k] = v
        end
    end

    return result
end

"""
    constraints_to_rust_string(constraints::Dict{Symbol, TypeConstraints}) -> String

Convert constraints back to Rust syntax for code generation.

# Example
```julia
constraints = Dict(:T => TypeConstraints([TraitBound("Copy", []), TraitBound("Clone", [])]))
constraints_to_rust_string(constraints)
# => "T: Copy + Clone"
```
"""
function constraints_to_rust_string(constraints::Dict{Symbol, TypeConstraints})
    if isempty(constraints)
        return ""
    end

    parts = String[]
    for (type_param, tc) in sort(collect(constraints), by=x->string(x[1]))
        if !isempty(tc)
            bound_strs = String[]
            for bound in tc.bounds
                if isempty(bound.type_params)
                    push!(bound_strs, bound.trait_name)
                else
                    push!(bound_strs, "$(bound.trait_name)<$(join(bound.type_params, ", "))>")
                end
            end
            push!(parts, "$(type_param): $(join(bound_strs, " + "))")
        end
    end

    return join(parts, ", ")
end

# ============================================================================
# Generic Function Parsing
# ============================================================================

"""
    parse_generic_function(code::AbstractString, func_name::AbstractString) -> Union{GenericFunctionInfo, Nothing}

Parse a Rust function to detect if it's generic and extract type parameters with trait bounds.

# Supported formats
1. Inline bounds: `fn foo<T: Copy + Clone, U: Debug>(x: T) -> U`
2. Where clause: `fn foo<T, U>(x: T) -> U where T: Copy + Clone, U: Debug`
3. Mixed: `fn foo<T: Copy, U>(x: T) -> U where U: Debug`

# Example
```rust
pub fn identity<T: Copy + Clone>(x: T) -> T { x }
```
This would be parsed as:
- name: "identity"
- type_params: [:T]
- constraints: Dict(:T => TypeConstraints([Copy, Clone]))

```rust
pub fn transform<T, U>(x: T) -> U where T: Copy, U: From<T> { ... }
```
This would be parsed as:
- name: "transform"
- type_params: [:T, :U]
- constraints: Dict(:T => TypeConstraints([Copy]), :U => TypeConstraints([From<T>]))
"""
function parse_generic_function(code::AbstractString, func_name::AbstractString)
    # Find "fn func_name<" using regex, then use bracket-counting to find the
    # matching ">". Never use regex alone to match angle brackets in Rust code —
    # generics nest arbitrarily deep (e.g., Vec<Option<Result<T, String>>>).
    prefix_pattern = Regex("fn\\s+$func_name\\s*<")
    m = match(prefix_pattern, code)

    if m === nothing
        return nothing  # Not a generic function
    end

    # Position of the opening '<'
    open_pos = m.offset + length(m.match) - 1
    close_pos = _find_matching_angle_bracket(code, open_pos)
    if close_pos == 0
        return nothing  # Malformed generic signature
    end

    # Extract the content between < and >
    type_params_str = code[nextind(code, open_pos):prevind(code, close_pos)]
    type_params, inline_constraints = parse_inline_constraints(type_params_str)

    # Parse where clause if present
    where_constraints = parse_where_clause(code)

    # Merge constraints (inline + where clause)
    constraints = merge_constraints(inline_constraints, where_constraints)

    return GenericFunctionInfo(String(func_name), String(code), type_params, constraints, "")
end

"""
    _find_matching_angle_bracket(s::AbstractString, open_pos::Int) -> Int

Find the position of the matching closing `>` for an opening `<` at `open_pos`,
correctly handling nested angle brackets like `Vec<Option<T>>`.
Returns 0 if no matching bracket is found.
"""
function _find_matching_angle_bracket(s::AbstractString, open_pos::Int)
    depth = 0
    i = open_pos
    while i <= ncodeunits(s)
        c = s[i]
        if c == '<'
            depth += 1
        elseif c == '>'
            depth -= 1
            if depth == 0
                return i
            end
        end
        i = nextind(s, i)
    end
    return 0
end

"""
    _remove_generic_params_from_fns(code::AbstractString) -> String

Remove generic parameter lists from function signatures (e.g., `fn name<T, Vec<U>>(` -> `fn name(`),
correctly handling nested angle brackets.
"""
function _remove_generic_params_from_fns(code::AbstractString)
    result = code
    # Repeatedly find and remove generic params from fn signatures
    while true
        m = match(r"(fn\s+\w+)\s*<", result)
        m === nothing && break
        open_pos = m.offset + length(m.match) - 1  # position of '<'
        close_pos = _find_matching_angle_bracket(result, open_pos)
        close_pos == 0 && break
        # Skip any whitespace after '>' before '('
        rest = result[nextind(result, close_pos):end]
        rest_trimmed = lstrip(rest)
        ws_len = length(rest) - length(rest_trimmed)
        result = result[1:m.offset + length(m.captures[1]) - 1] * rest[ws_len+1:end]
    end
    return result
end

"""
    _remove_generic_params_from_impls(code::AbstractString) -> String

Remove generic parameter lists from impl blocks (e.g., `impl<T>` -> `impl`),
correctly handling nested angle brackets.
"""
function _remove_generic_params_from_impls(code::AbstractString)
    result = code
    while true
        m = match(r"impl\s*<", result)
        m === nothing && break
        open_pos = m.offset + length(m.match) - 1  # position of '<'
        close_pos = _find_matching_angle_bracket(result, open_pos)
        close_pos == 0 && break
        # Replace impl<...> with impl
        result = result[1:m.offset + 3] * result[nextind(result, close_pos):end]
    end
    return result
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
    # Use bracket-counting instead of regex to correctly handle nested angle brackets
    # like Vec<T>, Option<T>, HashMap<K, V>
    specialized = _remove_generic_params_from_fns(specialized)
    specialized = _remove_generic_params_from_impls(specialized)

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
    # Get generic function info (protect read with REGISTRY_LOCK)
    generic_info = lock(REGISTRY_LOCK) do
        get(GENERIC_FUNCTION_REGISTRY, func_name, nothing)
    end
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

        # Specialize the code (this replaces type parameters with concrete types)
        specialized_code = specialize_generic_code(generic_info.code, type_params)

        # Extract the actual function name from the code (might differ from registered name)
        # Pattern: fn actual_name(
        actual_name_match = match(r"fn\s+(\w+)\s*\(", specialized_code)
        if actual_name_match === nothing
            @debug "Failed to find function name in specialized code" specialized_code
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
        lock(REGISTRY_LOCK) do
            if !haskey(RUST_LIBRARIES, lib_name)
                RUST_LIBRARIES[lib_name] = (lib_handle, Dict{String, Ptr{Cvoid}}())
            end
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
        lock(REGISTRY_LOCK) do
            _, func_cache = RUST_LIBRARIES[lib_name]
            func_cache[specialized_name] = func_ptr
        end

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
    context::String=""
)
    lock(REGISTRY_LOCK) do
        info = GenericFunctionInfo(func_name, code, type_params, constraints, context)
        GENERIC_FUNCTION_REGISTRY[func_name] = info
        return info
    end
end

# Backward compatibility: accept Dict{Symbol, String} and convert to TypeConstraints
function register_generic_function(
    func_name::String,
    code::String,
    type_params::Vector{Symbol},
    constraints::Dict{Symbol, String},
    context::String=""
)
    # Convert old format to new format
    new_constraints = Dict{Symbol, TypeConstraints}()
    for (k, v) in constraints
        new_constraints[k] = parse_trait_bounds(v)
    end
    return register_generic_function(func_name, code, type_params, new_constraints, context)
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
