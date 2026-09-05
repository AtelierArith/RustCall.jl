# External crate bindings generator (Maturin-like feature)
# This module provides automatic Julia bindings generation for external Rust crates
# that use the #[julia] attribute from juliacall_macros.
#
# Dependencies (must be included before this file in RustCall.jl):
#   - structs.jl / julia_functions.jl: RustStructInfo, RustFunctionSignature, emitters
#   - manifest.jl: extract_manifest, manifest_function_signatures, manifest_struct_infos

using TOML
using SHA

# Validate that required dependencies are available at include time.
# If manifest.jl failed to load or was included after this file, catch it early
# rather than at runtime when @rust_crate is used.
if !isdefined(@__MODULE__, :extract_manifest)
    error("crate_bindings.jl requires extract_manifest from manifest.jl — check include order in RustCall.jl")
end

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
    source_files = sort(find_rust_sources(crate_path))

    # The extractor reports every #[julia] item exactly as the proc-macro will
    # expand it (crate mode); Julia never reads the Rust source itself.
    # `.rs` files that are not complete modules (include!() fragments) are
    # skipped; Cargo is the authority on whether the crate compiles.
    # Cargo builds the crate with its own features and profile; prune only what
    # the target decides (`unix`, `windows`, `target_*`).
    manifest = extract_manifest(source_files; mode = "crate", skip_unparsable = true,
                                cfg = :lenient)
    all_functions = manifest_function_signatures(manifest)
    all_structs = manifest_struct_infos(manifest)

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
    # Add the target crate as a path dependency (escape for TOML safety)
    push!(lines, "$(info.name) = { path = \"$(escape_toml_string(info.path))\" }")
    # Add juliacall_macros (use path for now, will be crates.io later)
    juliacall_macros_path = joinpath(dirname(dirname(@__FILE__)), "deps", "juliacall_macros")
    if isdir(juliacall_macros_path)
        push!(lines, "juliacall_macros = { path = \"$(escape_toml_string(juliacall_macros_path))\" }")
    else
        push!(lines, "juliacall_macros = \"0.1\"")
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
        import RustCall: call_rust_function, get_function_pointer_from_lib, RustResult, RustOption, _check_not_freed,
                         _call_rust_owned_string_ptr, _call_rust_borrowed_string_ptr
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
    # The Julia wrapper keeps the Rust name; the exported symbol it calls is
    # `rustcall_<name>` since #279 (the helper types stay name-derived).
    symbol_str = func.symbol

    # Build argument list
    arg_syms = [Symbol(name) for name in func.arg_names]

    # Build converted arguments (string arguments become (ptr, len) pairs kept
    # alive with GC.@preserve, see `_string_arg_plan`)
    bindings, preserved, converted_args = _string_arg_plan(func, identity)

    # Result<T, E> / Option<T> returns are reported by the manifest
    if func.return_kind == :result
        return _generate_result_function_wrapper(func, arg_syms, bindings, preserved, converted_args)
    elseif func.return_kind == :option
        return _generate_option_function_wrapper(func, arg_syms, bindings, preserved, converted_args)
    elseif _uses_string_ffi(func)
        return _generate_string_function_wrapper(func, arg_syms)
    else
        # Standard function wrapper. The one return decision (#276).
        julia_ret_type = ffi_return_symbol_or_throw(func.return_type, func.return_abi,
                                                    _ffi_context(func))

        ptr_sym = _generated_local("func_ptr", func.arg_names)
        quote
            function $func_name($(arg_syms...))
                $ptr_sym = _get_func_ptr($symbol_str)
                call_rust_function($ptr_sym, $julia_ret_type, $(converted_args...))
            end
            export $func_name
        end
    end
end

