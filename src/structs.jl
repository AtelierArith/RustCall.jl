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
    derive_pattern = Regex(raw"#\s*\[\s*derive\s*\((.*?)\)\s*\]", "s")
    return replace(code, derive_pattern => (m -> begin
        m2 = match(derive_pattern, String(m))
        if m2 === nothing
            return String(m)
        end
        inner = String(m2.captures[1])
        items = _split_top_level_commas(inner)
        filtered = [item for item in items if strip(item) != "JuliaStruct"]
        if isempty(filtered)
            return ""
        end
        "#[derive($(join(filtered, ", ")))]"
    end))
end

function _split_top_level_commas(s::AbstractString)
    parts = String[]
    current = IOBuffer()
    angle_depth = 0
    paren_depth = 0
    bracket_depth = 0

    for c in s
        if c == '<'
            angle_depth += 1
            write(current, c)
        elseif c == '>'
            angle_depth = max(0, angle_depth - 1)
            write(current, c)
        elseif c == '('
            paren_depth += 1
            write(current, c)
        elseif c == ')'
            paren_depth = max(0, paren_depth - 1)
            write(current, c)
        elseif c == '['
            bracket_depth += 1
            write(current, c)
        elseif c == ']'
            bracket_depth = max(0, bracket_depth - 1)
            write(current, c)
        elseif c == ',' && angle_depth == 0 && paren_depth == 0 && bracket_depth == 0
            part = strip(String(take!(current)))
            if !isempty(part)
                push!(parts, part)
            end
        else
            write(current, c)
        end
    end

    last = strip(String(take!(current)))
    if !isempty(last)
        push!(parts, last)
    end

    return parts
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
    struct_head_pattern = r"pub\s+struct\s+([A-Z]\w*)\s*(?:<(.+?)>)?\s*(?:\s+where\s+[^{(]+)?(?:\{|\()"

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
        derive_pattern = Regex(raw"#\s*\[\s*derive\s*\((.*?)\)\s*\]", "s")
        derive_matches = collect(eachmatch(derive_pattern, preceding_code))
        has_derive_julia_struct = false

        # Parse derive options
        derive_options = Dict{String, Bool}()
        for derive_match in reverse(derive_matches)
            derive_items = _split_top_level_commas(String(derive_match.captures[1]))
            if any(strip(item) == "JuliaStruct" for item in derive_items)
                has_derive_julia_struct = true
                for item in derive_items
                    item = strip(item)
                    if item == "JuliaStruct"
                        derive_options["JuliaStruct"] = true
                    elseif item in ["Clone", "Debug", "PartialEq", "Eq", "PartialOrd", "Ord", "Hash", "Default"]
                        derive_options[item] = true
                    end
                end
                break
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
    impl_head_pattern = r"impl(?:\s*<.*?>)?\s+([A-Z]\w*)(?:\s*<.*?>)?\s*(?:\s+where\s+[^{]+)?\{"

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
    parse_struct_fields(struct_def::String) -> Vector{Tuple{String, String}}

