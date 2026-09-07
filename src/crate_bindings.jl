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
- `pyo3_functions::Vector{RustFunctionSignature}`: `#[pyfunction]` /
  `#[pymodule]` items found by the PyO3 scan of #275 — items the crate does
  *not* mark with a RustCall attribute. Nothing wraps them yet; each carries a
  `skip_reason` (empty when a Phase-2 wrapper crate could wrap it).
- `pyo3_structs::Vector{RustStructInfo}`: `#[pyclass]` items, likewise.
"""
struct CrateInfo
    name::String
    path::String
    version::String
    dependencies::Vector{DependencySpec}
    julia_functions::Vector{RustFunctionSignature}
    julia_structs::Vector{RustStructInfo}
    source_files::Vector{String}
    pyo3_functions::Vector{RustFunctionSignature}
    pyo3_structs::Vector{RustStructInfo}
end

# The PyO3 columns are schema-5 additions (#275); a caller that built a
# `CrateInfo` before them keeps working and simply reports no PyO3 items.
CrateInfo(name, path, version, dependencies, julia_functions, julia_structs, source_files) =
    CrateInfo(name, path, version, dependencies, julia_functions, julia_structs, source_files,
              RustFunctionSignature[], RustStructInfo[])

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
    # The feature set the crate is built with, on every path: the generated
    # `_julia_wrapper` crate names it in its `[dependencies]` entry, a direct
    # build passes it to `cargo build` (#307 review).
    features::Vector{String}
    default_features::Bool
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
    cache_enabled::Bool = true,
    features::Vector{String} = String[],
    default_features::Bool = true
)
    CrateBindingOptions(output_module_name, output_path, use_wrapper_crate, build_release,
                        cache_enabled, features, default_features)
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
function scan_crate(crate_path::String; cfg = :lenient,
                    cfg_text::Union{Nothing, AbstractString} = nothing)
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
    # By default Cargo builds the crate with features and a profile RustCall
    # does not know, so only what the target decides (`unix`, `windows`,
    # `target_*`) is pruned. A caller that *does* know — it just built the
    # crate and probed it with `_crate_build_cfg_text` — passes that text and
    # `cfg = :cargo`, and then every `#[cfg]` is decided, which is what lets
    # mutually exclusive feature variants of one `#[julia] fn` collapse to the
    # one that exists (#277 Phase B).
    # The PyO3 scan (#275) needs the crate's module tree, not a bag of files:
    # `src/api.rs` is `api`, and a `mod api;` that is not `pub` puts everything
    # below it out of a wrapper crate's reach. The `#[julia]` extraction stays
    # per file.
    lib_root, tree_files = _crate_scan_inputs(crate_path, cargo_toml, source_files)
    manifest = extract_manifest(tree_files; mode = "crate", skip_unparsable = true,
                                cfg = cfg, cfg_text = cfg_text,
                                crate_root = lib_root)
    all_functions = manifest_function_signatures(manifest)
    all_structs = manifest_struct_infos(manifest)
    # Items the crate marks only for PyO3 (#275 Phase 1). They are reported so
    # `@rust_crate` can say what it found and why an item is not wrappable;
    # generating the wrapper crate that exports them is Phase 2.
    pyo3_functions = manifest_function_signatures(manifest; origins = PYO3_ATTRIBUTE_ORIGINS)
    pyo3_structs = manifest_struct_infos(manifest; origins = PYO3_ATTRIBUTE_ORIGINS)

    # Extract dependencies from Cargo.toml
    dependencies = extract_crate_dependencies(cargo_toml)

    CrateInfo(
        cargo_toml["package"]["name"],
        abspath(crate_path),
        get(cargo_toml["package"], "version", "0.1.0"),
        dependencies,
        all_functions,
        all_structs,
        source_files,
        pyo3_functions,
        pyo3_structs,
    )
end

"""
    _crate_scan_inputs(crate_path, cargo_toml, source_files) -> (lib_root, tree_files)

The files the extractor is given for a crate, and the root its module tree
hangs off.

A `[lib] path` outside `src/` is not in `source_files`, so the root has to be
added even when the per-file `#[julia]` pass never sees it. Factored out because
`scan_crate` and the #275 Phase-2 wrapper generator must be handed **the same**
list: the wrapper is generated from a re-run of the very scan `scan_crate`
reported, and a different file list would let the two disagree about which items
exist.
"""
function _crate_scan_inputs(crate_path::AbstractString, cargo_toml::AbstractDict,
                            source_files::Vector{String})
    lib_root = crate_lib_root(crate_path, cargo_toml)
    tree_files = lib_root === nothing || lib_root in source_files ?
        source_files : vcat(source_files, [lib_root])
    return lib_root, tree_files
end

"""
    parse_cargo_toml(path::String) -> Dict

Parse a Cargo.toml file and return its contents as a dictionary.
"""
function parse_cargo_toml(path::String)
    TOML.parsefile(path)
end

"""
    crate_lib_root(crate_path, cargo_toml) -> Union{String, Nothing}

The crate's library root source file: `[lib] path` when the manifest sets one,
otherwise Cargo's default `src/lib.rs`. `nothing` when neither exists (a
binary-only crate).

