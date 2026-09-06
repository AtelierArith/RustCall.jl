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
    _alias_reloaded_library(mod, stored_name, actual_name)

A reload derived a different library name than the one a precompiled module
stored (the identity covers the toolchain fingerprint, compiler snapshot and
cfg text, any of which may have changed since precompilation). Register the
loaded handle under the stored name too, so the next `ensure_loaded` finds it
instead of reloading, and symbol lookups through the stored name hit this
library directly rather than the global fallback search. The module's active
library moves to the actual name, under which the manifest was registered.
"""
function _alias_reloaded_library(mod::Module, stored_name::String, actual_name::String)
    # `alias_artifact!` (src/loadpolicy.jl) owns the two-names-one-handle case:
    # both registries are per library (#279), so the alias gets its own symbol
    # mappings and return-type hints — without the mappings a lookup through
    # the stored name resolves `f` to `f`, misses the `rustcall_f` this library
    # exports and falls back to the cross-library search, which another block
    # defining `f` would make ambiguous; without the hints an untyped
    # `@rust f(...)` through the alias would pick up whatever another block
    # last registered for that name. The alias also shares the library's
    # liveness flag, so unloading either name retires both (#277 Phase B).
    alias_artifact!(inline_rustc_policy(), actual_name, stored_name)
    if isdefined(mod, :__RUSTCALL_ACTIVE_LIB)
        active = getfield(mod, :__RUSTCALL_ACTIVE_LIB)
        active[] == stored_name && (active[] = actual_name)
    end
    return nothing
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
        # `collect` first: a reload rebinds entries, and a Dict must not be
        # mutated while it is iterated.
        for (lname, code) in collect(libs)
            actual = ensure_loaded(lname, code)
            actual == lname && continue
            # The stored name no longer describes what was loaded — routine
            # since #278, because the identity covers the toolchain and the
            # compiler snapshot, and either may have changed since
            # precompilation. Alias so old callers still resolve, *and* rebind
            # the registry entry (and the module's active library, via
            # `_alias_reloaded_library`) to the name the manifest was actually
            # registered under, so the next `_resolve_lib` does not walk the
            # reload path all over again.
            _alias_reloaded_library(mod, lname, actual)
            libs[actual] = code
            delete!(libs, lname)
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
    # `@rust f(...)` names the Rust function; `#[julia]` exports the additive
    # wrapper `rustcall_f` next to it (#279). `_resolve_call` resolves that per
    # library and reports which library the pointer came from, so the return
    # type is read from that same library and never borrowed from another one
    # whose `f` has a different ABI.
    # One snapshot: pointer and panic channel from the same generation of the
    # same library. Resolving them separately let a reload land in between, so
    # the call entered the retired image and read the replacement's channel.
    target = resolve_call_target(lib_name, func_name)
    func_ptr = target.func_ptr
    channel = target.channel
    owning_lib = target.lib_name
    @debug "Calling function '$func_name' from library '$owning_lib'" generation = target.generation

    # Try to get type info from registered function info
    # Every call through a generated wrapper is followed by a read of that
    # wrapper's panic channel: a `#[julia]` function that panicked returned a
    # sentinel, and `guard_rust_panic_ptr` turns it into a `RustPanicError`
    # rather than letting the caller use it (#244). The symbol is the one the
    # pointer was resolved from, so the channel belongs to the same wrapper.
    #
    # The channel is resolved *here*, before any of the calls below: it is a
    # thread-local in the image, so nothing may yield between the wrapper call
    # and the read of the channel, and the resolution itself takes a lock.
    # ...and the *return ABI* comes from the same snapshot as the pointer. It
    # used to be looked up again here, so a reload landing in between could
    # call the retired generation's wrapper and read its result with the
    # replacement's return type — a scalar read as a struct (#277).
    func_info = target.func_info
    if func_info !== nothing && func_info.return_type !== Any
        return guard_rust_panic_ptr(call_rust_function(func_ptr, func_info.return_type, args...),
                                    channel, func_name)
    end

    # Try to get the return type the owning library registered — again, the one
    # captured in the snapshot.
    ret_type = target.return_type
    if ret_type !== nothing
        @debug "Using registered return type for $func_name: $ret_type"
        return guard_rust_panic_ptr(call_rust_function(func_ptr, ret_type, args...),
                                    channel, func_name)
    end

    # Try to get type info from LLVM analysis. The `try` covers the *inference*
    # and nothing else: it used to wrap the call as well, with a catch that
    # swallowed every exception but `RustPanicError`, so a fail-closed error
    # from the FFI type contract — an unregistered by-value aggregate (#245),
    # an invalid-UTF-8 argument (#246) — was replaced by the unrelated "no
    # return type" message below. Swallowing a fail-closed error is the
    # fail-open pattern the contract exists to remove.
    inferred = try
        infer_function_types(lib_name, func_name)
    catch e
        e isa SignatureInferenceError || rethrow()
        nothing
    end
    if inferred !== nothing
        inferred_ret, _ = inferred
        return guard_rust_panic_ptr(call_rust_function(func_ptr, inferred_ret, args...),
                                    channel, func_name)
    end

    # No last resort. Guessing the return type from the first argument was the
    # #245 / #246 shape: the guess is not derivable from an argument, and a
    # return slot read at the wrong width is undefined behaviour (#276).
    throw(RustError(
        "`@rust $func_name(...)` has no return type: the manifest records none " *
        "for '$func_name' in library '$lib_name', and RustCall no longer " *
        "guesses one from the arguments (#245, #246). Annotate the call — " *
        "`@rust $func_name(...)::T` — or mark the Rust function `#[julia]` so " *
        "the manifest reports its return type."))
end

"""
    _rust_call_typed(lib_name::String, func_name::String, ret_type::Type, args...)

