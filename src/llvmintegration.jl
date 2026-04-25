# LLVM.jl integration for RustCall.jl

using LLVM

"""
    RustModule

A wrapper around an LLVM module containing compiled Rust code.
"""
mutable struct RustModule
    ctx::LLVM.Context
    mod::LLVM.Module
    source_code::String
    functions::Dict{String, LLVM.Function}
    ir_file::String
end

# Registry of loaded Rust modules (keyed by SHA256 hash of IR content)
const RUST_MODULES = Dict{String, RustModule}()

# Lock for thread-safe access to LLVM registries (RUST_MODULES
# and LLVM_FUNCTION_REGISTRY in llvmcodegen.jl)
const LLVM_REGISTRY_LOCK = ReentrantLock()

const LLVM_IR_PARSE_UNSUPPORTED_ATTRIBUTES = Set([
    "nocreateundeforpoison",
])

function sanitize_unsupported_llvm_ir_attributes(ir_content::String)
    removed = String[]
    lines = split(ir_content, '\n'; keepempty=true)

    sanitized_lines = map(lines) do line
        m = match(r"^(\s*attributes\s+#\d+\s*=\s*\{)(.*)(\}\s*)$", line)
        m === nothing && return line

        prefix, body, suffix = m.captures
        tokens = split(body)
        kept = String[]

        for token in tokens
            if token in LLVM_IR_PARSE_UNSUPPORTED_ATTRIBUTES
                push!(removed, token)
            else
                push!(kept, token)
            end
        end

        if isempty(kept)
            return prefix * suffix
        end
        return prefix * " " * join(kept, " ") * " " * suffix
    end

    return join(sanitized_lines, "\n"), unique(removed)
end

function parse_llvm_module_with_fallback(ir_content::String)
    try
        return parse(LLVM.Module, ir_content), ir_content
    catch original_error
        sanitized_content, removed_attributes = sanitize_unsupported_llvm_ir_attributes(ir_content)
        if isempty(removed_attributes) || sanitized_content == ir_content
            rethrow(original_error)
        end

        try
            mod = parse(LLVM.Module, sanitized_content)
            @debug "Sanitized unsupported LLVM IR attributes before parsing" attributes = removed_attributes
            return mod, sanitized_content
        catch retry_error
            error("Failed to parse LLVM IR after removing unsupported attributes $(removed_attributes): $retry_error; original error: $original_error")
        end
    end
end

"""
    load_llvm_ir(ir_file::String) -> RustModule

Load an LLVM IR file and create a RustModule.
"""
function load_llvm_ir(ir_file::String; source_code::String = "")
    # Read the IR file
    ir_content = read(ir_file, String)

    # Create a context and activate it before parsing (#164).
    # This ensures the context and module share the same lifecycle.
    ctx = LLVM.Context()
    LLVM.activate(ctx)
    parsed_ir_content = ir_content
    mod = try
        mod, parsed_ir_content = parse_llvm_module_with_fallback(ir_content)
        mod
    catch e
        LLVM.deactivate(ctx)
        try
            dispose(ctx)
        catch
        end
        error("Failed to parse LLVM IR: $e")
    end
    LLVM.deactivate(ctx)

    # Extract functions
    functions = Dict{String, LLVM.Function}()
    for fn in LLVM.functions(mod)
        fn_name = LLVM.name(fn)
        # Skip internal/intrinsic functions
        if !isempty(fn_name) && !startswith(fn_name, "llvm.")
            functions[fn_name] = fn
        end
    end

    rust_mod = RustModule(ctx, mod, source_code, functions, ir_file)

    # Register in the global registry using SHA256 of IR content to avoid hash collisions
    mod_hash = bytes2hex(sha256(parsed_ir_content))
    lock(LLVM_REGISTRY_LOCK) do
        RUST_MODULES[mod_hash] = rust_mod
    end

    return rust_mod
end

"""
    get_function(mod::RustModule, name::String) -> Union{LLVM.Function, Nothing}

Get a function by name from the RustModule.
"""
function get_function(mod::RustModule, name::String)
    return get(mod.functions, name, nothing)
end

"""
    list_functions(mod::RustModule) -> Vector{String}

List all exported function names in the module.
"""
function list_functions(mod::RustModule)
    return collect(keys(mod.functions))
end

"""
    get_function_signature(fn::LLVM.Function) -> Tuple{Type, Vector{Type}}

Get the Julia return type and argument types for an LLVM function.
"""
function get_function_signature(fn::LLVM.Function)
    fn_type = LLVM.function_type(fn)

    # Get return type
    ret_llvm_type = LLVM.return_type(fn_type)
    ret_julia_type = llvm_type_to_julia(ret_llvm_type)

    # Get argument types
    arg_julia_types = Type[]
    for param_type in LLVM.parameters(fn_type)
        push!(arg_julia_types, llvm_type_to_julia(param_type))
    end

    return (ret_julia_type, arg_julia_types)
end

