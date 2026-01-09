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

# irust"" string literal implementation

"""
Registry for irust functions.
Maps function hash to (library name, function name).
"""
const IRUST_FUNCTIONS = Dict{UInt64, Tuple{String, String}}()

"""
    @irust(code, args...)

Execute Rust code at function scope.

This macro compiles Rust code into a temporary function and calls it.
Julia variables should be passed as arguments.

# Limitations (Phase 1)
- Single expression only
- Return type must be a basic type
- Compiled as a separate function
- Variables must be passed explicitly as arguments

# Example
```julia
function myfunc(x)
    @irust("arg1 * 2", x)
end
```

For more complex cases, use `rust""` to define functions explicitly.
"""
macro irust(code, args...)
    # Extract the code string
    code_str = isa(code, AbstractString) ? code : string(code)

    # Build the call expression
    return quote
        _compile_and_call_irust($code_str, $(map(esc, args)...))
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
    _compile_and_call_irust(code::String, args...)

Internal function to compile and execute Rust code at function scope.
"""
function _compile_and_call_irust(code::String, args...)
    # Generate a unique function name based on code and argument types
    arg_types = map(typeof, args)
    code_hash = hash((code, arg_types))
    func_name = "irust_func_$(string(code_hash, base=16))"

    # Check if already compiled
    if haskey(IRUST_FUNCTIONS, code_hash)
        lib_name, cached_func_name = IRUST_FUNCTIONS[code_hash]
        return _call_irust_function(lib_name, cached_func_name, args...)
    end

    # Infer Rust types from Julia types
    rust_arg_types = collect(map(_julia_to_rust_type, arg_types))  # Ensure Vector

    # Infer return type from arguments (use first argument's type as default)
    if isempty(arg_types)
        rust_ret_type = "i64"
    else
        # Use the type of the first argument as return type (heuristic)
        rust_ret_type = rust_arg_types[1]
    end

    # Generate Rust function code
    rust_func_code = _generate_irust_function(func_name, code, rust_arg_types, rust_ret_type)

    # Compile and load
    wrapped_code = wrap_rust_code(rust_func_code)
    compiler = get_default_compiler()
    lib_path = compile_rust_to_shared_lib(wrapped_code; compiler=compiler)

    # Load the library
    lib_handle = Libdl.dlopen(lib_path, Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW)
    if lib_handle == C_NULL
        error("Failed to load compiled Rust library for irust: $lib_path")
    end

    # Generate a unique library name
    lib_name = "irust_$(string(code_hash, base=16))"
    RUST_LIBRARIES[lib_name] = (lib_handle, Dict{String, Ptr{Cvoid}}())
    IRUST_FUNCTIONS[code_hash] = (lib_name, func_name)

    # Call the function
    return _call_irust_function(lib_name, func_name, args...)
end

"""
    _julia_to_rust_type(julia_type::Type) -> String

Convert Julia type to Rust type string.
"""
function _julia_to_rust_type(julia_type::Type)
    if julia_type == Int32
        return "i32"
    elseif julia_type == Int64
        return "i64"
    elseif julia_type == Float32
        return "f32"
    elseif julia_type == Float64
        return "f64"
    elseif julia_type == Bool
        return "bool"
    elseif julia_type == Int8
        return "i8"
    elseif julia_type == Int16
        return "i16"
    elseif julia_type == UInt8
        return "u8"
    elseif julia_type == UInt16
        return "u16"
    elseif julia_type == UInt32
        return "u32"
    elseif julia_type == UInt64
        return "u64"
    else
        return "i64"  # Default
    end
end

"""
    _rust_to_julia_type(rust_type::String) -> Type

Convert Rust type string to Julia type.
"""
function _rust_to_julia_type(rust_type::String)
    return rusttype_to_julia(Symbol(rust_type))
end

"""
    _infer_return_type(code::String) -> String

Infer return type from Rust code.
This is a simplified heuristic for Phase 1.
"""
function _infer_return_type(code::String)
    # Look for return statements or final expressions
    if occursin(r"return\s+[0-9]", code) || occursin(r"\b[0-9]+\s*$", code)
        return "i32"
    elseif occursin(r"return\s+[0-9]+\.[0-9]", code) || occursin(r"\b[0-9]+\.[0-9]+\s*$", code)
        return "f64"
    elseif occursin(r"return\s+(true|false)", code) || occursin(r"\b(true|false)\s*$", code)
        return "bool"
    else
        # Default to i64
        return "i64"
    end
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
    _call_irust_function(lib_name::String, func_name::String, args...)

Call an irust function with Julia arguments.
"""
function _call_irust_function(lib_name::String, func_name::String, args...)
    # Get function pointer
    func_ptr = get_function_pointer(lib_name, func_name)

    # Infer return type from first argument (simplified heuristic)
    # This should match the type used during compilation
    if isempty(args)
        ret_type = Cvoid
    else
        first_arg_type = typeof(first(args))
        # Use the same type as first argument for return type (heuristic)
        ret_type = first_arg_type
    end

    # Call using the codegen infrastructure
    return call_rust_function(func_ptr, ret_type, args...)
end
