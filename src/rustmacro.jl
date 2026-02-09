# @rust macro implementation

"""
    @rust expr

Call a Rust function from Julia.

# Syntax
- `@rust func(args...)` - Call a function with automatic type inference
- `@rust func(args...)::RetType` - Call with explicit return type
- `@rust lib::func(args...)` - Call from a specific library

# Examples
```julia
# Simple call (types inferred from arguments)
@rust add(10i32, 20i32)

# With explicit return type
@rust add(10, 20)::Int32

# From specific library
@rust mylib::multiply(3.0, 4.0)
```
"""
macro rust(expr)
    return rust_impl(__module__, expr)
end

const RUST_COMPARISON_OPS = Set{Symbol}([
    Symbol("=="),
    Symbol("==="),
    Symbol("!="),
    Symbol("!=="),
    Symbol("<"),
    Symbol("<="),
    Symbol(">"),
    Symbol(">="),
    Symbol("\u2248"),
])

"""
    _rust_comparison_operand(mod, expr)

Process an operand of a comparison in `@rust`.  If the expression looks
like a Rust call (or qualified call), expand it via `rust_impl`; otherwise
just escape it so plain Julia values pass through unchanged.
"""
function _rust_comparison_operand(mod, expr)
    if isexpr(expr, :call)
        fname = expr.args[1]
        # Only treat as a Rust call if the function name is a plain identifier
        # (not a Julia operator like +, -, *, /).  Operator calls such as
        # `10.0 / 3.0` should stay on the Julia side.
        if fname isa Symbol && !Base.isoperator(fname)
            return rust_impl(mod, expr)
        end
    elseif isexpr(expr, :(::))
        return rust_impl(mod, expr)
    end
    return esc(expr)
end

"""
    rust_impl(mod, expr)

Implementation of the @rust macro.
"""
function rust_impl(mod, expr)
    if isexpr(expr, :call)
        op = expr.args[1]
        if op isa Symbol && op in RUST_COMPARISON_OPS
            if length(expr.args) != 3
                error("Invalid @rust syntax: $expr")
            end
            lhs = expr.args[2]
            rhs = expr.args[3]
            rust_lhs = _rust_comparison_operand(mod, lhs)
            rust_rhs = _rust_comparison_operand(mod, rhs)
            return Expr(:call, op, rust_lhs, rust_rhs)
        end
    end

    # Handle return type annotation:
    # - @rust func(args...)::Type
    # - @rust lib::func(args...)::Type
    if isexpr(expr, :(::))
        lhs = expr.args[1]
        ret_type = expr.args[2]

        # Qualified call with explicit return type
        qualified = _parse_qualified_call(lhs)
        if qualified !== nothing
            lib_name, call_expr = qualified
            return rust_impl_qualified(mod, lib_name, call_expr, ret_type)
        end

        # Regular typed call
        if isexpr(lhs, :call)
            return rust_impl_with_type(mod, lhs, ret_type)
        end

        # Qualified call without return type: @rust lib::func(args...)
        qualified = _parse_qualified_call(expr)
        if qualified !== nothing
            lib_name, call_expr = qualified
            return rust_impl_qualified(mod, lib_name, call_expr, nothing)
        end

        error("Expected function call before ::Type, got: $lhs")
    end

    # Handle library-qualified call: @rust lib::func(args...)
    qualified = _parse_qualified_call(expr)
    if qualified !== nothing
        lib_name, call_expr = qualified
        return rust_impl_qualified(mod, lib_name, call_expr, nothing)
    end

    # Handle simple function call: @rust func(args...)
    if isexpr(expr, :call)
        return rust_impl_call(mod, expr, nothing)
    end

    error("Invalid @rust syntax: $expr")
end

"""
    rust_impl_call(mod, expr, ret_type)

Handle a simple function call.
"""
function rust_impl_call(mod, expr, ret_type)
    func_name = expr.args[1]
    args = expr.args[2:end]

    func_name_str = string(func_name)
    escaped_args = [esc(arg) for arg in args]

    if ret_type === nothing
        # Dynamic dispatch based on argument types
        return Expr(:call, GlobalRef(RustCall, :_rust_call_dynamic),
                    Expr(:call, GlobalRef(RustCall, :_resolve_lib), mod, ""),
                    func_name_str, escaped_args...)
    else
        # Static dispatch with known return type
        return Expr(:call, GlobalRef(RustCall, :_rust_call_typed),
                    Expr(:call, GlobalRef(RustCall, :_resolve_lib), mod, ""),
                    func_name_str, esc(ret_type), escaped_args...)
    end
end

"""
    _resolve_lib(mod::Module, lib_name::String)

Resolve the actual library name to use, handling session-aware reloading for precompiled modules.

When a module has multiple `rust\"\"\"` blocks, all libraries are loaded to enable
the fallback function lookup across libraries in `get_function_pointer`.
"""
function _resolve_lib(mod::Module, lib_name::String)
    # Ensure ALL libraries from this module are loaded first
    # This is needed because get_function_pointer does fallback search across all libraries
    if isdefined(mod, :__RUSTCALL_LIBS)
        libs = getfield(mod, :__RUSTCALL_LIBS)
        for (lname, code) in libs
            ensure_loaded(lname, code)
        end
    end

    # If no library name specified (e.g. @rust func() without a prior rust"""..."""),
    # try to use the module's active library.
    if isempty(lib_name)
        if isdefined(mod, :__RUSTCALL_ACTIVE_LIB)
            lib_name = getfield(mod, :__RUSTCALL_ACTIVE_LIB)[]
        else
            return get_current_library()
        end
    end

    return lib_name
