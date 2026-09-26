function _generate_crate_function_wrapper(func::RustFunctionSignature)
    # The item every position below is filed under (#454), named before the
    # argument plan, which records first.
    _boundary_item!(_boundary_label(func))
    # An item the Rust codegen refuses gets no wrapper (#491).
    _rust_refused_item!(func.skip_reason, func.name) && return Expr(:block)
    func_name = Symbol(julia_function_name(func))
    func_name_str = String(func_name)
    # The Julia wrapper keeps the Rust name; the exported symbol it calls is
    # `rustcall_<name>` since #279 (the helper types stay name-derived).
    symbol_str = func.symbol

    # Build argument list
    arg_syms = [Symbol(name) for name in func.arg_names]

    # Build converted arguments (string arguments become (ptr, len) pairs kept
    # alive with GC.@preserve, see `_string_arg_plan`)
    bindings, preserved, converted_args, frame = _string_arg_plan(func, identity)

    # Result<T, E> / Option<T> returns are reported by the manifest
    if func.return_kind == :result
        return _generate_result_function_wrapper(func, arg_syms, bindings, preserved, converted_args, frame)
    elseif func.return_kind == :py_result
        return _generate_py_result_function_wrapper(func, arg_syms, bindings, preserved,
                                                    converted_args, frame)
    elseif func.return_kind == :option
        return _generate_option_function_wrapper(func, arg_syms, bindings, preserved, converted_args, frame)
    elseif _uses_string_ffi(func)
        return _generate_string_function_wrapper(func, arg_syms)
    else
        # Standard function wrapper. The one return decision (#276).
        julia_ret_type = _emitted_type(ffi_return_symbol_or_throw(func.return_type, func.return_abi,
                                                    _ffi_context(func)))

        ptr_sym = _generated_local("func_ptr", func.arg_names)
        channel_sym = _generated_local("panic_channel", func.arg_names)
        cache_sym = _target_cache_name(:fn, symbol_str)
        @_emitted quote
            $(_target_cache_const(:fn, symbol_str))
            function $func_name($(arg_syms...))
                $ptr_sym, $channel_sym = _call_target($cache_sym, $symbol_str)
                _guard_panic(
                    call_rust_function($ptr_sym, $julia_ret_type, $(converted_args...)),
                    $channel_sym, $func_name_str)
            end
            export $func_name
        end
    end
end

"""
    _generate_string_function_wrapper(func, arg_syms) -> Expr

Wrapper for a `#[julia]` function with `String` / `&str` arguments or return
(#242): arguments are passed as `(ptr, len)` pairs under `GC.@preserve`, a
`String` return is copied out of `<fn>_RustCallOwnedString` and released with
`<fn>_free_rust_string`, a `&str` return is copied out of the borrowed view.
"""
function _generate_string_function_wrapper(func::RustFunctionSignature, arg_syms::Vector{Symbol})
    func_name = Symbol(julia_function_name(func))
    func_name_str = String(func_name)
    # The Julia wrapper keeps the Rust name; the exported symbol it calls is
    # `rustcall_<name>` since #279 (the helper types stay name-derived).
    symbol_str = func.symbol
    bindings, preserved, call_args, frame = _string_arg_plan(func, identity)
    # The helper types are named after the Rust item's FFI name, so that is the
    # owner and the contract derives `free_symbol` from it (#276, #300).
    c = _ffi_function_return(func)
    # Declared before the call expression is built, since it names them.
    channel_sym = _generated_local("panic_channel", func.arg_names)
    ptr_sym = _generated_local("func_ptr", func.arg_names)
    free_sym = _generated_local("free_ptr", func.arg_names)
    cache_sym = _target_cache_name(:fn, symbol_str)
    # The owned-string branch snapshots the release function with the call; see
    # `_call_target`'s three-argument arm.
    target = @_emitted(:(($ptr_sym, $channel_sym) = _call_target($cache_sym, $symbol_str)))
    call = if ffi_owned_string_return(c)
        target = @_emitted(:(($ptr_sym, $channel_sym, $free_sym) = _call_target($cache_sym, $symbol_str, $(c.free_symbol))))
        @_emitted(:(_call_rust_owned_string_ptr($ptr_sym, $free_sym, $(call_args...))))
    elseif ffi_borrowed_string_return(c)
        @_emitted(:(_call_rust_borrowed_string_ptr($ptr_sym, $(call_args...))))
    else
        ret = _emitted_type(ffi_return_symbol_or_throw(func.return_type, func.return_abi,
                                         _ffi_context(func)))
        @_emitted(:(call_rust_function($ptr_sym, $ret, $(call_args...))))
    end
    # The string paths return a buffer the wrapper filled; on a panic it is the
    # empty sentinel, which would decode to `""`, so the channel is read before
    # the value is used — and resolved, with the pointer, before the call
    # (#244, #277).
    call = @_emitted(:(_guard_panic($call, $channel_sym, $func_name_str)))
    @_emitted quote
        $(_target_cache_const(:fn, symbol_str))
        function $func_name($(arg_syms...))
            $target
            $(bindings...)
            $(_in_callback_frame(frame, @_emitted(:(GC.@preserve $(preserved...) begin
                $call
            end))))
        end
        export $func_name
    end
end

