# External crate bindings generator (Maturin-like feature)
# This module provides automatic Julia bindings generation for external Rust crates
# that use the #[julia] attribute from lastcall_macros.

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

Parse Rust source code and extract structs marked with #[julia].
"""
function parse_julia_structs_from_source(code::String)
    structs = RustStructInfo[]

    # Pattern to match #[julia] pub struct or #[julia] struct
    pattern = r"#\[julia\]\s*(?:pub\s+)?struct\s+([A-Z]\w*)\s*(?:<([^>]+)>)?\s*\{"

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

Parse impl blocks for a struct and extract methods marked with #[julia].
"""
function parse_impl_methods_for_struct(code::String, struct_name::String)
    methods = RustMethod[]

    # Pattern to find impl blocks for the struct
    impl_pattern = Regex("impl(?:\\s*<[^>]+>)?\\s+$struct_name(?:\\s*<[^>]+>)?\\s*\\{")

    for impl_match in eachmatch(impl_pattern, code)
        # Extract the impl block
        impl_block = extract_block_at(code, impl_match.offset)
        if impl_block === nothing
            continue
        end

        # Find #[julia] annotated methods within the impl block
        method_pattern = r"#\[julia\]\s*pub\s+fn\s+(\w+)\s*\(([^)]*)\)(?:\s*->\s*([^\{]+))?\s*\{"

        for method_match in eachmatch(method_pattern, impl_block)
            method_name = String(method_match.captures[1])
            args_str = method_match.captures[2] !== nothing ? String(method_match.captures[2]) : ""
            return_type = method_match.captures[3] !== nothing ? strip(String(method_match.captures[3])) : "()"

            # Determine if it's static/mutable based on self parameter
            is_static = !occursin("self", args_str)
            is_mutable = occursin("&mut self", args_str)

            # Parse arguments (excluding self)
            arg_names = String[]
            arg_types = String[]
            _parse_method_args!(arg_names, arg_types, args_str)

            push!(methods, RustMethod(method_name, is_static, is_mutable, arg_names, arg_types, return_type))
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
    wrapper_path = mktempdir(prefix="lastcall_wrapper_")

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
    # Add lastcall_macros (use path for now, will be crates.io later)
    lastcall_macros_path = joinpath(dirname(dirname(@__FILE__)), "deps", "lastcall_macros")
    if isdir(lastcall_macros_path)
        push!(lines, "lastcall_macros = { path = \"$lastcall_macros_path\" }")
    else
        push!(lines, "lastcall_macros = \"0.1\"")
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
    push!(lines, "// Generated by LastCall.jl")
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
        Symbol(titlecase(replace(info.name, "_" => "")))
    end

    # Generate function wrappers
    func_defs = generate_crate_function_wrappers(info, lib_path)

    # Generate struct definitions and wrappers
    struct_defs = generate_crate_struct_wrappers(info, lib_path)

    quote
        module $mod_name
            import LastCall: call_rust_function, get_function_pointer_from_lib
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
    end
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

    # Get return type
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
                    if x.ptr != C_NULL
                        free_fn = $(struct_name_str * "_free")
                        func_ptr = _get_func_ptr(free_fn)
                        ccall(func_ptr, Cvoid, (Ptr{Cvoid},), x.ptr)
                        x.ptr = C_NULL
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

    # Generate field accessors
    for (field_name, field_type) in info.fields
        if _is_ffi_compatible_field_type(field_type)
            accessor_wrapper = _generate_crate_field_accessor(info, field_name, field_type)
            push!(exprs, accessor_wrapper)
        end
    end

    Expr(:block, exprs...)
end

function _generate_crate_method_wrapper(info::RustStructInfo, method::RustMethod)
    struct_name = Symbol(info.name)
    struct_name_str = info.name
    method_name = Symbol(method.name)
    wrapper_name = "$(struct_name_str)_$(method.name)"

    arg_syms = [Symbol(name) for name in method.arg_names]

    # Determine if it's a constructor
    is_constructor = method.name == "new" || method.return_type == "Self" || method.return_type == struct_name_str

    if method.is_static
        if is_constructor
            # Static constructor - returns the wrapper struct
            quote
                function $struct_name($(arg_syms...))
                    func_ptr = _get_func_ptr($wrapper_name)
                    ptr = ccall(func_ptr, Ptr{Cvoid}, ($(map(_ -> :Cint, arg_syms)...),), $(arg_syms...))
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
                    ptr = ccall(func_ptr, Ptr{Cvoid}, (Ptr{Cvoid}, $(map(_ -> :Cint, arg_syms)...),), self.ptr, $(arg_syms...))
                    $struct_name(ptr)
                end
                export $method_name
            end
        else
            quote
                function $method_name(self::$struct_name, $(arg_syms...))
                    func_ptr = _get_func_ptr($wrapper_name)
                    call_rust_function(func_ptr, $julia_ret_type, self.ptr, $(arg_syms...))
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
        eval(bindings)
    end
end
