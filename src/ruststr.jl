# rust"" string literal implementation

"""
Registry for compiled Rust libraries.
Maps library name to (library handle, functions dict).
"""
const RUST_LIBRARIES = Dict{String, Tuple{Ptr{Cvoid}, Dict{String, Ptr{Cvoid}}}}()

"""
Registry for loaded RustModules (LLVM IR).
Maps code hash to RustModule.
"""
const RUST_MODULE_REGISTRY = Dict{UInt64, RustModule}()

"""
Current active library name.
"""
const CURRENT_LIB = Ref{String}("")

"""
Active library for each module during macro expansion.
"""
const MODULE_ACTIVE_LIB = Dict{Module, String}()

"""
    get_current_library() -> String

Get the name of the currently active Rust library.
"""
function get_current_library()
    lock(REGISTRY_LOCK) do
        if isempty(CURRENT_LIB[])
            error("No Rust library loaded. Use rust\"\"\"...\"\"\" to compile and load Rust code first.")
        end
        return CURRENT_LIB[]
    end
end

"""
    get_library_handle(name::String) -> Ptr{Cvoid}

Get the library handle for a named library.
"""
function get_library_handle(name::String)
    lock(REGISTRY_LOCK) do
        if !haskey(RUST_LIBRARIES, name)
            error("Library '$name' not found. Available: $(keys(RUST_LIBRARIES))")
        end
        return RUST_LIBRARIES[name][1]
    end
end

"""
    get_function_pointer(lib_name::String, func_name::String) -> Ptr{Cvoid}

Get a function pointer from a loaded library.

If the function is not found in the specified library, searches all other
loaded libraries as a fallback. This enables using functions from multiple
`rust\"\"\"` blocks.
"""
function get_function_pointer(lib_name::String, func_name::String)
    lock(REGISTRY_LOCK) do
        # `#[julia]` is additive (#279): a Rust item named `add` may be exported
        # as `rustcall_add`. The name-to-symbol mapping is per library, so it is
        # resolved separately for every library searched below — one library's
        # `#[julia] fn f` must never redirect the lookup of another library's
        # plain `#[no_mangle] fn f`. A library with no entry for the name looks
        # it up as given.

        # First, try the specified library
        if haskey(RUST_LIBRARIES, lib_name)
            symbol = exported_symbol(lib_name, func_name)
            lib_handle, func_cache = RUST_LIBRARIES[lib_name]

            # Check cache first
            if haskey(func_cache, symbol)
                return func_cache[symbol]
            end

            # Look up the function
            func_ptr = Libdl.dlsym(lib_handle, symbol; throw_error=false)
            if func_ptr !== nothing && func_ptr != C_NULL
                # Cache it
                func_cache[symbol] = func_ptr
                return func_ptr
            end
        end

        # Fallback: search all other loaded libraries
        found_libs = String[]
        found_ptr = C_NULL

        for (other_lib_name, (other_lib_handle, other_func_cache)) in RUST_LIBRARIES
            if other_lib_name == lib_name
                continue  # Already checked
            end
            symbol = exported_symbol(other_lib_name, func_name)

            # Check cache first
            if haskey(other_func_cache, symbol)
                push!(found_libs, other_lib_name)
                found_ptr = other_func_cache[symbol]
                continue
            end

            # Look up the function
            func_ptr = Libdl.dlsym(other_lib_handle, symbol; throw_error=false)
            if func_ptr !== nothing && func_ptr != C_NULL
                # Cache it
                other_func_cache[symbol] = func_ptr
                push!(found_libs, other_lib_name)
                found_ptr = func_ptr
            end
        end

        if length(found_libs) == 1
            # Found in exactly one other library - use it
            @debug "Function '$func_name' found in library '$(found_libs[1])' (fallback search)"
            return found_ptr
        elseif length(found_libs) > 1
            # Ambiguous - found in multiple libraries
            error("Function '$func_name' found in multiple libraries: $(join(found_libs, ", ")). Please use a unique function name.")
        else
            # Not found anywhere
            if haskey(RUST_LIBRARIES, lib_name)
                error("Function '$func_name' not found in library '$lib_name' or any other loaded library")
            else
                error("Library '$lib_name' not found and function '$func_name' not found in any loaded library")
            end
        end
    end
end

