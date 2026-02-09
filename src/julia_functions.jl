# #[julia] attribute support for automatic FFI wrapper generation
# This module handles detection, transformation, and Julia wrapper generation for
# Rust functions marked with #[julia] attribute.

"""
    RustFunctionSignature

Represents a parsed Rust function signature marked with #[julia].
"""
struct RustFunctionSignature
    name::String
    arg_names::Vector{String}
    arg_types::Vector{String}
    return_type::String
    is_generic::Bool
    type_params::Vector{String}
end

"""
    parse_julia_functions(code::String) -> Vector{RustFunctionSignature}

Parse Rust code and extract functions marked with `#[julia]` attribute.

# Example
```rust
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
```

Returns a vector of `RustFunctionSignature` for each `#[julia]` marked function.
"""
function parse_julia_functions(code::String)
    signatures = RustFunctionSignature[]

    # Use a two-step approach:
    # 1. Find #[julia] or #[julia_pyo3] markers with regex
    # 2. Parse the function signature using bracket-counting for generics
    #
    # This handles nested generic types like HashMap<String, Vec<Option<i32>>>
    # which regex alone cannot match correctly.
    attr_pattern = r"#\[julia(?:_pyo3)?\]\s*(?:pub\s+)?fn\s+(\w+)\s*"

    for m in eachmatch(attr_pattern, code)
        func_name = String(m.captures[1])

        # Position right after "fn name"
        pos = m.offset + length(m.match)

        # Check for generic parameters: <...>
        type_params_str = nothing
        is_generic = false
        if pos <= ncodeunits(code) && code[pos] == '<'
            close_pos = _find_matching_angle_bracket_jf(code, pos)
            if close_pos > 0
                type_params_str = code[nextind(code, pos):prevind(code, close_pos)]
                pos = nextind(code, close_pos)
                # Skip whitespace
                while pos <= ncodeunits(code) && isspace(code[pos])
                    pos = nextind(code, pos)
                end
            end
        end

        # Expect '('
        if pos > ncodeunits(code) || code[pos] != '('
            continue
        end

        # Find matching ')' using bracket counting
        paren_close = _find_matching_paren(code, pos)
        if paren_close == 0
            continue
        end
        args_str = code[nextind(code, pos):prevind(code, paren_close)]

        # Parse return type: look for -> ... {
        return_type = "()"
        rest_pos = nextind(code, paren_close)
        # Skip whitespace
        while rest_pos <= ncodeunits(code) && isspace(code[rest_pos])
            rest_pos = nextind(code, rest_pos)
        end
        if rest_pos + 1 <= ncodeunits(code) && code[rest_pos] == '-' && code[nextind(code, rest_pos)] == '>'
            # Found return type
            ret_start = nextind(code, nextind(code, rest_pos))
            # Find '{' at depth 0
            brace_pos = _find_open_brace(code, ret_start)
            if brace_pos > 0
                return_type = strip(code[ret_start:prevind(code, brace_pos)])
            end
        end

        # Parse type parameters
        type_params = String[]
        if type_params_str !== nothing && !isempty(strip(type_params_str))
            is_generic = true
            # Split by comma at depth 0
            for param_str in _split_at_depth_zero(type_params_str, ',')
                param = strip(param_str)
                if startswith(param, "'")
                    continue
                end
                if occursin(':', param)
                    param = strip(split(param, ':')[1])
                end
                push!(type_params, param)
            end
        end

        # Parse arguments
        arg_names = String[]
        arg_types = String[]

        if !isempty(strip(args_str))
            for arg_part in _split_at_depth_zero(args_str, ',')
                _parse_single_arg!(arg_names, arg_types, strip(arg_part))
            end
        end

        push!(signatures, RustFunctionSignature(
            func_name, arg_names, arg_types, return_type, is_generic, type_params
        ))
    end

    return signatures
end

"""
    _find_matching_angle_bracket_jf(s, open_pos) -> Int

Find the matching '>' for '<' at open_pos, handling nesting. Returns 0 if not found.
"""
function _find_matching_angle_bracket_jf(s::AbstractString, open_pos::Int)
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
    _find_matching_paren(s, open_pos) -> Int

