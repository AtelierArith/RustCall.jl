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
    type_params::Vector{String}
    methods::Vector{RustMethod}
    context_code::String   # Full source code of struct and impls
    fields::Vector{Tuple{String, String}}  # Field name and type pairs
    has_derive_julia_struct::Bool  # Whether #[derive(JuliaStruct)] is present
    derive_options::Dict{String, Bool}  # Options from derive attributes (Clone, Debug, etc.)
end

"""
    remove_derive_julia_struct_attributes(code::String) -> String

Remove #[derive(JuliaStruct)] and related attributes from Rust code before compilation.
This is necessary because JuliaStruct is not a real Rust macro.
"""
function remove_derive_julia_struct_attributes(code::String)
    lines = split(code, '\n')
    result_lines = String[]
    i = 1
    
    while i <= length(lines)
        line = lines[i]
        
        # Check if this line contains #[derive(JuliaStruct)]
        if occursin(r"#\[derive\(.*JuliaStruct", line)
            # Check if it's a single-line attribute
            if occursin(r"#\[derive\([^)]*JuliaStruct[^)]*\)\]", line)
                # Single line: #[derive(JuliaStruct)] or #[derive(JuliaStruct, Clone)]
                # Remove JuliaStruct from the derive list
                modified = replace(line, r"JuliaStruct\s*,?\s*" => "")
                modified = replace(modified, r",\s*\)" => ")")
                modified = replace(modified, r"\(\)" => "")
                
                # If the entire attribute becomes empty, skip the line
                if occursin(r"#\[derive\(\)\]", modified) || occursin(r"#\[derive\(\s*\)\]", modified)
                    # Skip this line entirely
                    i += 1
                    continue
                elseif !isempty(strip(modified))
                    push!(result_lines, modified)
                end
            else
                # Multi-line attribute: #[derive(JuliaStruct,
                #                                  Clone)]
                # Skip until we find the closing )]
                push!(result_lines, line)  # Keep the opening line for now
                i += 1
                while i <= length(lines)
                    next_line = lines[i]
                    if occursin(r"\)\]", next_line)
                        # Found closing, process it
                        modified = replace(next_line, r"JuliaStruct\s*,?\s*" => "")
                        modified = replace(modified, r",\s*\)" => ")")
                        if !isempty(strip(modified))
                            push!(result_lines, modified)
                        end
                        i += 1
                        break
                    else
                        # Keep intermediate lines
                        push!(result_lines, next_line)
                        i += 1
                    end
                end
                continue
            end
        else
            push!(result_lines, line)
        end
        
        i += 1
    end
    
    return join(result_lines, '\n')
end

