# #[julia] attribute support for automatic FFI wrapper generation
# This module handles detection, transformation, and Julia wrapper generation for
# Rust functions marked with #[julia] attribute.

"""
    RustFunctionSignature

Signature of a Rust free function as recorded in the FFI manifest produced by
`rustcall-extract` (see `src/macros/manifest.jl`). Julia never derives this from
source text.

# Fields
- `name`, `arg_types`, `return_type`: as written in Rust
- `arg_names`: the Julia parameter names of the arguments, in order —
  `julia_parameter_names` of the Rust names, applied by the constructor, so
  every emitter reads a name that parses (`end` → `end_`, `r#for` → `for_`,
  #516)
- `is_generic`, `type_params`, `constraints`: generic parameters and their trait bounds
- `symbol`: exported C symbol (`rustcall_<ffi_name>`, #279/#300)
- `ffi_name`: the stem every generated symbol of the function hangs off
  (manifest `Function.ffi_name`, schema 7, #300): `name` at the crate root,
  module-qualified otherwise (`a::run` -> `a__run`). The string release
  function is `<ffi_name>_free_rust_string`
- `attribute`: `:julia` or `:none`
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
- `ok_abi`/`err_abi`/`inner_abi`: how each `Result`/`Option` payload travels —
  `"string"` for an owned `<fn>_RustCallOwnedString` buffer, `""` as written
  (manifest schema 6, #268)
- `arg_slice_elements` / `arg_slice_lengths`: per argument, the manifest
  representation and length slot for `slice` / `slice_mut` borrows (#570);
  empty for every other argument
- `callback_args` / `callback_returns`: per argument, for an `arg_abis` entry
  of `"callback"`, the parameter and return spellings of the C-ABI function
  pointer (`Arg.callback_args` / `Arg.callback_return`, #296); empty otherwise
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
    # entry: `:julia` comes from a RustCall attribute,
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
    # Manifest schema 6 (#268): how each `Result`/`Option` payload travels —
    # `""` as written, `"string"` for an owned `<fn>_RustCallOwnedString`
    # buffer released with `<fn>_free_rust_string`.
    ok_abi::String
    err_abi::String
    inner_abi::String
    # Schema 12: PyO3's call shape, aligned with `arg_names`. Defaults are
    # Rust expressions for diagnostics only; generated Rust dispatchers own
    # their evaluation in the target crate's lexical scope.
    python_defaults::Vector{String}
    python_kinds::Vector{String}
    # Manifest schema 7 (#300): the stem of every generated symbol —
    # `rustcall_<ffi_name>`, `<ffi_name>_free_rust_string`. Equal to `name`
    # for a crate-root item; module-qualified inside modules.
    ffi_name::String
    # Callbacks (#296), aligned with `arg_names`: the function pointer's
    # parameter spellings and return spelling for an argument whose `abi` is
    # `"callback"`, empty for every other argument.
    callback_args::Vector{Vector{String}}
    callback_returns::Vector{String}
    # Manifest schema 0.6 additive (#424): the Python attribute path of an item
    # of a **declarative** PyO3 module (`#[pymodule] mod outer { ... }`), below
    # the imported module. Empty for a function-form crate or a direct item.
    python_path::Vector{String}
    # The PyO3-host shape of each argument and of the return (`Arg.py_shape`,
    # `Function.py_return`, additive within schema 0.7; PR #525 review);
    # `nothing` where the extractor described none (a `#[julia]` function).
    py_arg_shapes::Vector{Union{Nothing, PyO3Shape}}
    py_return_shape::Union{Nothing, PyO3Shape}
    # The `#[julia]` struct each argument borrows (#565), aligned with
    # `arg_names`; `nothing` for an argument that borrows none.
    arg_handles::Vector{Union{Nothing, RustHandleArg}}
    arg_slice_elements::Vector{String}
    arg_slice_lengths::Vector{String}
    return_handle::Union{Nothing, RustHandleArg}
    arg_borrow_reasons::Vector{String}
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
                               cfg_features::Vector{String} = String[],
                               ok_abi::String = _default_payload_abi(ok_type),
                               err_abi::String = _default_payload_abi(err_type),
                               inner_abi::String = _default_payload_abi(inner_type),
                               python_defaults::Vector{String} = fill("", length(arg_names)),
                               python_kinds::Vector{String} = fill("", length(arg_names)),
                               ffi_name::String = name,
                               callback_args::Vector{Vector{String}} = Vector{String}[String[] for _ in arg_names],
                               callback_returns::Vector{String} = fill("", length(arg_names)),
                               python_path::Vector{String} = String[],
                               py_arg_shapes::Vector{Union{Nothing, PyO3Shape}} =
                                   Union{Nothing, PyO3Shape}[nothing for _ in arg_names],
                               py_return_shape::Union{Nothing, PyO3Shape} = nothing,
                               arg_handles::Vector{Union{Nothing, RustHandleArg}} =
                                   Union{Nothing, RustHandleArg}[nothing for _ in arg_names],
                               arg_slice_elements::Vector{String} = fill("", length(arg_names)),
                               arg_slice_lengths::Vector{String} = fill("", length(arg_names)),
                               return_handle::Union{Nothing, RustHandleArg} = nothing,
                               arg_borrow_reasons::Vector{String} = fill("", length(arg_names)))
    length(arg_slice_elements) == length(arg_names) && length(arg_slice_lengths) == length(arg_names) ||
        throw(ArgumentError("slice metadata must have one entry per argument"))
    length(arg_borrow_reasons) == length(arg_names) ||
        throw(ArgumentError("arg_borrow_reasons must have one entry per argument"))
    length(arg_handles) == length(arg_names) ||
        throw(ArgumentError("arg_handles must have one entry per argument"))
    length(arg_abis) == length(arg_types) ||
        throw(ArgumentError("arg_abis must have one entry per argument"))
    length(python_defaults) == length(arg_names) ||
        throw(ArgumentError("python_defaults must have one entry per argument"))
    length(python_kinds) == length(arg_names) ||
        throw(ArgumentError("python_kinds must have one entry per argument"))
    length(callback_args) == length(arg_names) && length(callback_returns) == length(arg_names) ||
        throw(ArgumentError("callback_args and callback_returns must have one entry per argument"))
    # The Julia parameter names, decided here once for every emitter (#516).
    RustFunctionSignature(name, julia_parameter_names(arg_names), arg_types, return_type,
                          is_generic, type_params, symbol, attribute, exported, return_kind, ok_type, err_type, inner_type,
                          source, constraints, module_path, body_has_cfg,
                          has_owned_string_helper, has_borrowed_string_helper, arg_abis,
                          return_abi, vis, skip_reason, python_name, cfg_features,
                          ok_abi, err_abi, inner_abi, python_defaults, python_kinds,
                          isempty(ffi_name) ? name : ffi_name, callback_args,
                          callback_returns, python_path, py_arg_shapes, py_return_shape,
                          arg_handles, arg_slice_elements, arg_slice_lengths, return_handle, arg_borrow_reasons)
end

"""
    _default_arg_abis(arg_types) -> Vector{String}