Find the matching ')' for '(' at open_pos, handling nesting. Returns 0 if not found.
"""
function _find_matching_paren(s::AbstractString, open_pos::Int)
    depth = 0
    i = open_pos
    while i <= ncodeunits(s)
        c = s[i]
        if c == '('
            depth += 1
        elseif c == ')'
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
    _find_open_brace(s, start_pos) -> Int

Find the next '{' at bracket depth 0, starting from start_pos. Returns 0 if not found.
"""
function _find_open_brace(s::AbstractString, start_pos::Int)
    depth = 0
    i = start_pos
    while i <= ncodeunits(s)
        c = s[i]
        if c == '<'
            depth += 1
        elseif c == '>'
            depth -= 1
        elseif c == '{' && depth == 0
            return i
        end
        i = nextind(s, i)
    end
    return 0
end

"""
    _split_at_depth_zero(s, delimiter) -> Vector{String}

Split string by delimiter only when bracket depth (angle, paren, square) is zero.
"""
function _split_at_depth_zero(s::AbstractString, delimiter::Char)
    parts = String[]
    current = IOBuffer()
    angle = 0
    paren = 0
    bracket = 0

    for c in s
        if c == '<'
            angle += 1
            write(current, c)
        elseif c == '>'
            angle = max(0, angle - 1)
            write(current, c)
        elseif c == '('
            paren += 1
            write(current, c)
        elseif c == ')'
            paren = max(0, paren - 1)
            write(current, c)
        elseif c == '['
            bracket += 1
            write(current, c)
        elseif c == ']'
            bracket = max(0, bracket - 1)
            write(current, c)
        elseif c == delimiter && angle == 0 && paren == 0 && bracket == 0
            push!(parts, String(take!(current)))
        else
            write(current, c)
        end
    end

    last = String(take!(current))
    if !isempty(strip(last))
        push!(parts, last)
    end

    return parts
end

"""
    _parse_single_arg!(names::Vector{String}, types::Vector{String}, arg::AbstractString)

Parse a single function argument "name: type" and add to the vectors.
"""
function _parse_single_arg!(names::Vector{String}, types::Vector{String}, arg::AbstractString)
    if isempty(arg)
        return
    end

    # Skip self parameters
    if arg in ["self", "&self", "&mut self"]
        return
    end

    # Parse "name: type"
    if occursin(':', arg)
        parts = split(arg, ':', limit=2)
        push!(names, strip(String(parts[1])))
        push!(types, strip(String(parts[2])))
    end
end

"""
    transform_julia_attribute(code::String) -> String

Transform `#[julia]` attributes in Rust code:
- For functions: `#[julia] fn` → `#[no_mangle] pub extern "C" fn`
- For structs: `#[julia] pub struct` → `#[derive(JuliaStruct)] pub struct`

# Example
Input:
```rust
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[julia]
pub struct Point {
    x: f64,
    y: f64,
}
```

Output:
```rust
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[derive(JuliaStruct)]
pub struct Point {
    x: f64,
    y: f64,
}
```
"""
function transform_julia_attribute(code::String)
    result = code

    # Transform structs first (before functions to avoid conflicts)
    # Pattern: #[julia] pub struct -> #[derive(JuliaStruct)] pub struct
    result = replace(result, r"#\[julia\]\s*pub\s+struct\s+" => "#[derive(JuliaStruct)]\npub struct ")

    # Pattern: #[julia] struct -> #[derive(JuliaStruct)] pub struct (make it pub)
    result = replace(result, r"#\[julia\]\s*struct\s+" => "#[derive(JuliaStruct)]\npub struct ")

    # Transform functions
    # Pattern 1: #[julia] fn -> #[no_mangle] pub extern "C" fn
    result = replace(result, r"#\[julia\]\s*fn\s+" => "#[no_mangle]\npub extern \"C\" fn ")

    # Pattern 2: #[julia] pub fn -> #[no_mangle] pub extern "C" fn
    result = replace(result, r"#\[julia\]\s*pub\s+fn\s+" => "#[no_mangle]\npub extern \"C\" fn ")

    return result
end

"""
    emit_julia_function_wrappers(signatures::Vector{RustFunctionSignature}) -> Expr

Generate Julia wrapper functions for the given Rust function signatures.

For a function like:
```rust
#[julia]
fn add(a: i32, b: i32) -> i32 { ... }
```

Generates:
```julia
add(a, b) = @rust add(Int32(a), Int32(b))::Int32
```
"""
function emit_julia_function_wrappers(signatures::Vector{RustFunctionSignature})
    exprs = Expr[]

    for sig in signatures
        if sig.is_generic
            # Generic functions need special handling - skip for now
            # They should be registered via the generics system
            @debug "Skipping generic function wrapper generation for $(sig.name)"
            continue
        end

        wrapper_expr = _generate_single_wrapper(sig)
        if wrapper_expr !== nothing
            push!(exprs, wrapper_expr)
        end
    end

    if isempty(exprs)
        return :()
    end

    return Expr(:block, exprs...)