Parse field names and types from a Rust struct definition.
Returns a vector of (field_name, field_type) tuples.
"""
# Check if a Rust type is FFI-compatible (implements Copy or can be cloned for FFI).
# Returns true for primitive types, String, Vec, and pointer types.
# Returns false for complex types like Array2, ThreadRng, etc.
function _is_ffi_compatible_field_type(rust_type::String)
    rust_type = strip(rust_type)

    # Primitive types (implement Copy)
    primitive_types = Set([
        "i8", "i16", "i32", "i64", "i128",
        "u8", "u16", "u32", "u64", "u128",
        "f32", "f64",
        "bool", "char",
        "usize", "isize",
        "()"
    ])

    if rust_type in primitive_types
        return true
    end

    # String and Vec (can use .clone())
    if occursin(r"^String$|^Vec<", rust_type)
        return true
    end

    # Pointer types (Copy)
    if occursin(r"^\*(?:const|mut)\s+", rust_type)
        return true
    end

    # References are tricky for FFI, skip them
    if startswith(rust_type, "&")
        return false
    end

    # Known non-Copy types to exclude
    non_copy_patterns = [
        r"Array\d*<",           # ndarray types
        r"ThreadRng",           # RNG types
        r"HashMap<",            # Collections
        r"HashSet<",
        r"BTreeMap<",
        r"BTreeSet<",
        r"Mutex<",              # Sync primitives
        r"RwLock<",
        r"Arc<",
        r"Rc<",
        r"Box<",
        r"RefCell<",
        r"Cell<",
    ]

    for pattern in non_copy_patterns
        if occursin(pattern, rust_type)
            return false
        end
    end

    # Generic types with type parameters are likely not Copy
    if occursin(r"<.*>", rust_type)
        return false
    end

    # Default: assume it might work (primitive-like user types)
    return true
end

"""
    _extract_field_type(rest::AbstractString) -> String