"""
    _generate_string_function_wrapper(func, arg_syms) -> Expr

Wrapper for a `#[julia]` function with `String` / `&str` arguments or return
(#242): arguments are passed as `(ptr, len)` pairs under `GC.@preserve`, a
`String` return is copied out of `<fn>_RustCallOwnedString` and released with
`<fn>_free_rust_string`, a `&str` return is copied out of the borrowed view.
"""
function _generate_string_function_wrapper(func::RustFunctionSignature, arg_syms::Vector{Symbol})
    func_name = Symbol(func.name)
    func_name_str = func.name
    # The Julia wrapper keeps the Rust name; the exported symbol it calls is
    # `rustcall_<name>` since #279 (the helper types stay name-derived).
    symbol_str = func.symbol
    bindings, preserved, call_args = _string_arg_plan(func, identity)
    call = if func.has_owned_string_helper
        free_name = ffi_free_symbol(func_name_str)
        :(_call_rust_owned_string_ptr(_get_func_ptr($symbol_str), _get_func_ptr($free_name), $(call_args...)))
    elseif func.has_borrowed_string_helper
        :(_call_rust_borrowed_string_ptr(_get_func_ptr($symbol_str), $(call_args...)))
    else
        ret = ffi_return_symbol_or_throw(func.return_type, func.return_abi,
                                         _ffi_context(func))
        :(call_rust_function(_get_func_ptr($symbol_str), $ret, $(call_args...)))
    end
    quote
        function $func_name($(arg_syms...))
            $(bindings...)
            GC.@preserve $(preserved...) begin
                $call
            end
        end
        export $func_name
    end
end

