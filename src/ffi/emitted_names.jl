# How emitted code names what it does not define (#528).
#
# A generated module binds the crate's items under their Julia names: a
# `#[julia] struct Base` is the module's `Base`, a `#[julia] fn getfield` its
# `getfield`. Emitted code that spelled `Base.show`, `getfield(x, :ptr)` or
# `RustCall.StateView` by those plain names then reached the item instead
# (`FieldError: type DataType has no field getproperty`), and the only defence
# was refusing items by a list of names.
#
# The rule instead: emitted code reaches everything outside its own module
# through a name no Rust identifier can spell.
#
# * The expression emitters (`@rust_crate`, the PyO3 host, and the argument
#   plans `rust"""` shares) write their templates with `@_emitted`, which
#   rewrites every free name of Base, Core or RustCall into a `GlobalRef` at
#   RustCall's own load time. A `GlobalRef` is not a name at all: no binding of
#   the generated module can capture it.
# * The source-text emitter (`write_bindings_to_file`) cannot write a
#   `GlobalRef`, so it binds each module it depends on once, at the top of the
#   generated module, under a name in the `rustcall′` namespace
#   (`import Base as rustcall′Base`), and every reference goes through it
#   (`rustcall′Base.getfield(...)`). U+2032 PRIME is a Julia identifier
#   character and never a Rust one (it is not XID_Continue), so no Rust item,
#   raw or not, can be bound under such a name. Expressions the two emitters
#   share are printed through `_emitted_source`, which spells each `GlobalRef`
#   through those bindings.
#
# `test/test_module_name_shadowing.jl` lowers the output of every emitter and
# asserts that each free global it references is either spelled outside Rust's
# identifier grammar or one of the generated module's own definitions — read
# off the emitted code, not a list.

# The module aliases the source-text emitter binds, and how `_emitted_source`
# spells a `GlobalRef` into each module.
const _EMITTED_BASE_ALIAS = Symbol("rustcall′Base")
const _EMITTED_RUSTCALL_ALIAS = Symbol("rustcall′RustCall")
const _EMITTED_PYTHONCALL_ALIAS = Symbol("rustcall′PythonCall")

# RustCall's names that emitted templates spell bare: the helpers every
# generated module used to import (`import RustCall: ...`) and `Libdl`, which
# the modules reach through RustCall (#339). Everything else of RustCall is
# spelled `RustCall.<name>` in a template, which `@_emitted` rewrites the same way.
const _EMITTED_RUSTCALL_NAMES = (:RustCall, :Libdl, :call_rust_function,
                                 :get_function_pointer_from_lib, :RustResult, :RustOption,
                                 :_check_not_freed, :_call_rust_owned_string_ptr,
                                 :_call_rust_borrowed_string_ptr, :convert_return,
                                 :_result_payload, :FFIByValue)

# The names Julia's `module` syntax binds in every module besides the module's
# own name: its `eval` and `include`. A crate item bound under one would replace
# or extend them, so the layout checks refuse it (`_check_module_names`,
# `_pyo3_host_definitions`); `test/test_module_name_shadowing.jl` reads the set
# off a freshly evaluated module.
const _JULIA_MODULE_OWN_NAMES = (:eval, :include)

# Names lowering treats as syntax rather than as a binding: never rewritten.
const _EMITTED_SYNTAX_NAMES = (:ccall, :cglobal, :new, :end, :__module__, :__source__)

"""
    _rust_spellable(name) -> Bool

Whether `name` is a Rust identifier's spelling, and so a name a crate item can
be bound under: an XID_Start character or `_`, then XID_Continue characters
(approximated by their Unicode general categories). `rustcall′Base` is not —
U+2032 is punctuation (`Po`) — and neither is an operator, a macro name or a
`#`-name.
"""
function _rust_spellable(name::Union{Symbol, AbstractString})
    s = String(name)
    isempty(s) && return false
    start = ("Lu", "Ll", "Lt", "Lm", "Lo", "Nl")
    cont = (start..., "Mn", "Mc", "Nd", "Pc")
    ok(c, cats) = c == '_' || Base.Unicode.category_abbrev(c) in cats
    return ok(first(s), start) && all(c -> ok(c, cont), s)
end

"""
    _emitted_global(s::Symbol, rustcall::Module) -> Union{Nothing, GlobalRef, Symbol}

What a free name `s` of an emitted template refers to outside the generated
module: a `GlobalRef` into Base (every name Base exports, Core's included) or
into RustCall (`_EMITTED_RUSTCALL_NAMES`), the host module's alias for
`PythonCall`, or `nothing` when it is none of those — a helper the generated
module defines itself (`_call_target`, `_pyo3_module`), which stays bare.
"""
function _emitted_global(s::Symbol, rustcall::Module)
    s in _EMITTED_SYNTAX_NAMES && return nothing
    _rust_spellable(s) || return nothing
    s === :PythonCall && return _EMITTED_PYTHONCALL_ALIAS
    s in _EMITTED_RUSTCALL_NAMES && return GlobalRef(rustcall, s)
    (isdefined(Base, s) && Base.isexported(Base, s)) && return GlobalRef(Base, s)
    return nothing
