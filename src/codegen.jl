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
const FUNCTION_REGISTRY = Dict{String, FunctionInfo}()

"""
Library-scoped registry for function information.
Maps (library name, function name) to FunctionInfo.
"""
const FUNCTION_REGISTRY_BY_LIB = Dict{Tuple{String, String}, FunctionInfo}()

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
const FUNCTION_RETURN_TYPES_BY_LIB = Dict{Tuple{String, String}, Type}()

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
const FUNCTION_SYMBOLS_BY_LIB = Dict{Tuple{String, String}, String}()

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
    lock(REGISTRY_LOCK) do
        FUNCTION_SYMBOLS_BY_LIB[(String(lib_name), String(name))] = String(symbol)
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
    lock(REGISTRY_LOCK) do
        get(FUNCTION_SYMBOLS_BY_LIB, (String(lib_name), String(name)), String(name))
    end
end

"""
    clear_library_metadata!(lib_name)

Drop everything the registries record *about* one library: its name-to-symbol
mappings and its return-type hints.

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
"""
struct CallTarget
    func_ptr::Ptr{Cvoid}
    channel::Ptr{Cvoid}
    free_ptr::Ptr{Cvoid}
    handle::Ptr{Cvoid}
    lib_name::String
    return_type::Union{Type, Nothing}
    func_info::Union{FunctionInfo, Nothing}
    generation::Int
end

"""
    ArtifactGeneration

The per-object half of a snapshot: what a `#[julia]` struct captures at
construction so its finalizer needs no lookup at all (#249).

`free_ptr` and `alive` must come from **one** generation: taken separately, an
object could capture the destructor of the image it was allocated by and the
liveness flag of the image that replaced it, and would then either skip a free
it should have made or make one into an image that had been closed.
"""
struct ArtifactGeneration
    handle::Ptr{Cvoid}
    free_ptr::Ptr{Cvoid}
    alive::Base.RefValue{Bool}
    generation::Int
end

"""
    PANIC_CHANNELS

`(library name, wrapper symbol)` → the pointer to that wrapper's panic-channel
reader, or `C_NULL` when the library exports none.

A `#[julia]` wrapper catches the panic, records the message in a thread-local
slot and exports `<symbol>_take_panic` to read it (#244). Julia has to look
that symbol up once per wrapper — a `dlsym` per call would cost more than the
call — and remember the answer, including the negative one: an artifact built
before #244, or a raw `#[no_mangle]` function the user wrote themselves, has no
channel and must not be probed again.

Entries are dropped with their library (`purge_library_state!`), so a reloaded
library re-resolves against the image that is actually mapped rather than
calling a pointer into a `dlclose`d one.

Guarded by `REGISTRY_LOCK`.
"""
const PANIC_CHANNELS = Dict{Tuple{String, String}, Ptr{Cvoid}}()

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
    lock(REGISTRY_LOCK) do
        cached = get(PANIC_CHANNELS, (lib, sym), nothing)
        cached === nothing || return cached
        entry = get(RUST_LIBRARIES, lib, nothing)
        ptr = C_NULL
        if entry !== nothing
            found = Libdl.dlsym(entry[1], ffi_panic_symbol(sym); throw_error = false)
            (found === nothing || found == C_NULL) || (ptr = found)
        end
        PANIC_CHANNELS[(lib, sym)] = ptr
        return ptr
    end
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

"""
    guard_rust_panic_ptr(value, channel::Ptr{Cvoid}, func_name)

`value`, unless the wrapper whose channel is `channel` panicked — in which case
the sentinel `value` is discarded and `RustPanicError` is raised.

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
harmless, and this function is what runs immediately after it: one `ccall` into
a thread-local read, no lock, no allocation, no logging. The shape every call
site uses is

    channel = panic_channel_pointer(lib, symbol)   # may yield: before the call
    value   = call_rust_function(ptr, T, args...)  # cannot yield
    guard_rust_panic_ptr(value, channel, name)     # cannot yield

`C_NULL` means the artifact has no channel (built before #244, or a raw
`#[no_mangle]` function the user wrote), and the guard is then a no-op.
"""
function guard_rust_panic_ptr(value, channel::Ptr{Cvoid}, func_name::AbstractString)
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

"""
    install_library_metadata!(lib_name, symbols, return_types)

Replace everything the registries record about `lib_name` with `symbols`
(`name => exported symbol` pairs) and `return_types` (`name => Type` pairs).

**The caller must hold `REGISTRY_LOCK`**, and must publish the library handle
in the same critical section: a task that finds the library in
`RUST_LIBRARIES` has to find how to resolve its names as well (#279). That is
what `load_artifact!` does; this is its metadata half, factored out so the
already-loaded re-registration path (`register_artifact_metadata!`) writes
exactly the same rows.

Whatever the library recorded before is dropped first, so a library
re-registered under the same name — a re-run block, a hot reload — keeps
nothing about a function it no longer defines or now declares differently.
"""
function install_library_metadata!(lib_name::AbstractString, symbols, return_types)
    name = String(lib_name)
    clear_library_metadata!(name)
    for (rust_name, symbol) in symbols
        register_function_symbol(name, rust_name, symbol)
    end
    for (key, ret_type) in return_types
        FUNCTION_RETURN_TYPES_BY_LIB[(name, String(key))] = ret_type
    end
    return nothing
