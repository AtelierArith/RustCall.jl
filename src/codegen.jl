# Code generation for Rust function calls

"""
    FunctionInfo

Information about a registered Rust function.
"""
struct FunctionInfo
    name::String
    lib_name::String
    return_type::Type
    arg_types::Vector{Type}
    func_ptr::Ptr{Cvoid}
    # String ABI of a monomorphized `#[julia]` function (#242): `arg_abis` is
    # the manifest `abi` per argument ("string" / "str" arguments travel as
    # `(ptr, len)` pairs), `string_return` is `:none`, `:owned` (released
    # through `free_ptr`) or `:borrowed`.
    arg_abis::Vector{String}
    string_return::Symbol
    free_ptr::Ptr{Cvoid}
    # The panic channel of the wrapper `func_ptr` points at, resolved when this
    # record was built (#244, #277). A cached `FunctionInfo` is a snapshot: it
    # outlives the lookup that produced it, so looking the channel up later by
    # library name could find no library — the pointer still enters the mapped
    # retired image — and a panic would then be read as a successful zero.
    channel::Ptr{Cvoid}
    # The image the pointers were resolved on, and which generation of
    # `lib_name` it was. The handle is what finds the *right* liveness flag
    # later (`alive_ref_for_handle`): the name's flag may by then belong to a
    # different image, or be freshly invented for a name nothing is registered
    # under.
    handle::Ptr{Cvoid}
    generation::Int
end

FunctionInfo(name::String, lib_name::String, return_type::Type, arg_types::Vector{Type}, func_ptr::Ptr{Cvoid}) =
    FunctionInfo(name, lib_name, return_type, arg_types, func_ptr, String[], :none, C_NULL,
                 C_NULL, C_NULL, 0)

FunctionInfo(name::String, lib_name::String, return_type::Type, arg_types::Vector{Type},
             func_ptr::Ptr{Cvoid}, arg_abis::Vector{String}, string_return::Symbol,
             free_ptr::Ptr{Cvoid}) =
    FunctionInfo(name, lib_name, return_type, arg_types, func_ptr, arg_abis, string_return,
                 free_ptr, C_NULL, C_NULL, 0)

"""
Registry for function information.
Maps function name to FunctionInfo.
"""
const FUNCTION_REGISTRY = _state_view(:function_registry, Dict{String, FunctionInfo}())

"""
Library-scoped registry for function information.
Maps (library name, function name) to FunctionInfo.
"""
const FUNCTION_REGISTRY_BY_LIB = _state_view(:function_registry_by_lib,
    Dict{Tuple{String, String}, FunctionInfo}())

"""
Registry for function return types (for functions without full signature
registration), keyed by `(library name, function name)`.

There is deliberately **no** name-only fallback table, and no cross-library
search. A name-keyed hint outlives the library that wrote it: clearing or
reloading that library would leave its return type answering for every other
library's function of the same name, and a rebuilt library that no longer
declares the function that way would be typed by the stale value (#279).
Lookups go through the library `_resolve_call` took the pointer from, so a
call's pointer and its ABI always come from the same build.

Guarded by `REGISTRY_LOCK`.
"""
const FUNCTION_RETURN_TYPES_BY_LIB = _state_view(:function_return_types_by_lib,
    Dict{Tuple{String, String}, Type}())

"""
Rust item name to exported C symbol, keyed by `(library name, Rust name)`.

`#[julia]` is additive since #279: the annotated function keeps its own name
and the library exports the wrapper `rustcall_<name>` next to it. `@rust
add(1, 2)` names the *Rust function*, so the lookup has to go through this
mapping, which is filled from the manifest (`Function.symbol`) — never by
string surgery on the name.

The mapping is strictly **per library**, and identity mappings are recorded
too. One library exporting `#[julia] fn f` as `rustcall_f` must not decide how
`f` resolves in another library that exports a plain `#[no_mangle] fn f` under
its own name; a library with no entry for a name resolves it to the name
itself. Entries are dropped with the library (`clear_library_metadata!`), so an
unloaded library cannot leave a stale mapping behind.

Guarded by `REGISTRY_LOCK`.
"""
const FUNCTION_SYMBOLS_BY_LIB = _state_view(:function_symbols_by_lib,
    Dict{Tuple{String, String}, String}())

"""
    register_function_symbol(lib_name, name, symbol)

Record that the Rust item `name` of `lib_name` is exported as `symbol`.
Identity mappings are recorded as well: a plain `#[no_mangle] extern "C" fn f`
is explicitly `f => f` for its own library, which is what keeps another
library's `f => rustcall_f` from leaking into it.
"""
function register_function_symbol(lib_name::AbstractString, name::AbstractString,
                                  symbol::AbstractString)
    isempty(symbol) && return nothing
    key, exported = (String(lib_name), String(name)), String(symbol)
    lock(REGISTRY_LOCK) do
        FUNCTION_SYMBOLS_BY_LIB[key] = exported
    end
    return nothing
end

"""
    exported_symbol(lib_name, name) -> String

The exported C symbol of the Rust item `name` **in `lib_name`**, or `name`
itself when that library recorded nothing for it (a library loaded outside the
manifest pipeline, or a `name` that is already the exported symbol). Never
consults another library's mapping.
"""
function exported_symbol(lib_name::AbstractString, name::AbstractString)
    lib, item = String(lib_name), String(name)
    lock(REGISTRY_LOCK) do
        get(FUNCTION_SYMBOLS_BY_LIB, (lib, item), item)
    end
end