"""
    _generate_result_function_wrapper(func, result_info, arg_syms, converted_args) -> Expr

Generate a Julia wrapper for a function that returns Result<T, E>.
The wrapper will return RustResult{T, E}.
"""
function _generate_result_function_wrapper(func::RustFunctionSignature, arg_syms::Vector{Symbol},
                                           bindings::Vector, preserved::Vector, converted_args::Vector,
                                           frame::Union{Nothing, Symbol} = nothing)
    func_name = Symbol(julia_function_name(func))
    func_name_str = String(func_name)
    # The Julia wrapper keeps the Rust name; the exported symbol it calls is
    # `rustcall_<name>` since #279 (the helper types stay name-derived).
    symbol_str = func.symbol

    # The payloads are FIELDS of a `#[repr(C)]` aggregate: declared with the C
    # slot Rust stored, converted to the surface type after the call. They
    # differ for `char`, whose slot is a `UInt32` code point (#245).
    ctx = _ffi_context(func)
    ok_julia_type, ok_slot_type = _emitted_type(ffi_payload_symbols(func.ok_type, func.ok_abi, ctx;
                                                      position = "Ok payload"))
    err_julia_type, err_slot_type = _emitted_type(ffi_payload_symbols(func.err_type, func.err_abi, ctx;
                                                        position = "Err payload"))
    # An owned-string payload is released through the function's own
    # `<fn>_free_rust_string`, snapshotted with the call pointer (#268, #277);
    # `<fn>` is the FFI name (#300).
    free_str = _payload_free_symbol(func.ffi_name, (func.ok_abi, func.err_abi))

    # The C-compatible struct name generated by the proc-macro
    c_result_struct_name = Symbol("CResult_", func.ffi_name)
    ptr_sym = _generated_local("func_ptr", func.arg_names)
    c_sym = _generated_local("c_result", func.arg_names)
    channel_sym = _generated_local("panic_channel", func.arg_names)
    free_sym = _generated_local("free_ptr", func.arg_names)
    cache_sym = _target_cache_name(:fn, symbol_str)
    target = isempty(free_str) ?
        @_emitted(:(($ptr_sym, $channel_sym) = _call_target($cache_sym, $symbol_str))) :
        @_emitted(:(($ptr_sym, $channel_sym, $free_sym) = _call_target($cache_sym, $symbol_str, $free_str)))
    free_expr = isempty(free_str) ? @_emitted(:(C_NULL)) : free_sym

    @_emitted quote
        $(_target_cache_const(:fn, symbol_str))
        # Define the C-compatible struct for this function's result
        # RustCall's own mirror of the extractor's `#[repr(C)]` aggregate, so
        # it carries the by-value layout assertion in its supertype (#245) —
        # a static property that survives this module being precompiled into a
        # downstream package, which a registry mutation would not.
        struct $c_result_struct_name <: FFIByValue
            is_ok::UInt8
            ok_value::$ok_slot_type
            err_value::$err_slot_type
        end

        function $func_name($(arg_syms...))
            # String arguments are converted first: an argument may be called
            # `func_ptr`, so the pointer local is resolved only afterwards.
            $(bindings...)
            $target
            $c_sym = $(_in_callback_frame(frame, @_emitted(:(GC.@preserve $(preserved...) call_rust_function($ptr_sym, $c_result_struct_name, $(converted_args...))))))
            # A panic returns `CResult::panicked()` — the Err discriminant with
            # an uninitialized payload — so the channel is read before the
            # payload is decoded, and resolved before the call (#244).
            _guard_panic($c_sym, $channel_sym, $func_name_str, $free_expr)
            # Convert to RustResult; an owned-string payload is copied out and
            # released here, and only on the branch that owns it (#268).
            if $c_sym.is_ok == 1
                RustResult{$ok_julia_type, $err_julia_type}(true, _result_payload($ok_julia_type, $c_sym.ok_value, $free_expr))
            else
                RustResult{$ok_julia_type, $err_julia_type}(false, _result_payload($err_julia_type, $c_sym.err_value, $free_expr))
            end
        end
        export $func_name
    end
end

"""
    _py_result_types(ok_type, ok_abi, context; strict) -> (surface, slot, is_unit)

How a lowered `PyResult<T>` is read on the Julia side (#275 Phase 2).

The wrapper returns `CResult_<owner> { is_ok: u8, ok_value: <slot>,
err_value: i32 }`. `slot` is the C field type, `surface` is what the caller
sees, and `is_unit` says the `Ok` payload is a placeholder: a `PyResult<()>`
still has to report success or failure, so the wrapper writes a `u8` there and
Julia hands back `nothing`.

The error side is not a type at all — it is always `PYO3_OPAQUE_ERROR`, because
the generated wrapper drops the `PyErr` without ever rendering it.
"""
function _py_result_types(ok_type::AbstractString, ok_abi::AbstractString,
                          context::AbstractString;
                          strict::Symbol = _ffi_strict())
    if isempty(strip(String(ok_type))) || strip(String(ok_type)) == "()"
        return (:Nothing, :UInt8, true)
    end
    surface, slot = _emitted_type(ffi_payload_symbols(String(ok_type), String(ok_abi), context;
                                        position = "Ok payload", strict = strict))
    return (surface, slot, false)
end

"""
    _generate_py_result_function_wrapper(func, arg_syms, bindings, preserved, converted_args) -> Expr

Julia wrapper for a scanned `#[pyfunction]` returning `PyResult<T>` (#275
Phase 2). The result is a `RustResult{T, String}` whose error value is the fixed
`PYO3_OPAQUE_ERROR`: the wrapper reports only that *some* Python-side error
occurred, because rendering a `PyErr` without an interpreter panics inside pyo3
and the panic crossing `extern "C"` would abort the process.
"""
function _generate_py_result_function_wrapper(func::RustFunctionSignature, arg_syms::Vector{Symbol},
                                              bindings::Vector, preserved::Vector,
                                              converted_args::Vector,
                                              frame::Union{Nothing, Symbol} = nothing)
    func_name = Symbol(julia_function_name(func))
    func_name_str = String(func_name)
    symbol_str = func.symbol
    ok_julia_type, ok_slot_type, is_unit =
        _emitted_type(_py_result_types(func.ok_type, func.ok_abi, _ffi_context(func)))

    c_result_struct_name = Symbol("CResult_", func.ffi_name)
    ptr_sym = _generated_local("func_ptr", func.arg_names)
    c_sym = _generated_local("c_result", func.arg_names)
    channel_sym = _generated_local("panic_channel", func.arg_names)
    free_sym = _generated_local("free_ptr", func.arg_names)
    free_str = _payload_free_symbol(func.ffi_name, (func.ok_abi,))
    cache_sym = _target_cache_name(:fn, symbol_str)
    target = isempty(free_str) ?
        @_emitted(:(($ptr_sym, $channel_sym) = _call_target($cache_sym, $symbol_str))) :
        @_emitted(:(($ptr_sym, $channel_sym, $free_sym) = _call_target($cache_sym, $symbol_str, $free_str)))
    free_expr = isempty(free_str) ? @_emitted(:(C_NULL)) : free_sym
    ok_value = is_unit ? :nothing :
        @_emitted(:(_result_payload($ok_julia_type, $c_sym.ok_value, $free_expr)))

    @_emitted quote
        $(_target_cache_const(:fn, symbol_str))
        # `<: FFIByValue` is RustCall's own by-value layout assertion about a
        # mirror it generated (#245): the wrapper crate declares this aggregate
        # `#[repr(C)]` through the same `generate_c_result_type` the `#[julia]`
        # path uses, so the claim is identical.
        struct $c_result_struct_name <: FFIByValue
            is_ok::UInt8
            ok_value::$ok_slot_type
            # Always `RustCall.PYO3_ERROR_CODE`; the message is fixed.
            err_value::Int32
        end

        function $func_name($(arg_syms...))
            $(bindings...)
            $target
            $c_sym = $(_in_callback_frame(frame, @_emitted(:(GC.@preserve $(preserved...) call_rust_function($ptr_sym, $c_result_struct_name, $(converted_args...))))))
            # A panic returns the Err discriminant with an uninitialized
            # payload, so the channel is read before anything is decoded (#244).
            _guard_panic($c_sym, $channel_sym, $func_name_str, $free_expr)
            if $c_sym.is_ok == 1
                RustResult{$ok_julia_type, String}(true, $ok_value)
            else
                RustResult{$ok_julia_type, String}(false, RustCall.PYO3_OPAQUE_ERROR)
            end
        end
        export $func_name
    end
end