"""
    llvm_type_to_julia(llvm_type::LLVM.LLVMType) -> Type

Convert an LLVM type to the corresponding Julia type.
Uses LLVM.jl 9.x API which uses concrete types for different LLVM types.
"""
llvm_type_to_julia(::LLVM.VoidType) = Cvoid
llvm_type_to_julia(::LLVM.LLVMFloat) = Float32
llvm_type_to_julia(::LLVM.LLVMDouble) = Float64

function llvm_type_to_julia(llvm_type::LLVM.IntegerType)
    width = LLVM.width(llvm_type)
    if width == 1
        return Bool
    elseif width == 8
        return Int8
    elseif width == 16
        return Int16
    elseif width == 32
        return Int32
    elseif width == 64
        return Int64
    elseif width == 128
        return Int128
    else
        error("Unsupported integer width: $width")
    end
end

function llvm_type_to_julia(llvm_type::LLVM.PointerType)
    # Try to preserve inner type information when available (#182)
    inner_type = try
        eltype = LLVM.eltype(llvm_type)
        llvm_type_to_julia(eltype)
    catch
        Cvoid
    end
    return Ptr{inner_type}
end

# For structs/arrays, return generic pointers for now.
llvm_type_to_julia(::LLVM.StructType) = Ptr{Cvoid}
llvm_type_to_julia(::LLVM.ArrayType) = Ptr{Cvoid}

function llvm_type_to_julia(llvm_type::LLVM.LLVMType)
    type_str = string(typeof(llvm_type))
    error("Unsupported LLVM type: $type_str")
end

"""
    julia_type_to_llvm(julia_type::Type) -> LLVM.LLVMType

Convert a Julia type to the corresponding LLVM type.
Note: Must be called within an active LLVM context (use LLVM.Context() do ... end).
"""
julia_type_to_llvm(::Type{Cvoid}) = LLVM.VoidType()  # Cvoid === Nothing
julia_type_to_llvm(::Type{Bool}) = LLVM.IntType(1)
julia_type_to_llvm(::Type{<:Union{Int8, UInt8}}) = LLVM.IntType(8)
julia_type_to_llvm(::Type{<:Union{Int16, UInt16}}) = LLVM.IntType(16)
julia_type_to_llvm(::Type{<:Union{Int32, UInt32}}) = LLVM.IntType(32)
julia_type_to_llvm(::Type{<:Union{Int64, UInt64}}) = LLVM.IntType(64)
julia_type_to_llvm(::Type{<:Union{Int128, UInt128}}) = LLVM.IntType(128)
julia_type_to_llvm(::Type{Float32}) = LLVM.FloatType()
julia_type_to_llvm(::Type{Float64}) = LLVM.DoubleType()

function julia_type_to_llvm(julia_type::Type{<:Ptr})
    # Preserve inner type information when possible (#182)
    inner = eltype(julia_type)
    if inner == Cvoid
        return LLVM.PointerType(LLVM.IntType(8))
    else
        inner_llvm = try
            julia_type_to_llvm(inner)
        catch
            LLVM.IntType(8)
        end
        return LLVM.PointerType(inner_llvm)
    end
end

function julia_type_to_llvm(julia_type::Type)
    error("Unsupported Julia type for LLVM: $julia_type")
end

# Keep the old signature for backward compatibility (ignore ctx)
julia_type_to_llvm(ctx::LLVM.Context, julia_type::Type) = julia_type_to_llvm(julia_type)

"""
    dispose_module(mod::RustModule)

Dispose of the LLVM resources associated with a RustModule.
"""
function dispose_module(mod::RustModule)
    lock(LLVM_REGISTRY_LOCK) do
        # Remove from cache
        for (k, v) in RUST_MODULES
            if v === mod
                delete!(RUST_MODULES, k)
                break
            end
        end

        # Clean up temporary files
        if isfile(mod.ir_file)
            try
                rm(dirname(mod.ir_file), recursive=true, force=true)
            catch
            end
        end

        # Dispose LLVM resources inside the lock to prevent race conditions (#167)
        dispose(mod.mod)
        dispose(mod.ctx)
    end
end

"""
    get_or_compile_function(mod::RustModule, name::String) -> Ptr{Cvoid}

Get a compiled function pointer, compiling if necessary using Julia's JIT.

# Arguments
- `mod::RustModule`: The Rust module containing the function
- `name::String`: Name of the function to compile

# Returns
- `Ptr{Cvoid}`: Function pointer to the compiled function

# Note
This function is a placeholder for future LLVM JIT compilation support.
Currently, it raises an error indicating that direct LLVM JIT compilation
is not yet implemented. Use the shared library approach instead.

# Example
```julia
mod = load_llvm_ir("path/to/file.ll")
# Note: This will raise an error until JIT compilation is implemented
# func_ptr = get_or_compile_function(mod, "my_function")
```
"""
function get_or_compile_function(mod::RustModule, name::String)
    fn = get_function(mod, name)
    if fn === nothing
        error("Function '$name' not found in module")
    end

    # LLVM IR -> llvmcall integration requires more work
    # This is a placeholder for future LLVM JIT compilation
    error("Direct LLVM JIT compilation not yet implemented. Use shared library approach.")
end
