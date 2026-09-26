# External crate bindings generator (Maturin-like feature)
# This module provides automatic Julia bindings generation for external Rust crates
# that use the #[julia] attribute from rustcall_julia_macros.
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
    _crate_manifest(crate_path; cfg = :lenient, cfg_text = nothing, build_env = nothing,
                    allow_cargo = true) -> (cargo_toml, source_files, manifest)

The extractor's crate-mode manifest of the crate at `crate_path`, read the way
`scan_crate` reads it: the crate's module tree from its library root, under the
crate's edition. Shared by `scan_crate` and `boundary_report` (#441).
"""
function _crate_manifest(crate_path::AbstractString; cfg = :lenient,
                         cfg_text::Union{Nothing, AbstractString} = nothing,
                         build_env::Union{Nothing, AbstractDict} = nothing,
                         allow_cargo::Bool = true,
                         cargo_env::Union{Nothing, AbstractDict} = nothing)
    crate_path = String(crate_path)
    cargo_toml_path = joinpath(crate_path, "Cargo.toml")
    # Parse Cargo.toml
    cargo_toml = parse_cargo_toml(cargo_toml_path)
    edition = _crate_rust_edition(crate_path, cargo_toml; allow_cargo = allow_cargo,
                                  env = something(cargo_env, ENV))
    # A build passes the environment it runs under (#481): the cfg the scan
    # decides with is probed under it, not under `ENV` read now.
    if cfg_text === nothing && cargo_env !== nothing && _cfg_mode(cfg) in (:lenient, :cargo)
        cfg_text = _cargo_cfg_text(cargo_env)
    end

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
    # Both scans need the crate's module tree, not a bag of files: `src/api.rs`
    # is `api`, a `mod api;` that is not `pub` puts everything below it out of
    # a wrapper crate's reach (#275), and a `#[julia] impl crate::Gauge` in
    # `ops.rs` has to find the `Gauge` declared in `lib.rs` (#315).
    lib_root, tree_files = _crate_scan_inputs(crate_path, cargo_toml, source_files)
    manifest = extract_manifest(tree_files; mode = "crate", skip_unparsable = true,
                                cfg = cfg, cfg_text = cfg_text,
                                crate_root = lib_root, edition = edition,
                                build_env = build_env)
    return cargo_toml, source_files, manifest
end

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
                    cfg_text::Union{Nothing, AbstractString} = nothing,
                    build_env::Union{Nothing, AbstractDict} = nothing,
                    allow_cargo::Bool = true,
                    cargo_env::Union{Nothing, AbstractDict} = nothing)
    # Validate path
    if !isdir(crate_path)
        error("Crate path does not exist: $crate_path")
    end

    cargo_toml_path = joinpath(crate_path, "Cargo.toml")
    if !isfile(cargo_toml_path)
        error("Cargo.toml not found in: $crate_path")
    end

    cargo_toml, source_files, manifest = _crate_manifest(crate_path; cfg = cfg, cfg_text = cfg_text,
                                                         build_env = build_env,
                                                         allow_cargo = allow_cargo,
                                                         cargo_env = cargo_env)
    all_functions = manifest_function_signatures(manifest)
    all_structs = manifest_struct_infos(manifest)
    # Items the crate marks only for PyO3 (#275 Phase 1). They are reported so
    # `@rust_crate` can say what it found and why an item is not wrappable;
    # generating the wrapper crate that exports them is Phase 2.
    pyo3_functions = manifest_function_signatures(manifest; origins = PYO3_ATTRIBUTE_ORIGINS)
    pyo3_structs = manifest_struct_infos(manifest; origins = PYO3_ATTRIBUTE_ORIGINS)

    # Extract dependencies from Cargo.toml
    dependencies = extract_crate_dependencies(cargo_toml)
    version = _package_field(crate_path, cargo_toml, "version", "0.1.0";
                             allow_cargo = allow_cargo, env = something(cargo_env, ENV))

    # `String(...)::String`: the manifest's values are `Any`, and a constructor
    # called on `Any` is compiled through `convert(String, ::Any)`, which any
    # later package adding a `convert(::Type{String}, ...)` method invalidates
    # — PythonCall's JSON does — so the precompiled scan was recompiled on the
    # first call after `using PythonCall` (#449).
    CrateInfo(
        String(cargo_toml["package"]["name"])::String,
        abspath(crate_path),
        String(version)::String,
        dependencies,
        all_functions,
        all_structs,
        source_files,
        pyo3_functions,
        pyo3_structs,
    )
end

function _crate_rust_edition(crate_path::AbstractString, cargo_toml::AbstractDict;
                             allow_cargo::Bool = true, env::AbstractDict = ENV)
    edition = _package_field(crate_path, cargo_toml, "edition", "2015";
                             allow_cargo = allow_cargo, env = env)
    return String(edition)
end

"""
    _package_field(crate_path, cargo_toml, key, fallback; allow_cargo = true, env = ENV)

