# rust"" string literal implementation

"""
Registry for compiled Rust libraries.
Maps library name to (library handle, functions dict).
"""
const RUST_LIBRARIES = _state_view(:rust_libraries,
    Dict{String, Tuple{Ptr{Cvoid}, Dict{String, Ptr{Cvoid}}}}())

"""
Current active library name.
"""
const CURRENT_LIB = _state_view(:current_lib, Ref{String}(""))

"""
Active library for each module during macro expansion.
"""
const MODULE_ACTIVE_LIB = _state_view(:module_active_lib, Dict{Module, String}())

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
    _resolve_call(lib_name::String, func_name::String) -> (Ptr{Cvoid}, String)

The function pointer for `func_name` **and the library it came from**.

`lib_name` is tried first; failing that, every other loaded library is searched
as a fallback, which is what lets one `rust\"\"\"` block call another's
functions. Each library resolves the name through its own symbol mapping
(`#[julia]` is additive, so `f` may be exported as `rustcall_f`, #279).

Candidates are deduplicated **by pointer**: one loaded handle may legitimately
sit in `RUST_LIBRARIES` under two names — `_alias_reloaded_library` registers a
reloaded library under the identity a precompiled module stored as well as the
one the reload derived — and finding the same function twice through the same
handle is not an ambiguity. Genuinely different functions of the same name in
different libraries still are, and are refused rather than guessed.

Returning the owning library is the point of this function: the caller needs
the pointer and the return-type hint to come from the *same* library, or a
`Result`-returning `f` in one library gets typed by a primitive-returning `f`
in another.
"""
function _resolve_call(lib_name::String, func_name::String)
    target = resolve_call_target(lib_name, func_name)
    return (target.func_ptr, target.lib_name)
end

"""
    resolve_call_target(lib_name, func_name; free_symbol = "") -> CallTarget

Everything one call needs — the function pointer, its panic channel, and
optionally the release function for an owned-`String` result — resolved from
**one generation** of one library, under **one** `REGISTRY_LOCK` critical
section.

This is the entry point every FFI call goes through, and the single lock is the
point of it. A library can be replaced between any two lookups (that is what a
hot reload is), so resolving the pointer and then the channel separately means
the call can enter the retired image and read the replacement's channel: a
panic raised by the call is invisible, and a panic the new image happens to
have left there is reported against a call that never made it. Same for the
release function of a `String` result, which used to be resolved by library
name *after* the wrapper had already returned.

`free_symbol`, when given, is resolved on the same handle — the
`<owner>_free_rust_string` of a function returning an owned `String`, or the
`<Struct>_free` of a constructor, whose result must capture *this* generation's
destructor. It is only ever the
`<owner>_free_rust_string` of the function being called, which by construction
lives in the same image as the buffer it releases — the allocator contract
(`docs/src/panics.md`).

Resolution starts at `lib_name` and falls back to the other loaded libraries,
which is what lets one `rust\"\"\"` block call another's functions. Candidates
are deduplicated **by pointer**: one handle may sit in `RUST_LIBRARIES` under
two names (`alias_artifact!`), and finding the same function twice through the
same handle is not an ambiguity. Genuinely different functions of the same name
in different libraries are refused rather than guessed.
"""
function resolve_call_target(lib_name::String, func_name::String;
                             free_symbol::AbstractString = "")
    lock(REGISTRY_LOCK) do
        # Resolve a symbol on one library's handle, memoizing into that
        # library's own pointer cache. Caller holds the lock.
        resolve_in(handle, cache, symbol) = begin
            cached = get(cache, symbol, C_NULL)
            cached == C_NULL || return cached
            found = Libdl.dlsym(handle, symbol; throw_error = false)
            (found === nothing || found == C_NULL) && return C_NULL
            cache[symbol] = found
            found
        end
        # The whole target, from one library, in one place: this is what makes
        # the pieces belong to the same generation.
        target_in(owner, handle, cache, func_ptr) = begin
            symbol = exported_symbol(owner, func_name)
            channel = get(PANIC_CHANNELS, (owner, symbol), nothing)
            if channel === nothing
                channel = resolve_in(handle, cache, ffi_panic_symbol(symbol))
                PANIC_CHANNELS[(owner, symbol)] = channel
            end
            free_ptr = isempty(free_symbol) ? C_NULL :
                       resolve_in(handle, cache, String(free_symbol))
            # The return metadata belongs to the snapshot as much as the
            # pointers do: it decides how the `ccall` reads the return slot,
            # and reading a retired generation's result with the replacement's
            # ABI is memory corruption, not a wrong answer (#277).
            return_type = get(FUNCTION_RETURN_TYPES_BY_LIB, (owner, func_name), nothing)
            func_info = get(FUNCTION_REGISTRY_BY_LIB, (owner, func_name),
                            get(FUNCTION_REGISTRY, func_name, nothing))
            CallTarget(func_ptr, channel, free_ptr,
                       alive_ref_for_handle(handle, owner), handle, owner,
                       return_type, func_info,
                       get(ARTIFACT_GENERATIONS, owner, 0))
        end

        # First, try the specified library
        if haskey(RUST_LIBRARIES, lib_name)
            symbol = exported_symbol(lib_name, func_name)
            lib_handle, func_cache = RUST_LIBRARIES[lib_name]
            func_ptr = resolve_in(lib_handle, func_cache, symbol)
            func_ptr == C_NULL ||
                return target_in(lib_name, lib_handle, func_cache, func_ptr)
        end

        # Fallback: search all other loaded libraries
        candidates = Tuple{String, Ptr{Cvoid}}[]
        for (other_lib_name, (other_lib_handle, other_func_cache)) in RUST_LIBRARIES
            other_lib_name == lib_name && continue   # Already checked
            symbol = exported_symbol(other_lib_name, func_name)
            ptr = resolve_in(other_lib_handle, other_func_cache, symbol)
            ptr == C_NULL && continue
            push!(candidates, (other_lib_name, ptr))
        end

        # Two names for one handle resolve to one pointer, and that is one
        # candidate, not a conflict.
        distinct = unique(last, candidates)
        if length(distinct) == 1
            owner, ptr = first(distinct)
            handle, cache = RUST_LIBRARIES[owner]
            return target_in(owner, handle, cache, ptr)
        elseif length(distinct) > 1
            # Ambiguous - found in genuinely different libraries
            error("Function '$func_name' found in multiple libraries: $(join(first.(candidates), ", ")). Please use a unique function name.")
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
    get_function_pointer(lib_name::String, func_name::String) -> Ptr{Cvoid}

Get a function pointer from a loaded library.

If the function is not found in the specified library, searches all other
loaded libraries as a fallback. This enables using functions from multiple
`rust\"\"\"` blocks. See `_resolve_call`, which a caller that also needs the
return type should use instead so that both come from the same library.
"""
get_function_pointer(lib_name::String, func_name::String) =
    first(_resolve_call(lib_name, func_name))

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
    julia_func_signatures = manifest_function_signatures(expanded.manifest)
    # A static method whose name a free function of this block (or another
    # struct's static method) also has gets no bare form (#323).
    colliding = _static_method_collisions(julia_func_signatures, struct_infos)
    julia_defs = [emit_julia_definitions(info; colliding = colliding) for info in struct_infos]

    julia_func_wrappers = emit_julia_function_wrappers(julia_func_signatures)
    # The symbols this block exports, known at macro-expansion time. They are
    # recorded per *module* so that a wrapper resolves through the library its
    # own block loaded — not through whichever block ran last anywhere in the
    # session (#250).
    block_symbols = String[sig.symbol for sig in julia_func_signatures
                           if !sig.is_generic && sig.exported && !isempty(sig.symbol)]

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

        # Which library exported each of this block's symbols, per module. A
        # generated wrapper resolves through *this* table, so two modules that
        # each define `add` call their own `add` regardless of which block was
        # compiled last (#250). Registering a name a second block of the same
        # module already exported is refused here, with a message.
        if !isdefined($__module__, :__RUSTCALL_SYMBOL_LIB)
            @eval $__module__ const __RUSTCALL_SYMBOL_LIB = Dict{String, String}()
        end
        RustCall._record_module_symbols!($__module__.__RUSTCALL_SYMBOL_LIB,
                                         lib_name, $block_symbols,
                                         $(QuoteNode(nameof(__module__))))

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
    _record_module_symbols!(table, lib_name, symbols, module_name)

Record that `lib_name` exports `symbols` for one module, refusing a name the
module already exports from a *different, still-loaded* library.

Two blocks in one module that both export `add` are a genuine ambiguity: the
Julia wrapper of the second silently replaced the first, and which library the
call reached depended on load order (#250). Rust-side clashes inside one block
are already refused by the extractor (`symbol_collisions`, #279); this is the
Julia-side half, across blocks.

Re-running the *same* block is not a collision — the identity, and therefore
the library name, is unchanged. Neither is re-running an edited block whose
previous library has been unloaded.
"""
function _record_module_symbols!(table::AbstractDict, lib_name::AbstractString,
                                 symbols, module_name = :Main)
    name = String(lib_name)
    for symbol in symbols
        sym = String(symbol)
        owner = get(table, sym, "")
        if !isempty(owner) && owner != name
            still_loaded = lock(REGISTRY_LOCK) do
                haskey(RUST_LIBRARIES, owner)
            end
            if still_loaded
                throw(RustError("""
                    `$(sym)` is already exported by another `rust\"\"\"` block in module $(module_name).

                    Two blocks of one module exporting the same name is an ambiguity, not an
                    override: the Julia wrapper of the second would replace the first while both
                    libraries stayed loaded, and which one a call reached would depend on the
                    order they were compiled in.

                    Either rename the Rust function, or drop the earlier block first:

                        RustCall.unload_library("$(owner)")
                    """))
            end
        end
        table[sym] = name
    end
    return nothing
end

"""
    module_symbol_library(mod::Module, symbol::AbstractString) -> String

The library **this module's** block exported `symbol` from, or the session's
current library when the module recorded nothing for it.

This is what makes a generated wrapper call its own function. Resolving from
`get_current_library()` alone meant the wrapper started its search at whichever
block was compiled last *anywhere*, so a second module defining the same Rust
name captured the first module's calls (#250).
"""
function module_symbol_library(mod::Module, symbol::AbstractString)
    if isdefined(mod, :__RUSTCALL_SYMBOL_LIB)
        table = getfield(mod, :__RUSTCALL_SYMBOL_LIB)
        name = get(table, String(symbol), "")
        if !isempty(name)
            loaded = lock(REGISTRY_LOCK) do
                haskey(RUST_LIBRARIES, name)
            end
            loaded && return name
        end
    end
    if isdefined(mod, :__RUSTCALL_ACTIVE_LIB)
        name = getfield(mod, :__RUSTCALL_ACTIVE_LIB)[]
        if !isempty(name)
            loaded = lock(REGISTRY_LOCK) do
                haskey(RUST_LIBRARIES, name)
            end
            loaded && return name
        end
    end
    return get_current_library()
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
    # Which `ArtifactId` encoding was in force when this snapshot was recorded.
    # The snapshot stores *inputs*, never a key: `toolchain` and `compiler` are
    # properties of the loading session, so a precompiled key would pin a rustc
    # that may since have been upgraded — #252 in reverse. An older schema means
    # "recompute, then alias", never an error (#278).
    artifact_schema::Int

    function RustBlockSnapshot(code, cfg_text, compiler_target, compiler_level,
                               cargo_env = nothing,
                               artifact_schema = ARTIFACT_ID_SCHEMA_VERSION)
        return new(String(code), String(cfg_text), String(compiler_target),
                   Int(compiler_level),
                   cargo_env === nothing ? nothing : String(cargo_env),
                   Int(artifact_schema))
    end
end

"""
    ensure_loaded(lib_name::String, block) -> String

Ensure that a Rust library is loaded in the current session; `block` is the
`RustBlockSnapshot` stored by the macro (a plain source string is
accepted for modules precompiled by older versions, and is rebuilt under the
current default compiler). Returns the name of the loaded library. Useful for
precompiled modules that need to reload libraries at runtime.
"""
function ensure_loaded(lib_name::String, block::RustBlockSnapshot)
    # A snapshot recorded under an older `ArtifactId` encoding names a library
    # this session can no longer derive, so the stored name cannot be trusted as
    # evidence that the right library is loaded: recompute, and let the caller
    # alias. Never an error.
    stale_schema = block.artifact_schema != ARTIFACT_ID_SCHEMA_VERSION
    needs_reload = stale_schema || lock(REGISTRY_LOCK) do
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

    # One identity for this block, used both as the disk cache key and as the
    # in-memory library name (#278). It covers the compiler snapshot as well as
    # the source: the same expanded source built at another opt-level, target or
    # cfg set is another artifact, so a lookup can never hand back a build made
    # under a different configuration — and the disk key and the registry name
    # can no longer drift apart, because there is only one formula.
    cache_key = _rustc_block_identity(wrapped_code, compiler, cfg_text)
    lib_name = "rust_$(artifact_short_id(cache_key))"

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
    policy = inline_rustc_policy()
    if is_in_memory &&
       _register_manifest(expanded, lib_name; compiler, policy, require_loaded = true)
        return lib_name
    end

    # Check cache first
    cached_lib = get_cached_library(cache_key)
    if cached_lib !== nothing && is_cache_valid(cache_key, wrapped_code, compiler; cfg_text)
        # Load from cache. `load_cached_library` verifies the checksum and
        # hands back a path; opening it and publishing the handle together with
        # the manifest's lookup tables is `load_artifact!`'s job (#277 Phase
        # B), so a concurrent `ensure_loaded` never sees the library before its
        # symbols.
        _register_manifest(expanded, lib_name; compiler, policy,
                           load_path = load_cached_library(cache_key))

        return lib_name
    end

    # Compile to shared library (cache miss)
    lib_path = compile_rust_to_shared_lib(wrapped_code; compiler=compiler)

    # Save to cache
    try
        # The function list in the metadata is informational only; the
        # manifest is what registers a library's functions.
        functions = String[]

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

    # Load and register the library: the handle and the manifest's lookup
    # tables are published in one critical section (#279 follow-up, #277).
    _register_manifest(expanded, lib_name; compiler, policy, load_path = lib_path)

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
    # `build_env_key` is the environment the build actually runs under: the
    # snapshot recorded by the macro, or the current one. Local path
    # dependencies contribute their *content*, so editing one rebuilds.
    #
    # The effective Cargo configuration is folded in *here*, not later: the
    # `.cargo/config.toml` chain above the generated project can set
    # `[build] rustflags`, so it changes the binary, and a key that omits it
    # hands back the pre-change build. Generated projects are created with
    # `mktempdir` directly under `tempdir()` (see `create_cargo_project`), so
    # that is the directory whose chain reaches the build, and it is knowable
    # before the project exists — which is what lets this be computed once.
    cargo_config = _cargo_config_digest(ENV; dir = tempdir())

    # The resolved dependency graph is part of the identity, not only the
    # requested ranges: `ndarray = "0.15"` resolves to one set of versions today
    # and another after an upstream patch release, and a key over the range
    # alone served the old binary for the new graph — or built a new graph
    # behind an unchanged key (#256). The graph lives in a `Cargo.lock`
    # persisted per dependency set (`lockfile_path`): when it exists, its
    # content is known before any project does; when it does not, the set is
    # resolved once, in the project that will be built, and persisted. The
    # project's root package is named from the set (`cargo_block_package`) so
    # the lockfile fits every block declaring it.
    project = nothing
    compiler = get_default_compiler()
    cleanup = () -> begin
        project === nothing && return
        # Clean up the temporary project (kept for debugging in debug mode).
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

    try
        stored_lock = lockfile_path(dependencies)
        cargo_lock = if isfile(stored_lock)
            _file_content_digest(stored_lock)
        else
            project = create_cargo_project(cargo_block_package(dependencies), dependencies)
            something(ensure_cargo_lockfile!(project; env = build_env), "")
        end
        cargo_id = _cargo_block_id(augmented_code, dependencies, build_env_key;
                                   cargo_config = cargo_config, cargo_lock = cargo_lock)
        # THE key for this block: the in-memory name, the disk lookup, the build
        # and the save all use this one value (#278, #287). If a second formula
        # ever appears downstream, `build_cargo_project_cached` refuses the build
        # rather than silently caching under two keys.
        code_hash = artifact_key(cargo_id)

        # The library name. `artifact_short_id` is the only truncation in the
        # design and is never a lookup key (#278).
        lib_name = "rust_cargo_$(artifact_short_id(code_hash, 16))"

        # Check if already compiled and loaded in memory
        is_in_memory = lock(REGISTRY_LOCK) do
            haskey(RUST_LIBRARIES, lib_name)
        end
        # As in the rustc path: the re-check happens inside `_register_manifest`'s
        # critical section, so a concurrent unload sends us down the build path
        # rather than leaving metadata for a library that is gone.
        policy = inline_cargo_policy()
        if is_in_memory &&
           _register_manifest(expanded, lib_name; cargo_backed = true, policy,
                              snapshot_env = build_env, require_loaded = true)
            @debug "Using cached Cargo library from memory" lib_name=lib_name
            return lib_name
        end

        # The block identity *is* the cache key: re-mixing already-mixed material
        # under a second, hand-rolled formula (and truncating it to 32 characters)
        # was the Cargo half of #278, and deriving a *richer* key inside the builder
        # while looking up with the base one was #287 — same bug, other direction.
        cache_key = code_hash

        cached_lib = get_cargo_cached_library(cache_key)
        if !isnothing(cached_lib) && isfile(cached_lib)
            # Load from cache through the one loader (#277 Phase B). A failure to
            # open the cached file is not fatal: fall through and rebuild.
            loaded = try
                _register_manifest(expanded, lib_name; cargo_backed = true, policy,
                                   load_path = cached_lib, snapshot_env = build_env)
            catch e
                @debug "Failed to load the cached Cargo library; rebuilding" exception = e
                false
            end
            if loaded
                @debug "Loaded Cargo library from cache" lib_name=lib_name cache_key=artifact_short_id(cache_key, 8)
                return lib_name
            end
        end

        # Build necessary if not in cache or cache load failed
        @info "Building Rust code with external dependencies..." dependencies=length(dependencies) lib_name=lib_name

        if project === nothing
            project = create_cargo_project(cargo_block_package(dependencies), dependencies)
            # The store had a lockfile when the identity was computed; the
            # build must be of exactly that graph. A file that changed in
            # between would make the key describe another build — refuse.
            replayed = something(ensure_cargo_lockfile!(project; env = build_env), "")
            replayed == cargo_lock || throw(CargoBuildError(
                "The persisted Cargo.lock changed while this block was being prepared",
                "lockfile: $(stored_lock)", project.path))
        end

        # Ensure the code with wrappers is written to the project
        write_rust_code_to_project(project, augmented_code)

        # `--locked`: the project's lockfile is authoritative, so Cargo builds
        # the graph the key describes or fails; it never re-resolves silently.
        lib_path = build_cargo_project_cached(project, cargo_id, release=true, env=build_env,
                                              locked = !isempty(cargo_lock))

        # Cache the built library (if it wasn't already in cache)
        try
            save_cargo_cached_library(cache_key, lib_path)
        catch e
            @debug "Failed to cache Cargo library: $e"
        end

        # Load and register the library: handle and manifest lookup tables
        # together (#279 follow-up, #277 Phase B).
        _register_manifest(expanded, lib_name; cargo_backed = true, policy,
                           load_path = lib_path, snapshot_env = build_env)

        @info "Successfully built Rust code with Cargo" lib_name=lib_name
        return lib_name
    finally
        cleanup()
    end
end


"""
    _cargo_block_id(expanded_source, dependencies, cargo_env = "") -> ArtifactId

Identity of a Cargo-backed block, as an `ArtifactId`: expanded source, the
dependency set (`artifact_dependency_strings`, which folds a *local path*
dependency in by content rather than by location, so editing one rebuilds), the
Cargo/RUSTFLAGS environment the build runs under (`cargo_env`, see
`_cargo_cfg_env_key`), the release profile, and — new in #278 — the toolchain
fingerprint and the identity of the compiler that runs, both defaulted by
`ArtifactId`.

`cargo_config` is the digest of the effective `.cargo/config.toml` chain above
the directory the build will run in (`_cargo_config_digest`); the caller passes
it because it must be the *same* digest the whole evaluation uses.
`cargo_lock` is the content digest of the `Cargo.lock` the build is made with —
the resolved graph, persisted per dependency set (`lockfile_path`,
`ensure_cargo_lockfile!`, #256) — so two builds of one source and one requested
range that resolve differently are two artifacts.

`artifact_key` of this record is the in-memory library name, the disk cache
key, the build key and the save key — one value per block evaluation (the
generated project's package name is derived from the dependency set,
`cargo_block_package`, so a persisted lockfile fits every block declaring it).
The Cargo path used to hash the block once and then
re-mix that digest under a second formula for the cache key (#278); the first
fix then left `build_cargo_project_cached` deriving a *richer* key than the one
the outer lookup used, so a Cargo-config change still hit the old binary
(#287).
"""
function _cargo_block_id(expanded_source::AbstractString, dependencies,
                         cargo_env::AbstractString = "";
                         cargo_config::AbstractString = "",
                         cargo_lock::AbstractString = "",
                         release::Bool = true)
    # `cargo_lock` is the content digest of the `Cargo.lock` the build is made
    # with (`ensure_cargo_lockfile!`): the *resolved* graph, where
    # `dependencies` names only the requested ranges (#256). "" when the block
    # has none — a set with no dependency to resolve.
    return ArtifactId(
        kind = "cargo",
        source = String(expanded_source),
        codegen = Pair{String, String}["profile" => (release ? "release" : "debug")],
        dependencies = artifact_dependency_strings(dependencies),
        build_env = Pair{String, String}[
            "cargo-env" => String(cargo_env),
            "cargo-config" => String(cargo_config),
        ],
        extra = Pair{String, String}["cargo-lock" => String(cargo_lock)],
    )
end

"""
    _cargo_block_identity(expanded_source, deps_hash, cargo_env = "") -> String

The `artifact_key` of a Cargo-backed block described by an opaque dependency
digest (`hash_dependencies`) rather than by the specs themselves. Kept for
callers — and tests — that only have the digest; `_cargo_block_id` is the
richer form the compile path uses, and the two deliberately produce different
keys because they describe the dependency set differently.
"""
function _cargo_block_identity(expanded_source::AbstractString, deps_hash::AbstractString,
                              cargo_env::AbstractString = "")
    return artifact_key(ArtifactId(
        kind = "cargo",
        source = String(expanded_source),
        codegen = Pair{String, String}["profile" => "release"],
        dependencies = String[String(deps_hash)],
        build_env = Pair{String, String}["cargo-env" => String(cargo_env)],
    ))
end

"""
    _rustc_block_identity(wrapped_source, compiler, cfg_text) -> String

Identity of a block built by `rustc` directly. A thin adapter over
`generate_cache_key`, which is `artifact_key` of an `ArtifactId`: wrapped
source, the compiler snapshot it was expanded for (target, opt-level, debug
info), the cfg text the wrappers were derived from, the tracked rustc
environment (`RUSTC_BUILD_ENV_NAMES`), the toolchain fingerprint and the
identity of the compiler that runs. `cfg_text === nothing` means the current
strict snapshot, as in `expand_inline`.

Since #278 this is the *same value* as the on-disk cache key of the artifact:
the library name is `artifact_short_id` of it, never a second digest.
"""
function _rustc_block_identity(wrapped_source::AbstractString, compiler::RustCompiler,
                              cfg_text::Union{Nothing, AbstractString})
    return generate_cache_key(wrapped_source, compiler; cfg_text = cfg_text)
end

"""
    _register_manifest(expanded::ExpandedInline, lib_name::String;
                       policy, load_path = nothing) -> Bool

Register everything the manifest of a compiled block tells us:

- the name-to-symbol mapping and the return type of every exported function,
  so `@rust f(...)` resolves `rustcall_f` (#279) and works without `::T`;
- generic free functions and generic struct wrappers, for on-demand
  monomorphization. The registered code is the whole expanded block and the
  function is addressed by its qualified name, so `specialize` instantiates it
  in place with sibling items, imports and `super::` paths intact.

Pass `load_path` to open and publish a freshly compiled (or cached) library at
the same time: the load goes through `load_artifact!` (`src/loadpolicy.jl`),
which opens the file under `policy` and installs the handle together with the
manifest-derived lookup tables in **one** `REGISTRY_LOCK` critical section.
That is what makes a concurrent `ensure_loaded` / `@rust f(...)` safe: a task
that sees the library in `RUST_LIBRARIES` also sees that `f` is exported as
`rustcall_f`, instead of resolving `f` to itself and failing (or, worse,
hitting another library's `f`). No call site inserts into `RUST_LIBRARIES`
itself (#277 Phase B).

Omit `load_path` when re-registering the volatile tables of a library that is
*already* loaded. The existence check then happens inside the same critical
section (`register_artifact_metadata!(...; require_loaded = true)`), so an
`unload_library` or hot reload racing between a caller's `haskey` and this call
cannot leave metadata and `CURRENT_LIB[]` pointing at a library that is no
longer in `RUST_LIBRARIES`. Returns `false` when the library turned out to be
gone and nothing was registered; the caller then falls through to compiling and
loading it again.

The generic registrations stay outside the lock: `register_generic_function`
may shell out to the extractor to recover a signature, which must not run with
the global registry lock held.
"""
function _register_manifest(expanded, lib_name::String; compiler = nothing,
                            cargo_backed::Bool = false,
                            policy::LoadPolicy = inline_rustc_policy(),
                            load_path::Union{AbstractString, Nothing} = nothing,
                            handle::Union{Ptr{Cvoid}, Nothing} = nothing,
                            snapshot_env = nothing,
                            require_loaded::Bool = false,
                            set_current::Bool = true)
    manifest = expanded.manifest
    signatures = manifest_function_signatures(manifest; only_attributed = false)
    symbols, return_types = _manifest_registry_entries(signatures)

    registered = if load_path !== nothing
        load_artifact!(policy, load_path; lib_name, symbols, return_types,
                       snapshot_env, set_current)
        true
    elseif handle !== nothing
        adopt_artifact!(policy, handle; lib_name, symbols, return_types,
                        snapshot_env, set_current)
        true
    else
        register_artifact_metadata!(policy, lib_name; symbols, return_types,
                                    require_loaded, set_current)
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
    _manifest_registry_entries(signatures) -> (symbols, return_types)

The registry rows a manifest implies: `name => exported symbol` pairs and
`name => Julia return type` pairs for every exported, non-generic function.

Computing them is deliberately separate from installing them. The rows are
derived here, outside any lock (recovering a return type consults the FFI
contract and the generic registry), and handed to `load_artifact!` /
`register_artifact_metadata!`, which install them in the same critical section
that publishes the library handle — so a task which finds the library in
`RUST_LIBRARIES` also finds how to resolve its names (#279, #277 Phase B).

Identity mappings are included, so a plain `#[no_mangle] fn f` is explicitly
`f => f` for its library and cannot pick up another library's
`f => rustcall_f`.

A manifest may report one symbol twice. `@rust_crate` and the hot reload scan
an external crate leniently — only target predicates are decided, because the
crate's own features and build script are not RustCall's to evaluate — so
mutually exclusive `#[cfg(feature = ...)]` variants of one `#[julia] fn` both
survive. The symbol mapping is the same either way and is recorded, but the
**return type is not**: source order is not evidence of which variant was
built, and a wrong primitive hint is a wrong ABI. Such a call falls through to
inference or an explicit `::T` instead. Deciding an external crate's features
exactly needs the crate's own build configuration, which #277 Phase B owns.
"""
function _manifest_registry_entries(signatures)
    exported = [sig for sig in signatures if !sig.is_generic && sig.exported]
    occurrences = Dict{String, Int}()
    for sig in exported
        occurrences[sig.symbol] = get(occurrences, sig.symbol, 0) + 1
    end
    symbols = Pair{String, String}[]
    return_types = Pair{String, Type}[]
    for sig in exported
        isempty(sig.symbol) || push!(symbols, String(sig.name) => String(sig.symbol))
        if occurrences[sig.symbol] > 1
            @debug "Ambiguous manifest entry: not registering a return type" symbol = sig.symbol
            continue
        end
        ret_type = _manifest_return_type(sig)
        ret_type === nothing && continue
        # Recorded under both the Rust name and the exported symbol: `@rust
        # f(...)` names the function, while a caller that already resolved the
        # symbol (or a generated wrapper) asks for `rustcall_f`. Both keys are
        # library-scoped — a name-only hint would outlive this library (#279).
        for key in unique((sig.name, sig.symbol))
            push!(return_types, String(key) => ret_type)
        end
    end
    return symbols, return_types
end

"""
    _manifest_return_type(sig::RustFunctionSignature) -> Union{Type, Nothing}

The Julia return type to record for an exported function so that `@rust` calls
may omit `::ReturnType`, or `nothing` when the return type has no single-slot
Julia counterpart and the call must be explicit.
"""
function _manifest_return_type(sig)
    if haskey(FUNCTION_REGISTRY, sig.symbol) || is_generic_function(sig.symbol)
        return nothing
    end
    ret_type = if sig.return_kind == :unit
        Cvoid
    elseif sig.return_kind == :plain
        # One C slot, decided by the contract (`src/ffi_contract.jl`), not by a
        # private primitive table: `i128`, `u128`, `char`, the `c_*` aliases and
        # raw pointers all register now. Multi-word returns (a lowered `String`)
        # are deliberately excluded — `@rust f(x)` without `::T` cannot decode a
        # `(ptr, len, cap)` buffer, and the generated wrapper handles them.
        c = ffi_return_contract(sig.return_type; abi = sig.return_abi)
        c.known && (c.abi === :by_value || c.abi === :pointer) ? only(c.ccall_types) : nothing
    else
        # Result/Option wrappers return `CResult_<fn>`/`COption_<fn>` structs; the
        # generated Julia wrapper handles them, `@rust` callers must be explicit.
        nothing
    end
    return ret_type
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

The Rust function names the manifest recorded for a loaded library, sorted.

Read from `FUNCTION_SYMBOLS_BY_LIB`, the per-library name-to-symbol table the
manifest fills when the library is registered (#279). A library that is not
loaded, or whose manifest recorded no functions, yields an empty list. (Until
0.3.0 this consulted the module registry of the removed LLVM IR path, which
nothing ever wrote to, so it always returned an empty list; #265.)
"""
function list_library_functions(lib_name::String)
    names = lock(REGISTRY_LOCK) do
        [name for (lib, name) in keys(FUNCTION_SYMBOLS_BY_LIB) if lib == lib_name]
    end
    return sort!(names)
end

"""
    unload_library(lib_name::String; close = false)

Retire a Rust library: remove everything the registries record about it.

A thin wrapper over `unload_artifact!` (`src/loadpolicy.jl`), which is the one
place a library leaves the registry (#277 Phase B). It drops everything the
registries record about the library — its name-to-symbol mappings and
return-type hints (a stale mapping would keep redirecting lookups to a symbol
that is no longer reachable, #279), its `FUNCTION_REGISTRY` rows, the
monomorphizations whose pointers point into it (#73), its `@irust` memos and
its panic channels.

**The image stays mapped.** Unloading is the same act as a hot reload replacing
a library, and unsafe to close for the same reason: a call that started a
moment ago may still be inside it. The image is retired
(`RustCall.retired_handles`) and keeps its liveness flag, so an object it
allocated still runs its destructor through it.

`close = true` reclaims it — the caller stating that no call into it is in
flight. That, and only that, makes objects from the image inert (#249, #277).
"""
function unload_library(lib_name::String; close::Bool = false)
    if !unload_artifact!(inline_rustc_policy(), lib_name; close)
        @warn "Library '$lib_name' not loaded"
    end
    return nothing
end

"""
    unload_all_libraries(; close = false)

Retire every loaded Rust library. `close = true` also closes every retired
image — see `unload_library`.
"""
function unload_all_libraries(; close::Bool = false)
    # One image may sit under several names (`alias_artifact!`), and unloading
    # any of them removes them all and closes the image once. So the loop
    # re-checks rather than warning about a name a previous iteration already
    # took away (#277 Phase B).
    while true
        name = lock(REGISTRY_LOCK) do
            isempty(RUST_LIBRARIES) ? nothing : first(keys(RUST_LIBRARIES))
        end
        name === nothing && break
        unload_artifact!(inline_rustc_policy(), name; close)
    end
    # Images retired under a name that is no longer registered — a library that
    # was hot-reloaded and then unloaded — are swept too, when the caller says
    # it is safe.
    close && close_retired_handles!()
    return nothing
end

# irust"" string literal implementation

"""
    IrustSnippet

What one compiled `@irust` snippet is, from the point of view of a later call:
the library it was loaded into, the **exported symbol** of the generated
wrapper (`rustcall_irust_func_<id>`, the one with the `catch_unwind` boundary),
and the Julia type its result is read back as.

All three are decided once, when the snippet is compiled, and stored together.
The return type in particular is *not* re-derived on a cache hit: it is the type
the Rust function was actually generated with, so a second route to it — a
changed heuristic, a different Julia version — can never disagree with the ABI
the compiled code has (#346).
"""
struct IrustSnippet
    lib_name::String
    symbol::String
    return_type::Type
end

"""
Registry for irust snippets.
Maps a snippet's artifact key to the `IrustSnippet` describing what was built.
"""
const IRUST_FUNCTIONS = _state_view(:irust_functions, Dict{String, IrustSnippet}())

"""
    @irust(code, args...)
    @irust(code)

Compile one Rust **expression** into a throwaway function and call it.

`@irust` is the small end of RustCall: a scalar expression typed at the REPL or
in a notebook. For anything larger — several functions, a `String`, a
`Result`/`Option`, a struct, or code you want to keep — use `rust\"\"\"...\"\"\"`
with `@rust`, which takes its types from the Rust side instead of guessing them.

# Interpolation

`\\\$name` is replaced by the value of the Julia variable `name`, which is passed
to the generated Rust function as an argument. The rules:

- `\\\$name` matches an identifier: an ASCII letter or `_` followed by letters,
  digits and `_`. `\\\$obj.field` therefore interpolates `obj` only, and
  `.field` is left as Rust source.
- The same variable used twice is passed once.
- Substitution is **textual and unconditional**, so it happens inside Rust
  string literals too: `"\\\$x"` becomes the *value* of `x`, not the text
  `\\\$x`.
- `\\\$\\\$` is an escape for a literal `\\\$`, consuming no variable. Write
  `macro_rules!` metavariables as `\\\$\\\$name`.
- A `\\\$` that is not followed by an identifier is left alone.
- Julia itself interpolates a bare `\$` inside `"..."`, so a quoted argument has
  to escape it with a backslash — that is why every example below reads
  `@irust("\\\$x * 2")`. The string-literal form `irust"..."` is not
  interpolated by Julia and needs no backslash at all.

Variables may also be passed explicitly and referenced as `arg1`, `arg2`, …

# Body

The snippet is the **body** of the generated function, so a trailing expression
is its value, an explicit `return` works, and statements, `let` bindings, loops
and multi-line snippets need no special treatment.

# Return type

The return type is rustc's, not a guess: the snippet is type-checked on its own
first, and the type it evaluates to becomes the generated function's return
type (#348). An unsuffixed integer literal is an `i64` and an unsuffixed float
literal an `f64`, as in Julia; write `1u8`, `2.0f32` and so on for the rest. A
snippet whose value is `()` returns `nothing`. When the snippet does not
type-check, the error carries rustc's own diagnostic.

# Limitations

See "Limitations of `@irust`" in the manual. In short:

- arguments **and results** are **scalars only**: `Int8`…`Int64`,
  `UInt8`…`UInt64`, `Float32`, `Float64`, `Bool` (`IRUST_SCALAR_TYPES`). No
  `String`, arrays, structs or 128-bit integers —
  `rust\"\"\"...\"\"\"` handles those;
- `\\\$name` substitution is **textual**, so it happens inside Rust string
  literals too, and `\\\$obj.field` interpolates `obj` only;
- `@irust` is **not type-stable**: the return type is decided at run time from
  the snippet;
- each new snippet costs a few `rustc` invocations (the type probe, the
  confirmation of its answer, and the build), memoized afterwards. `@irust` is
  for exploration; a package should use `rust\"\"\"...\"\"\"` with `@rust`.

A Rust panic inside the snippet is a catchable `RustPanicError`, as it is on
every other RustCall path (#346).

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

# Statements and a trailing expression
@irust("let t = 20i64; t + 22")
```
"""
macro irust(code, args...)
    return _irust_expansion(code, args, "@irust")
end

"""
    @irust_str(code)

String-literal form of `@irust`: `irust"\$x * 2"`.

Julia does not interpolate inside a non-standard string literal, so `\$name`
reaches the macro as written and needs no backslash. Everything else — the
interpolation rules, the body rules, and the limitations — is `@irust`'s;
read its docstring first, and reach for `rust\"\"\"...\"\"\"` for anything beyond
a small scalar expression.

# Example
```julia
irust"40 + 2"          # => 42

x = Int64(21)
irust"\$x * 2"          # => 42
```
"""
macro irust_str(code)
    return _irust_expansion(code, (), "@irust_str")
end

"""
    _irust_expansion(code, args, macro_name) -> Expr

The shared expansion of `@irust` and `@irust_str`: parse `\\\$var`
interpolation out of the snippet, then call `_compile_and_call_irust` with the
referenced variables escaped into the caller's scope.

Both macros go through it so the two forms cannot drift: `irust"\$x * 2"` and
`@irust("\\\$x * 2")` are the same program. Before #347 the literal form passed
no arguments at all and could not interpolate anything.
"""
function _irust_expansion(code, args, macro_name::String)
    isa(code, AbstractString) ||
        error("$(macro_name) expects a string literal as the first argument. Got: $(typeof(code))")
    vars_from_code, processed_code = _parse_irust_variables(String(code))

    # `$var` references first, then any explicitly passed arguments — the
    # order the generated `arg1, arg2, …` parameters are numbered in.
    all_vars = vcat(vars_from_code, collect(args))

    isempty(all_vars) &&
        return Expr(:call, GlobalRef(RustCall, :_compile_and_call_irust), processed_code)
    # Each variable is escaped so it is evaluated in the calling scope.
    var_exprs = Any[esc(var) for var in all_vars]
    return Expr(:call, GlobalRef(RustCall, :_compile_and_call_irust), processed_code, var_exprs...)
end

"""
    _parse_irust_variables(code::String) -> (Vector{Symbol}, String)

Resolve `\\\$var` interpolation in an `@irust` snippet: return the variables it
references, in order of first appearance, and the snippet with each reference
rewritten to the `argN` the generated Rust function names that parameter.

The rules, which the `@irust` docstring documents for users:

- `\\\$name` matches an ASCII letter or `_` followed by letters, digits and `_`,
  so `\\\$obj.field` interpolates `obj` and leaves `.field` alone;
- the same variable used twice is one parameter;
- `\\\$\\\$` is an escape producing a literal `\\\$` and consuming no variable —
  which is how a `macro_rules!` metavariable is written (#350). The comment
  here used to claim the escape existed while the pattern had no case for it,
  so `\\\$\\\$x` substituted the *second* `\\\$` and emitted `\\\$arg1`;
- a `\\\$` followed by anything else is left as written.

Substitution is textual and unconditional — it happens inside Rust string
literals too. That is deliberate (`"\\\$x"` is meant to read as the value), and
`\\\$\\\$` is the way out of it.

# Example
```julia
vars, code = _parse_irust_variables("\\\$x + \\\$y * 2")
# vars = [:x, :y]
# code = "arg1 + arg2 * 2"
```
"""
function _parse_irust_variables(code::String)
    # `$$` first, so it wins over `$` + identifier: the alternation is ordered.
    pattern = r"\$\$|\$([a-zA-Z_][a-zA-Z0-9_]*)"

    vars = Symbol[]
    var_to_idx = Dict{Symbol, Int}()
    out = IOBuffer()
    pos = firstindex(code)
    for m in eachmatch(pattern, code)
        # Everything since the previous match, verbatim.
        print(out, SubString(code, pos, prevind(code, m.offset)))
        if m.captures[1] === nothing
            print(out, '$')          # `$$` -> one literal `$`, no variable
        else
            name = Symbol(m.captures[1])
            idx = get(var_to_idx, name, 0)
            if idx == 0
                push!(vars, name)
                idx = length(vars)
                var_to_idx[name] = idx
            end
            print(out, "arg", idx)
        end
        pos = m.offset + ncodeunits(m.match)
    end
    print(out, SubString(code, pos, lastindex(code)))

    return (vars, String(take!(out)))
end

"""
    _compile_and_call_irust(code::String, args...)

Compile one `@irust` snippet — as a `#[julia]` function — load it, and call it.

The snippet goes through the *same* machinery `rust\"\"\"` uses (#346): it is
emitted as a `#[julia] pub fn`, expanded by `rustcall-extract`
(`expand_inline`), and called through the exported symbol of the wrapper the
expansion generates. That wrapper is what carries the `catch_unwind` boundary
and the thread-local panic channel, so a panic inside a snippet is a
`RustPanicError` instead of an abort. Until #346 this function hand-wrote a
bare `#[no_mangle] pub extern \"C\"` entry point, which had neither: an unwind
crossing it terminated the process, while `_call_irust_function` read a channel
nothing ever wrote.

What is decided here is decided *once* and stored in `IRUST_FUNCTIONS`: the
symbol and the Julia return type come back from the manifest of the very
expansion that was compiled, and a cache hit reuses them rather than deriving
them again by a second route.

# Error Handling
This function provides improved error messages for:
- Type mismatches
- Compilation failures
- Missing variables
"""
function _compile_and_call_irust(code::String, args...)
    try
        # The identity of this snippet: the source and the argument types it is
        # being compiled for, through the one identity function (#278). Julia's
        # `hash` is randomized per session, so a name derived from it could
        # never be matched again — the rule at the top of src/cache.jl.
        #
        # The element types are named rather than inferred from the elements:
        # `collect(map(typeof, ()))` is a `Vector{Union{}}`, which matches none
        # of the `Vector{<:Type}` / `Vector{String}` methods below — that is
        # why every argument-less `@irust`, and therefore every `irust"..."`,
        # used to die with a `MethodError` (#347).
        arg_types = Type[typeof(a) for a in args]
        rust_arg_types = String[_julia_to_rust_type(t) for t in arg_types]
        compiler = get_default_compiler()
        code_hash = artifact_key(ArtifactId(
            kind = "irust",
            source = code,
            type_params = artifact_type_params(
                ["arg$(i)" for i in eachindex(arg_types)], arg_types),
            target_triple = compiler.target_triple,
            codegen = artifact_codegen_options(compiler),
        ))
        func_name = "irust_func_$(artifact_short_id(code_hash))"

        # Check if already compiled (protect IRUST_FUNCTIONS with REGISTRY_LOCK)
        cached = lock(REGISTRY_LOCK) do
            snippet = get(IRUST_FUNCTIONS, code_hash, nothing)
            snippet === nothing && return nothing
            haskey(RUST_LIBRARIES, snippet.lib_name) && return snippet
            # Stale memo: the library was unloaded, so recompile transparently.
            delete!(IRUST_FUNCTIONS, code_hash)
            return nothing
        end
        if cached !== nothing
            # The symbol and the return type are the ones the compiled code was
            # built with, not a fresh guess at them.
            return _call_irust_function(cached.lib_name, cached.symbol,
                                        cached.return_type, args...)
        end

        # Ask rustc what the snippet evaluates to (#348). This is the only
        # decision the old code took by pattern-matching the Rust source, and
        # the one it got wrong for most real snippets. The answer is then
        # *confirmed* with the type declared, which is what catches a path the
        # first question could not provoke a diagnostic for — a fallthrough
        # that is `()`.
        rust_ret_type = _probe_irust_return_type(code, rust_arg_types, compiler)
        rust_ret_type = _confirm_irust_return_type(code, rust_arg_types,
                                                   rust_ret_type, compiler)

        # Generate the `#[julia]` item and expand it: `expanded.source` is the
        # snippet's function plus the generated wrapper with the panic
        # boundary, and `expanded.manifest` names the symbol that wrapper
        # exports and the return type it was built for.
        rust_func_code = _generate_irust_function(func_name, code, rust_arg_types, rust_ret_type)
        expanded = try
            expand_inline(rust_func_code)
        catch e
            error("""
            Failed to compile Rust code for @irust.

            Code: $code
            Generated Rust function:
            $rust_func_code

            Original error: $e

            Tip: the snippet is the *body* of the generated function, so it must
            be valid Rust there: a trailing expression, or statements ending in
            one, or an explicit `return`.
            """)
        end
        sig = _irust_signature(expanded, func_name)
        julia_ret_type = _irust_return_type(sig, code)

        # Compile and load
        wrapped_code = wrap_rust_code(expanded.source)

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
            The return type (`$rust_ret_type`) is the one rustc gave the snippet
            when it was type-checked on its own, so a failure here is about the
            FFI boundary rather than the snippet: @irust passes and returns
            scalars only. Use rust\"\"\"...\"\"\" with `@rust` for anything else.
            """)
        end

        # Load and register the snippet through the one loader (#277 Phase B).
        # `IRUST_FUNCTIONS` is written in the same critical section as the
        # handle: a concurrent `@irust` that finds the memo must find the
        # library it names.
        lib_name = "irust_$(artifact_short_id(code_hash))"
        load_artifact!(irust_policy(), lib_path; lib_name, eager = (sig.symbol,))
        lock(REGISTRY_LOCK) do
            IRUST_FUNCTIONS[code_hash] = IrustSnippet(lib_name, sig.symbol, julia_ret_type)
        end

        # Call the function with correct return type
        return _call_irust_function(lib_name, sig.symbol, julia_ret_type, args...)
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
    _probe_irust_return_type(code, rust_arg_types, compiler) -> String

The Rust return type of an `@irust` snippet, **as rustc names it**.

A thin adapter over `probe_rust_expression_type`: build the parameter list the
generated function will have, run the probe, and turn "the probe could not name
a type" into an error that shows rustc's own diagnostics — because a probe that
does not answer is a snippet that does not type-check, and rustc's message is
the diagnosis.

Until #348 this was `_infer_return_type_improved`, a list of ordered regexes
over the snippet: a snippet containing `->` (an inner `fn`, a closure), `=>`
(a `match` arm) or any comparison was called `bool`; `\\\$x as f64` with an
integer argument was called `i64`; a `Float32` argument forced `f64`. Every
miss surfaced as a rustc error in generated source the user never wrote.
"""
function _probe_irust_return_type(code::String, rust_arg_types::Vector{String},
                                  compiler::RustCompiler)
    params = join(("arg$(i): $(t)" for (i, t) in enumerate(rust_arg_types)), ", ")
    probe = probe_rust_expression_type(code, params; compiler)
    probe.rust_type === nothing || return probe.rust_type
    isempty(probe.conflict) || error("""
        @irust cannot give this snippet one return type.

        Code: $code

        Its return sites require: $(join(probe.conflict, ", ")).

        A Rust function has one return type, so the snippet has to as well.
        Give the literals a suffix (`0i32`) or a cast (`as i64`) so every path
        agrees, or use rust\"\"\"...\"\"\" with `@rust`.
        """)
    error("""
        Failed to compile Rust code for @irust.

        Code: $code

        rustc could not type-check the snippet:

        $(probe.rendered)
        Tip: the snippet is the *body* of the generated function — a trailing
        expression is its value, and `arg1`, `arg2`, … are the interpolated
        variables. Use rust\"\"\"...\"\"\" with `@rust` for anything that needs
        more than one expression's worth of context.
        """)
end

"""
    _confirm_irust_return_type(code, rust_arg_types, rust_ret_type, compiler)

Type-check the snippet once more with the probed type **declared**, and raise
with rustc's own diagnostics if it does not hold.

The `()`-returning probe learns the type from the mismatches it provokes, and a
path that already produces `()` provokes none: `if \\\$flag { return 1i64; }`
comes back as `i64` with nothing said about the fallthrough, which is unit
(Codex review of PR #354). Declaring `-> i64` and asking again is what sees it,
and the error is then rustc's about *the snippet* — "expected `i64`, found
`()`" — rather than the same failure discovered later, in generated source the
user never wrote.

When the declared type is rejected and rustc's diagnostic names a different
concrete one — ``expected `i64`, found `i32` `` — that named type is tried
**once**. The first answer can be rustc's default for an unconstrained literal,
and a site the `()` comparison could not reach may know better; the compiler is
the one that knows, so it is asked rather than guessed at. Bounded at a single
retry, and a type that still does not hold raises: a wrong default is the class
of bug #348 is about, and a clear error naming `rust\"\"\"...\"\"\"`
is the documented outcome.

Skipped when the snippet's value is `()`: a clean `()`-probe already checked
every path against `()`.

Returns the Rust type to generate with — `rust_ret_type` unless the retry
replaced it.
"""
function _confirm_irust_return_type(code::String, rust_arg_types::Vector{String},
                                    rust_ret_type::String, compiler::RustCompiler)
    rust_ret_type == "()" && return rust_ret_type
    params = join(("arg$(i): $(t)" for (i, t) in enumerate(rust_arg_types)), ", ")
    confirmation = confirm_rust_return_type(code, params, rust_ret_type; compiler)
    confirmation.ok && return rust_ret_type

    suggested = confirmation.suggested
    if suggested !== nothing && suggested != rust_ret_type
        retry = confirm_rust_return_type(code, params, suggested; compiler)
        retry.ok && return suggested
        confirmation = retry
        rust_ret_type = suggested
    end

    error("""
        @irust cannot give this snippet one return type.

        Code: $code

        rustc typed its value as `$(rust_ret_type)`, but the snippet does not
        type-check as a function returning it:

        $(confirmation.rendered)
        Tip: every path has to produce the same value. An `if` with no `else`
        falls through to `()`, so `if cond { return x; }` needs an `else` (or a
        trailing expression). Use rust\"\"\"...\"\"\" with `@rust` for anything
        that needs more than one expression's worth of context.
        """)
end

"""
    _irust_signature(expanded, func_name) -> RustFunctionSignature

The one signature an `@irust` expansion describes.

`_generate_irust_function` emits exactly one `#[julia]` item, so the manifest
must report exactly one exported, non-generic function, and its `symbol` is the
wrapper the call goes through. Anything else means the snippet smuggled items
of its own into the block — which `@irust` does not support — and is refused
here rather than guessed at.
"""
function _irust_signature(expanded, func_name::String)
    sigs = manifest_function_signatures(expanded.manifest)
    matching = [sig for sig in sigs
                if sig.name == func_name && sig.exported && !sig.is_generic]
    length(matching) == 1 || error("""
        @irust could not identify the function it generated.

        The expansion reported $(length(matching)) exported functions named
        `$(func_name)` (of $(length(sigs)) in total). @irust compiles a single
        expression; define items of your own with rust\"\"\"...\"\"\" instead.
        """)
    return only(matching)
end

"""
    _irust_return_type(sig, code) -> Type

The Julia type an `@irust` result is read back as, taken from the manifest of
the expansion that was compiled — never guessed a second time.

`@irust` supports a single by-value scalar (or `()`); a `String`,
`Result`/`Option` or aggregate return is refused here with a message that points
at `rust\"\"\"`, because the generated wrapper for those returns a buffer or a
`CResult_*` struct that `_call_irust_function` has no way to decode.

The accepted spellings are `IRUST_SCALAR_RUST_TYPES` — the exact set `@irust`
accepts as *arguments*, and the set the documentation promises — not everything
the FFI contract can pass by value. The difference is `i128` / `u128`: the
contract knows them, but they do not round-trip on
`x86_64-pc-windows-msvc` (rust-lang/rust#54341), and only the argument side
refused them before (Codex review of PR #354).
"""
function _irust_return_type(sig, code::String)
    unsupported(what) = error("""
        @irust cannot return $(what).

        Code: $code
        Rust return type: $(sig.return_type)

        @irust handles one by-value scalar — Int8…Int64, UInt8…UInt64, Float32,
        Float64, Bool — and `()`. Use rust\"\"\"...\"\"\" with `@rust` for a
        String, a Result/Option, a struct or a 128-bit integer: those get a
        generated wrapper that knows how to decode them.
        """)
    sig.return_kind === :unit && return Nothing
    sig.return_kind === :plain || unsupported("a $(sig.return_kind) value")
    sig.return_type in IRUST_SCALAR_RUST_TYPES || unsupported("`$(sig.return_type)`")
    # Belt and braces: the spelling is in the table, so the contract must agree
    # that it travels in one by-value slot.
    c = ffi_return_contract(sig.return_type; abi = sig.return_abi)
    (c.known && (c.abi === :by_value || c.abi === :void)) ||
        unsupported("`$(sig.return_type)`")
    return rusttype_to_julia(sig.return_type)
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
    if haskey(IRUST_SCALAR_TYPES, julia_type)
        return IRUST_SCALAR_TYPES[julia_type]
    end
    error("Unsupported Julia type for @irust: $julia_type")
end

"""
    IRUST_SCALAR_TYPES :: Base.ImmutableDict{Type, String}

The scalars `@irust` passes and returns, Julia type to Rust spelling — the
whole surface, and the same table for both directions so an argument type and a
result type cannot drift apart.

It stops at 64 bits deliberately. `i128` / `u128` *are* known by-value types in
the FFI contract, but they do not round-trip on `x86_64-pc-windows-msvc`: MSVC
has no native 128-bit integer, so Rust and Julia disagree on how `extern "C"`
passes one (rust-lang/rust#54341, and the note above the primitives table in
`src/ffi_contract.jl`). Nothing stopped a snippet like `@irust("1i128")` from
reaching the `ccall` through the *return* path, since the probe would name
`i128` and the contract would accept it — a platform ABI mismatch rather than a
wrong answer (Codex review of PR #354).
"""
const IRUST_SCALAR_TYPES = Base.ImmutableDict(Base.ImmutableDict{Type, String}(),
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

"""
    IRUST_SCALAR_RUST_TYPES :: Tuple

The Rust spellings `IRUST_SCALAR_TYPES` covers, for checking a *result*. `()`
is accepted separately: a snippet whose value is unit returns `nothing`.
"""
const IRUST_SCALAR_RUST_TYPES = Tuple(values(IRUST_SCALAR_TYPES))

"""
    _rust_to_julia_type(rust_type::String) -> Type

Convert Rust type string to Julia type.
"""
function _rust_to_julia_type(rust_type::String)
    return rusttype_to_julia(rust_type)
end

"""
    _generate_irust_function(func_name::String, code::String, arg_types::Vector{String}, ret_type::String) -> String

The `#[julia]` item an `@irust` snippet becomes: the snippet **verbatim** as the
body of a function taking `arg1`, `arg2`, … .

Two things follow from that, and both were bugs before #346/#349:

- the snippet is Rust's to interpret, so a trailing expression is the value, an
  explicit `return` works, and `let` bindings, loops and multi-line snippets
  need no special case. The old code closed the body by looking at the first
  word — anything not starting with `return` was wrapped whole as
  `return <snippet>;`, which turned `let t = …; t + 1` into non-Rust, while a
  snippet that *did* start with `return` was emitted as-is and so had to be a
  single statement (#349);
- the item is `#[julia]`, not a hand-written `#[no_mangle] pub extern \"C\"`,
  so `expand_inline` generates the wrapper around it: the `catch_unwind`
  boundary and the thread-local panic channel every other RustCall entry point
  has. Without them an unwind crossing the `extern \"C\"` frame aborted the
  process (#346).
"""
function _generate_irust_function(func_name::String, code::String, arg_types::Vector{String}, ret_type::String)
    params_str = join(("arg$(i): $(t)" for (i, t) in enumerate(arg_types)), ", ")
    # Built by concatenation rather than a triple-quoted literal: the snippet
    # goes in exactly as the user wrote it, indentation and all.
    return string("#[julia]\npub fn ", func_name, "(", params_str, ") -> ", ret_type,
                  " {\n", code, "\n}\n")
end

"""
    _call_irust_function(lib_name::String, symbol::String, ret_type::Type, args...)

Call a compiled `@irust` snippet with Julia arguments.

`symbol` is the **exported symbol of the generated wrapper**
(`rustcall_irust_func_<id>`, from the manifest), not the Rust function name:
that wrapper is the one with the `catch_unwind` boundary, and its thread-local
panic channel is what `guard_rust_panic_ptr` reads here. Before #346 the symbol
was a hand-written `extern \"C\"` entry point with no boundary at all, so the
channel this always consulted was never written and a panic aborted the
process instead.

The pointer and the channel come from **one** `resolve_call_target` snapshot,
and nothing that can yield sits between the call and the channel read — the
channel is a thread-local (#244, #277).

# Error Handling
Provides improved error messages for function call failures.
"""
function _call_irust_function(lib_name::String, func_name::String, ret_type::Type, args...)
    try
        # One snapshot: pointer and panic channel from the same generation, so
        # an `@irust` snippet reloaded under this call cannot have its result
        # read against another generation's channel (#244, #277).
        target = resolve_call_target(lib_name, func_name)

        # Call using the codegen infrastructure with explicit return type
        result = guard_rust_panic_ptr(
            call_rust_function(target.func_ptr, ret_type, args...),
            target.channel, func_name)

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
