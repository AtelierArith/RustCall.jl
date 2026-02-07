# External crate bindings generator (Maturin-like feature)
# This module provides automatic Julia bindings generation for external Rust crates
# that use the #[julia] attribute from rustcall_macros.

using TOML
using SHA

# ============================================================================
# Type Definitions
# ============================================================================

"""
    CrateInfo

Information about a Rust crate for binding generation.

# Fields
- `name::String`: Crate name from Cargo.toml
- `path::String`: Path to the crate root directory
- `version::String`: Crate version
- `dependencies::Vector{DependencySpec}`: Crate dependencies
- `julia_functions::Vector{RustFunctionSignature}`: Functions marked with #[julia]
- `julia_structs::Vector{RustStructInfo}`: Structs marked with #[julia]
- `source_files::Vector{String}`: Paths to .rs source files
"""
struct CrateInfo
    name::String
    path::String
    version::String
    dependencies::Vector{DependencySpec}
    julia_functions::Vector{RustFunctionSignature}
    julia_structs::Vector{RustStructInfo}
    source_files::Vector{String}
end

"""
    CrateBindingOptions

Options for binding generation.

# Fields
- `output_module_name::Union{String, Nothing}`: Name for the generated module (default: crate name)
- `output_path::Union{String, Nothing}`: Path to write generated Julia code
- `use_wrapper_crate::Bool`: Whether to create a wrapper crate for building
- `build_release::Bool`: Build in release mode
- `cache_enabled::Bool`: Enable caching of compiled libraries
"""
struct CrateBindingOptions
    output_module_name::Union{String, Nothing}
    output_path::Union{String, Nothing}
    use_wrapper_crate::Bool
    build_release::Bool
    cache_enabled::Bool
end

"""
    CrateBindingOptions(; kwargs...) -> CrateBindingOptions

Create binding options with defaults.
"""
function CrateBindingOptions(;
    output_module_name::Union{String, Nothing} = nothing,
    output_path::Union{String, Nothing} = nothing,
    use_wrapper_crate::Bool = true,
    build_release::Bool = true,
    cache_enabled::Bool = true
)
    CrateBindingOptions(output_module_name, output_path, use_wrapper_crate, build_release, cache_enabled)
end

# ============================================================================
# Crate Scanning Functions
# ============================================================================

"""
    scan_crate(crate_path::String) -> CrateInfo

Scan a Rust crate and extract information about #[julia] marked items.

# Arguments
- `crate_path::String`: Path to the crate root directory (containing Cargo.toml)

# Returns
- `CrateInfo`: Information about the crate including functions and structs

# Example
```julia
info = scan_crate("/path/to/my_crate")
println("Found \$(length(info.julia_functions)) Julia functions")
```
"""
function scan_crate(crate_path::String)
    # Validate path
    if !isdir(crate_path)
        error("Crate path does not exist: $crate_path")
    end

    cargo_toml_path = joinpath(crate_path, "Cargo.toml")
    if !isfile(cargo_toml_path)
        error("Cargo.toml not found in: $crate_path")
    end

    # Parse Cargo.toml
    cargo_toml = parse_cargo_toml(cargo_toml_path)

    # Find all Rust source files
    source_files = find_rust_sources(crate_path)

    # Scan each source file for #[julia] items
    all_functions = RustFunctionSignature[]
    all_structs = RustStructInfo[]

    for src_file in source_files
        code = read(src_file, String)

        # Parse #[julia] functions
        funcs = parse_julia_functions(code)
        append!(all_functions, funcs)

        # Parse #[julia] structs (detected as #[derive(JuliaStruct)] after transformation)
        # But we also need to detect the original #[julia] pub struct pattern
        structs = parse_julia_structs_from_source(code)
        append!(all_structs, structs)
    end

    # Extract dependencies from Cargo.toml
    dependencies = extract_crate_dependencies(cargo_toml)

    CrateInfo(
        cargo_toml["package"]["name"],
        abspath(crate_path),
        get(cargo_toml["package"], "version", "0.1.0"),
        dependencies,
        all_functions,
        all_structs,
        source_files
    )
end

"""
    parse_cargo_toml(path::String) -> Dict

Parse a Cargo.toml file and return its contents as a dictionary.
"""
function parse_cargo_toml(path::String)
    TOML.parsefile(path)
end

"""
    find_rust_sources(crate_path::String) -> Vector{String}

Find all .rs files in a crate's src directory.
"""
function find_rust_sources(crate_path::String)
    src_dir = joinpath(crate_path, "src")
    if !isdir(src_dir)
        return String[]
    end

    sources = String[]
    _find_rs_files_recursive!(sources, src_dir)
    return sources
end

function _find_rs_files_recursive!(sources::Vector{String}, dir::String)
    for entry in readdir(dir, join=true)
        if isfile(entry) && endswith(entry, ".rs")
            push!(sources, entry)
        elseif isdir(entry)
            _find_rs_files_recursive!(sources, entry)
        end
    end
end

"""
    parse_julia_structs_from_source(code::String) -> Vector{RustStructInfo}

Parse Rust source code and extract structs marked with #[julia] or #[julia_pyo3].
"""
function parse_julia_structs_from_source(code::String)
    structs = RustStructInfo[]

    # Pattern to match #[julia] or #[julia_pyo3] pub struct or struct
    pattern = r"#\[julia(?:_pyo3)?\]\s*(?:pub\s+)?struct\s+([A-Z]\w*)\s*(?:<([^>]+)>)?\s*\{"

    for m in eachmatch(pattern, code)
        struct_name = String(m.captures[1])
        type_params_str = m.captures[2]

        # Parse type parameters
        type_params = String[]
        if type_params_str !== nothing && !isempty(type_params_str)
            for p in split(type_params_str, ',')
                p = strip(p)
                if occursin(':', p)
                    p = strip(split(p, ':')[1])
                end
                push!(type_params, p)
            end
        end

        # Extract struct definition block
        struct_def = extract_block_at(code, m.offset)
        context = struct_def !== nothing ? struct_def : ""

        # Parse fields
        fields = parse_struct_fields(context)

        # Find impl blocks for this struct
        methods = parse_impl_methods_for_struct(code, struct_name)

        push!(structs, RustStructInfo(
            struct_name,
            type_params,
            methods,
            context,
            fields,
            true,  # has_derive_julia_struct
            Dict{String, Bool}()
        ))
    end

    return structs
end