"""
    _generate_option_function_wrapper(func, option_info, arg_syms, converted_args) -> Expr

Generate a Julia wrapper for a function that returns Option<T>.
The wrapper will return RustOption{T}.
"""
function _generate_option_function_wrapper(func::RustFunctionSignature, arg_syms::Vector{Symbol},
                                           bindings::Vector, preserved::Vector, converted_args::Vector,
                                           frame::Union{Nothing, Symbol} = nothing)
    func_name = Symbol(julia_function_name(func))
    func_name_str = String(func_name)
    # The Julia wrapper keeps the Rust name; the exported symbol it calls is
    # `rustcall_<name>` since #279 (the helper types stay name-derived).
    symbol_str = func.symbol

    # See `_generate_result_function_wrapper`: the payload field holds the C
    # slot, the surface type is what the caller sees.
    inner_julia_type, inner_slot_type =
        _emitted_type(ffi_payload_symbols(func.inner_type, func.inner_abi, _ffi_context(func);
                            position = "Some payload"))
    free_str = _payload_free_symbol(func.ffi_name, (func.inner_abi,))

    # The C-compatible struct name generated by the proc-macro
    c_option_struct_name = Symbol("COption_", func.ffi_name)
    ptr_sym = _generated_local("func_ptr", func.arg_names)
    c_sym = _generated_local("c_option", func.arg_names)
    channel_sym = _generated_local("panic_channel", func.arg_names)
    free_sym = _generated_local("free_ptr", func.arg_names)
    cache_sym = _target_cache_name(:fn, symbol_str)
    target = isempty(free_str) ?
        @_emitted(:(($ptr_sym, $channel_sym) = _call_target($cache_sym, $symbol_str))) :
        @_emitted(:(($ptr_sym, $channel_sym, $free_sym) = _call_target($cache_sym, $symbol_str, $free_str)))
    free_expr = isempty(free_str) ? @_emitted(:(C_NULL)) : free_sym

    @_emitted quote
        $(_target_cache_const(:fn, symbol_str))
        # Define the C-compatible struct for this function's option
        # See the Result wrapper: RustCall's own mirror (#245).
        struct $c_option_struct_name <: FFIByValue
            is_some::UInt8
            value::$inner_slot_type
        end

        function $func_name($(arg_syms...))
            # String arguments are converted first: an argument may be called
            # `func_ptr`, so the pointer local is resolved only afterwards.
            $(bindings...)
            $target
            $c_sym = $(_in_callback_frame(frame, @_emitted(:(GC.@preserve $(preserved...) call_rust_function($ptr_sym, $c_option_struct_name, $(converted_args...))))))
            _guard_panic($c_sym, $channel_sym, $func_name_str, $free_expr)
            # Convert to RustOption
            if $c_sym.is_some == 1
                RustOption{$inner_julia_type}(true, _result_payload($inner_julia_type, $c_sym.value, $free_expr))
            else
                RustOption{$inner_julia_type}(false, nothing)
            end
        end
        export $func_name
    end
end

function _struct_wrappers_expr(structs, colliding::Set{String})
    exprs = Expr[]

    for s in structs
        wrapper = _generate_crate_struct_wrapper(s; colliding = colliding)
        push!(exprs, wrapper)
    end

    if isempty(exprs)
        return :()
    end

    Expr(:block, exprs...)
end

"""
    _static_method_collisions(info::CrateInfo) -> Set{String}

The names a static (non-constructor) `#[julia]` method shares with a free
function or with another struct's static method in the same crate.

A static method is bound as `name(::Type{Struct}, args...)` (#323); it also gets
the bare `name(args...)` form for convenience, but only when nothing else in the
generated module would define `name(args...)` too — two such definitions
overwrite each other (silently under `@rust_crate`, a hard error when a written
module is precompiled). Free functions always keep their bare name; the static
method yields.
"""
_static_method_collisions(info::CrateInfo) =
    _static_method_collisions(info.julia_functions, info.julia_structs)

function _generate_crate_struct_wrapper(info::RustStructInfo;
                                        colliding::Set{String} = Set{String}())
    # A struct the Rust codegen refuses (a generic crate struct, #462) gets no
    # Julia type; the report names it at its entry point (#503).
    if !_binds_julia_struct(info)
        _boundary_item!(_boundary_label(info))
        _rust_refused_item!(info.skip_reason, info.name)
        return Expr(:block)
    end
    struct_name_str = julia_struct_name(info)
    struct_name = Symbol(struct_name_str)
    release_alive = _python_owned_handle(info) ? @_emitted(:(Ref(true))) : _emitter_local("alive")

    # Start with struct definition
    exprs = Expr[]

    free_symbol = ffi_struct_free_symbol(info.ffi_name)
    free_cache = _target_cache_name(:free, free_symbol)

    # Define the wrapper struct
    push!(exprs, @_emitted quote
        $(_target_cache_const(:free, free_symbol))
        mutable struct $struct_name
            ptr::Ptr{Cvoid}
            free_ptr::Ptr{Cvoid}
            alive::Base.RefValue{Bool}
            free_channel::Ptr{Cvoid}

            # The destructor and the liveness flag are handed in by the call
            # that allocated `ptr`, from that call's own snapshot: a finalizer
            # must do no `dlsym` and compile no method (#249), and resolving
            # them after the constructor returned could pair a pointer from the
            # retired image with the replacement's destructor (#277).
            function $struct_name(rustcall′ptr::Ptr{Cvoid}, rustcall′free_ptr::Ptr{Cvoid},
                                  rustcall′alive::Base.RefValue{Bool},
                                  rustcall′free_channel::Ptr{Cvoid} = C_NULL)
                rustcall′obj = new(rustcall′ptr, rustcall′free_ptr, rustcall′alive,
                                   rustcall′free_channel)
                finalizer(RustCall.finalize_rust_object!, rustcall′obj)
                return rustcall′obj
            end

            # For a pointer that did not come from a call of this module.
            function $struct_name(rustcall′ptr::Ptr{Cvoid})
                rustcall′free_ptr, rustcall′alive, rustcall′free_channel =
                    _struct_generation($free_cache, $free_symbol)
                return $struct_name(rustcall′ptr, rustcall′free_ptr, $release_alive,
                                    rustcall′free_channel)
            end
        end
        export $struct_name

        function Base.show(rustcall′io::IO, rustcall′self::$struct_name)
            print(rustcall′io, nameof(@__MODULE__), ".", $struct_name_str, "(")
            show(rustcall′io, getfield(rustcall′self, :ptr))
            print(rustcall′io, ")")
        end

        function Base.show(rustcall′io::IO, ::MIME"text/plain", rustcall′self::$struct_name)
            Base.show(rustcall′io, rustcall′self)
        end
    end)

    # Generate constructor and method wrappers
    for m in info.methods
        method_wrapper = _generate_crate_method_wrapper(info, m;
                                                        bare = !(julia_method_name(m) in colliding))
        push!(exprs, method_wrapper)
    end

    # Generate field accessors (get_field, set_field! functions), for every
    # field the manifest names an accessor of — a setter alone included.
    for (field_name, field_type) in info.fields
        if field_is_accessible(info, field_name) || field_is_writable(info, field_name)
            accessor_wrapper = _generate_crate_field_accessor(info, field_name, field_type)
            push!(exprs, accessor_wrapper)
        end
    end

    # Generate getproperty/setproperty! for natural field access syntax
    property_accessors = _generate_property_accessors(info)
    if property_accessors !== nothing
        push!(exprs, property_accessors)
    end

    Expr(:block, exprs...)