The `abi` column for signatures constructed by hand (tests, legacy callers):
the extractor classifies argument types on the Rust side (`Arg.abi`:
`"string"`, `"str"` or `""`); this reconstructs the column from the FFI
contract (`src/ffi/ffi_contract.jl`), which is the same table the wrapper
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
    _string_arg_plan(sig) -> (bindings, preserved, call_args, frame)

How the Julia wrapper of `sig` passes its arguments: `bindings` converts each
argument (`String(x)` for string arguments, `Int32(x)` and friends for
primitives), `preserved` lists the string bindings to keep alive during the
call, and `call_args` are the expressions handed to the `ccall` (`pointer(s),
sizeof(s)` for strings, a constant slot-function pointer for a callback).
`frame` is `nothing`, or — when the signature has callback arguments (#296) —
the symbol of the `CallbackFrame` the last binding pushes for the call; the
site wraps the call with `_in_callback_frame(frame, call)`, whose `finally`
pops it. `escape` wraps user-visible symbols (`esc` in macro context,
`identity` inside a generated module).

Every argument is a position of the boundary report (#454): each is recorded
as it is decided, and in collecting mode a refusal — a callback signature the
plan cannot build, one callback past `CALLBACK_SLOTS` — is recorded and the
argument skipped rather than thrown.
"""
function _string_arg_plan(sig::RustFunctionSignature, escape::Function;
                          handle_scope::Union{Nothing, Vector{String}} = nothing)
    return _string_arg_plan(sig.arg_names, sig.arg_types, sig.arg_abis, escape;
                            context = sig.name,
                            callbacks = collect(zip(sig.callback_args, sig.callback_returns)),
                            handles = sig.arg_handles, handle_scope,
                            slice_elements = sig.arg_slice_elements,
                            slice_lengths = sig.arg_slice_lengths,
                            borrow_reasons = sig.arg_borrow_reasons)
end

# Same plan for a struct method (`RustMethod`), whose arguments follow `self`.
# `receiver` is the expression of the `self` handle, which every borrowed
# `#[julia]` argument is checked against (#565); `nothing` for a static method
# or a receiver that is not a Rust-owned handle.
function _string_arg_plan(method::RustMethod, escape::Function;
                          handle_scope::Union{Nothing, Vector{String}} = nothing,
                          receiver = nothing)
    plan = _string_arg_plan(method.arg_names, method.arg_types, method.arg_abis, escape;
                            context = method.name,
                            callbacks = collect(zip(method.callback_args, method.callback_returns)),
                            handles = method.arg_handles, handle_scope,
                            slice_elements = method.arg_slice_elements,
                            slice_lengths = method.arg_slice_lengths,
                            borrow_reasons = method.arg_borrow_reasons,
                            receiver = (method.is_static || receiver === nothing) ? nothing :
                                       (receiver, method.is_mutable))
    if !method.is_static && receiver !== nothing && _uses_optional_owner_ffi(method)
        pushfirst!(plan[1], @_emitted(:(RustCall.check_not_freed($receiver, "receiver of " * $(method.name)))))
    end
    return plan
end

"""
    _handle_type_ref(h::RustHandleArg, scope, escape) -> Any

How a wrapper names the Julia handle type of the struct a borrowed argument
names (#565). `scope` is the module path of the Julia module the wrapper is
defined in — every crate submodule mirrors a Rust module (#300) — and the
type is reached from there by `parentmodule` / `getfield`, so the reference
needs no name of the root module; `nothing` is an inline `rust` string block, which binds
every struct in its caller's module. Both emitters print the expression.
"""
function _handle_type_ref(h::RustHandleArg, scope::Union{Nothing, Vector{String}}, escape::Function)
    type_name = Symbol(julia_binding_name(h.name))
    (scope === nothing || scope == h.module_path) && return escape(type_name)
    common = 0
    while common < min(length(scope), length(h.module_path)) &&
          scope[common + 1] == h.module_path[common + 1]
        common += 1
    end
    ref = Expr(:macrocall, Symbol("@__MODULE__"), LineNumberNode(0, :none))
    for _ in (common + 1):length(scope)
        ref = @_emitted(:(parentmodule($ref)))
    end
    for segment in h.module_path[(common + 1):end]
        ref = @_emitted(:(getfield($ref, $(QuoteNode(Symbol(_julia_module_name(segment)))))))
    end
    return @_emitted(:(getfield($ref, $(QuoteNode(type_name)))))
end

function _string_arg_plan(arg_names::Vector{String}, arg_types::Vector{String},
                          arg_abis::Vector{String}, escape::Function;
                          context::AbstractString = "",
                          callbacks = Tuple{Vector{String}, String}[(String[], "") for _ in arg_names],
                          handles = Union{Nothing, RustHandleArg}[nothing for _ in arg_names],
                          handle_scope::Union{Nothing, Vector{String}} = nothing,
                          receiver = nothing,
                          slice_elements = fill("", length(arg_names)),
                          slice_lengths = fill("", length(arg_names)),
                          borrow_reasons = fill("", length(arg_names)))
    bindings = Expr[]
    preserved = Symbol[]
    call_args = Any[]
    prefix = _string_temp_prefix(arg_names)
    trampolines = Any[]
    callbacks_seen = 0
    has_mutable_slice = any(==("slice_mut"), arg_abis)
    # Every Julia handle the call borrows from — `self` first — with the
    # pointer it lends and whether the borrow is `&mut`, for the checks after
    # the loop (#565).
    # A label is a tuple of string literals with the parameter's name a literal
    # of its own, so renaming a parameter (#526) changes nothing else.
    buffer_borrows = Tuple{Any, Any, Bool, String}[]
    borrows = Tuple{Any, Any, Bool, Tuple}[]
    receiver === nothing ||
        push!(borrows, (first(receiver), @_emitted(:(getfield($(first(receiver)), :ptr))),
                        last(receiver), ("`self`",)))
    for (index, (name, rust_type, abi, callback, handle)) in
            enumerate(zip(arg_names, arg_types, arg_abis, callbacks, handles))
        arg_sym = escape(Symbol(name))
        position = "argument `$(name)`"
        if abi == "optional_borrow" || (_is_optional_handle_abi(abi) && handle === nothing)
            _boundary_refuse(position, rust_type, abi,
                "argument `$name` of `$context` is an optional borrowed owner whose concrete #[julia] owner is unresolved: " *
                (isempty(borrow_reasons[index]) ? "the defining Rust scope cannot prove a concrete owner" : borrow_reasons[index]) *
                "; annotate the owner with #[julia] and use an explicit import or qualified path where the scope is known; a rewriting context cannot prove an owner, and optional owners do not accept raw pointers")
            continue
        end
        if abi == "borrow_unresolved"
            reason = ffi_unresolved_borrow_message(name, context, borrow_reasons[index])
            _boundary_examined!(position, rust_type, abi, reason)
            ptr = Symbol(_EMITTER_LOCAL_PREFIX, "unresolved_borrow_ptr′", index)
            helper = GlobalRef(@__MODULE__, :ffi_unresolved_borrow_argument)
            push!(bindings, :($ptr = $helper($arg_sym, $reason)))
            push!(call_args, ptr)
            continue
        end
        if _is_handle_abi(abi) && handle !== nothing
            # A borrowed `#[julia]` struct (#565): the wrapper takes the
            # reference as written, one thin pointer, so the call passes the
            # pointer the Julia handle owns — never the object by value. The
            # handle is checked to be of the struct's own Julia type (another
            # crate's same-named type, or another module's, is refused), to
            # be neither freed nor of a closed image, and is preserved for
            # the whole call, so its finalizer cannot free the Rust value
            # under the borrow. A handle the manifest describes no Rust-owned
            # struct for (`_manifest_arg_handles`) is passed as before.
            _boundary_examined!(position, rust_type, abi, nothing)
            # Locals by position: a parameter's name appears only where the
            # parameter does (#526).
            obj = Symbol(_EMITTER_LOCAL_PREFIX, "handle′", index)
            ptr = Symbol(_EMITTER_LOCAL_PREFIX, "handle_ptr′", index)
            T = _handle_type_ref(handle, handle_scope, escape)
            label = ("`", name, "`")
            checker = GlobalRef(@__MODULE__, :check_not_freed)
            push!(bindings, :($obj = $arg_sym))
            # A raw pointer is passed through unchecked, as it was before
            # handles were recognised: the caller vouches for it. Anything
            # else must be the struct's own live handle.
            optional = _is_optional_handle_abi(abi)
            push!(bindings, @_emitted(:($ptr = if $optional && $obj === nothing
                Ptr{Cvoid}(C_NULL)
            elseif !$optional && $obj isa Ptr{Cvoid}
                $obj
            else
                $obj isa $T || throw(ArgumentError(string(
                    "argument ", $(label...), " of `", $context, "` borrows the Rust `",
                    $(handle.name), "`: expected a `", $T, "` handle, got ", typeof($obj))))
                $checker($obj, $(handle.name))
                getfield($obj, :ptr)
            end)))
            if optional
                roots = Symbol(_EMITTER_LOCAL_PREFIX, "optional_roots′", index)
                push!(bindings, @_emitted(:($roots = $obj === nothing ? () : ($obj,))))
                push!(preserved, roots)
            else
                push!(preserved, obj)
            end
            push!(call_args, ptr)
            push!(borrows, (obj, ptr, _is_mut_handle_abi(abi), label))
            continue
        end
        # The contract, not the spelling, decides how many C slots this
        # position occupies and what goes in them (#276).
        c = ffi_argument_contract(rust_type; abi = abi,
                                  slice_element = slice_elements[index],
                                  slice_length = slice_lengths[index])
        # Every argument is a position of the boundary report (#454, #441). A
        # spelling the contract does not cover is *accepted* here — the value
        # is handed to `call_rust_function` below and fails only when called —
        # so the report, not a refusal, is what names it.
        _boundary_examined!(position, rust_type, abi,
                            c.known ? nothing : ffi_describe(rust_type; direction = :argument, abi = abi))
        if abi in ("slice", "slice_mut")
            obj = Symbol(_EMITTER_LOCAL_PREFIX, "slice_owner′", index)
            span = Symbol(_EMITTER_LOCAL_PREFIX, "slice_span′", index)
            T = _emitted_type(ffi_type_expr(ffi_slice_element_type(slice_elements[index])))
            helper = GlobalRef(@__MODULE__, :ffi_slice_argument)
            push!(bindings, :($obj = $arg_sym))
            push!(bindings, :($span = $helper($obj, $T, $name, $context)))
            push!(preserved, obj)
            push!(call_args, @_emitted(:(getfield($span, :ptr))))
            push!(call_args, @_emitted(:(getfield($span, :len))))
            push!(buffer_borrows, (span, obj, abi == "slice_mut", name))
        elseif c.abi === :callback
            # A Julia function handed to Rust as `extern "C" fn` (#296). The
            # pointer's own signature comes from the manifest, and the
            # contract decides whether it can be built — at wrapper
            # generation, never at call time. Rust receives a constant
            # pointer to the plain slot function for this position, compiled
            # for exactly these slot types; the user's function travels in
            # the `CallbackFrame` the last binding pushes for the call (no
            # closure `@cfunction`, which not every platform has). The
            # trampoline keeps any Julia exception from unwinding through
            # Rust; the guard after the call re-raises it.
            plan = try
                ffi_callback_plan(first(callback), last(callback),
                                  "argument `$(name)` of `$(context)`")
            catch e
                (e isa RustError && _boundary_collecting()) || rethrow()
                # Collecting mode (#454): the plan's refusal is a finding and
                # this position gets no slot; the remaining arguments are
                # still examined.
                _boundary_examined!(position, rust_type, abi, e.message)
                nothing
            end
            plan === nothing && continue
            callbacks_seen += 1
            k = callbacks_seen
            if k > CALLBACK_SLOTS
                _boundary_refuse(position, rust_type, abi,
                    "`$(context)` takes more than $(CALLBACK_SLOTS) callback arguments (`$(name)` is " *
                    "number $(k)); at most $(CALLBACK_SLOTS) are supported (#296).")
                continue
            end
            # The slot's C types are contract spellings: `GlobalRef`s into Base,
            # so a crate item named `Int64` cannot capture them (#528).
            ret_expr = _emitted_type(plan.ret_expr)
            arg_exprs = map(_emitted_type, plan.arg_exprs)
            push!(trampolines,
                  :($(GlobalRef(@__MODULE__, :CallbackTrampoline)){$ret_expr}($arg_sym)))
            # A singleton callable carrying the slot's return type, so a
            # call with no trampoline behind it can still hand Rust a value of
            # the right type instead of raising (#460).
            slot = :($(GlobalRef(@__MODULE__, :CallbackSlot)){$k, $ret_expr}())
            push!(call_args, Expr(:macrocall, GlobalRef(Base, Symbol("@cfunction")), nothing,
                                  slot, ret_expr, Expr(:tuple, arg_exprs...)))
        elseif c.abi === :ptr_len || c.abi === :ptr_len_cap
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
            push!(call_args, @_emitted(:(pointer($bytes))))
            push!(call_args, @_emitted(:(sizeof($bytes) % Csize_t)))
            c.abi === :ptr_len_cap && push!(call_args, @_emitted(:(sizeof($bytes) % Csize_t)))
            if has_mutable_slice && abi in ("str", "string")
                span = Symbol(_EMITTER_LOCAL_PREFIX, "string_span′", index)
                helper = GlobalRef(@__MODULE__, :_ffi_string_span)
                push!(bindings, :($span = $helper($bytes)))
                push!(buffer_borrows, (span, bytes, false, name))
            end
        elseif c.known && c.abi === :by_value
            push!(call_args, :($(_emitted_type(_ffi_slot_expr(rust_type, c)))($arg_sym)))
        else
            # A pointer, the unit type, or a spelling the contract does not
            # cover: hand the value to `call_rust_function`, which applies its
            # own Julia-type-keyed coercion, exactly as before.
            push!(call_args, arg_sym)
        end
    end
    # Every handle a call borrows comes from one library image (#565): its
    # liveness flag is the image's identity (one image, one flag), so two
    # objects of a retired and a replacement generation, which may disagree
    # on the struct's layout, are never handed to one call together.
    for i in eachindex(borrows), j in (i + 1):length(borrows)
        (first_obj, _, _, first_label), (obj, _, _, label) = borrows[i], borrows[j]
        push!(bindings, @_emitted(:($obj === nothing || $first_obj === nothing ||
            $obj isa Ptr{Cvoid} || $first_obj isa Ptr{Cvoid} ||
            getfield($obj, :alive) === getfield($first_obj, :alive) ||
            throw(ArgumentError(string("`", $context, "` borrows ", $(first_label...), " and ",
                $(label...), " from different library images (a hot reload replaced the ",
                "library between their creation): pass objects of one generation"))))))
    end
    # Rust forbids a `&mut` borrow aliasing any other borrow of the call: one
    # Julia object passed both as `&mut` and as another argument (or as
    # `self`) is refused before Rust ever sees the two references (#565).
    # Shared borrows may alias (`sum(a, a)`).
    for i in eachindex(borrows), j in (i + 1):length(borrows)
        (pobj, p, pmut, plabel), (qobj, q, qmut, qlabel) = borrows[i], borrows[j]
        pmut || qmut || continue
        push!(bindings, @_emitted(:($pobj !== nothing && $qobj !== nothing && $p == $q && throw(ArgumentError(string(
            "`", $context, "` cannot borrow one Rust object as ", $(plabel...), " and ",
            $(qlabel...), ": a `&mut` borrow may not alias another borrow"))))))
    end
    for i in eachindex(buffer_borrows), j in (i + 1):length(buffer_borrows)
        (p, _, pmut, pname), (q, _, qmut, qname) = buffer_borrows[i], buffer_borrows[j]
        pmut || qmut || continue
        helper = GlobalRef(@__MODULE__, :_ffi_check_slice_overlap)
        push!(bindings, :($helper($p, $q, $pname, $qname, $context)))
    end
    for (span, _, mutable, name) in buffer_borrows
        for (obj, ptr, handle_mutable, label) in borrows
            mutable || handle_mutable || continue
            helper = GlobalRef(@__MODULE__, :_ffi_check_slice_handle_overlap)
            push!(bindings, @_emitted(:($obj === nothing || $helper($span, $ptr, $name, $context))))
        end
    end
    frame = nothing
    if !isempty(trampolines)
        # Last, after every conversion that can raise (a string that is not
        # UTF-8): nothing may throw between the push and the call's `finally`.
        frame = Symbol(_callback_temp_prefix(arg_names), "frame")
        push!(bindings, :($frame = $(GlobalRef(@__MODULE__, :_push_callback_frame!))($(trampolines...))))
    end
    return bindings, preserved, call_args, frame
end

"""
    _in_callback_frame(frame, call::Expr) -> Expr

`call`, or — when the plan pushed a `CallbackFrame` — `call` inside a
`try … finally` that pops it, so the frame is gone whether the call returns,
panics or raises (#296). Every wrapper generator wraps the expression that
performs the `ccall` with this; the source-text emitter's twin is
`_emit_in_callback_frame`.
"""
function _in_callback_frame(frame::Union{Nothing, Symbol}, call::Expr)
    frame === nothing && return call
    pop = GlobalRef(@__MODULE__, :_pop_callback_frame!)
    return :(try
                 $call
             finally
                 $pop($frame)
             end)
end

"""
    _string_temp_prefix(arg_names) -> String

Prefix for the temporaries that hold the converted strings: `rustcall′str′`,
in the namespace of the names an emitter binds itself (`_emitter_local`), which
no Rust identifier — so no argument, and no item of the crate — can spell (PR
#527 review). `arg_names` is no longer consulted.
"""
_string_temp_prefix(arg_names) = string(_EMITTER_LOCAL_PREFIX, "str′")

# The same for the `CallbackFrame` local of a call with callbacks (#296).
_callback_temp_prefix(arg_names) = string(_EMITTER_LOCAL_PREFIX, "cb′")

"""
    _generated_local(base, arg_names) -> Symbol

Name for a local the generated wrapper introduces (`func_ptr`, `c_result`,
...): `_emitter_local(base)`, which no Rust argument or crate item can spell,
so the two never meet (PR #527 review). `arg_names` is no longer consulted.
"""
_generated_local(base::AbstractString, arg_names) = _emitter_local(base)

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
    _boundary_label(sig) -> String
    _boundary_label(info, member) -> String

The item a boundary-report position is filed under (#454): the Rust item as
Rust names it, module-qualified below the crate root — `f`, `a::f`,
`a::S::method`, `S::field`.
"""
_boundary_label(sig::RustFunctionSignature) = qualified_name(sig.module_path, sig.name)
_boundary_label(info::RustStructInfo) = qualified_name(info.module_path, info.name)
_boundary_label(info::RustStructInfo, member::AbstractString) =
    string(qualified_name(info.module_path, info.name), "::", member)
# A method: `S::m`, or `<S as tr::Trait>::m` for a trait impl's, so a refused
# trait method and an inherent method of the same name are two items (#503).
_boundary_label(info::RustStructInfo, m::RustMethod) =
    isempty(m.trait_path) ? _boundary_label(info, m.name) :
    string("<", qualified_name(info.module_path, info.name), " as ", m.trait_path, ">::", m.name)

"""
    _ffi_function_return(sig) -> FFIContract

The return contract of a free function, with the owner set: the string helpers
are named after the Rust item's FFI name, so `<ffi_name>_free_rust_string`
comes out of the contract rather than being spelled at the call site (#246,
#249, #300).
"""
_ffi_function_return(sig::RustFunctionSignature) =
    _ffi_item_return(sig.return_type, sig.return_abi, sig.ffi_name, sig.return_kind)

"""
    _ffi_method_return(m::RustMethod, owner) -> FFIContract

The return contract of a struct method, with the owner of its string buffers
(`_method_string_owner`). A method that returns the struct itself
(`returns_boxed_struct`) hands back a handle bound to the generation that
allocated it: its spelling (`Self`) is not a contract position, so nothing
is recorded for it, and the emitter must not resolve it as one either.
"""
function _ffi_method_return(m::RustMethod, owner::AbstractString)
    m.returns_boxed_struct &&
        return ffi_return_contract(m.return_type; abi = m.return_abi, owner = owner)
    return _ffi_item_return(m.return_type, m.return_abi, owner, m.return_kind)
end

# The contract of an item's own return position, recorded for the boundary
# report (#454): the contract's verdict here, upgraded to a refusal by the
# `or_throw` helper the emitter calls next when the position needs one. A
# `Result` / `Option` return is not a position of its own — its payloads are,
# recorded by `ffi_payload_symbols` — so its spelling, which the contract
# never describes, is looked up but not recorded.
function _ffi_item_return(rust_type::AbstractString, abi::AbstractString, owner::AbstractString,
                          return_kind::Symbol)
    c = ffi_return_contract(rust_type; abi = abi, owner = owner)
    return_kind in (:result, :option, :py_result) && return c
    _boundary_examined!("return", rust_type, abi,
                        c.known ? nothing : ffi_describe(rust_type; direction = :return, abi = abi))
    _boundary_raw_pointer_return!("return", rust_type, c)
    return c
end

"""
    _ffi_field_return(info, field_name, field_type) -> FFIContract

The return contract of a struct field getter. `Field.abi` says whether the
getter hands back an owned String or Vec buffer. String release is derived from
the struct's FFI name; a Vec carries its element and exact release symbol in
schema 10 so the resulting `RustVec` retains the producing allocator (#303).
"""
function _ffi_field_return(info, field_name::AbstractString, field_type::AbstractString)
    # A field is one position of the boundary report however many accessors
    # read or write it (#454). The item is named here because every field
    # emitter — getter, setter, property branch, source text — starts with
    # this contract, and nothing records before it.
    _boundary_item!(_boundary_label(info, field_name))
    abi = get(info.field_abis, field_name, "")
    c = if abi == "vec"
        element = get(info.field_vec_elements, field_name, "")
        free_symbol = get(info.field_free_symbols, field_name, "")
        ffi_owned_vec_contract(field_type, element, free_symbol)
    else
        ffi_return_contract(field_type; abi = abi, owner = info.ffi_name)
    end
    _boundary_examined!(_ffi_field_position(info, field_name), field_type, abi,
                        c.known ? nothing : ffi_describe(field_type; direction = :return, abi = abi))
    return c
end

# The report's label for a field's one position: what the getter reads, or —
# for a write-only `#[pyo3(set)]` field — what the setter writes (#454).
_ffi_field_position(info, field_name::AbstractString) =
    field_is_accessible(info, field_name) ? "field getter" : "field setter"

# A field getter reads as `Struct::field -> T`.
_ffi_field_context(info, field_name::AbstractString, field_type::AbstractString) =
    string(info.name, "::", field_name, " -> ", field_type)

"""
    _uses_string_ffi(sig) -> Bool

Whether the wrapper of `sig` needs the preserving wrapper: string arguments, a
`String` / `&str` return, or a callback argument whose `CFunction` must stay
rooted for the call (#296). The plain wrapper has no `GC.@preserve` region.
"""
function _uses_string_ffi(sig::RustFunctionSignature)
    _ffi_function_return(sig).aggregate_type === nothing || return true
    # A borrowed `#[julia]` struct keeps its handle rooted for the call (#565).
    any(abi -> _is_handle_abi(abi) || abi in ("slice", "slice_mut", "optional_borrow", "borrow_unresolved"), sig.arg_abis) && return true
    return any(zip(sig.arg_types, sig.arg_abis)) do (rust_type, abi)
        c = ffi_argument_contract(rust_type; abi = abi)
        c.abi === :ptr_len || c.abi === :ptr_len_cap || c.abi === :callback
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

generates an `add(a, b)` that converts its arguments to the FFI slot types,
takes the call's generation snapshot (`cached_call_target`, #253, #277), calls
the exported wrapper through `ccall` and checks its panic channel
(`guard_rust_panic_ptr`). Strings, `Result` / `Option` returns, by-value
aggregates and callbacks each have their own generator
(`_generate_single_wrapper` dispatches). Generic signatures are skipped.
"""
function emit_julia_function_wrappers(signatures::Vector{RustFunctionSignature})
    exprs = Expr[]

    for sig in signatures
        if _function_skipped!(sig)
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
    _binds_julia_wrapper(sig) -> Bool

Whether a function gets a static Julia wrapper, and so a binding in the
generated module: not a generic (inline, it is monomorphized per call; in a
crate, the proc macro refuses it), and not an item the Rust codegen refuses
(#491, `_rust_refuses`). The one predicate the emitters
(`_function_skipped!`) and the layout checks (`_check_module_names`,
`_static_method_collisions`) share, so a name is checked exactly when it is
bound.
"""
_binds_julia_wrapper(sig::RustFunctionSignature) =
    !sig.is_generic && !_rust_refuses(sig.skip_reason)

"""
    _binds_julia_struct(info) -> Bool

Whether a struct gets a Julia type, and so a name in the generated module: not
one the Rust codegen refuses (a generic `#[julia]` struct of a crate, #462,
#503). The struct emitters report such a struct through `_rust_refused_item!`,
and the layout checks skip it through this predicate.
"""
_binds_julia_struct(info::RustStructInfo) = !_rust_refuses(info.skip_reason)

"""
    _function_skipped!(sig) -> Bool

Whether a function emitter skips `sig` (`!_binds_julia_wrapper(sig)`). The
emitter is still where a refusal the Rust codegen makes on its own is recorded
(#491), a generic `#[julia] unsafe fn` included, so the report names it.
"""
function _function_skipped!(sig::RustFunctionSignature)
    _binds_julia_wrapper(sig) && return false
    _boundary_item!(_boundary_label(sig))
    _rust_refused_item!(sig.skip_reason, sig.name)
    return true
end

"""
    _inline_wrapper_exprs(signatures, struct_infos) -> (struct_defs, function_wrappers)

The Julia definitions of one `rust\"\"\"` block: an expression per `#[julia]`
struct (`emit_julia_definitions`, with the block-wide static-method
collisions of #323) and the block's function wrappers. `@rust_str` splices
them into its expansion; `inline_boundary_report` runs them in collecting
mode (#454), so what the report examines is what the block defines.

`block` is the block's `RustBlockSnapshot` as `@rust_str` records it: a generic
struct's generated code finds its members through it (#522).
"""
function _inline_wrapper_exprs(signatures::Vector{RustFunctionSignature},
                               struct_infos::Vector{RustStructInfo};
                               block = nothing)
    # Every parameter named against the definitions it lands in (#526).
    emit(fs, ss) = begin
        defs, wrappers = _inline_wrapper_exprs_as_emitted(
            Vector{RustFunctionSignature}(fs), Vector{RustStructInfo}(ss); block)
        Expr(:block, defs..., wrappers)
    end
    signatures, struct_infos = _rename_parameters(signatures, struct_infos, emit)
    return _inline_wrapper_exprs_as_emitted(Vector{RustFunctionSignature}(signatures),
                                            Vector{RustStructInfo}(struct_infos); block)
end

function _inline_wrapper_exprs_as_emitted(signatures::Vector{RustFunctionSignature},
                                          struct_infos::Vector{RustStructInfo}; block = nothing)
    colliding = _static_method_collisions(signatures, struct_infos)
    struct_defs = [emit_julia_definitions(info; colliding = colliding, block = block)
                   for info in struct_infos]
    return struct_defs, emit_julia_function_wrappers(signatures)
end

"""
    _generate_single_wrapper(sig::RustFunctionSignature) -> Union{Expr, Nothing}

Generate a Julia wrapper function for a single Rust function signature.
Uses direct function call instead of @rust macro for better scope handling.
"""
function _generate_single_wrapper(sig::RustFunctionSignature)
    # The item every position below is filed under (#454), named before the
    # argument plan, which records first.
    _boundary_item!(_boundary_label(sig))
    # An item the Rust codegen refuses gets no wrapper (#491).
    _rust_refused_item!(sig.skip_reason, sig.name) && return nothing
    sig.return_handle === nothing || return _owned_return_wrapper(sig; inline = true, escape = esc)
    # The Julia wrapper keeps the Rust *name* (`add(1, 2)`); the call goes to
    # the exported *symbol*, which since #279 is `rustcall_add`.
    func_name = esc(Symbol(julia_function_name(sig)))
    symbol_str = sig.symbol

    # Build argument list with conversion (string arguments become (ptr, len)
    # pairs kept alive with GC.@preserve, see `_string_arg_plan`)
    arg_syms = [esc(Symbol(name)) for name in sig.arg_names]
    bindings, preserved, converted_args, frame = _string_arg_plan(sig, esc)

    if sig.return_kind == :result
        return _generate_inline_result_wrapper(sig, func_name, symbol_str, arg_syms, bindings, preserved, converted_args, frame)
    elseif sig.return_kind == :option
        return _generate_inline_option_wrapper(sig, func_name, symbol_str, arg_syms, bindings, preserved, converted_args, frame)
    elseif _uses_string_ffi(sig)
        return _generate_inline_string_wrapper(sig, func_name, symbol_str, arg_syms)
    end

    # The one return decision (#276): the contract, or a failure naming the
    # signature — never a silent `Any`.
    julia_ret_type = ffi_return_symbol_or_throw(sig.return_type, sig.return_abi,
                                                _ffi_context(sig))

    # Generate the wrapper function using internal API directly
    # This avoids macro expansion issues
    rust_name = sig.name
    # The snapshot carries the pointer **and the panic channel of the image
    # that holds it**. A wrapper defined by one block may well resolve through
    # another (the cross-library fallback), and the panic channel has to be
    # read on the library that actually holds the wrapper — otherwise a panic
    # is looked for in the wrong image and silently missed (#244).
    channel_sym = _generated_local("panic_channel", sig.arg_names)
    # This call site's own cache, spliced into the body as a constant: one
    # object per generated wrapper, no binding in the caller's module, and a
    # fresh one if the wrapper is generated again (#253).
    cache = RustCall.CallTargetCache()
    return quote
        function $func_name($(arg_syms...))
            # One snapshot: pointer and panic channel from the same
            # generation, resolved before the call (the channel is a
            # thread-local, so nothing may yield between call and read) — #244,
            # #277. Reused across calls only while the artifact epoch says no
            # state write has happened since it was taken (#253) — still one
            # snapshot of one image per call, never reassembled from pieces.
            $channel_sym = RustCall.cached_call_target($cache, @__MODULE__, $symbol_str)
            RustCall.guard_rust_panic_ptr(
                RustCall.call_rust_function($channel_sym.func_ptr, $julia_ret_type, $(converted_args...)),
                $channel_sym.channel, $rust_name)
        end
    end
end

# Insert the snapshot and its borrow checks after argument validation, but
# before the argument plan pushes a callback frame. A failed image check must
# neither enter Rust nor leave a callback frame behind.
function _inline_handle_target_bindings!(bindings, sig, target, frame, snapshot)
    checks = Expr[snapshot]
    if _uses_slice_ffi(sig)
        push!(checks, @_emitted(:(RustCall._require_slice_args_abi($target.handle, $(sig.symbol)))))
    end
    if _uses_optional_owner_ffi(sig)
        push!(checks, @_emitted(:(RustCall._require_optional_owner_abi($target.handle, $(sig.symbol)))))
    end
    for (i, (abi, handle)) in enumerate(zip(sig.arg_abis, sig.arg_handles))
        _is_handle_abi(abi) && handle !== nothing || continue
        obj = Symbol(_EMITTER_LOCAL_PREFIX, "handle′", i)
        push!(checks, @_emitted(:($obj === nothing || $obj isa Ptr{Cvoid} ||
            getfield($obj, :alive) === $target.alive ||
            throw(ArgumentError("borrowed handle and call target belong to different library images; recreate the object after hot reload")))))
    end
    at = length(bindings) + (frame === nothing ? 1 : 0)
    for check in checks
        insert!(bindings, at, check)
        at += 1
    end
    return bindings
end

# String / &str arguments and returns (#242): arguments travel as (ptr, len)
# byte pairs kept alive with GC.@preserve; a `String` return is an owned
# `<fn>_RustCallOwnedString` released through `<fn>_free_rust_string`, a `&str`
# return a borrowed `<fn>_RustCallBorrowedString`.
function _generate_inline_string_wrapper(sig, func_name, symbol_str, arg_syms)
    bindings, preserved, call_args, frame = _string_arg_plan(sig, esc)
    c = _ffi_function_return(sig)
    rust_name = sig.name
    channel_sym = _generated_local("panic_channel", sig.arg_names)
    raw_sym = _generated_local("string_result", sig.arg_names)
    string_cache = RustCall.CallTargetCache()
    snapshot = if ffi_owned_string_return(c)
        # The release function, panic channel and borrow identity all come
        # from the very image executing the call, never a later name lookup.
        :($channel_sym = RustCall.resolve_call_target(
            RustCall.module_symbol_library(@__MODULE__, $symbol_str), $symbol_str;
            free_symbol = $(c.free_symbol)))
    else
        :($channel_sym = RustCall.cached_call_target($string_cache, @__MODULE__, $symbol_str; slice_args = $(_uses_slice_ffi(sig)), optional_owner_args = $(_uses_optional_owner_ffi(sig))))
    end
    _inline_handle_target_bindings!(bindings, sig, channel_sym, frame, snapshot)
    call = if ffi_owned_string_return(c)
        quote
            $raw_sym = RustCall.call_rust_function($channel_sym.func_ptr, RustCall.CRustString, $(call_args...))
            RustCall.check_rust_panic_ptr($channel_sym.channel, $rust_name, $raw_sym, $channel_sym.free_ptr)
            RustCall._take_owned_string($raw_sym, $channel_sym.free_ptr)
        end
    elseif ffi_borrowed_string_return(c)
        quote
            $raw_sym = RustCall.call_rust_function($channel_sym.func_ptr, RustCall.CRustStr, $(call_args...))
            RustCall.check_rust_panic_ptr($channel_sym.channel, $rust_name)
            RustCall._crust_str_to_julia($raw_sym)
        end
    else
        ret = ffi_return_symbol_or_throw(sig.return_type, sig.return_abi, _ffi_context(sig))
        :(RustCall.guard_rust_panic_ptr(
              RustCall.call_rust_function($channel_sym.func_ptr, $ret, $(call_args...)),
              $channel_sym.channel, $rust_name))
    end
    quote
        function $func_name($(arg_syms...))
            $(bindings...)
            $(_in_callback_frame(frame, :(GC.@preserve $(preserved...) begin
                $call
            end)))
        end
    end
end

# Result<T, E> / Option<T> returning #[julia] functions in inline blocks: the
# extractor generates `CResult_<fn>` / `COption_<fn>` on the Rust side; the
# wrapper reads that struct and converts it to RustResult / RustOption.
function _generate_inline_result_wrapper(sig, func_name, symbol_str, arg_syms, bindings, preserved, converted_args,
                                         frame::Union{Nothing, Symbol} = nothing)
    ctx = _ffi_context(sig)
    # The payloads are FIELDS of a `#[repr(C)]` aggregate, so they are declared
    # with the type Rust stored — the C slot — and converted to the surface type
    # after the call. For `char` those differ: Rust writes a `UInt32` code point
    # where Julia's `Char` would be a left-aligned UTF-8 bit pattern (#245); for
    # a `String` payload the slot is the owned `CRustString` buffer (#268).
    ok_t, ok_slot = ffi_payload_symbols(sig.ok_type, sig.ok_abi, ctx; position = "Ok payload")
    err_t, err_slot = ffi_payload_symbols(sig.err_type, sig.err_abi, ctx; position = "Err payload")
    free_sym = _payload_free_symbol(sig.ffi_name, (sig.ok_abi, sig.err_abi))
    c_sym = _generated_local("c_result", sig.arg_names)
    channel_sym = _generated_local("panic_channel", sig.arg_names)
    rust_name = sig.name
    snapshot = :($channel_sym = RustCall.resolve_call_target(
        RustCall.module_symbol_library(@__MODULE__, $symbol_str), $symbol_str;
        free_symbol = $free_sym))
    _inline_handle_target_bindings!(bindings, sig, channel_sym, frame, snapshot)
    quote
        function $func_name($(arg_syms...))
            $(bindings...)
            # One snapshot: the wrapper, its panic channel and — when a payload
            # is an owned string — the `<fn>_free_rust_string` that releases it,
            # all from the generation that will run the call (#277).
            $c_sym = $(_in_callback_frame(frame, :(GC.@preserve $(preserved...) RustCall.call_rust_function($channel_sym.func_ptr, RustCall.CResultType{$ok_slot, $err_slot}, $(converted_args...)))))
            # A panic returns `CResult::panicked()` — the Err discriminant with
            # an uninitialized payload — so the channel must be read before the
            # payload is decoded, and resolved before the call (#244).
            RustCall.check_rust_panic_ptr($channel_sym.channel, $rust_name, $c_sym,
                                          $channel_sym.free_ptr)
            RustCall.convert_c_result_to_rust_result($c_sym, $ok_t, $err_t,
                                                     $channel_sym.free_ptr)
        end
    end
end

function _generate_inline_option_wrapper(sig, func_name, symbol_str, arg_syms, bindings, preserved, converted_args,
                                         frame::Union{Nothing, Symbol} = nothing)
    ctx = _ffi_context(sig)
    inner_t, inner_slot = ffi_payload_symbols(sig.inner_type, sig.inner_abi, ctx;
                                              position = "Some payload")
    free_sym = _payload_free_symbol(sig.ffi_name, (sig.inner_abi,))
    c_sym = _generated_local("c_option", sig.arg_names)
    channel_sym = _generated_local("panic_channel", sig.arg_names)
    rust_name = sig.name
    snapshot = :($channel_sym = RustCall.resolve_call_target(
        RustCall.module_symbol_library(@__MODULE__, $symbol_str), $symbol_str;
        free_symbol = $free_sym))
    _inline_handle_target_bindings!(bindings, sig, channel_sym, frame, snapshot)
    quote
        function $func_name($(arg_syms...))
            $(bindings...)
            $c_sym = $(_in_callback_frame(frame, :(GC.@preserve $(preserved...) RustCall.call_rust_function($channel_sym.func_ptr, RustCall.COptionType{$inner_slot}, $(converted_args...)))))
            RustCall.check_rust_panic_ptr($channel_sym.channel, $rust_name, $c_sym,
                                          $channel_sym.free_ptr)
            RustCall.convert_c_option_to_rust_option($c_sym, $inner_t,
                                                     $channel_sym.free_ptr)
        end
    end
end

"""
    _payload_free_symbol(owner, abis) -> String

The `<owner>_free_rust_string` a `Result` / `Option` wrapper must resolve with
its function pointer, or `""` when no payload is an owned string buffer (#268).
Both payloads of one wrapper share the owner's single buffer type, so there is
never more than one release symbol to snapshot.
"""
_payload_free_symbol(owner::AbstractString, abis) =
    any(_is_string_abi, abis) ? ffi_free_symbol(owner) : ""

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
# `COption_<fn>`, `deps/rustcall_julia_core/src/codegen.rs`), so the by-value layout
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
function convert_c_result_to_rust_result(c_result, ::Type{T}, ::Type{E},
                                        free_ptr::Ptr{Cvoid} = C_NULL) where {T, E}
    # The payload fields hold the C slot; `_result_payload` reads them back as
    # the surface type (identity for everything but `char`, whose slot is a
    # `UInt32` code point, and an owned `CRustString`, which is copied out and
    # released through `free_ptr`). Only the ACTIVE payload is converted — the
    # inactive one is uninitialized on the Rust side and may hold anything, and
    # releasing it would be a double free.
    if c_result.is_ok == 1
        RustResult{T, E}(true, _result_payload(T, c_result.ok_value, free_ptr))
    else
        RustResult{T, E}(false, _result_payload(E, c_result.err_value, free_ptr))
    end
end

"""
    convert_c_option_to_rust_option(c_option, inner_type::Type) -> RustOption

Convert a C-compatible option struct to RustOption{T}.
"""
function convert_c_option_to_rust_option(c_option, ::Type{T},
                                        free_ptr::Ptr{Cvoid} = C_NULL) where {T}
    # See `convert_c_result_to_rust_result`: the field holds the C slot, and
    # only a `Some` payload is initialized.
    if c_option.is_some == 1
        RustOption{T}(true, _result_payload(T, c_option.value, free_ptr))
    else
        RustOption{T}(false, nothing)
    end
end

# One explicit owned-return plan, shared by all three Julia emitters. The
# front doors supply only the function declaration and the existing image
# snapshot flavour; the selected owner, payload and adoption rules live here.
function _owned_return_wrapper(
    item,
    info = nothing;
    inline::Bool,
    escape::Function = identity,
    bare::Bool = true,
)
    owner = item.return_handle
    owner === nothing &&
        throw(ArgumentError("an explicit owned return needs return_handle metadata"))
    item.return_kind in (:plain, :result) || throw(
        RustError("explicit owned return supports only direct owners or Result<Owner, E>"),
    )
    item.return_kind === :result &&
        item.ok_abi != "boxed" &&
        throw(RustError("explicit owned Result must declare a boxed Ok payload"))
    item.return_kind === :plain &&
        item.return_abi != "boxed" &&
        throw(RustError("explicit owned return must declare a boxed return ABI"))
    method = info !== nothing
    scope = method ? info.module_path : item.module_path
    type_ref = _handle_type_ref(owner, inline ? nothing : scope, escape)
    T = _emitter_local("owned_type")
    symbol = method ? method_wrapper_symbol(info.ffi_name, item) : item.symbol
    free_symbol = ffi_struct_free_symbol(owner.ffi_name)
    receiver =
        method && !item.is_static ? (inline ? :self : _emitter_local("self")) : nothing
    bindings, preserved, args, frame =
        method ?
        _string_arg_plan(item, escape; handle_scope = inline ? nothing : scope, receiver) :
        _string_arg_plan(item, escape; handle_scope = inline ? nothing : scope)
    if method && item.is_static && item.is_constructor && length(item.arg_names) == 1
        argument = escape(Symbol(only(item.arg_names)))
        pushfirst!(
            bindings,
            @_emitted(
                :(
                    $argument isa Ptr && throw(
                        ArgumentError(
                            "an explicit owned factory requires its declared value/owner argument; raw pointer adoption uses the full pointer/free/alive constructor",
                        ),
                    )
                )
            )
        )
    end
    # Resolve the selected class before entering Rust: a missing Julia binding
    # must never strand an already-produced pointer outside the adopter.
    pushfirst!(bindings, :($T = $type_ref))
    if receiver !== nothing
        pushfirst!(
            bindings,
            @_emitted(:(RustCall.check_not_freed($receiver, $(info.name))))
        )
        pushfirst!(preserved, receiver)
        pushfirst!(args, @_emitted(:(getfield($receiver, :ptr))))
    end
    borrows =
        method ?
        (
            inline ? _inline_method_borrows(item; receiver = receiver) :
            _crate_call_borrows(item; receiver = receiver)
        ) : _crate_call_borrows(item)
    target = _emitter_local("owned_target")
    fp, channel, free, alive, free_channel, payload = (
        _emitter_local(n) for n in (
            "owned_fn",
            "owned_panic",
            "owned_free",
            "owned_alive",
            "owned_drop_panic",
            "owned_payload_free",
        )
    )
    raw, value = _emitter_local("owned_raw"), _emitter_local("owned_value")
    fallible = item.return_kind === :result
    _boundary_examined!(
        fallible ? "Ok payload" : "return",
        fallible ? item.ok_type : item.return_type,
        "boxed",
        nothing,
    )
    err_surface, err_slot =
        fallible ?
        ffi_payload_symbols(
            item.err_type,
            item.err_abi,
            method ? _ffi_context(item, info.name) : _ffi_context(item);
            position = "Err payload",
        ) : (nothing, nothing)
    err_surface = fallible ? _emitted_type(err_surface) : nothing
    err_slot = fallible ? _emitted_type(err_slot) : nothing
    string_owner = method ? _method_string_owner(item, info.ffi_name) : item.ffi_name
    payload_symbol = fallible ? _payload_free_symbol(string_owner, (item.err_abi,)) : ""
    lib =
        inline ?
        (
            receiver === nothing ?
            @_emitted(:(RustCall.module_symbol_library(@__MODULE__, $symbol))) :
            @_emitted(:(getfield($receiver, :lib_name)))
        ) : ""
    snapshot = if inline
        @_emitted quote
            $target = RustCall._check_inline_call_borrows(
                RustCall.resolve_call_target($lib, $symbol; free_symbol = $free_symbol),
                $borrows;
                slice_symbol = $(_uses_slice_ffi(item) ? symbol : ""),
                optional_symbol = $(_uses_optional_owner_ffi(item) ? symbol : ""),
            )
            RustCall._require_owned_return_abi($target.handle, $symbol)
            $(
                fallible ?
                @_emitted(
                    :(RustCall.Libdl.dlsym($target.handle, $symbol * "_boxed_result_v1"))
                ) : nothing
            )
            $fp, $channel, $free, $alive, $free_channel = $target.func_ptr,
            $target.channel,
            $target.free_ptr,
            $target.alive,
            $target.free_channel
            $payload = $(
                isempty(payload_symbol) ? @_emitted(:(Ptr{Cvoid}(C_NULL))) :
                @_emitted(:(RustCall.Libdl.dlsym($target.handle, $payload_symbol)))
            )
        end
    else
        cache = _target_cache_name(method ? :m : :fn, symbol)
        fallible ?
        @_emitted(
            :(
                ($fp, $channel, $free, $alive, $free_channel, $payload) =
                    _ctor_result_target(
                        $cache,
                        $symbol,
                        $free_symbol,
                        $payload_symbol;
                        borrows = $borrows,
                    )
            )
        ) :
        @_emitted quote
            $fp, $channel, $free, $alive, $free_channel =
                _ctor_target($cache, $symbol, $free_symbol; borrows = $borrows)
            $payload = Ptr{Cvoid}(C_NULL)
        end
    end
    snapshot = @_emitted quote
        $snapshot
        $free != C_NULL || error("explicit owned return from " * $symbol * " has no selected owner destructor")
    end
    insert!(bindings, frame === nothing ? length(bindings) + 1 : length(bindings), snapshot)
    lib_value = inline ? :($target.lib_name) : ""
    adopt(pointer) = @_emitted(
        :(RustCall._adopt_owned_return(
            $T,
            $pointer,
            $lib_value,
            $free,
            $alive,
            $free_channel,
            $inline,
        ))
    )
    ctype =
        fallible ? @_emitted(:(RustCall.CResultType{Ptr{Cvoid},$err_slot})) :
        @_emitted(:(Ptr{Cvoid}))
    call = @_emitted(:(RustCall.call_rust_function($fp, $ctype, $(args...))))
    guarded_call = _in_callback_frame(frame, _quote_preserved(preserved, call))
    body = if fallible
        @_emitted quote
            $(bindings...)
            $raw = $guarded_call
            RustCall.guard_boxed_result_panic_ptr(
                $raw,
                $channel,
                $symbol,
                $payload,
                $free,
                $alive,
                $free_channel,
            )
            if $raw.is_ok == 1
                $value = $(adopt(:($raw.ok_value)))
                RustCall.RustResult{$T,$err_surface}(true, $value)
            else
                RustCall.RustResult{$T,$err_surface}(
                    false,
                    RustCall._result_payload($err_surface, $raw.err_value, $payload),
                )
            end
        end
    else
        @_emitted quote
            $(bindings...)
            $raw = $guarded_call
            RustCall._guard_owned_return_ptr(
                $raw,
                $channel,
                $symbol,
                $free,
                $alive,
                $free_channel,
            )
            $(adopt(raw))
        end
    end
    arg_names = [escape(Symbol(n)) for n in item.arg_names]
    fname =
        method ? escape(Symbol(julia_method_name(item))) :
        escape(Symbol(julia_function_name(item)))
    owner_type = method ? escape(Symbol(julia_struct_name(info))) : nothing
    decl = if !method
        Expr(:call, fname, arg_names...)
    elseif item.is_static && item.is_constructor
        Expr(:call, Expr(:(::), Expr(:curly, GlobalRef(Core, :Type), owner_type)), arg_names...)
    elseif item.is_static
        Expr(
            :call,
            fname,
            Expr(:(::), Expr(:curly, GlobalRef(Core, :Type), owner_type)),
            arg_names...,
        )
    else
        Expr(:call, fname, Expr(:(::), receiver, owner_type), arg_names...)
    end
    definition = Expr(:function, decl, body)
    result = Expr(:block)
    inline || push!(result.args, _target_cache_const(method ? :m : :fn, symbol))
    push!(result.args, definition)
    if !inline && (!method || !item.is_static || !item.is_constructor)
        push!(result.args, Expr(:export, fname))
    end
    if method && item.is_static && !item.is_constructor && bare
        delegate_args = [_emitter_local("owned_arg$i") for i in eachindex(arg_names)]
        push!(
            result.args,
            Expr(
                :(=),
                Expr(:call, fname, delegate_args...),
                Expr(:call, fname, owner_type, delegate_args...),
            ),
        )
    end
    return result
end
