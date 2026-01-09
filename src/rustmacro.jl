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
    return rust_impl(__module__, expr, __source__)
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
    rust_impl(mod, expr, source)

Implementation of the @rust macro.
"""
function rust_impl(mod, expr, source)
    if isexpr(expr, :call)
        op = expr.args[1]
        if op isa Symbol && op in RUST_COMPARISON_OPS
            if length(expr.args) != 3
                error("Invalid @rust syntax: $expr")
            end
            lhs = expr.args[2]
            rhs = expr.args[3]
            rust_expr = rust_impl(mod, lhs, source)
            return Expr(:call, op, rust_expr, esc(rhs))
        end
    end

    # Handle return type annotation: @rust func(args...)::Type
    if isexpr(expr, :(::))
        call_expr = expr.args[1]
        ret_type = expr.args[2]
        return rust_impl_with_type(mod, call_expr, ret_type, source)
    end

    # Handle library-qualified call: @rust lib::func(args...)
    if isexpr(expr, :call) && isexpr(expr.args[1], :(::))
        return rust_impl_qualified(mod, expr, source)
    end

    # Handle simple function call: @rust func(args...)
    if isexpr(expr, :call)
        return rust_impl_call(mod, expr, nothing, source)
    end

    error("Invalid @rust syntax: $expr")
end

"""
    rust_impl_call(mod, expr, ret_type, source)

Handle a simple function call.
"""
function rust_impl_call(mod, expr, ret_type, source)
    func_name = expr.args[1]
    args = expr.args[2:end]

    func_name_str = string(func_name)
    escaped_args = [esc(arg) for arg in args]

    if ret_type === nothing
        # Dynamic dispatch based on argument types
        return Expr(:call, GlobalRef(LastCall, :_rust_call_dynamic),
                    Expr(:call, GlobalRef(LastCall, :get_current_library)),
                    func_name_str, escaped_args...)
    else
        # Static dispatch with known return type
        return Expr(:call, GlobalRef(LastCall, :_rust_call_typed),
                    Expr(:call, GlobalRef(LastCall, :get_current_library)),
                    func_name_str, esc(ret_type), escaped_args...)
    end
end

"""
    rust_impl_with_type(mod, call_expr, ret_type, source)

Handle a function call with explicit return type.
"""
function rust_impl_with_type(mod, call_expr, ret_type, source)
    if !isexpr(call_expr, :call)
        error("Expected function call before ::Type, got: $call_expr")
    end

    return rust_impl_call(mod, call_expr, ret_type, source)
end

"""
    rust_impl_qualified(mod, expr, source)

Handle a library-qualified function call: lib::func(args...)
"""
function rust_impl_qualified(mod, expr, source)
    qualified_name = expr.args[1]
    args = expr.args[2:end]

    # Extract library and function name
    lib_name = qualified_name.args[1]
    func_name = qualified_name.args[2]

    lib_name_str = string(lib_name)
    func_name_str = string(func_name)
    escaped_args = map(esc, args)

    return quote
        $(GlobalRef(LastCall, :_rust_call_from_lib))($(lib_name_str), $(func_name_str), $(escaped_args...))
    end
end

"""
    _convert_args_for_rust(args...)

Convert Julia arguments to Rust-compatible types.
String arguments are passed directly and converted by ccall.
"""
function _convert_args_for_rust(args...)
    # No conversion needed - ccall handles String -> Cstring
    return args
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
    func_ptr = get_function_pointer(lib_name, func_name)

    # Convert arguments (String -> Cstring)
    converted_args = _convert_args_for_rust(args...)

    # Try to get type info from LLVM analysis
    try
        ret_type, expected_arg_types = infer_function_types(lib_name, func_name)
        return call_rust_function(func_ptr, ret_type, converted_args...)
    catch
        # Fall back to inference from arguments
    end

    # Use inference from argument types
    return call_rust_function_infer(func_ptr, converted_args...)
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
            println("DEBUG: Function $func_name not found, but is generic. Calling call_generic_function...")
            return call_generic_function(func_name, args...)
        else
            println("DEBUG: Function $func_name not found and is NOT generic. (is_generic_function returned false)")
            rethrow(e)
        end
    end

    # Convert arguments (String -> Cstring)
    converted_args = _convert_args_for_rust(args...)
    return call_rust_function(func_ptr, ret_type, converted_args...)
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
        lib_name = $(GlobalRef(LastCall, :get_current_library))()
        $(GlobalRef(LastCall, :register_function))($(func_name_str), lib_name, $(esc(ret_type)), Type[$(map(esc, arg_types_vec)...)])
    end
end