end

_python_owned_handle(info::RustStructInfo) = info.python_owned_handle

"""
    _crate_field_read(info, field_name, field_type, ptr_expr, self_ptr_expr) -> Expr

How a crate-mode field getter is *read*: the one decision, from
`ffi_return_contract`. A field whose manifest `abi` is `"string"` comes back as
an owned `<Struct>_RustCallOwnedString` buffer released through the contract's
`free_symbol`; every other field is a single C slot.
"""
function _crate_field_read(info::RustStructInfo, field_name::AbstractString,
                           field_type::AbstractString, getter_symbol::AbstractString,
                           self_ptr_expr, cache::Symbol)
    c = _ffi_field_return(info, field_name, field_type)
    name = String(getter_symbol)
    if ffi_owned_string_return(c)
        # Getter and release function from one snapshot: separately resolved,
        # a reload between them freed the buffer through the wrong image (#277).
        return @_emitted quote
            let (rustcall′fp, rustcall′channel, rustcall′freep) = _call_target($cache, $name, $(c.free_symbol))
                rustcall′raw = _guard_panic(call_rust_function(rustcall′fp, RustCall.CRustString, $self_ptr_expr), rustcall′channel, $name, rustcall′freep)
                RustCall._take_owned_string(rustcall′raw, rustcall′freep)
            end
        end
    elseif ffi_owned_vec_return(c)
        element_type = c.surface_type.parameters[1]
        return @_emitted quote
            let (rustcall′fp, rustcall′channel, rustcall′freep, rustcall′alive) = _vec_target($cache, $name, $(c.free_symbol))
                rustcall′raw = _guard_panic(call_rust_function(rustcall′fp, RustCall.CRustVec, $self_ptr_expr), rustcall′channel, $name)
                RustCall.RustVec{$element_type}(rustcall′raw.ptr, rustcall′raw.len, rustcall′raw.cap, (rustcall′freep, rustcall′alive))
            end
        end
    elseif ffi_borrowed_string_return(c)
        return @_emitted quote
            let (rustcall′fp, rustcall′channel) = _call_target($cache, $name)
                rustcall′raw = _guard_panic(call_rust_function(rustcall′fp, RustCall.CRustStr, $self_ptr_expr), rustcall′channel, $name)
                RustCall._crust_str_to_julia(rustcall′raw)
            end
        end
    end
    julia_type = _emitted_type(ffi_return_symbol_or_throw(field_type, get(info.field_abis, field_name, ""),
                                            _ffi_field_context(info, field_name, field_type);
                                            position = _ffi_field_position(info, field_name)))
    return @_emitted quote
        let (rustcall′fp, rustcall′channel) = _call_target($cache, $name)
            _guard_panic(call_rust_function(rustcall′fp, $julia_type, $self_ptr_expr), rustcall′channel, $name)
        end
    end
end

"""
    _crate_field_write(info, field_name, field_type, setter_symbol, self_ptr_expr, value_expr) -> Expr

The call a field setter makes, with the value **converted to the field's
surface type first**. `call_rust_function` derives the `ccall` signature from
the runtime type of each argument, so passing `value` through as it came meant
`set_scale!(obj, 3)` on an `f64` field put an `Int64` in an integer register
while Rust read an `f64` from a floating-point one — garbage stored, or worse
(#307 review). The type is the one the getter reads the field back as
(`ffi_return_symbol_or_throw`), so the two directions agree, and the
conversion raises on a value that does not fit rather than reinterpreting it.
"""
function _crate_field_write(info::RustStructInfo, field_name::AbstractString,
                            field_type::AbstractString, setter_symbol::AbstractString,
                            self_ptr_expr, value_expr, cache::Symbol)
    name = String(setter_symbol)
    if get(info.field_abis, field_name, "") == "vec"
        element_type = ffi_vec_element_type(get(info.field_vec_elements, field_name, ""))
        return @_emitted quote
            let rustcall′values = collect($element_type, $value_expr),
                (rustcall′fp, rustcall′channel) = _call_target($cache, $name)
                GC.@preserve rustcall′values begin
                    _guard_panic(call_rust_function(rustcall′fp, Cvoid, $self_ptr_expr,
                                                    pointer(rustcall′values), Csize_t(length(rustcall′values))),
                                 rustcall′channel, $name)
                end
            end
        end
    end
    c = _ffi_field_return(info, field_name, field_type)
    if ffi_owned_string_return(c)
        # Match the wrapper's byte pointer/length input; never pass Rust String
        # by value or truncate an embedded NUL through a C string.
        return @_emitted quote
            let rustcall′text = RustCall.ffi_string_argument($value_expr, "value", $name),
                (rustcall′fp, rustcall′channel) = _call_target($cache, $name)
                GC.@preserve rustcall′text begin
                    _guard_panic(call_rust_function(rustcall′fp, Cvoid, $self_ptr_expr, pointer(rustcall′text), Csize_t(ncodeunits(rustcall′text))), rustcall′channel, $name)
                end
            end
        end
    elseif ffi_borrowed_string_return(c)
        return @_emitted quote
            let (rustcall′fp, rustcall′channel) = _call_target($cache, $name)
                _guard_panic(call_rust_function(rustcall′fp, Cvoid, $self_ptr_expr, $value_expr), rustcall′channel, $name)
            end
        end
    end
    julia_type = _emitted_type(ffi_return_symbol_or_throw(field_type, get(info.field_abis, field_name, ""),
                                            _ffi_field_context(info, field_name, field_type);
                                            position = _ffi_field_position(info, field_name)))
    return @_emitted quote
        let rustcall′value = convert($julia_type, $value_expr), (rustcall′fp, rustcall′channel) = _call_target($cache, $name)
            _guard_panic(call_rust_function(rustcall′fp, Cvoid, $self_ptr_expr, rustcall′value), rustcall′channel, $name)
        end
    end
end

