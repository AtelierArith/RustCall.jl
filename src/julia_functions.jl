# #[julia] attribute support for automatic FFI wrapper generation
# This module handles detection, transformation, and Julia wrapper generation for
# Rust functions marked with #[julia] attribute.

"""
    RustFunctionSignature

Signature of a Rust free function as recorded in the FFI manifest produced by
`rustcall-extract` (see `src/manifest.jl`). Julia never derives this from
source text.

# Fields
- `name`, `arg_names`, `arg_types`, `return_type`: as written in Rust
- `is_generic`, `type_params`, `constraints`: generic parameters and their trait bounds
- `symbol`: exported C symbol (equals `name` unless generic)
- `attribute`: `:julia`, `:julia_pyo3` or `:none`
- `exported`: whether the compiled library exports `symbol`
- `return_kind`: `:plain`, `:unit`, `:result` or `:option`
- `ok_type`/`err_type`/`inner_type`: components of `Result`/`Option` returns
- `source`: function source (generic functions only), used for monomorphization
- `module_path`: enclosing inline modules (`["api", "deep"]`)
- `has_owned_string_helper` / `has_borrowed_string_helper`: the function returns
  `String` / `&str`; the wrapper returns `<fn>_RustCallOwnedString` (freed with
  `<fn>_free_rust_string`) / `<fn>_RustCallBorrowedString` (#242). Derived from
  `return_abi` since manifest schema 4
- `return_abi`: manifest `Function.return_abi` — `"string"` (owned buffer),
  `"str"` (borrowed view) or `""` (as written). The normative description of
  how the wrapper returns its value (#276)
"""
struct RustFunctionSignature
    name::String
    arg_names::Vector{String}
    arg_types::Vector{String}
    return_type::String
    is_generic::Bool
    type_params::Vector{String}
    symbol::String
    attribute::Symbol
    exported::Bool
    return_kind::Symbol
    ok_type::String
    err_type::String
    inner_type::String
    source::String
    constraints::Dict{Symbol, TypeConstraints}
    module_path::Vector{String}
    # The body contains `#[cfg]`/`cfg!`, so it still depends on the build
    # configuration after item-level pruning (see `Function::body_has_cfg`).
    body_has_cfg::Bool
    has_owned_string_helper::Bool
    has_borrowed_string_helper::Bool
    arg_abis::Vector{String}
    return_abi::String
    # Manifest schema 5 (#275). `attribute` doubles as the *origin* of the
    # entry: `:julia` / `:julia_pyo3` come from a RustCall attribute,
    # `:py_function` / `:py_module` from the PyO3 scan of a crate that carries
    # no RustCall attribute at all. `vis` is the visibility as written,
    # `skip_reason` says why the item cannot be wrapped (empty when it can) and
    # `python_name` is the name PyO3 exposes it under.
    vis::String
    skip_reason::String
    python_name::String
    # Crate features the item's `#[cfg]` predicate depends on, derived from the
    # predicate by the extractor so Julia never reads Rust `cfg` syntax (#275).
    cfg_features::Vector{String}
end

function RustFunctionSignature(name::String, arg_names::Vector{String}, arg_types::Vector{String},
                               return_type::String, is_generic::Bool, type_params::Vector{String};
                               symbol::String = name, attribute::Symbol = :julia,
                               exported::Bool = !is_generic,
                               return_kind::Symbol = return_type == "()" ? :unit : :plain,
                               ok_type::String = "", err_type::String = "", inner_type::String = "",
                               source::String = "",
                               constraints::Dict{Symbol, TypeConstraints} = Dict{Symbol, TypeConstraints}(),
                               module_path::Vector{String} = String[],
                               body_has_cfg::Bool = false,
                               has_owned_string_helper::Bool = false,
                               has_borrowed_string_helper::Bool = false,
                               arg_abis::Vector{String} = _default_arg_abis(arg_types),
                               return_abi::String = _default_return_abi(return_type, arg_abis),
                               vis::String = "pub", skip_reason::String = "",
                               python_name::String = "",
                               cfg_features::Vector{String} = String[])
    length(arg_abis) == length(arg_types) ||
        throw(ArgumentError("arg_abis must have one entry per argument"))
    RustFunctionSignature(name, arg_names, arg_types, return_type, is_generic, type_params,
                          symbol, attribute, exported, return_kind, ok_type, err_type, inner_type,
                          source, constraints, module_path, body_has_cfg,
                          has_owned_string_helper, has_borrowed_string_helper, arg_abis,
                          return_abi, vis, skip_reason, python_name, cfg_features)
