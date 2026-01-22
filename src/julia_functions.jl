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

    # Pattern to match #[julia] followed by fn definition
    # Handles:
    # - #[julia] fn name(...)
    # - #[julia] pub fn name(...)
    # - #[julia]\npub fn name(...)
    # - #[julia] fn name<T>(...)
    pattern = r"#\[julia\]\s*(?:pub\s+)?fn\s+(\w+)\s*(?:<([^>]+)>)?\s*\(([^)]*)\)(?:\s*->\s*([^\{]+))?\s*\{"

    for m in eachmatch(pattern, code)
        func_name = String(m.captures[1])
        type_params_str = m.captures[2]
        args_str = m.captures[3] !== nothing ? String(m.captures[3]) : ""
        return_type = m.captures[4] !== nothing ? strip(String(m.captures[4])) : "()"

        # Parse type parameters
        type_params = String[]
        is_generic = false
        if type_params_str !== nothing && !isempty(type_params_str)
            is_generic = true
            for param in split(type_params_str, ',')
                param = strip(param)
                # Handle trait bounds: T: Copy -> just T
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
            # Parse each argument, handling nested generics
            current_arg = ""
            bracket_level = 0

            for char in args_str
                if char in ['<', '(', '[']
                    bracket_level += 1
                    current_arg *= char
                elseif char in ['>', ')', ']']
                    bracket_level -= 1
                    current_arg *= char
                elseif char == ',' && bracket_level == 0
                    _parse_single_arg!(arg_names, arg_types, strip(current_arg))
                    current_arg = ""
                else
                    current_arg *= char
                end
            end

            # Process last argument
            if !isempty(strip(current_arg))
                _parse_single_arg!(arg_names, arg_types, strip(current_arg))
            end
        end

        push!(signatures, RustFunctionSignature(
            func_name, arg_names, arg_types, return_type, is_generic, type_params
        ))
    end

    return signatures
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
            lib_name = LastCall.get_current_library()
            func_ptr = LastCall.get_function_pointer(lib_name, $func_name_str)
            LastCall.call_rust_function(func_ptr, $julia_ret_type, $(converted_args...))
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

"""
    has_julia_attribute(code::String) -> Bool

Check if the code contains any `#[julia]` attributes.
"""
function has_julia_attribute(code::String)
    return occursin(r"#\[julia\]", code)
end