"""
    _crate_field_write_source(info, field_name, field_type, setter_symbol, self_ptr, value; strict) -> String

Source-text counterpart of `_crate_field_write` for the file emitter.
"""
function _crate_field_write_source(info::RustStructInfo, field_name::AbstractString,
                                   field_type::AbstractString, setter_symbol::AbstractString,
                                   self_ptr::String, value::String, cache::AbstractString;
                                   strict::Symbol = _ffi_strict())
    target = "(rustcall′fp, rustcall′channel) = _call_target($cache, \"$setter_symbol\")"
    if get(info.field_abis, field_name, "") == "vec"
        element_type = _emitted_type_source(ffi_type_expr(ffi_vec_element_type(get(info.field_vec_elements, field_name, ""))))
        return "let rustcall′values = rustcall′Base.collect($element_type, $value), $target; " *
               "rustcall′Base.GC.@preserve rustcall′values begin _guard_panic(rustcall′RustCall.call_rust_function(rustcall′fp, rustcall′Base.Cvoid, $self_ptr, rustcall′Base.pointer(rustcall′values), rustcall′Base.Csize_t(rustcall′Base.length(rustcall′values))), rustcall′channel, \"$setter_symbol\"); end; end"
    end
    c = _ffi_field_return(info, field_name, field_type)
    if ffi_owned_string_return(c)
        return "let rustcall′text = rustcall′RustCall.ffi_string_argument($value, \"value\", \"$setter_symbol\"), $target; " *
               "rustcall′Base.GC.@preserve rustcall′text begin _guard_panic(rustcall′RustCall.call_rust_function(rustcall′fp, rustcall′Base.Cvoid, $self_ptr, rustcall′Base.pointer(rustcall′text), rustcall′Base.Csize_t(rustcall′Base.ncodeunits(rustcall′text))), rustcall′channel, \"$setter_symbol\"); end; end"
    elseif ffi_borrowed_string_return(c)
        return "let $target; _guard_panic(rustcall′RustCall.call_rust_function(rustcall′fp, rustcall′Base.Cvoid, $self_ptr, $value), rustcall′channel, \"$setter_symbol\"); end"
    end
    julia_type = _emitted_type(ffi_return_symbol_or_throw(field_type, get(info.field_abis, field_name, ""),
                                            _ffi_field_context(info, field_name, field_type);
                                            strict = strict,
                                            position = _ffi_field_position(info, field_name)))
    return "let rustcall′converted_value = rustcall′Base.convert($(_emitted_source(julia_type)), $value), $target; " *
           "_guard_panic(rustcall′RustCall.call_rust_function(rustcall′fp, rustcall′Base.Cvoid, $self_ptr, rustcall′converted_value), rustcall′channel, \"$setter_symbol\"); end"
end

"""
    _crate_field_read_source(info, field_name, field_type, ptr_var, self_ptr) -> String

Source-text counterpart of `_crate_field_read` for the file emitter.
"""
function _crate_field_read_source(info::RustStructInfo, field_name::AbstractString,
                                  field_type::AbstractString, getter_symbol::AbstractString,
                                  self_ptr::String, cache::AbstractString; strict::Symbol = _ffi_strict())
    c = _ffi_field_return(info, field_name, field_type)
    target = "(rustcall′fp, rustcall′channel) = _call_target($cache, \"$getter_symbol\")"
    if ffi_owned_string_return(c)
        # Getter and release function from one snapshot (#277).
        return "let (rustcall′fp, rustcall′channel, rustcall′freep) = _call_target($cache, \"$getter_symbol\", \"$(c.free_symbol)\"); " *
               "rustcall′raw = _guard_panic(rustcall′RustCall.call_rust_function(rustcall′fp, rustcall′RustCall.CRustString, $self_ptr), rustcall′channel, \"$getter_symbol\", rustcall′freep); " *
               "rustcall′RustCall._take_owned_string(rustcall′raw, rustcall′freep); end"
    elseif ffi_owned_vec_return(c)
        element_type = _emitted_type_source(ffi_type_expr(c.surface_type.parameters[1]))
        return "let (rustcall′fp, rustcall′channel, rustcall′freep, rustcall′alive) = _vec_target($cache, \"$getter_symbol\", \"$(c.free_symbol)\"); " *
               "rustcall′raw = _guard_panic(rustcall′RustCall.call_rust_function(rustcall′fp, rustcall′RustCall.CRustVec, $self_ptr), rustcall′channel, \"$getter_symbol\"); " *
               "rustcall′RustCall.RustVec{$element_type}(rustcall′raw.ptr, rustcall′raw.len, rustcall′raw.cap, (rustcall′freep, rustcall′alive)); end"
    elseif ffi_borrowed_string_return(c)
        return "let $target; rustcall′raw = _guard_panic(rustcall′RustCall.call_rust_function(rustcall′fp, rustcall′RustCall.CRustStr, $self_ptr), rustcall′channel, \"$getter_symbol\"); " *
               "rustcall′RustCall._crust_str_to_julia(rustcall′raw); end"
    end
    julia_type = _emitted_type(ffi_return_symbol_or_throw(field_type, get(info.field_abis, field_name, ""),
                                            _ffi_field_context(info, field_name, field_type);
                                            strict = strict,
                                            position = _ffi_field_position(info, field_name)))
    return "let $target; _guard_panic(rustcall′RustCall.call_rust_function(rustcall′fp, $(_emitted_source(julia_type)), $self_ptr), rustcall′channel, \"$getter_symbol\"); end"
end

"""
    _generate_property_accessors(info::RustStructInfo) -> Union{Expr, Nothing}

Generate Base.getproperty and Base.setproperty! methods for natural field access.
This allows `obj.field` and `obj.field = value` syntax.
"""
function _generate_property_accessors(info::RustStructInfo)
    struct_name_str = julia_struct_name(info)
    struct_name = Symbol(struct_name_str)

    # A field is a property when the manifest names an accessor for it: a
    # getter, a setter, or both. `#[julia]` structs carry both; a `#[pyclass]`
    # field carries exactly what `#[pyo3(get)]` / `#[pyo3(set)]` declared, so a
    # write-only field gets a `setproperty!` branch and no `getproperty` one.
    # Nothing here invents a symbol the manifest did not list (#307 review).
    readable_fields = [(name, type) for (name, type) in info.fields if field_is_accessible(info, name)]
    writable_fields = [(name, type) for (name, type) in info.fields if field_is_writable(info, name)]
    property_fields = [(name, type) for (name, type) in info.fields
                       if field_is_accessible(info, name) || field_is_writable(info, name)]

    if isempty(property_fields)
        return nothing
    end

    # Build getproperty branches. Each branch is its own call site and declares
    # its own snapshot cache (#253): the `:prop` kind keeps it distinct from the
    # `get_<field>` helper's, which calls the same getter symbol.
    caches = Expr[]
    getprop_branches = Expr[]
    for (field_name, field_type) in readable_fields
        field_sym = QuoteNode(Symbol(julia_field_name(field_name)))
        getter_fn = info.field_getters[field_name]
        push!(caches, _target_cache_const(:prop, getter_fn))
        # A `String` field getter hands back an owned buffer, on the crate path
        # too since manifest schema 4 — it used to be read as `Any` (#246).
        read = _crate_field_read(info, field_name, field_type, getter_fn,
                                 @_emitted(:(getfield(rustcall′self, :ptr))), _target_cache_name(:prop, getter_fn))
        push!(getprop_branches, @_emitted quote
            if rustcall′field === $field_sym
                return $read
            end
        end)
    end

    # Build setproperty! branches
    setprop_branches = Expr[]
    for (field_name, field_type) in writable_fields
        field_sym = QuoteNode(Symbol(julia_field_name(field_name)))
        setter_fn = info.field_setters[field_name]
        push!(caches, _target_cache_const(:prop, setter_fn))

        write = _crate_field_write(info, field_name, field_type, setter_fn,
                                   @_emitted(:(getfield(rustcall′self, :ptr))), _emitter_local("value"),
                                   _target_cache_name(:prop, setter_fn))
        push!(setprop_branches, @_emitted quote
            if rustcall′field === $field_sym
                $write
                return rustcall′value
            end
        end)
    end

    # Generate the field names tuple for propertynames
    field_symbols = [QuoteNode(Symbol(julia_field_name(name))) for (name, _) in property_fields]

    @_emitted quote
        $(caches...)
        function Base.getproperty(rustcall′self::$struct_name, rustcall′field::Symbol)
            # Allow access to internal ptr field
            if rustcall′field === :ptr
                return getfield(rustcall′self, :ptr)
            end
            _check_not_freed(rustcall′self, $struct_name_str)
            $(getprop_branches...)
            error("type $($struct_name_str) has no field $rustcall′field")
        end

        function Base.setproperty!(rustcall′self::$struct_name, rustcall′field::Symbol, rustcall′value)
            # Disallow setting internal ptr field
            if rustcall′field === :ptr
                error("cannot set internal field :ptr")
            end
            _check_not_freed(rustcall′self, $struct_name_str)
            $(setprop_branches...)
            error("type $($struct_name_str) has no field $rustcall′field")
        end

        function Base.propertynames(rustcall′self::$struct_name)
            ($(field_symbols...),)
        end
    end