end

"""
    _default_arg_abis(arg_types) -> Vector{String}

The `abi` column for signatures constructed by hand (tests, legacy callers):
the extractor classifies argument types on the Rust side (`Arg.abi`:
`"string"`, `"str"` or `""`); this reconstructs the column from the FFI
contract (`src/ffi_contract.jl`), which is the same table the wrapper
generators consult, so a hand-built signature and a manifest one agree.
"""
_default_arg_abis(arg_types) = String[_default_arg_abi(t) for t in arg_types]

function _default_arg_abi(rust_type::AbstractString)
    entry = ffi_lookup(rust_type)
    entry === nothing && return ""
    entry.surface_type === RustString && return "string"
    entry.surface_type === RustStr && return "str"
    return ""
end

"""
    _is_string_abi(abi) -> Bool

Whether an argument travels as a `(ptr, len)` byte pair (`Arg.abi` of the
manifest is `"string"` or `"str"`; covers `&'a str` and other spellings).
"""
_is_string_abi(abi::AbstractString) = abi in ("string", "str")

"""
    _string_arg_plan(sig) -> (bindings, preserved, call_args)

How the Julia wrapper of `sig` passes its arguments: `bindings` converts each
argument (`String(x)` for string arguments, `Int32(x)` and friends for
primitives), `preserved` lists the string bindings to keep alive during the
call, and `call_args` are the expressions handed to the `ccall` (`pointer(s),
sizeof(s)` for strings). `escape` wraps user-visible symbols (`esc` in macro
context, `identity` inside a generated module).
"""
function _string_arg_plan(sig::RustFunctionSignature, escape::Function)
    return _string_arg_plan(sig.arg_names, sig.arg_types, sig.arg_abis, escape;
                            context = sig.name)
end

# Same plan for a struct method (`RustMethod`), whose arguments follow `self`.
function _string_arg_plan(method::RustMethod, escape::Function)
    return _string_arg_plan(method.arg_names, method.arg_types, method.arg_abis, escape;
                            context = method.name)
end

function _string_arg_plan(arg_names::Vector{String}, arg_types::Vector{String},
                          arg_abis::Vector{String}, escape::Function;
                          context::AbstractString = "")
    bindings = Expr[]
    preserved = Symbol[]
    call_args = Any[]
    prefix = _string_temp_prefix(arg_names)
    for (name, rust_type, abi) in zip(arg_names, arg_types, arg_abis)
        arg_sym = escape(Symbol(name))
        # The contract, not the spelling, decides how many C slots this
        # position occupies and what goes in them (#276).
        c = ffi_argument_contract(rust_type; abi = abi)
        if c.abi === :ptr_len || c.abi === :ptr_len_cap
            # `(ptr, len)` — and, should an owned buffer ever be taken by
            # value, `(ptr, len, cap)`. Slot-count driven, so a new multi-word
            # ABI needs no new branch here.
            bytes = Symbol(prefix, name)
            # Validity is checked here, before the pointer exists: a Julia
            # `String` is a byte vector and need not be UTF-8, and the Rust
            # wrapper's `from_utf8_lossy` would have replaced the bad bytes
            # rather than reported them (#246).
            #
            # A `GlobalRef`, not the bare name: a Rust argument may legitimately
            # be called `ffi_string_argument`, and in the generated wrapper that
            # parameter would shadow the helper — the call would then try to
            # call the caller's string and raise a `MethodError` before reaching
            # Rust (#246 review). It also stringifies as
            # `RustCall.ffi_string_argument`, so the source-text emitter is
            # fixed by the same line.
            helper = GlobalRef(@__MODULE__, :ffi_string_argument)
            push!(bindings, :($bytes = $helper($arg_sym, $name, $context)))
            push!(preserved, bytes)
            push!(call_args, :(pointer($bytes)))
            push!(call_args, :(sizeof($bytes) % Csize_t))
            c.abi === :ptr_len_cap && push!(call_args, :(sizeof($bytes) % Csize_t))
        elseif c.known && c.abi === :by_value
            push!(call_args, :($(_ffi_slot_expr(rust_type, c))($arg_sym)))
        else
            # A pointer, the unit type, or a spelling the contract does not
            # cover: hand the value to `call_rust_function`, which applies its
            # own Julia-type-keyed coercion, exactly as before.
            push!(call_args, arg_sym)
        end
    end
    return bindings, preserved, call_args