"""
    clear_library_metadata!(lib_name)

Drop everything the registries record *about* one library: its name-to-symbol
mappings, its return-type hints, its panic channels and the generic functions
its block defined (`GENERIC_FUNCTIONS_BY_LIB`).

Called wherever a library leaves `RUST_LIBRARIES` or is replaced under the same
name (unload, hot reload, re-registration of a `rust\"\"\"` block). A stale
mapping would redirect a later lookup to a symbol that is no longer loaded, and
a stale hint would type a call to a function the rebuilt library no longer
declares that way — so the two must go together, in the same transaction that
removes the handle (#279).

Both registries are keyed by library, so dropping a library's rows is all there
is to it: nothing it recorded can outlive it under a name-only key.
"""
function clear_library_metadata!(lib_name::AbstractString)
    name = String(lib_name)
    lock(REGISTRY_LOCK) do
        for key in collect(keys(FUNCTION_SYMBOLS_BY_LIB))
            first(key) == name && delete!(FUNCTION_SYMBOLS_BY_LIB, key)
        end
        for key in collect(keys(FUNCTION_RETURN_TYPES_BY_LIB))
            first(key) == name && delete!(FUNCTION_RETURN_TYPES_BY_LIB, key)
        end
        # A panic-channel pointer points *into the image*. A library replaced
        # under the same name — a re-run block, a hot reload — is a different
        # image, so the pointer must be resolved again rather than called into
        # the one that was closed (#244).
        for key in collect(keys(PANIC_CHANNELS))
            first(key) == name && delete!(PANIC_CHANNELS, key)
        end
        # The generic functions the library's block defined (#520): a rebuilt
        # block registers its own again after loading, and a row left behind
        # would let a call from the defining module specialize a source the
        # library no longer holds.
        for key in collect(keys(GENERIC_FUNCTIONS_BY_LIB))
            first(key) == name && delete!(GENERIC_FUNCTIONS_BY_LIB, key)
        end
    end
    return nothing
end

"""
    CallTarget

Everything one FFI call needs, taken from **one generation** of a library.

# Why this is a struct and not three lookups

A library can be replaced between any two lookups — that is what a hot reload
is — and the pieces of a call belong to *different generations* if they are
resolved separately. Resolving the function pointer, then the panic channel by
`(library name, symbol)`, meant a call could enter the retired image and read
the replacement's channel: the panic it raised would be invisible, and a panic
the *new* image left there would be reported against a call that never made it.
The same split applied to a struct's destructor and its liveness flag, and to
an owned-`String` result whose release function was resolved after the wrapper
had already returned.

So every entry point takes one snapshot under one lock and uses only that. The
rule for the whole package: **nothing after the snapshot may look anything up
by library name.**

# Fields

- `func_ptr` — the wrapper to call.
- `channel` — that wrapper's panic channel (`C_NULL` when it has none).
- `free_ptr` — the release function for an owned-`String` result, when the
  caller asked for one (`C_NULL` otherwise).
- `alive` — the liveness flag of that image. A **constructor** needs it: the
  object it returns was allocated by this generation, so it must capture this
  generation's destructor and this generation's flag, not whatever the library
  name resolves to after the call returns.
- `handle` — the image they were resolved on. What finds the right liveness
  flag later, when the library's *name* may have moved on.
- `lib_name` — the library the pointers came from, for diagnostics.
- `return_type` — the return-type hint that library registered for this
  function (`nothing` when it registered none), and `func_info` — the richer
  `FunctionInfo` when one is registered. **Both are part of the snapshot**: the
  return ABI decides how the `ccall` reads the return slot, so taking it from a
  later lookup could call a pointer from the retired generation while reading
  its result with the replacement's ABI — a scalar read as a struct, which is
  memory corruption rather than a wrong answer.
- `generation` — which generation of `lib_name` all of the above came from.
- `free_channel` — the release/destructor's panic channel from that same image,
  captured before allocation so an object's finalizer never resolves it later.
"""
struct CallTarget
    func_ptr::Ptr{Cvoid}
    channel::Ptr{Cvoid}
    free_ptr::Ptr{Cvoid}
    alive::Base.RefValue{Bool}
    handle::Ptr{Cvoid}
    lib_name::String
    return_type::Union{Type, Nothing}
    func_info::Union{FunctionInfo, Nothing}
    generation::Int
    free_channel::Ptr{Cvoid}
end

CallTarget(func_ptr, channel, free_ptr, alive, handle, lib_name, return_type, func_info, generation) =
    CallTarget(func_ptr, channel, free_ptr, alive, handle, lib_name, return_type, func_info,
               generation, C_NULL)

"""
    ArtifactGeneration

The per-object half of a snapshot: what a `#[julia]` struct captures at
construction so its finalizer needs no lookup at all (#249).

`free_ptr`, `free_channel` and `alive` must come from **one** generation: taken separately, an
object could capture the destructor of the image it was allocated by and the
liveness flag of the image that replaced it, and would then either skip a free
it should have made or make one into an image that had been closed.
"""
struct ArtifactGeneration
    handle::Ptr{Cvoid}
    free_ptr::Ptr{Cvoid}
    alive::Base.RefValue{Bool}
    generation::Int
    free_channel::Ptr{Cvoid}
end

ArtifactGeneration(handle, free_ptr, alive, generation) =
    ArtifactGeneration(handle, free_ptr, alive, generation, C_NULL)

"""
    PANIC_CHANNELS

`(library name, wrapper symbol)` → the pointer to that wrapper's panic-channel
reader, or `C_NULL` when the library exports none.

A `#[julia]` wrapper catches the panic, records the message in a thread-local
slot and exports `<symbol>_take_panic` to read it (#244). This is the legacy,
name-keyed memo of that lookup, written only by `panic_channel_pointer` (which
records the negative answer too: an artifact built before #244, or a raw
`#[no_mangle]` function, has no channel and is not probed again). No generated
call site uses it any more: a call resolves its channel inside its generation
snapshot (`resolve_call_target`), which reads this memo first and otherwise the
image's own pointer cache, so a channel always comes from the image the call
captured.

Entries are dropped with their library (`purge_library_state!`), so a reloaded
library re-resolves against the image that is actually mapped rather than
calling a pointer into a `dlclose`d one.

A `StateView` into `STATE`: every access takes the state lock (`REGISTRY_LOCK`).
"""
const PANIC_CHANNELS = _state_view(:panic_channels,
    Dict{Tuple{String, String}, Ptr{Cvoid}}())

# Buffer for one panic message. Panic text is short; a message longer than this
# is fetched again with an exact-size buffer (the channel keeps it until it has
# been read whole).
const _PANIC_BUFFER_BYTES = 4096

