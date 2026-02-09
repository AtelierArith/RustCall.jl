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
        # First, try the specified library
        if haskey(RUST_LIBRARIES, lib_name)
            lib_handle, func_cache = RUST_LIBRARIES[lib_name]

            # Check cache first
            if haskey(func_cache, func_name)
                return func_cache[func_name]
            end

            # Look up the function
            func_ptr = Libdl.dlsym(lib_handle, func_name; throw_error=false)
            if func_ptr !== nothing && func_ptr != C_NULL
                # Cache it
                func_cache[func_name] = func_ptr
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

            # Check cache first
            if haskey(other_func_cache, func_name)
                push!(found_libs, other_lib_name)
                found_ptr = other_func_cache[func_name]
                continue
            end

            # Look up the function
            func_ptr = Libdl.dlsym(other_lib_handle, func_name; throw_error=false)
            if func_ptr !== nothing && func_ptr != C_NULL
                # Cache it
                other_func_cache[func_name] = func_ptr
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
    # Phase 5: Transform #[julia] attributes FIRST for macro expansion
    # This converts #[julia] pub struct -> #[derive(JuliaStruct)] pub struct
    transformed_code = transform_julia_attribute(code)

    # Phase 4: Detect structs and generate Julia-side wrappers at macro expansion time
    # (after #[julia] transformation so #[julia] pub struct is detected)
    struct_infos = parse_structs_and_impls(transformed_code)
    julia_defs = [emit_julia_definitions(info) for info in struct_infos]

    # Phase 5: Detect #[julia] attributed functions and generate wrappers
    julia_func_signatures = parse_julia_functions(code)
    julia_func_wrappers = emit_julia_function_wrappers(julia_func_signatures)

    return quote
        lib_name = _compile_and_load_rust($(esc(code)), $(string(__source__.file)), $(__source__.line))

        # Store library information in the calling module for precompilation support
        if !isdefined($__module__, :__RUSTCALL_LIBS)
            # Use Core.eval to define the constant if it doesn't exist
            # Note: We use a Dict to support multiple blocks
            @eval $__module__ const __RUSTCALL_LIBS = Dict{String, String}()
        end
        $__module__.__RUSTCALL_LIBS[lib_name] = $(esc(code))

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
    ensure_loaded(lib_name::String, code::String)

Ensure that a Rust library is loaded in the current session.
Useful for precompiled modules that need to reload libraries at runtime.
"""
function ensure_loaded(lib_name::String, code::String)
    needs_reload = lock(REGISTRY_LOCK) do
        !haskey(RUST_LIBRARIES, lib_name)
    end
    if needs_reload
        _compile_and_load_rust(code, "reload", 0)
    end
    return nothing
end

"""
    _compile_and_load_rust(code::String, source_file::String, source_line::Int)

Internal function to compile Rust code and load the resulting shared library.
Uses caching to avoid recompilation when possible.