"""
    _generate_result_function_wrapper(func, result_info, arg_syms, converted_args) -> Expr

Generate a Julia wrapper for a function that returns Result<T, E>.
The wrapper will return RustResult{T, E}.
"""
function _generate_result_function_wrapper(func::RustFunctionSignature, arg_syms::Vector{Symbol},
                                           bindings::Vector, preserved::Vector, converted_args::Vector)
    func_name = Symbol(func.name)
    func_name_str = func.name
    # The Julia wrapper keeps the Rust name; the exported symbol it calls is
    # `rustcall_<name>` since #279 (the helper types stay name-derived).
    symbol_str = func.symbol

    # Get Julia types for ok and err
    ctx = _ffi_context(func)
    ok_julia_type = ffi_return_symbol_or_throw(func.ok_type, "", ctx)
    err_julia_type = ffi_return_symbol_or_throw(func.err_type, "", ctx)

    # The C-compatible struct name generated by the proc-macro
    c_result_struct_name = Symbol("CResult_", func_name_str)
    ptr_sym = _generated_local("func_ptr", func.arg_names)
    c_sym = _generated_local("c_result", func.arg_names)

    quote
        # Define the C-compatible struct for this function's result
        struct $c_result_struct_name
            is_ok::UInt8
            ok_value::$ok_julia_type
            err_value::$err_julia_type
        end

        function $func_name($(arg_syms...))
            # String arguments are converted first: an argument may be called
            # `func_ptr`, so the pointer local is resolved only afterwards.
            $(bindings...)
            $ptr_sym = _get_func_ptr($symbol_str)
            $c_sym = GC.@preserve $(preserved...) call_rust_function($ptr_sym, $c_result_struct_name, $(converted_args...))
            # Convert to RustResult
            if $c_sym.is_ok == 1
                RustResult{$ok_julia_type, $err_julia_type}(true, $c_sym.ok_value)
            else
                RustResult{$ok_julia_type, $err_julia_type}(false, $c_sym.err_value)
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
function _generate_option_function_wrapper(func::RustFunctionSignature, arg_syms::Vector{Symbol},
                                           bindings::Vector, preserved::Vector, converted_args::Vector)
    func_name = Symbol(func.name)
    func_name_str = func.name
    # The Julia wrapper keeps the Rust name; the exported symbol it calls is
    # `rustcall_<name>` since #279 (the helper types stay name-derived).
    symbol_str = func.symbol

    # Get Julia type for inner type
    inner_julia_type = ffi_return_symbol_or_throw(func.inner_type, "", _ffi_context(func))

    # The C-compatible struct name generated by the proc-macro
    c_option_struct_name = Symbol("COption_", func_name_str)
    ptr_sym = _generated_local("func_ptr", func.arg_names)
    c_sym = _generated_local("c_option", func.arg_names)

    quote
        # Define the C-compatible struct for this function's option
        struct $c_option_struct_name
            is_some::UInt8
            value::$inner_julia_type
        end

        function $func_name($(arg_syms...))
            # String arguments are converted first: an argument may be called
            # `func_ptr`, so the pointer local is resolved only afterwards.
            $(bindings...)
            $ptr_sym = _get_func_ptr($symbol_str)
            $c_sym = GC.@preserve $(preserved...) call_rust_function($ptr_sym, $c_option_struct_name, $(converted_args...))
            # Convert to RustOption
            if $c_sym.is_some == 1
                RustOption{$inner_julia_type}(true, $c_sym.value)
            else
                RustOption{$inner_julia_type}(false, nothing)
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
                    try
                        if getfield(x, :ptr) != C_NULL
                            free_fn = $(struct_name_str * "_free")
                            func_ptr = _get_func_ptr(free_fn)
                            ccall(func_ptr, Cvoid, (Ptr{Cvoid},), getfield(x, :ptr))
                            setfield!(x, :ptr, C_NULL)
                        end
                    catch e
                        @warn "Failed to free $($(struct_name_str))" exception=e maxlog=10
                    end
                end
                return obj
            end
        end
        export $struct_name

        function Base.show(io::IO, self::$struct_name)
            print(io, nameof(@__MODULE__), ".", $struct_name_str, "(")
            show(io, getfield(self, :ptr))
            print(io, ")")
        end

        function Base.show(io::IO, ::MIME"text/plain", self::$struct_name)
            Base.show(io, self)
        end
    end)

    # Generate constructor and method wrappers
    for m in info.methods
        method_wrapper = _generate_crate_method_wrapper(info, m)
        push!(exprs, method_wrapper)
    end

    # Generate field accessors (get_field, set_field! functions)
    for (field_name, field_type) in info.fields
        if field_is_accessible(info, field_name)
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
    compatible_fields = [(name, type) for (name, type) in info.fields if field_is_accessible(info, name)]

    if isempty(compatible_fields)
        return nothing
    end

    # Build getproperty branches
    getprop_branches = Expr[]
    for (field_name, field_type) in compatible_fields
        field_sym = QuoteNode(Symbol(field_name))
        getter_fn = info.field_getters[field_name]
        julia_type = ffi_return_symbol_or_throw(field_type, get(info.field_abis, field_name, ""),
                                                _ffi_field_context(info, field_name, field_type))

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
        setter_fn = get(info.field_setters, field_name, "$(struct_name_str)_set_$(field_name)")

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
            _check_not_freed(self, $struct_name_str)
            $(getprop_branches...)
            error("type $($struct_name_str) has no field $field")
        end

        function Base.setproperty!(self::$struct_name, field::Symbol, value)
            # Disallow setting internal ptr field
            if field === :ptr
                error("cannot set internal field :ptr")
            end
            _check_not_freed(self, $struct_name_str)
            $(setprop_branches...)
            error("type $($struct_name_str) has no field $field")
        end

        function Base.propertynames(self::$struct_name)
            ($(field_symbols...),)
        end
    end
end

"""
    _check_not_freed(obj, type_name::String)

Check that a wrapped Rust object has not been freed. Throws an error if the
internal pointer is C_NULL, preventing use-after-free crashes.
"""
function _check_not_freed(obj, type_name::String)
    if getfield(obj, :ptr) == C_NULL
        error("Attempted to use a freed $type_name object")
    end
end