end

"""
    _check_not_freed(obj, type_name::String)

Check that a wrapped Rust object has not been freed, raising rather than
letting the call dereference `C_NULL` inside Rust.

The generated `@rust_crate` modules and the emitted bindings files import this
name, so it stays; the implementation is `check_not_freed`
(`src/structs.jl`), which the inline `#[julia]` structs use as well. One rule,
one message, both flavours (#249, #277 Phase B4).
"""
_check_not_freed(obj, type_name::String) = check_not_freed(obj, type_name)

function _generate_crate_method_wrapper(info::RustStructInfo, method::RustMethod;
                                        bare::Bool = true)
    # The item every position below is filed under (#454), named before the
    # argument plan, which records first.
    _boundary_item!(_boundary_label(info, method))
    # A method the Rust codegen refuses gets no wrapper (#491).
    _rust_refused_item!(method.skip_reason, method.name) && return Expr(:block)
    struct_name_str = julia_struct_name(info)
    struct_name = Symbol(struct_name_str)
    # The Julia name: the Rust name, or `<Trait>_<name>` for a trait method
    # another method of the struct shares its name with (#506).
    method_name = Symbol(julia_method_name(method))
    # Exported symbol of the method wrapper (`rustcall_<Struct>_<method>`, #279)
    # and the owner of the per-method string buffers, both off the struct's
    # FFI name, which carries the module path (#300). The manifest states the
    # owner (#342); the derivation stands in only for an entry that states none.
    wrapper_name = method_wrapper_symbol(info.ffi_name, method)
    helper_owner = _method_string_owner(method, "$(info.ffi_name)_$(rust_name(method.name))")

    arg_syms = [Symbol(name) for name in method.arg_names]

    # String arguments become (ptr, len) pairs kept alive with GC.@preserve
    # (see `_string_arg_plan`); the other arguments are converted to the Julia
    # type of the Rust parameter. The pointer local must not shadow an
    # argument of the same name.
    bindings, preserved, converted_args, frame = _string_arg_plan(method, identity)
    ptr_sym = _generated_local("func_ptr", method.arg_names)

    # Crate method wrappers return strings through per-method buffers:
    # `<Struct>_<method>_RustCallOwnedString`, released with
    # `<Struct>_<method>_free_rust_string` (see rustcall_julia_core::codegen).
    c = _ffi_method_return(method, helper_owner)

    all_args = Any[]
    method.is_static || push!(all_args, @_emitted(:(getfield(rustcall′self, :ptr))))
    append!(all_args, converted_args)

    channel_sym = _generated_local("panic_channel", method.arg_names)
    free_sym = _generated_local("free_ptr", method.arg_names)
    free_channel_sym = _generated_local("free_panic_channel", method.arg_names)
    cache_sym = _target_cache_name(:m, wrapper_name)
    target = @_emitted(:(($ptr_sym, $channel_sym) = _call_target($cache_sym, $wrapper_name)))
    alive_sym = _generated_local("alive", method.arg_names)
    release_alive = _python_owned_handle(info) ? @_emitted(:(Ref(true))) : alive_sym
    # A `PyResult` method needs a C struct declared next to the wrapper, so it
    # is built whole rather than as one `call` expression (#275 Phase 2).
    if method.return_kind === :py_result
        return _generate_py_result_method_wrapper(info, method, arg_syms, bindings, preserved,
                                                  converted_args, wrapper_name; bare = bare, frame)
    end
    # Definitions the wrapper needs next to it: the `#[repr(C)]` mirror of a
    # `CResult_<Struct>_<method>` / `COption_<Struct>_<method>` aggregate (#268).
    predefs = Expr[]
    payload_body = nothing
    if method.return_kind === :result || method.return_kind === :option
        plan = _method_payload_plan(info, method, helper_owner)
        push!(predefs, plan.definition)
        payload_target = isempty(plan.free_symbol) ?
            @_emitted(:(($ptr_sym, $channel_sym) = _call_target($cache_sym, $wrapper_name))) :
            @_emitted(:(($ptr_sym, $channel_sym, $free_sym) = _call_target($cache_sym, $wrapper_name, $(plan.free_symbol))))
        free_expr = isempty(plan.free_symbol) ? @_emitted(:(C_NULL)) : free_sym
        c_sym = _generated_local("c_payload", method.arg_names)
        method.is_static || pushfirst!(preserved, _emitter_local("self"))
        payload_body = @_emitted quote
            $(bindings...)
            $payload_target
            $c_sym = $(_in_callback_frame(frame, _quote_preserved(preserved,
                                        @_emitted(:(call_rust_function($ptr_sym, $(plan.struct_name),
                                                             $(all_args...)))))))
            # A panic returns the `panicked()` sentinel — the Err / None
            # discriminant with an uninitialized payload — so the channel is
            # read *before* anything is decoded (#244).
            _guard_panic($c_sym, $channel_sym, $("$(struct_name_str)::$(method_name)"), $free_expr)
            $(_payload_decode_expr(plan, c_sym, free_expr))
        end
    end
    call = if payload_body !== nothing
        # The payload branch builds its own body; the return-contract lookups
        # below cannot describe a `Result<..>` spelling and would raise (#268).
        nothing
    elseif method.returns_boxed_struct
        # Constructors and `Self`-returning methods allocate, so the object is
        # bound to the generation that ran the call (#277).
        target = @_emitted(:(($ptr_sym, $channel_sym, $free_sym, $alive_sym, $free_channel_sym) =
                       _ctor_target($cache_sym, $wrapper_name, $(ffi_struct_free_symbol(info.ffi_name)))))
        @_emitted(:($struct_name(call_rust_function($ptr_sym, Ptr{Cvoid}, $(all_args...)),
                       $free_sym, $release_alive, $free_channel_sym)))
    elseif ffi_owned_string_return(c)
        target = @_emitted(:(($ptr_sym, $channel_sym, $free_sym) = _call_target($cache_sym, $wrapper_name, $(c.free_symbol))))
        @_emitted(:(_call_rust_owned_string_ptr($ptr_sym, $free_sym, $(all_args...))))
    elseif ffi_borrowed_string_return(c)
        @_emitted(:(_call_rust_borrowed_string_ptr($ptr_sym, $(all_args...))))
    else
        julia_ret_type = _emitted_type(ffi_return_symbol_or_throw(method.return_type, method.return_abi,
                                                    _ffi_context(method, struct_name_str)))
        @_emitted(:(call_rust_function($ptr_sym, $julia_ret_type, $(all_args...))))
    end
    # The wrapper object itself is kept alive for the whole call as well: a
    # borrowed `&str` result points into the Rust object, which the finalizer
    # of a temporary `self` could otherwise free mid-call.
    payload_body === nothing && !method.is_static && pushfirst!(preserved, _emitter_local("self"))
    method_label = "$(struct_name_str)::$(method_name)"
    body = payload_body !== nothing ? payload_body : @_emitted quote
        $(bindings...)
        $target
        _guard_panic($(_in_callback_frame(frame, _quote_preserved(preserved, call))), $channel_sym, $method_label)
    end

    definition = if method.is_static && method.is_constructor
        # Static constructor - returns the wrapper struct
        @_emitted quote
            function $struct_name($(arg_syms...))
                $body
            end
        end
    elseif method.is_static
        # A static method dispatches on the type — `shout(Labeler, s)` for
        # `Labeler::shout` — so it can never share a method table with a free
        # function or another struct's static method of the same name (#323).
        # The bare `shout(s)` form is kept only while no such name exists.
        # The delegator names its own arguments: an argument called like the
        # method (`fn scale(scale)`) or like the struct would otherwise shadow
        # the function or the type inside the forwarding body.
        dargs = [_emitter_local(string("arg", i)) for i in eachindex(arg_syms)]
        bare_def = bare ?
            @_emitted(:($method_name($(dargs...)) = $method_name($struct_name, $(dargs...)))) :
            nothing
        @_emitted quote
            function $method_name(::Type{$struct_name}, $(arg_syms...))
                $body
            end
            $bare_def
            export $method_name
        end
    else
        @_emitted quote
            function $method_name(rustcall′self::$struct_name, $(arg_syms...))
                _check_not_freed(rustcall′self, $struct_name_str)
                $body
            end
            export $method_name
        end
    end
    # The call site's snapshot cache, declared at module scope beside the
    # wrapper that uses it (#253). One per method: the branches above are
    # alternatives, so exactly one of them ever runs against this cache.
    Expr(:block, _target_cache_const(:m, wrapper_name), predefs..., definition)