"""
    parse_impl_methods_for_struct(code::String, struct_name::String) -> Vector{RustMethod}

Parse impl blocks for a struct and extract methods marked with #[julia] or #[julia_pyo3].
If the impl block itself has #[julia_pyo3], all pub fn methods are captured.
"""
function parse_impl_methods_for_struct(code::String, struct_name::String)
    methods = RustMethod[]

    # Pattern to find impl blocks with #[julia_pyo3] attribute (captures ALL pub fn)
    impl_pattern_pyo3 = Regex("#\\[julia_pyo3\\]\\s*impl(?:\\s*<[^>]+>)?\\s+$struct_name(?:\\s*<[^>]+>)?\\s*\\{")

    # Pattern to find regular impl blocks (only captures #[julia] methods)
    impl_pattern_regular = Regex("(?<!#\\[julia_pyo3\\]\\s)impl(?:\\s*<[^>]+>)?\\s+$struct_name(?:\\s*<[^>]+>)?\\s*\\{")

    # First, process #[julia_pyo3] impl blocks - capture ALL pub fn methods
    for impl_match in eachmatch(impl_pattern_pyo3, code)
        impl_block = extract_block_at(code, impl_match.offset)
        if impl_block === nothing
            continue
        end

        # Match ALL pub fn methods in this impl block
        method_pattern = r"pub\s+fn\s+(\w+)\s*\(([^)]*)\)(?:\s*->\s*([^\{]+))?\s*\{"

        for method_match in eachmatch(method_pattern, impl_block)
            method_name = String(method_match.captures[1])
            args_str = method_match.captures[2] !== nothing ? String(method_match.captures[2]) : ""
            return_type = method_match.captures[3] !== nothing ? strip(String(method_match.captures[3])) : "()"

            is_static = !occursin("self", args_str)
            is_mutable = occursin("&mut self", args_str)

            arg_names = String[]
            arg_types = String[]
            _parse_method_args!(arg_names, arg_types, args_str)

            push!(methods, RustMethod(method_name, is_static, is_mutable, arg_names, arg_types, return_type))
        end
    end

    # Then, process regular impl blocks with #[julia] on individual methods
    for impl_match in eachmatch(impl_pattern_regular, code)
        impl_block = extract_block_at(code, impl_match.offset)
        if impl_block === nothing
            continue
        end

        # Only match methods with explicit #[julia] attribute
        method_pattern = r"#\[julia\]\s*pub\s+fn\s+(\w+)\s*\(([^)]*)\)(?:\s*->\s*([^\{]+))?\s*\{"

        for method_match in eachmatch(method_pattern, impl_block)
            method_name = String(method_match.captures[1])
            args_str = method_match.captures[2] !== nothing ? String(method_match.captures[2]) : ""
            return_type = method_match.captures[3] !== nothing ? strip(String(method_match.captures[3])) : "()"

            is_static = !occursin("self", args_str)
            is_mutable = occursin("&mut self", args_str)

            arg_names = String[]
            arg_types = String[]
            _parse_method_args!(arg_names, arg_types, args_str)

            # Avoid duplicates
            if !any(m -> m.name == method_name, methods)
                push!(methods, RustMethod(method_name, is_static, is_mutable, arg_names, arg_types, return_type))
            end
        end
    end

    return methods
end

function _parse_method_args!(names::Vector{String}, types::Vector{String}, args_str::AbstractString)
    if isempty(strip(args_str))
        return
    end

    # Split by comma, handling nested brackets
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
            _parse_single_method_arg!(names, types, strip(current_arg))
            current_arg = ""
        else
            current_arg *= char
        end
    end

    if !isempty(strip(current_arg))
        _parse_single_method_arg!(names, types, strip(current_arg))
    end
end

function _parse_single_method_arg!(names::Vector{String}, types::Vector{String}, arg::AbstractString)
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
    extract_crate_dependencies(cargo_toml::Dict) -> Vector{DependencySpec}

Extract dependencies from parsed Cargo.toml.
"""
function extract_crate_dependencies(cargo_toml::Dict)
    dependencies = DependencySpec[]

    deps_section = get(cargo_toml, "dependencies", Dict())

    for (name, spec) in deps_section
        if isa(spec, String)
            # Simple version string
            push!(dependencies, DependencySpec(name, version=spec))
        elseif isa(spec, Dict)
            # Complex dependency specification
            version = get(spec, "version", nothing)
            features = get(spec, "features", String[])
            git = get(spec, "git", nothing)
            path = get(spec, "path", nothing)
            push!(dependencies, DependencySpec(name, version=version, features=features, git=git, path=path))
        end
    end

    return dependencies
end

# ============================================================================
# Wrapper Crate Generation
# ============================================================================

"""
    create_wrapper_crate(info::CrateInfo, opts::CrateBindingOptions) -> String

Create a wrapper crate that depends on the target crate and re-exports #[julia] items.

# Returns
- `String`: Path to the created wrapper crate directory
"""
function create_wrapper_crate(info::CrateInfo, opts::CrateBindingOptions)
    # Create temporary directory for wrapper crate
    wrapper_path = mktempdir(prefix="rustcall_wrapper_")

    # Generate Cargo.toml
    cargo_toml_content = generate_wrapper_cargo_toml(info, opts)
    write(joinpath(wrapper_path, "Cargo.toml"), cargo_toml_content)

    # Generate src/lib.rs
    src_dir = joinpath(wrapper_path, "src")
    mkpath(src_dir)
    lib_rs_content = generate_wrapper_lib_rs(info)
    write(joinpath(src_dir, "lib.rs"), lib_rs_content)

    return wrapper_path
end

"""
    generate_wrapper_cargo_toml(info::CrateInfo, opts::CrateBindingOptions) -> String

Generate Cargo.toml content for the wrapper crate.
"""
function generate_wrapper_cargo_toml(info::CrateInfo, opts::CrateBindingOptions)
    lines = String[]

    # Package section
    push!(lines, "[package]")
    push!(lines, "name = \"$(info.name)_julia_wrapper\"")
    push!(lines, "version = \"0.1.0\"")
    push!(lines, "edition = \"2021\"")
    push!(lines, "")

    # Library section - build as cdylib for FFI
    push!(lines, "[lib]")
    push!(lines, "crate-type = [\"cdylib\"]")
    push!(lines, "")

    # Dependencies section
    push!(lines, "[dependencies]")
    # Add the target crate as a path dependency
    push!(lines, "$(info.name) = { path = \"$(info.path)\" }")
    # Add rustcall_macros (use path for now, will be crates.io later)
    rustcall_macros_path = joinpath(dirname(dirname(@__FILE__)), "deps", "rustcall_macros")
    if isdir(rustcall_macros_path)
        push!(lines, "rustcall_macros = { path = \"$rustcall_macros_path\" }")
    else
        push!(lines, "rustcall_macros = \"0.1\"")
    end
    push!(lines, "")

    # Profile for release builds
    push!(lines, "[profile.release]")
    push!(lines, "opt-level = 3")
    push!(lines, "lto = true")

    join(lines, "\n")
end

"""
    generate_wrapper_lib_rs(info::CrateInfo) -> String