Phase 3: Automatically detects dependencies in the code and uses Cargo for building
when external crates are required.
"""
function _compile_and_load_rust(code::String, source_file::String, source_line::Int)
    # Phase 3: Check for dependencies in the code
    if has_dependencies(code)
        return _compile_and_load_rust_with_cargo(code, source_file, source_line)
    end

    # Phase 5: Transform #[julia] attributes FIRST
    # - #[julia] fn -> #[no_mangle] pub extern "C" fn
    # - #[julia] pub struct -> #[derive(JuliaStruct)] pub struct
    transformed_code = transform_julia_attribute(code)

    # Phase 4: Detect structs and generate wrappers (after #[julia] transformation)
    struct_infos = parse_structs_and_impls(transformed_code)

    # Remove #[derive(JuliaStruct)] attributes from code before compilation
    # (JuliaStruct is not a real Rust macro, so it would cause compilation errors)
    cleaned_code = remove_derive_julia_struct_attributes(transformed_code)

    augmented_code = cleaned_code
    for info in struct_infos
        augmented_code *= generate_struct_wrappers(info)
    end

    # Original implementation for dependency-free code
    # Wrap the code if needed
    wrapped_code = wrap_rust_code(augmented_code)

    # Generate cache key
    compiler = get_default_compiler()
    cache_key = generate_cache_key(wrapped_code, compiler)

    # Generate a unique library name based on a deterministic code hash
    # Use SHA256 instead of hash() which is randomized per Julia session
    code_hash = bytes2hex(sha256(wrapped_code))[1:16]
    lib_name = "rust_$(code_hash)"

    # Check if already compiled and loaded in memory
    lock(REGISTRY_LOCK) do
        if haskey(RUST_LIBRARIES, lib_name)
            CURRENT_LIB[] = lib_name

            # Ensure generic functions are registered (dictionary is volatile)
            try
                _detect_and_register_generic_functions(wrapped_code, lib_name)
            catch e
                @debug "Failed to register generic functions from memory: $e"
            end

            # Register function signatures from memory
            try
                _register_function_signatures(code, lib_name)
            catch e
                @debug "Failed to register function signatures from memory: $e"
            end

            return lib_name
        end
    end

    # Check cache first
    cached_lib = get_cached_library(cache_key)
    if cached_lib !== nothing && is_cache_valid(cache_key, wrapped_code, compiler)
        # Load from cache
        lib_handle, _ = load_cached_library(cache_key)

        # Register the library
        lock(REGISTRY_LOCK) do
            RUST_LIBRARIES[lib_name] = (lib_handle, Dict{String, Ptr{Cvoid}}())
            CURRENT_LIB[] = lib_name

        end

        # Try to detect and register generic functions from the cached code
        try
            _detect_and_register_generic_functions(wrapped_code, lib_name)
        catch e
            @debug "Failed to detect generic functions from cache: $e"
        end

        # Register function signatures from cached code
        try
            _register_function_signatures(code, lib_name)
        catch e
            @debug "Failed to register function signatures from cache: $e"
        end

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
            bytes2hex(sha256(wrapped_code)),
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

    # Register the library
    lock(REGISTRY_LOCK) do
        RUST_LIBRARIES[lib_name] = (lib_handle, Dict{String, Ptr{Cvoid}}())
        CURRENT_LIB[] = lib_name
    end

    # Temporarily disabled LLVM IR loading for stability
    # (LLVM IR is used for type inference and @rust_llvm)

    # Detect and register generic functions
    try
        _detect_and_register_generic_functions(code, lib_name)
    catch e
        @debug "Failed to detect generic functions: $e"
    end

    # Register non-generic functions with their signatures
    try
        _register_function_signatures(code, lib_name)
    catch e
        @debug "Failed to register function signatures: $e"
    end

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
function _compile_and_load_rust_with_cargo(code::String, source_file::String, source_line::Int)
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

    # Phase 5: Transform #[julia] attributes FIRST
    transformed_code = transform_julia_attribute(code)

    # Phase 4: Detect structs and generate wrappers (after #[julia] transformation)
    struct_infos = parse_structs_and_impls(transformed_code)

    # Remove #[derive(JuliaStruct)] attributes from code before compilation
    cleaned_code = remove_derive_julia_struct_attributes(transformed_code)

    augmented_code = cleaned_code
    for info in struct_infos
        augmented_code *= generate_struct_wrappers(info)
    end

    # Generate hashes for caching based on the code to be compiled
    # Use SHA256 instead of hash() which is randomized per Julia session
    code_hash = bytes2hex(sha256(augmented_code))
    deps_hash = hash_dependencies(dependencies)

    # Project and library names
    project_name = "rustcall_$(code_hash[1:12])"
    lib_name = "rust_cargo_$(code_hash[1:16])"

    # Check if already compiled and loaded in memory
    is_in_memory = lock(REGISTRY_LOCK) do
        haskey(RUST_LIBRARIES, lib_name)
    end
    if is_in_memory
        lock(REGISTRY_LOCK) do
            CURRENT_LIB[] = lib_name
        end
        @debug "Using cached Cargo library from memory" lib_name=lib_name

        # Ensure generic functions are registered
        try
            clean_code = remove_dependency_comments(code)
            _detect_and_register_generic_functions(clean_code, lib_name)
        catch e
            @debug "Failed to register generic functions from memory cache: $e"
        end

        # Register function signatures from memory cache
        try
            _register_function_signatures(code, lib_name)
        catch e
            @debug "Failed to register function signatures from memory cache: $e"
        end

        return lib_name
    end

    cache_key_data = "$(code_hash)_$(deps_hash)_release"
    cache_key = bytes2hex(sha256(cache_key_data))[1:32]

    cached_lib = get_cargo_cached_library(cache_key)
    if !isnothing(cached_lib) && isfile(cached_lib)
        # Load from cache
        lib_handle = Libdl.dlopen(cached_lib, Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW)
        if lib_handle != C_NULL
            lock(REGISTRY_LOCK) do
                RUST_LIBRARIES[lib_name] = (lib_handle, Dict{String, Ptr{Cvoid}}())
                CURRENT_LIB[] = lib_name
            end
            @debug "Loaded Cargo library from cache" lib_name=lib_name cache_key=cache_key[1:8]

            # Ensure generic functions are registered
            try
                clean_code = remove_dependency_comments(code)
                _detect_and_register_generic_functions(clean_code, lib_name)
            catch e
                @debug "Failed to register generic functions from disk cache: $e"
            end

            # Register function signatures from disk cache
            try
                _register_function_signatures(code, lib_name)
            catch e
                @debug "Failed to register function signatures from disk cache: $e"
            end

            return lib_name
        end
    end

    # Build necessary if not in cache or cache load failed
    @info "Building Rust code with external dependencies..." dependencies=length(dependencies) project=project_name

    project = create_cargo_project(project_name, dependencies)

    try
        # Ensure the code with wrappers is written to the project
        write_rust_code_to_project(project, augmented_code)

        lib_path = build_cargo_project_cached(project, code_hash, release=true)

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

        # Register the library
        lock(REGISTRY_LOCK) do
            RUST_LIBRARIES[lib_name] = (lib_handle, Dict{String, Ptr{Cvoid}}())
            CURRENT_LIB[] = lib_name
        end

        @info "Successfully built Rust code with Cargo" lib_name=lib_name

        # Try to detect and register generic functions
        clean_code = remove_dependency_comments(code)
        try
            _detect_and_register_generic_functions(clean_code, lib_name)
        catch e
            @debug "Failed to detect generic functions: $e"
        end

        # Register non-generic function signatures
        try
            _register_function_signatures(code, lib_name)
        catch e
            @debug "Failed to register function signatures: $e"
        end
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
    extract_function_code(code::String, func_name::String) -> Union{String, Nothing}

Extract the full code for a function from Rust source code.
"""
function extract_function_code(code::String, func_name::String)
    # Find function start - improved to handle nested brackets
    func_start_pattern = Regex("fn\\s+$func_name.*?\\{", "s")
    m = match(func_start_pattern, code)

    if m === nothing
        return nothing
    end

    start_idx = m.offset
    code_after_start = code[start_idx:end]

    # Find matching closing brace
    brace_count = 0
    in_string = false
    string_char = nothing

    for (i, char) in enumerate(code_after_start)
        if char == '"' || char == '\''
            if !in_string
                in_string = true
                string_char = char
            elseif char == string_char
                in_string = false
                string_char = nothing
            end
        elseif !in_string
            if char == '{'
                brace_count += 1
            elseif char == '}'
                brace_count -= 1
                if brace_count == 0
                    return String(code_after_start[1:i])
                end
            end
        end
    end

    return nothing