The value of the `[package]` field `key` of `cargo_toml`, with `{ workspace =
true }` inheritance resolved from the workspace root's `[workspace.package]`
table **by reading that manifest**.

A member that inherits `edition` or `version` is a common layout, and reading
the root is what keeps the probe-free scan of #425 from running `cargo metadata`
for it. When the root cannot be found or does not declare the field, `fallback`
is what a caller that may not invoke Cargo gets; with `allow_cargo = true` Cargo
is asked instead, which remains the authority for the layouts a manifest read
cannot decide.
"""
function _package_field(crate_path::AbstractString, cargo_toml::AbstractDict,
                        key::AbstractString, fallback;
                        allow_cargo::Bool = true, env::AbstractDict = ENV)
    value = get(cargo_toml["package"], key, fallback)
    if value isa AbstractDict && get(value, "workspace", false) === true
        inherited = _workspace_inherited_package_field(crate_path, key)
        inherited === nothing || return inherited
        allow_cargo || return fallback
        # Under the caller's environment: a crate build passes its own (#481).
        metadata = _cargo_package_metadata(crate_path; env = env)
        manifest_path = realpath(joinpath(crate_path, "Cargo.toml"))
        package = only(p for p in metadata["packages"]
                       if realpath(p["manifest_path"]) == manifest_path)
        return package[key]
    end
    return value
end

# `[workspace.package].<key>` of the workspace `crate_path` belongs to, for a
# member that writes `key = { workspace = true }`. `nothing` when there is no
# workspace, no such key, or the manifest cannot be read: pure file reads, so
# the no-Cargo scan can use it.
function _workspace_inherited_package_field(crate_path::AbstractString, key::AbstractString)
    root = _workspace_root_dir(crate_path)
    root === nothing && return nothing
    manifest = joinpath(root, "Cargo.toml")
    isfile(manifest) || return nothing
    parsed = _parse_manifest_or_nothing(manifest)
    parsed isa AbstractDict || return nothing
    workspace = get(parsed, "workspace", nothing)
    workspace isa AbstractDict || return nothing
    package = get(workspace, "package", nothing)
    package isa AbstractDict || return nothing
    haskey(package, key) || return nothing
    return package[key]
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
    rustcall_runtime_crate_path() -> String

This installation's `deps/rustcall_julia_macros`, the crate every generated
wrapper names for its quiet-panic boundary guard (`PanicHook::Runtime`, #304).

Every `Cargo.toml` RustCall writes for a crate that contains generated wrappers
declares this dependency, and they all have to declare the **same** one: two
packages of this name from different sources would each bring a copy of
`#[no_mangle] __rustcall_install_panic_hook` into one `cdylib`, which is a
duplicate symbol at link time. A crate of the user's that also uses `#[julia]`
therefore has to point at this same directory — `docs/src/panics.md` says so.

Raises when the directory is missing rather than falling back to a registry
version. The generated source names `::rustcall_julia_macros` unconditionally,
so a manifest without this entry does not compile, and a `rustc` resolution
error naming a crate the user never wrote is a much worse way to learn that this
installation is incomplete.
"""
function rustcall_runtime_crate_path()
    path = joinpath(dirname(dirname(@__FILE__)), "deps", "rustcall_julia_macros")
    isdir(path) && return path
    throw(RustError("RustCall's runtime crate is missing: expected it at $(path). " *
                    "Every generated wrapper depends on it for the quiet panic hook " *
                    "(#304). Reinstall the package, or check out `deps/`."))
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
    # `rustcall_julia_macros` is load-bearing for this crate, not a leftover: the
    # wrappers below take their quiet-panic boundary guard from it
    # (`rustcall_julia_core::codegen::PanicHook::Runtime`), and its rlib is what
    # exports `__rustcall_install_panic_hook` from the `cdylib` for
    # `load_artifact!` to call. It is the same rlib the wrapped crate's own
    # `#[julia]` items use, so both share one hook and one depth counter — and
    # emitting the items here as well would define the symbol twice (#304).
    runtime = rustcall_runtime_crate_path()
    push!(lines, "rustcall_julia_macros = { path = \"$(escape_toml_string(runtime))\" }")
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

# `crate_rust_identifier` of the crate at `crate_path`, read from its own
# `Cargo.toml`; the package name with `-` mapped to `_` when there is none to
# read (a `CrateInfo` built by hand).
function _crate_rust_identifier_at(crate_path::AbstractString, package_name::AbstractString)
    manifest = joinpath(crate_path, "Cargo.toml")
    cargo_toml = isfile(manifest) ? parse_cargo_toml(manifest) : Dict{String, Any}()
    return crate_rust_identifier(package_name, cargo_toml)
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
    # The name Rust code refers to the crate by — `[lib] name`, with `-` mapped
    # to `_` — not its package name, which a hyphen or a `[lib] name` override
    # makes an unresolved or wrong crate (#461).
    push!(lines, "use $(_crate_rust_identifier_at(info.path, info.name))::*;")
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