Generate lib.rs content for the wrapper crate that re-exports #[julia] items.
"""
function generate_wrapper_lib_rs(info::CrateInfo)
    lines = String[]

    push!(lines, "// Auto-generated wrapper crate for $(info.name)")
    push!(lines, "// Generated by RustCall.jl")
    push!(lines, "")
    push!(lines, "use $(info.name)::*;")
    push!(lines, "")

    # Re-export functions (they should already have #[no_mangle] from the proc-macro)
    for func in info.julia_functions
        push!(lines, "// Function: $(func.name) is re-exported from $(info.name)")
    end
    push!(lines, "")

    # Re-export structs and their FFI functions
    for s in info.julia_structs
        push!(lines, "// Struct $(s.name) and its FFI functions are re-exported from $(info.name)")
    end

    join(lines, "\n")
end

# ============================================================================
# Julia Module Generation
# ============================================================================

"""
    emit_crate_module(info::CrateInfo, lib_path::String; module_name::Union{String, Nothing}=nothing) -> Expr

Generate a Julia module expression containing bindings for the crate.

# Arguments
- `info::CrateInfo`: Crate information from scan_crate
- `lib_path::String`: Path to the compiled shared library

# Keyword Arguments
- `module_name::Union{String, Nothing}`: Name for the module (default: crate name with first letter capitalized)

# Returns
- `Expr`: A module expression that can be evaluated
"""
function emit_crate_module(info::CrateInfo, lib_path::String; module_name::Union{String, Nothing}=nothing)
    # Determine module name
    mod_name = if module_name !== nothing
        Symbol(module_name)
    else
        Symbol(snake_to_pascal(info.name))
    end

    # Generate function wrappers
    func_defs = generate_crate_function_wrappers(info, lib_path)

    # Generate struct definitions and wrappers
    struct_defs = generate_crate_struct_wrappers(info, lib_path)

    # Build the module body as a block
    module_body = quote
        import RustCall: call_rust_function, get_function_pointer_from_lib
        import Libdl

        const _LIB_PATH = $lib_path
        const _LIB_HANDLE = Ref{Ptr{Cvoid}}(C_NULL)

        function __init__()
            _LIB_HANDLE[] = Libdl.dlopen(_LIB_PATH, Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW)
        end

        function _get_func_ptr(name::String)
            if _LIB_HANDLE[] == C_NULL
                error("Library not loaded. Call __init__() first.")
            end
            Libdl.dlsym(_LIB_HANDLE[], name)
        end

        $func_defs
        $struct_defs
    end

    # Return a clean module expression (not wrapped in a block)
    # The module expression format is: Expr(:module, not_baremodule, name, body)
    Expr(:module, true, mod_name, module_body)
end

"""
    generate_crate_function_wrappers(info::CrateInfo, lib_path::String) -> Expr

Generate Julia wrapper functions for all #[julia] functions in the crate.
"""
function generate_crate_function_wrappers(info::CrateInfo, lib_path::String)
    exprs = Expr[]

    for func in info.julia_functions
        if func.is_generic
            continue  # Skip generics for now
        end

        wrapper = _generate_crate_function_wrapper(func)
        push!(exprs, wrapper)
    end

    if isempty(exprs)
        return :()
    end

    Expr(:block, exprs...)
end

function _generate_crate_function_wrapper(func::RustFunctionSignature)
    func_name = Symbol(func.name)
    func_name_str = func.name

    # Build argument list
    arg_syms = [Symbol(name) for name in func.arg_names]

    # Build converted arguments with type conversion
    converted_args = Expr[]
    for (name, rust_type) in zip(func.arg_names, func.arg_types)
        julia_type = _rust_type_to_julia_conversion_type(rust_type)
        arg_sym = Symbol(name)

        if julia_type !== nothing
            push!(converted_args, :($julia_type($arg_sym)))
        else
            push!(converted_args, arg_sym)
        end
    end

    # Check if return type is Result<T, E> or Option<T>
    result_info = parse_result_type(func.return_type)
    option_info = parse_option_type(func.return_type)

    if result_info !== nothing
        # Generate wrapper for Result<T, E> returning function
        return _generate_result_function_wrapper(func, result_info, arg_syms, converted_args)
    elseif option_info !== nothing
        # Generate wrapper for Option<T> returning function
        return _generate_option_function_wrapper(func, option_info, arg_syms, converted_args)
    else
        # Standard function wrapper
        julia_ret_type = _rust_type_to_julia_type_symbol(func.return_type)
        if julia_ret_type === nothing
            julia_ret_type = :Any
        end

        quote
            function $func_name($(arg_syms...))
                func_ptr = _get_func_ptr($func_name_str)
                call_rust_function(func_ptr, $julia_ret_type, $(converted_args...))
            end
            export $func_name
        end
    end
end

"""
    _generate_result_function_wrapper(func, result_info, arg_syms, converted_args) -> Expr

Generate a Julia wrapper for a function that returns Result<T, E>.
The wrapper will return RustResult{T, E}.
"""
function _generate_result_function_wrapper(func::RustFunctionSignature, result_info::ResultTypeInfo, arg_syms::Vector{Symbol}, converted_args::Vector)
    func_name = Symbol(func.name)
    func_name_str = func.name

    # Get Julia types for ok and err
    ok_julia_type = _rust_type_to_julia_type_symbol(result_info.ok_type)
    err_julia_type = _rust_type_to_julia_type_symbol(result_info.err_type)

    if ok_julia_type === nothing
        ok_julia_type = :Any
    end
    if err_julia_type === nothing
        err_julia_type = :Any
    end

    # The C-compatible struct name generated by the proc-macro
    c_result_struct_name = Symbol("CResult_", func_name_str)

    quote
        # Define the C-compatible struct for this function's result
        struct $c_result_struct_name
            is_ok::UInt8
            ok_value::$ok_julia_type
            err_value::$err_julia_type
        end

        function $func_name($(arg_syms...))
            func_ptr = _get_func_ptr($func_name_str)
            c_result = call_rust_function(func_ptr, $c_result_struct_name, $(converted_args...))
            # Convert to RustResult
            if c_result.is_ok == 1
                RustCall.RustResult{$ok_julia_type, $err_julia_type}(true, c_result.ok_value)
            else
                RustCall.RustResult{$ok_julia_type, $err_julia_type}(false, c_result.err_value)
            end
        end
        export $func_name
    end
end

"""
    _generate_option_function_wrapper(func, option_info, arg_syms, converted_args) -> Expr

