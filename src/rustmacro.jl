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

"""
    rust_impl(mod, expr, source)

Implementation of the @rust macro.
"""
function rust_impl(mod, expr, source)
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
    escaped_args = map(esc, args)

    if ret_type === nothing
        # Dynamic dispatch based on argument types
        return quote
            lib_name = get_current_library()
            _rust_call_dynamic(lib_name, $func_name_str, $(escaped_args...))
        end
    else
        # Static dispatch with known return type
        return quote
            lib_name = get_current_library()
            _rust_call_typed(lib_name, $func_name_str, $(esc(ret_type)), $(escaped_args...))
        end
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
        _rust_call_from_lib($lib_name_str, $func_name_str, $(escaped_args...))
    end
end

"""
    _rust_call_dynamic(lib_name::String, func_name::String, args...)

Call a Rust function with dynamic type dispatch.
"""
function _rust_call_dynamic(lib_name::String, func_name::String, args...)
    # Get function pointer
    func_ptr = get_function_pointer(lib_name, func_name)

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
    func_ptr = get_function_pointer(lib_name, func_name)
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
        lib_name = get_current_library()
        register_function($func_name_str, lib_name, $(esc(ret_type)), Type[$(map(esc, arg_types_vec)...)])
    end
end