Extract a Rust field type from the text after the colon, using bracket-counting
to correctly handle generic types with commas like `HashMap<String, Vec<Option<i32>>>`.
Stops at a trailing comma or semicolon at bracket depth 0.
"""
function _extract_field_type(rest::AbstractString)
    buf = IOBuffer()
    angle_depth = 0
    paren_depth = 0
    bracket_depth = 0

    for c in rest
        if c == '<'
            angle_depth += 1
            write(buf, c)
        elseif c == '>'
            angle_depth = max(0, angle_depth - 1)
            write(buf, c)
        elseif c == '('
            paren_depth += 1
            write(buf, c)
        elseif c == ')'
            paren_depth = max(0, paren_depth - 1)
            write(buf, c)
        elseif c == '['
            bracket_depth += 1
            write(buf, c)
        elseif c == ']'
            bracket_depth = max(0, bracket_depth - 1)
            write(buf, c)
        elseif (c == ',' || c == ';') && angle_depth == 0 && paren_depth == 0 && bracket_depth == 0
            break
        else
            write(buf, c)
        end
    end

    return strip(String(take!(buf)))
end

function parse_struct_fields(struct_def::String)
    fields = Tuple{String, String}[]

    if isempty(struct_def)
        return fields
    end

    # Find the struct body (content between { and })
    brace_start = findfirst('{', struct_def)
    brace_end = findlast('}', struct_def)

    if brace_start === nothing || brace_end === nothing
        return fields
    end

    # Extract the body content
    body = struct_def[brace_start+1:brace_end-1]

    # Parse fields using bracket-counting to handle generic types with commas
    # e.g. HashMap<String, Vec<Option<i32>>> or (String, i32)
    # Split body into lines and parse each field
    for line in split(body, '\n')
        line = strip(line)
        # Skip empty lines and comments
        if isempty(line) || startswith(line, "//") || startswith(line, "/*")
            continue
        end
        # Skip visibility modifiers, then find "name: type"
        line = replace(line, r"^\s*pub\s+" => "")
        # Match field_name: ...
        colon_pos = findfirst(':', line)
        if colon_pos === nothing
            continue
        end
        field_name = strip(line[1:prevind(line, colon_pos)])
        # Validate field name is a simple identifier
        if !occursin(r"^\w+$", field_name) || startswith(field_name, "//")
            continue
        end
        # Extract field type using bracket-counting to find the end
        rest = strip(line[nextind(line, colon_pos):end])
        field_type = _extract_field_type(rest)
        if !isempty(field_type)
            push!(fields, (field_name, field_type))
        end
    end

    return fields
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
    in_char = false
    in_line_comment = false
    in_block_comment = false

    while idx <= ncodeunits(code)
        char = code[idx]
        prev_char = idx > 1 ? code[prevind(code, idx)] : '\0'
        next_idx = nextind(code, idx)
        next_char = next_idx <= ncodeunits(code) ? code[next_idx] : '\0'

        # Handle line comments
        if !in_string && !in_char && !in_block_comment && char == '/' && next_char == '/'
            in_line_comment = true
            idx = next_idx
            idx = nextind(code, idx)
            continue
        end

        # End of line comment
        if in_line_comment && char == '\n'
            in_line_comment = false
            idx = nextind(code, idx)
            continue
        end

        # Skip if in line comment
        if in_line_comment
            idx = nextind(code, idx)
            continue
        end

        # Handle block comments
        if !in_string && !in_char && !in_block_comment && char == '/' && next_char == '*'
            in_block_comment = true
            idx = next_idx
            idx = nextind(code, idx)
            continue
        end

        # End of block comment
        if in_block_comment && char == '*' && next_char == '/'
            in_block_comment = false
            idx = next_idx
            idx = nextind(code, idx)
            continue
        end

        # Skip if in block comment
        if in_block_comment
            idx = nextind(code, idx)
            continue
        end

        # Handle strings (double quotes)
        if char == '"' && prev_char != '\\'
            if !in_char
                in_string = !in_string
            end
        # Handle character literals (single quotes) - they are exactly 'c' or '\x'
        elseif char == '\'' && !in_string
            if !in_char
                # Start of character literal - check if it looks valid
                # Rust char literals are: 'a', '\n', '\x00', '\u{...}'
                # For simplicity, just toggle in_char and expect closing ' within ~10 chars
                in_char = true
            else
                in_char = false
            end
        elseif !in_string && !in_char
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
Only generates wrappers for structs marked with #[derive(JuliaStruct)] or #[julia].
"""
function generate_struct_wrappers(info::RustStructInfo)
    # Only generate FFI wrappers for structs with #[derive(JuliaStruct)]
    if !info.has_derive_julia_struct
        return ""  # Return empty string - no FFI wrappers generated
    end

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

        # Generic Field Accessors
        if info.has_derive_julia_struct && !isempty(info.fields)
            method_wrapper_names = Set(["$(struct_name)_$(m.name)" for m in info.methods])
            for (field_name, field_type) in info.fields
                getter_name = "$(struct_name)_get_$(field_name)"
                if getter_name in method_wrapper_names
                    continue
                end

                # Getter
                g_io = IOBuffer()
                println(g_io, "pub fn $(getter_name)$(type_params_decl)(ptr: *const $(struct_name)$(type_params_decl)) -> $field_type {")
                if occursin(r"String|Vec", field_type)
                    println(g_io, "    unsafe { (*ptr).$(field_name).clone() }")
                else
                    println(g_io, "    unsafe { (*ptr).$(field_name) }")
                end
                println(g_io, "}")
                reg(getter_name, String(take!(g_io)))

                # Setter
                s_io = IOBuffer()
                println(s_io, "pub fn $(struct_name)_set_$(field_name)$(type_params_decl)(ptr: *mut $(struct_name)$(type_params_decl), value: $field_type) {")
                println(s_io, "    unsafe { (*ptr).$(field_name) = value; }")
                println(s_io, "}")
                reg("$(struct_name)_set_$(field_name)", String(take!(s_io)))
            end
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
        # Get set of method wrapper names to avoid conflicts
        # Method wrappers are named: struct_name_method_name
        method_wrapper_names = Set(["$(struct_name)_$(m.name)" for m in info.methods])

        for (field_name, field_type) in info.fields
            # Skip if there's a method wrapper with the same name as the field getter
            getter_name = "$(struct_name)_get_$(field_name)"
            if getter_name in method_wrapper_names
                continue  # Skip field accessor if method wrapper with same name exists
            end

            # Skip non-Copy types that would cause compilation errors
            # Only generate accessors for primitive types and String/Vec (which use clone)
            if !_is_ffi_compatible_field_type(field_type)
                @debug "Skipping field accessor for non-FFI-compatible type: $field_name: $field_type"
                continue
            end

            # Getter - need to clone String and Vec types
            println(io, "#[no_mangle]")
            println(io, "pub extern \"C\" fn $(struct_name)_get_$(field_name)(ptr: *const $struct_name) -> $field_type {")
            # String and Vec types need clone(), Copy types can be returned directly
            if occursin(r"String|Vec", field_type)
                println(io, "    unsafe { (*ptr).$(field_name).clone() }")
            else
                println(io, "    unsafe { (*ptr).$(field_name) }")
            end
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
        # Handle String types specially - they need FFI-safe conversion
        wrapper_args = String[]
        call_args = String[]
        string_conversions = String[]  # Code to convert FFI strings to Rust String

        if !m.is_static
            push!(wrapper_args, "ptr: " * (m.is_mutable ? "*mut " : "*const ") * struct_name)
            push!(call_args, "unsafe { &" * (m.is_mutable ? "mut " : "") * "*ptr }")
        end

        for (aname, atype) in zip(m.arg_names, m.arg_types)
            if atype == "String"
                # String is not FFI-safe, use *const u8 + length
                push!(wrapper_args, "$(aname)_ptr: *const u8")
                push!(wrapper_args, "$(aname)_len: usize")
                # Add conversion code
                push!(string_conversions, """    let $(aname) = unsafe {
        let slice = std::slice::from_raw_parts($(aname)_ptr, $(aname)_len);
        String::from_utf8_lossy(slice).into_owned()
    };""")
                push!(call_args, aname)
            elseif atype == "&str"
                # &str is also not FFI-safe
                push!(wrapper_args, "$(aname)_ptr: *const u8")
                push!(wrapper_args, "$(aname)_len: usize")
                push!(string_conversions, """    let $(aname)_bytes = unsafe { std::slice::from_raw_parts($(aname)_ptr, $(aname)_len) };
    let $(aname) = unsafe { std::str::from_utf8_unchecked($(aname)_bytes) };""")
                push!(call_args, aname)
            else
                push!(wrapper_args, "$aname: $atype")
                push!(call_args, aname)
            end
        end

        args_str = join(wrapper_args, ", ")
        conversions_str = join(string_conversions, "\n")

        returns_self = m.return_type == "Self" || m.return_type == struct_name

        if returns_self
            println(io, "pub extern \"C\" fn $wrapper_name($args_str) -> *mut $struct_name {")
            # Add string conversions if any
            if !isempty(string_conversions)
                println(io, conversions_str)
            end
            if m.is_static
                # For static methods, call_args contains only the method arguments (no self)
                println(io, "    let obj = $struct_name::$(m.name)($(join(call_args, ", ")));")
            else
                # For instance methods, call_args[1] is self, so skip it
                println(io, "    let self_obj = unsafe { &$(m.is_mutable ? "mut " : "") *ptr };")
                println(io, "    let obj = self_obj.$(m.name)($(join(call_args[2:end], ", ")));")
            end
            println(io, "    Box::into_raw(Box::new(obj))")
        else
            ret_decl = m.return_type == "()" ? "" : " -> $(m.return_type)"
            println(io, "pub extern \"C\" fn $wrapper_name($args_str)$ret_decl {")
            # Add string conversions if any
            if !isempty(string_conversions)
                println(io, conversions_str)
            end
            if m.is_static
                println(io, "    $struct_name::$(m.name)($(join(call_args, ", ")))")
            else
                println(io, "    let self_obj = unsafe { &$(m.is_mutable ? "mut " : "") *ptr };")
                println(io, "    self_obj.$(m.name)($(join(call_args[2:end], ", ")))")
            end
        end
        println(io, "}\n")
    end

    return String(take!(io))