This is the file the PyO3 scan of #275 follows the module tree from, so a crate
that puts its root somewhere else — `[lib] path = "src/core/lib.rs"`, or a path
outside `src/` altogether — is resolved from the right place instead of having
every source file treated as its own root.
"""
function crate_lib_root(crate_path::AbstractString, cargo_toml::AbstractDict)
    lib = get(cargo_toml, "lib", nothing)
    if lib isa AbstractDict
        configured = get(lib, "path", nothing)
        if configured isa AbstractString
            path = normpath(joinpath(String(crate_path), String(configured)))
            return isfile(path) ? path : nothing
        end
    end
    default = joinpath(String(crate_path), "src", "lib.rs")
    return isfile(default) ? default : nothing
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
    # The feature set belongs in the *dependency* entry: `cargo build
    # --no-default-features` applies to the package being built, i.e. this
    # wrapper, and never reaches a dependency's defaults (#307 review).
    dep = "$(info.name) = { path = \"$(escape_toml_string(info.path))\""
    opts.default_features || (dep *= ", default-features = false")
    isempty(opts.features) ||
        (dep *= ", features = [" *
                join(("\"$(escape_toml_string(f))\"" for f in opts.features), ", ") * "]")
    push!(lines, dep * " }")
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
    # Pinned, for the same reason as the inline Cargo manifest: the generated
    # `catch_unwind` boundary can only catch a panic that unwinds (#244).
    panic_line = cargo_profile_panic_line(crate_wrapper_policy())
    panic_line === nothing || push!(lines, panic_line)

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
function emit_crate_module(info::CrateInfo, lib_path::String;
                           module_name::Union{String, Nothing}=nothing,
                           build_release::Bool = true,
                           lib_name::Union{String, Nothing} = nothing,
                           preload::Vector{String} = String[])
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

    # The registry name of this crate's library. `@rust_crate` used to keep its
    # handle only in a module-local `Ref`, invisible to `unload_library`,
    # `unload_all_libraries` and every registry the rest of RustCall keeps
    # (#250). It goes through `load_artifact!` now, so the module's `Ref` and
    # the registry hold the same handle and the same liveness flag.
    lib_key = lib_name === nothing ? crate_library_name(info; release = build_release) : lib_name

    # Build the module body as a block
    module_body = quote
        import RustCall
        import RustCall: call_rust_function, get_function_pointer_from_lib, RustResult, RustOption, _check_not_freed,
                         _call_rust_owned_string_ptr, _call_rust_borrowed_string_ptr, convert_return,
                         _result_payload, FFIByValue
        import Libdl

        const _LIB_PATH = $lib_path
        const _LIB_NAME = $lib_key
        # Libraries the image imports by name that the loader would not find on
        # its own — a PyO3 wrapper's `python3xy.dll` on Windows, where there is
        # no rpath — opened before it (`PyO3LinkPlan.runtime_libraries`).
        const _PRELOAD_LIBRARIES = $preload

        # Everything this module knows about the image it calls — handle,
        # liveness flag and generation number — as **one immutable value**, in
        # one `Ref`.
        #
        # It used to be two `Ref`s, written by the loader under `REGISTRY_LOCK`
        # and read here under this module's own lock. Two unrelated locks over
        # two cells is not a snapshot: a constructor could read the old handle,
        # the reload could commit, and the constructor would then pair that
        # handle with the *replacement's* liveness flag — so an object
        # allocated by the retired image believed itself live after that image
        # was closed, and its finalizer jumped through an unmapped destructor.
        # One record, published by `_update_handle_mirrors!` in the same
        # transaction that swaps the registry entry, makes every read of
        # `_LIB_GEN[]` a consistent generation with no lock at all (#277).
        const _LIB_GEN = Ref(RustCall.CrateGeneration())

        function __init__()
            # Register *before* loading, and do not assign afterwards: the
            # `load_artifact!` transaction is what publishes the generation. An
            # assignment after it would overwrite a newer generation that a
            # concurrent reload had already published, and calls through this
            # module would go back to entering the retired image (#277).
            RustCall.register_handle_mirror!(_LIB_NAME, _LIB_GEN)
            RustCall.load_artifact!(RustCall.crate_direct_policy(), _LIB_PATH;
                                    lib_name = _LIB_NAME, preload = _PRELOAD_LIBRARIES)
        end

        # Resolved symbols, memoized per **handle**: a reload swaps the image
        # under the same module, and a pointer resolved against the old one
        # would be a call into code that is no longer there. Negative answers
        # are cached too — a crate built by an older RustCall exports no panic
        # channels and must not be probed on every call.
        const _SYMBOLS = Dict{Tuple{Ptr{Cvoid}, String}, Ptr{Cvoid}}()
        # `get!` on a `Dict` is not safe against a concurrent `get!`. This lock
        # guards the *cache*, never the generation read: resolution happens
        # before the Rust call, so a lock here costs nothing that matters — it
        # is the channel read *after* the call that must not take one (#244).
        const _SYMBOL_LOCK = ReentrantLock()

        function _symbol(handle::Ptr{Cvoid}, name::String)
            lock(_SYMBOL_LOCK) do
                get!(_SYMBOLS, (handle, name)) do
                    ptr = Libdl.dlsym(handle, name; throw_error = false)
                    ptr === nothing ? C_NULL : ptr
                end
            end
        end

        function _required_symbol(handle::Ptr{Cvoid}, name::String)
            ptr = _symbol(handle, name)
            ptr == C_NULL && error("The Rust library '" * _LIB_NAME *
                                   "' does not export '" * name * "'.")
            ptr
        end

        function _live_handle(gen::RustCall.CrateGeneration)
            gen.handle == C_NULL &&
                error("The Rust library backing this module is not loaded. " *
                      "It was either never initialised, or unloaded with " *
                      "RustCall.unload_library(\"" * _LIB_NAME * "\").")
            gen.handle
        end

        _get_func_ptr(name::String) = _required_symbol(_live_handle(_LIB_GEN[]), name)

        # One snapshot per call: the wrapper and its panic channel, resolved
        # against **one** deref of `_LIB_GEN`. Reading the generation twice
        # could straddle a reload, and the call would then enter the retired
        # image while the channel came from the replacement (#277).
        function _call_target(symbol::String)
            handle = _live_handle(_LIB_GEN[])
            (_required_symbol(handle, symbol),
             _symbol(handle, RustCall.ffi_panic_symbol(symbol)))
        end

        # The owned-`String` arm, with the function that releases the buffer the
        # wrapper returns. Resolving that release function after the call let a
        # reload land in between, and the buffer was then freed through the
        # replacement's allocator (#277).
        function _call_target(symbol::String, free_symbol::String)
            handle = _live_handle(_LIB_GEN[])
            (_required_symbol(handle, symbol),
             _symbol(handle, RustCall.ffi_panic_symbol(symbol)),
             _required_symbol(handle, free_symbol))
        end

        # The constructor arm: the wrapper that *allocates*, its channel, and
        # the destructor and liveness flag the resulting object will carry —
        # all from one deref. Taking the object's half after the call returned
        # would bind a pointer allocated by the retired image to the
        # replacement's destructor (#277).
        function _ctor_target(symbol::String, free_symbol::String)
            gen = _LIB_GEN[]
            handle = _live_handle(gen)
            (_required_symbol(handle, symbol),
             _symbol(handle, RustCall.ffi_panic_symbol(symbol)),
             _symbol(handle, free_symbol),
             gen.alive)
        end

        # The per-object half: a struct's destructor and the liveness flag of
        # the image that exports it — one deref, so they are always the same
        # generation. A missing destructor is `C_NULL`, which makes the
        # finalizer a no-op: a leak, not a crash (#249).
        function _struct_generation(free_symbol::String)
            gen = _LIB_GEN[]
            gen.handle == C_NULL && return (C_NULL, gen.alive)
            (_symbol(gen.handle, free_symbol), gen.alive)
        end

        # The channel is resolved by the *caller*, before the wrapper call:
        # it is a thread-local in the image, so nothing may yield between the
        # call and the read, and `_panic_channel` can allocate (#244).
        _guard_panic(value, channel::Ptr{Cvoid}, name::String) =
            RustCall.guard_rust_panic_ptr(value, channel, name)

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
    elseif func.return_kind == :py_result
        return _generate_py_result_function_wrapper(func, arg_syms, bindings, preserved,
                                                    converted_args)
    elseif func.return_kind == :option
        return _generate_option_function_wrapper(func, arg_syms, bindings, preserved, converted_args)
    elseif _uses_string_ffi(func)
        return _generate_string_function_wrapper(func, arg_syms)
    else
        # Standard function wrapper. The one return decision (#276).
        julia_ret_type = ffi_return_symbol_or_throw(func.return_type, func.return_abi,
                                                    _ffi_context(func))

        ptr_sym = _generated_local("func_ptr", func.arg_names)
        channel_sym = _generated_local("panic_channel", func.arg_names)
        quote
            function $func_name($(arg_syms...))
                $ptr_sym, $channel_sym = _call_target($symbol_str)
                _guard_panic(
                    call_rust_function($ptr_sym, $julia_ret_type, $(converted_args...)),
                    $channel_sym, $func_name_str)
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
    # The helper types stay named after the Rust item, so the owner is the
    # function name and the contract derives `free_symbol` from it (#276).
    c = ffi_return_contract(func.return_type; abi = func.return_abi, owner = func_name_str)
    # Declared before the call expression is built, since it names them.
    channel_sym = _generated_local("panic_channel", func.arg_names)
    ptr_sym = _generated_local("func_ptr", func.arg_names)
    free_sym = _generated_local("free_ptr", func.arg_names)
    # The owned-string branch snapshots the release function with the call; see
    # `_call_target`'s two-argument arm.
    target = :(($ptr_sym, $channel_sym) = _call_target($symbol_str))
    call = if ffi_owned_string_return(c)
        target = :(($ptr_sym, $channel_sym, $free_sym) = _call_target($symbol_str, $(c.free_symbol)))
        :(_call_rust_owned_string_ptr($ptr_sym, $free_sym, $(call_args...)))
    elseif ffi_borrowed_string_return(c)
        :(_call_rust_borrowed_string_ptr($ptr_sym, $(call_args...)))
    else
        ret = ffi_return_symbol_or_throw(func.return_type, func.return_abi,
                                         _ffi_context(func))
        :(call_rust_function($ptr_sym, $ret, $(call_args...)))
    end
    # The string paths return a buffer the wrapper filled; on a panic it is the
    # empty sentinel, which would decode to `""`, so the channel is read before
    # the value is used — and resolved, with the pointer, before the call
    # (#244, #277).
    call = :(_guard_panic($call, $channel_sym, $func_name_str))
    quote
        function $func_name($(arg_syms...))
            $target
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

    # The payloads are FIELDS of a `#[repr(C)]` aggregate: declared with the C
    # slot Rust stored, converted to the surface type after the call. They
    # differ for `char`, whose slot is a `UInt32` code point (#245).
    ctx = _ffi_context(func)
    ok_julia_type, ok_slot_type = ffi_payload_symbols(func.ok_type, func.ok_abi, ctx)
    err_julia_type, err_slot_type = ffi_payload_symbols(func.err_type, func.err_abi, ctx)
    # An owned-string payload is released through the function's own
    # `<fn>_free_rust_string`, snapshotted with the call pointer (#268, #277).
    free_str = _payload_free_symbol(func_name_str, (func.ok_abi, func.err_abi))

    # The C-compatible struct name generated by the proc-macro
    c_result_struct_name = Symbol("CResult_", func_name_str)
    ptr_sym = _generated_local("func_ptr", func.arg_names)
    c_sym = _generated_local("c_result", func.arg_names)
    channel_sym = _generated_local("panic_channel", func.arg_names)
    free_sym = _generated_local("free_ptr", func.arg_names)
    target = isempty(free_str) ?
        :(($ptr_sym, $channel_sym) = _call_target($symbol_str)) :
        :(($ptr_sym, $channel_sym, $free_sym) = _call_target($symbol_str, $free_str))
    free_expr = isempty(free_str) ? :(C_NULL) : free_sym

    quote
        # Define the C-compatible struct for this function's result
        # RustCall's own mirror of the extractor's `#[repr(C)]` aggregate, so
        # it carries the by-value layout assertion in its supertype (#245) —
        # a static property that survives this module being precompiled into a
        # downstream package, which a registry mutation would not.
        struct $c_result_struct_name <: FFIByValue
            is_ok::UInt8
            ok_value::$ok_slot_type
            err_value::$err_slot_type
        end

        function $func_name($(arg_syms...))
            # String arguments are converted first: an argument may be called
            # `func_ptr`, so the pointer local is resolved only afterwards.
            $(bindings...)
            $target
            $c_sym = GC.@preserve $(preserved...) call_rust_function($ptr_sym, $c_result_struct_name, $(converted_args...))
            # A panic returns `CResult::panicked()` — the Err discriminant with
            # an uninitialized payload — so the channel is read before the
            # payload is decoded, and resolved before the call (#244).
            _guard_panic(nothing, $channel_sym, $func_name_str)
            # Convert to RustResult; an owned-string payload is copied out and
            # released here, and only on the branch that owns it (#268).
            if $c_sym.is_ok == 1
                RustResult{$ok_julia_type, $err_julia_type}(true, _result_payload($ok_julia_type, $c_sym.ok_value, $free_expr))
            else
                RustResult{$ok_julia_type, $err_julia_type}(false, _result_payload($err_julia_type, $c_sym.err_value, $free_expr))
            end
        end
        export $func_name
    end
end

"""
    _py_result_types(ok_type, context; strict) -> (surface, slot, is_unit)