Call a Rust function with explicit return type.
"""
function _rust_call_typed(lib_name::String, func_name::String, ret_type::Type, args...)
    local target
    try
        target = resolve_call_target(lib_name, func_name)
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

    # An annotation that contradicts the manifest is an error, not an override
    # (#245). `@rust f(x)::Float64` on a function the manifest records as
    # `-> i32` used to reinterpret the 32-bit result as a `Float64` and return
    # silent garbage; the declared type and the recorded one come from the same
    # snapshot, so comparing them costs nothing.
    _check_return_annotation(target, func_name, ret_type)

    # Pointer and channel come from the same snapshot, so the call and the
    # channel read cannot straddle two generations (#244, #277).
    return guard_rust_panic_ptr(call_rust_function(target.func_ptr, ret_type, args...),
                                target.channel, func_name)
end

"""
    _snapshot_return_type(target) -> Union{Type, Nothing}

The return type the resolved generation records for this symbol: the richer
`FunctionInfo` first, then the per-library hint, and `nothing` when neither
says anything. Read from the snapshot only — never looked up again by name,
which is the #277 rule.
"""
function _snapshot_return_type(target)
    info = target.func_info
    if info !== nothing && info.return_type !== Any
        return info.return_type
    end
    recorded = target.return_type
    return recorded === Any ? nothing : recorded
end

"""
    _return_annotation_agrees(declared, recorded) -> Bool

Whether a `::T` annotation says the same thing as the return type the manifest
recorded.

Identity is not the test, because the manifest records the **C slot** while an
annotation names the **surface** type a caller sees, and the two differ where
the contract says they do: Rust `char` is a `UInt32` code point in the slot and
a `Char` on the surface, `bool` is a `UInt8` and a `Bool`. `@rust f()::Char` on
a `-> char` was a correct call before #245 added this check and must stay one.

Two types agree when they lower to the same `ccall` return slot: the generated
call is then byte-for-byte the same and only `convert_return` differs, which is
the conversion the annotation was asking for. `::Float64` on a `-> i32` does
*not* agree — different slot, and reading one as the other is undefined
behaviour.
"""
_return_annotation_agrees(declared::Type, recorded::Type) =
    declared === recorded || ccall_return_type(declared) === ccall_return_type(recorded)

"""
    _check_return_annotation(target, func_name, declared)

Raise when a `::T` annotation disagrees with the return type the manifest
recorded for `func_name`, naming both (#245).

An annotation exists to supply a return type RustCall does not know. When it
*is* known, a differing annotation is not an override — the ccall would read
the return slot at the wrong width or in the wrong register class, which is
undefined behaviour, not a cast. `Cvoid === Nothing` and `Cstring ===
Ptr{UInt8}` are the same type to `===`, so aliases never trip this, and neither
does a **surface** annotation over the slot the manifest records
(`_return_annotation_agrees`).
"""
function _check_return_annotation(target, func_name::AbstractString, declared::Type)
    recorded = _snapshot_return_type(target)
    (recorded === nothing || _return_annotation_agrees(declared, recorded)) && return nothing
    throw(RustError(
        "return type annotation `::$declared` on `@rust $func_name(...)` " *
        "disagrees with the manifest, which records `$recorded` for " *
        "'$func_name' in library '$(target.lib_name)' (#245). Reading a " *
        "`$recorded` return slot as a `$declared` is undefined behaviour, not " *
        "a conversion. Drop the annotation and let the manifest decide, " *
        "write `::$recorded`, or change the Rust signature — and convert the " *
        "result on the Julia side if you wanted a `$declared`."))
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