end

"""
    _detect_and_register_generic_functions(code::String, lib_name::String)

Detect generic functions in Rust code and register them for monomorphization.
"""
function _detect_and_register_generic_functions(code::String, lib_name::String)
    func_pattern = r"(?:#\[no_mangle\])?\s*(?:pub\s+)?(?:extern\s+\"C\"\s+)?fn\s+(\w+)\s*<(.+?)>\s*\("

    for m in eachmatch(func_pattern, code)
        func_name = String(m.captures[1])
        type_params_str = m.captures[2]

        # Check if this is a generic function
        if type_params_str !== nothing && !isempty(type_params_str)
            # Extract type parameters
            type_params = Symbol[]
            for param in split(type_params_str, ',', keepempty=false)
                param = strip(param)
                # Handle trait bounds: T: Copy + Clone -> just T
                if occursin(':', param)
                    param = split(param, ':')[1]
                end
                push!(type_params, Symbol(strip(param)))
            end

            # Extract the full function code
            func_code = extract_function_code(code, func_name)

            if func_code === nothing
                func_code = code
            end

            # Register as generic function
            register_generic_function(func_name, func_code, type_params)
            @info "Registered generic function: $func_name" type_params=type_params
        end
    end
end


"""
    _parse_function_return_type(code::String, func_name::String) -> Union{Type, Nothing}

Parse the return type of a function from Rust code.
Returns the Julia type corresponding to the Rust return type, or nothing if not found.
"""
function _parse_function_return_type(code::String, func_name::String)
    # Pattern to match: pub extern "C" fn func_name(...) -> return_type {
    # or: #[no_mangle] pub extern "C" fn func_name(...) -> return_type {
    pattern = Regex("(?:#\\[no_mangle\\]\\s*)?(?:pub\\s+)?(?:extern\\s+\"C\"\\s+)?fn\\s+$func_name\\s*\\([^)]*\\)\\s*->\\s*([\\w:<>,\\s\\[\\]]+)", "s")
    m = match(pattern, code)

    if m === nothing
        return nothing
    end

    ret_type_str = strip(m.captures[1])

    # Map Rust type to Julia type
    rust_to_julia = Dict(
        "i8" => Int8, "i16" => Int16, "i32" => Int32, "i64" => Int64,
        "u8" => UInt8, "u16" => UInt16, "u32" => UInt32, "u64" => UInt64,
        "f32" => Float32, "f64" => Float64,
        "bool" => Bool,
        "()" => Cvoid,
    )

    # Remove generic parameters if present (e.g., "Box<T>" -> "Box")
    if occursin('<', ret_type_str)
        ret_type_str = split(ret_type_str, '<')[1]
    end

    ret_type_str = strip(ret_type_str)

    if haskey(rust_to_julia, ret_type_str)
        return rust_to_julia[ret_type_str]
    end

    return nothing