end

"""
    _string_temp_prefix(arg_names) -> String

Prefix for the temporaries that hold the converted strings, chosen so that no
temporary can collide with a Rust argument called, say, `__rustcall_str_s`.
"""
function _string_temp_prefix(arg_names)
    prefix = "__rustcall_str_"
    while any(startswith(n, prefix) for n in arg_names)
        prefix *= "_"
    end
    return prefix
end

"""
    _generated_local(base, arg_names) -> Symbol

Name for a local the generated wrapper introduces (`func_ptr`, `lib_name`,
`c_result`, ...). A Rust argument may legitimately be called `func_ptr`, and
the wrapper must not shadow it, so the name is prefixed when — and only when —
it would collide with one of `arg_names`. Without a collision the readable
name is kept, so generated code is unchanged for the common case.
"""
function _generated_local(base::AbstractString, arg_names)
    base in arg_names || return Symbol(base)
    prefix = "__rustcall_"
    while any(startswith(n, prefix) for n in arg_names)
        prefix *= "_"
    end
    return Symbol(prefix, base)
end

"""
    _ffi_context(sig_or_method, owner = nothing) -> String

The signature an unsupported return type is reported against, for
`ffi_return_symbol_or_throw`.
"""
_ffi_context(sig::RustFunctionSignature) =
    ffi_signature_context(sig.name, sig.arg_types, sig.return_type)

_ffi_context(m::RustMethod, owner::AbstractString) =
    ffi_signature_context(m.name, m.arg_types, m.return_type; owner = owner)

"""
    _ffi_function_return(sig) -> FFIContract

The return contract of a free function, with the owner set: the string helpers
are named after the Rust item, so `<fn>_free_rust_string` comes out of the
contract rather than being spelled at the call site (#246, #249).
"""
_ffi_function_return(sig::RustFunctionSignature) =
    ffi_return_contract(sig.return_type; abi = sig.return_abi, owner = sig.name)

"""
    _ffi_field_return(info, field_name, field_type) -> FFIContract

The return contract of a struct field getter. `Field.abi` (manifest schema 4)
says whether the getter hands back an owned buffer, and the struct owns the
`<Struct>_free_rust_string` that releases it — on both wrapper flavours.
"""
_ffi_field_return(info, field_name::AbstractString, field_type::AbstractString) =
    ffi_return_contract(field_type; abi = get(info.field_abis, field_name, ""),
                        owner = info.name)

# A field getter reads as `Struct::field -> T`.
_ffi_field_context(info, field_name::AbstractString, field_type::AbstractString) =
    string(info.name, "::", field_name, " -> ", field_type)

"""
    _uses_string_ffi(sig) -> Bool

Whether the wrapper of `sig` needs the string ABI (string arguments or a
`String` / `&str` return).
"""
function _uses_string_ffi(sig::RustFunctionSignature)
    ffi_return_contract(sig.return_type; abi = sig.return_abi).aggregate_type === nothing ||
        return true
    return any(zip(sig.arg_types, sig.arg_abis)) do (rust_type, abi)
        c = ffi_argument_contract(rust_type; abi = abi)
        c.abi === :ptr_len || c.abi === :ptr_len_cap
    end
end

"""
    qualified_name(sig_or_info) -> String

`module_path::name` of a manifest entry, as accepted by `rustcall-extract specialize`.
"""
qualified_name(module_path::Vector{String}, name::String) = join(vcat(module_path, [name]), "::")