Generate a Julia wrapper for a function that returns Option<T>.
The wrapper will return RustOption{T}.
"""
function _generate_option_function_wrapper(func::RustFunctionSignature, option_info::OptionTypeInfo, arg_syms::Vector{Symbol}, converted_args::Vector)
    func_name = Symbol(func.name)
    func_name_str = func.name

    # Get Julia type for inner type
    inner_julia_type = _rust_type_to_julia_type_symbol(option_info.inner_type)

    if inner_julia_type === nothing
        inner_julia_type = :Any
    end

    # The C-compatible struct name generated by the proc-macro
    c_option_struct_name = Symbol("COption_", func_name_str)

    quote
        # Define the C-compatible struct for this function's option
        struct $c_option_struct_name
            is_some::UInt8
            value::$inner_julia_type
        end

        function $func_name($(arg_syms...))
            func_ptr = _get_func_ptr($func_name_str)
            c_option = call_rust_function(func_ptr, $c_option_struct_name, $(converted_args...))
            # Convert to RustOption
            if c_option.is_some == 1
                RustCall.RustOption{$inner_julia_type}(true, c_option.value)
            else
                RustCall.RustOption{$inner_julia_type}(false, nothing)
            end
        end
        export $func_name
    end
end

"""
    generate_crate_struct_wrappers(info::CrateInfo, lib_path::String) -> Expr

Generate Julia struct definitions and wrappers for all #[julia] structs in the crate.
"""
function generate_crate_struct_wrappers(info::CrateInfo, lib_path::String)
    exprs = Expr[]

    for s in info.julia_structs
        wrapper = _generate_crate_struct_wrapper(s)
        push!(exprs, wrapper)
    end

    if isempty(exprs)
        return :()
    end

    Expr(:block, exprs...)
end

function _generate_crate_struct_wrapper(info::RustStructInfo)
    struct_name = Symbol(info.name)
    struct_name_str = info.name

    # Start with struct definition
    exprs = Expr[]

    # Define the wrapper struct
    push!(exprs, quote
        mutable struct $struct_name
            ptr::Ptr{Cvoid}

            function $struct_name(ptr::Ptr{Cvoid})
                obj = new(ptr)
                finalizer(obj) do x
                    if getfield(x, :ptr) != C_NULL
                        free_fn = $(struct_name_str * "_free")
                        func_ptr = _get_func_ptr(free_fn)
                        ccall(func_ptr, Cvoid, (Ptr{Cvoid},), getfield(x, :ptr))
                        setfield!(x, :ptr, C_NULL)
                    end
                end
                return obj
            end
        end
        export $struct_name
    end)

    # Generate constructor and method wrappers
    for m in info.methods
        method_wrapper = _generate_crate_method_wrapper(info, m)
        push!(exprs, method_wrapper)
    end

    # Generate field accessors (get_field, set_field! functions)
    for (field_name, field_type) in info.fields
        if _is_ffi_compatible_field_type(field_type)
            accessor_wrapper = _generate_crate_field_accessor(info, field_name, field_type)
            push!(exprs, accessor_wrapper)
        end
    end

    # Generate getproperty/setproperty! for natural field access syntax
    property_accessors = _generate_property_accessors(info)
    if property_accessors !== nothing
        push!(exprs, property_accessors)
    end

    Expr(:block, exprs...)
end

"""
    _generate_property_accessors(info::RustStructInfo) -> Union{Expr, Nothing}