"""
    panic_channel_pointer(lib_name, symbol) -> Ptr{Cvoid}

The panic-channel reader of `symbol` in `lib_name`, resolved once and cached
(`C_NULL` when the library has none).
"""
function panic_channel_pointer(lib_name::AbstractString, symbol::AbstractString)
    lib = String(lib_name)
    sym = String(symbol)
    cached, entry = lock(REGISTRY_LOCK) do
        (get(PANIC_CHANNELS, (lib, sym), nothing), get(RUST_LIBRARIES, lib, nothing))
    end
    cached === nothing || return cached
    ptr = C_NULL
    if entry !== nothing
        found = Libdl.dlsym(entry[1], ffi_panic_symbol(sym); throw_error = false)
        (found === nothing || found == C_NULL) || (ptr = found)
    end
    lock(REGISTRY_LOCK) do
        # Compare only for cache publication. The answer always belongs to
        # the image captured above, never to a replacement found by this check.
        if get(RUST_LIBRARIES, lib, nothing) === entry
            PANIC_CHANNELS[(lib, sym)] = ptr
        end
    end
    return ptr
end

"""
    take_rust_panic(channel::Ptr{Cvoid}) -> Union{String, Nothing}

Read and clear the pending panic message of one wrapper, or `nothing` when it
did not panic.

Two `ccall`s at most, and **the first one allocates nothing**: passing a null
buffer asks the channel for the length only, which it reports without clearing
the slot. That matters because the answer is almost always "no panic", and
because the probe has to happen with nothing at all between it and the wrapper
call that preceded it — see `guard_rust_panic_ptr`.

The second call, made only when there *is* a message, passes a buffer of
exactly the length the channel reported and clears the slot.
"""
function take_rust_panic(channel::Ptr{Cvoid})
    channel == C_NULL && return nothing
    len = ccall(channel, Csize_t, (Ptr{UInt8}, Csize_t), C_NULL, 0)
    len == 0 && return nothing
    return _fetch_rust_panic(channel, Int(len))
end

# Separate function so the allocation is out of line: `take_rust_panic` stays
# small enough to inline as one `ccall` plus a branch on the common path.
@noinline function _fetch_rust_panic(channel::Ptr{Cvoid}, len::Int)
    buffer = Vector{UInt8}(undef, len)
    got = ccall(channel, Csize_t, (Ptr{UInt8}, Csize_t), buffer, length(buffer))
    # The slot was emptied between the probe and the fetch. That should not
    # happen — nothing between them yields, so the task cannot have moved off
    # this thread — but reporting the panic without its text beats reporting no
    # panic at all.
    got == 0 && return "the Rust function panicked (message unavailable)"
    return String(@view buffer[1:min(Int(got), len)])
end

# ============================================================================
# Callbacks: a Julia function handed to Rust as `extern "C" fn` (#296)
# ============================================================================

"""
    CallbackTrampoline{R}(f)

The callable a generated wrapper wraps a user's function in (#296): it calls
`f`, converts the result to the C slot type `R` (`nothing` for `Cvoid`), and
**never lets a Julia exception escape** — the frames below it are Rust's, and
unwinding through them is undefined behaviour. An exception is stored for the
task (`_store_callback_error!`) and a zero of `R` is returned as a sentinel;
the wrapper that made the call re-raises the exception once the Rust call has
returned (`guard_rust_panic_ptr`). Only the first exception of a call is kept.

# How a Julia function becomes a C function pointer without a closure

`@cfunction(\$f, ...)` — a closure trampoline — is not available on every
platform Julia runs on (aarch64 raises `cfunction: closures are not supported
on this platform`), so no generated wrapper uses one. Instead the wrapper
pushes a `CallbackFrame` holding the call's trampolines onto a **task-local
stack** for the duration of the call, and passes Rust a constant pointer to
one of the plain slot functions `_callback_slot_1` … `_callback_slot_N`
(`CALLBACK_SLOTS`), each compiled by `@cfunction` for the exact slot types of
that argument. Slot `k` calls the `k`-th trampoline of the frame on top of the
stack. Nested calls push their own frames and pop them on return, so the top
is always the innermost call in progress — which is the one Rust is running
right now, because a callback may only be invoked while the call that passed
it is on the stack (synchronous borrow) and on the thread that made the call.
"""
struct CallbackTrampoline{R, F}
    f::F
end
CallbackTrampoline{R}(f::F) where {R, F} = CallbackTrampoline{R, F}(f)

function (t::CallbackTrampoline{R})(args...) where {R}
    try
        v = t.f(args...)
        return R === Cvoid ? nothing : convert(R, v)::R
    catch e
        _store_callback_error!(e, catch_backtrace())
        return _callback_zero(R)
    end
end

# The value a callback slot returns to Rust when the Julia side failed: the
# exception is stored and re-raised after the call, and Rust gets a harmless
# zero of the slot type. `zero(Ptr{T})` has no method, so a raw-pointer slot
# gets `C_NULL` — raising here would unwind through the Rust frames (#460).
_callback_zero(::Type{Cvoid}) = nothing
_callback_zero(::Type{R}) where {R <: Ptr} = R(C_NULL)
_callback_zero(::Type{R}) where {R} = zero(R)

"""
    CallbackFrame

The trampolines of one call in progress, slot by slot; see
`CallbackTrampoline`. Pushed by the wrapper before the call
(`_push_callback_frame!`), popped in its `finally` (`_pop_callback_frame!`).
"""
struct CallbackFrame
    trampolines::Vector{Any}
end

const _CALLBACK_FRAMES_KEY = :__rustcall_callback_frames

"""
    CALLBACK_SLOTS

How many callback arguments one `#[julia]` function or method may take: one
plain slot function exists per position, and a wrapper with more callback
parameters than this is refused at generation.
"""
const CALLBACK_SLOTS = 8

function _callback_frames()
    tls = task_local_storage()
    stack = get(tls, _CALLBACK_FRAMES_KEY, nothing)
    stack === nothing || return stack::Vector{CallbackFrame}
    fresh = CallbackFrame[]
    tls[_CALLBACK_FRAMES_KEY] = fresh
    return fresh
end

function _push_callback_frame!(trampolines...)
    frame = CallbackFrame(Any[trampolines...])
    push!(_callback_frames(), frame)
    return frame
end