end

# The names a template binds anywhere — parameters, assignment targets, `let`
# / `for` / `catch` variables, type parameters, struct fields. Collected over
# the whole template and never rewritten: a template's own local is not a
# global, whatever it is called.
function _emitted_bound!(bound::Set{Symbol}, x)
    x isa Expr || return bound
    head = x.head
    (head === :$ || head === :quote || head === :export || head === :import ||
     head === :using) && return bound
    lhs!(t) = begin
        if t isa Symbol
            push!(bound, t)
        elseif t isa Expr && t.head in (:tuple, :parameters)
            foreach(lhs!, t.args)
        elseif t isa Expr && t.head === :(::) && length(t.args) == 2
            lhs!(t.args[1])
        elseif t isa Expr && t.head in (:kw, :(=))
            lhs!(t.args[1])
        elseif t isa Expr && t.head === :...
            lhs!(t.args[1])
        end
    end
    sig!(sig) = begin
        while sig isa Expr && sig.head === :where
            for tv in sig.args[2:end]
                tv isa Symbol && push!(bound, tv)
                tv isa Expr && tv.head in (:<:, :>:) && tv.args[1] isa Symbol &&
                    push!(bound, tv.args[1])
            end
            sig = sig.args[1]
        end
        sig isa Expr && sig.head === :(::) && length(sig.args) == 2 && (sig = sig.args[1])
        if sig isa Expr && sig.head === :call
            callee = sig.args[1]
            # A callable-object definition `(obj::T)(args)` binds `obj`.
            callee isa Expr && callee.head === :(::) && length(callee.args) == 2 &&
                lhs!(callee.args[1])
            foreach(lhs!, sig.args[2:end])
        elseif sig isa Expr && sig.head === :tuple
            foreach(lhs!, sig.args)
        elseif sig isa Symbol && head === :->
            push!(bound, sig)
        end
    end
    if head === :function || head === :->
        sig!(x.args[1])
    elseif head === :(=) && x.args[1] isa Expr &&
           (x.args[1].head === :call || x.args[1].head === :where ||
            (x.args[1].head === :(::) && x.args[1].args[1] isa Expr &&
             x.args[1].args[1].head === :call))
        sig!(x.args[1])
    elseif head === :(=) || head === :local || head === :global || head === :const
        lhs!(x.args[1])
    elseif head === :try && length(x.args) >= 2 && x.args[2] isa Symbol
        push!(bound, x.args[2])
    elseif head === :struct
        for field in x.args[3].args
            lhs!(field)
        end
    end
    foreach(a -> _emitted_bound!(bound, a), x.args)
    return bound
end

# Rewrite every free name of `x` that `_emitted_global` resolves. Definitions
# keep their own names (`function _symbol`, `struct CResult_f`); a dotted
# definition name (`function Base.show`) has its root rewritten like any other
# reference.
function _emitted_rewrite(x, bound::Set{Symbol}, rustcall::Module)
    rw(y) = _emitted_rewrite(y, bound, rustcall)
    if x isa Symbol
        x in bound && return x
        g = _emitted_global(x, rustcall)
        return g === nothing ? x : g
    end
    x isa Expr || return x
    head = x.head
    (head === :$ || head === :quote || head === :export || head === :import ||
     head === :using || head === :meta) && return x
    if head === :.
        # `Base.show`, `Core.Int32`, `RustCall.StateView`: one `GlobalRef` into
        # that module, unless the template binds the root itself.
        root = x.args[1]
        if root isa Symbol && !(root in bound) && length(x.args) == 2 && x.args[2] isa QuoteNode &&
           x.args[2].value isa Symbol
            mod = root === :Base ? Base : root === :Core ? Core : root === :RustCall ? rustcall : nothing
            mod === nothing || return GlobalRef(mod, x.args[2].value)
        end
        return Expr(:., rw(x.args[1]), x.args[2:end]...)
    elseif head === :kw
        # A keyword's name is not a reference; a defaulted parameter's type is
        # (`free_channel::Ptr{Cvoid} = C_NULL`), and its name is bound.
        name = x.args[1] isa Symbol ? x.args[1] : rw(x.args[1])
        return Expr(:kw, name, map(rw, x.args[2:end])...)
    elseif head === :function && x.args[1] isa Symbol
        return Expr(:function, x.args[1], map(rw, x.args[2:end])...)
    elseif head === :function || (head === :(=) && x.args[1] isa Expr &&
                                  x.args[1].head in (:call, :where, :(::)))
        return Expr(head, _emitted_signature(x.args[1], bound, rustcall), map(rw, x.args[2:end])...)
    elseif head === :struct
        name = x.args[2]
        name = name isa Expr && name.head === :<: ?
            Expr(:<:, name.args[1], rw(name.args[2])) : name
        return Expr(:struct, x.args[1], name, rw(x.args[3]))
    elseif head === :abstract
        return x
    end
    return Expr(head, map(rw, x.args)...)