end

"""
    purge_library_state!(lib_name)

Drop *every* registry row that belongs to `lib_name`: its symbol mappings and
return-type hints (`clear_library_metadata!`), its `FUNCTION_REGISTRY_BY_LIB`
entries, the `MONOMORPHIZED_FUNCTIONS` entries whose function pointers point
into it (stale pointers into an unloaded image are a use-after-free, #73) and
its `IRUST_FUNCTIONS` rows.

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
        info.lib_name == name && delete!(MONOMORPHIZED_FUNCTIONS, key)
    end
    for (key, (lib, _)) in collect(IRUST_FUNCTIONS)
        lib == name && delete!(IRUST_FUNCTIONS, key)
    end
    return nothing
end

"""
    copy_library_metadata!(from, to)

Give the library `to` the same name-to-symbol mappings and return-type hints as
`from`, replacing whatever it had.

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
    infer_function_types(lib_name::String, func_name::String) -> Tuple{Type, Vector{Type}}

Try to infer the return type and argument types for a function.
Uses LLVM IR analysis if available.
"""
function infer_function_types(lib_name::String, func_name::String)
    # The RustModule for this library, if the LLVM IR path recorded one.
    # `RUST_MODULE_REGISTRY` is keyed by library name (#278); it used to be
    # keyed by Julia's session-randomized `hash`, which no name could match.
    mod = lock(REGISTRY_LOCK) do
        get(RUST_MODULE_REGISTRY, lib_name, nothing)
    end
    if mod !== nothing
        fn = get_function(mod, func_name)
        if fn !== nothing
            return _get_function_signature(fn)
        end
    end

    # If we can't infer, return generic types
    error("Cannot infer types for function '$func_name'. Please provide explicit type annotations.")
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

default_numeric_arg_type(::Type{Bool}) = Int32
default_numeric_arg_type(::Type{UInt32}) = Int32
default_numeric_arg_type(::Type{Cstring}) = Int32
default_numeric_arg_type(::Type{String}) = Int32
default_numeric_arg_type(::Type{Cvoid}) = Int64
default_numeric_arg_type(::Type{T}) where {T} = T

normalize_arg_type(::Type{R}, ::Type{T}) where {R,T} = T
normalize_arg_type(::Type{R}, ::Type{T}) where {R,T<:AbstractString} = String
normalize_arg_type(::Type{R}, ::Type{Cstring}) where {R} = Cstring
normalize_arg_type(::Type{R}, ::Type{T}) where {R,T<:Integer} = T  # Preserve integer types
normalize_arg_type(::Type{R}, ::Type{T}) where {R,T<:AbstractFloat} = T  # Preserve float types
normalize_arg_type(::Type{R}, ::Type{Ptr{T}}) where {R,T} = Ptr{T}  # Preserve pointer types
normalize_arg_type(::Type{R}, ::Type{Ref{T}}) where {R,T} = Ref{T}  # Preserve Ref types

function normalize_arg_types(::Type{R}, argt::Type{<:Tuple}) where {R}
    normalized = map(t -> normalize_arg_type(R, t), argt.parameters)
    return Core.apply_type(Tuple, normalized...)
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
    return _call_rust_function(func_ptr, ret_type, argt, args...)
end

"""
    call_rust_function_infer(func_ptr::Ptr{Cvoid}, args...)

!!! warning "Deprecated (#276)"
    This function guessed the **return** type from the type of the **first
    argument**, defaulting to `Int64` and reading a string argument as a
    `Cstring` return. Neither is derivable from an argument, and reading a
    return slot at the wrong width is undefined behaviour, not a fallback
    (#245, #246). It now always raises.

    Call `call_rust_function(func_ptr, T, args...)` with the return type, or
    annotate the call site: `@rust f(x)::T`. A `#[julia]` function needs
    neither — its return type comes from the manifest.

Always throws a [`RustError`](@ref) naming the caller-visible fix.
"""
function call_rust_function_infer(func_ptr::Ptr{Cvoid}, args...)
    Base.depwarn(
        "call_rust_function_infer guesses the return type from the first " *
        "argument and is deprecated (#276); pass the return type explicitly, " *
        "e.g. call_rust_function(func_ptr, T, args...) or `@rust f(x)::T`.",
        :call_rust_function_infer)
    guessed = isempty(args) ? "Cvoid" : ffi_describe(juliatype_to_rust_or_name(typeof(first(args))))
    throw(RustError(
        "cannot call a Rust function without a return type: the return type " *
        "was previously guessed from the first argument " *
        "($(isempty(args) ? "no arguments" : guessed)), which is not " *
        "derivable from it (#245, #246). Annotate the call site with " *
        "`::T`, or call `call_rust_function(func_ptr, T, args...)`."))
end

# The Rust spelling of a Julia argument type, for the message above; falls back
# to the Julia name when there is no Rust counterpart, so `ffi_describe` still
# renders something useful.
function juliatype_to_rust_or_name(::Type{T}) where {T}
    return get(JULIA_TO_RUST_TYPE_MAP, T, string(nameof(T)))
end

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