# Pops `frame` — normally the top; by identity otherwise, so a frame can never
# be left behind or a neighbour's taken by mistake.
function _pop_callback_frame!(frame::CallbackFrame)
    stack = _callback_frames()
    if !isempty(stack) && stack[end] === frame
        pop!(stack)
    else
        i = findlast(f -> f === frame, stack)
        i === nothing || deleteat!(stack, i)
    end
    return nothing
end

# The trampoline Rust is calling: slot `k` of the innermost call in progress,
# or `nothing` when there is none — no frame at all (the call that passed the
# pointer has returned, or the pointer was called from another task), or a top
# frame with fewer than `k` callbacks. Never raises: it runs inside a
# `@cfunction`, and an exception there would unwind through Rust (#460).
function _callback_trampoline(k::Int)
    stack = _callback_frames()
    isempty(stack) && return nothing
    trampolines = stack[end].trampolines
    return checkbounds(Bool, trampolines, k) ? trampolines[k] : nothing
end

"""
    CallbackSlot{K, R}

The function Rust calls for callback argument `K` whose C return type is `R`:
a singleton, so `@cfunction(CallbackSlot{K, R}(), R, (...))` is a constant
pointer with no closure (#296). It looks up the `K`-th trampoline of the
innermost call in progress and calls it; the trampoline converts the result
and catches every exception.

Nothing may raise out of it, because it runs on a Rust stack. When no
trampoline is there to call (see `_callback_trampoline`), or the trampoline's
result is not an `R` (a frame from another call on top), the failure is
recorded exactly like an exception a callback threw — re-raised by the guard
after the next Rust call on this task — and Rust gets `_callback_zero(R)`
(#460). The return type is a parameter rather than a lookup for exactly this
reason: the fallback value has to have the slot's type.
"""
struct CallbackSlot{K, R} end

function (::CallbackSlot{K, R})(args...) where {K, R}
    try
        t = _callback_trampoline(K)
        if t === nothing
            _store_callback_error!(RustError(
                "a callback (slot $(K)) was invoked with no call in progress that passed it — " *
                "after the Rust call returned, or from another task or thread (#296, #460)"),
                backtrace())
            return _callback_zero(R)
        end
        v = t(args...)
        v isa R && return v
        R === Cvoid && return nothing
        _store_callback_error!(RustError(
            "a callback (slot $(K)) returned a `$(typeof(v))` where its C signature " *
            "returns `$(R)` (#460)"), backtrace())
        return _callback_zero(R)
    catch e
        _store_callback_error!(e, catch_backtrace())
        return _callback_zero(R)
    end
end

# The slot functions bindings files of format <= 11 name
# (`RustCall._callback_slot_k`). They do not know their return type, so they
# can only return `nothing` when there is no trampoline to call — correct for
# a `Cvoid` callback; regenerate such a file to get `CallbackSlot` (#460).
for k in 1:CALLBACK_SLOTS
    name = Symbol("_callback_slot_", k)
    @eval function $name(args...)
        t = _callback_trampoline($k)
        if t === nothing
            _store_callback_error!(RustError(
                "a callback (slot $($k)) was invoked with no call in progress that passed it (#296)"),
                backtrace())
            return nothing
        end
        return t(args...)
    end
end

# How many tasks currently hold a stored callback exception. The guard on
# every FFI return reads this atomic first, so the hot path pays one load and
# consults task-local storage only when some callback has actually failed.
const _CALLBACK_ERRORS_PENDING = Threads.Atomic{Int}(0)
const _CALLBACK_ERROR_KEY = :__rustcall_callback_error

# Task-local, because a callback runs on the task that made the Rust call and
# the exception belongs to that call: two tasks driving callbacks at once
# each get their own.
function _store_callback_error!(e, bt)
    tls = task_local_storage()
    haskey(tls, _CALLBACK_ERROR_KEY) && return nothing   # the first one wins
    tls[_CALLBACK_ERROR_KEY] = (e, bt)
    Threads.atomic_add!(_CALLBACK_ERRORS_PENDING, 1)
    return nothing
end

function _take_callback_error()
    tls = task_local_storage()
    haskey(tls, _CALLBACK_ERROR_KEY) || return nothing
    stored = pop!(tls, _CALLBACK_ERROR_KEY)
    Threads.atomic_sub!(_CALLBACK_ERRORS_PENDING, 1)
    return stored
end

# Re-raise the exception a callback stored during the call that just
# returned, after draining a panic the Rust side may have raised on the
# sentinel the callback returned — the exception is the root cause, and a
# message left in the thread-local channel would be charged to the next call.
#
# `value` is what the call returned. When Rust did *not* panic it returned a
# real value — it ran on the callback's sentinel to completion — and an owned
# buffer in it (a `String`, or the active `String` payload of a
# `Result` / `Option` aggregate) is released through `free_ptr` before the
# exception is raised; otherwise it would leak (#460). When Rust panicked the
# value is the panic sentinel: an empty buffer, or an aggregate whose payload
# is uninitialized, which must not be touched.
function _rethrow_callback_error!(channel::Ptr{Cvoid}, value = nothing,
                                  free_ptr::Ptr{Cvoid} = C_NULL)
    stored = _take_callback_error()
    stored === nothing && return nothing
    panicked = false
    if channel != C_NULL
        len = ccall(channel, Csize_t, (Ptr{UInt8}, Csize_t), C_NULL, 0)
        if len != 0
            panicked = true
            _fetch_rust_panic(channel, Int(len))
        end
    end
    panicked || _release_owned_return(value, free_ptr)
    throw(first(stored))
end

"""
    _release_owned_return(value, free_ptr)

Release the owned buffer a call returned and nobody will decode, because the
guard is about to raise (#460). A `CRustString` is freed through `free_ptr`;
a `Result` / `Option` aggregate (`is_ok` / `ok_value` / `err_value`, or
`is_some` / `value`) releases its **active** payload only — the inactive one is
zeroed on the Rust side and freeing it would be a double free. Anything else
owns nothing here.
"""
function _release_owned_return(raw::CRustString, free_ptr::Ptr{Cvoid})
    if raw.ptr != C_NULL && free_ptr != C_NULL
        ccall(free_ptr, Cvoid, (Ptr{UInt8}, UInt, UInt), raw.ptr, raw.len, raw.cap)
    end
    return nothing
end