Generate Base.getproperty and Base.setproperty! methods for natural field access.
This allows `obj.field` and `obj.field = value` syntax.
"""
function _generate_property_accessors(info::RustStructInfo)
    struct_name = Symbol(info.name)
    struct_name_str = info.name

    # Filter to FFI-compatible fields
    compatible_fields = [(name, type) for (name, type) in info.fields if _is_ffi_compatible_field_type(type)]

    if isempty(compatible_fields)
        return nothing
    end

    # Build getproperty branches
    getprop_branches = Expr[]
    for (field_name, field_type) in compatible_fields
        field_sym = QuoteNode(Symbol(field_name))
        getter_fn = "$(struct_name_str)_get_$(field_name)"
        julia_type = _rust_type_to_julia_type_symbol(field_type)
        if julia_type === nothing
            julia_type = :Any
        end

        push!(getprop_branches, quote
            if field === $field_sym
                func_ptr = _get_func_ptr($getter_fn)
                return call_rust_function(func_ptr, $julia_type, getfield(self, :ptr))
            end
        end)
    end

    # Build setproperty! branches
    setprop_branches = Expr[]
    for (field_name, field_type) in compatible_fields
        field_sym = QuoteNode(Symbol(field_name))
        setter_fn = "$(struct_name_str)_set_$(field_name)"

        push!(setprop_branches, quote
            if field === $field_sym
                func_ptr = _get_func_ptr($setter_fn)
                call_rust_function(func_ptr, Cvoid, getfield(self, :ptr), value)
                return value
            end
        end)
    end

    # Generate the field names tuple for propertynames
    field_symbols = [QuoteNode(Symbol(name)) for (name, _) in compatible_fields]

    quote
        function Base.getproperty(self::$struct_name, field::Symbol)
            # Allow access to internal ptr field
            if field === :ptr
                return getfield(self, :ptr)
            end
            $(getprop_branches...)
            error("type $($struct_name_str) has no field $field")
        end

        function Base.setproperty!(self::$struct_name, field::Symbol, value)
            # Disallow setting internal ptr field
            if field === :ptr
                error("cannot set internal field :ptr")
            end
            $(setprop_branches...)
            error("type $($struct_name_str) has no field $field")
        end

        function Base.propertynames(self::$struct_name)
            ($(field_symbols...),)
        end
    end
end

function _generate_crate_method_wrapper(info::RustStructInfo, method::RustMethod)
    struct_name = Symbol(info.name)
    struct_name_str = info.name
    method_name = Symbol(method.name)
    wrapper_name = "$(struct_name_str)_$(method.name)"

    arg_syms = [Symbol(name) for name in method.arg_names]

    # Convert argument types to Julia types for ccall
    arg_julia_types = [_rust_type_to_julia_type_symbol(t) for t in method.arg_types]
    # Default to Any if type conversion fails
    arg_julia_types = [t === nothing ? :Any : t for t in arg_julia_types]

    # Determine if it's a constructor
    is_constructor = method.name == "new" || method.return_type == "Self" || method.return_type == struct_name_str

    if method.is_static
        if is_constructor
            # Static constructor - returns the wrapper struct
            quote
                function $struct_name($(arg_syms...))
                    func_ptr = _get_func_ptr($wrapper_name)
                    ptr = ccall(func_ptr, Ptr{Cvoid}, ($(arg_julia_types...),), $(arg_syms...))
                    $struct_name(ptr)
                end
            end
        else
            # Static method
            julia_ret_type = _rust_type_to_julia_type_symbol(method.return_type)
            if julia_ret_type === nothing
                julia_ret_type = :Any
            end
            quote
                function $method_name($(arg_syms...))
                    func_ptr = _get_func_ptr($wrapper_name)
                    call_rust_function(func_ptr, $julia_ret_type, $(arg_syms...))
                end
                export $method_name
            end
        end
    else
        # Instance method
        julia_ret_type = _rust_type_to_julia_type_symbol(method.return_type)
        if julia_ret_type === nothing
            julia_ret_type = :Cvoid
        end

        if is_constructor
            # Method that returns Self
            quote
                function $method_name(self::$struct_name, $(arg_syms...))
                    func_ptr = _get_func_ptr($wrapper_name)
                    ptr = ccall(func_ptr, Ptr{Cvoid}, (Ptr{Cvoid}, $(arg_julia_types...),), getfield(self, :ptr), $(arg_syms...))
                    $struct_name(ptr)
                end
                export $method_name
            end
        else
            quote
                function $method_name(self::$struct_name, $(arg_syms...))
                    func_ptr = _get_func_ptr($wrapper_name)
                    call_rust_function(func_ptr, $julia_ret_type, getfield(self, :ptr), $(arg_syms...))
                end
                export $method_name
            end
        end
    end
end

function _generate_crate_field_accessor(info::RustStructInfo, field_name::String, field_type::String)
    struct_name = Symbol(info.name)
    struct_name_str = info.name
    getter_name = "$(struct_name_str)_get_$(field_name)"
    setter_name = "$(struct_name_str)_set_$(field_name)"

    julia_type = _rust_type_to_julia_type_symbol(field_type)
    if julia_type === nothing
        julia_type = :Any
    end

    field_sym = Symbol(field_name)

    # Generate getproperty and setproperty! methods will be handled separately
    # For now, just generate get_field and set_field! functions
    quote
        function $(Symbol("get_$field_name"))(self::$struct_name)
            func_ptr = _get_func_ptr($getter_name)
            call_rust_function(func_ptr, $julia_type, self.ptr)
        end

        function $(Symbol("set_$(field_name)!"))(self::$struct_name, value)
            func_ptr = _get_func_ptr($setter_name)
            call_rust_function(func_ptr, Cvoid, self.ptr, value)
            value
        end
    end
end

# ============================================================================
# Main API
# ============================================================================

"""
    generate_bindings(crate_path::String; kwargs...) -> Expr

Generate Julia bindings for an external Rust crate.

This is the main entry point for the Maturin-like feature. It scans the crate,
creates a wrapper crate if needed, builds it, and generates Julia bindings.

# Arguments
- `crate_path::String`: Path to the Rust crate root directory

# Keyword Arguments
- `output_module_name::Union{String, Nothing}`: Name for the generated module
- `build_release::Bool`: Build in release mode (default: true)
- `cache_enabled::Bool`: Enable caching (default: true)

# Returns
- `Expr`: A module expression containing all bindings

# Example
```julia
bindings = generate_bindings("/path/to/my_crate")
eval(bindings)
# Now MyCrate module is available
MyCrate.add(1, 2)
```
"""
function generate_bindings(crate_path::String;
    output_module_name::Union{String, Nothing} = nothing,
    build_release::Bool = true,
    cache_enabled::Bool = true
)
    opts = CrateBindingOptions(
        output_module_name = output_module_name,
        build_release = build_release,
        cache_enabled = cache_enabled
    )

    # Scan the crate
    @info "Scanning crate at $crate_path"
    info = scan_crate(crate_path)
    @info "Found $(length(info.julia_functions)) functions and $(length(info.julia_structs)) structs"

    # Check cache
    cache_key = compute_crate_hash(info)
    cached_lib = cache_enabled ? get_cargo_cached_library(cache_key) : nothing

    lib_path = if cached_lib !== nothing && isfile(cached_lib)
        @info "Using cached library"
        cached_lib
    else
        # Check if the crate already has cdylib crate-type
        if crate_has_cdylib(crate_path)
            # Build the crate directly
            @info "Building crate directly (already has cdylib crate-type)..."
            lib_path = build_crate_directly(info, build_release)
        else
            # Create wrapper crate and build
            @info "Creating wrapper crate..."
            wrapper_path = create_wrapper_crate(info, opts)

            @info "Building wrapper crate..."
            wrapper_project = CargoProject(
                "$(info.name)_julia_wrapper",
                "0.1.0",
                DependencySpec[],  # Dependencies are in Cargo.toml
                "2021",
                wrapper_path
            )

            lib_path = build_cargo_project(wrapper_project, release=build_release)
        end

        # Cache the result
        if cache_enabled
            try
                save_cargo_cached_library(cache_key, lib_path)
            catch e
                @debug "Failed to cache library: $e"
            end
        end

        lib_path
    end

    # Generate module
    @info "Generating Julia module..."
    return emit_crate_module(info, lib_path, module_name=output_module_name)
end

"""
    crate_has_cdylib(crate_path::String) -> Bool

Check if the crate has cdylib in its crate-type.
"""
function crate_has_cdylib(crate_path::String)
    cargo_toml_path = joinpath(crate_path, "Cargo.toml")
    if !isfile(cargo_toml_path)
        return false
    end

    cargo_toml = parse_cargo_toml(cargo_toml_path)
    lib_section = get(cargo_toml, "lib", Dict())
    crate_types = get(lib_section, "crate-type", String[])

    return "cdylib" in crate_types
end

"""
    build_crate_directly(info::CrateInfo, release::Bool) -> String