"""
    parse_structs_and_impls(code::String) -> Vector{RustStructInfo}

Heuristic parser to find pub structs and their impl blocks.
Supports generics (e.g. `struct Point<T>`) and captures full source context.
Now supports #[derive(JuliaStruct)] attribute for automatic mapping.
"""
function parse_structs_and_impls(code::String)
    structs = Dict{String, RustStructInfo}()

    # 1. Find all pub structs
    # Pattern: pub struct Name<T> { ... } or #[derive(JuliaStruct)] pub struct Name { ... }
    # Capture 1: Name, Capture 2: Generics (optional)
    struct_head_pattern = r"pub\s+struct\s+([A-Z]\w*)\s*(?:<(.+?)>)?\s*(?:\{|\()"

    for m in eachmatch(struct_head_pattern, code)
        name = String(m.captures[1])
        params_str = m.captures[2]

        type_params = String[]
        if params_str !== nothing
            for p in split(params_str, ',')
                push!(type_params, strip(p))
            end
        end

        # Extract the full struct definition block
        struct_def = extract_block_at(code, m.offset)
        context = struct_def !== nothing ? struct_def : ""

        # Check for #[derive(JuliaStruct)] attribute before the struct
        # Look backwards from the match to find attributes
        start_pos = max(1, m.offset - 200)  # Look back up to 200 chars
        preceding_code = code[start_pos:m.offset-1]
        has_derive_julia_struct = occursin(r"#\[derive\(JuliaStruct[^\]]*\)\]", preceding_code)
        
        # Parse derive options
        derive_options = Dict{String, Bool}()
        if has_derive_julia_struct
            # Extract derive attributes: #[derive(JuliaStruct, Clone)]
            derive_match = match(r"#\[derive\(([^\]]+)\)\]", preceding_code)
            if derive_match !== nothing
                derive_list = derive_match.captures[1]
                for item in split(derive_list, ',')
                    item = strip(item)
                    if item == "JuliaStruct"
                        derive_options["JuliaStruct"] = true
                    elseif item in ["Clone", "Debug", "PartialEq", "Eq", "PartialOrd", "Ord", "Hash", "Default"]
                        derive_options[item] = true
                    end
                end
            end
        end

        # Parse struct fields
        fields = parse_struct_fields(struct_def !== nothing ? struct_def : "")

        if !haskey(structs, name)
            structs[name] = RustStructInfo(name, type_params, RustMethod[], context, fields, has_derive_julia_struct, derive_options)
        end
    end

    # 2. Find impl blocks
    # Pattern: impl<T> Name<T> { ... } or impl Name { ... }
    impl_head_pattern = r"impl(?:\s*<.*?>)?\s+([A-Z]\w*)(?:\s*<.*?>)?\s*\{"

    for m in eachmatch(impl_head_pattern, code)
        struct_name = String(m.captures[1])

        # Extract the full impl block
        impl_block = extract_block_at(code, m.offset)

        if impl_block !== nothing && haskey(structs, struct_name)
            # Append this impl block to the struct's context (needed for generics)
            info = structs[struct_name]
            # Replace immutable struct
            new_context = info.context_code * "\n" * impl_block

            # Parse methods inside the block (strip the "impl ... {" header first)
            # Simple heuristic: find first {
            header_end = findfirst('{', impl_block)
            if header_end !== nothing
                body = impl_block[header_end+1:end-1] # content inside braces
                methods = parse_methods_in_impl(body)
                append!(info.methods, methods)
            end

            structs[struct_name] = RustStructInfo(info.name, info.type_params, info.methods, new_context, info.fields, info.has_derive_julia_struct, info.derive_options)
        end
    end

    return collect(values(structs))
end

"""
    extract_block_at(code::String, start_idx::Int) -> Union{String, Nothing}

Extract a balanced brace block starting near start_idx.
Searches for the first '{' at or after start_idx.
"""
function extract_block_at(code::String, start_idx::Int)
    # Find start brace
    # Search range limited to reasonable distance to avoid false positives?
    # No, look until next brace.
    brace_idx = findnext('{', code, start_idx)
    if brace_idx === nothing
        # Maybe it's a tuple struct `struct Foo(i32);` -> ends with ;
        semi_idx = findnext(';', code, start_idx)
        if semi_idx !== nothing
            # Check if there is a { before it?
            return code[start_idx:semi_idx]
        end
        return nothing
    end

    # Count braces
    count = 1
    idx = brace_idx + 1
    in_string = false
    string_char = nothing

    while idx <= ncodeunits(code)
        char = code[idx]

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
                count += 1
            elseif char == '}'
                count -= 1
                if count == 0
                    # Include the whole declaration line?
                    # The caller `start_idx` points to `pub struct...`.
                    # We want from start_idx to idx.
                    return code[start_idx:idx]
                end
            end
        end
        idx = nextind(code, idx)
    end
    return nothing
end