How a lowered `PyResult<T>` is read on the Julia side (#275 Phase 2).

The wrapper returns `CResult_<owner> { is_ok: u8, ok_value: <slot>,
err_value: i32 }`. `slot` is the C field type, `surface` is what the caller
sees, and `is_unit` says the `Ok` payload is a placeholder: a `PyResult<()>`
still has to report success or failure, so the wrapper writes a `u8` there and
Julia hands back `nothing`.

The error side is not a type at all — it is always `PYO3_OPAQUE_ERROR`, because
the generated wrapper drops the `PyErr` without ever rendering it.
"""
function _py_result_types(ok_type::AbstractString, context::AbstractString;
                          strict::Symbol = FFI_STRICT[])
    if isempty(strip(String(ok_type))) || strip(String(ok_type)) == "()"
        return (:Nothing, :UInt8, true)
    end
    surface = ffi_return_symbol_or_throw(String(ok_type), "", context; strict = strict)
    slot = ffi_return_slot_symbol_or_throw(String(ok_type), "", context; strict = strict)
    return (surface, slot, false)
end

"""
    _generate_py_result_function_wrapper(func, arg_syms, bindings, preserved, converted_args) -> Expr

Julia wrapper for a scanned `#[pyfunction]` returning `PyResult<T>` (#275
Phase 2). The result is a `RustResult{T, String}` whose error value is the fixed
`PYO3_OPAQUE_ERROR`: the wrapper reports only that *some* Python-side error
occurred, because rendering a `PyErr` without an interpreter panics inside pyo3
and the panic crossing `extern "C"` would abort the process.
"""
function _generate_py_result_function_wrapper(func::RustFunctionSignature, arg_syms::Vector{Symbol},
                                              bindings::Vector, preserved::Vector,
                                              converted_args::Vector)
    func_name = Symbol(func.name)
    func_name_str = func.name
    symbol_str = func.symbol
    ok_julia_type, ok_slot_type, is_unit = _py_result_types(func.ok_type, _ffi_context(func))

    c_result_struct_name = Symbol("CResult_", func_name_str)
    ptr_sym = _generated_local("func_ptr", func.arg_names)
    c_sym = _generated_local("c_result", func.arg_names)
    channel_sym = _generated_local("panic_channel", func.arg_names)
    ok_value = is_unit ? :nothing : :(convert_return($ok_julia_type, $c_sym.ok_value))

    quote
        # `<: FFIByValue` is RustCall's own by-value layout assertion about a
        # mirror it generated (#245): the wrapper crate declares this aggregate
        # `#[repr(C)]` through the same `generate_c_result_type` the `#[julia]`
        # path uses, so the claim is identical.
        struct $c_result_struct_name <: FFIByValue
            is_ok::UInt8
            ok_value::$ok_slot_type
            # Always `RustCall.PYO3_ERROR_CODE`; the message is fixed.
            err_value::Int32
        end

        function $func_name($(arg_syms...))
            $(bindings...)
            $ptr_sym, $channel_sym = _call_target($symbol_str)
            $c_sym = GC.@preserve $(preserved...) call_rust_function($ptr_sym, $c_result_struct_name, $(converted_args...))
            # A panic returns the Err discriminant with an uninitialized
            # payload, so the channel is read before anything is decoded (#244).
            _guard_panic(nothing, $channel_sym, $func_name_str)
            if $c_sym.is_ok == 1
                RustResult{$ok_julia_type, String}(true, $ok_value)
            else
                RustResult{$ok_julia_type, String}(false, RustCall.PYO3_OPAQUE_ERROR)
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

    # See `_generate_result_function_wrapper`: the payload field holds the C
    # slot, the surface type is what the caller sees.
    inner_julia_type, inner_slot_type =
        ffi_payload_symbols(func.inner_type, func.inner_abi, _ffi_context(func))
    free_str = _payload_free_symbol(func_name_str, (func.inner_abi,))

    # The C-compatible struct name generated by the proc-macro
    c_option_struct_name = Symbol("COption_", func_name_str)
    ptr_sym = _generated_local("func_ptr", func.arg_names)
    c_sym = _generated_local("c_option", func.arg_names)
    channel_sym = _generated_local("panic_channel", func.arg_names)
    free_sym = _generated_local("free_ptr", func.arg_names)
    target = isempty(free_str) ?
        :(($ptr_sym, $channel_sym) = _call_target($symbol_str)) :
        :(($ptr_sym, $channel_sym, $free_sym) = _call_target($symbol_str, $free_str))
    free_expr = isempty(free_str) ? :(C_NULL) : free_sym

    quote
        # Define the C-compatible struct for this function's option
        # See the Result wrapper: RustCall's own mirror (#245).
        struct $c_option_struct_name <: FFIByValue
            is_some::UInt8
            value::$inner_slot_type
        end

        function $func_name($(arg_syms...))
            # String arguments are converted first: an argument may be called
            # `func_ptr`, so the pointer local is resolved only afterwards.
            $(bindings...)
            $target
            $c_sym = GC.@preserve $(preserved...) call_rust_function($ptr_sym, $c_option_struct_name, $(converted_args...))
            _guard_panic(nothing, $channel_sym, $func_name_str)
            # Convert to RustOption
            if $c_sym.is_some == 1
                RustOption{$inner_julia_type}(true, _result_payload($inner_julia_type, $c_sym.value, $free_expr))
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
            free_ptr::Ptr{Cvoid}
            alive::Base.RefValue{Bool}

            # The destructor and the liveness flag are handed in by the call
            # that allocated `ptr`, from that call's own snapshot: a finalizer
            # must do no `dlsym` and compile no method (#249), and resolving
            # them after the constructor returned could pair a pointer from the
            # retired image with the replacement's destructor (#277).
            function $struct_name(ptr::Ptr{Cvoid}, free_ptr::Ptr{Cvoid},
                                  alive::Base.RefValue{Bool})
                obj = new(ptr, free_ptr, alive)
                finalizer(RustCall.finalize_rust_object!, obj)
                return obj
            end

            # For a pointer that did not come from a call of this module.
            function $struct_name(ptr::Ptr{Cvoid})
                free_ptr, alive = _struct_generation($(ffi_struct_free_symbol(struct_name_str)))
                return $struct_name(ptr, free_ptr, alive)
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

    # Generate field accessors (get_field, set_field! functions), for every
    # field the manifest names an accessor of — a setter alone included.
    for (field_name, field_type) in info.fields
        if field_is_accessible(info, field_name) || field_is_writable(info, field_name)
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
    _crate_field_read(info, field_name, field_type, ptr_expr, self_ptr_expr) -> Expr

How a crate-mode field getter is *read*: the one decision, from
`ffi_return_contract`. A field whose manifest `abi` is `"string"` comes back as
an owned `<Struct>_RustCallOwnedString` buffer released through the contract's
`free_symbol`; every other field is a single C slot.
"""
function _crate_field_read(info::RustStructInfo, field_name::AbstractString,
                           field_type::AbstractString, getter_symbol::AbstractString,
                           self_ptr_expr)
    c = _ffi_field_return(info, field_name, field_type)
    ptr_expr = :(_get_func_ptr($(String(getter_symbol))))
    if ffi_owned_string_return(c)
        # Getter and release function from one snapshot: separately resolved,
        # a reload between them freed the buffer through the wrong image (#277).
        return quote
            let (fp, _, freep) = _call_target($(String(getter_symbol)), $(c.free_symbol))
                _call_rust_owned_string_ptr(fp, freep, $self_ptr_expr)
            end
        end
    elseif ffi_borrowed_string_return(c)
        return :(_call_rust_borrowed_string_ptr($ptr_expr, $self_ptr_expr))
    end
    julia_type = ffi_return_symbol_or_throw(field_type, get(info.field_abis, field_name, ""),
                                            _ffi_field_context(info, field_name, field_type))
    return :(call_rust_function($ptr_expr, $julia_type, $self_ptr_expr))
end

"""
    _crate_field_read_source(info, field_name, field_type, ptr_var, self_ptr) -> String

Source-text counterpart of `_crate_field_read` for the file emitter.
"""
function _crate_field_read_source(info::RustStructInfo, field_name::AbstractString,
                                  field_type::AbstractString, getter_symbol::AbstractString,
                                  self_ptr::String; strict::Symbol = FFI_STRICT[])
    c = _ffi_field_return(info, field_name, field_type)
    ptr_expr = "_get_func_ptr(\"$getter_symbol\")"
    if ffi_owned_string_return(c)
        # Getter and release function from one snapshot (#277).
        return "let (fp, _, freep) = _call_target(\"$getter_symbol\", \"$(c.free_symbol)\"); " *
               "_call_rust_owned_string_ptr(fp, freep, $self_ptr); end"
    elseif ffi_borrowed_string_return(c)
        return "_call_rust_borrowed_string_ptr($ptr_expr, $self_ptr)"
    end
    julia_type = ffi_return_symbol_or_throw(field_type, get(info.field_abis, field_name, ""),
                                            _ffi_field_context(info, field_name, field_type);
                                            strict = strict)
    return "call_rust_function($ptr_expr, $julia_type, $self_ptr)"
end

"""
    _generate_property_accessors(info::RustStructInfo) -> Union{Expr, Nothing}

Generate Base.getproperty and Base.setproperty! methods for natural field access.
This allows `obj.field` and `obj.field = value` syntax.
"""
function _generate_property_accessors(info::RustStructInfo)
    struct_name = Symbol(info.name)
    struct_name_str = info.name

    # A field is a property when the manifest names an accessor for it: a
    # getter, a setter, or both. `#[julia]` structs carry both; a `#[pyclass]`
    # field carries exactly what `#[pyo3(get)]` / `#[pyo3(set)]` declared, so a
    # write-only field gets a `setproperty!` branch and no `getproperty` one.
    # Nothing here invents a symbol the manifest did not list (#307 review).
    readable_fields = [(name, type) for (name, type) in info.fields if field_is_accessible(info, name)]
    writable_fields = [(name, type) for (name, type) in info.fields if field_is_writable(info, name)]
    property_fields = [(name, type) for (name, type) in info.fields
                       if field_is_accessible(info, name) || field_is_writable(info, name)]

    if isempty(property_fields)
        return nothing
    end

    # Build getproperty branches
    getprop_branches = Expr[]
    for (field_name, field_type) in readable_fields
        field_sym = QuoteNode(Symbol(field_name))
        getter_fn = info.field_getters[field_name]
        # A `String` field getter hands back an owned buffer, on the crate path
        # too since manifest schema 4 — it used to be read as `Any` (#246).
        read = _crate_field_read(info, field_name, field_type, getter_fn,
                                 :(getfield(self, :ptr)))
        push!(getprop_branches, quote
            if field === $field_sym
                return $read
            end
        end)
    end

    # Build setproperty! branches
    setprop_branches = Expr[]
    for (field_name, field_type) in writable_fields
        field_sym = QuoteNode(Symbol(field_name))
        setter_fn = info.field_setters[field_name]

        push!(setprop_branches, quote
            if field === $field_sym
                func_ptr = _get_func_ptr($setter_fn)
                call_rust_function(func_ptr, Cvoid, getfield(self, :ptr), value)
                return value
            end
        end)
    end

    # Generate the field names tuple for propertynames
    field_symbols = [QuoteNode(Symbol(name)) for (name, _) in property_fields]

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

Check that a wrapped Rust object has not been freed, raising rather than
letting the call dereference `C_NULL` inside Rust.

The generated `@rust_crate` modules and the emitted bindings files import this
name, so it stays; the implementation is `check_not_freed`
(`src/structs.jl`), which the inline `#[julia]` structs use as well. One rule,
one message, both flavours (#249, #277 Phase B4).
"""
_check_not_freed(obj, type_name::String) = check_not_freed(obj, type_name)

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
    c = ffi_return_contract(method.return_type; abi = method.return_abi, owner = helper_owner)

    all_args = Any[]
    method.is_static || push!(all_args, :(getfield(self, :ptr)))
    append!(all_args, converted_args)

    channel_sym = _generated_local("panic_channel", method.arg_names)
    free_sym = _generated_local("free_ptr", method.arg_names)
    target = :(($ptr_sym, $channel_sym) = _call_target($wrapper_name))
    alive_sym = _generated_local("alive", method.arg_names)
    # A `PyResult` method needs a C struct declared next to the wrapper, so it
    # is built whole rather than as one `call` expression (#275 Phase 2).
    if method.return_kind === :py_result
        return _generate_py_result_method_wrapper(info, method, arg_syms, bindings, preserved,
                                                  converted_args, wrapper_name)
    end
    # Definitions the wrapper needs next to it: the `#[repr(C)]` mirror of a
    # `CResult_<Struct>_<method>` / `COption_<Struct>_<method>` aggregate (#268).
    predefs = Expr[]
    payload_body = nothing
    if method.return_kind === :result || method.return_kind === :option
        plan = _method_payload_plan(info, method, helper_owner)
        push!(predefs, plan.definition)
        payload_target = isempty(plan.free_symbol) ?
            :(($ptr_sym, $channel_sym) = _call_target($wrapper_name)) :
            :(($ptr_sym, $channel_sym, $free_sym) = _call_target($wrapper_name, $(plan.free_symbol)))
        free_expr = isempty(plan.free_symbol) ? :(C_NULL) : free_sym
        c_sym = _generated_local("c_payload", method.arg_names)
        method.is_static || pushfirst!(preserved, :self)
        payload_body = quote
            $(bindings...)
            $payload_target
            $c_sym = $(_quote_preserved(preserved,
                                        :(call_rust_function($ptr_sym, $(plan.struct_name),
                                                             $(all_args...)))))
            # A panic returns the `panicked()` sentinel — the Err / None
            # discriminant with an uninitialized payload — so the channel is
            # read *before* anything is decoded (#244).
            _guard_panic(nothing, $channel_sym, $("$(struct_name_str)::$(method.name)"))
            $(_payload_decode_expr(plan, c_sym, free_expr))
        end
    end
    call = if payload_body !== nothing
        # The payload branch builds its own body; the return-contract lookups
        # below cannot describe a `Result<..>` spelling and would raise (#268).
        nothing
    elseif method.returns_boxed_struct
        # Constructors and `Self`-returning methods allocate, so the object is
        # bound to the generation that ran the call (#277).
        target = :(($ptr_sym, $channel_sym, $free_sym, $alive_sym) =
                       _ctor_target($wrapper_name, $(ffi_struct_free_symbol(struct_name_str))))
        :($struct_name(call_rust_function($ptr_sym, Ptr{Cvoid}, $(all_args...)),
                       $free_sym, $alive_sym))
    elseif ffi_owned_string_return(c)
        target = :(($ptr_sym, $channel_sym, $free_sym) = _call_target($wrapper_name, $(c.free_symbol)))
        :(_call_rust_owned_string_ptr($ptr_sym, $free_sym, $(all_args...)))
    elseif ffi_borrowed_string_return(c)
        :(_call_rust_borrowed_string_ptr($ptr_sym, $(all_args...)))
    else
        julia_ret_type = ffi_return_symbol_or_throw(method.return_type, method.return_abi,
                                                    _ffi_context(method, struct_name_str))
        :(call_rust_function($ptr_sym, $julia_ret_type, $(all_args...)))
    end
    # The wrapper object itself is kept alive for the whole call as well: a
    # borrowed `&str` result points into the Rust object, which the finalizer
    # of a temporary `self` could otherwise free mid-call.
    payload_body === nothing && !method.is_static && pushfirst!(preserved, :self)
    method_label = "$(struct_name_str)::$(method.name)"
    body = payload_body !== nothing ? payload_body : quote
        $(bindings...)
        $target
        _guard_panic($(_quote_preserved(preserved, call)), $channel_sym, $method_label)
    end

    definition = if method.is_static && method.is_constructor
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
    isempty(predefs) ? definition : Expr(:block, predefs..., definition)
end

"""
    MethodPayloadPlan

Everything both `@rust_crate` method emitters need for a `Result` / `Option`
return (#268): the name of the `#[repr(C)]` mirror, its definition, the surface
types the caller sees, and the `<owner>_free_rust_string` an owned-string
payload is released through (empty when no payload is one).
"""
struct MethodPayloadPlan
    kind::Symbol
    struct_name::Symbol
    definition::Expr
    source::String
    surface::Tuple{Any, Any}
    free_symbol::String
end

"""
    _method_payload_plan(info, method, helper_owner) -> MethodPayloadPlan

The `CResult_<Struct>_<method>` / `COption_<Struct>_<method>` mirror of one
method, shared by the in-memory `@rust_crate` emitter and the source-text one so
the two cannot describe the same aggregate differently.

`helper_owner` is what the wrapper's owned-string buffer is named after — the
struct for an inline method, `<Struct>_<method>` for a crate one — and is the
only thing that differs between the flavours.
"""
function _method_payload_plan(info::RustStructInfo, method::RustMethod,
                              helper_owner::AbstractString;
                              strict::Symbol = FFI_STRICT[])
    ctx = _ffi_context(method, info.name)
    if method.return_kind === :result
        ok_t, ok_slot = ffi_payload_symbols(method.ok_type, method.ok_abi, ctx; strict = strict)
        err_t, err_slot = ffi_payload_symbols(method.err_type, method.err_abi, ctx; strict = strict)
        name = Symbol("CResult_", info.name, "_", method.name)
        definition = quote
            # RustCall's own mirror of the extractor's `#[repr(C)]` aggregate,
            # so it carries the by-value layout assertion in its supertype
            # (#245).
            struct $name <: FFIByValue
                is_ok::UInt8
                ok_value::$ok_slot
                err_value::$err_slot
            end
        end
        source = """
struct $name <: FFIByValue
    is_ok::UInt8
    ok_value::$ok_slot
    err_value::$err_slot
end"""
        free = _payload_free_symbol(helper_owner, (method.ok_abi, method.err_abi))
        return MethodPayloadPlan(:result, name, definition, source, (ok_t, err_t), free)
    end
    inner_t, inner_slot =
        ffi_payload_symbols(method.inner_type, method.inner_abi, ctx; strict = strict)
    name = Symbol("COption_", info.name, "_", method.name)
    definition = quote
        struct $name <: FFIByValue
            is_some::UInt8
            value::$inner_slot
        end
    end
    source = """
struct $name <: FFIByValue
    is_some::UInt8
    value::$inner_slot
end"""
    free = _payload_free_symbol(helper_owner, (method.inner_abi,))
    return MethodPayloadPlan(:option, name, definition, source, (inner_t, nothing), free)
end

# The expression that turns the aggregate bound to `c_sym` into a
# `RustResult` / `RustOption`. Only the active payload is decoded, and only it
# is released (#268).
function _payload_decode_expr(plan::MethodPayloadPlan, c_sym::Symbol, free_expr)
    if plan.kind === :result
        ok_t, err_t = plan.surface
        return quote
            if $c_sym.is_ok == 1
                RustResult{$ok_t, $err_t}(true, _result_payload($ok_t, $c_sym.ok_value, $free_expr))
            else
                RustResult{$ok_t, $err_t}(false, _result_payload($err_t, $c_sym.err_value, $free_expr))
            end
        end
    end
    inner_t, _ = plan.surface
    return quote
        if $c_sym.is_some == 1
            RustOption{$inner_t}(true, _result_payload($inner_t, $c_sym.value, $free_expr))
        else
            RustOption{$inner_t}(false, nothing)
        end
    end
end

"""
    _generate_py_result_method_wrapper(info, method, ...) -> Expr

Julia wrapper for a scanned `#[pymethods]` method returning `PyResult<T>`
(#275 Phase 2), the method twin of `_generate_py_result_function_wrapper`. The
C struct is `CResult_<Struct>_<method>`, matching the name the wrapper
generator gives it.
"""
function _generate_py_result_method_wrapper(info::RustStructInfo, method::RustMethod,
                                            arg_syms::Vector{Symbol}, bindings::Vector,
                                            preserved::Vector, converted_args::Vector,
                                            wrapper_name::String)
    struct_name = Symbol(info.name)
    struct_name_str = info.name
    method_name = Symbol(method.name)
    ok_julia_type, ok_slot_type, is_unit =
        _py_result_types(method.ok_type, _ffi_context(method, struct_name_str))

    c_result_struct_name = Symbol("CResult_", struct_name_str, "_", method.name)
    ptr_sym = _generated_local("func_ptr", method.arg_names)
    c_sym = _generated_local("c_result", method.arg_names)
    channel_sym = _generated_local("panic_channel", method.arg_names)

    all_args = Any[]
    method.is_static || push!(all_args, :(getfield(self, :ptr)))
    append!(all_args, converted_args)
    method.is_static || pushfirst!(preserved, :self)
    method_label = "$(struct_name_str)::$(method.name)"
    ok_value = is_unit ? :nothing : :(convert_return($ok_julia_type, $c_sym.ok_value))

    body = quote
        $(bindings...)
        $ptr_sym, $channel_sym = _call_target($wrapper_name)
        $c_sym = $(_quote_preserved(preserved,
                                    :(call_rust_function($ptr_sym, $c_result_struct_name,
                                                         $(all_args...)))))
        _guard_panic(nothing, $channel_sym, $method_label)
        if $c_sym.is_ok == 1
            RustResult{$ok_julia_type, String}(true, $ok_value)
        else
            RustResult{$ok_julia_type, String}(false, RustCall.PYO3_OPAQUE_ERROR)
        end
    end

    declaration = quote
        # RustCall's own mirror of a `#[repr(C)]` aggregate it generated (#245).
        struct $c_result_struct_name <: FFIByValue
            is_ok::UInt8
            ok_value::$ok_slot_type
            err_value::Int32
        end
    end

    if method.is_static
        quote
            $declaration
            function $method_name($(arg_syms...))
                $body
            end
            export $method_name
        end
    else
        quote
            $declaration
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
    exprs = Expr[]

    # `get_<field>` and `set_<field>!`, each only when the manifest names the
    # accessor: a `set`-only `#[pyo3(set)]` field has the second and not the
    # first (#307 review).
    # Both helpers check the object is still live before touching its pointer,
    # as `getproperty` / `setproperty!` and every instance method do: after an
    # explicit `finalize(obj)` the pointer is `C_NULL`, and handing that to the
    # Rust accessor is a crash where the others raise a `RustError` (#307
    # review).
    struct_name_str = info.name
    if field_is_accessible(info, field_name)
        getter_name = info.field_getters[field_name]
        read = _crate_field_read(info, field_name, field_type, getter_name,
                                 :(self.ptr))
        push!(exprs, quote
            function $(Symbol("get_$field_name"))(self::$struct_name)
                _check_not_freed(self, $struct_name_str)
                $read
            end
        end)
    end
    if field_is_writable(info, field_name)
        setter_name = info.field_setters[field_name]
        push!(exprs, quote
            function $(Symbol("set_$(field_name)!"))(self::$struct_name, value)
                _check_not_freed(self, $struct_name_str)
                func_ptr = _get_func_ptr($setter_name)
                call_rust_function(func_ptr, Cvoid, self.ptr, value)
                value
            end
        end)
    end

    return Expr(:block, exprs...)
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
    cache_enabled::Bool = true,
    features::Vector{String} = String[],
    default_features::Bool = true
)
    opts = CrateBindingOptions(
        output_module_name = output_module_name,
        build_release = build_release,
        cache_enabled = cache_enabled,
        features = features,
        default_features = default_features
    )

    # Scan the crate
    @info "Scanning crate at $crate_path"
    info = scan_crate(crate_path)
    @info "Found $(length(info.julia_functions)) functions and $(length(info.julia_structs)) structs"

    # A crate that carries only PyO3 attributes gets a generated wrapper crate
    # (#275 Phase 2); everything else takes the pre-#275 path — under the
    # configuration this build compiles with (`_plain_scan_info`).
    plain = true
    if crate_needs_pyo3_wrapper(info)
        plan = pyo3_link_plan(crate_path; features = features,
                              default_features = default_features, release = build_release)
        wrapper = build_pyo3_wrapper(info; features = features,
                                     default_features = default_features,
                                     release = build_release, cache_enabled = cache_enabled,
                                     plan = plan)
        if wrapper === nothing
            # Under this build's own configuration the crate exposes nothing to
            # PyO3 (every marker is behind a feature that is off), so there is
            # nothing to wrap and the pre-#275 path applies — under that same
            # configuration: the lenient scan lists every feature variant of a
            # `#[julia]` item, the resolved one says which this build compiles
            # (#307 review).
            @info "No PyO3 item is exposed by this build; binding the crate as before"
            info = _resolved_plain_info(crate_path, info, plan)
            plain = false
        else
            @info "Wrapped $(length(wrapper.info.julia_functions)) functions and " *
                  "$(length(wrapper.info.julia_structs)) types ($(wrapper.plan.mode))"
            return emit_crate_module(wrapper.info, loadable_library_copy(wrapper.lib_path);
                                     module_name = output_module_name,
                                     build_release = build_release,
                                     lib_name = wrapper.lib_name,
                                     preload = wrapper.plan.runtime_libraries)
        end
    end
    plain && (info = _plain_scan_info(crate_path, info, features, default_features, build_release))

    # Check cache. The feature set is part of the identity on this path too:
    # a build the caller asked for with `features` / `default_features` is
    # not the default build, and must neither answer its lookup nor be built
    # as it (#307 review).
    cache_key = compute_crate_hash(info; release = build_release,
                                   features = features, default_features = default_features)
    cached_lib = cache_enabled ? get_cargo_cached_library(cache_key) : nothing

    lib_path = if cached_lib !== nothing && isfile(cached_lib)
        @info "Using cached library"
        cached_lib
    else
        # Check if the crate already has cdylib crate-type
        if crate_has_cdylib(crate_path)
            # Build the crate directly
            @info "Building crate directly (already has cdylib crate-type)..."
            lib_path = build_crate_directly(info, build_release;
                                            features = features,
                                            default_features = default_features)
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
                lib_path = build_cargo_project(wrapper_project, release=build_release,
                                               policy=crate_wrapper_policy())
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

    # RustCall never maps the file Cargo writes: a later build of the same
    # crate rewrites its output in place, which on Windows *fails* against a
    # mapped DLL (`Access is denied`) and elsewhere silently hands the old
    # image back to the next `dlopen`. Opening a private copy leaves Cargo's
    # output free (#255, #277).
    lib_path = loadable_library_copy(lib_path)

    # Generate module. The registry name follows the key, feature set
    # included, so two feature sets of one crate are two entries.
    @info "Generating Julia module..."
    return emit_crate_module(info, lib_path; module_name=output_module_name,
                             build_release=build_release,
                             lib_name=crate_library_name(info; release = build_release,
                                                         features = features,
                                                         default_features = default_features))
end

"""
    _plain_scan_info(crate_path, info, features, default_features, release) -> CrateInfo

The scan the plain (`#[julia]`) path emits bindings from: `info` rescanned under
the configuration the crate is **built** with — `rustc --print cfg` of the crate
as its own Cargo root, under the requested profile and feature flags
(`_crate_build_cfg_text`) — so every `#[cfg]` is decided the way the build
decides it.

The lenient scan lists every feature variant of an item; the build has exactly
one of them. Emitting the lenient list produced a module that named symbols the
library does not export (a `#[cfg(feature = "x")] #[julia] fn` with `x` off),
or the wrong one of two mutually exclusive signatures, and the mismatch
surfaced as a `dlsym` failure on the first call. Hot reload has always
rescanned this way after a rebuild (`_scan_crate_signatures`); the first load now
does too, and the feature set a caller asks for (`features`,
`default_features`) is what the probe runs under, as it is what the build
runs under (#307 review; #277 Phase B).

The probe has the shape of the build. A crate with a `cdylib` target is built
**as the Cargo root** (`build_crate_directly`), so it is probed as one and its
own `[profile.*]` applies. Any other crate is built as the dependency of a
generated `_julia_wrapper` root, whose profile — RustCall's, `panic = "unwind"`
pinned — replaces the crate's own; such a crate is probed as a wrapper's
dependency (`_wrapper_probe_cfg_text`), so a `#[cfg(debug_assertions)]` item
under a crate-level `debug-assertions = true` is scanned the way the build
compiles it: out (#307 review).

`info` is returned unchanged when Cargo will not answer (no cargo, an
unresolvable crate); the build then fails on its own terms.
"""
function _plain_scan_info(crate_path::AbstractString, info::CrateInfo,
                          features::Vector{String}, default_features::Bool, release::Bool)
    path = String(crate_path)
    cfg_text = if crate_has_cdylib(path)
        _crate_build_cfg_text(path; profile = release ? "release" : "debug",
                              features = _cargo_feature_args(features, default_features))
    else
        _wrapper_probe_cfg_text(path; features = features, default_features = default_features,
                                release = release)
    end
    isempty(cfg_text) && return info
    return scan_crate(path; cfg = :cargo, cfg_text = cfg_text)
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
function build_crate_directly(info::CrateInfo, release::Bool;
                              features::Vector{String} = String[],
                              default_features::Bool = true)
    # Create a CargoProject that points to the original crate
    project = CargoProject(
        info.name,
        info.version,
        info.dependencies,
        "2021",
        info.path
    )

    # The Cargo root here is the *user's* manifest, so the policy pins nothing
    # and their profile decides (`crate_direct_policy`, #244). The feature set
    # is the caller's, exactly as a wrapper build's is (#307 review).
    build_cargo_project(project, release=release, policy=crate_direct_policy(),
                        features=features, default_features=default_features)
end

"""
    BINDINGS_FORMAT_VERSION

Format marker carried by every file `write_bindings_to_file` emits.

Bumped when a generated bindings file stops being interchangeable with one an
older RustCall produced.

- `2` (#277 Phase B5): the file loads its library through
  `RustCall.load_artifact!` rather than `Libdl.dlopen`, so the handle is
  registered and `unload_library` can see it, and its struct finalizers capture
  a destructor pointer and the library's liveness flag instead of resolving the
  destructor when they run.
- `3` (#246): string arguments are built with `RustCall.ffi_string_argument`,
  which the file imports, so invalid UTF-8 raises instead of being substituted.
  That name does not exist in an older RustCall, so a file emitted here does
  not load against one — the direction the marker is really for.
- `4` (#245): the emitted `CResult_<fn>` / `COption_<fn>` mirrors subtype
  `RustCall.FFIByValue`, which the file imports. That name does not exist in an
  older RustCall, so a file emitted here does not load against one — the
  direction the marker is really for.

- `5` (#268): a method returning `Result<T, E>` / `Option<T>` emits a
  `CResult_<Struct>_<method>` / `COption_<Struct>_<method>` mirror and decodes
  it with `RustCall._result_payload`, which the file imports and which does not
  exist in an older RustCall. The same import carries the release of an owned
  `String` payload, so a file emitted here must not be loaded against a
  RustCall that would leak it.

A file emitted by an older version still *works* — it only uses public API that
still exists — but it does not get the unload, panic or lifetime guarantees.
Regenerate after upgrading; the marker is what makes that visible.
"""
const BINDINGS_FORMAT_VERSION = 5

"""
    crate_library_name(info::CrateInfo; release = true) -> String

The `RUST_LIBRARIES` key a `@rust_crate` library is registered under:
`rust_crate_<crate name>_<short id of the crate identity for that profile>`.

The **profile is part of the name**, exactly as it is part of the cache key
(`compute_crate_hash(info; release)`). A debug and a release build of one crate
are two different binaries, and giving them one registry name made them clobber
each other: the second `@rust_crate` replaced the first\'s entry, retired its
liveness flag out from under objects that were still alive, and pointed its
module mirror at the other profile\'s image.

`@rust_crate` used to keep its handle only in a module-local `Ref`, so
`unload_library`, `unload_all_libraries` and every registry the rest of
RustCall keeps were blind to it (#250). Registering it means the same
transaction that publishes the handle also publishes the liveness flag its
objects capture, and unloading it retires them (#277 Phase B5).

Keyed by the crate identity so two crates — or one crate rebuilt under a
different toolchain — do not collide on one entry.
"""
crate_library_name(info::CrateInfo; release::Bool = true, kind::AbstractString = "crate",
                   features::Vector{String} = String[], default_features::Bool = true,
                   build_env::Vector{Pair{String, String}} = Pair{String, String}[]) =
    "rust_crate_$(info.name)_$(artifact_short_id(compute_crate_hash(info; release = release,
        kind = kind, features = features, default_features = default_features,
        build_env = build_env)))"

"""
    compute_crate_hash(info::CrateInfo) -> String

Identity of an external crate build: `artifact_key` of an `ArtifactId`, so the
`@rust_crate` path answers "which artifact is this?" with the same function as
every other path (#278).

What it covers, and what the previous formula missed:

- **the whole crate directory**, through `crate_content_digest`, not only the
  `.rs` files the scan happened to list — so `Cargo.toml`, `Cargo.lock`,
  `build.rs` and any `include_str!`ed data are inputs;
- **local path dependencies**, by content, through
  `artifact_path_dependency_digest`, so editing a sibling crate rebuilds;
- **the effective Cargo configuration** of the crate directory
  (`.cargo/config.toml` and the chain above it, plus the Cargo home file);
- **the toolchain and the compiler that runs**, defaulted by `ArtifactId`;
- the release profile, and the crate's name and version as before.

Absolute paths are deliberately absent: an identical crate checked out
elsewhere keys the same, so a cache hit survives a move.

The name, the signature and the return type (a hex `String`) are unchanged, and
so is the format of the file `write_bindings_to_file` emits; only the *value*
changes, which means the first build after upgrading rebuilds.
"""
function compute_crate_hash(info::CrateInfo; release::Bool = true,
                            kind::AbstractString = "crate",
                            features::Vector{String} = String[],
                            default_features::Bool = true,
                            build_env::Vector{Pair{String, String}} = Pair{String, String}[])
    # The dependency digest first, and deliberately so: resolving the graph
    # lets Cargo write `Cargo.lock` into the crate directory (exactly as the
    # build that follows would), and `Cargo.lock` is one of the files
    # `crate_content_digest` hashes. Computing the content digest first would
    # make the very first call disagree with every later one.
    deps_digest = artifact_path_dependency_digest(info.path)
    # `kind` and the feature set are what separates a #275 Phase-2 wrapper
    # build from a plain `@rust_crate` build of the same crate, and one feature
    # set from another: the wrapper's `lib.rs`, its dependency's resolved
    # features and the RUSTFLAGS it links with are all decided by them, and two
    # such builds are different binaries under one crate directory. The
    # feature set is in the key for *every* kind: a plain build made with
    # `features = ...` / `default_features = false` is a different binary
    # from the default build too (#307 review).
    codegen = Pair{String, String}["profile" => (release ? "release" : "debug"),
                                   "features" => join(features, ","),
                                   "default-features" => string(default_features)]
    # `build_env` is the caller's, appended to the Cargo-config digest every
    # crate build already carries. A #275 wrapper build passes
    # `artifact_build_env()` plus its own link flags, because it inherits the
    # ambient `RUSTFLAGS` and the rest of the #282 allowlist — two builds under
    # different ambient flags are different binaries and must not share a key.
    env = Pair{String, String}["cargo-config" => _cargo_config_digest(ENV; dir = info.path)]
    append!(env, build_env)
    extra = Pair{String, String}["name" => info.name, "version" => info.version]
    # A workspace member's build is decided by files outside its directory:
    # the workspace root's manifest (`[workspace.dependencies]`, `[patch]`)
    # and lockfile, which a wrapper build now carries over
    # (`_wrapper_shaped_project`). Hashed by content, so a change there that
    # touches no file of the member still rebuilds (#307 review, #278).
    root = _cargo_root_dir(info.path)
    if root != abspath(info.path)
        push!(extra, "workspace-root-manifest" => _file_content_digest(joinpath(root, "Cargo.toml")))
        push!(extra, "workspace-root-lock" => _file_content_digest(joinpath(root, "Cargo.lock")))
    end
    # So is a library root outside the package directory (`[lib] path =
    # "../shared/lib.rs"`), which the scan follows and `source` — the package
    # directory's content — does not see (#307 review).
    manifest_path = joinpath(info.path, "Cargo.toml")
    lib_root = isfile(manifest_path) ? crate_lib_root(info.path, parse_cargo_toml(manifest_path)) :
                                       nothing
    external = external_lib_tree_digest(info.path, lib_root)
    external === nothing || push!(extra, "external-lib-tree" => external)
    return artifact_key(ArtifactId(
        kind = String(kind),
        source = crate_content_digest(info.path),
        codegen = codegen,
        dependencies = String[deps_digest],
        build_env = env,
        extra = extra,
    ))
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
    cache_enabled::Bool = true,
    features::Vector{String} = String[],
    default_features::Bool = true,
)
    bindings_expr = generate_bindings(
        crate_path;
        output_module_name = output_module_name,
        build_release = build_release,
        cache_enabled = cache_enabled,
        features = features,
        default_features = default_features,
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
    features = :(String[])
    default_features = true

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
            elseif key == :features
                features = value
            elseif key == :default_features
                default_features = value
            end
        end
    end

    quote
        load_crate_bindings(
            $(esc(path));
            output_module_name = $module_name,
            build_release = $release,
            cache_enabled = $cache,
            features = String[$(esc(features))...],
            default_features = $(esc(default_features)),
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
    strict::Symbol = FFI_STRICT[],
    features::Vector{String} = String[],
    default_features::Bool = true
)
    # Scan and build the crate
    @info "Scanning crate at $crate_path"
    info = scan_crate(crate_path)
    @info "Found $(length(info.julia_functions)) functions and $(length(info.julia_structs)) structs"

    # A PyO3-only crate is bound through a generated wrapper crate, exactly as
    # `@rust_crate` binds it (#275 Phase 2); `info` and the library name that
    # goes into the file come from the wrapper's own manifest.
    lib_name = nothing
    wrapper_lib_path = ""
    preload = String[]
    plain = true
    if crate_needs_pyo3_wrapper(info)
        plan = pyo3_link_plan(crate_path; features = features,
                              default_features = default_features, release = build_release)
        wrapper = build_pyo3_wrapper(info; features = features,
                                     default_features = default_features,
                                     release = build_release, plan = plan)
        # `nothing` when this build exposes nothing to PyO3; the plain path
        # then binds the crate under the resolved configuration, see
        # `generate_bindings` and `_resolved_plain_info` (#307 review).
        if wrapper === nothing
            info = _resolved_plain_info(crate_path, info, plan)
        else
            info = wrapper.info
            lib_name = wrapper.lib_name
            wrapper_lib_path = wrapper.lib_path
            preload = wrapper.plan.runtime_libraries
        end
        plain = false
    end
    # The plain path scans under the configuration it builds (#307 review).
    plain && (info = _plain_scan_info(crate_path, info, features, default_features, build_release))

    # Build the crate. On the plain path the feature set travels with the
    # build and with the registry name, as it does for a wrapper build.
    lib_name === nothing &&
        (lib_name = crate_library_name(info; release = build_release,
                                       features = features, default_features = default_features))
    lib_path = if !isempty(wrapper_lib_path)
        wrapper_lib_path
    elseif crate_has_cdylib(crate_path)
        @info "Building crate directly (already has cdylib crate-type)..."
        build_crate_directly(info, build_release;
                             features = features, default_features = default_features)
    else
        # Create wrapper crate and build
        opts = CrateBindingOptions(
            output_module_name = output_module_name,
            build_release = build_release,
            features = features,
            default_features = default_features
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
            build_cargo_project(wrapper_project, release=build_release,
                                policy=crate_wrapper_policy())
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

    # Generate the module code as a string. `strict` is threaded through the
    # emitters rather than stashed in the global `FFI_STRICT[]`, so two
    # concurrent calls with different settings cannot interfere (#276).
    code = emit_crate_module_code(info, lib_path_for_code,
        module_name = output_module_name,
        use_relative_path = relative_lib_path !== nothing,
        build_release = build_release,
        strict = strict,
        lib_name = lib_name,
        preload = preload,
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
- `strict::Symbol`: how an unsupported return type is handled, see
  [`FFI_STRICT`](@ref). Threaded through every emitter rather than set globally,
  so concurrent calls do not interfere.
- `preload::Vector{String}`: libraries the image imports by name that the
  loader would not find on its own (a PyO3 wrapper's Python DLL on Windows),
  opened before it by `load_artifact!`. Emitted only when non-empty, so a file
  that needs none reads under a RustCall without the option.

# Returns
- `String`: Julia source code for the module
"""
function emit_crate_module_code(info::CrateInfo, lib_path::String;
    module_name::Union{String, Nothing} = nothing,
    use_relative_path::Bool = false,
    build_release::Bool = true,
    strict::Symbol = FFI_STRICT[],
    lib_name::Union{String, Nothing} = nothing,
    preload::Vector{String} = String[]
)
    # Determine module name
    mod_name = if module_name !== nothing
        module_name
    else
        snake_to_pascal(info.name)
    end

    lines = String[]

    # Header comment. The format marker is bumped whenever the emitted module
    # stops being interchangeable with an older one: since #277 Phase B5 the
    # file loads its library through `RustCall.load_artifact!` and its struct
    # finalizers capture a destructor pointer and a liveness flag, neither of
    # which an older RustCall provides. Regenerate after upgrading.
    push!(lines, "# Auto-generated bindings for $(info.name)")
    push!(lines, "# Generated by RustCall.jl - DO NOT EDIT")
    push!(lines, "# Bindings format: $(BINDINGS_FORMAT_VERSION)")
    push!(lines, "# Regenerate with: write_bindings_to_file(\"$(info.path)\", \"<output_path>\")")
    push!(lines, "")

    # Module start
    push!(lines, "module $mod_name")
    push!(lines, "")

    # Imports
    push!(lines, "import RustCall")
    push!(lines, "import RustCall: call_rust_function, get_function_pointer_from_lib, RustResult, RustOption, _check_not_freed,")
    push!(lines, "                 _call_rust_owned_string_ptr, _call_rust_borrowed_string_ptr, convert_return,")
    push!(lines, "                 _result_payload, FFIByValue")
    push!(lines, "import Libdl")
    push!(lines, "")

    # Library path constant
    if use_relative_path
        push!(lines, "const _LIB_PATH = joinpath(@__DIR__, $(repr(lib_path)))")
    else
        push!(lines, "const _LIB_PATH = $(repr(lib_path))")
    end
    push!(lines, "const _LIB_NAME = $(repr(lib_name === nothing ?
        crate_library_name(info; release = build_release) : lib_name))")
    if !isempty(preload)
        push!(lines, "# Libraries the image imports by name that the loader would not find on")
        push!(lines, "# its own (a PyO3 wrapper's Python DLL on Windows, which has no rpath),")
        push!(lines, "# opened before it.")
        push!(lines, "const _PRELOAD_LIBRARIES = $(repr(preload))")
    end
    push!(lines, "")
    push!(lines, "# Everything this module knows about the image it calls -- handle, liveness")
    push!(lines, "# flag and generation -- as one immutable value, published by the loader in")
    push!(lines, "# the transaction that swaps the registry entry (#277).")
    push!(lines, "const _LIB_GEN = Ref(RustCall.CrateGeneration())")
    push!(lines, "")
    push!(lines, "function __init__()")
    push!(lines, "    # Register before loading, and do not assign afterwards: an assignment")
    push!(lines, "    # after `load_artifact!` would overwrite a newer generation that a")
    push!(lines, "    # concurrent reload had already published.")
    push!(lines, "    RustCall.register_handle_mirror!(_LIB_NAME, _LIB_GEN)")
    push!(lines, "    RustCall.load_artifact!(RustCall.crate_direct_policy(), _LIB_PATH;")
    if isempty(preload)
        push!(lines, "                            lib_name = _LIB_NAME)")
    else
        push!(lines, "                            lib_name = _LIB_NAME, preload = _PRELOAD_LIBRARIES)")
    end
    push!(lines, "end")
    push!(lines, "")
    push!(lines, "# Resolved symbols, memoized per handle: a reload swaps the image under the")
    push!(lines, "# same module. Negative answers are cached too.")
    push!(lines, "const _SYMBOLS = Dict{Tuple{Ptr{Cvoid}, String}, Ptr{Cvoid}}()")
    push!(lines, "const _SYMBOL_LOCK = ReentrantLock()")
    push!(lines, "")
    push!(lines, "function _symbol(handle::Ptr{Cvoid}, name::String)")
    push!(lines, "    lock(_SYMBOL_LOCK) do")
    push!(lines, "        get!(_SYMBOLS, (handle, name)) do")
    push!(lines, "            ptr = Libdl.dlsym(handle, name; throw_error = false)")
    push!(lines, "            ptr === nothing ? C_NULL : ptr")
    push!(lines, "        end")
    push!(lines, "    end")
    push!(lines, "end")
    push!(lines, "")
    push!(lines, "function _required_symbol(handle::Ptr{Cvoid}, name::String)")
    push!(lines, "    ptr = _symbol(handle, name)")
    push!(lines, "    ptr == C_NULL && error(\"The Rust library '\" * _LIB_NAME *")
    push!(lines, "                           \"' does not export '\" * name * \"'.\")")
    push!(lines, "    ptr")
    push!(lines, "end")
    push!(lines, "")
    push!(lines, "function _live_handle(gen::RustCall.CrateGeneration)")
    push!(lines, "    gen.handle == C_NULL &&")
    push!(lines, "        error(\"The Rust library backing this module is not loaded. \" *")
    push!(lines, "              \"It was either never initialised, or unloaded with \" *")
    push!(lines, "              \"RustCall.unload_library(\\\"\" * _LIB_NAME * \"\\\").\")")
    push!(lines, "    gen.handle")
    push!(lines, "end")
    push!(lines, "")
    push!(lines, "_get_func_ptr(name::String) = _required_symbol(_live_handle(_LIB_GEN[]), name)")
    push!(lines, "")
    push!(lines, "# One snapshot per call, from ONE deref of `_LIB_GEN` (#277).")
    push!(lines, "function _call_target(symbol::String)")
    push!(lines, "    handle = _live_handle(_LIB_GEN[])")
    push!(lines, "    (_required_symbol(handle, symbol),")
    push!(lines, "     _symbol(handle, RustCall.ffi_panic_symbol(symbol)))")
    push!(lines, "end")
    push!(lines, "")
    push!(lines, "# ...and the owned-`String` arm, release function included.")
    push!(lines, "function _call_target(symbol::String, free_symbol::String)")
    push!(lines, "    handle = _live_handle(_LIB_GEN[])")
    push!(lines, "    (_required_symbol(handle, symbol),")
    push!(lines, "     _symbol(handle, RustCall.ffi_panic_symbol(symbol)),")
    push!(lines, "     _required_symbol(handle, free_symbol))")
    push!(lines, "end")
    push!(lines, "")
    push!(lines, "# The constructor arm: the allocating wrapper, its channel, and the")
    push!(lines, "# destructor and flag the resulting object carries -- one deref (#277).")
    push!(lines, "function _ctor_target(symbol::String, free_symbol::String)")
    push!(lines, "    gen = _LIB_GEN[]")
    push!(lines, "    handle = _live_handle(gen)")
    push!(lines, "    (_required_symbol(handle, symbol),")
    push!(lines, "     _symbol(handle, RustCall.ffi_panic_symbol(symbol)),")
    push!(lines, "     _symbol(handle, free_symbol),")
    push!(lines, "     gen.alive)")
    push!(lines, "end")
    push!(lines, "")
    push!(lines, "# A struct's destructor and the liveness flag of the image that exports it,")
    push!(lines, "# from the same deref (#249, #277).")
    push!(lines, "function _struct_generation(free_symbol::String)")
    push!(lines, "    gen = _LIB_GEN[]")
    push!(lines, "    gen.handle == C_NULL && return (C_NULL, gen.alive)")
    push!(lines, "    (_symbol(gen.handle, free_symbol), gen.alive)")
    push!(lines, "end")
    push!(lines, "")
    # The channel is resolved by the caller, before the wrapper call: it is a
    # thread-local in the image, so nothing may yield between the two (#244).
    push!(lines, "_guard_panic(value, channel::Ptr{Cvoid}, name::String) =")
    push!(lines, "    RustCall.guard_rust_panic_ptr(value, channel, name)")
    push!(lines, "")

    # Generate function wrappers
    for func in info.julia_functions
        if func.is_generic
            continue
        end
        code = _emit_function_code(func; strict = strict)
        push!(lines, code)
        push!(lines, "")
    end

    # Generate struct wrappers
    for s in info.julia_structs
        code = _emit_struct_code(s; strict = strict)
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
function _emit_function_code(func::RustFunctionSignature; strict::Symbol = FFI_STRICT[])
    func_name = func.name
    # The generated Julia function keeps the Rust name; the symbol it looks up
    # is the additive wrapper `rustcall_<name>` (#279).
    sym = func.symbol
    arg_names = func.arg_names
    # Resolved before the call in every branch below: the panic channel is a
    # thread-local in the image, so nothing may yield between the wrapper call
    # and the read of the channel (#244).
    channel_var = _generated_local("panic_channel", arg_names)
    # Bound in every branch below, not just the plain one: the string branches
    # call through the same snapshot.
    ptr_var = _generated_local("func_ptr", arg_names)
    free_var = _generated_local("free_ptr", arg_names)

    # Build argument conversions (string arguments become (ptr, len) pairs)
    arg_syms = join(arg_names, ", ")
    bindings_str, preserve_str, converted_args_str = _emit_string_arg_plan(func)
    prologue = isempty(bindings_str) ? "" : bindings_str * "\n"

    # Result/Option return types are reported by the manifest
    if func.return_kind == :result
        return _emit_result_function_code(func, arg_syms, converted_args_str; prologue, preserve_str, strict)
    elseif func.return_kind == :py_result
        return _emit_py_result_function_code(func, arg_syms, converted_args_str; prologue,
                                             preserve_str, strict)
    elseif func.return_kind == :option
        return _emit_option_function_code(func, arg_syms, converted_args_str; prologue, preserve_str, strict)
    elseif ffi_owned_string_return(_ffi_function_return(func))
        return """
function $func_name($arg_syms)
$(prologue)    $ptr_var, $channel_var, $free_var = _call_target("$sym", "$(_ffi_function_return(func).free_symbol)")
    _guard_panic($(_emit_preserved(preserve_str, "_call_rust_owned_string_ptr($ptr_var, $free_var, $converted_args_str)")), $channel_var, "$func_name")
end
export $func_name"""
    elseif ffi_borrowed_string_return(_ffi_function_return(func))
        return """
function $func_name($arg_syms)
$(prologue)    $ptr_var, $channel_var = _call_target("$sym")
    _guard_panic($(_emit_preserved(preserve_str, "_call_rust_borrowed_string_ptr($ptr_var, $converted_args_str)")), $channel_var, "$func_name")
end
export $func_name"""
    else
        # Standard function
        ret_type_str = string(ffi_return_symbol_or_throw(func.return_type, func.return_abi,
                                                         _ffi_context(func); strict = strict))
        return """
function $func_name($arg_syms)
$(prologue)    $ptr_var, $channel_var = _call_target("$sym")
    _guard_panic($(_emit_preserved(preserve_str, "call_rust_function($ptr_var, $ret_type_str, $converted_args_str)")), $channel_var, "$func_name")
end
export $func_name"""
    end
end

function _emit_result_function_code(func::RustFunctionSignature, arg_syms::String, converted_args_str::String;
                                    prologue::String = "", preserve_str::String = "",
                                    strict::Symbol = FFI_STRICT[])
    func_name = func.name
    ctx = _ffi_context(func)
    # The payload fields carry the C slot; see `_generate_result_function_wrapper`.
    ok_surface, ok_slot = ffi_payload_symbols(func.ok_type, func.ok_abi, ctx; strict = strict)
    err_surface, err_slot = ffi_payload_symbols(func.err_type, func.err_abi, ctx; strict = strict)
    ok_type_str = string(ok_surface)
    err_type_str = string(err_surface)
    ok_slot_str = string(ok_slot)
    err_slot_str = string(err_slot)
    sym = func.symbol
    c_result_struct_name = "CResult_$func_name"
    ptr_var = _generated_local("func_ptr", func.arg_names)
    c_var = _generated_local("c_result", func.arg_names)
    channel_var = _generated_local("panic_channel", func.arg_names)
    free_var = _generated_local("free_ptr", func.arg_names)
    free_str = _payload_free_symbol(func_name, (func.ok_abi, func.err_abi))
    target = isempty(free_str) ?
        "$ptr_var, $channel_var = _call_target(\"$sym\")" :
        "$ptr_var, $channel_var, $free_var = _call_target(\"$sym\", \"$free_str\")"
    free_expr = isempty(free_str) ? "C_NULL" : string(free_var)

    return """
struct $c_result_struct_name <: FFIByValue
    is_ok::UInt8
    ok_value::$ok_slot_str
    err_value::$err_slot_str
end

function $func_name($arg_syms)
$(prologue)    $target
    $c_var = $(_emit_preserved(preserve_str, "call_rust_function($ptr_var, $c_result_struct_name, $converted_args_str)"))
    _guard_panic(nothing, $channel_var, "$func_name")
    if $c_var.is_ok == 1
        RustResult{$ok_type_str, $err_type_str}(true, _result_payload($ok_type_str, $c_var.ok_value, $free_expr))
    else
        RustResult{$ok_type_str, $err_type_str}(false, _result_payload($err_type_str, $c_var.err_value, $free_expr))
    end
end
export $func_name"""
end

"""
    _emit_py_result_function_code(func, arg_syms, converted_args_str; ...) -> String

Source-text counterpart of `_generate_py_result_function_wrapper` (#275
Phase 2).
"""
function _emit_py_result_function_code(func::RustFunctionSignature, arg_syms::String,
                                       converted_args_str::String;
                                       prologue::String = "", preserve_str::String = "",
                                       strict::Symbol = FFI_STRICT[])
    func_name = func.name
    ok_type_str, ok_slot_str, is_unit =
        _py_result_types(func.ok_type, _ffi_context(func); strict = strict)
    sym = func.symbol
    c_result_struct_name = "CResult_$func_name"
    ptr_var = _generated_local("func_ptr", func.arg_names)
    c_var = _generated_local("c_result", func.arg_names)
    channel_var = _generated_local("panic_channel", func.arg_names)
    ok_value = is_unit ? "nothing" : "convert_return($ok_type_str, $c_var.ok_value)"

    return """
# RustCall's own mirror of a `#[repr(C)]` aggregate it generated (#245).
struct $c_result_struct_name <: FFIByValue
    is_ok::UInt8
    ok_value::$ok_slot_str
    err_value::Int32
end

function $func_name($arg_syms)
$(prologue)    $ptr_var, $channel_var = _call_target("$sym")
    $c_var = $(_emit_preserved(preserve_str, "call_rust_function($ptr_var, $c_result_struct_name, $converted_args_str)"))
    _guard_panic(nothing, $channel_var, "$func_name")
    if $c_var.is_ok == 1
        RustResult{$ok_type_str, String}(true, $ok_value)
    else
        RustResult{$ok_type_str, String}(false, RustCall.PYO3_OPAQUE_ERROR)
    end
end
export $func_name"""
end

function _emit_option_function_code(func::RustFunctionSignature, arg_syms::String, converted_args_str::String;
                                    prologue::String = "", preserve_str::String = "",
                                    strict::Symbol = FFI_STRICT[])
    func_name = func.name
    inner_surface, inner_slot =
        ffi_payload_symbols(func.inner_type, func.inner_abi, _ffi_context(func); strict = strict)
    inner_type_str = string(inner_surface)
    inner_slot_str = string(inner_slot)
    sym = func.symbol
    c_option_struct_name = "COption_$func_name"
    ptr_var = _generated_local("func_ptr", func.arg_names)
    c_var = _generated_local("c_option", func.arg_names)
    channel_var = _generated_local("panic_channel", func.arg_names)
    free_var = _generated_local("free_ptr", func.arg_names)
    free_str = _payload_free_symbol(func_name, (func.inner_abi,))
    target = isempty(free_str) ?
        "$ptr_var, $channel_var = _call_target(\"$sym\")" :
        "$ptr_var, $channel_var, $free_var = _call_target(\"$sym\", \"$free_str\")"
    free_expr = isempty(free_str) ? "C_NULL" : string(free_var)

    return """
struct $c_option_struct_name <: FFIByValue
    is_some::UInt8
    value::$inner_slot_str
end

function $func_name($arg_syms)
$(prologue)    $target
    $c_var = $(_emit_preserved(preserve_str, "call_rust_function($ptr_var, $c_option_struct_name, $converted_args_str)"))
    _guard_panic(nothing, $channel_var, "$func_name")
    if $c_var.is_some == 1
        RustOption{$inner_type_str}(true, _result_payload($inner_type_str, $c_var.value, $free_expr))
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
function _emit_struct_code(info::RustStructInfo; strict::Symbol = FFI_STRICT[])
    struct_name = info.name

    lines = String[]

    # Struct definition
    push!(lines, "mutable struct $struct_name")
    push!(lines, "    ptr::Ptr{Cvoid}")
    # Captured at construction: the destructor, and the flag that says whether
    # the library is still loaded. A finalizer must take no lock, resolve no
    # symbol and log nothing (#249).
    push!(lines, "    free_ptr::Ptr{Cvoid}")
    push!(lines, "    alive::Base.RefValue{Bool}")
    push!(lines, "")
    push!(lines, "    function $struct_name(ptr::Ptr{Cvoid}, free_ptr::Ptr{Cvoid}, alive::Base.RefValue{Bool})")
    push!(lines, "        obj = new(ptr, free_ptr, alive)")
    push!(lines, "        finalizer(RustCall.finalize_rust_object!, obj)")
    push!(lines, "        return obj")
    push!(lines, "    end")
    push!(lines, "")
    push!(lines, "    function $struct_name(ptr::Ptr{Cvoid})")
    push!(lines, "        free_ptr, alive = _struct_generation($(repr(ffi_struct_free_symbol(struct_name))))")
    push!(lines, "        return $struct_name(ptr, free_ptr, alive)")
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
        code = _emit_method_code(info, m; strict = strict)
        push!(lines, code)
        push!(lines, "")
    end

    # Property access. The same split as `_generate_property_accessors`: a
    # getter branch per readable field, a setter branch per writable one, and
    # a write-only `#[pyo3(set)]` field is a property with no read (#307 review).
    readable_fields = [(name, type) for (name, type) in info.fields if field_is_accessible(info, name)]
    writable_fields = [(name, type) for (name, type) in info.fields if field_is_writable(info, name)]
    property_fields = [(name, type) for (name, type) in info.fields
                       if field_is_accessible(info, name) || field_is_writable(info, name)]

    if !isempty(property_fields)
        # getproperty
        push!(lines, "function Base.getproperty(self::$struct_name, field::Symbol)")
        push!(lines, "    if field === :ptr")
        push!(lines, "        return getfield(self, :ptr)")
        push!(lines, "    end")
        push!(lines, "    _check_not_freed(self, \"$struct_name\")")
        for (field_name, field_type) in readable_fields
            getter_fn = info.field_getters[field_name]
            read = _crate_field_read_source(info, field_name, field_type, getter_fn,
                                            "getfield(self, :ptr)"; strict = strict)
            push!(lines, "    if field === :$field_name")
            push!(lines, "        return $read")
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
        for (field_name, field_type) in writable_fields
            setter_fn = info.field_setters[field_name]
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
        field_syms = join([":$name" for (name, _) in property_fields], ", ")
        push!(lines, "function Base.propertynames(self::$struct_name)")
        push!(lines, "    ($field_syms,)")
        push!(lines, "end")
    end

    return join(lines, "\n")
end

"""
    _quote_preserved(preserved, call) -> Expr

`GC.@preserve <objects> <call>`, or just `call` when `preserved` is empty.
The expression twin of `_emit_preserved`: `GC.@preserve` needs at least one
object, so an empty list must not produce the macro call at all.
"""
_quote_preserved(preserved, call) =
    isempty(preserved) ? call : Expr(:macrocall, Expr(:., :GC, QuoteNode(Symbol("@preserve"))),
                                     nothing, preserved..., call)

"""
    _emit_preserved(preserve_str, call) -> String

`GC.@preserve <objects>, <call>` as source text, or just `<call>` when there is
nothing to preserve.

`GC.@preserve` takes at least one object followed by the expression, so the
empty case has to omit the macro entirely rather than emit
`GC.@preserve(, call)`. The parenthesized form is used because the result is
nested inside `_guard_panic(...)`, and it needs the objects **comma**-separated
where the statement form separates them by spaces.
"""
function _emit_preserved(preserve_str::AbstractString, call::AbstractString)
    objects = filter(!isempty, split(strip(preserve_str)))
    isempty(objects) && return call
    return "GC.@preserve($(join(objects, ", ")), $call)"
end

"""
    _emit_method_code(struct_info::RustStructInfo, method::RustMethod) -> String

Generate Julia code for a method wrapper as a string.
"""
function _emit_method_code(struct_info::RustStructInfo, method::RustMethod;
                           strict::Symbol = FFI_STRICT[])
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
    c = ffi_return_contract(method.return_type; abi = method.return_abi, owner = helper_owner)

    all_args = String[]
    method.is_static || push!(all_args, "getfield(self, :ptr)")
    isempty(converted_args_str) || push!(all_args, converted_args_str)
    args_str = join(all_args, ", ")

    free_var = _generated_local("free_ptr", method.arg_names)
    channel_var = _generated_local("panic_channel", method.arg_names)
    target = "$ptr_var, $channel_var = _call_target(\"$wrapper_name\")"
    alive_var = _generated_local("alive", method.arg_names)
    if method.return_kind === :py_result
        return _emit_py_result_method_code(struct_info, method, arg_syms, converted_args_str,
                                           wrapper_name; prologue, preserve_str, strict)
    end
    method_label = "$(struct_name)::$(method_name)"
    # `Result` / `Option` returns are lowered like a free function's (#268):
    # the aggregate mirror is emitted above the wrapper and the channel is read
    # before either payload is decoded.
    if method.return_kind === :result || method.return_kind === :option
        plan = _method_payload_plan(struct_info, method, helper_owner; strict = strict)
        c_var = _generated_local("c_payload", method.arg_names)
        payload_target = isempty(plan.free_symbol) ?
            "$ptr_var, $channel_var = _call_target(\"$wrapper_name\")" :
            "$ptr_var, $channel_var, $free_var = _call_target(\"$wrapper_name\", \"$(plan.free_symbol)\")"
        free_expr = isempty(plan.free_symbol) ? "C_NULL" : string(free_var)
        payload_body = """
$(prologue)    $payload_target
    $c_var = $(_emit_preserved(preserve_str, "call_rust_function($ptr_var, $(plan.struct_name), $args_str)"))
    _guard_panic(nothing, $channel_var, "$method_label")
$(_emit_payload_decode(plan, c_var, free_expr))"""
        return _emit_method_definition(struct_name, method, arg_syms, payload_body;
                                       predef = plan.source)
    end
    call = if method.returns_boxed_struct
        target = "$ptr_var, $channel_var, $free_var, $alive_var = " *
                 "_ctor_target(\"$wrapper_name\", \"$(ffi_struct_free_symbol(struct_name))\")"
        "$struct_name(call_rust_function($ptr_var, Ptr{Cvoid}, $args_str), $free_var, $alive_var)"
    elseif ffi_owned_string_return(c)
        target = "$ptr_var, $channel_var, $free_var = _call_target(\"$wrapper_name\", \"$(c.free_symbol)\")"
        "_call_rust_owned_string_ptr($ptr_var, $free_var, $args_str)"
    elseif ffi_borrowed_string_return(c)
        "_call_rust_borrowed_string_ptr($ptr_var, $args_str)"
    else
        ret_type_str = string(ffi_return_symbol_or_throw(method.return_type, method.return_abi,
                                                         _ffi_context(method, struct_name);
                                                         strict = strict))
        "call_rust_function($ptr_var, $ret_type_str, $args_str)"
    end
    body = """
$(prologue)    $target
    _guard_panic($(_emit_preserved(preserve_str, call)), $channel_var, "$method_label")"""

    return _emit_method_definition(struct_name, method, arg_syms, body)
end

# The `function ... end` (and `export`) wrapper shared by every method-emitting
# branch, so a new return shape cannot forget the freed-object check or the
# receiver argument. `predef` is emitted above the definition.
function _emit_method_definition(struct_name::AbstractString, method::RustMethod,
                                 arg_syms::AbstractString, body::AbstractString;
                                 predef::AbstractString = "")
    method_name = method.name
    definition = if method.is_static && method.is_constructor
        """
function $struct_name($arg_syms)
$body
end"""
    elseif method.is_static
        """
function $method_name($arg_syms)
$body
end
export $method_name"""
    else
        self_args = isempty(arg_syms) ? "" : ", $arg_syms"
        """
function $method_name(self::$struct_name$self_args)
    _check_not_freed(self, "$struct_name")
$body
end
export $method_name"""
    end
    return isempty(predef) ? definition : predef * "\n\n" * definition
end

# The source-text counterpart of `_payload_decode_expr`.
function _emit_payload_decode(plan::MethodPayloadPlan, c_var, free_expr::AbstractString)
    if plan.kind === :result
        ok_t, err_t = plan.surface
        return """
    if $c_var.is_ok == 1
        RustResult{$ok_t, $err_t}(true, _result_payload($ok_t, $c_var.ok_value, $free_expr))
    else
        RustResult{$ok_t, $err_t}(false, _result_payload($err_t, $c_var.err_value, $free_expr))
    end"""
    end
    inner_t, _ = plan.surface
    return """
    if $c_var.is_some == 1
        RustOption{$inner_t}(true, _result_payload($inner_t, $c_var.value, $free_expr))
    else
        RustOption{$inner_t}(false, nothing)
    end"""
end

"""
    _emit_py_result_method_code(info, method, ...) -> String

Source-text counterpart of `_generate_py_result_method_wrapper` (#275 Phase 2).
"""
function _emit_py_result_method_code(info::RustStructInfo, method::RustMethod,
                                     arg_syms::String, converted_args_str::String,
                                     wrapper_name::String;
                                     prologue::AbstractString = "",
                                     preserve_str::AbstractString = "",
                                     strict::Symbol = FFI_STRICT[])
    struct_name = info.name
    method_name = method.name
    ok_type_str, ok_slot_str, is_unit =
        _py_result_types(method.ok_type, _ffi_context(method, struct_name); strict = strict)
    c_result_struct_name = "CResult_$(struct_name)_$(method_name)"
    ptr_var = _generated_local("func_ptr", method.arg_names)
    c_var = _generated_local("c_result", method.arg_names)
    channel_var = _generated_local("panic_channel", method.arg_names)

    all_args = String[]
    method.is_static || push!(all_args, "getfield(self, :ptr)")
    isempty(converted_args_str) || push!(all_args, converted_args_str)
    args_str = join(all_args, ", ")
    method_label = "$(struct_name)::$(method_name)"
    ok_value = is_unit ? "nothing" : "convert_return($ok_type_str, $c_var.ok_value)"

    body = """
$(prologue)    $ptr_var, $channel_var = _call_target("$wrapper_name")
    $c_var = $(_emit_preserved(preserve_str, "call_rust_function($ptr_var, $c_result_struct_name, $args_str)"))
    _guard_panic(nothing, $channel_var, "$method_label")
    if $c_var.is_ok == 1
        RustResult{$ok_type_str, String}(true, $ok_value)
    else
        RustResult{$ok_type_str, String}(false, RustCall.PYO3_OPAQUE_ERROR)
    end"""

    declaration = """
# RustCall's own mirror of a `#[repr(C)]` aggregate it generated (#245).
struct $c_result_struct_name <: FFIByValue
    is_ok::UInt8
    ok_value::$ok_slot_str
    err_value::Int32
end
"""

    if method.is_static
        return """$declaration
function $method_name($arg_syms)
$body
end
export $method_name"""
    end
    self_args = isempty(arg_syms) ? "" : ", $arg_syms"
    return """$declaration
function $method_name(self::$struct_name$self_args)
    _check_not_freed(self, "$struct_name")
$body
end
export $method_name"""
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