end

"""
    _register_function_signatures(code::String, lib_name::String)

Register function return types from Rust code for type inference.
"""
function _register_function_signatures(code::String, lib_name::String)
    # Pattern to match function definitions: pub extern "C" fn name(...) -> type {
    # or: #[no_mangle] pub extern "C" fn name(...) -> type {
    # Use a simpler pattern that matches the function signature more reliably
    pattern = Regex("(?:#\\[no_mangle\\]\\s*)?(?:pub\\s+)?(?:extern\\s+\"C\"\\s+)?fn\\s+(\\w+)\\s*\\([^)]*\\)(?:\\s*->\\s*([\\w:<>,\\s\\[\\]]+))?", "s")

    for m in eachmatch(pattern, code)
        func_name = String(m.captures[1])
        ret_type_str = length(m.captures) >= 2 && m.captures[2] !== nothing ? String(m.captures[2]) : nothing

        # Skip if already registered in FUNCTION_REGISTRY or is generic
        if haskey(FUNCTION_REGISTRY, func_name) || is_generic_function(func_name)
            continue
        end

        # Parse return type.
        # Functions without an explicit return type in Rust default to `()`,
        # which maps to `Cvoid` on the Julia FFI boundary.
        ret_type = Cvoid
        if ret_type_str !== nothing && !isempty(strip(ret_type_str))
            parsed = _parse_function_return_type(code, func_name)
            if parsed === nothing
                continue
            end
            ret_type = parsed
        end

        # Update both library-scoped and global fallback registries.
        FUNCTION_RETURN_TYPES_BY_LIB[(lib_name, func_name)] = ret_type
        FUNCTION_RETURN_TYPES[func_name] = ret_type
        @debug "Registered return type for function: $func_name => $ret_type (library: $lib_name)"
    end
end

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
Julia variables can be referenced using `\$var` syntax or passed as arguments.

# Features
- Automatic variable binding with `\$var` syntax
- Improved type inference from code
- Better error messages

# Examples
```julia
# Using \$var syntax (recommended)
function myfunc(x)
    @irust("\$x * 2")
end

# Using explicit arguments (legacy, still supported)
function myfunc(x)
    @irust("arg1 * 2", x)
end

# Multiple variables
function add_and_multiply(a, b, c)
    @irust("\$a + \$b * \$c")
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

Parse `\$var` syntax in irust code and extract variable names.
Returns (list of variable symbols, processed code with \$var replaced by argN).

# Example
```julia
vars, code = _parse_irust_variables("\$x + \$y * 2")
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

        # Check if already compiled
        if haskey(IRUST_FUNCTIONS, code_hash)
            lib_name, cached_func_name = IRUST_FUNCTIONS[code_hash]
            is_loaded = lock(REGISTRY_LOCK) do
                haskey(RUST_LIBRARIES, lib_name)
            end
            if is_loaded
                # Re-infer return type for cached function (should match original)
                rust_ret_type = _infer_return_type_improved(code, arg_types, rust_arg_types)
                julia_ret_type = _rust_to_julia_type(rust_ret_type)
                return _call_irust_function(lib_name, cached_func_name, julia_ret_type, args...)
            else
                # Stale cache entry: library was unloaded, so recompile transparently.
                delete!(IRUST_FUNCTIONS, code_hash)
            end
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

        # Generate a unique library name
        lib_name = "irust_$(string(code_hash, base=16))"
        lock(REGISTRY_LOCK) do
            RUST_LIBRARIES[lib_name] = (lib_handle, Dict{String, Ptr{Cvoid}}())
        end
        IRUST_FUNCTIONS[code_hash] = (lib_name, func_name)

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