"""
    parse_methods_in_impl(impl_body::AbstractString) -> Vector{RustMethod}

Parse function definitions inside an impl block.
"""
function parse_methods_in_impl(impl_body::AbstractString)
    methods = RustMethod[]

    # Pattern: pub fn name(args) -> ret {
    fn_pattern = r"pub\s+fn\s+(\w+)\s*\(([\s\S]*?)\)(?:\s*->\s*([\w:<>, \[\]]+))?\s*(?:where[\s\S]*?)?\{"

    for m in eachmatch(fn_pattern, impl_body)
        name = String(m.captures[1])
        args_str = m.captures[2]
        ret_type = m.captures[3] === nothing ? "()" : strip(String(m.captures[3]))

        is_static = !occursin("self", args_str)
        is_mutable = occursin("&mut self", args_str)

        arg_names = String[]
        arg_types = String[]

        # Quick argument parsing
        current_arg = ""
        bracket_level = 0

        for char in args_str
            if char == '<' || char == '(' || char == '['
                bracket_level += 1
                current_arg *= char
            elseif char == '>' || char == ')' || char == ']'
                bracket_level -= 1
                current_arg *= char
            elseif char == ',' && bracket_level == 0
                _process_arg!(arg_names, arg_types, strip(current_arg))
                current_arg = ""
            else
                current_arg *= char
            end
        end
        if !isempty(strip(current_arg))
            _process_arg!(arg_names, arg_types, strip(current_arg))
        end

        push!(methods, RustMethod(name, is_static, is_mutable, arg_names, arg_types, ret_type))
    end

    return methods
end

function _process_arg!(names, types, arg)
    if isempty(arg) || arg == "self" || arg == "&self" || arg == "&mut self"
        return
    end
    if occursin(':', arg)
        parts = split(arg, ':', limit=2)
        push!(names, strip(parts[1]))
        push!(types, strip(parts[2]))
    end
end