function _generate_crate_method_wrapper(info::RustStructInfo, method::RustMethod)
    struct_name = Symbol(info.name)
    struct_name_str = info.name
    method_name = Symbol(method.name)
    # Exported symbol of the method wrapper (`rustcall_<Struct>_<method>`, #279);
    # the per-method string buffers stay named after the method itself.
    wrapper_name = method_wrapper_symbol(struct_name_str, method)
    helper_owner = "$(struct_name_str)_$(method.name)"

    arg_syms = [Symbol(name) for name in method.arg_names]

    # String arguments become (ptr, len) pairs kept alive with GC.@preserve
    # (see `_string_arg_plan`); the other arguments are converted to the Julia
    # type of the Rust parameter. The pointer local must not shadow an
    # argument of the same name.
    bindings, preserved, converted_args = _string_arg_plan(method, identity)
    ptr_sym = _generated_local("func_ptr", method.arg_names)

    # Crate method wrappers return strings through per-method buffers:
    # `<Struct>_<method>_RustCallOwnedString`, released with
    # `<Struct>_<method>_free_rust_string` (see rustcall_core::codegen).
    free_name = ffi_free_symbol(helper_owner)

    all_args = Any[]
    method.is_static || push!(all_args, :(getfield(self, :ptr)))
    append!(all_args, converted_args)

    call = if method.is_constructor
        # Constructors and `Self`-returning methods get a boxed struct pointer
        :($struct_name(call_rust_function($ptr_sym, Ptr{Cvoid}, $(all_args...))))
    elseif method.return_abi == "string"
        :(_call_rust_owned_string_ptr($ptr_sym, _get_func_ptr($free_name), $(all_args...)))
    elseif method.return_abi == "str"
        :(_call_rust_borrowed_string_ptr($ptr_sym, $(all_args...)))
    else
        julia_ret_type = ffi_return_symbol_or_throw(method.return_type, method.return_abi,
                                                    _ffi_context(method, struct_name_str))
        :(call_rust_function($ptr_sym, $julia_ret_type, $(all_args...)))
    end
    # The wrapper object itself is kept alive for the whole call as well: a
    # borrowed `&str` result points into the Rust object, which the finalizer
    # of a temporary `self` could otherwise free mid-call.
    method.is_static || pushfirst!(preserved, :self)
    body = quote
        $(bindings...)
        $ptr_sym = _get_func_ptr($wrapper_name)
        GC.@preserve $(preserved...) $call
    end

    if method.is_static && method.is_constructor
        # Static constructor - returns the wrapper struct
        quote
            function $struct_name($(arg_syms...))
                $body
            end
        end
    elseif method.is_static
        quote
            function $method_name($(arg_syms...))
                $body
            end
            export $method_name
        end
    else
        quote
            function $method_name(self::$struct_name, $(arg_syms...))
                _check_not_freed(self, $struct_name_str)
                $body
            end
            export $method_name
        end
    end
end

function _generate_crate_field_accessor(info::RustStructInfo, field_name::String, field_type::String)
    struct_name = Symbol(info.name)
    struct_name_str = info.name
    getter_name = info.field_getters[field_name]
    setter_name = get(info.field_setters, field_name, "$(struct_name_str)_set_$(field_name)")

    julia_type = ffi_return_symbol_or_throw(field_type, get(info.field_abis, field_name, ""),
                                            _ffi_field_context(info, field_name, field_type))

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
# The generated bindings are now available
MyCrate.add(Int32(1), Int32(2))
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

            try
                lib_path = build_cargo_project(wrapper_project, release=build_release)
            finally
                cleanup_cargo_project(wrapper_project)
            end
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

"""
    CrateBindings

Runtime wrapper returned by `@rust_crate` and [`load_crate_bindings`](@ref).

Property access preserves non-function exports such as types and constants,
while exported functions are routed through a proxy so calls remain
world-age-safe after dynamic loading.
"""
struct CrateBindings
    module_ref::Module
end

struct CrateBindingMember
    bindings::CrateBindings
    name::Symbol
end

struct CrateBindingObject
    bindings::CrateBindings
    value::Any
end

_unwrap_crate_binding_value(value) = value
_unwrap_crate_binding_value(value::CrateBindingObject) = getfield(value, :value)

_should_proxy_crate_binding(value) = value isa Function

function _wrap_crate_binding_value(bindings::CrateBindings, value)
    if value isa CrateBindings || value isa CrateBindingMember || value isa CrateBindingObject
        return value
    end

    if value isa Module
        return CrateBindings(value)
    end

    if value !== nothing && parentmodule(typeof(value)) === getfield(bindings, :module_ref)
        return CrateBindingObject(bindings, value)
    end

    return value