Build the crate directly using cargo and return the path to the library.
"""
function build_crate_directly(info::CrateInfo, release::Bool)
    # Create a CargoProject that points to the original crate
    project = CargoProject(
        info.name,
        info.version,
        info.dependencies,
        "2021",
        info.path
    )

    build_cargo_project(project, release=release)
end

"""
    compute_crate_hash(info::CrateInfo) -> String

Compute a hash for caching based on crate contents.
"""
function compute_crate_hash(info::CrateInfo)
    # Hash the source files content
    content = IOBuffer()

    for src_file in sort(info.source_files)
        print(content, src_file)
        print(content, read(src_file, String))
    end

    # Include crate metadata
    print(content, info.name)
    print(content, info.version)

    bytes2hex(sha256(take!(content)))[1:32]
end

"""
    get_function_pointer_from_lib(lib_handle::Ptr{Cvoid}, func_name::String) -> Ptr{Cvoid}

Get a function pointer from a loaded library.
"""
function get_function_pointer_from_lib(lib_handle::Ptr{Cvoid}, func_name::String)
    Libdl.dlsym(lib_handle, func_name)
end

# ============================================================================
# @rust_crate Macro
# ============================================================================

"""
    @rust_crate(path)
    @rust_crate(path, options...)

Generate and load bindings for an external Rust crate.

# Arguments
- `path`: Path to the Rust crate (string literal)

# Options
- `name="ModuleName"`: Override the generated module name
- `release=true/false`: Build in release mode (default: true)
- `cache=true/false`: Enable caching (default: true)

# Example
```julia
# Basic usage
@rust_crate "/path/to/my_crate"

# With options
@rust_crate "/path/to/my_crate" name="MyBindings" release=true

# After loading, use the module
MyCrate.add(1, 2)
```
"""
macro rust_crate(path, options...)
    # Parse options
    module_name = nothing
    release = true
    cache = true

    for opt in options
        if isa(opt, Expr) && opt.head == :(=)
            key = opt.args[1]
            value = opt.args[2]

            if key == :name
                module_name = value
            elseif key == :release
                release = value
            elseif key == :cache
                cache = value
            end
        end
    end

    quote
        local bindings = generate_bindings(
            $(esc(path)),
            output_module_name = $module_name,
            build_release = $release,
            cache_enabled = $cache
        )
        Core.eval($__module__, bindings)
    end
end

# ============================================================================
# Precompilation Support
# ============================================================================

"""
    write_bindings_to_file(crate_path::String, output_path::String; kwargs...) -> String

Generate Julia bindings for a Rust crate and write them to a file.

This function is designed for package development workflow where bindings should
be generated once and then included in the package for precompilation.

# Arguments
- `crate_path::String`: Path to the Rust crate root directory
- `output_path::String`: Path to write the generated Julia code

# Keyword Arguments
- `output_module_name::Union{String, Nothing}`: Name for the generated module
- `build_release::Bool`: Build in release mode (default: true)
- `relative_lib_path::Union{String, Nothing}`: Path to library relative to the generated file
  If not provided, uses the absolute path to the compiled library.

# Returns
- `String`: Path to the generated Julia file

# Workflow for Package Development

1. During development, call `write_bindings_to_file` to generate bindings:
   ```julia
   using RustCall
   write_bindings_to_file(
       "deps/my_rust_crate",
       "src/generated/MyRustBindings.jl",
       relative_lib_path = "../deps/lib"
   )
   ```

2. Include the generated file in your package:
   ```julia
   # In src/MyPackage.jl
   include("generated/MyRustBindings.jl")
   ```

3. The generated module will be precompiled with your package.

# Example
```julia
using RustCall

# Generate bindings to a file
write_bindings_to_file(
    "/path/to/my_crate",
    "src/MyCrateBindings.jl",
    output_module_name = "MyCrate"
)

# The file can now be included in your package
```
"""
function write_bindings_to_file(crate_path::String, output_path::String;
    output_module_name::Union{String, Nothing} = nothing,
    build_release::Bool = true,
    relative_lib_path::Union{String, Nothing} = nothing
)
    # Scan and build the crate
    @info "Scanning crate at $crate_path"
    info = scan_crate(crate_path)
    @info "Found $(length(info.julia_functions)) functions and $(length(info.julia_structs)) structs"

    # Build the crate
    lib_path = if crate_has_cdylib(crate_path)
        @info "Building crate directly (already has cdylib crate-type)..."
        build_crate_directly(info, build_release)
    else
        # Create wrapper crate and build
        opts = CrateBindingOptions(
            output_module_name = output_module_name,
            build_release = build_release
        )
        @info "Creating wrapper crate..."
        wrapper_path = create_wrapper_crate(info, opts)

        @info "Building wrapper crate..."
        wrapper_project = CargoProject(
            "$(info.name)_julia_wrapper",
            "0.1.0",
            DependencySpec[],
            "2021",
            wrapper_path
        )

        build_cargo_project(wrapper_project, release=build_release)
    end

    # Determine the library path to use in the generated code
    if relative_lib_path !== nothing
        # Copy the library to the relative path
        output_dir = dirname(output_path)
        lib_dest_dir = normpath(joinpath(output_dir, relative_lib_path))
        mkpath(lib_dest_dir)

        lib_filename = basename(lib_path)
        lib_dest_path = joinpath(lib_dest_dir, lib_filename)

        cp(lib_path, lib_dest_path, force=true)
        @info "Copied library to $lib_dest_path"

        # Use @__DIR__ based path in generated code
        lib_path_for_code = joinpath(relative_lib_path, lib_filename)
    else
        lib_path_for_code = lib_path
    end

    # Generate the module code as a string
    code = emit_crate_module_code(info, lib_path_for_code,
        module_name = output_module_name,
        use_relative_path = relative_lib_path !== nothing
    )

    # Write to file
    mkpath(dirname(output_path))
    write(output_path, code)

    @info "Generated bindings written to $output_path"
    return output_path
end

"""
    emit_crate_module_code(info::CrateInfo, lib_path::String; kwargs...) -> String

Generate Julia module code as a string, suitable for writing to a file.

# Arguments
- `info::CrateInfo`: Crate information from scan_crate
- `lib_path::String`: Path to the compiled shared library (or relative path)

