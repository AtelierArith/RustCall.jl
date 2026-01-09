# Rust struct and impl parsing for Phase 4
# This module identifies structs and their methods for automatic wrapping.

"""
    RustMethod

Represents a Rust method found in an impl block.
"""
struct RustMethod
    name::String
    is_static::Bool        # true if no 'self'
    is_mutable::Bool       # true if '&mut self'
    arg_names::Vector{String}
    arg_types::Vector{String}
    return_type::String
end

"""
    RustStructInfo

Represents a Rust struct and its associated implementation.
"""
struct RustStructInfo
    name::String
    methods::Vector{RustMethod}
end

"""
    parse_structs_and_impls(code::String) -> Vector{RustStructInfo}

Heuristic parser to find pub structs and their impl blocks.
"""
function parse_structs_and_impls(code::String)
    structs = Dict{String, RustStructInfo}()

    # 1. Find all pub structs (only simple ones without generics for Phase 4)
    # Pattern: pub struct Name { ... } but NOT pub struct Name<T> { ... }
    # We look for name followed by { or ( to avoid generics <...>
    struct_pattern = r"pub\s+struct\s+([A-Z]\w*)\s*(?:\{|\()"
    for m in eachmatch(struct_pattern, code)
        name = String(m.captures[1])
        if !haskey(structs, name)
            structs[name] = RustStructInfo(name, RustMethod[])
        end
    end

    # 2. Find impl blocks
    # Pattern: impl Name { ... }
    # This is a bit tricky with regex, so we'll look for blocks
    impl_pattern = r"impl\s+([A-Z]\w*)\s*\{([\s\S]*?)\n\}"
    for m in eachmatch(impl_pattern, code)
        struct_name = String(m.captures[1])
        impl_body = m.captures[2]

        if haskey(structs, struct_name)
            methods = parse_methods_in_impl(impl_body)
            append!(structs[struct_name].methods, methods)
        end
    end

    return collect(values(structs))
end

"""
    parse_methods_in_impl(impl_body::AbstractString) -> Vector{RustMethod}

Parse function definitions inside an impl block.
"""
function parse_methods_in_impl(impl_body::AbstractString)
    methods = RustMethod[]

    # Pattern: pub fn name(args) -> ret {
    # Handles: &self, &mut self, self, and static methods
    fn_pattern = r"pub\s+fn\s+(\w+)\s*\(([\s\S]*?)\)(?:\s*->\s*([\w:<>, ]+))?\s*\{"

    for m in eachmatch(fn_pattern, impl_body)
        name = String(m.captures[1])
        args_str = m.captures[2]
        ret_type = m.captures[3] === nothing ? "()" : strip(String(m.captures[3]))

        is_static = !occursin("self", args_str)
        is_mutable = occursin("&mut self", args_str)

        # Simple arg parsing (ignoring self)
        arg_names = String[]
        arg_types = String[]

        for arg in split(args_str, ',')
            arg = strip(arg)
            if isempty(arg) || arg == "self" || arg == "&self" || arg == "&mut self"
                continue
            end

            # Pattern: name: type
            if occursin(':', arg)
                parts = split(arg, ':')
                push!(arg_names, strip(parts[1]))
                push!(arg_types, strip(parts[2]))
            end
        end

        push!(methods, RustMethod(name, is_static, is_mutable, arg_names, arg_types, ret_type))
    end

    return methods
end

"""
    generate_struct_wrappers(info::RustStructInfo) -> String

Generate "extern C" C-FFI wrappers for a given struct.
"""
function generate_struct_wrappers(info::RustStructInfo)
    io = IOBuffer()
    struct_name = info.name

    println(io, "\n// --- Auto-generated FFI wrappers for $struct_name ---")

    # Add a free function for the finalizer
    println(io, "#[no_mangle]")
    println(io, "pub extern \"C\" fn $(struct_name)_free(ptr: *mut $struct_name) {")
    println(io, "    if !ptr.is_null() {")
    println(io, "        unsafe { Box::from_raw(ptr); }")
    println(io, "    }")
    println(io, "}\n")

    for m in info.methods
        wrapper_name = "$(struct_name)_$(m.name)"

        # Special handling for 'new' or methods returning Self
        is_constructor = m.name == "new" || m.return_type == "Self" || m.return_type == struct_name

        println(io, "#[no_mangle]")

        # Build arguments list for the wrapper
        wrapper_args = String[]
        call_args = String[]

        if !m.is_static
            push!(wrapper_args, "ptr: " * (m.is_mutable ? "*mut " : "*const ") * struct_name)
            push!(call_args, "unsafe { &" * (m.is_mutable ? "mut " : "") * "*ptr }")
        end

        for (aname, atype) in zip(m.arg_names, m.arg_types)
            push!(wrapper_args, "$aname: $atype")
            push!(call_args, aname)
        end

        args_str = join(wrapper_args, ", ")
        call_params = join(call_args, ", ")

        if is_constructor
            println(io, "pub extern \"C\" fn $wrapper_name($args_str) -> *mut $struct_name {")
            println(io, "    let obj = $struct_name::$(m.name)($(join(m.arg_names, ", ")));")
            println(io, "    Box::into_raw(Box::new(obj))")
        else
            ret_decl = m.return_type == "()" ? "" : " -> $(m.return_type)"
            println(io, "pub extern \"C\" fn $wrapper_name($args_str)$ret_decl {")
            if m.is_static
                println(io, "    $struct_name::$(m.name)($(join(m.arg_names, ", ")))")
            else
                println(io, "    let self_obj = unsafe { &$(m.is_mutable ? "mut " : "") *ptr };")
                println(io, "    self_obj.$(m.name)($(join(m.arg_names, ", ")))")
            end
        end
        println(io, "}\n")
    end

    return String(take!(io))