"""
    generate_struct_wrappers(info::RustStructInfo) -> String

Generate "extern C" C-FFI wrappers for a given struct.
For generic structs, registers them as generic functions instead of returning static wrappers.
"""
function generate_struct_wrappers(info::RustStructInfo)
    io = IOBuffer()
    struct_name = info.name

    # Handle Generics
    if !isempty(info.type_params)
        # For generics, we generate generic wrapper functions and register them.
        # We DO NOT return them to be compiled into the main lib.

        type_params_decl = "<" * join(info.type_params, ", ") * ">"
        # We assume strict mirroring for now: T, U...

        # Helper to register
        function reg(func_name, code)
             # context: Struct def + Impl defs
             register_generic_function(func_name, code, Symbol.(info.type_params), Dict{Symbol, String}(), info.context_code)
        end

        # Constructor wrapper logic
        # pub fn Point_new<T>(x: T) -> *mut Point<T> { ... }

        for m in info.methods
             wrapper_name = "$(struct_name)_$(m.name)"

             # Build signature
             wrapper_args = String[]
             call_args = String[]

             if !m.is_static
                 # ptr: *mut Point<T>
                 mut_prefix = m.is_mutable ? "*mut " : "*const "
                 push!(wrapper_args, "ptr: $(mut_prefix)$(struct_name)$(type_params_decl)")

                 ref_prefix = m.is_mutable ? "&mut " : "&"
                 push!(call_args, "unsafe { $(ref_prefix)*ptr }")
             end

             for (aname, atype) in zip(m.arg_names, m.arg_types)
                 push!(wrapper_args, "$aname: $atype")
                 push!(call_args, aname)
             end

             args_str = join(wrapper_args, ", ")

             w_io = IOBuffer()

             is_ctor = m.name == "new" || m.return_type == "Self"

             ret_decl = ""
             if is_ctor
                 ret_decl = " -> *mut $(struct_name)$(type_params_decl)"
                 println(w_io, "pub fn $(wrapper_name)$(type_params_decl)($args_str)$ret_decl {")
                 println(w_io, "    let obj = $(struct_name)::$(m.name)($(join(m.arg_names, ", ")));")
                 println(w_io, "    Box::into_raw(Box::new(obj))")
                 println(w_io, "}")
             else
                 ret_decl = m.return_type == "()" ? "" : " -> $(m.return_type)"
                 println(w_io, "pub fn $(wrapper_name)$(type_params_decl)($args_str)$ret_decl {")
                 # Extract self
                 if m.is_static
                     println(w_io, "    $(struct_name)::$(m.name)($(join(m.arg_names, ", ")))")
                 else
                     println(w_io, "    let self_obj = $(call_args[1]);")
                     println(w_io, "    self_obj.$(m.name)($(join(m.arg_names, ", ")))")
                 end
                 println(w_io, "}")
             end

             code = String(take!(w_io))
             reg(wrapper_name, code)
        end

        # Free function
        free_name = "$(struct_name)_free"
        f_io = IOBuffer()
        println(f_io, "pub fn $(free_name)$(type_params_decl)(ptr: *mut $(struct_name)$(type_params_decl)) {")
        println(f_io, "    if !ptr.is_null() { unsafe { Box::from_raw(ptr); } }")
        println(f_io, "}")
        reg(free_name, String(take!(f_io)))

        return "\n// Generics struct $(struct_name): wrappers registered for on-demand monomorphization.\n"
    end

    # Non-Generic Path (Original)
    println(io, "\n// --- Auto-generated FFI wrappers for $struct_name ---")
    println(io, "#[no_mangle]")
    println(io, "pub extern \"C\" fn $(struct_name)_free(ptr: *mut $struct_name) {")
    println(io, "    if !ptr.is_null() {")
    println(io, "        unsafe { Box::from_raw(ptr); }")
    println(io, "    }")
    println(io, "}\n")

    # Generate field accessors if struct has fields and derive(JuliaStruct)
    if info.has_derive_julia_struct && !isempty(info.fields)
        for (field_name, field_type) in info.fields
            # Getter
            println(io, "#[no_mangle]")
            println(io, "pub extern \"C\" fn $(struct_name)_get_$(field_name)(ptr: *const $struct_name) -> $field_type {")
            println(io, "    unsafe { (*ptr).$(field_name) }")
            println(io, "}\n")
            
            # Setter (only if mutable)
            println(io, "#[no_mangle]")
            println(io, "pub extern \"C\" fn $(struct_name)_set_$(field_name)(ptr: *mut $struct_name, value: $field_type) {")
            println(io, "    unsafe { (*ptr).$(field_name) = value; }")
            println(io, "}\n")
        end
    end

    # Generate trait implementations if requested
    if info.has_derive_julia_struct
        if get(info.derive_options, "Clone", false)
            println(io, "#[no_mangle]")
            println(io, "pub extern \"C\" fn $(struct_name)_clone(ptr: *const $struct_name) -> *mut $struct_name {")
            println(io, "    unsafe { Box::into_raw(Box::new((*ptr).clone())) }")
            println(io, "}\n")
        end
    end

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
    struct_name_str = info.name
    esc_struct = esc(Symbol(struct_name_str))

    # Handle Generics
    if !isempty(info.type_params)
        # struct Point{T}
        T_params = [Symbol(t) for t in info.type_params]
        esc_T_params = [esc(t) for t in T_params]
        where_clause = :($(esc_struct){$(esc_T_params...)})

        exprs = []

        # 1. Define Struct
        push!(exprs, quote
            mutable struct $where_clause
                ptr::Ptr{Cvoid}
                lib_name::String

                function $where_clause(ptr::Ptr{Cvoid}, lib::String) where {$(esc_T_params...)}
                    obj = new{$(esc_T_params...)}(ptr, lib)
                    finalizer(obj) do x
                        # Call free (generic)
                        # We use a special helper that resolves the generic free function
                        # struct_func: Point_free
                        _call_generic_free(x.lib_name, $(struct_name_str * "_free"), x.ptr, $(esc_T_params...))
                        x.ptr = C_NULL
                    end
                    return obj
                end
            end
        end)

        # 2. Methods
        for m in info.methods
            fname = esc(Symbol(m.name))
            wrapper_name = "$(struct_name_str)_$(m.name)"
            is_ctor = m.name == "new" || m.return_type == "Self"

            arg_names = [Symbol(an) for an in m.arg_names]
            esc_args = [esc(a) for a in arg_names]

            if m.is_static
                 if is_ctor
                     # Point(x, y) -> Point{T}(ptr, lib)
                     # Needs to infer T? Or explicit?
                     # For simplicity, we define: function Point{T}(args...)
                     push!(exprs, quote
                         function (::Type{$esc_struct})($(esc_args...))
                             # Infer T from args? Or assume args are T?
                             # This is tricky without explicit types.
                             # We assume simpler case: Point{Int32}(1, 2)
                             error("Automatic constructor for generic structs is not yet fully implemented. Use explicit builder pattern.")
                         end

                         function (::Type{$where_clause})($(esc_args...)) where {$(esc_T_params...)}
                             # Precompile free function to avoid compilation in finalizer
                             _precompile_generic_free($(struct_name_str * "_free"), ($(esc_T_params...),))

                             # Call generic constructor
                             # Point_new<T>(...)
                             # Pass args and types as tuples to separate them
                             ptr_lib_tuple = _call_generic_constructor($wrapper_name, ($(esc_args...),), ($(esc_T_params...),))

                             (ptr_val, lib_val) = ptr_lib_tuple
                             return $esc_struct{$(esc_T_params...)}(ptr_val, lib_val)
                         end
                     end)
                 end
            else
                 push!(exprs, quote
                     function $fname(self::$where_clause, $(esc_args...)) where {$(esc_T_params...)}
                         _call_generic_method(self.lib_name, $wrapper_name, self.ptr, ($(esc_args...),), ($(esc_T_params...),))
                     end
                 end)
            end
        end

        return Expr(:block, exprs...)
    end

    # Non-Generic Path (Original)
    exprs = []

    # 1. Define the struct
    push!(exprs, quote
        mutable struct $esc_struct
            ptr::Ptr{Cvoid}
            lib_name::String

            function $esc_struct(ptr::Ptr{Cvoid}, lib::String)
                obj = new(ptr, lib)
                finalizer(obj) do x
                    if x.ptr != C_NULL
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
                        lib = get_current_library()
                        ptr = _call_rust_constructor(lib, $wrapper_name, $(esc_args...))
                        return $esc_struct(ptr, lib)
                    end
                end)
            else
                jl_ret_type = rust_to_julia_type_sym(m.return_type)
                push!(exprs, quote
                    function $fname($(esc_args...))
                        lib = get_current_library()
                        return _call_rust_method(lib, $wrapper_name, C_NULL, $(esc_args...), $(QuoteNode(jl_ret_type)))
                    end
                end)
            end
        else
            jl_ret_type = rust_to_julia_type_sym(m.return_type)
            push!(exprs, quote
                function $fname(self::$esc_struct, $(esc_args...))
                    return _call_rust_method(self.lib_name, $wrapper_name, self.ptr, $(esc_args...), $(QuoteNode(jl_ret_type)))
                end
            end)
        end
    end

    # 3. Add field accessors if derive(JuliaStruct) is present
    if info.has_derive_julia_struct && !isempty(info.fields)
        for (field_name, field_type) in info.fields
            field_sym = esc(Symbol(field_name))
            jl_field_type = rust_to_julia_type_sym(field_type)
            getter_name = struct_name_str * "_get_" * field_name
            setter_name = struct_name_str * "_set_" * field_name

            # Getter
            push!(exprs, quote
                function Base.getproperty(self::$esc_struct, field::Symbol)
                    if field === $(QuoteNode(Symbol(field_name)))
                        lib = self.lib_name
                        return _call_rust_method(lib, $getter_name, self.ptr, $(QuoteNode(jl_field_type)))
                    else
                        return getfield(self, field)
                    end
                end
            end)

            # Setter
            push!(exprs, quote
                function Base.setproperty!(self::$esc_struct, field::Symbol, value)
                    if field === $(QuoteNode(Symbol(field_name)))
                        lib = self.lib_name
                        _call_rust_method(lib, $setter_name, self.ptr, value, $(QuoteNode(Cvoid)))
                        return value
                    else
                        return setfield!(self, field, value)
                    end
                end
            end)
        end
    end

    # 4. Add trait implementations if requested
    if info.has_derive_julia_struct
        if get(info.derive_options, "Clone", false)
            clone_name = struct_name_str * "_clone"
            push!(exprs, quote
                function Base.copy(self::$esc_struct)
                    lib = self.lib_name
                    ptr = _call_rust_constructor(lib, $clone_name, self.ptr)
                    return $esc_struct(ptr, lib)
                end
            end)
        end
    end

    return Expr(:block, exprs...)