end

function Base.getproperty(bindings::CrateBindings, name::Symbol)
    if name === :module_ref
        return getfield(bindings, :module_ref)
    end

    module_ref = getfield(bindings, :module_ref)
    if !isdefined(module_ref, name)
        error("module $(nameof(module_ref)) has no binding $name")
    end

    value = Base.invokelatest(getproperty, module_ref, name)
    if _should_proxy_crate_binding(value)
        return CrateBindingMember(bindings, name)
    end

    return _wrap_crate_binding_value(bindings, value)
end

Base.propertynames(bindings::CrateBindings, private::Bool=false) = names(getfield(bindings, :module_ref); all=private)

function (member::CrateBindingMember)(args...)
    bindings = getfield(member, :bindings)
    module_ref = getfield(bindings, :module_ref)
    binding_name = getfield(member, :name)
    callable = Base.invokelatest(getproperty, module_ref, binding_name)
    result = Base.invokelatest(callable, map(_unwrap_crate_binding_value, args)...)
    return _wrap_crate_binding_value(bindings, result)
end

function Base.getproperty(proxy::CrateBindingObject, name::Symbol)
    if name === :bindings || name === :value
        return getfield(proxy, name)
    end

    value = getfield(proxy, :value)
    result = Base.invokelatest(getproperty, value, name)
    return _wrap_crate_binding_value(getfield(proxy, :bindings), result)
end

function Base.setproperty!(proxy::CrateBindingObject, name::Symbol, value)
    if name === :bindings || name === :value
        error("cannot set internal proxy field $name")
    end

    target = getfield(proxy, :value)
    raw_value = _unwrap_crate_binding_value(value)
    result = Base.invokelatest(setproperty!, target, name, raw_value)
    return _wrap_crate_binding_value(getfield(proxy, :bindings), result)
end

function Base.propertynames(proxy::CrateBindingObject, private::Bool=false)
    Base.invokelatest(propertynames, getfield(proxy, :value), private)
end

Base.show(io::IO, bindings::CrateBindings) = print(io, "CrateBindings(", nameof(getfield(bindings, :module_ref)), ")")
Base.show(io::IO, member::CrateBindingMember) = print(io, nameof(getfield(getfield(member, :bindings), :module_ref)), ".", getfield(member, :name))

function _show_crate_binding_object(io::IO, proxy::CrateBindingObject)
    value = getfield(proxy, :value)
    module_name = nameof(getfield(getfield(proxy, :bindings), :module_ref))
    type_name = nameof(typeof(value))

    print(io, module_name, ".", type_name, "(")
    for (idx, field_name) in enumerate(fieldnames(typeof(value)))
        idx > 1 && print(io, ", ")
        show(io, getfield(value, field_name))
    end
    print(io, ")")
end

Base.show(io::IO, proxy::CrateBindingObject) = _show_crate_binding_object(io, proxy)
Base.show(io::IO, ::MIME"text/plain", proxy::CrateBindingObject) = _show_crate_binding_object(io, proxy)

function _instantiate_runtime_bindings(bindings_expr::Expr)
    runtime_namespace = Module(gensym(:RustCallCrateRuntime))
    return Base.invokelatest(Core.eval, runtime_namespace, bindings_expr)
end

"""
    load_crate_bindings(crate_path::String; output_module_name=nothing, build_release=true, cache_enabled=true) -> CrateBindings

Generate, load, and return explicit bindings for a Rust crate.

Use the returned [`CrateBindings`](@ref) value directly:

```julia
const MyCrate = load_crate_bindings("/path/to/my_crate")
MyCrate.add(Int32(1), Int32(2))
p = MyCrate.Point(3.0, 4.0)
p isa MyCrate.Point
```

`output_module_name` controls the generated runtime module name stored inside the
returned bindings object; it does not inject a caller-visible module.
"""
function load_crate_bindings(crate_path::String;
    output_module_name::Union{String, Nothing} = nothing,
    build_release::Bool = true,
    cache_enabled::Bool = true
)
    bindings_expr = generate_bindings(
        crate_path;
        output_module_name = output_module_name,
        build_release = build_release,
        cache_enabled = cache_enabled,
    )

    crate_module = _instantiate_runtime_bindings(bindings_expr)
    return CrateBindings(crate_module)
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
- `name="ModuleName"`: Override the generated runtime module name used inside the returned bindings object
- `release=true/false`: Build in release mode (default: true)
- `cache=true/false`: Enable caching (default: true)