end

"""
    MethodPayloadPlan

Everything both `@rust_crate` method emitters need for a `Result` / `Option`
return (#268): the name of the `#[repr(C)]` mirror, its definition, the surface
types the caller sees, and the `<owner>_free_rust_string` an owned-string
payload is released through (empty when no payload is one).
"""
struct MethodPayloadPlan
    kind::Symbol
    struct_name::Symbol
    definition::Expr
    source::String
    surface::Tuple{Any, Any}
    free_symbol::String
end

"""
    _method_payload_plan(info, method, helper_owner) -> MethodPayloadPlan

The `CResult_<Struct>_<method>` / `COption_<Struct>_<method>` mirror of one
method, shared by the in-memory `@rust_crate` emitter and the source-text one so
the two cannot describe the same aggregate differently.

`helper_owner` is what the wrapper's owned-string buffer is named after — the
struct for a method wrapped next to its struct, `<Struct>_<method>` for one
whose wrapper declares its own buffers — and is the only thing that differs
between the flavours. The caller takes it from the manifest
(`_method_string_owner`, #342).
"""
function _method_payload_plan(info::RustStructInfo, method::RustMethod,
                              helper_owner::AbstractString;
                              strict::Symbol = _ffi_strict())
    ctx = _ffi_context(method, info.name)
    if method.return_kind === :result
        ok_t, ok_slot = _emitted_type(ffi_payload_symbols(method.ok_type, method.ok_abi, ctx;
                                            position = "Ok payload", strict = strict))
        err_t, err_slot = _emitted_type(ffi_payload_symbols(method.err_type, method.err_abi, ctx;
                                              position = "Err payload", strict = strict))
        name = Symbol("CResult_", julia_struct_name(info), "_", julia_method_name(method))
        definition = @_emitted quote
            # RustCall's own mirror of the extractor's `#[repr(C)]` aggregate,
            # so it carries the by-value layout assertion in its supertype
            # (#245).
            struct $name <: FFIByValue
                is_ok::UInt8
                ok_value::$ok_slot
                err_value::$err_slot
            end
        end
        source = """
struct $name <: rustcall′RustCall.FFIByValue
    is_ok::rustcall′Base.UInt8
    ok_value::$(_emitted_source(ok_slot))
    err_value::$(_emitted_source(err_slot))
end"""
        free = _payload_free_symbol(helper_owner, (method.ok_abi, method.err_abi))
        return MethodPayloadPlan(:result, name, definition, source, (ok_t, err_t), free)
    end
    inner_t, inner_slot =
        _emitted_type(ffi_payload_symbols(method.inner_type, method.inner_abi, ctx;
                            position = "Some payload", strict = strict))
    name = Symbol("COption_", julia_struct_name(info), "_", julia_method_name(method))
    definition = @_emitted quote
        struct $name <: FFIByValue
            is_some::UInt8
            value::$inner_slot
        end
    end
    source = """
struct $name <: rustcall′RustCall.FFIByValue
    is_some::rustcall′Base.UInt8
    value::$(_emitted_source(inner_slot))
end"""
    free = _payload_free_symbol(helper_owner, (method.inner_abi,))
    return MethodPayloadPlan(:option, name, definition, source, (inner_t, nothing), free)
end

# The expression that turns the aggregate bound to `c_sym` into a
# `RustResult` / `RustOption`. Only the active payload is decoded, and only it
# is released (#268).
function _payload_decode_expr(plan::MethodPayloadPlan, c_sym::Symbol, free_expr)
    if plan.kind === :result
        ok_t, err_t = plan.surface
        return @_emitted quote
            if $c_sym.is_ok == 1
                RustResult{$ok_t, $err_t}(true, _result_payload($ok_t, $c_sym.ok_value, $free_expr))
            else
                RustResult{$ok_t, $err_t}(false, _result_payload($err_t, $c_sym.err_value, $free_expr))
            end
        end
    end
    inner_t, _ = plan.surface
    return @_emitted quote
        if $c_sym.is_some == 1
            RustOption{$inner_t}(true, _result_payload($inner_t, $c_sym.value, $free_expr))
        else
            RustOption{$inner_t}(false, nothing)
        end
    end
end