end

"""
    _generate_single_wrapper(sig::RustFunctionSignature) -> Union{Expr, Nothing}

Generate a Julia wrapper function for a single Rust function signature.
Uses direct function call instead of @rust macro for better scope handling.
"""
function _generate_single_wrapper(sig::RustFunctionSignature)
    func_name_str = sig.name
    func_name = esc(Symbol(func_name_str))

    # Build argument list with conversion
    arg_syms = [esc(Symbol(name)) for name in sig.arg_names]

    # Build converted arguments
    converted_args = Expr[]
    arg_types = Symbol[]
    for (name, rust_type) in zip(sig.arg_names, sig.arg_types)
        julia_type = _rust_type_to_julia_conversion_type(rust_type)
        arg_sym = esc(Symbol(name))

        if julia_type !== nothing
            # Add type conversion: Type(arg)
            push!(converted_args, :($julia_type($arg_sym)))
            push!(arg_types, julia_type)
        else
            # No conversion needed
            push!(converted_args, arg_sym)
            push!(arg_types, :Any)
        end
    end

    # Get Julia return type
    julia_ret_type = _rust_type_to_julia_type_symbol(sig.return_type)
    if julia_ret_type === nothing
        julia_ret_type = :Any
    end

    # Generate the wrapper function using internal API directly
    # This avoids macro expansion issues
    return quote
        function $func_name($(arg_syms...))
            lib_name = RustCall.get_current_library()
            func_ptr = RustCall.get_function_pointer(lib_name, $func_name_str)
            RustCall.call_rust_function(func_ptr, $julia_ret_type, $(converted_args...))
        end
    end
end

"""
    _rust_type_to_julia_conversion_type(rust_type::String) -> Union{Symbol, Nothing}

Get the Julia type to use for argument conversion from Rust type.
Returns Nothing if no conversion is needed or type is unknown.
"""
function _rust_type_to_julia_conversion_type(rust_type::String)
    type_map = Dict(
        "i8" => :Int8,
        "i16" => :Int16,
        "i32" => :Int32,
        "i64" => :Int64,
        "u8" => :UInt8,
        "u16" => :UInt16,
        "u32" => :UInt32,
        "u64" => :UInt64,
        "f32" => :Float32,
        "f64" => :Float64,
        "bool" => :Bool,
        "usize" => :Csize_t,
        "isize" => :Cssize_t,
    )

    return get(type_map, strip(rust_type), nothing)
end

"""
    _rust_type_to_julia_type_symbol(rust_type::String) -> Union{Symbol, Nothing}

Get the Julia type symbol for return type annotation.
"""
function _rust_type_to_julia_type_symbol(rust_type::String)
    rust_type = strip(rust_type)

    type_map = Dict(
        "i8" => :Int8,
        "i16" => :Int16,
        "i32" => :Int32,
        "i64" => :Int64,
        "u8" => :UInt8,
        "u16" => :UInt16,
        "u32" => :UInt32,
        "u64" => :UInt64,
        "f32" => :Float32,
        "f64" => :Float64,
        "bool" => :Bool,
        "usize" => :Csize_t,
        "isize" => :Cssize_t,
        "()" => :Cvoid,
    )

    return get(type_map, rust_type, nothing)
end

# ============================================================================
# Result<T, E> and Option<T> Support
# ============================================================================

"""
    ResultTypeInfo

Parsed information about a Result<T, E> return type.
"""
struct ResultTypeInfo
    ok_type::String
    err_type::String
end

"""
    OptionTypeInfo

Parsed information about an Option<T> return type.
"""
struct OptionTypeInfo
    inner_type::String
end