# Keyword Arguments
- `module_name::Union{String, Nothing}`: Name for the module
- `use_relative_path::Bool`: If true, treat lib_path as relative to @__DIR__

# Returns
- `String`: Julia source code for the module
"""
function emit_crate_module_code(info::CrateInfo, lib_path::String;
    module_name::Union{String, Nothing} = nothing,
    use_relative_path::Bool = false
)
    # Determine module name
    mod_name = if module_name !== nothing
        module_name
    else
        snake_to_pascal(info.name)
    end

    lines = String[]

    # Header comment
    push!(lines, "# Auto-generated bindings for $(info.name)")
    push!(lines, "# Generated by RustCall.jl - DO NOT EDIT")
    push!(lines, "# Regenerate with: write_bindings_to_file(\"$(info.path)\", \"<output_path>\")")
    push!(lines, "")

    # Module start
    push!(lines, "module $mod_name")
    push!(lines, "")

    # Imports
    push!(lines, "import RustCall: call_rust_function, get_function_pointer_from_lib, RustResult, RustOption")
    push!(lines, "import Libdl")
    push!(lines, "")

    # Library path constant
    if use_relative_path
        push!(lines, "const _LIB_PATH = joinpath(@__DIR__, $(repr(lib_path)))")
    else
        push!(lines, "const _LIB_PATH = $(repr(lib_path))")
    end
    push!(lines, "const _LIB_HANDLE = Ref{Ptr{Cvoid}}(C_NULL)")
    push!(lines, "")

    # __init__ function for loading library
    push!(lines, "function __init__()")
    push!(lines, "    _LIB_HANDLE[] = Libdl.dlopen(_LIB_PATH, Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW)")
    push!(lines, "end")
    push!(lines, "")

    # Helper function
    push!(lines, "function _get_func_ptr(name::String)")
    push!(lines, "    if _LIB_HANDLE[] == C_NULL")
    push!(lines, "        error(\"Library not loaded. Call __init__() first.\")")
    push!(lines, "    end")
    push!(lines, "    Libdl.dlsym(_LIB_HANDLE[], name)")
    push!(lines, "end")
    push!(lines, "")

    # Generate function wrappers
    for func in info.julia_functions
        if func.is_generic
            continue
        end
        code = _emit_function_code(func)
        push!(lines, code)
        push!(lines, "")
    end

    # Generate struct wrappers
    for s in info.julia_structs
        code = _emit_struct_code(s)
        push!(lines, code)
        push!(lines, "")
    end

    # Module end
    push!(lines, "end # module $mod_name")

    return join(lines, "\n")
end

"""
    _emit_function_code(func::RustFunctionSignature) -> String

Generate Julia code for a function wrapper as a string.
"""
function _emit_function_code(func::RustFunctionSignature)
    func_name = func.name
    arg_names = func.arg_names
    arg_types = func.arg_types

    # Build argument conversions
    arg_syms = join(arg_names, ", ")
    converted_args = String[]
    for (name, rust_type) in zip(arg_names, arg_types)
        julia_type = _rust_type_to_julia_conversion_type(rust_type)
        if julia_type !== nothing
            push!(converted_args, "$julia_type($name)")
        else
            push!(converted_args, name)
        end
    end
    converted_args_str = join(converted_args, ", ")

    # Check for Result/Option return types
    result_info = parse_result_type(func.return_type)
    option_info = parse_option_type(func.return_type)

    if result_info !== nothing
        return _emit_result_function_code(func, result_info, arg_syms, converted_args_str)
    elseif option_info !== nothing
        return _emit_option_function_code(func, option_info, arg_syms, converted_args_str)
    else
        # Standard function
        julia_ret_type = _rust_type_to_julia_type_symbol(func.return_type)
        ret_type_str = julia_ret_type !== nothing ? string(julia_ret_type) : "Any"

        return """
function $func_name($arg_syms)
    func_ptr = _get_func_ptr("$func_name")
    call_rust_function(func_ptr, $ret_type_str, $converted_args_str)
end
export $func_name"""
    end
end

function _emit_result_function_code(func::RustFunctionSignature, result_info::ResultTypeInfo, arg_syms::String, converted_args_str::String)
    func_name = func.name
    ok_julia_type = _rust_type_to_julia_type_symbol(result_info.ok_type)
    err_julia_type = _rust_type_to_julia_type_symbol(result_info.err_type)
    ok_type_str = ok_julia_type !== nothing ? string(ok_julia_type) : "Any"
    err_type_str = err_julia_type !== nothing ? string(err_julia_type) : "Any"
    c_result_struct_name = "CResult_$func_name"

    return """
struct $c_result_struct_name
    is_ok::UInt8
    ok_value::$ok_type_str
    err_value::$err_type_str
end

function $func_name($arg_syms)
    func_ptr = _get_func_ptr("$func_name")
    c_result = call_rust_function(func_ptr, $c_result_struct_name, $converted_args_str)
    if c_result.is_ok == 1
        RustResult{$ok_type_str, $err_type_str}(true, c_result.ok_value)
    else
        RustResult{$ok_type_str, $err_type_str}(false, c_result.err_value)
    end
end
export $func_name"""
end

function _emit_option_function_code(func::RustFunctionSignature, option_info::OptionTypeInfo, arg_syms::String, converted_args_str::String)
    func_name = func.name
    inner_julia_type = _rust_type_to_julia_type_symbol(option_info.inner_type)
    inner_type_str = inner_julia_type !== nothing ? string(inner_julia_type) : "Any"
    c_option_struct_name = "COption_$func_name"

    return """
struct $c_option_struct_name
    is_some::UInt8
    value::$inner_type_str
end

function $func_name($arg_syms)
    func_ptr = _get_func_ptr("$func_name")
    c_option = call_rust_function(func_ptr, $c_option_struct_name, $converted_args_str)
    if c_option.is_some == 1
        RustOption{$inner_type_str}(true, c_option.value)
    else
        RustOption{$inner_type_str}(false, nothing)
    end
end
export $func_name"""
end

"""
    _emit_struct_code(info::RustStructInfo) -> String