end

# Internal helpers
function _call_rust_free(lib_name::String, func_name::String, ptr::Ptr{Cvoid})
    # This is for non-generic
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
    ret_type = last(args)
    actual_args = args[1:end-1]
    real_ret_type = julia_sym_to_type(ret_type)

    if ptr == C_NULL
        return _rust_call_typed(lib_name, func_name, real_ret_type, actual_args...)
    else
        return _rust_call_typed(lib_name, func_name, real_ret_type, ptr, actual_args...)
    end
end

# Generic helpers
function _call_generic_constructor(func_name::String, args::Tuple, types::Tuple)
    # Use explicit types to monomorphize
    # We assume types correspond to T, U... in order
    # We need parameter names (T, U).
    # Helper to get parameter names from registry?
    generic_info = GENERIC_FUNCTION_REGISTRY[func_name]
    param_names = generic_info.type_params

    type_params = Dict{Symbol, Type}()
    for (i, p) in enumerate(param_names)
        type_params[p] = types[i]
    end

    info = monomorphize_function(func_name, type_params)

    # args are in a tuple, need to splat
    ptr = call_rust_function(info.func_ptr, info.return_type, args...)

    return (ptr, info.lib_name)
end

function _call_generic_method(lib_name::String, func_name::String, ptr::Ptr{Cvoid}, args::Tuple, types::Tuple)
    generic_info = GENERIC_FUNCTION_REGISTRY[func_name]
    param_names = generic_info.type_params

    type_params = Dict{Symbol, Type}()
    for (i, p) in enumerate(param_names)
        type_params[p] = types[i]
    end

    info = monomorphize_function(func_name, type_params)

    # Method call: pass ptr (self) then args
    return call_rust_function(info.func_ptr, info.return_type, ptr, args...)
end

function _precompile_generic_free(func_name::String, types::Tuple)
    # Same as _call_generic_free but only compile/cache
    generic_info = GENERIC_FUNCTION_REGISTRY[func_name]
    param_names = generic_info.type_params

    type_params = Dict{Symbol, Type}()
    for (i, p) in enumerate(param_names)
        type_params[p] = types[i]
    end

    # This will cache the function info
    monomorphize_function(func_name, type_params)
end

function _call_generic_free(lib_name::String, func_name::String, ptr::Ptr{Cvoid}, types...)
    # We need to construct the type params manually since we only have types, not values.
    # call_generic_function infers from values.
    # We need explicit monomorphization call.

    generic_info = GENERIC_FUNCTION_REGISTRY[func_name]
    param_names = generic_info.type_params

    type_params = Dict{Symbol, Type}()
    for (i, p) in enumerate(param_names)
        type_params[p] = types[i]
    end

    # Should use cached version (fast path for finalizer)
    info = get_monomorphized_function(func_name, type_params)
    if info === nothing
        # Fallback to monomorphize (unsafe in finalizer)
        # Should not happen if precompiled
        info = monomorphize_function(func_name, type_params)
    end

    call_rust_function(info.func_ptr, Cvoid, ptr)
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