"""
    emit_julia_function_wrappers(signatures::Vector{RustFunctionSignature}) -> Expr

Generate Julia wrapper functions for the given Rust function signatures.

For a function like:
```rust
#[julia]
fn add(a: i32, b: i32) -> i32 { ... }
```

Generates:
```julia
add(a, b) = @rust add(Int32(a), Int32(b))::Int32
```
"""
function emit_julia_function_wrappers(signatures::Vector{RustFunctionSignature})
    exprs = Expr[]

    for sig in signatures
        if sig.is_generic
            # Generic functions are registered for monomorphization at load time
            # and called through `@rust`; no static wrapper is emitted.
            @debug "Skipping generic function wrapper generation for $(sig.name)"
            continue
        end

        wrapper_expr = _generate_single_wrapper(sig)
        if wrapper_expr !== nothing
            push!(exprs, wrapper_expr)
        end
    end

    if isempty(exprs)
        return :()
    end

    return Expr(:block, exprs...)
end

"""
    _generate_single_wrapper(sig::RustFunctionSignature) -> Union{Expr, Nothing}

Generate a Julia wrapper function for a single Rust function signature.
Uses direct function call instead of @rust macro for better scope handling.
"""
function _generate_single_wrapper(sig::RustFunctionSignature)
    # The Julia wrapper keeps the Rust *name* (`add(1, 2)`); the call goes to
    # the exported *symbol*, which since #279 is `rustcall_add`.
    func_name = esc(Symbol(sig.name))
    symbol_str = sig.symbol

    # Build argument list with conversion (string arguments become (ptr, len)
    # pairs kept alive with GC.@preserve, see `_string_arg_plan`)
    arg_syms = [esc(Symbol(name)) for name in sig.arg_names]
    bindings, preserved, converted_args = _string_arg_plan(sig, esc)

    if sig.return_kind == :result
        return _generate_inline_result_wrapper(sig, func_name, symbol_str, arg_syms, bindings, preserved, converted_args)
    elseif sig.return_kind == :option
        return _generate_inline_option_wrapper(sig, func_name, symbol_str, arg_syms, bindings, preserved, converted_args)
    elseif _uses_string_ffi(sig)
        return _generate_inline_string_wrapper(sig, func_name, symbol_str, arg_syms)
    end

    # The one return decision (#276): the contract, or a failure naming the
    # signature — never a silent `Any`.
    julia_ret_type = ffi_return_symbol_or_throw(sig.return_type, sig.return_abi,
                                                _ffi_context(sig))

    # Generate the wrapper function using internal API directly
    # This avoids macro expansion issues
    lib_sym = _generated_local("lib_name", sig.arg_names)
    ptr_sym = _generated_local("func_ptr", sig.arg_names)
    rust_name = sig.name
    # `_resolve_call` returns the pointer **and the library it came from**.
    # `get_current_library()` is only where the search starts: a wrapper
    # defined by one block may well resolve through another (the cross-library
    # fallback), and the panic channel has to be read on the library that
    # actually holds the wrapper — otherwise a panic is looked for in the
    # wrong image and silently missed (#244).
    channel_sym = _generated_local("panic_channel", sig.arg_names)
    return quote
        function $func_name($(arg_syms...))
            # One snapshot: pointer and panic channel from the same
            # generation, resolved before the call (the channel is a
            # thread-local, so nothing may yield between call and read) — #244,
            # #277.
            $channel_sym =
                RustCall.resolve_call_target(RustCall.module_symbol_library(@__MODULE__, $symbol_str), $symbol_str)
            RustCall.guard_rust_panic_ptr(
                RustCall.call_rust_function($channel_sym.func_ptr, $julia_ret_type, $(converted_args...)),
                $channel_sym.channel, $rust_name)
        end
    end
end

