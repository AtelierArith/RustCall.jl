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
    strict::Symbol = _ffi_strict(),
    features::Vector{String} = String[],
    default_features::Bool = true
)
    # ONE snapshot of the environment for the whole build, as in
    # `generate_bindings` (#481): nothing below reads `ENV`.
    snapshot = BuildEnvSnapshot()
    # Scan and build the crate
    @info "Scanning crate at $crate_path"
    info = scan_crate(crate_path; cargo_env = snapshot_env(snapshot))
    @info "Found $(length(info.julia_functions)) functions and $(length(info.julia_structs)) structs"

    # A PyO3-only crate is bound through a generated wrapper crate, exactly as
    # `@rust_crate` binds it (#275 Phase 2); `info` and the library name that
    # goes into the file come from the wrapper's own manifest.
    lib_name = nothing
    wrapper_lib_path = ""
    # The build's record, on every path: the wrapper's or the plain build's
    # (#485 review). The emitter is never left to take one of its own.
    record = nothing
    preload = String[]
    links_python = false
    if crate_needs_pyo3_wrapper(info)
        plan = pyo3_link_plan(crate_path; features = features,
                              default_features = default_features, release = build_release,
                              snapshot = snapshot)
        # As in `generate_bindings`: the record of the plan the key came from.
        wrapper_record = pyo3_wrapper_build_record(crate_path, plan, snapshot;
                                                   release = build_release, features = features,
                                                   default_features = default_features)
        wrapper = build_pyo3_wrapper(info; features = features,
                                     default_features = default_features,
                                     release = build_release, plan = plan, snapshot = snapshot)
        # `nothing` when this build exposes nothing to PyO3; the plain path
        # then binds the crate under the configuration it builds, like any
        # other crate (`_plain_scan_info` below, #307 review).
        if wrapper !== nothing
            info = wrapper.info
            lib_name = wrapper.lib_name
            wrapper_lib_path = wrapper.lib_path
            preload = wrapper.plan.runtime_libraries
            links_python = wrapper.plan.mode === :link_libpython
            record = wrapper_record
        end
    end
    # The plain path scans under the configuration it builds, probed with the
    # shape of that build (#307 review), as `generate_bindings` does.
    # One snapshot of the environment for the probe, the build and the file's
    # record (#474 review), as in `generate_bindings`.
    build_env = nothing
    if isempty(wrapper_lib_path)
        record = crate_build_record(crate_path, "";
            build_options = crate_build_options(release = build_release, features = features,
                default_features = default_features,
                kind = crate_has_cdylib(crate_path) ? :direct : :wrapper),
            snapshot = snapshot)
        build_env = _record_build_subprocess_env(record, snapshot)
        info = _plain_scan_info(crate_path, info, features, default_features, build_release;
                                env = build_env)
    end

    # Build the crate. On the plain path the feature set travels with the
    # build and with the registry name, as it does for a wrapper build.
    lib_name === nothing &&
        (lib_name = crate_library_name(info; release = build_release,
                                       features = features, default_features = default_features,
                                       snapshot = snapshot))
    build_kind = !isempty(wrapper_lib_path) ? :pyo3_wrapper :
                 crate_has_cdylib(crate_path) ? :direct : :wrapper
    lib_path = if !isempty(wrapper_lib_path)
        wrapper_lib_path
    elseif crate_has_cdylib(crate_path)
        @info "Building crate directly (already has cdylib crate-type)..."
        built = build_crate_directly(info, build_release;
                                     features = features, default_features = default_features,
                                     env = build_env)
        _verify_build_interpreter(record, snapshot)
        built
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
            built = build_cargo_project(wrapper_project, release=build_release,
                                        policy=crate_wrapper_policy(), env=build_env)
            _verify_build_interpreter(record, snapshot)
            # The library must leave the wrapper project before the `finally`
            # deletes it, as in `generate_bindings`: the file's `_LIB_PATH`
            # would otherwise name a file that no longer exists (#461). With a
            # relative destination it goes straight there — that copy is the
            # one the file names, and a durable staging copy beside it would
            # be left behind on every regeneration (#461 review). Otherwise it
            # gets a durable home of its own (`_uncached_library_home`).
            relative_lib_path === nothing ? _uncached_library_home(built) :
                _copy_to_relative_lib(built, output_path, relative_lib_path)
        finally
            cleanup_cargo_project(wrapper_project)
        end
    end

    # Determine the library path to use in the generated code
    if relative_lib_path !== nothing
        # Copy the library to the relative path (a wrapper build already put
        # it there).
        lib_dest_path = _copy_to_relative_lib(lib_path, output_path, relative_lib_path)
        # Use @__DIR__ based path in generated code
        lib_path_for_code = joinpath(relative_lib_path, basename(lib_dest_path))
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
        pin_library = any(_python_owned_handle, info.julia_structs),
        python = links_python,
        build_options = crate_build_options(release = build_release, features = features,
                                            default_features = default_features,
                                            kind = build_kind),
        build_record = _record_named(record, lib_name),
        snapshot = snapshot,
    )

    # Write to file
    mkpath(dirname(output_path))
    write(output_path, code)

    @info "Generated bindings written to $output_path"
    return output_path
end

# `lib_path` copied to `relative_lib_path` resolved against the directory of
# `output_path`, and that copy's path; a no-op when it is already there.
function _copy_to_relative_lib(lib_path::AbstractString, output_path::AbstractString,
                               relative_lib_path::AbstractString)
    lib_dest_dir = normpath(joinpath(dirname(output_path), relative_lib_path))
    mkpath(lib_dest_dir)
    lib_dest_path = joinpath(lib_dest_dir, basename(lib_path))
    if abspath(lib_dest_path) != abspath(lib_path)
        cp(lib_path, lib_dest_path, force = true)
        @info "Copied library to $lib_dest_path"
    end
    return String(lib_dest_path)
end