Generate Julia code for a struct wrapper as a string.
"""
function _emit_struct_code(info::RustStructInfo)
    struct_name = info.name

    lines = String[]

    # Struct definition
    push!(lines, "mutable struct $struct_name")
    push!(lines, "    ptr::Ptr{Cvoid}")
    push!(lines, "")
    push!(lines, "    function $struct_name(ptr::Ptr{Cvoid})")
    push!(lines, "        obj = new(ptr)")
    push!(lines, "        finalizer(obj) do x")
    push!(lines, "            if getfield(x, :ptr) != C_NULL")
    push!(lines, "                free_fn = \"$(struct_name)_free\"")
    push!(lines, "                func_ptr = _get_func_ptr(free_fn)")
    push!(lines, "                ccall(func_ptr, Cvoid, (Ptr{Cvoid},), getfield(x, :ptr))")
    push!(lines, "                setfield!(x, :ptr, C_NULL)")
    push!(lines, "            end")
    push!(lines, "        end")
    push!(lines, "        return obj")
    push!(lines, "    end")
    push!(lines, "end")
    push!(lines, "export $struct_name")
    push!(lines, "")

    # Method wrappers
    for m in info.methods
        code = _emit_method_code(info, m)
        push!(lines, code)
        push!(lines, "")
    end

    # Property access
    compatible_fields = [(name, type) for (name, type) in info.fields if _is_ffi_compatible_field_type(type)]

    if !isempty(compatible_fields)
        # getproperty
        push!(lines, "function Base.getproperty(self::$struct_name, field::Symbol)")
        push!(lines, "    if field === :ptr")
        push!(lines, "        return getfield(self, :ptr)")
        push!(lines, "    end")
        for (field_name, field_type) in compatible_fields
            julia_type = _rust_type_to_julia_type_symbol(field_type)
            julia_type_str = julia_type !== nothing ? string(julia_type) : "Any"
            getter_fn = "$(struct_name)_get_$(field_name)"
            push!(lines, "    if field === :$field_name")
            push!(lines, "        func_ptr = _get_func_ptr(\"$getter_fn\")")
            push!(lines, "        return call_rust_function(func_ptr, $julia_type_str, getfield(self, :ptr))")
            push!(lines, "    end")
        end
        push!(lines, "    error(\"type $struct_name has no field \$field\")")
        push!(lines, "end")
        push!(lines, "")

        # setproperty!
        push!(lines, "function Base.setproperty!(self::$struct_name, field::Symbol, value)")
        push!(lines, "    if field === :ptr")
        push!(lines, "        error(\"cannot set internal field :ptr\")")
        push!(lines, "    end")
        for (field_name, field_type) in compatible_fields
            setter_fn = "$(struct_name)_set_$(field_name)"
            push!(lines, "    if field === :$field_name")
            push!(lines, "        func_ptr = _get_func_ptr(\"$setter_fn\")")
            push!(lines, "        call_rust_function(func_ptr, Cvoid, getfield(self, :ptr), value)")
            push!(lines, "        return value")
            push!(lines, "    end")
        end
        push!(lines, "    error(\"type $struct_name has no field \$field\")")
        push!(lines, "end")
        push!(lines, "")

        # propertynames
        field_syms = join([":$name" for (name, _) in compatible_fields], ", ")
        push!(lines, "function Base.propertynames(self::$struct_name)")
        push!(lines, "    ($field_syms,)")
        push!(lines, "end")
    end

    return join(lines, "\n")
end

"""
    _emit_method_code(struct_info::RustStructInfo, method::RustMethod) -> String

Generate Julia code for a method wrapper as a string.
"""
function _emit_method_code(struct_info::RustStructInfo, method::RustMethod)
    struct_name = struct_info.name
    method_name = method.name
    wrapper_name = "$(struct_name)_$(method_name)"

    arg_names = method.arg_names
    arg_types = method.arg_types

    # Convert argument types to Julia types
    arg_julia_types = [_rust_type_to_julia_type_symbol(t) for t in arg_types]
    arg_julia_types = [t === nothing ? :Any : t for t in arg_julia_types]
    arg_types_str = join([string(t) for t in arg_julia_types], ", ")

    arg_syms = join(arg_names, ", ")

    is_constructor = method_name == "new" || method.return_type == "Self" || method.return_type == struct_name

    if method.is_static
        if is_constructor
            # Static constructor
            return """
function $struct_name($arg_syms)
    func_ptr = _get_func_ptr("$wrapper_name")
    ptr = ccall(func_ptr, Ptr{Cvoid}, ($arg_types_str,), $arg_syms)
    $struct_name(ptr)
end"""
        else
            # Static method
            julia_ret_type = _rust_type_to_julia_type_symbol(method.return_type)
            ret_type_str = julia_ret_type !== nothing ? string(julia_ret_type) : "Any"
            return """
function $method_name($arg_syms)
    func_ptr = _get_func_ptr("$wrapper_name")
    call_rust_function(func_ptr, $ret_type_str, $arg_syms)
end
export $method_name"""
        end
    else
        # Instance method
        julia_ret_type = _rust_type_to_julia_type_symbol(method.return_type)
        ret_type_str = julia_ret_type !== nothing ? string(julia_ret_type) : "Cvoid"

        if is_constructor
            # Method returning Self
            self_args = isempty(arg_syms) ? "" : ", $arg_syms"
            arg_types_with_ptr = isempty(arg_types_str) ? "Ptr{Cvoid}" : "Ptr{Cvoid}, $arg_types_str"
            return """
function $method_name(self::$struct_name$self_args)
    func_ptr = _get_func_ptr("$wrapper_name")
    ptr = ccall(func_ptr, Ptr{Cvoid}, ($arg_types_with_ptr,), getfield(self, :ptr)$self_args)
    $struct_name(ptr)
end
export $method_name"""
        else
            self_args = isempty(arg_syms) ? "" : ", $arg_syms"
            return """
function $method_name(self::$struct_name$self_args)
    func_ptr = _get_func_ptr("$wrapper_name")
    call_rust_function(func_ptr, $ret_type_str, getfield(self, :ptr)$self_args)
end
export $method_name"""
        end
    end
end

"""
    @rust_crate_static(lib_path, module_name)

Load a pre-generated Rust crate binding with a specific library path.

This macro is for loading bindings that were generated with `write_bindings_to_file`
where the library was placed at a known location.

# Arguments
- `lib_path`: Path to the compiled shared library
- `module_name`: Name of the module to create

# Example
```julia
# In a precompiled package
const _RUST_LIB = joinpath(@__DIR__, "..", "deps", "libmycrate.so")
@rust_crate_static _RUST_LIB MyCrate
```
"""
macro rust_crate_static(lib_path, module_name)
    quote
        # This is a simplified loader for precompiled bindings
        # The full module should be included from a generated file
        error("@rust_crate_static is deprecated. Use write_bindings_to_file and include the generated file instead.")
    end
end