# String / &str arguments and returns (#242): arguments travel as (ptr, len)
# byte pairs kept alive with GC.@preserve; a `String` return is an owned
# `<fn>_RustCallOwnedString` released through `<fn>_free_rust_string`, a `&str`
# return a borrowed `<fn>_RustCallBorrowedString`.
function _generate_inline_string_wrapper(sig, func_name, symbol_str, arg_syms)
    bindings, preserved, call_args = _string_arg_plan(sig, esc)
    lib_sym = _generated_local("lib_name", sig.arg_names)
    # The string helpers are named after the Rust item, not the symbol, so the
    # owner is the function name; the contract turns that into `free_symbol`.
    c = ffi_return_contract(sig.return_type; abi = sig.return_abi, owner = sig.name)
    rust_name = sig.name
    channel_sym = _generated_local("panic_channel", sig.arg_names)
    call = if ffi_owned_string_return(c)
        # The release stays indirect — the symbol is resolved inside the
        # allocating library, which is the #249 half (#277 swaps the mechanism).
        # `_call_rust_owned_string` reads the panic channel itself, before it
        # decodes the buffer: on a panic the buffer is the empty sentinel and
        # would otherwise decode to "" (#244).
        free_name = c.free_symbol
        :(RustCall._call_rust_owned_string($lib_sym, $symbol_str, $free_name, $(call_args...)))
    elseif ffi_borrowed_string_return(c)
        :(RustCall._call_rust_borrowed_string($lib_sym, $symbol_str, $(call_args...)))
    else
        ret = ffi_return_symbol_or_throw(sig.return_type, sig.return_abi, _ffi_context(sig))
        :(RustCall.guard_rust_panic_ptr(
              RustCall.call_rust_function($channel_sym.func_ptr, $ret, $(call_args...)),
              $channel_sym.channel, $rust_name))
    end
    quote
        function $func_name($(arg_syms...))
            $(bindings...)
            # The owning library is resolved once; the string helpers take
            # their own single snapshot, free pointer included (#277).
            $lib_sym = RustCall.resolve_call_target(
                RustCall.module_symbol_library(@__MODULE__, $symbol_str), $symbol_str).lib_name
            $channel_sym = RustCall.resolve_call_target($lib_sym, $symbol_str)
            GC.@preserve $(preserved...) begin
                $call
            end
        end
    end
end

# Result<T, E> / Option<T> returning #[julia] functions in inline blocks: the
# extractor generates `CResult_<fn>` / `COption_<fn>` on the Rust side; the
# wrapper reads that struct and converts it to RustResult / RustOption.
function _generate_inline_result_wrapper(sig, func_name, symbol_str, arg_syms, bindings, preserved, converted_args)
    ctx = _ffi_context(sig)
    # The payloads are FIELDS of a `#[repr(C)]` aggregate, so they are declared
    # with the type Rust stored — the C slot — and converted to the surface type
    # after the call. For `char` those differ: Rust writes a `UInt32` code point
    # where Julia's `Char` would be a left-aligned UTF-8 bit pattern (#245).
    ok_t = ffi_return_symbol_or_throw(sig.ok_type, "", ctx)
    err_t = ffi_return_symbol_or_throw(sig.err_type, "", ctx)
    ok_slot = ffi_return_slot_symbol_or_throw(sig.ok_type, "", ctx)
    err_slot = ffi_return_slot_symbol_or_throw(sig.err_type, "", ctx)
    lib_sym = _generated_local("lib_name", sig.arg_names)
    ptr_sym = _generated_local("func_ptr", sig.arg_names)
    c_sym = _generated_local("c_result", sig.arg_names)
    channel_sym = _generated_local("panic_channel", sig.arg_names)
    rust_name = sig.name
    quote
        function $func_name($(arg_syms...))
            $(bindings...)
            $channel_sym =
                RustCall.resolve_call_target(RustCall.module_symbol_library(@__MODULE__, $symbol_str), $symbol_str)
            $c_sym = GC.@preserve $(preserved...) RustCall.call_rust_function($channel_sym.func_ptr, RustCall.CResultType{$ok_slot, $err_slot}, $(converted_args...))
            # A panic returns `CResult::panicked()` — the Err discriminant with
            # an uninitialized payload — so the channel must be read before the
            # payload is decoded, and resolved before the call (#244).
            RustCall.check_rust_panic_ptr($channel_sym.channel, $rust_name)
            RustCall.convert_c_result_to_rust_result($c_sym, $ok_t, $err_t)
        end
    end
end

function _generate_inline_option_wrapper(sig, func_name, symbol_str, arg_syms, bindings, preserved, converted_args)
    inner_t = ffi_return_symbol_or_throw(sig.inner_type, "", _ffi_context(sig))
    inner_slot = ffi_return_slot_symbol_or_throw(sig.inner_type, "", _ffi_context(sig))
    lib_sym = _generated_local("lib_name", sig.arg_names)
    ptr_sym = _generated_local("func_ptr", sig.arg_names)
    c_sym = _generated_local("c_option", sig.arg_names)
    channel_sym = _generated_local("panic_channel", sig.arg_names)
    rust_name = sig.name
    quote
        function $func_name($(arg_syms...))
            $(bindings...)
            $channel_sym =
                RustCall.resolve_call_target(RustCall.module_symbol_library(@__MODULE__, $symbol_str), $symbol_str)
            $c_sym = GC.@preserve $(preserved...) RustCall.call_rust_function($channel_sym.func_ptr, RustCall.COptionType{$inner_slot}, $(converted_args...))
            RustCall.check_rust_panic_ptr($channel_sym.channel, $rust_name)
            RustCall.convert_c_option_to_rust_option($c_sym, $inner_t)
        end
    end