# Example
```julia
# Basic usage
const MyCrate = @rust_crate "/path/to/my_crate"

# With options
const MyBindings = @rust_crate "/path/to/my_crate" name="MyBindings" release=true

# After loading, use the returned bindings value directly
MyCrate.add(Int32(1), Int32(2))
p = MyCrate.Point(3.0, 4.0)
MyCrate.distance(p)
```
"""
macro rust_crate(path, options...)
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
        load_crate_bindings(
            $(esc(path));
            output_module_name = $module_name,
            build_release = $release,
            cache_enabled = $cache,
        )
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
- `strict::Symbol`: what to do when the FFI contract cannot describe a return
  type — `:error` (raise, naming the signature), `:warn` (warn once and emit
  `Any`) or `:none` (emit `Any` silently). Defaults to `RustCall.FFI_STRICT[]`.
  A crate that used to emit `Any` for an unsupported type keeps building with
  `:warn`; see `docs/src/crate_bindings.md`.
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
    relative_lib_path::Union{String, Nothing} = nothing,
    strict::Symbol = FFI_STRICT[]
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

        try
            build_cargo_project(wrapper_project, release=build_release)
        finally
            cleanup_cargo_project(wrapper_project)
        end
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

    # Generate the module code as a string. `strict` is bound around the whole
    # emission so every return decision in it — free functions, methods and
    # field getters alike — answers the same way (#276).
    previous_strict = FFI_STRICT[]
    FFI_STRICT[] = strict
    code = try
        emit_crate_module_code(info, lib_path_for_code,
            module_name = output_module_name,
            use_relative_path = relative_lib_path !== nothing
        )
    finally
        FFI_STRICT[] = previous_strict
    end

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
    push!(lines, "import RustCall: call_rust_function, get_function_pointer_from_lib, RustResult, RustOption, _check_not_freed,")
    push!(lines, "                 _call_rust_owned_string_ptr, _call_rust_borrowed_string_ptr")
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
    _emit_string_arg_plan(func_or_method) -> (bindings_str, preserve_str, converted_args_str)

Source-text counterpart of `_string_arg_plan` for the file emitter (free
functions and struct methods alike).
"""
function _emit_string_arg_plan(func::Union{RustFunctionSignature, RustMethod})
    bindings, preserved, call_args = _string_arg_plan(func, identity)
    bindings_str = join(("    " * string(b) for b in bindings), "\n")
    preserve_str = join(string.(preserved), " ")
    converted_args_str = join(string.(call_args), ", ")
    return bindings_str, preserve_str, converted_args_str
end

"""
    _emit_function_code(func::RustFunctionSignature) -> String

Generate Julia code for a function wrapper as a string.
"""
function _emit_function_code(func::RustFunctionSignature)
    func_name = func.name
    # The generated Julia function keeps the Rust name; the symbol it looks up
    # is the additive wrapper `rustcall_<name>` (#279).
    sym = func.symbol
    arg_names = func.arg_names

    # Build argument conversions (string arguments become (ptr, len) pairs)
    arg_syms = join(arg_names, ", ")
    bindings_str, preserve_str, converted_args_str = _emit_string_arg_plan(func)
    prologue = isempty(bindings_str) ? "" : bindings_str * "\n"

    # Result/Option return types are reported by the manifest
    if func.return_kind == :result
        return _emit_result_function_code(func, arg_syms, converted_args_str; prologue, preserve_str)
    elseif func.return_kind == :option
        return _emit_option_function_code(func, arg_syms, converted_args_str; prologue, preserve_str)
    elseif func.has_owned_string_helper
        return """
function $func_name($arg_syms)
$(prologue)    GC.@preserve $preserve_str _call_rust_owned_string_ptr(_get_func_ptr("$sym"), _get_func_ptr("$(ffi_free_symbol(func_name))"), $converted_args_str)
end
export $func_name"""
    elseif func.has_borrowed_string_helper
        return """
function $func_name($arg_syms)
$(prologue)    GC.@preserve $preserve_str _call_rust_borrowed_string_ptr(_get_func_ptr("$sym"), $converted_args_str)
end
export $func_name"""
    else
        # Standard function
        ret_type_str = string(ffi_return_symbol_or_throw(func.return_type, func.return_abi,
                                                         _ffi_context(func)))

        ptr_var = _generated_local("func_ptr", func.arg_names)
        return """
function $func_name($arg_syms)
$(prologue)    $ptr_var = _get_func_ptr("$sym")
    GC.@preserve $preserve_str call_rust_function($ptr_var, $ret_type_str, $converted_args_str)
end
export $func_name"""
    end