"""
    @rust_str(code)

Compile Rust code and load it as a shared library.

# Example
```julia
rust\"\"\"
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}
\"\"\"
```
"""
macro rust_str(code)
    # The extractor expands #[julia] items and reports every signature in a
    # manifest. Julia definitions are emitted from that manifest at macro
    # expansion time; the expanded Rust source is compiled at run time.
    # Blocks with dependencies are built by Cargo, whose cfg set (features,
    # profile) is not known here: decide only target predicates for them.
    code_str = String(code)
    cfg_mode = has_dependencies(code_str) ? :cargo : :strict
    # One configuration for both phases: the Julia wrappers emitted here and
    # the run-time expansion *and compilation* must agree on which items exist,
    # so the cfg snapshot and the compiler settings it was derived from travel
    # into the generated code.
    cfg_text = _cfg_snapshot(cfg_mode)
    snapshot_compiler = get_default_compiler()
    # Cargo-backed blocks also record the Cargo/RUSTFLAGS environment that
    # produced `cfg_text`, so a reload can rebuild under it. An empty snapshot
    # is a real snapshot ("nothing was set"); `nothing` marks direct rustc
    # blocks, which have no Cargo environment.
    cargo_env = cfg_mode === :cargo ? _cargo_cfg_env_key() : nothing
    expanded = expand_inline(code_str; cfg = cfg_mode, cfg_text = cfg_text)
    struct_infos = manifest_struct_infos(expanded.manifest)
    julia_defs = [emit_julia_definitions(info) for info in struct_infos]

    julia_func_signatures = manifest_function_signatures(expanded.manifest)
    julia_func_wrappers = emit_julia_function_wrappers(julia_func_signatures)

    return quote
        lib_name = _compile_and_load_rust($(esc(code)), $(string(__source__.file)), $(__source__.line);
                                          cfg_text = $cfg_text,
                                          compiler_target = $(snapshot_compiler.target_triple),
                                          compiler_level = $(snapshot_compiler.optimization_level),
                                          cargo_env = $cargo_env)

        # Store the block (source plus the cfg/compiler snapshot it was expanded
        # under) in the calling module for precompilation support: a reload in a
        # later session rebuilds the very same configuration, see `ensure_loaded`.
        if !isdefined($__module__, :__RUSTCALL_LIBS)
            # Use Core.eval to define the constant if it doesn't exist
            # Note: We use a Dict to support multiple blocks
            @eval $__module__ const __RUSTCALL_LIBS = Dict{String, Any}()
        end
        $__module__.__RUSTCALL_LIBS[lib_name] = RustCall.RustBlockSnapshot(
            $(esc(code)), $cfg_text,
            $(snapshot_compiler.target_triple), $(snapshot_compiler.optimization_level),
            $cargo_env)

        # Track the "current" library for this module
        # Use Ref{String} so the binding is const but the value can be mutated
        # This avoids Pluto's "cannot assign to imported variable" error
        if !isdefined($__module__, :__RUSTCALL_ACTIVE_LIB)
            @eval $__module__ const __RUSTCALL_ACTIVE_LIB = Ref("")
        end
        $__module__.__RUSTCALL_ACTIVE_LIB[] = lib_name

        # Track active library for macro expansion in this session
        lock(REGISTRY_LOCK) do
            MODULE_ACTIVE_LIB[$__module__] = lib_name
        end

        $(julia_defs...)
        $(julia_func_wrappers)
        lib_name
    end
end

"""
    RustBlockSnapshot

What a `rust\"\"\"` block records in the calling module's `__RUSTCALL_LIBS`:
the source and the cfg / compiler configuration it was expanded under, so a
reload after precompilation (`ensure_loaded`) rebuilds exactly the library the
emitted Julia wrappers were generated for.
"""
struct RustBlockSnapshot
    code::String
    cfg_text::String
    compiler_target::String
    compiler_level::Int
    # `_cargo_cfg_env_key()` for Cargo-backed blocks — possibly "" when no
    # tracked variable was set, which is still a snapshot to restore — and
    # `nothing` for direct rustc blocks.
    cargo_env::Union{Nothing, String}
end

RustBlockSnapshot(code, cfg_text, compiler_target, compiler_level) =
    RustBlockSnapshot(code, cfg_text, compiler_target, compiler_level, nothing)

"""
    ensure_loaded(lib_name::String, block) -> String

Ensure that a Rust library is loaded in the current session; `block` is the
`RustBlockSnapshot` stored by the macro (a plain source string is
accepted for modules precompiled by older versions, and is rebuilt under the
current default compiler). Returns the name of the loaded library. Useful for
precompiled modules that need to reload libraries at runtime.
"""
function ensure_loaded(lib_name::String, block::RustBlockSnapshot)
    needs_reload = lock(REGISTRY_LOCK) do
        !haskey(RUST_LIBRARIES, lib_name)
    end
    needs_reload || return lib_name
    return _compile_and_load_rust(block.code, "reload", 0;
                                  cfg_text = block.cfg_text,
                                  compiler_target = block.compiler_target,
                                  compiler_level = block.compiler_level,
                                  cargo_env = block.cargo_env)
end

function ensure_loaded(lib_name::String, code::String)
    needs_reload = lock(REGISTRY_LOCK) do
        !haskey(RUST_LIBRARIES, lib_name)
    end
    needs_reload || return lib_name
    return _compile_and_load_rust(code, "reload", 0)
end

"""
    _snapshot_compiler(target, level) -> RustCompiler

The default compiler with the target triple and optimization level captured
at macro-expansion time (the settings that decided the cfg snapshot); the
default compiler itself when no snapshot is given.
"""
function _snapshot_compiler(target, level)
    default = get_default_compiler()
    (target === nothing || level === nothing) && return default
    return RustCompiler(String(target), Int(level), default.emit_debug_info,
                        default.debug_mode, default.debug_dir)
end