# `CResultType` / `COptionType` and the `CResult_<fn>` / `COption_<fn>`
# mirrors a crate module declares have the same field names; `hasfield` on the
# concrete type folds at compile time.
function _release_owned_return(c, free_ptr::Ptr{Cvoid})
    free_ptr == C_NULL && return nothing
    T = typeof(c)
    if hasfield(T, :is_ok) && hasfield(T, :ok_value) && hasfield(T, :err_value)
        _release_owned_return(c.is_ok == 1 ? c.ok_value : c.err_value, free_ptr)
    elseif hasfield(T, :is_some) && hasfield(T, :value)
        c.is_some == 1 && _release_owned_return(c.value, free_ptr)
    end
    return nothing
end

"""
    guard_rust_panic_ptr(value, channel::Ptr{Cvoid}, func_name)

`value`, unless the wrapper whose channel is `channel` panicked — in which case
the sentinel `value` is discarded and `RustPanicError` is raised — or a
callback the call drove threw a Julia exception, which is re-raised here, as
itself, once the Rust frames are gone (#296).

# Why the channel is a pointer and not a `(library, symbol)` pair

The channel is a **thread-local** in the loaded image, so the wrapper call and
the channel read have to happen on the same OS thread. A Julia task moves
between threads only at a yield point, so the rule is that nothing between the
two may yield — and resolving the channel from a `Dict` under `REGISTRY_LOCK`
does yield when the lock is contended. That is exactly long enough for the task
to be rescheduled elsewhere, where it would read an empty slot and miss the
panic entirely, while a later task landing on the original thread would pick up
a message that does not belong to it.

So the resolution happens **before** the wrapper call, where yielding is
harmless — the channel is part of the call's generation snapshot — and this
function is what runs immediately after it: one `ccall` into a thread-local
read, no lock, no allocation, no logging. The shape every call site uses is

    target  = resolve_call_target(lib, name)       # may yield: before the call
    value   = call_rust_function(target.func_ptr, T, args...)  # cannot yield
    guard_rust_panic_ptr(value, target.channel, name)          # cannot yield

`C_NULL` means the artifact has no channel (built before #244, or a raw
`#[no_mangle]` function the user wrote), and the guard is then a no-op.
"""
function guard_rust_panic_ptr(value, channel::Ptr{Cvoid}, func_name::AbstractString,
                              free_ptr::Ptr{Cvoid} = C_NULL)
    # One atomic load on the common path; the task-local lookup only when a
    # callback somewhere has failed (#296). `free_ptr` releases an owned
    # buffer in `value` if that exception is raised instead (#460).
    _CALLBACK_ERRORS_PENDING[] == 0 || _rethrow_callback_error!(channel, value, free_ptr)
    channel == C_NULL && return value
    len = ccall(channel, Csize_t, (Ptr{UInt8}, Csize_t), C_NULL, 0)
    len == 0 && return value
    throw(RustPanicError(String(func_name), _fetch_rust_panic(channel, Int(len))))
end

"""
    check_rust_panic_ptr(channel::Ptr{Cvoid}, func_name)

`guard_rust_panic_ptr` for a call whose result is decoded separately — a
`CResult_*` / `COption_*` payload, or a string buffer. Same rule: the channel
must already be resolved, and nothing may run between the wrapper call and
this.
"""
check_rust_panic_ptr(channel::Ptr{Cvoid}, func_name::AbstractString) =
    (guard_rust_panic_ptr(nothing, channel, func_name); nothing)

# The form for a call that returned an owned buffer (a `CRustString`, or a
# `Result` / `Option` aggregate with a `String` payload) still to be decoded:
# if the guard raises a callback's exception instead, the buffer is released
# through `free_ptr` first rather than leaked (#460).
check_rust_panic_ptr(channel::Ptr{Cvoid}, func_name::AbstractString, value,
                     free_ptr::Ptr{Cvoid}) =
    (guard_rust_panic_ptr(value, channel, func_name, free_ptr); nothing)

# `G` is `GenericFunctionInfo`, which `src/generics.jl` defines after this file;
# `prepare_library_metadata` always builds a `Vector{GenericFunctionInfo}`, so
# the rows are concrete.
struct PreparedLibraryMetadata{G}
    symbols::Vector{Pair{String, String}}
    return_types::Vector{Pair{String, Type}}
    # The generic functions the library's block defines (#520), installed
    # under `(library, name)` in `GENERIC_FUNCTIONS_BY_LIB` and by bare name in
    # `GENERIC_FUNCTION_REGISTRY`.
    generics::Vector{G}
end

# Evaluate caller iterators and conversions before entering STATE. In
# particular, malformed metadata must not erase an existing registration.
function prepare_library_metadata(symbols, return_types, generics = ())
    prepared_symbols = Pair{String, String}[]
    prepared_types = Pair{String, Type}[]
    prepared_generics = GenericFunctionInfo[]
    for (name, symbol) in symbols
        push!(prepared_symbols, String(name) => String(symbol))
    end
    for (name, type) in return_types
        type isa Type || throw(ArgumentError("return metadata must contain Julia types"))
        push!(prepared_types, String(name) => type)
    end
    for info in generics
        info isa GenericFunctionInfo ||
            throw(ArgumentError("generic metadata must contain GenericFunctionInfo records"))
        push!(prepared_generics, info)
    end
    PreparedLibraryMetadata(prepared_symbols, prepared_types, prepared_generics)
end

"""
    install_library_metadata!(name, metadata::PreparedLibraryMetadata)

Replace a library's symbol mappings, return-type hints and generic functions
atomically. The caller must hold `REGISTRY_LOCK` and publish the handle in that
same transaction. Prepare caller-supplied iterators with
`prepare_library_metadata` outside the lock; this publication step accepts only
materialized rows.

The generics go in the same transaction as the rest (#520): clearing a
library's rows and publishing its generics in two steps left a window in which
a call from the defining module found the library without its own generic and
fell through to another module's generic of the same name.
"""
function install_library_metadata!(name::String, metadata::PreparedLibraryMetadata)
    clear_library_metadata!(name)
    for (rust_name, symbol) in metadata.symbols
        isempty(symbol) || (FUNCTION_SYMBOLS_BY_LIB[(name, rust_name)] = symbol)
    end
    for (key, ret_type) in metadata.return_types
        FUNCTION_RETURN_TYPES_BY_LIB[(name, key)] = ret_type
    end
    for info in metadata.generics
        GENERIC_FUNCTION_REGISTRY[info.name] = info
        GENERIC_FUNCTIONS_BY_LIB[(name, info.name)] = info
    end
    return nothing