end

"""
    rust_impl_with_type(mod, call_expr, ret_type)

Handle a function call with explicit return type.
"""
function rust_impl_with_type(mod, call_expr, ret_type)
    if !isexpr(call_expr, :call)
        error("Expected function call before ::Type, got: $call_expr")
    end

    return rust_impl_call(mod, call_expr, ret_type)
end

"""
    rust_impl_qualified(mod, lib_name, call_expr, ret_type)

Handle a library-qualified function call: lib::func(args...)
"""
function rust_impl_qualified(mod, lib_name, call_expr, ret_type)
    func_name = call_expr.args[1]
    args = call_expr.args[2:end]
    lib_name_str = string(lib_name)
    func_name_str = string(func_name)
    escaped_args = map(esc, args)

    if ret_type === nothing
        return Expr(
            :call,
            GlobalRef(RustCall, :_rust_call_from_lib),
            Expr(:call, GlobalRef(RustCall, :_resolve_lib), mod, lib_name_str),
            func_name_str,
            escaped_args...
        )
    end

    return Expr(
        :call,
        GlobalRef(RustCall, :_rust_call_typed),
        Expr(:call, GlobalRef(RustCall, :_resolve_lib), mod, lib_name_str),
        func_name_str,
        esc(ret_type),
        escaped_args...
    )
end

"""
    _parse_qualified_call(expr) -> Union{Tuple{Any, Expr}, Nothing}

Parse `lib::func(args...)` into `(lib, call_expr)`.
"""
function _parse_qualified_call(expr)
    if isexpr(expr, :(::)) && length(expr.args) == 2
        lib_name = expr.args[1]
        call_expr = expr.args[2]
        if isexpr(call_expr, :call)
            return (lib_name, call_expr)
        end
    end

    if isexpr(expr, :call) && !isempty(expr.args) && isexpr(expr.args[1], :(::))
        qualified_name = expr.args[1]
        if length(qualified_name.args) == 2
            lib_name = qualified_name.args[1]
            func_name = qualified_name.args[2]
            call_expr = Expr(:call, func_name, expr.args[2:end]...)
            return (lib_name, call_expr)
        end
    end

    return nothing
end


"""
    _rust_call_dynamic(lib_name::String, func_name::String, args...)

Call a Rust function with dynamic type dispatch.
Automatically handles generic functions by monomorphizing them.
"""
function _rust_call_dynamic(lib_name::String, func_name::String, args...)
    # Check if this is a generic function
    if is_generic_function(func_name)
        # Handle as generic function - monomorphize and call
        return call_generic_function(func_name, args...)
    end

    # Regular function - use existing logic
    # Get function pointer
    @debug "Calling function '$func_name' from library '$lib_name'"
    func_ptr = get_function_pointer(lib_name, func_name)

    # Try to get type info from registered function info
    func_info = get_function_info(lib_name, func_name)
    if func_info !== nothing && func_info.return_type !== Any
        return call_rust_function(func_ptr, func_info.return_type, args...)
    end

    # Try to get return type from registries (library-scoped first, then fallback)
    ret_type = get_function_return_type(lib_name, func_name)
    if ret_type !== nothing
        @debug "Using registered return type for $func_name: $ret_type"
        return call_rust_function(func_ptr, ret_type, args...)
    end

    # Try to get type info from LLVM analysis
    try
        ret_type, expected_arg_types = infer_function_types(lib_name, func_name)
        return call_rust_function(func_ptr, ret_type, args...)
    catch
        # Fall back to inference from arguments
    end

    # Use inference from argument types
    return call_rust_function_infer(func_ptr, args...)
end

"""
    _rust_call_typed(lib_name::String, func_name::String, ret_type::Type, args...)

Call a Rust function with explicit return type.
"""
function _rust_call_typed(lib_name::String, func_name::String, ret_type::Type, args...)
    local func_ptr
    try
        func_ptr = get_function_pointer(lib_name, func_name)
    catch e
        # If not found, check if it's a generic function that needs monomorphization
        if is_generic_function(func_name)
            @debug "Function not found in library, but is registered as generic" func_name
            return call_generic_function(func_name, args...)
        else
            @debug "Function not found and is not registered as generic" func_name
            rethrow(e)
        end
    end

    return call_rust_function(func_ptr, ret_type, args...)
end

"""
    _rust_call_from_lib(lib_name::String, func_name::String, args...)

Call a Rust function from a specific library.
"""
function _rust_call_from_lib(lib_name::String, func_name::String, args...)
    return _rust_call_dynamic(lib_name, func_name, args...)
end

# Helper to check if an expression is of a specific form
isexpr(x, head) = isa(x, Expr) && x.head == head

"""
    @rust_register(func_name, ret_type, arg_types...)

Register a Rust function with its type signature for optimized calling.

# Example
```julia
@rust_register(add, Int32, Int32, Int32)
```
"""
macro rust_register(func_name, ret_type, arg_types...)
    func_name_str = string(func_name)
    arg_types_vec = collect(arg_types)

    return quote
        lib_name = $(GlobalRef(RustCall, :get_current_library))()
        $(GlobalRef(RustCall, :register_function))($(func_name_str), lib_name, $(esc(ret_type)), Type[$(map(esc, arg_types_vec)...)])
    end
end