end

"""
    emit_julia_definitions(info::RustStructInfo)

Generate Julia code to define a corresponding mutable struct and its methods.
"""
function emit_julia_definitions(info::RustStructInfo)
    # Use escaped symbols to ensure they are defined in the caller's scope
    struct_name_str = info.name
    esc_struct = esc(Symbol(struct_name_str))

    exprs = []

    # 1. Define the struct
    push!(exprs, quote
        mutable struct $esc_struct
            ptr::Ptr{Cvoid}
            lib_name::String # Store which library this object belongs to

            function $esc_struct(ptr::Ptr{Cvoid}, lib::String)
                obj = new(ptr, lib)
                finalizer(obj) do x
                    if x.ptr != C_NULL
                        # Call free through explicit library reference
                        _call_rust_free(x.lib_name, $(struct_name_str * "_free"), x.ptr)
                        x.ptr = C_NULL
                    end
                end
                return obj
            end
        end
    end)

    # 2. Add constructors and methods
    for m in info.methods
        fname = esc(Symbol(m.name))
        wrapper_name = struct_name_str * "_" * m.name

        is_ctor = m.name == "new" || m.return_type == "Self" || m.return_type == struct_name_str

        arg_names = [Symbol(an) for an in m.arg_names]
        esc_args = [esc(a) for a in arg_names]

        if m.is_static
            if is_ctor
                push!(exprs, quote
                    function (::Type{$esc_struct})($(esc_args...))
                        # Use runtime-resolved current library
                        lib = get_current_library()
                        ptr = _call_rust_constructor(lib, $wrapper_name, $(esc_args...))
                        return $esc_struct(ptr, lib)
                    end
                end)
            else
                # Static method: map return type
                jl_ret_type = rust_to_julia_type_sym(m.return_type)
                push!(exprs, quote
                    function $fname($(esc_args...))
                        lib = get_current_library()
                        return _call_rust_method(lib, $wrapper_name, C_NULL, $(esc_args...), $(QuoteNode(jl_ret_type)))
                    end
                end)
            end
        else
            # Instance method: map return type
            jl_ret_type = rust_to_julia_type_sym(m.return_type)
            push!(exprs, quote
                function $fname(self::$esc_struct, $(esc_args...))
                    # Call using the library the object was created with
                    return _call_rust_method(self.lib_name, $wrapper_name, self.ptr, $(esc_args...), $(QuoteNode(jl_ret_type)))
                end
            end)
        end
    end

    return Expr(:block, exprs...)
end

# Internal helpers to handle the calls with explicit library names
function _call_rust_free(lib_name::String, func_name::String, ptr::Ptr{Cvoid})
    try
        _rust_call_typed(lib_name, func_name, Cvoid, ptr)
    catch e
        @debug "Failed to call Rust free function $func_name in $lib_name: $e"
    end
end

function _call_rust_constructor(lib_name::String, func_name::String, args...)
    return _rust_call_typed(lib_name, func_name, Ptr{Cvoid}, args...)
end

function _call_rust_method(lib_name::String, func_name::String, ptr::Ptr{Cvoid}, args...)
    # Special case: return type passed as last argument
    ret_type = last(args)
    actual_args = args[1:end-1]

    # Convert Symbol back to Type if needed, but our _rust_call_typed and helpers
    # usually handle types. Let's resolve the symbol using a simple mapping.
    real_ret_type = julia_sym_to_type(ret_type)

    if ptr == C_NULL
        return _rust_call_typed(lib_name, func_name, real_ret_type, actual_args...)
    else
        return _rust_call_typed(lib_name, func_name, real_ret_type, ptr, actual_args...)
    end
end

function julia_sym_to_type(s::Symbol)
    m = Dict(
        :Float64 => Float64,
        :Float32 => Float32,
        :Int32 => Int32,
        :Int64 => Int64,
        :UInt32 => UInt32,
        :UInt64 => UInt64,
        :Bool => Bool,
        :Cvoid => Cvoid,
        :Any => Any
    )
    return get(m, s, Any)
end

"""
    rust_to_julia_type_sym(rust_type::String) -> Symbol

Map Rust type strings to Julia type symbols for code generation.
"""
function rust_to_julia_type_sym(rust_type::String)
    m = Dict(
        "f64" => :Float64,
        "f32" => :Float32,
        "i32" => :Int32,
        "i64" => :Int64,
        "u32" => :UInt32,
        "u64" => :UInt64,
        "bool" => :Bool,
        "()" => :Cvoid,
        "String" => :RustString,
        "&str" => :RustStr,
    )
    return get(m, rust_type, :Any)
end


"""
    free_rust_obj(ptr::Ptr{Cvoid}, lib_func::String)

Helper to safely call the Rust destructor.
"""
function free_rust_obj(ptr::Ptr{Cvoid}, lib_func::String)
    if ptr != C_NULL
        # We use @rust here as it handles library lookup automatically
        # Since this is called from the finalizer, we need to be careful.
        # However, @rust is generally thread-safe as it uses a global registry.
        @eval LastCall.@rust $(Symbol(lib_func))(ptr::Ptr{Cvoid})::Cvoid
    end
end