end

"""
    purge_library_state!(lib_name)

Drop *every* registry row that belongs to `lib_name`: its symbol mappings and
return-type hints (`clear_library_metadata!`), its `FUNCTION_REGISTRY_BY_LIB`
entries, the `MONOMORPHIZED_FUNCTIONS` entries whose function pointers point
into it (stale pointers into an unloaded image are a use-after-free, #73) —
together with their `MONOMORPHIZATION_OWNERS` rows and the image's
`GENERIC_IMAGE_PATHS` record (#397) — and its `IRUST_FUNCTIONS` rows.

The caller must hold `REGISTRY_LOCK`. Called from `unload_artifact!`, which is
the only place a library leaves `RUST_LIBRARIES` (#277 Phase B).
"""
function purge_library_state!(lib_name::AbstractString)
    name = String(lib_name)
    clear_library_metadata!(name)
    for key in collect(keys(FUNCTION_REGISTRY_BY_LIB))
        first(key) == name && delete!(FUNCTION_REGISTRY_BY_LIB, key)
    end
    for (key, info) in collect(FUNCTION_REGISTRY)
        info.lib_name == name && delete!(FUNCTION_REGISTRY, key)
    end
    for (key, info) in collect(MONOMORPHIZED_FUNCTIONS)
        info.lib_name == name || continue
        delete!(MONOMORPHIZED_FUNCTIONS, key)
        # The instantiation's owner and its image's path go with the row, on
        # every path that removes one — `unload_library`, a hot reload, a
        # release — or a session that unloads generic images directly would
        # keep one tombstone per instantiation for its lifetime (#397 review).
        delete!(MONOMORPHIZATION_OWNERS, key)
    end
    delete!(GENERIC_IMAGE_PATHS, name)
    for (key, snippet) in collect(IRUST_FUNCTIONS)
        snippet.lib_name == name && delete!(IRUST_FUNCTIONS, key)
    end
    return nothing
end

"""
    copy_library_metadata!(from, to)

Give the library `to` the same name-to-symbol mappings, return-type hints and
owner-qualified generic registrations as `from`, replacing whatever it had.

Used when one loaded handle is registered under a second name (`@rust`'s reload
alias, `_alias_reloaded_library`): both registries are per library, so the alias
needs its own entries. Without the mappings a lookup through it would resolve
`f` to `f` and miss the `rustcall_f` the library actually exports; without the
hints an untyped `@rust f(...)` through the alias would fall back to the
unscoped table and pick up whatever *another* block last registered for that
name (#279).
"""
function copy_library_metadata!(from::AbstractString, to::AbstractString)
    source = String(from)
    target = String(to)
    source == target && return nothing
    lock(REGISTRY_LOCK) do
        clear_library_metadata!(target)
        for ((lib, name), symbol) in collect(FUNCTION_SYMBOLS_BY_LIB)
            lib == source && (FUNCTION_SYMBOLS_BY_LIB[(target, name)] = symbol)
        end
        for ((lib, name), ret_type) in collect(FUNCTION_RETURN_TYPES_BY_LIB)
            lib == source && (FUNCTION_RETURN_TYPES_BY_LIB[(target, name)] = ret_type)
        end
        for ((lib, name), generic) in collect(GENERIC_FUNCTIONS_BY_LIB)
            lib == source && (GENERIC_FUNCTIONS_BY_LIB[(target, name)] = generic)
        end
    end
    return nothing
end

"""
    register_function(name::String, lib_name::String, ret_type::Type, arg_types::Vector{Type})

Register a function with its type signature for later calling.
"""
function register_function(name::String, lib_name::String, ret_type::Type, arg_types::Vector{Type})
    # One snapshot: the record is cached and used long after this call, so it
    # carries the panic channel and the handle its pointer came from rather
    # than a name to look them up by later (#277).
    target = resolve_call_target(lib_name, name)
    info = FunctionInfo(name, target.lib_name, ret_type, arg_types, target.func_ptr,
                        String[], :none, C_NULL,
                        target.channel, target.handle, target.generation)
    FUNCTION_REGISTRY_BY_LIB[(lib_name, name)] = info
    FUNCTION_REGISTRY[name] = info
    return info
end

"""
    get_function_info(name::String) -> Union{FunctionInfo, Nothing}

Get the registered function info for a function name.
"""
function get_function_info(name::String)
    return get(FUNCTION_REGISTRY, name, nothing)
end

"""
    get_function_info(lib_name::String, name::String) -> Union{FunctionInfo, Nothing}

Get registered function info scoped to a library. Falls back to name-only registry
for backward compatibility.
"""
function get_function_info(lib_name::String, name::String)
    return get(FUNCTION_REGISTRY_BY_LIB, (lib_name, name), get(FUNCTION_REGISTRY, name, nothing))
end

"""
    get_function_return_type(lib_name::String, func_name::String) -> Union{Type, Nothing}

The return type `lib_name` itself registered for `func_name`, or `nothing`.

**Only that library's own entry is consulted.** No name-only fallback, and no
search of the other libraries: a hint must never describe a function in a
library other than the one the call actually reaches. `lib_name` here is the
*owning* library — the one `_resolve_call` took the pointer from — so the
pointer and the ABI it is called with always come from the same build.

Borrowing would be worse than having no hint: a library whose `f` returns
`Result<i32, i32>` deliberately records nothing (the wrapper returns a
`CResult_f` struct, and `@rust` callers must be explicit), so any hint found
elsewhere for the name `f` is not merely unrelated but the wrong ABI. Absent a
hint the caller infers from the arguments or demands an explicit `::T` (#279).
"""
function get_function_return_type(lib_name::String, func_name::String)
    lock(REGISTRY_LOCK) do
        get(FUNCTION_RETURN_TYPES_BY_LIB, (lib_name, func_name), nothing)
    end
