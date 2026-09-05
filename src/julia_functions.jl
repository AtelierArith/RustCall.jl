# #[julia] attribute support for automatic FFI wrapper generation
# This module handles detection, transformation, and Julia wrapper generation for
# Rust functions marked with #[julia] attribute.

"""
    RustFunctionSignature

Signature of a Rust free function as recorded in the FFI manifest produced by
`rustcall-extract` (see `src/manifest.jl`). Julia never derives this from
source text.

# Fields
- `name`, `arg_names`, `arg_types`, `return_type`: as written in Rust
- `is_generic`, `type_params`, `constraints`: generic parameters and their trait bounds
- `symbol`: exported C symbol (equals `name` unless generic)
- `attribute`: `:julia`, `:julia_pyo3` or `:none`
- `exported`: whether the compiled library exports `symbol`
- `return_kind`: `:plain`, `:unit`, `:result` or `:option`
- `ok_type`/`err_type`/`inner_type`: components of `Result`/`Option` returns
- `source`: function source (generic functions only), used for monomorphization
- `module_path`: enclosing inline modules (`["api", "deep"]`)
"""
struct RustFunctionSignature
    name::String
    arg_names::Vector{String}
    arg_types::Vector{String}
    return_type::String
    is_generic::Bool
    type_params::Vector{String}
    symbol::String
    attribute::Symbol
    exported::Bool
    return_kind::Symbol
    ok_type::String
    err_type::String
    inner_type::String
    source::String
    constraints::Dict{Symbol, TypeConstraints}
    module_path::Vector{String}
    # The body contains `#[cfg]`/`cfg!`, so it still depends on the build
    # configuration after item-level pruning (see `Function::body_has_cfg`).
    body_has_cfg::Bool
end

function RustFunctionSignature(name::String, arg_names::Vector{String}, arg_types::Vector{String},
                               return_type::String, is_generic::Bool, type_params::Vector{String};
                               symbol::String = name, attribute::Symbol = :julia,
                               exported::Bool = !is_generic,
                               return_kind::Symbol = return_type == "()" ? :unit : :plain,
                               ok_type::String = "", err_type::String = "", inner_type::String = "",
                               source::String = "",
                               constraints::Dict{Symbol, TypeConstraints} = Dict{Symbol, TypeConstraints}(),
                               module_path::Vector{String} = String[],
                               body_has_cfg::Bool = false)
    RustFunctionSignature(name, arg_names, arg_types, return_type, is_generic, type_params,
                          symbol, attribute, exported, return_kind, ok_type, err_type, inner_type,
                          source, constraints, module_path, body_has_cfg)
end

"""
    qualified_name(sig_or_info) -> String

`module_path::name` of a manifest entry, as accepted by `rustcall-extract specialize`.
"""
qualified_name(module_path::Vector{String}, name::String) = join(vcat(module_path, [name]), "::")

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
            # Generic functions are registered for monomorphization at load time
            # and called through `@rust`; no static wrapper is emitted.
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

    if sig.return_kind == :result
        return _generate_inline_result_wrapper(sig, func_name, func_name_str, arg_syms, converted_args)
    elseif sig.return_kind == :option
        return _generate_inline_option_wrapper(sig, func_name, func_name_str, arg_syms, converted_args)
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

# Result<T, E> / Option<T> returning #[julia] functions in inline blocks: the
# extractor generates `CResult_<fn>` / `COption_<fn>` on the Rust side; the
# wrapper reads that struct and converts it to RustResult / RustOption.
function _generate_inline_result_wrapper(sig, func_name, func_name_str, arg_syms, converted_args)
    ok_t = something(_rust_type_to_julia_type_symbol(sig.ok_type), :Any)
    err_t = something(_rust_type_to_julia_type_symbol(sig.err_type), :Any)
    quote
        function $func_name($(arg_syms...))
            lib_name = RustCall.get_current_library()
            func_ptr = RustCall.get_function_pointer(lib_name, $func_name_str)
            c = RustCall.call_rust_function(func_ptr, RustCall.CResultType{$ok_t, $err_t}, $(converted_args...))
            RustCall.convert_c_result_to_rust_result(c, $ok_t, $err_t)
        end
    end
end

function _generate_inline_option_wrapper(sig, func_name, func_name_str, arg_syms, converted_args)
    inner_t = something(_rust_type_to_julia_type_symbol(sig.inner_type), :Any)
    quote
        function $func_name($(arg_syms...))
            lib_name = RustCall.get_current_library()
            func_ptr = RustCall.get_function_pointer(lib_name, $func_name_str)
            c = RustCall.call_rust_function(func_ptr, RustCall.COptionType{$inner_t}, $(converted_args...))
            RustCall.convert_c_option_to_rust_option(c, $inner_t)
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
