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

const RUST_COMPARISON_OPS = (
    Symbol("=="),
    Symbol("==="),
    Symbol("!="),
    Symbol("!=="),
    Symbol("<"),
    Symbol("<="),
    Symbol(">"),
    Symbol(">="),
    Symbol("\u2248"),
)

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

    # One cache per expansion, spliced in as a constant: the call site keeps the
    # snapshot it resolved and re-resolves only when the artifact epoch moves
    # (#253). `_resolve_lib` moves with it onto the slow path — it walked every
    # block of the module, on every call.
    cache = CallTargetCache()
    if ret_type === nothing
        # Dynamic dispatch based on argument types
        return Expr(:call, GlobalRef(RustCall, :_rust_call_dynamic_cached),
                    cache, mod, "", func_name_str, escaped_args...)
    else
        # Static dispatch with known return type
        return Expr(:call, GlobalRef(RustCall, :_rust_call_typed_cached),
                    cache, mod, "", func_name_str, esc(ret_type), escaped_args...)
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
    active = _module_binding(mod, :__RUSTCALL_ACTIVE_LIB)
    if active !== nothing
        active[] == stored_name && (active[] = actual_name)
    end
    return nothing
end

"""
    _module_binding(mod, name) -> Any

The value bound to `name` in `mod`, or `nothing` when there is none. For an
adopted legacy caller's runtime tables, return its STATE-owned view instead
of the historical raw constant.

`getfield` is invoked in the **latest** world. A `rust\"\"\"` block defines
`__RUSTCALL_LIBS` and `__RUSTCALL_ACTIVE_LIB` in `mod`, and a `@rust` call in
the same top-level expression — or a test that builds a module and calls
straight into it — reads them from a world older than the one that defined
them. Julia 1.12 warns about that access ("in a world prior to its definition
world") and says it will become an error; `invokelatest` is the documented way
to say "resolve this now", which is what these two bindings need: they are
plain mutable containers whose *identity* is what matters, not something the
compiler should specialize on.
"""
function _module_binding(mod::Module, name::Symbol)
    isdefined(mod, name) || return nothing
    # Once a legacy caller is adopted, internal reads/writes use its owned
    # copy. Its old constants are historical snapshots, not live registries.
    kind = name === :__RUSTCALL_LIBS ? :libs :
           name === :__RUSTCALL_SYMBOL_LIB ? :symbols :
           name === :__RUSTCALL_ACTIVE_LIB ? :active : nothing
    if kind !== nothing && haskey(MODULE_STATES, mod)
        return StateView(kind, mod)
    end
    return Base.invokelatest(getfield, mod, name)
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
    libs = _module_binding(mod, :__RUSTCALL_LIBS)
    if libs !== nothing
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
            # The key and the block's recorded order move together, in one
            # transaction: a concurrent first call that saw the new key without
            # its order ranked the module's newest block last (#520 review).
            _rebind_module_block!(mod, libs, lname, actual, code)
        end
    end

    # If no library name specified (e.g. @rust func() without a prior rust"""..."""),
    # try to use the module's active library.
    if isempty(lib_name)
        active = _module_binding(mod, :__RUSTCALL_ACTIVE_LIB)
        active === nothing && return get_current_library()
        lib_name = active[]
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

    cache = CallTargetCache()
    if ret_type === nothing
        return Expr(
            :call,
            GlobalRef(RustCall, :_rust_call_dynamic_cached),
            cache, mod, lib_name_str,
            func_name_str,
            escaped_args...
        )
    end

    return Expr(
        :call,
        GlobalRef(RustCall, :_rust_call_typed_cached),
        cache, mod, lib_name_str,
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
    # One resolution order for every `@rust` form (#520): `resolve_rust_call`
    # decides whether `func_name` is a generic to specialize or a function to
    # call — here with `lib_name` as the caller's own library. A resolved
    # target is one snapshot: pointer, panic channel and return type from the
    # same generation of the same library (#277).
    resolution = resolve_rust_call(nothing, lib_name, func_name)
    resolution isa GenericFunctionInfo && return call_generic_function(resolution, args...)
    _, target = resolution
    return _dispatch_with_target(target, lib_name, func_name, args...)
end

"""
    resolve_rust_call(mod, lib_name, func_name) -> Union{GenericFunctionInfo, Tuple{Int, CallTarget}}

What `@rust func_name(...)` called from `mod` reaches — **the one place that
decides it**, for every form: typed and untyped, generic and not, `lib::f`
qualified or not (#520). Returns the generic registration to specialize, or the
epoch sampled before resolving together with the resolved snapshot.

The order:

1. **The caller's own blocks.** For an unqualified call, every library a
   `rust\"\"\"` block of `mod` loaded, **most recently recorded first**; for
   `lib::f`, that library alone (and, with `mod === nothing` — the entry points
   that take a library name — just `lib_name`). A block defines `func_name`
   either as a function its library exports — asked of that library alone,
   `resolve_call_target(...; fallback = false)` — or as a generic it
   registered (`GENERIC_FUNCTIONS_BY_LIB`), and each block is asked about
   **both kinds together**: the first block that defines the name answers,
   with whichever kind it defines. So a later block redefines a name for its
   module — a function or a generic, over a function or a generic — as the
   module's active block always did for functions; one block cannot define
   both (`_check_julia_name_clashes`).
2. **The documented fallback** (`docs/src/generics.md`), only when none of the
   caller's own blocks defines the name: a generic registered process-wide
   under the bare name (`register_generic_function`, or another module's
   block), then any other loaded library that exports it — the cross-block
   call, which refuses two different libraries exporting it.

The typed path used to try the symbol tables first and the generic registry
only on failure, and the untyped path the other way round, both through a
process-wide registry: an unrelated block's plain `f` shadowed a module's own
generic `f` under `::T`, and that generic captured another module's untyped
`@rust f(x)` (#520).

`_resolve_lib` runs **first**, outside anything that could mistake its failure
for a missing name: it replays a precompiled caller's recorded blocks, which is
what registers that module's generics at all, and a block that fails to load
must say so (#390 review). The epoch is sampled after it — restoring loads,
and a load is a state write — and **before** anything is resolved, so a write
landing in between leaves a published entry stale rather than current (#253).
A caller that verifies the snapshot (`::T`) does so before publishing it.
"""
@noinline function resolve_rust_call(mod::Union{Module, Nothing}, lib_name::String,
                                     func_name::String)
    # One attempt per restore; an attempt that finds one of the caller's own
    # blocks unloaded after its restore cannot know whether that block defines
    # the name, and is retried rather than answered by the fallback (#522).
    return _resolve_own_definition() do
        resolved, own, blocks = if mod === nothing
            lib_name, String[lib_name], String[]
        else
            restored = _resolve_lib(mod, lib_name)
            blocks = _module_block_libraries(mod)
            restored, isempty(lib_name) ? blocks : String[restored], blocks
        end
        _resolution_seam(:restored)
        epoch = artifact_epoch()

        for lib in own
            # A generic row first only because it is a table read; one block
            # never defines a function and a generic of one Julia name.
            generic = get(GENERIC_FUNCTIONS_BY_LIB, (lib, func_name), nothing)
            generic === nothing || return generic
            target = resolve_call_target(lib, func_name; fallback = false)
            target === nothing || return (epoch, target)
            # A library's rows are installed and dropped with the library in
            # one transaction, so a loaded block that answered nothing does
            # not define the name. An unloaded one may: it was unloaded after
            # the restore above, and what it defines is unknown until it is
            # restored again.
            lib in blocks && !_library_loaded(lib) &&
                return _OwnDefinitionVanished("`$func_name` in library '$lib'")
        end

        generic = get(GENERIC_FUNCTION_REGISTRY, func_name, nothing)
        generic === nothing || return generic
        return (epoch, resolve_call_target(resolved, func_name))
    end
end

"""
    _OwnDefinitionVanished(what)

What one attempt of `_resolve_own_definition` returns when the caller's own
defining library went away between restoring it and reading its rows: the
answer is unknown, and nothing process-wide may stand in for it (#522).
"""
struct _OwnDefinitionVanished
    what::String
end

# How many times `_resolve_own_definition` restores before it gives up. A
# library disappears only while an unload races the resolution; the restore
# that follows registers it again.
const _OWN_DEFINITION_ATTEMPTS = 3

"""
    _resolve_own_definition(attempt) -> result

Run `attempt()` — which restores the caller's blocks and reads their rows —
until it returns something other than `_OwnDefinitionVanished`, at most
`_OWN_DEFINITION_ATTEMPTS` times, then raise a `RustError` naming what
vanished. The one rule for both lookups by owner (#522): `resolve_rust_call`
(a name the caller's own block may define) and `_generic_struct_snapshot` (a
member of the block that emitted a struct). Once the caller's own definition
is in question, the process-wide registration is never consulted for that
call — it may be another module's definition of the same name.
"""
function _resolve_own_definition(attempt)
    last = nothing
    for _ in 1:_OWN_DEFINITION_ATTEMPTS
        result = attempt()
        result isa _OwnDefinitionVanished || return result
        last = result
        yield()
    end
    throw(RustError("$(last.what) is not registered: its defining block's library was " *
                    "unloaded or replaced while it was being resolved, and restoring it did " *
                    "not register it again"))
end

# Whether `lib` is loaded now.
_library_loaded(lib::String) = lock(REGISTRY_LOCK) do
    haskey(RUST_LIBRARIES, lib)
end

# Test seam: called with a stage from `resolve_rust_call`, outside STATE —
# `:restored` right after the caller's blocks are restored and before anything
# is resolved, so a test can unload a library in exactly that window (#522).
# Task local, like `_AFTER_MANIFEST_REGISTRATION`: no other task can install one.
const _AFTER_RUST_RESOLUTION_RESTORE = :rustcall_after_rust_resolution_restore

function _resolution_seam(stage::Symbol)
    hook = get(task_local_storage(), _AFTER_RUST_RESOLUTION_RESTORE, nothing)
    hook === nothing || hook(stage)
    return nothing
end

# The libraries `mod`'s own `rust"""` blocks loaded, after `_resolve_lib` has
# restored them, the most recently recorded first. A block with no recorded
# order (a legacy caller's) sorts last, by name, so the order never depends on
# hashing.
#
# The names and their order are read in **one** transaction, as
# `_rebind_module_block!` writes them: two reads could straddle a rebind and
# pair the old key with the new order, ranking the newest block last (#520
# review).
function _module_block_libraries(mod::Module)
    snapshot = _module_block_snapshot(mod)
    snapshot === nothing || return snapshot
    libs = _module_binding(mod, :__RUSTCALL_LIBS)
    libs === nothing && return String[]
    return sort!(String[String(first(entry)) for entry in collect(libs)])
end

"""
    _call_and_guard(func_ptr, R, channel, func_name, args...)

Make the call and read its channel, with the return type as a **type
parameter**.

`@rust f(a, b)` without an annotation learns its return type from the snapshot,
so that type is a runtime value and the call through it is a dynamic dispatch.
This is the barrier that keeps it to exactly one: everything inside is
specialised on `R` and on the argument arity, where calling `call_rust_function`
with a runtime `Type` left the whole chain behind it dynamic — the `@generated`
`_call_rust_function` reached by a specialisation lookup on every call (#253).

An annotated call (`::T`) and a `#[julia]` wrapper know their type statically and
do not come through here.
"""
@noinline function _call_and_guard(func_ptr::Ptr{Cvoid}, ::Type{R}, channel::Ptr{Cvoid},
                                   func_name::String, args::Vararg{Any, N}) where {R, N}
    return guard_rust_panic_ptr(call_rust_function(func_ptr, R, args...), channel, func_name)
end

"""
    _dispatch_with_target(target, lib_name, func_name, args...)

The half of `_rust_call_dynamic` that runs once a snapshot is in hand: pick the
return type the snapshot recorded, call, and read that snapshot's channel.

Shared with the cached call sites (#253), which reach the same snapshot without
re-resolving it, so the two cannot drift in what they do with one.
"""
function _dispatch_with_target(target, lib_name::String, func_name::String,
                               args::Vararg{Any, N}) where {N}
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
        return _call_and_guard(func_ptr, func_info.return_type, channel, func_name, args...)
    end

    # Try to get the return type the owning library registered — again, the one
    # captured in the snapshot.
    ret_type = target.return_type
    if ret_type !== nothing
        @debug "Using registered return type for $func_name: $ret_type"
        return _call_and_guard(func_ptr, ret_type, channel, func_name, args...)
    end

    # No last resort. Guessing the return type from the first argument was the
    # #245 / #246 shape: the guess is not derivable from an argument, and a
    # return slot read at the wrong width is undefined behaviour (#276). (The
    # LLVM IR inference that used to sit here read a module registry nothing
    # ever wrote to; it went with the LLVM path, #265.) Nothing is caught on
    # the way here: a fail-closed error from the FFI type contract — an
    # unregistered by-value aggregate (#245), an invalid-UTF-8 argument (#246)
    # — propagates as itself rather than as this message.
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
    # The same resolution order as every other `@rust` form (#520).
    resolution = resolve_rust_call(nothing, lib_name, func_name)
    resolution isa GenericFunctionInfo && return call_generic_function(resolution, args...)
    _, target = resolution
    return _call_resolved_typed(target, func_name, ret_type, args...)
end

"""
    _rust_call_symbol(lib_name, symbol, ret_type, args...)

Call the exported FFI symbol `symbol` — a generated wrapper such as
`rustcall_S_scale` — with the return type its generator spliced in.

Not a name `@rust` resolves: a generated wrapper already knows the exact symbol
it calls, so it never goes through `resolve_rust_call`, whose job is to decide
what a user-facing *name* means and which consults the generic registries
first. Routing wrappers through it let a generic free function whose Julia
name happened to equal a wrapper symbol (`fn rustcall_S_scale<T>` beside
`S::scale`) capture the method call (#520 review). The symbol is resolved as
the one snapshot `resolve_call_target` takes, starting at `lib_name`.
"""
function _rust_call_symbol(lib_name::String, symbol::String, ret_type::Type, args...)
    target = resolve_call_target(lib_name, symbol)
    return _call_resolved_typed(target, symbol, ret_type, args...)
end

# Call a resolved snapshot with a declared return type: the annotation check,
# then the call and its panic channel, all from that one snapshot.
function _call_resolved_typed(target, func_name::String, ret_type::Type, args...)
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
    _rust_call_dynamic_cached(cache, mod, lib_name, func_name, args...)

`@rust f(a, b)` with this call site's snapshot cache (#253).

The generic question stays on the slow path deliberately. A name
`resolve_rust_call` resolves to a generic is specialized and never populates the
cache — so a cache hit is by construction a name that already answered it with
"a function", and the per-call registry lookup is gone for everyone else. A
generic registered later is a state write, which moves the epoch and sends the
next call back through `resolve_rust_call`.
"""
function _rust_call_dynamic_cached(cache::CallTargetCache, mod::Module, lib_name::String,
                                   func_name::String, args::Vararg{Any, N}) where {N}
    hit = cached_target_hit(cache)
    hit === nothing || return _dispatch_with_target(hit, hit.lib_name, func_name, args...)
    # The one resolution order (#520). It restores a precompiled caller's
    # blocks first — they are what register the module's generics — and
    # samples the epoch before it resolves anything (#253, #390 review).
    resolution = resolve_rust_call(mod, lib_name, func_name)
    resolution isa GenericFunctionInfo && return call_generic_function(resolution, args...)
    epoch, target = resolution
    publish_call_target!(cache, epoch, target)
    return _dispatch_with_target(target, target.lib_name, func_name, args...)
end

"""
    _rust_call_typed_cached(cache, mod, lib_name, func_name, ret_type, args...)

`@rust f(a, b)::T` with this call site's snapshot cache (#253).
"""
# `args::Vararg{Any, N}) where {N}`, not `args...`: a plain vararg method gets one
# specialization shared by every arity, so the argument tuple stays abstract and
# the `ccall` behind `call_rust_function` is reached by dynamic dispatch — 590 ns
# and four allocations, against 10 ns once `N` makes the arity part of the
# signature. Every cached entry point below is annotated for that reason (#253).
function _rust_call_typed_cached(cache::CallTargetCache, mod::Module, lib_name::String,
                                 func_name::String, ::Type{R},
                                 args::Vararg{Any, N}) where {R, N}
    # `R` is part of the hit: the annotation is an expression, so one call site
    # can ask for a different type on each call while sharing this cache, and an
    # entry validated for another type would be read at the wrong width
    # (#245, #390 review).
    target = cached_target_hit(cache, R)
    target === nothing &&
        return _rust_call_typed_uncached(cache, mod, lib_name, func_name, R, args...)
    return guard_rust_panic_ptr(call_rust_function(target.func_ptr, R, args...),
                                target.channel, func_name)
end

# Out of line: the slow half of the typed call site, which runs only when the
# epoch moved or the annotation changed (#253).
@noinline function _rust_call_typed_uncached(cache::CallTargetCache, mod::Module,
                                             lib_name::String, func_name::String,
                                             ::Type{R},
                                             args::Vararg{Any, N}) where {R, N}
    # The same resolution order as the untyped form (#520): the caller's own
    # blocks — functions and generics together — then the documented fallback.
    # It restores a precompiled caller's blocks before resolving, outside
    # anything that could hide a block that fails to load (#390 review).
    resolution = resolve_rust_call(mod, lib_name, func_name)
    resolution isa GenericFunctionInfo && return call_generic_function(resolution, args...)
    epoch, target = resolution
    # Checked here rather than on the fast path, and **before** publishing.
    #
    # Both inputs are fixed for as long as the entry lives — the snapshot is the
    # one just resolved, and `R` is this call site's annotation, spliced in by
    # the macro — so checking once per snapshot is checking every call, and a
    # new snapshot is a new check. It cost 550 ns per call where it stood,
    # because comparing two runtime `Type` values through `ccall_return_type`
    # is a dynamic call and the annotation check makes two of them.
    #
    # Publishing only after it passes is what keeps that true: an entry that
    # failed the check must not be left behind for later calls to hit, which
    # would skip the check for the rest of the session (#245, #253).
    _check_return_annotation(target, func_name, R)
    publish_call_target!(cache, epoch, target, R)
    return guard_rust_panic_ptr(call_rust_function(target.func_ptr, R, args...),
                                target.channel, func_name)
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