end

"""
    julia_to_c_type(::Type{T}) -> Type

Convert a Julia type to its C-compatible equivalent for ccall.
Uses multiple dispatch for efficient type-specific conversions.
"""
# Default fallback for unknown types
julia_to_c_type(::Type{T}) where {T} = isbitstype(T) ? T : Ptr{Cvoid}

# Specific type conversions using multiple dispatch
julia_to_c_type(::Type{T}) where {T<:Integer} = T
julia_to_c_type(::Type{T}) where {T<:AbstractFloat} = T
julia_to_c_type(::Type{Bool}) = Bool
julia_to_c_type(::Type{T}) where {T<:Ptr} = Ptr{Cvoid}
julia_to_c_type(::Type{String}) = Cstring
julia_to_c_type(::Type{Cstring}) = Cstring
# `RustString` / `RustStr` deliberately have NO `Cstring` lowering: a Rust
# `String` is a `(ptr, len, cap)` buffer and a `&str` a `(ptr, len)` view,
# neither of which is a NUL-terminated C string. That coercion was the wrong
# shape #246 is about, and since #276 every string position is described by
# `ffi_return_contract` / `ffi_argument_contract` instead.
julia_to_c_type(::Type{T}) where {T<:AbstractString} = Cstring

# Helper functions for ccall type handling (using multiple dispatch)
# Note: Cvoid === Nothing in Julia, so we only define for Cvoid
ccall_return_type(::Type{Cvoid}) = Cvoid
ccall_return_type(::Type{Cstring}) = Cstring
ccall_return_type(::Type{String}) = Cstring
# Rust's bool type in C ABI is represented as UInt8 (1 byte)
ccall_return_type(::Type{Bool}) = UInt8
# Rust `char` is a Unicode scalar value in 4 bytes; Julia's `Char` stores UTF-8
# code units left-aligned, so the slot is a `UInt32` code point and the value is
# converted here rather than reinterpreted (#245). This is the single place the
# contract's slot-to-surface conversion happens: every return site asks
# `ffi_return_symbol_or_throw` for the SURFACE type and lands in this dispatch.
ccall_return_type(::Type{Char}) = UInt32
ccall_return_type(::Type{T}) where {T} = T

convert_return(::Type{Cvoid}, _) = nothing
convert_return(::Type{Cstring}, value) = cstring_to_julia_string(value)
convert_return(::Type{String}, value) = cstring_to_julia_string(value)
# Convert Rust bool (UInt8) to Julia Bool: 0 = false, non-zero = true
convert_return(::Type{Bool}, value::UInt8) = value != 0x00
convert_return(::Type{Bool}, value) = Bool(value != 0)
convert_return(::Type{Char}, value::Integer) = ffi_char_from_code_point(value)
convert_return(::Type{T}, value) where {T} = value

normalize_arg_type(::Type{R}, ::Type{T}) where {R,T} = T
normalize_arg_type(::Type{R}, ::Type{T}) where {R,T<:AbstractString} = String
normalize_arg_type(::Type{R}, ::Type{Cstring}) where {R} = Cstring
normalize_arg_type(::Type{R}, ::Type{T}) where {R,T<:Integer} = T  # Preserve integer types
normalize_arg_type(::Type{R}, ::Type{T}) where {R,T<:AbstractFloat} = T  # Preserve float types
normalize_arg_type(::Type{R}, ::Type{Ptr{T}}) where {R,T} = Ptr{T}  # Preserve pointer types
normalize_arg_type(::Type{R}, ::Type{Ref{T}}) where {R,T} = Ref{T}  # Preserve Ref types

# `@generated`, because this is pure type arithmetic on the hot path (#253).
#
# Every method of `normalize_arg_type` above dispatches on types alone and reads
# no runtime state, so the answer for a given `(R, A)` can never change within a
# session and belongs at compile time. Computing it per call cost 529 ns and
# three allocations — a hundred times the 5.1 ns `ccall` it was preparing.
#
# This is deliberately *not* what `ffi_check_by_value` does: that one consults
# layouts `register_ffi_struct` may add later in the session, so it stays a
# runtime check. The two look similar and are not.
@generated function normalize_arg_types(::Type{R}, ::Type{A}) where {R, A <: Tuple}
    normalized = map(t -> normalize_arg_type(R, t), A.parameters)
    return :($(Core.apply_type(Tuple, normalized...)))
end

is_supported_arg_type(::Type{T}) where {T<:Integer} = true
is_supported_arg_type(::Type{T}) where {T<:AbstractFloat} = true
is_supported_arg_type(::Type{Bool}) = true
is_supported_arg_type(::Type{T}) where {T<:Ptr} = true
is_supported_arg_type(::Type{T}) where {T<:Ref} = true
is_supported_arg_type(::Type{T}) where {T<:AbstractString} = true
is_supported_arg_type(::Type{Cstring}) = true
is_supported_arg_type(::Type{Char}) = true
is_supported_arg_type(::Type{T}) where {T} = isbitstype(T)

is_supported_return_type(::Type{T}) where {T<:Integer} = true
is_supported_return_type(::Type{T}) where {T<:AbstractFloat} = true
is_supported_return_type(::Type{Bool}) = true
is_supported_return_type(::Type{Cvoid}) = true  # Note: Cvoid === Nothing
is_supported_return_type(::Type{String}) = true
is_supported_return_type(::Type{Cstring}) = true
is_supported_return_type(::Type{T}) where {T<:Ptr} = true
is_supported_return_type(::Type{Char}) = true
is_supported_return_type(::Type{T}) where {T} = isbitstype(T)

ccall_arg_type(::Type{T}) where {T<:AbstractString} = Cstring
ccall_arg_type(::Type{Cstring}) = Cstring
ccall_arg_type(::Type{T}) where {T<:Integer} = T
ccall_arg_type(::Type{T}) where {T<:AbstractFloat} = T
ccall_arg_type(::Type{Bool}) = Bool
ccall_arg_type(::Type{Char}) = UInt32
ccall_arg_type(::Type{Ptr{T}}) where {T} = Ptr{T}
ccall_arg_type(::Type{Ref{T}}) where {T} = Ref{T}
ccall_arg_type(::Type{T}) where {T} = T # Pass structs by value