end

"""
    emit_julia_definitions(info::RustStructInfo)

Generate Julia code to define a corresponding mutable struct and its methods.
Only generates definitions for structs marked with #[derive(JuliaStruct)] or #[julia].
"""
function emit_julia_definitions(info::RustStructInfo)
    # Only generate Julia definitions for structs with #[derive(JuliaStruct)]
    # This is set when #[julia] attribute is used (transformed to #[derive(JuliaStruct)])
    if !info.has_derive_julia_struct
        return :()  # Return empty expression - no Julia wrapper generated
    end

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
                        # Temporarily disabled free to diagnose segfault
                        @debug "Finalizer: skipped free for generic struct $(struct_name_str) (ptr=$(x.ptr))"
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

        # 3. Field and Method Accessors
        field_getters = Dict{Symbol, Tuple{String, Symbol}}()
        field_setters = Dict{Symbol, String}()
        if info.has_derive_julia_struct && !isempty(info.fields)
            for (field_name, field_type) in info.fields
                # Skip non-FFI-compatible types
                if !_is_ffi_compatible_field_type(field_type)
                    continue
                end
                field_sym = Symbol(field_name)
                jl_field_type = rust_to_julia_type_sym(field_type)
                field_getters[field_sym] = ("$(struct_name_str)_get_$(field_name)", jl_field_type)
                field_setters[field_sym] = "$(struct_name_str)_set_$(field_name)"
            end
        end

        method_names = Set([Symbol(m.name) for m in info.methods])
        method_accessors = Expr[]
        for m in info.methods
            method_sym = Symbol(m.name)
            method_func = esc(Symbol(m.name))
            push!(method_accessors, quote
                if field === $(QuoteNode(method_sym))
                    return (args...) -> $method_func(self, args...)
                end
            end)
        end

        push!(exprs, quote
            function Base.getproperty(self::$where_clause, field::Symbol) where {$(esc_T_params...)}
                field_info = $(QuoteNode(field_getters))
                method_names_set = $(QuoteNode(method_names))

                if haskey(field_info, field)
                    getter_name, jl_field_type_sym = field_info[field]
                    field_type = julia_sym_to_type(jl_field_type_sym)
                    return _call_generic_field(self.lib_name, getter_name, self.ptr, field_type, ($(esc_T_params...),))
                elseif field in method_names_set
                    $(method_accessors...)
                    return getfield(self, field)
                else
                    return getfield(self, field)
                end
            end

            function Base.setproperty!(self::$where_clause, field::Symbol, value) where {$(esc_T_params...)}
                field_setters_map = $(QuoteNode(field_setters))
                if haskey(field_setters_map, field)
                    setter_name = field_setters_map[field]
                    _call_generic_method(self.lib_name, setter_name, self.ptr, (value,), ($(esc_T_params...),))
                    return value
                else
                    return setfield!(self, field, value)
                end
            end
        end)

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
                        # Temporarily disabled free to diagnose segfault
                        @debug "Finalizer: skipped free for struct $(struct_name_str) (ptr=$(x.ptr))"
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

        # Build expanded arguments for String types
        # String args need to be passed as (pointer, length) pairs
        expanded_call_args = Expr[]
        for (aname, atype) in zip(arg_names, m.arg_types)
            esc_aname = esc(aname)
            if atype == "String" || atype == "&str"
                # Convert to (pointer, length) pair
                push!(expanded_call_args, :(pointer($esc_aname)))
                push!(expanded_call_args, :(sizeof($esc_aname)))
            else
                push!(expanded_call_args, esc_aname)
            end
        end

        if m.is_static
            if is_ctor
                push!(exprs, quote
                    function (::Type{$esc_struct})($(esc_args...))
                        lib = get_current_library()
                        ptr = _call_rust_constructor(lib, $wrapper_name, $(expanded_call_args...))
                        return $esc_struct(ptr, lib)
                    end
                end)
            else
                jl_ret_type = rust_to_julia_type_sym(m.return_type)
                push!(exprs, quote
                    function $fname($(esc_args...))
                        lib = get_current_library()
                        return _call_rust_method(lib, $wrapper_name, C_NULL, $(expanded_call_args...), $(QuoteNode(jl_ret_type)))
                    end
                end)
            end
        else
        jl_ret_type = rust_to_julia_type_sym(m.return_type)
        is_ctor_ret = m.return_type == "Self" || m.return_type == struct_name_str
        push!(exprs, quote
            function $fname(self::$esc_struct, $(esc_args...))
                res = _call_rust_method(self.lib_name, $wrapper_name, self.ptr, $(expanded_call_args...), $(QuoteNode(jl_ret_type)))
                if $is_ctor_ret
                    return $esc_struct(res, self.lib_name)
                else
                    return res
                end
            end
        end)
        end
    end

    # 3. Add field accessors if derive(JuliaStruct) is present
    if info.has_derive_julia_struct && !isempty(info.fields)
        # Build field accessor mappings
        field_getters = Dict{Symbol, Tuple{String, Symbol}}()
        field_setters = Dict{Symbol, String}()

        for (field_name, field_type) in info.fields
            # Skip non-FFI-compatible types
            if !_is_ffi_compatible_field_type(field_type)
                continue
            end
            field_sym = Symbol(field_name)
            jl_field_type = rust_to_julia_type_sym(field_type)
            getter_name = struct_name_str * "_get_" * field_name
            setter_name = struct_name_str * "_set_" * field_name
            field_getters[field_sym] = (getter_name, jl_field_type)
            field_setters[field_sym] = setter_name
        end

        # Single Base.getproperty for all fields and methods
        method_names = Set([Symbol(m.name) for m in info.methods])
        # Build method accessor expressions
        method_accessors = Expr[]
        for m in info.methods
            method_sym = Symbol(m.name)
            method_func = esc(Symbol(m.name))
            # Use a fixed name 'args' – it's safe within the anonymous function scope
            # and avoids 'Module.##gensym' qualification issues
            push!(method_accessors, quote
                if field === $(QuoteNode(method_sym))
                    return (args...) -> $method_func(self, args...)
                end
            end)
        end

        push!(exprs, quote
            function Base.getproperty(self::$esc_struct, field::Symbol)
                field_info = $(QuoteNode(field_getters))
                method_names_set = $(QuoteNode(method_names))

                # Check if it's a field
                if haskey(field_info, field)
                    getter_name, jl_field_type_sym = field_info[field]
                    lib = self.lib_name
                    func_ptr = get_function_pointer(lib, getter_name)
                    field_type = julia_sym_to_type(jl_field_type_sym)
                    return call_rust_function(func_ptr, field_type, self.ptr)
                # Check if it's a method
                elseif field in method_names_set
                    $(method_accessors...)
                    return getfield(self, field)
                else
                    return getfield(self, field)
                end
            end
        end)

        # Single Base.setproperty! for all fields
        push!(exprs, quote
            function Base.setproperty!(self::$esc_struct, field::Symbol, value)
                field_setters_map = $(QuoteNode(field_setters))
                if haskey(field_setters_map, field)
                    setter_name = field_setters_map[field]
                    lib = self.lib_name
                    func_ptr = get_function_pointer(lib, setter_name)
                    call_rust_function(func_ptr, Cvoid, self.ptr, value)
                    return value
                else
                    return setfield!(self, field, value)
                end
            end
        end)
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

function _call_generic_field(lib_name::String, func_name::String, ptr::Ptr{Cvoid}, ret_type::Type, types::Tuple)
    generic_info = GENERIC_FUNCTION_REGISTRY[func_name]
    param_names = generic_info.type_params

    type_params = Dict{Symbol, Type}()
    for (i, p) in enumerate(param_names)
        type_params[p] = types[i]
    end

    info = monomorphize_function(func_name, type_params)
    return call_rust_function(info.func_ptr, ret_type, ptr)
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
        @eval RustCall.@rust $(Symbol(lib_func))(ptr::Ptr{Cvoid})::Cvoid
    end
end