"""
    _compile_and_load_rust(code::String, source_file::String, source_line::Int)

Internal function to compile Rust code and load the resulting shared library.
Uses caching to avoid recompilation when possible.

Phase 3: Automatically detects dependencies in the code and uses Cargo for building
when external crates are required.
"""
function _compile_and_load_rust(code::String, source_file::String, source_line::Int;
                                cfg_text::Union{Nothing, AbstractString} = nothing,
                                compiler_target::Union{Nothing, AbstractString} = nothing,
                                compiler_level::Union{Nothing, Integer} = nothing,
                                cargo_env::Union{Nothing, AbstractString} = nothing)
    # Phase 3: Check for dependencies in the code
    if has_dependencies(code)
        return _compile_and_load_rust_with_cargo(code, source_file, source_line; cfg_text, cargo_env)
    end

    # Expand #[julia] items (functions, structs, accessors, method wrappers)
    # ahead of rustc. The manifest describes exactly what was generated.
    # `cfg_text` is the snapshot captured by the macro (see `_cfg_snapshot`)
    # and `compiler` the settings it was derived from, so the library is built
    # with the configuration the Julia wrappers were emitted for even if
    # `set_default_compiler` ran in between.
    compiler = _snapshot_compiler(compiler_target, compiler_level)
    expanded = expand_inline(code; cfg = :strict, cfg_text = cfg_text)
    manifest = expanded.manifest

    # Wrap the code if needed
    wrapped_code = wrap_rust_code(expanded.source)

    # Generate cache key
    cache_key = generate_cache_key(wrapped_code, compiler)

    # The in-memory library identity covers the compiler snapshot as well as
    # the source: the same expanded source built at another opt-level, target
    # or cfg set is another library (see `_rustc_block_identity`), so a lookup
    # can never hand back a build made under a different configuration.
    # Use stable_content_hash() — never hash() for persistent identifiers
    code_hash = _rustc_block_identity(wrapped_code, compiler, cfg_text)[1:16]
    lib_name = "rust_$(code_hash)"

    # Check if already compiled and loaded in memory
    is_in_memory = lock(REGISTRY_LOCK) do
        haskey(RUST_LIBRARIES, lib_name)
    end
    # Ensure the symbol mappings, return types and generic functions are
    # registered (the registries are volatile). The handle is already
    # published, so only `CURRENT_LIB[]` moves here. `require_loaded` re-checks
    # inside the lock: an `unload_library` racing with the check above must
    # send us down the compile path, not leave metadata behind for a library
    # that is gone.
    if is_in_memory && _register_manifest(expanded, lib_name; compiler, require_loaded = true)
        return lib_name
    end

    # Check cache first
    cached_lib = get_cached_library(cache_key)
    if cached_lib !== nothing && is_cache_valid(cache_key, wrapped_code, compiler)
        # Load from cache
        lib_handle, _ = load_cached_library(cache_key)

        # Register the library. The handle and the manifest's lookup tables
        # are published together (#279 follow-up): a concurrent
        # `ensure_loaded` must never see the library before its symbols.
        _register_manifest(expanded, lib_name; compiler, handle = lib_handle)

        return lib_name
    end

    # Compile to shared library (cache miss)
    lib_path = compile_rust_to_shared_lib(wrapped_code; compiler=compiler)

    # Save to cache
    try
        # Extract function names for metadata (simplified - we'll get them from LLVM IR if available)
        functions = String[]  # Will be populated if LLVM IR is available

        metadata = CacheMetadata(
            cache_key,
            stable_content_hash(wrapped_code),
            "$(compiler.optimization_level)_$(compiler.emit_debug_info)",
            compiler.target_triple,
            now(),
            functions
        )

        save_cached_library(cache_key, lib_path, metadata)
    catch e
        @warn "Failed to save library to cache: $e"
    end

    # Load the library
    lib_handle = Libdl.dlopen(lib_path, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
    if lib_handle == C_NULL
        error("Failed to load compiled Rust library: $lib_path")
    end

    # Temporarily disabled LLVM IR loading for stability
    # (LLVM IR is used for type inference and @rust_llvm)

    # Register the library: the handle and the manifest's lookup tables are
    # published in one critical section (#279 follow-up).
    _register_manifest(expanded, lib_name; compiler, handle = lib_handle)

    return lib_name
end

"""
    _compile_and_load_rust_with_cargo(code::String, source_file::String, source_line::Int)

Internal function to compile Rust code that has external dependencies using Cargo.
Phase 3: Supports rustscript-style dependency specifications.

# Dependency Specification Formats
1. Document comment format:
   ```rust
   //! ```cargo
   //! [dependencies]
   //! ndarray = "0.15"
   //! ```
   ```

2. Single-line comment format:
   ```rust
   // cargo-deps: ndarray="0.15", serde="1.0"
   ```
"""
function _compile_and_load_rust_with_cargo(code::String, source_file::String, source_line::Int;
                                           cfg_text::Union{Nothing, AbstractString} = nothing,
                                           cargo_env::Union{Nothing, AbstractString} = nothing)
    # The Cargo/RUSTFLAGS environment the block was expanded under and the
    # text identifying it (see `_cargo_build_env_for`). An empty snapshot is
    # not "the current environment": it clears every tracked variable.
    build_env, build_env_key = _cargo_build_env_for(cargo_env)
    # Parse dependencies from the code
    dependencies = parse_dependencies_from_code(code)

    if isempty(dependencies)
        @warn "has_dependencies returned true but no dependencies were parsed. Falling back to regular compilation."
        # Clean the code anyway and compile normally
        clean_code = remove_dependency_comments(code)
        wrapped_code = wrap_rust_code(clean_code)
        # Fall back to the regular path by calling the base implementation logic
        # But since we already checked has_dependencies, let's just continue here
    end

    # Validate dependencies
    try
        validate_dependencies(dependencies)
    catch e
        if e isa DependencyResolutionError
            rethrow(e)
        end
        throw(DependencyResolutionError("unknown", "Dependency validation failed: $e"))
    end

    # Expand #[julia] items ahead of Cargo. The dependency comments are read
    # from the original source above; the expanded source no longer needs them.
    # RustCall generates this Cargo project (release profile), so target and
    # profile predicates are pruned; features and build-script cfgs are kept.
    expanded = expand_inline(code; cfg = :cargo, cfg_text = cfg_text)
    manifest = expanded.manifest
    augmented_code = expanded.source

    # The library identity covers the code to be compiled, the dependency set
    # and the toolchain/pipeline fingerprint. The dependency comments are gone
    # from the expanded source, so the dependency hash must be part of the
    # identity itself, or two blocks with identical items but different
    # `// cargo-deps:` would share one in-memory library.
    # Use stable_content_hash() — never hash() for persistent identifiers
    deps_hash = hash_dependencies(dependencies)
    # `build_env_key` is the environment the build actually runs under: the
    # snapshot recorded by the macro, or the current one.
    code_hash = _cargo_block_identity(augmented_code, deps_hash, build_env_key)

    # Project and library names
    project_name = "rustcall_$(code_hash[1:12])"
    lib_name = "rust_cargo_$(code_hash[1:16])"

    # Check if already compiled and loaded in memory
    is_in_memory = lock(REGISTRY_LOCK) do
        haskey(RUST_LIBRARIES, lib_name)
    end
    # As in the rustc path: the re-check happens inside `_register_manifest`'s
    # critical section, so a concurrent unload sends us down the build path
    # rather than leaving metadata for a library that is gone.
    if is_in_memory &&
       _register_manifest(expanded, lib_name; cargo_backed = true, require_loaded = true)
        @debug "Using cached Cargo library from memory" lib_name=lib_name
        return lib_name
    end

    cache_key_data = "$(code_hash)_$(deps_hash)_release_$(bytes2hex(sha256(build_env_key)))"
    cache_key = bytes2hex(sha256(cache_key_data))[1:32]

    cached_lib = get_cargo_cached_library(cache_key)
    if !isnothing(cached_lib) && isfile(cached_lib)
        # Load from cache
        lib_handle = Libdl.dlopen(cached_lib, Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW)
        if lib_handle != C_NULL
            _register_manifest(expanded, lib_name; cargo_backed = true, handle = lib_handle)
            @debug "Loaded Cargo library from cache" lib_name=lib_name cache_key=cache_key[1:8]

            return lib_name
        end
    end

    # Build necessary if not in cache or cache load failed
    @info "Building Rust code with external dependencies..." dependencies=length(dependencies) project=project_name

    project = create_cargo_project(project_name, dependencies)

    try
        # Ensure the code with wrappers is written to the project
        write_rust_code_to_project(project, augmented_code)

        lib_path = build_cargo_project_cached(project, code_hash, release=true, env=build_env)

        # Cache the built library (if it wasn't already in cache)
        try
            save_cargo_cached_library(cache_key, lib_path)
        catch e
            @debug "Failed to cache Cargo library: $e"
        end

        # Load the library
        lib_handle = Libdl.dlopen(lib_path, Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW)
        if lib_handle == C_NULL
            error("Failed to load compiled Cargo library: $lib_path")
        end

        # Register the library: handle and manifest lookup tables together
        # (#279 follow-up).
        _register_manifest(expanded, lib_name; cargo_backed = true, handle = lib_handle)

        @info "Successfully built Rust code with Cargo" lib_name=lib_name
    finally
        # Clean up temporary project (keep for debugging if debug mode is enabled)
        compiler = get_default_compiler()
        if !compiler.debug_mode
            try
                cleanup_cargo_project(project)
            catch e
                @debug "Failed to cleanup Cargo project: $e"
            end
        else
            @info "Debug mode: keeping Cargo project at $(project.path)"
        end
    end

    return lib_name
end


"""
    _block_identity(expanded_source, (name => value)...) -> String

Stable identity of an inline block: the expanded source, the named sections
describing the configuration it is built under, and the toolchain
fingerprint. Both the direct-rustc and the Cargo path derive their library
names from it ([`_rustc_block_identity`], [`_cargo_block_identity`]), so two
builds of the same source under different configurations are different
libraries and a registry lookup never aliases one to the other.
"""
function _block_identity(expanded_source::AbstractString, sections::Pair{String, String}...)
    io = IOBuffer()
    write(io, expanded_source)
    for (name, value) in sections
        write(io, "\n---", name, "---\n", value)
    end
    write(io, "\n---toolchain---\n", toolchain_fingerprint())
    # Use stable_content_hash() — never hash() for persistent identifiers
    return stable_content_hash(String(take!(io)))
end

"""
    _cargo_block_identity(expanded_source, deps_hash, cargo_env = "") -> String

Identity of a Cargo-backed block: expanded source, dependency hash and the
Cargo/RUSTFLAGS environment the build runs under (`cargo_env`, see
`_cargo_cfg_env_key`). Used for the in-memory library name, the temporary
project name and the disk cache key.
"""
function _cargo_block_identity(expanded_source::AbstractString, deps_hash::AbstractString,
                              cargo_env::AbstractString = "")
    return _block_identity(expanded_source, "deps" => String(deps_hash),
                           "cargo-env" => String(cargo_env))
end

# Environment that changes what a direct `rustc` invocation produces: rustc
# itself ignores `RUSTFLAGS`, but rustup's proxy honours `RUSTUP_TOOLCHAIN`,
# and RUSTFLAGS is tracked so a user who sets it sees the same rebuild
# behaviour as with Cargo-backed blocks. Same allowlist discipline as
# `_is_cargo_env_key`: named variables only, never credentials.
const _RUSTC_ENV_NAMES = ("RUSTFLAGS", "RUSTUP_TOOLCHAIN")

_rustc_env_key() = join(("$k=$(ENV[k])" for k in _RUSTC_ENV_NAMES if haskey(ENV, k)), "\n")

"""
    _rustc_block_identity(wrapped_source, compiler, cfg_text) -> String

Identity of a block built by `rustc` directly: wrapped source, the compiler
snapshot it was expanded for (target, opt-level, debug info), the cfg text
the wrappers were derived from and the rustc environment
([`_rustc_env_key`]). `cfg_text === nothing` means the current strict
snapshot, as in [`expand_inline`].
"""
function _rustc_block_identity(wrapped_source::AbstractString, compiler::RustCompiler,
                              cfg_text::Union{Nothing, AbstractString})
    text = cfg_text === nothing ? _cfg_snapshot(:strict) : String(cfg_text)
    return _block_identity(wrapped_source,
                           "compiler" => "$(compiler.target_triple)_$(compiler.optimization_level)_$(compiler.emit_debug_info)",
                           "cfg" => bytes2hex(sha256(text)),
                           "rustc-env" => _rustc_env_key())
end

"""
    _register_manifest(expanded::ExpandedInline, lib_name::String; handle = nothing)

Register everything the manifest of a compiled block tells us:

- the name-to-symbol mapping and the return type of every exported function,
  so `@rust f(...)` resolves `rustcall_f` (#279) and works without `::T`;
- generic free functions and generic struct wrappers, for on-demand
  monomorphization. The registered code is the whole expanded block and the
  function is addressed by its qualified name, so `specialize` instantiates it
  in place with sibling items, imports and `super::` paths intact.

Pass `handle` to publish a freshly loaded library at the same time. The handle
and the manifest-derived lookup tables then become visible in **one**
`REGISTRY_LOCK` critical section, which is what makes a concurrent
`ensure_loaded` / `@rust f(...)` safe: a task that sees the library in
`RUST_LIBRARIES` also sees that `f` is exported as `rustcall_f`, instead of
resolving `f` to itself and failing (or, worse, hitting another library's `f`).
Callers must therefore not insert into `RUST_LIBRARIES` themselves.

Pass `require_loaded` instead when re-registering the volatile tables of a
library that is *already* loaded. The existence check then happens inside the
same critical section, so an `unload_library` or hot reload racing between a
caller's `haskey` and this call cannot leave metadata and `CURRENT_LIB[]`
pointing at a library that is no longer in `RUST_LIBRARIES`. Returns `false`
when the library turned out to be gone and nothing was registered; the caller
then falls through to compiling and loading it again.

The generic registrations stay outside the lock: `register_generic_function`
may shell out to the extractor to recover a signature, which must not run with
the global registry lock held.
"""
function _register_manifest(expanded, lib_name::String; compiler = nothing,
                            cargo_backed::Bool = false,
                            handle::Union{Ptr{Cvoid}, Nothing} = nothing,
                            set_current::Bool = true,
                            require_loaded::Bool = false)
    manifest = expanded.manifest
    signatures = manifest_function_signatures(manifest; only_attributed = false)

    registered = lock(REGISTRY_LOCK) do
        if require_loaded && !haskey(RUST_LIBRARIES, lib_name)
            return false
        end
        _register_exported_symbols!(signatures, lib_name)
        # Publishing the handle last is what closes the window: no reader can
        # find the library before its symbol mappings are in place.
        if handle !== nothing
            RUST_LIBRARIES[lib_name] = (handle, Dict{String, Ptr{Cvoid}}())
        end
        set_current && (CURRENT_LIB[] = lib_name)
        return true
    end
    registered || return false

    for info in manifest_struct_infos(manifest)
        register_generic_struct_wrappers(info, expanded.source; compiler)
    end
    for sig in signatures
        if sig.is_generic
            # Generic functions are compiled lazily; keep the compiler they were
            # expanded for so a later `set_default_compiler` cannot drop
            # #[cfg]-gated items from the specialization.
            #
            # A lazy specialization is a direct `rustc` build. For a Cargo-backed
            # block that is a different configuration (profile, `panic`,
            # RUSTFLAGS `--cfg`s) from the one the block was expanded and built
            # under. Item-level pruning has resolved the `#[cfg]`s on items and
            # signatures, but a `#[cfg]` statement or `cfg!` inside the body
            # would be decided anew by rustc: refuse such a generic rather than
            # build it under the wrong configuration.
            blocked = cargo_backed && sig.body_has_cfg ?
                "generic function `$(sig.name)` comes from a `// cargo-deps:` block and its body " *
                "contains `#[cfg]` or `cfg!`, which the lazy specialization (a direct rustc build) " *
                "would evaluate under a different configuration than the Cargo build; move the " *
                "configuration-dependent code out of the generic body or into a non-generic helper" : ""
            register_generic_function(sig.name, expanded.source, Symbol.(sig.type_params), sig.constraints, "";
                                      arg_types = sig.arg_types, return_type = sig.return_type,
                                      path = qualified_name(sig.module_path, sig.name), compiler, blocked)
            @debug "Registered generic function: $(sig.name)" type_params = sig.type_params
        end
    end
    return true
end

"""
    _register_exported_symbols!(signatures, lib_name)

Record the name-to-symbol mapping and the return type of every exported,
non-generic function of a manifest.

The caller must hold `REGISTRY_LOCK` and publish the library handle in the same
critical section, so that a task which finds the library in `RUST_LIBRARIES`
also finds how to resolve its names (#279). Everything the registries recorded
about the library is dropped first (`clear_library_metadata!`: both the symbol
mappings and the return-type hints), so a library re-registered under the same
name — a re-run block, a hot reload — keeps nothing about a function it no
longer defines or now declares differently.

Identity mappings are recorded too, so a plain `#[no_mangle] fn f` is
explicitly `f => f` for this library and cannot pick up another library's
`f => rustcall_f`.
"""
function _register_exported_symbols!(signatures, lib_name::String)
    clear_library_metadata!(lib_name)
    for sig in signatures
        sig.is_generic && continue
        sig.exported || continue
        register_function_symbol(lib_name, sig.name, sig.symbol)
        _register_return_type(sig, lib_name)
    end
    return nothing
end

"""
    _register_return_type(sig::RustFunctionSignature, lib_name::String)

Record the Julia return type of an exported function for `@rust` calls that
omit `::ReturnType`. Functions whose return type has no primitive Julia
counterpart are skipped and must be called with an explicit return type.
"""
function _register_return_type(sig, lib_name::String)
    if haskey(FUNCTION_REGISTRY, sig.symbol) || is_generic_function(sig.symbol)
        return nothing
    end
    ret_type = if sig.return_kind == :unit
        Cvoid
    elseif sig.return_kind == :plain
        _rust_primitive_to_julia_type(sig.return_type)
    else
        # Result/Option wrappers return `CResult_<fn>`/`COption_<fn>` structs; the
        # generated Julia wrapper handles them, `@rust` callers must be explicit.
        nothing
    end
    ret_type === nothing && return nothing
    # Recorded under both the Rust name and the exported symbol: `@rust f(...)`
    # names the function, while a caller that already resolved the symbol (or a
    # generated wrapper) asks for `rustcall_f`. Both keys are library-scoped —
    # a name-only hint would outlive this library (#279).
    for key in unique((sig.name, sig.symbol))
        FUNCTION_RETURN_TYPES_BY_LIB[(lib_name, key)] = ret_type
    end
    @debug "Registered return type for function: $(sig.name) (symbol $(sig.symbol)) => $ret_type (library: $lib_name)"
    return nothing
end

const _RUST_PRIMITIVE_TO_JULIA = Dict{String, Type}(
    "i8" => Int8, "i16" => Int16, "i32" => Int32, "i64" => Int64,
    "u8" => UInt8, "u16" => UInt16, "u32" => UInt32, "u64" => UInt64,
    "f32" => Float32, "f64" => Float64,
    "bool" => Bool,
    "usize" => Csize_t, "isize" => Cssize_t,
    "()" => Cvoid,
)

"""
    _rust_primitive_to_julia_type(rust_type::AbstractString) -> Union{Type, Nothing}

Julia type of a primitive Rust type name recorded in the manifest, or `nothing`.
"""
_rust_primitive_to_julia_type(rust_type::AbstractString) = get(_RUST_PRIMITIVE_TO_JULIA, strip(rust_type), nothing)

"""
    get_rust_module(code::String) -> Union{RustModule, Nothing}

Get the RustModule for a given code string, if available.
"""
function get_rust_module(code::String)
    code_hash = hash(wrap_rust_code(code))
    return get(RUST_MODULE_REGISTRY, code_hash, nothing)
end

"""
    list_loaded_libraries() -> Vector{String}

List all currently loaded Rust libraries.
"""
function list_loaded_libraries()
    return lock(REGISTRY_LOCK) do
        collect(keys(RUST_LIBRARIES))
    end
end

"""
    list_library_functions(lib_name::String) -> Vector{String}

List all exported functions in a loaded library.
Note: This uses the LLVM IR module if available, otherwise returns an empty list.
"""
function list_library_functions(lib_name::String)
    # Try to find the corresponding RustModule
    for (hash, mod) in RUST_MODULE_REGISTRY
        # Check if this module corresponds to the library
        mod_lib_name = "rust_$(string(hash, base=16))"
        if mod_lib_name == lib_name
            return list_functions(mod)
        end
    end

    return String[]
end

"""
    unload_library(lib_name::String)

Unload a Rust library and free its resources.
"""
function unload_library(lib_name::String)
    local lib_handle
    found = lock(REGISTRY_LOCK) do
        if !haskey(RUST_LIBRARIES, lib_name)
            return false
        end
        lib_handle, _ = RUST_LIBRARIES[lib_name]
        delete!(RUST_LIBRARIES, lib_name)
        # A stale name-to-symbol mapping would keep redirecting lookups to a
        # symbol that is no longer loaded (#279).
        clear_library_metadata!(lib_name)
        if CURRENT_LIB[] == lib_name
            CURRENT_LIB[] = ""
        end
        return true
    end
    if !found
        @warn "Library '$lib_name' not loaded"
        return
    end

    Libdl.dlclose(lib_handle)
end

"""
    unload_all_libraries()

Unload all loaded Rust libraries.
"""
function unload_all_libraries()
    libs = lock(REGISTRY_LOCK) do
        collect(keys(RUST_LIBRARIES))
    end
    for lib_name in libs
        unload_library(lib_name)
    end
end

# irust"" string literal implementation

"""
Registry for irust functions.
Maps function hash to (library name, function name).
"""
const IRUST_FUNCTIONS = Dict{UInt64, Tuple{String, String}}()

"""
    @irust(code, args...)
    @irust(code)

Execute Rust code at function scope.

This macro compiles Rust code into a temporary function and calls it.
Julia variables can be referenced using `\\\$var` syntax or passed as arguments.

# Features
- Automatic variable binding with `\\\$var` syntax
- Improved type inference from code
- Better error messages

# Examples
```julia
# Using \\\$var syntax (recommended)
function myfunc(x)
    @irust("\\\$x * 2")
end

# Using explicit arguments (legacy, still supported)
function myfunc(x)
    @irust("arg1 * 2", x)
end

# Multiple variables
function add_and_multiply(a, b, c)
    @irust("\\\$a + \\\$b * \\\$c")
end
```

For more complex cases, use `rust\"\"\"` to define functions explicitly.
"""
macro irust(code, args...)
    # Handle different input types
    if isa(code, AbstractString)
        # String literal: parse $var syntax
        code_str = code
        vars_from_code, processed_code = _parse_irust_variables(code_str)

        # Combine variables from $var syntax and explicit arguments
        # Note: args is a tuple from varargs, so we need to collect it
        all_vars = vcat(vars_from_code, collect(args))

        # Build the call expression
        if isempty(all_vars)
            return quote
                _compile_and_call_irust($processed_code)
            end
        else
            # Create escaped variable expressions
            # Each variable needs to be escaped to be evaluated in the calling scope
            var_exprs = [esc(var) for var in all_vars]

            # Build the call expression with proper argument splatting
            # We need to call RustCall._compile_and_call_irust with the escaped variables
            return Expr(:call, GlobalRef(RustCall, :_compile_and_call_irust), processed_code, var_exprs...)
        end
    else
        # Non-string: treat as expression (for future expansion)
        error("@irust expects a string literal as the first argument. Got: $(typeof(code))")
    end
end

"""
    @irust_str(code)

String literal form of @irust. Use @irust("code", args...) for better syntax.

# Example
```julia
@irust_str("arg1 * 2")  # Note: arguments must be passed separately
```
"""
macro irust_str(code)
    code_str = isa(code, AbstractString) ? code : string(code)
    return quote
        _compile_and_call_irust($code_str)
    end
end

"""
    _parse_irust_variables(code::String) -> (Vector{Symbol}, String)

Parse `\\\$var` syntax in irust code and extract variable names.
Returns (list of variable symbols, processed code with `\\\$var` replaced by argN).

# Example
```julia
vars, code = _parse_irust_variables("\\\$x + \\\$y * 2")
# vars = [:x, :y]
# code = "arg1 + arg2 * 2"
```
"""
function _parse_irust_variables(code::String)
    # Pattern to match $variable (but not $$ which is escaped)
    # Match $ followed by identifier (letter, underscore, or digit after first char)
    pattern = r"\$([a-zA-Z_][a-zA-Z0-9_]*)"

    # Find all matches (in order of appearance)
    matches = collect(eachmatch(pattern, code))

    # Build ordered list of unique variables (in order of first appearance)
    vars = Symbol[]
    var_to_idx = Dict{Symbol, Int}()
    for m in matches
        var_name = Symbol(m.captures[1])
        if !haskey(var_to_idx, var_name)
            push!(vars, var_name)
            var_to_idx[var_name] = length(vars)
        end
    end

    # Process from end to start to preserve positions
    processed = code
    for m in reverse(matches)
        var_name = Symbol(m.captures[1])
        var_idx = var_to_idx[var_name]

        # Replace $var with argN
        arg_ref = "arg$(var_idx)"
        processed = processed[1:prevind(processed, m.offset)] * arg_ref * processed[nextind(processed, m.offset + length(m.match) - 1):end]
    end

    return (vars, processed)
end

"""
    _compile_and_call_irust(code::String, args...)

Internal function to compile and execute Rust code at function scope.

# Error Handling
This function provides improved error messages for:
- Type mismatches
- Compilation failures
- Missing variables
"""
function _compile_and_call_irust(code::String, args...)
    try
        # Generate a unique function name based on code and argument types
        arg_types = collect(map(typeof, args))  # Vector{Type}
        code_hash = hash((code, Tuple(arg_types)))  # Use Tuple for hash consistency
        func_name = "irust_func_$(string(code_hash, base=16))"

        # Infer Rust types from Julia types (needed for both cached and new functions)
        rust_arg_types = collect(map(_julia_to_rust_type, arg_types))

        # Check if already compiled (protect IRUST_FUNCTIONS with REGISTRY_LOCK)
        cached = lock(REGISTRY_LOCK) do
            if haskey(IRUST_FUNCTIONS, code_hash)
                lib_name, cached_func_name = IRUST_FUNCTIONS[code_hash]
                if haskey(RUST_LIBRARIES, lib_name)
                    return (lib_name, cached_func_name, true)
                else
                    # Stale cache entry: library was unloaded, so recompile transparently.
                    delete!(IRUST_FUNCTIONS, code_hash)
                    return nothing
                end
            end
            return nothing
        end
        if cached !== nothing
            lib_name, cached_func_name, _ = cached
            # Re-infer return type for cached function (should match original)
            rust_ret_type = _infer_return_type_improved(code, arg_types, rust_arg_types)
            julia_ret_type = _rust_to_julia_type(rust_ret_type)
            return _call_irust_function(lib_name, cached_func_name, julia_ret_type, args...)
        end

        # Infer return type from code (improved)
        rust_ret_type = _infer_return_type_improved(code, arg_types, rust_arg_types)

        # Generate Rust function code
        rust_func_code = _generate_irust_function(func_name, code, rust_arg_types, rust_ret_type)

        # Compile and load
        wrapped_code = wrap_rust_code(rust_func_code)
        compiler = get_default_compiler()

        local lib_path
        try
            lib_path = compile_rust_to_shared_lib(wrapped_code; compiler=compiler)
        catch e
            error("""
            Failed to compile Rust code for @irust.

            Code: $code
            Generated Rust function:
            $rust_func_code

            Original error: $e

            Tip: Check that your Rust code is valid and uses arg1, arg2, etc. correctly.
            """)
        end

        # Load the library
        lib_handle = Libdl.dlopen(lib_path, Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW)
        if lib_handle == C_NULL
            error("""
            Failed to load compiled Rust library for @irust.

            Library path: $lib_path
            Code: $code

            This may indicate a linking issue or missing dependencies.
            """)
        end

        # Generate a unique library name and register under lock
        lib_name = "irust_$(string(code_hash, base=16))"
        lock(REGISTRY_LOCK) do
            RUST_LIBRARIES[lib_name] = (lib_handle, Dict{String, Ptr{Cvoid}}())
            IRUST_FUNCTIONS[code_hash] = (lib_name, func_name)
        end

        # Convert Rust return type to Julia type
        julia_ret_type = _rust_to_julia_type(rust_ret_type)

        # Call the function with correct return type
        return _call_irust_function(lib_name, func_name, julia_ret_type, args...)
    catch e
        # Improve error messages
        if isa(e, MethodError)
            error("""
            Type error in @irust call.

            Code: $code
            Arguments: $(map(x -> "$(typeof(x))", args))

            Original error: $e

            Tip: Ensure argument types match what the Rust code expects.
            """)
        else
            rethrow(e)
        end
    end
end

"""
    _julia_to_rust_type(julia_type::Type) -> String

Convert Julia type to Rust type string.

# Supported Types
- Integer types: Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64
- Floating point: Float32, Float64
- Boolean: Bool

# Error Handling
Unsupported types throw an error to prevent ABI mismatches.
"""
function _julia_to_rust_type(julia_type::Type)
    type_map = Dict(
        Int8 => "i8",
        Int16 => "i16",
        Int32 => "i32",
        Int64 => "i64",
        UInt8 => "u8",
        UInt16 => "u16",
        UInt32 => "u32",
        UInt64 => "u64",
        Float32 => "f32",
        Float64 => "f64",
        Bool => "bool",
    )

    if haskey(type_map, julia_type)
        return type_map[julia_type]
    end
    error("Unsupported Julia type for @irust: $julia_type")
end

"""
    _rust_to_julia_type(rust_type::String) -> Type

Convert Rust type string to Julia type.
"""
function _rust_to_julia_type(rust_type::String)
    return rusttype_to_julia(Symbol(rust_type))
end

"""
    _infer_return_type_improved(code::String, arg_types::Vector{Type}, rust_arg_types::Vector{String}) -> String

Infer return type from Rust code with improved heuristics.

# Strategy
1. Look for explicit return statements with literals
2. Analyze arithmetic operations (int vs float)
3. Use argument types as hints
4. Fall back to first argument type if available
"""
function _infer_return_type_improved(code::String, arg_types::Vector{<:Type}, rust_arg_types::Vector{String})
    code_lower = lowercase(strip(code))

    # 1. Check for explicit return statements with literals
    if occursin(r"return\s+[0-9]+\s*;", code) || occursin(r"return\s+[0-9]+\s*$", code)
        # Integer literal - check if it's a float by looking for decimal point
        if occursin(r"return\s+[0-9]+\.[0-9]", code)
            return "f64"
        else
            return "i32"
        end
    end

    # 2. Check for boolean literals
    if occursin(r"return\s+(true|false)\s*;", code) || occursin(r"return\s+(true|false)\s*$", code)
        return "bool"
    end

    # 3. Analyze arithmetic operations
    # If code contains division or multiplication with floats, likely returns float
    if occursin(r"arg\d+\s*[*/]\s*[0-9]+\.[0-9]", code) ||
       occursin(r"[0-9]+\.[0-9]\s*[*/]\s*arg\d+", code) ||
       occursin(r"arg\d+\s*[*/]\s*arg\d+", code) && any(t -> t == Float32 || t == Float64, arg_types)
        return "f64"
    end

    # 4. Check if any argument is float
    if any(t -> t == Float32 || t == Float64, arg_types)
        return "f64"
    end

    # 5. Check if any argument is bool (and operation is boolean)
    if occursin(r"==|!=|<|>|<=|>=", code) || occursin(r"&&|\|\|", code)
        return "bool"
    end

    # 6. Use first argument type if available
    if !isempty(rust_arg_types)
        return rust_arg_types[1]
    end

    # 7. Default fallback
    return "i64"
end

"""
    _infer_return_type(code::String) -> String

Infer return type from Rust code (legacy function, kept for compatibility).
"""
function _infer_return_type(code::String)
    return _infer_return_type_improved(code, Type[], String[])
end

"""
    _generate_irust_function(func_name::String, code::String, arg_types::Vector{String}, ret_type::String) -> String

Generate a complete Rust function from the code snippet.
The code should use arg1, arg2, etc. to reference arguments.
"""
function _generate_irust_function(func_name::String, code::String, arg_types::Vector{String}, ret_type::String)
    # Build function parameters
    params = String[]
    for (i, arg_type) in enumerate(arg_types)
        push!(params, "arg$(i): $arg_type")
    end

    params_str = join(params, ", ")

    # Ensure the code returns a value
    final_code = strip(code)
    if !startswith(final_code, "return")
        # If no return statement, wrap in a return
        final_code = "return $final_code;"
    end

    # Generate the function
    rust_code = """
    #[no_mangle]
    pub extern "C" fn $func_name($params_str) -> $ret_type {
        $final_code
    }
    """

    return rust_code
end

"""
    _call_irust_function(lib_name::String, func_name::String, ret_type::Type, args...)
    _call_irust_function(lib_name::String, func_name::String, args...)

Call an irust function with Julia arguments.

# Error Handling
Provides improved error messages for function call failures.
"""
function _call_irust_function(lib_name::String, func_name::String, ret_type::Type, args...)
    try
        # Get function pointer
        func_ptr = get_function_pointer(lib_name, func_name)

        # Call using the codegen infrastructure with explicit return type
        result = call_rust_function(func_ptr, ret_type, args...)

        # Safety check: Convert integer to Bool if needed (should already be handled by codegen.jl)
        # Rust bool is represented as UInt8 in C ABI (0 = false, non-zero = true)
        if ret_type == Bool
            if isa(result, Integer)
                return Bool(result != 0)
            elseif isa(result, Bool)
                return result
            end
        end

        return result
    catch e
        if isa(e, ErrorException) && occursin("not found", e.msg)
            error("""
            Function '$func_name' not found in library '$lib_name'.

            This may indicate:
            1. The function was not properly compiled
            2. A name mangling issue
            3. The library was not loaded correctly

            Original error: $e
            """)
        else
            rethrow(e)
        end
    end
end