end

# A definition's signature: its name stays unless it is dotted; everything else
# is an ordinary expression.
function _emitted_signature(sig, bound::Set{Symbol}, rustcall::Module)
    rw(y) = _emitted_rewrite(y, bound, rustcall)
    sig isa Expr || return sig
    if sig.head === :where
        return Expr(:where, _emitted_signature(sig.args[1], bound, rustcall), map(rw, sig.args[2:end])...)
    elseif sig.head === :(::) && length(sig.args) == 2 && sig.args[1] isa Expr &&
           sig.args[1].head === :call
        return Expr(:(::), _emitted_signature(sig.args[1], bound, rustcall), rw(sig.args[2]))
    elseif sig.head === :call
        callee = sig.args[1]
        callee = callee isa Symbol ? callee : rw(callee)
        return Expr(:call, callee, map(rw, sig.args[2:end])...)
    end
    return rw(sig)
end

"""
    @_emitted quote ... end
    @_emitted :(...)

A template of emitted code whose free references to Base, Core and RustCall are
`GlobalRef`s (#528): rewritten once, when RustCall itself is loaded, so no
binding of the module the code lands in can capture them. Interpolations
(`\$x`) are left alone — they carry the crate's own names and values — and so
is every name the template binds or defines itself.
"""
macro _emitted(ex)
    # `:(C_NULL)` parses as a `QuoteNode`, not a `:quote` expression.
    ex isa QuoteNode && return esc(QuoteNode(_emitted_rewrite(ex.value, Set{Symbol}(), __module__)))
    (ex isa Expr && ex.head === :quote) ||
        throw(ArgumentError("@_emitted takes a quoted template"))
    bound = _emitted_bound!(Set{Symbol}(), ex.args[1])
    return esc(Expr(:quote, _emitted_rewrite(ex.args[1], bound, __module__)))
end

"""
    _emitted_type(spelling) -> Union{Symbol, Expr, GlobalRef}

A type spelling from the FFI contract (`:Int32`, `:(Ptr{Cvoid})`,
`:(RustCall.RustVec{Float64})`) with every name it takes from Base or RustCall
made a `GlobalRef`, for a hole of an emitted template. A contract spelling names
no crate item, so every free name in it is one of those.
"""
_emitted_type(x) = _emitted_rewrite(x, Set{Symbol}(), @__MODULE__)
# `(surface, slot)` and the like, element by element.
_emitted_type(x::Tuple) = map(_emitted_type, x)

"""
    _emitted_source(ex) -> String

`ex` as the source-text emitter writes it: every `GlobalRef` spelled through the
generated module's `rustcall′` aliases (`rustcall′Base.getfield`,
`rustcall′RustCall.ffi_string_argument`) rather than by the module's plain
name, which a crate item could take.
"""
_emitted_source(ex) = string(_emitted_aliased(ex))

"""
    _emitted_type_source(spelling) -> String

A contract spelling as the source-text emitter writes it: `_emitted_type`, then
`_emitted_source`. A string is taken as already written.
"""
_emitted_type_source(x) = _emitted_source(_emitted_type(x))
_emitted_type_source(x::AbstractString) = String(x)

function _emitted_aliased(x)
    if x isa GlobalRef
        root = x.mod === Base ? _EMITTED_BASE_ALIAS :
               x.mod === Core ? Expr(:., _EMITTED_BASE_ALIAS, QuoteNode(:Core)) :
               x.mod === (@__MODULE__) ? _EMITTED_RUSTCALL_ALIAS :
               throw(ArgumentError("no alias for a reference into $(x.mod)"))
        x.name === nameof(x.mod) && return root
        return Expr(:., root, QuoteNode(x.name))
    elseif x isa Expr
        return Expr(x.head, map(_emitted_aliased, x.args)...)
    end
    return x
end

"""
    _emitted_aliases_source() -> Vector{String}

The lines that bind the source-text emitter's aliases at the top of a generated
module (and of each submodule): the only statements that name Base and RustCall
by their plain names, before any crate item is defined.
"""
_emitted_aliases_source() = [
    "import Base as $(_EMITTED_BASE_ALIAS)",
    "import RustCall as $(_EMITTED_RUSTCALL_ALIAS)",
]

# The same aliases in RustCall itself, so an expression that spells them —
# printed back with `_emitted_source` or evaluated here — resolves in RustCall
# too.
const var"rustcall′Base" = Base
const var"rustcall′RustCall" = @__MODULE__