end

function _emit_result_function_code(func::RustFunctionSignature, arg_syms::String, converted_args_str::String;
                                    prologue::String = "", preserve_str::String = "")
    func_name = func.name
    ctx = _ffi_context(func)
    ok_type_str = string(ffi_return_symbol_or_throw(func.ok_type, "", ctx))
    err_type_str = string(ffi_return_symbol_or_throw(func.err_type, "", ctx))
    sym = func.symbol
    c_result_struct_name = "CResult_$func_name"
    ptr_var = _generated_local("func_ptr", func.arg_names)
    c_var = _generated_local("c_result", func.arg_names)

    return """
struct $c_result_struct_name
    is_ok::UInt8
    ok_value::$ok_type_str
    err_value::$err_type_str
end

function $func_name($arg_syms)
$(prologue)    $ptr_var = _get_func_ptr("$sym")
    $c_var = GC.@preserve $preserve_str call_rust_function($ptr_var, $c_result_struct_name, $converted_args_str)
    if $c_var.is_ok == 1
        RustResult{$ok_type_str, $err_type_str}(true, $c_var.ok_value)
    else
        RustResult{$ok_type_str, $err_type_str}(false, $c_var.err_value)
    end
end
export $func_name"""
end

function _emit_option_function_code(func::RustFunctionSignature, arg_syms::String, converted_args_str::String;
                                    prologue::String = "", preserve_str::String = "")
    func_name = func.name
    inner_type_str = string(ffi_return_symbol_or_throw(func.inner_type, "",
                                                       _ffi_context(func)))
    sym = func.symbol
    c_option_struct_name = "COption_$func_name"
    ptr_var = _generated_local("func_ptr", func.arg_names)
    c_var = _generated_local("c_option", func.arg_names)

    return """
struct $c_option_struct_name
    is_some::UInt8
    value::$inner_type_str
end

function $func_name($arg_syms)
$(prologue)    $ptr_var = _get_func_ptr("$sym")
    $c_var = GC.@preserve $preserve_str call_rust_function($ptr_var, $c_option_struct_name, $converted_args_str)
    if $c_var.is_some == 1
        RustOption{$inner_type_str}(true, $c_var.value)
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
    push!(lines, "            try")
    push!(lines, "                if getfield(x, :ptr) != C_NULL")
    push!(lines, "                    free_fn = \"$(struct_name)_free\"")
    push!(lines, "                    func_ptr = _get_func_ptr(free_fn)")
    push!(lines, "                    ccall(func_ptr, Cvoid, (Ptr{Cvoid},), getfield(x, :ptr))")
    push!(lines, "                    setfield!(x, :ptr, C_NULL)")
    push!(lines, "                end")
    push!(lines, "            catch e")
    push!(lines, "                @warn \"Failed to free $(struct_name)\" exception=e maxlog=10")
    push!(lines, "            end")
    push!(lines, "        end")
    push!(lines, "        return obj")
    push!(lines, "    end")
    push!(lines, "end")
    push!(lines, "export $struct_name")
    push!(lines, "function Base.show(io::IO, self::$struct_name)")
    push!(lines, "    print(io, nameof(@__MODULE__), \".$struct_name(\")")
    push!(lines, "    show(io, getfield(self, :ptr))")
    push!(lines, "    print(io, \")\")")
    push!(lines, "end")
    push!(lines, "function Base.show(io::IO, ::MIME\"text/plain\", self::$struct_name)")
    push!(lines, "    Base.show(io, self)")
    push!(lines, "end")
    push!(lines, "")

    # Method wrappers
    for m in info.methods
        code = _emit_method_code(info, m)
        push!(lines, code)
        push!(lines, "")
    end

    # Property access
    compatible_fields = [(name, type) for (name, type) in info.fields if field_is_accessible(info, name)]

    if !isempty(compatible_fields)
        # getproperty
        push!(lines, "function Base.getproperty(self::$struct_name, field::Symbol)")
        push!(lines, "    if field === :ptr")
        push!(lines, "        return getfield(self, :ptr)")
        push!(lines, "    end")
        push!(lines, "    _check_not_freed(self, \"$struct_name\")")
        for (field_name, field_type) in compatible_fields
            julia_type_str = string(ffi_return_symbol_or_throw(
                field_type, get(info.field_abis, field_name, ""),
                _ffi_field_context(info, field_name, field_type)))
            getter_fn = info.field_getters[field_name]
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
        push!(lines, "    _check_not_freed(self, \"$struct_name\")")
        for (field_name, field_type) in compatible_fields
            setter_fn = get(info.field_setters, field_name, "$(struct_name)_set_$(field_name)")
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
    # Exported symbol (`rustcall_<Struct>_<method>`, #279); the per-method
    # string buffers stay named after the method itself.
    wrapper_name = method_wrapper_symbol(struct_name, method)
    helper_owner = "$(struct_name)_$(method_name)"

    arg_syms = join(method.arg_names, ", ")

    # Same shape as `_generate_crate_method_wrapper`: string arguments are
    # (ptr, len) pairs under GC.@preserve, string results come back through
    # the per-method `<Struct>_<method>_RustCallOwnedString` buffer.
    bindings_str, preserve_str, converted_args_str = _emit_string_arg_plan(method)
    prologue = isempty(bindings_str) ? "" : bindings_str * "\n"
    # `self` is preserved too: a borrowed `&str` result points into the Rust
    # object, which the finalizer of a temporary could free mid-call.
    method.is_static || (preserve_str = strip("self " * preserve_str))
    ptr_var = _generated_local("func_ptr", method.arg_names)
    free_name = ffi_free_symbol(helper_owner)

    all_args = String[]
    method.is_static || push!(all_args, "getfield(self, :ptr)")
    isempty(converted_args_str) || push!(all_args, converted_args_str)
    args_str = join(all_args, ", ")

    call = if method.is_constructor
        "$struct_name(call_rust_function($ptr_var, Ptr{Cvoid}, $args_str))"
    elseif method.return_abi == "string"
        "_call_rust_owned_string_ptr($ptr_var, _get_func_ptr(\"$free_name\"), $args_str)"
    elseif method.return_abi == "str"
        "_call_rust_borrowed_string_ptr($ptr_var, $args_str)"
    else
        ret_type_str = string(ffi_return_symbol_or_throw(method.return_type, method.return_abi,
                                                         _ffi_context(method, struct_name)))
        "call_rust_function($ptr_var, $ret_type_str, $args_str)"
    end
    body = """
$(prologue)    $ptr_var = _get_func_ptr("$wrapper_name")
    GC.@preserve $preserve_str $call"""

    if method.is_static && method.is_constructor
        # Static constructor
        return """
function $struct_name($arg_syms)
$body
end"""
    elseif method.is_static
        return """
function $method_name($arg_syms)
$body
end
export $method_name"""
    else
        self_args = isempty(arg_syms) ? "" : ", $arg_syms"
        return """
function $method_name(self::$struct_name$self_args)
    _check_not_freed(self, "$struct_name")
$body
end
export $method_name"""
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