convert_arg(::Type{T}, x) where {T<:AbstractString} = julia_string_to_cstring(String(x))
convert_arg(::Type{Cstring}, x) = x
convert_arg(::Type{T}, x) where {T<:Integer} = convert(T, x)
convert_arg(::Type{T}, x) where {T<:AbstractFloat} = convert(T, x)
convert_arg(::Type{Bool}, x) = Bool(x)
convert_arg(::Type{Char}, x) = ffi_char_code_point(x)
convert_arg(::Type{Ptr{T}}, x) where {T} = convert(Ptr{T}, x)
convert_arg(::Type{Ref{T}}, x) where {T} = convert(Ref{T}, x)
convert_arg(::Type{T}, x) where {T} = x

@generated function _call_rust_function(func_ptr::Ptr{Cvoid}, ::Type{R}, ::Type{A}, args...) where {R,A<:Tuple}
    if !is_supported_return_type(R)
        return :(error("Unsupported return type ($($(QuoteNode(R)))). Use @rust_ccall for custom types."))
    end
    arg_types = A.parameters
    for T in arg_types
        if !is_supported_arg_type(T)
            return :(error("Unsupported argument type ($($(QuoteNode(T)))). Use @rust_ccall for custom types."))
        end
    end
    ret_ccall = ccall_return_type(R)
    ccall_arg_types = map(ccall_arg_type, arg_types)
    arg_exprs = Any[]
    for (i, T) in enumerate(arg_types)
        push!(arg_exprs, :(convert_arg($T, args[$i])))
    end
    ccall_expr = Expr(:call, :ccall, :func_ptr, ret_ccall, Expr(:tuple, ccall_arg_types...), arg_exprs...)
    # Every return type whose C slot differs from its Julia surface type is
    # converted here, once, rather than at each generated call site.
    if R == String || R == Cstring || R == Bool || R == Char
        return :(convert_return($R, $ccall_expr))
    end
    return ccall_expr
end

"""
    call_rust_function(func_ptr::Ptr{Cvoid}, ret_type::Type, args...)

Call a Rust function with the given return type.
Uses a generated ccall based on normalized argument types.

# Arguments
- `func_ptr::Ptr{Cvoid}`: Function pointer to the Rust function
- `ret_type::Type`: Expected return type of the function
- `args...`: Arguments to pass to the function

# Returns
- The return value of the Rust function, converted to the specified `ret_type`

# Example
```julia
target = resolve_call_target("mylib", "add")
result = call_rust_function(target.func_ptr, Int32, 10, 20)  # Returns Int32
```
"""
function call_rust_function(func_ptr::Ptr{Cvoid}, ret_type::Type, args...)
    argt = normalize_arg_types(ret_type, typeof(args))
    # Fail closed on an aggregate nobody asserted a layout for (#245 item 3).
    # Checked here rather than inside `_call_rust_function`, which is
    # `@generated`: a generated method is not re-generated when
    # `register_ffi_struct` is called later in the session. The signature form
    # keeps that property — it falls back to the runtime check for any
    # signature containing an aggregate, and elides it only where no
    # registration could ever be consulted (#253).
    ffi_check_by_value_signature(ret_type, argt)
    return _call_rust_function(func_ptr, ret_type, argt, args...)
end

"""
    call_rust_function(func_ptr::Ptr{Cvoid}, ret_type::Type, arg_types::Vector{Type}, args...)

Call a Rust function with explicit argument types.

# Arguments
- `func_ptr::Ptr{Cvoid}`: Function pointer to the Rust function
- `ret_type::Type`: Expected return type
- `arg_types::Vector{Type}`: Vector of argument types
- `args...`: Arguments to pass to the function

# Returns
- The return value of the Rust function

# Example
```julia
target = resolve_call_target("mylib", "multiply")
result = call_rust_function(target.func_ptr, Float64, [Float64, Float64], 3.14, 2.0)
```
"""
function call_rust_function(func_ptr::Ptr{Cvoid}, ret_type::Type, arg_types::Vector{Type}, args...)
    if length(arg_types) != length(args)
        error("Argument count mismatch: expected $(length(arg_types)), got $(length(args))")
    end
    argt = Core.apply_type(Tuple, arg_types...)
    ffi_check_by_value(ret_type, argt.parameters)
    return _call_rust_function(func_ptr, ret_type, argt, args...)
end

"""
    call_rust_function(func_ptr::Ptr{Cvoid}, ret_type::Type, argt::Type{<:Tuple}, args...)

Call a Rust function with a tuple type for arguments.

# Arguments
- `func_ptr::Ptr{Cvoid}`: Function pointer to the Rust function
- `ret_type::Type`: Expected return type
- `argt::Type{<:Tuple}`: Tuple type containing argument types
- `args...`: Arguments to pass to the function

# Returns
- The return value of the Rust function
"""
function call_rust_function(func_ptr::Ptr{Cvoid}, ret_type::Type, argt::Type{<:Tuple}, args...)
    if length(argt.parameters) != length(args)
        error("Argument count mismatch: expected $(length(argt.parameters)), got $(length(args))")
    end
    ffi_check_by_value(ret_type, argt.parameters)
    return _call_rust_function(func_ptr, ret_type, argt, args...)
end

# `call_rust_function_infer`, which guessed the return type from the first
# argument, was deprecated in #276 (it only ever raised after that) and
# removed in v0.5 (#417). Pass the return type: `call_rust_function(func_ptr,
# T, args...)` or `@rust f(x)::T`.

"""
    @rust_ccall(func_name, ret_type, arg_types, args...)

Low-level macro for calling a Rust function with explicit types.

# Example
```julia
@rust_ccall(add, Int32, (Int32, Int32), 10, 20)
```
"""
macro rust_ccall(func_name, ret_type, arg_types, args...)
    func_name_str = string(func_name)
    return quote
        # One snapshot, like every other door: pointer and panic channel from
        # the same generation (#277).
        target = resolve_call_target(get_current_library(), $func_name_str)
        guard_rust_panic_ptr(
            ccall(target.func_ptr, $(esc(ret_type)), $(esc(arg_types)), $(map(esc, args)...)),
            target.channel, $func_name_str)
    end
end