"""
    _generate_py_result_method_wrapper(info, method, ...) -> Expr

Julia wrapper for a scanned `#[pymethods]` method returning `PyResult<T>`
(#275 Phase 2), the method twin of `_generate_py_result_function_wrapper`. The
C struct is `CResult_<Struct>_<method>`, matching the name the wrapper
generator gives it.
"""
function _generate_py_result_method_wrapper(info::RustStructInfo, method::RustMethod,
                                            arg_syms::Vector{Symbol}, bindings::Vector,
                                            preserved::Vector, converted_args::Vector,
                                            wrapper_name::String; bare::Bool = true,
                                            frame::Union{Nothing, Symbol} = nothing)
    struct_name_str = julia_struct_name(info)
    struct_name = Symbol(struct_name_str)
    method_name = Symbol(julia_method_name(method))
    boxed = method.returns_boxed_struct
    ok_julia_type, ok_slot_type, is_unit = boxed ?
        (struct_name, @_emitted(:(Ptr{Cvoid})), false) :
        _emitted_type(_py_result_types(method.ok_type, method.ok_abi,
                         _ffi_context(method, struct_name_str)))

    helper_owner = _method_string_owner(method, "$(info.ffi_name)_$(rust_name(method.name))")
    c_result_struct_name = Symbol("CResult_", helper_owner)
    ptr_sym = _generated_local("func_ptr", method.arg_names)
    c_sym = _generated_local("c_result", method.arg_names)
    channel_sym = _generated_local("panic_channel", method.arg_names)
    free_sym = _generated_local("free_ptr", method.arg_names)
    alive_sym = _generated_local("alive", method.arg_names)
    free_channel_sym = _generated_local("free_panic_channel", method.arg_names)
    release_alive = _python_owned_handle(info) ? @_emitted(:(Ref(true))) : alive_sym

    all_args = Any[]
    method.is_static || push!(all_args, @_emitted(:(getfield(rustcall′self, :ptr))))
    append!(all_args, converted_args)
    method.is_static || pushfirst!(preserved, _emitter_local("self"))
    method_label = "$(struct_name_str)::$(method_name)"
    payload_free = _payload_free_symbol(helper_owner, (method.ok_abi,))
    cache_sym = _target_cache_name(:m, wrapper_name)
    target = if boxed
        @_emitted(:(($ptr_sym, $channel_sym, $free_sym, $alive_sym, $free_channel_sym) =
              _ctor_target($cache_sym, $wrapper_name, $(ffi_struct_free_symbol(info.ffi_name)))))
    elseif !isempty(payload_free)
        @_emitted(:(($ptr_sym, $channel_sym, $free_sym) =
              _call_target($cache_sym, $wrapper_name, $payload_free)))
    else
        @_emitted(:(($ptr_sym, $channel_sym) = _call_target($cache_sym, $wrapper_name)))
    end
    free_expr = isempty(payload_free) ? @_emitted(:(C_NULL)) : free_sym
    ok_value = if is_unit
        :nothing
    elseif boxed
        @_emitted(:($struct_name($c_sym.ok_value, $free_sym, $release_alive, $free_channel_sym)))
    else
        @_emitted(:(_result_payload($ok_julia_type, $c_sym.ok_value, $free_expr)))
    end

    body = @_emitted quote
        $(bindings...)
        $target
        $c_sym = $(_in_callback_frame(frame, _quote_preserved(preserved,
                                    @_emitted(:(call_rust_function($ptr_sym, $c_result_struct_name,
                                                         $(all_args...)))))))
        _guard_panic($c_sym, $channel_sym, $method_label, $free_expr)
        if $c_sym.is_ok == 1
            RustResult{$ok_julia_type, String}(true, $ok_value)
        else
            RustResult{$ok_julia_type, String}(false, RustCall.PYO3_OPAQUE_ERROR)
        end
    end

    declaration = @_emitted quote
        # The call site's snapshot cache, beside the wrapper that uses it (#253).
        $(_target_cache_const(:m, wrapper_name))
        # RustCall's own mirror of a `#[repr(C)]` aggregate it generated (#245).
        struct $c_result_struct_name <: FFIByValue
            is_ok::UInt8
            ok_value::$ok_slot_type
            err_value::Int32
        end
    end

    if method.is_static && method.is_constructor
        @_emitted quote
            $declaration
            function $struct_name($(arg_syms...))
                $body
            end
        end
    elseif method.is_static
        # Type-dispatched, bare form only without a name collision (#323); see
        # `_generate_crate_method_wrapper`.
        # The delegator names its own arguments: an argument called like the
        # method (`fn scale(scale)`) or like the struct would otherwise shadow
        # the function or the type inside the forwarding body.
        dargs = [_emitter_local(string("arg", i)) for i in eachindex(arg_syms)]
        bare_def = bare ?
            @_emitted(:($method_name($(dargs...)) = $method_name($struct_name, $(dargs...)))) :
            nothing
        @_emitted quote
            $declaration
            function $method_name(::Type{$struct_name}, $(arg_syms...))
                $body
            end
            $bare_def
            export $method_name
        end
    else
        @_emitted quote
            $declaration
            function $method_name(rustcall′self::$struct_name, $(arg_syms...))
                _check_not_freed(rustcall′self, $struct_name_str)
                $body
            end
            export $method_name
        end
    end
end

function _generate_crate_field_accessor(info::RustStructInfo, field_name::String, field_type::String)
    struct_name = Symbol(julia_struct_name(info))
    exprs = Expr[]

    # `get_<field>` and `set_<field>!`, each only when the manifest names the
    # accessor: a `set`-only `#[pyo3(set)]` field has the second and not the
    # first (#307 review).
    # Both helpers check the object is still live before touching its pointer,
    # as `getproperty` / `setproperty!` and every instance method do: after an
    # explicit `finalize(obj)` the pointer is `C_NULL`, and handing that to the
    # Rust accessor is a crash where the others raise a `RustError` (#307
    # review).
    struct_name_str = String(struct_name)
    if field_is_accessible(info, field_name)
        getter_name = info.field_getters[field_name]
        read = _crate_field_read(info, field_name, field_type, getter_name,
                                 @_emitted(:(rustcall′self.ptr)), _target_cache_name(:acc, getter_name))
        push!(exprs, @_emitted quote
            $(_target_cache_const(:acc, getter_name))
            function $(Symbol("get_", julia_field_name(field_name)))(rustcall′self::$struct_name)
                _check_not_freed(rustcall′self, $struct_name_str)
                $read
            end
        end)
    end
    if field_is_writable(info, field_name)
        setter_name = info.field_setters[field_name]
        write = _crate_field_write(info, field_name, field_type, setter_name, @_emitted(:(rustcall′self.ptr)),
                                   _emitter_local("value"),
                                   _target_cache_name(:acc, setter_name))
        push!(exprs, @_emitted quote
            $(_target_cache_const(:acc, setter_name))
            function $(Symbol("set_", julia_field_name(field_name), "!"))(rustcall′self::$struct_name, rustcall′value)
                _check_not_freed(rustcall′self, $struct_name_str)
                $write
                rustcall′value
            end
        end)
    end

    return Expr(:block, exprs...)
end