end

# ============================================================================
# Result<T, E> and Option<T> Support
# ============================================================================

"""
    CResultType{T, E}

C-compatible struct for Result<T, E> returned by FFI functions.
Generated by #[julia] proc-macro as `CResult_<function_name>`.
"""
struct CResultType{T, E}
    is_ok::UInt8
    ok_value::T
    err_value::E
end

"""
    COptionType{T}

C-compatible struct for Option<T> returned by FFI functions.
Generated by #[julia] proc-macro as `COption_<function_name>`.
"""
struct COptionType{T}
    is_some::UInt8
    value::T
end

# Both mirror a `#[repr(C)]` aggregate the extractor emits (`CResult_<fn>` /
# `COption_<fn>`, `deps/rustcall_core/src/codegen.rs`), so the by-value layout
# assertion #245 requires is one RustCall makes about its own types — for every
# instantiation, since the shape is the discriminant plus a payload whatever the
# payload is.
ffi_by_value_layout(::Type{<:CResultType}) = :repr_c
ffi_by_value_layout(::Type{<:COptionType}) = :repr_c

"""
    generate_c_result_struct_type(func_name::String, ok_type::Symbol, err_type::Symbol) -> Expr

Generate a Julia struct definition for the C-compatible Result type.
"""
function generate_c_result_struct_type(func_name::String, ok_type::Symbol, err_type::Symbol)
    struct_name = Symbol("CResult_", func_name)
    quote
        # `<: FFIByValue` is RustCall's own by-value assertion about a mirror it
        # generated for the extractor's `#[repr(C)]` `CResult_<fn>` (#245). It
        # is a supertype rather than a `register_ffi_struct` call because this
        # code may be precompiled into a downstream package, and Julia does not
        # replay a dependency's global mutations when loading from cache.
        struct $struct_name <: $(GlobalRef(RustCall, :FFIByValue))
            is_ok::UInt8
            ok_value::$ok_type
            err_value::$err_type
        end
    end
end

"""
    generate_c_option_struct_type(func_name::String, inner_type::Symbol) -> Expr

Generate a Julia struct definition for the C-compatible Option type.
"""
function generate_c_option_struct_type(func_name::String, inner_type::Symbol)
    struct_name = Symbol("COption_", func_name)
    quote
        # See `generate_c_result_struct_type`: RustCall's own mirror (#245).
        struct $struct_name <: $(GlobalRef(RustCall, :FFIByValue))
            is_some::UInt8
            value::$inner_type
        end
    end
end

"""
    convert_c_result_to_rust_result(c_result, ok_type::Type, err_type::Type) -> RustResult

Convert a C-compatible result struct to RustResult{T, E}.
"""
function convert_c_result_to_rust_result(c_result, ::Type{T}, ::Type{E}) where {T, E}
    # The payload fields hold the C slot; `convert_return` reads them back as
    # the surface type (identity for everything but `char`, whose slot is a
    # `UInt32` code point). Only the ACTIVE payload is converted — the inactive
    # one is uninitialized on the Rust side and may hold anything.
    if c_result.is_ok == 1
        RustResult{T, E}(true, convert_return(T, c_result.ok_value))
    else
        RustResult{T, E}(false, convert_return(E, c_result.err_value))
    end
end

"""
    convert_c_option_to_rust_option(c_option, inner_type::Type) -> RustOption

Convert a C-compatible option struct to RustOption{T}.
"""
function convert_c_option_to_rust_option(c_option, ::Type{T}) where {T}
    # See `convert_c_result_to_rust_result`: the field holds the C slot, and
    # only a `Some` payload is initialized.
    if c_option.is_some == 1
        RustOption{T}(true, convert_return(T, c_option.value))
    else
        RustOption{T}(false, nothing)
    end
end
