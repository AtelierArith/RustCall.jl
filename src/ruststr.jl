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
    get_current_library() -> String

Get the name of the currently active Rust library.
"""
function get_current_library()
    if isempty(CURRENT_LIB[])
        error("No Rust library loaded. Use rust\"\"\"...\"\"\" to compile and load Rust code first.")
    end
    return CURRENT_LIB[]
end

"""
    get_library_handle(name::String) -> Ptr{Cvoid}

Get the library handle for a named library.
"""
function get_library_handle(name::String)
    if !haskey(RUST_LIBRARIES, name)
        error("Library '$name' not found. Available: $(keys(RUST_LIBRARIES))")
    end
    return RUST_LIBRARIES[name][1]
end

"""
    get_function_pointer(lib_name::String, func_name::String) -> Ptr{Cvoid}

Get a function pointer from a loaded library.
"""
function get_function_pointer(lib_name::String, func_name::String)
    if !haskey(RUST_LIBRARIES, lib_name)
        error("Library '$lib_name' not found")
    end

    lib_handle, func_cache = RUST_LIBRARIES[lib_name]

    # Check cache first
    if haskey(func_cache, func_name)
        return func_cache[func_name]
    end

    # Look up the function
    func_ptr = Libdl.dlsym(lib_handle, func_name; throw_error=false)
    if func_ptr === nothing || func_ptr == C_NULL
        error("Function '$func_name' not found in library '$lib_name'")
    end

    # Cache it
    func_cache[func_name] = func_ptr
    return func_ptr
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
    return quote
        _compile_and_load_rust($(esc(code)), $(string(__source__.file)), $(__source__.line))
    end
end

"""
    _compile_and_load_rust(code::String, source_file::String, source_line::Int)

Internal function to compile Rust code and load the resulting shared library.
"""
function _compile_and_load_rust(code::String, source_file::String, source_line::Int)
    # Wrap the code if needed
    wrapped_code = wrap_rust_code(code)

    # Generate a unique library name based on the code hash
    code_hash = hash(wrapped_code)
    lib_name = "rust_$(string(code_hash, base=16))"

    # Check if already compiled and loaded
    if haskey(RUST_LIBRARIES, lib_name)
        CURRENT_LIB[] = lib_name
        return nothing
    end

    # Compile to shared library
    compiler = get_default_compiler()
    lib_path = compile_rust_to_shared_lib(wrapped_code; compiler=compiler)

    # Load the library
    lib_handle = Libdl.dlopen(lib_path, Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW)
    if lib_handle == C_NULL
        error("Failed to load compiled Rust library: $lib_path")
    end

    # Register the library
    RUST_LIBRARIES[lib_name] = (lib_handle, Dict{String, Ptr{Cvoid}}())
    CURRENT_LIB[] = lib_name

    # Also try to load LLVM IR for analysis (optional)
    try
        ir_path = compile_rust_to_llvm_ir(wrapped_code; compiler=compiler)
        rust_mod = load_llvm_ir(ir_path; source_code=wrapped_code)
        RUST_MODULE_REGISTRY[code_hash] = rust_mod
    catch e
        # LLVM IR loading is optional, don't fail if it doesn't work
        @debug "Failed to load LLVM IR for analysis: $e"
    end

    return nothing
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
    return collect(keys(RUST_LIBRARIES))
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
    if !haskey(RUST_LIBRARIES, lib_name)
        @warn "Library '$lib_name' not loaded"
        return
    end

    lib_handle, _ = RUST_LIBRARIES[lib_name]
    Libdl.dlclose(lib_handle)
    delete!(RUST_LIBRARIES, lib_name)

    if CURRENT_LIB[] == lib_name
        CURRENT_LIB[] = ""
    end
end

"""
    unload_all_libraries()

Unload all loaded Rust libraries.
"""
function unload_all_libraries()
    for lib_name in collect(keys(RUST_LIBRARIES))
        unload_library(lib_name)
    end
end