"""
    parse_result_type(rust_type::String) -> Union{ResultTypeInfo, Nothing}

Parse a Result<T, E> type string and extract T and E.
Returns nothing if not a Result type.
"""
function parse_result_type(rust_type::String)
    rust_type = strip(rust_type)

    # Match the "Result<" prefix
    m = match(r"^Result\s*<", rust_type)
    if m === nothing
        return nothing
    end

    # Extract the inner content between "Result<" and the final ">"
    inner_start = m.offset + length(m.match)
    # The last character must be '>'
    if rust_type[end] != '>'
        return nothing
    end
    inner = rust_type[inner_start:prevind(rust_type, lastindex(rust_type))]

    # Find the comma that separates ok_type and err_type at bracket depth 0
    depth = 0
    for i in eachindex(inner)
        c = inner[i]
        if c in ('<', '(', '[')
            depth += 1
        elseif c in ('>', ')', ']')
            depth -= 1
        elseif c == ',' && depth == 0
            ok_type = strip(inner[1:prevind(inner, i)])
            err_type = strip(inner[nextind(inner, i):end])
            return ResultTypeInfo(ok_type, err_type)
        end
    end

    return nothing
end

"""
    parse_option_type(rust_type::String) -> Union{OptionTypeInfo, Nothing}

Parse an Option<T> type string and extract T.
Returns nothing if not an Option type.
"""
function parse_option_type(rust_type::String)
    rust_type = strip(rust_type)

    # Match the "Option<" prefix
    m = match(r"^Option\s*<", rust_type)
    if m === nothing
        return nothing
    end

    # Extract the inner content between "Option<" and the final ">"
    inner_start = m.offset + length(m.match)
    # The last character must be '>'
    if rust_type[end] != '>'
        return nothing
    end
    inner_type = strip(rust_type[inner_start:prevind(rust_type, lastindex(rust_type))])

    if isempty(inner_type)
        return nothing
    end

    return OptionTypeInfo(inner_type)
end

"""
    is_result_type(rust_type::String) -> Bool

Check if a Rust type is Result<T, E>.
"""
function is_result_type(rust_type::String)
    return parse_result_type(rust_type) !== nothing
end

"""
    is_option_type(rust_type::String) -> Bool

Check if a Rust type is Option<T>.
"""
function is_option_type(rust_type::String)
    return parse_option_type(rust_type) !== nothing
end

"""
    CResultType{T, E}

C-compatible struct for Result<T, E> returned by FFI functions.
Generated by #[julia] proc-macro as `CResult_<function_name>`.
"""
struct CResultType{T, E}
    is_ok::UInt8
    ok_value::T
    err_value::E
end

"""
    COptionType{T}

C-compatible struct for Option<T> returned by FFI functions.
Generated by #[julia] proc-macro as `COption_<function_name>`.
"""
struct COptionType{T}
    is_some::UInt8
    value::T
end

"""
    generate_c_result_struct_type(func_name::String, ok_type::Symbol, err_type::Symbol) -> Expr

Generate a Julia struct definition for the C-compatible Result type.
"""
function generate_c_result_struct_type(func_name::String, ok_type::Symbol, err_type::Symbol)
    struct_name = Symbol("CResult_", func_name)
    quote
        struct $struct_name
            is_ok::UInt8
            ok_value::$ok_type
            err_value::$err_type
        end
    end
end

"""
    generate_c_option_struct_type(func_name::String, inner_type::Symbol) -> Expr

Generate a Julia struct definition for the C-compatible Option type.
"""
function generate_c_option_struct_type(func_name::String, inner_type::Symbol)
    struct_name = Symbol("COption_", func_name)
    quote
        struct $struct_name
            is_some::UInt8
            value::$inner_type
        end
    end
end

"""
    convert_c_result_to_rust_result(c_result, ok_type::Type, err_type::Type) -> RustResult

Convert a C-compatible result struct to RustResult{T, E}.
"""
function convert_c_result_to_rust_result(c_result, ::Type{T}, ::Type{E}) where {T, E}
    if c_result.is_ok == 1
        RustResult{T, E}(true, c_result.ok_value)
    else
        RustResult{T, E}(false, c_result.err_value)
    end
end

"""
    convert_c_option_to_rust_option(c_option, inner_type::Type) -> RustOption

Convert a C-compatible option struct to RustOption{T}.
"""
function convert_c_option_to_rust_option(c_option, ::Type{T}) where {T}
    if c_option.is_some == 1
        RustOption{T}(true, c_option.value)
    else
        RustOption{T}(false, nothing)
    end
end

"""
    has_julia_attribute(code::String) -> Bool

Check if the code contains any `#[julia]` or `#[julia_pyo3]` attributes.
"""
function has_julia_attribute(code::String)
    return occursin(r"#\[julia(?:_pyo3)?\]", code)
end
