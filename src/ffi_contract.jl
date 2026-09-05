# The FFI type contract: single source of truth (issue #276, Phase A)
#
# RustCall currently decides "what does this Rust type mean at the C boundary?"
# in five independent places, each with its own table and its own domain:
#
#   | table                                                    | knows                          |
#   | -------------------------------------------------------- | ------------------------------ |
#   | `is_ffi_compatible_type` / `is_non_ffi_type`             | `PRIMITIVES` + `Type::Ptr`     |
#   | (`deps/rustcall_core/src/types.rs:85,104`)               |                                |
#   | `_rust_type_to_julia_conversion_type`                    | 13 primitives                  |
#   | (`src/julia_functions.jl:193`)                           |                                |
#   | `_rust_type_to_julia_type_symbol`                        | the same 13 plus `()`          |
#   | (`src/julia_functions.jl:220`)                           |                                |
#   | `_RUST_PRIMITIVE_TO_JULIA` (`src/ruststr.jl:519`)        | 13 primitives plus `()`        |
#   | `rust_to_julia_type_sym` (`src/structs.jl:665`)          | 8 primitives, `String`, `&str` |
#
# (`RUST_TO_JULIA_TYPE_MAP` in `src/typetranslation.jl` is a sixth, wider one.)
#
# This file is the *one* table those five are meant to collapse into. It also
# makes explicit two things the manifest leaves implicit today:
#
#   * the **C ABI form** of a value — by value, behind a pointer, as a
#     `(ptr, len)` pair, as a `(ptr, len, cap)` triple, ...
#   * **ownership** — who is responsible for releasing the memory a C slot
#     points at, and through which symbol.
#
# Phase A is strictly additive: nothing here is wired into a call site yet, and
# no existing behaviour changes. `test/test_ffi_contract.jl` enumerates, as
# executable documentation, every point where the five tables disagree with
# this one. Phase B migrates the call sites; those tests then become the
# regression tests for #245, #246 and #249.
#
# Forward compatibility with the `abi` manifest column (#270, PR #274): the
# extractor is growing an `Arg.abi` / `Method.return_abi` string column whose
# values are `""` (as written), `"string"` and `"str"`. Every entry point here
# accepts that column verbatim as the `abi` keyword and lets it override the
# ABI derived from the Rust type spelling, so wiring the manifest column in
# later is a parameter pass, not a rewrite.

# ============================================================================
# Vocabulary
# ============================================================================

"""
    FFI_ABI_KINDS

The C ABI forms a Rust value can take when it crosses the boundary.

| kind             | C slots                              | notes |
| ---------------- | ------------------------------------ | ----- |
| `:void`          | none                                 | the Rust unit type `()` |
| `:by_value`      | one, the scalar itself               | primitives, `#[repr(C)]` aggregates |
| `:pointer`       | one, `Ptr{T}`                        | raw pointers, opaque handles |
| `:ptr_len`       | two, `Ptr{UInt8}` + `Csize_t`        | `&str` and `&[T]` slices |
| `:ptr_len_cap`   | three, `Ptr{UInt8}` + 2 × `Csize_t`  | an owned Rust `String` / `Vec<T>` buffer |
| `:unknown`       | undefined                            | the type is not in the contract |

`:unknown` exists so that callers can *fail closed* (issue #276 acceptance
criterion 2) rather than fall back to a guess the way
`call_rust_function_infer` (`src/codegen.jl:304`) does today.
"""
const FFI_ABI_KINDS = (:void, :by_value, :pointer, :ptr_len, :ptr_len_cap, :unknown)

"""
    FFI_OWNERSHIP_KINDS

Who owns the memory a C slot refers to, and therefore who must release it.

| kind                   | meaning |
| ---------------------- | ------- |
| `:none`                | nothing is owned; the value is a scalar passed by value |
| `:borrowed`            | the pointee belongs to the other side and is only valid for the duration of the call |
| `:owned_by_julia`      | Julia allocated the buffer; Julia frees it, and must keep it rooted (`GC.@preserve`) across the call |
| `:owned_by_rust`       | Rust allocated the buffer; Julia must hand it back through `free_symbol` (#246) |
| `:transferred_to_julia`| ownership moved to Julia, which frees it with its own allocator |
| `:unknown`             | the contract does not say — callers must fail rather than assume |

`:owned_by_rust` is the tag whose missing `free_symbol` is the root of #246
(leaked `String` returns) and #249 (the drop symbol picked from the Julia-side
type tag instead of from the library that allocated the value).
"""
const FFI_OWNERSHIP_KINDS =
    (:none, :borrowed, :owned_by_julia, :owned_by_rust, :transferred_to_julia, :unknown)

"""
    FFIType

One row of the contract: what a Rust type spelling means at the boundary.

# Fields
- `rust::String` — the canonical Rust spelling (`"i32"`, `"String"`, `"&str"`, `"()"`).
- `ccall_type::Type` — the Julia type of the single C slot in the *by value*
  form. For multi-slot ABIs (`:ptr_len`, `:ptr_len_cap`) this is the type of the
  leading pointer slot; use [`ffi_argument_contract`](@ref) /
  [`ffi_return_contract`](@ref) for the full slot list.
- `surface_type::Type` — the type a Julia caller sees.
- `julia_symbol::Symbol` — how the surface type is *spelled* in generated code.
  Kept separate from `surface_type` because Julia aliases erase spellings:
  `Cvoid === Nothing` and `Csize_t === UInt64`, and the existing generators emit
  `:Cvoid` / `:Csize_t`.
- `abi::Symbol` — one of [`FFI_ABI_KINDS`], the ABI when the type appears as a
  plain by-value argument or return.
- `ownership::Symbol` — one of [`FFI_OWNERSHIP_KINDS`].
- `note::String` — why this row is the way it is, when that is not obvious.
"""
struct FFIType
    rust::String
    ccall_type::Type
    surface_type::Type
    julia_symbol::Symbol
    abi::Symbol
    ownership::Symbol
    note::String
end

"""
    FFIContract

The contract for one *position* — a single argument, or the return value — of a
function, i.e. an [`FFIType`](@ref) resolved for a direction and (optionally)
for the manifest `abi` column.

# Fields
- `rust_type::String` — the Rust spelling this was resolved from.
- `direction::Symbol` — `:argument` or `:return`.
- `abi::Symbol` — the resolved [`FFI_ABI_KINDS`] entry.
- `ccall_types::Vector{Type}` — the C slots, in order. Empty for a `:void`
  return; one entry for `:by_value` / `:pointer`; two for `:ptr_len`; three for
  `:ptr_len_cap`.
- `surface_type::Type` — the Julia type the user sees at this position.
- `ownership::Symbol` — one of [`FFI_OWNERSHIP_KINDS`].
- `free_symbol::Union{Nothing,String}` — for `:owned_by_rust`, the name of the
  symbol that releases the value, or `nothing` when the contract cannot name it
  yet (it is per-function: `<fn>_free_rust_string`, see #242/#246).
- `known::Bool` — `false` when the Rust spelling is not in the contract. A
  caller that must fail closed checks this instead of inspecting the fallback.
"""
struct FFIContract
    rust_type::String
    direction::Symbol
    abi::Symbol
    ccall_types::Vector{Type}
    surface_type::Type
    ownership::Symbol
    free_symbol::Union{Nothing, String}
    known::Bool
end

# ============================================================================
# The table
# ============================================================================

_ffi_row(rust, ccall_type, surface_type, julia_symbol, abi, ownership, note = "") =
    FFIType(rust, ccall_type, surface_type, julia_symbol, abi, ownership, note)

_ffi_scalar(rust, T, sym = Symbol(T)) = _ffi_row(rust, T, T, sym, :by_value, :none)

"""
    FFI_TYPE_TABLE :: Dict{String, FFIType}

The single source of truth: Rust type spelling → [`FFIType`](@ref).

Built by merging the domains of the five existing tables (see the header of
this file). Every spelling accepted by *any* of them is present here, so a type
that one layer accepts can no longer be silently mistranslated by the next
(#245 item 2). Spellings the contract deliberately refuses are absent, and
[`ffi_lookup`](@ref) returns `nothing` for them.
"""
const FFI_TYPE_TABLE = Dict{String, FFIType}()

function _ffi_register!(entry::FFIType)
    FFI_TYPE_TABLE[entry.rust] = entry
    return entry
end

# -- Rust primitives ---------------------------------------------------------
# The `PRIMITIVES` list of `deps/rustcall_core/src/types.rs:12` in full. The
# Julia-side tables stop at 13 of them; `i128`, `u128` and `char` are accepted
# by the Rust side and map to `:Any` on the Julia side today (#245 item 2).
for (rust, T) in (
    ("i8", Int8),
    ("i16", Int16),
    ("i32", Int32),
    ("i64", Int64),
    ("i128", Int128),
    ("u8", UInt8),
    ("u16", UInt16),
    ("u32", UInt32),
    ("u64", UInt64),
    ("u128", UInt128),
    ("f32", Float32),
    ("f64", Float64),
    ("bool", Bool),
)
    _ffi_register!(_ffi_scalar(rust, T))
end

# `usize` / `isize` are spelled with the C aliases because that is what the
# generated code emits; `Csize_t === UInt64` and `Cssize_t === Int64` on every
# platform RustCall supports, so this agrees with `RUST_TO_JULIA_TYPE_MAP`'s
# `UInt` / `Int` as a *type* while differing as a *spelling*.
_ffi_register!(_ffi_scalar("usize", Csize_t, :Csize_t))
_ffi_register!(_ffi_scalar("isize", Cssize_t, :Cssize_t))

# Rust `char` is a 4-byte Unicode scalar value. Julia's `Char` is also 4 bytes
# but stores UTF-8 code units left-aligned, so the bit patterns differ: the C
# slot must be `UInt32` and the surface value converted, never reinterpreted.
_ffi_register!(FFIType(
    "char", UInt32, Char, :Char, :by_value, :none,
    "Rust char is a code point; Julia Char is left-aligned UTF-8. Convert, do not reinterpret.",
))

# -- The unit type -----------------------------------------------------------
_ffi_register!(FFIType("()", Cvoid, Cvoid, :Cvoid, :void, :none, ""))

# -- `std::os::raw` aliases (from `RUST_TO_JULIA_TYPE_MAP`) ------------------
for (rust, T, sym) in (
    ("c_char", Cchar, :Cchar),
    ("c_int", Cint, :Cint),
    ("c_uint", Cuint, :Cuint),
    ("c_long", Clong, :Clong),
    ("c_ulong", Culong, :Culong),
    ("c_longlong", Clonglong, :Clonglong),
    ("c_ulonglong", Culonglong, :Culonglong),
    ("c_float", Cfloat, :Cfloat),
    ("c_double", Cdouble, :Cdouble),
)
    _ffi_register!(_ffi_scalar(rust, T, sym))
end

# -- Strings -----------------------------------------------------------------
# The ABI is direction-dependent, which is exactly what the flat tables cannot
# express and why #246 exists:
#
#   * as an argument, both `String` and `&str` arrive as `(ptr, len)` bytes —
#     Julia owns the buffer and must keep it rooted for the call; the Rust
#     wrapper copies (`String`) or borrows (`&str`).
#   * as a return, `String` is an owned `(ptr, len, cap)` buffer that Julia must
#     hand back to the library that allocated it, and `&str` is a borrowed
#     `(ptr, len)` view.
#
# The rows below carry the *return* ABI; [`ffi_argument_contract`](@ref)
# rewrites them for the argument direction.
_ffi_register!(FFIType(
    "String", Ptr{UInt8}, RustString, :RustString, :ptr_len_cap, :owned_by_rust,
    "Owned Rust buffer: (ptr, len, cap). Never a Cstring — see #246.",
))
_ffi_register!(FFIType(
    "&str", Ptr{UInt8}, RustStr, :RustStr, :ptr_len, :borrowed,
    "Fat pointer (ptr, len) borrowed from the callee; copy before the borrow ends.",
))
# Bare `str` is unsized and cannot cross the boundary by value; the existing
# `RUST_TO_JULIA_TYPE_MAP` maps it to `Cstring`, which is recorded here so the
# divergence tests can see it, but the contract treats it as a borrowed view.
_ffi_register!(FFIType(
    "str", Ptr{UInt8}, RustStr, :RustStr, :ptr_len, :borrowed,
    "Unsized; only ever reachable behind a reference. RUST_TO_JULIA_TYPE_MAP says Cstring.",
))

# ============================================================================
# Lookup
# ============================================================================

const _FFI_PTR_CONST_PREFIX = "*const "
const _FFI_PTR_MUT_PREFIX = "*mut "

"""
    ffi_lookup(rust_type::AbstractString) -> Union{FFIType, Nothing}

The contract row for a Rust type spelling, or `nothing` when the contract does
not cover it. Leading and trailing whitespace is ignored.

Raw pointer spellings (`*const T`, `*mut T`) are synthesised on demand: they map
to `Ptr{J}` where `J` is the pointee's Julia type, and to `Ptr{Cvoid}` when the
pointee is not itself in the contract (an opaque handle). This mirrors
`rustcall_core`'s `Type::Ptr => true` (`deps/rustcall_core/src/types.rs:91`),
which accepts every pointer wholesale.

`nothing` is the fail-closed answer. Callers must not substitute a default for
it; that is the guess this file exists to remove (#245 item 1).
"""
function ffi_lookup(rust_type::AbstractString)
    key = strip(rust_type)
    entry = get(FFI_TYPE_TABLE, key, nothing)
    entry === nothing || return entry
    return _ffi_pointer_row(key)
end

function _ffi_pointer_row(key::AbstractString)
    if startswith(key, _FFI_PTR_CONST_PREFIX)
        return _ffi_pointer_row(key, strip(key[(length(_FFI_PTR_CONST_PREFIX) + 1):end]))
    elseif startswith(key, _FFI_PTR_MUT_PREFIX)
        return _ffi_pointer_row(key, strip(key[(length(_FFI_PTR_MUT_PREFIX) + 1):end]))
    end
    return nothing
end

function _ffi_pointer_row(key::AbstractString, pointee::AbstractString)
    inner = get(FFI_TYPE_TABLE, pointee, nothing)
    T = if inner === nothing || inner.abi != :by_value
        Ptr{Cvoid}
    else
        Ptr{inner.ccall_type}
    end
    note = inner === nothing ? "Opaque pointee: the contract does not know $(pointee)." : ""
    return FFIType(String(key), T, T, Symbol(T), :pointer, :borrowed, note)
end

"""
    ffi_known(rust_type::AbstractString) -> Bool

Whether the contract covers this Rust type spelling.
"""
ffi_known(rust_type::AbstractString) = ffi_lookup(rust_type) !== nothing

"""
    ffi_ccall_type(rust_type::AbstractString) -> Union{Type, Nothing}

The Julia type of the leading C slot, or `nothing` when the type is unknown.
For multi-slot ABIs use [`ffi_argument_contract`](@ref) /
[`ffi_return_contract`](@ref), whose `ccall_types` lists every slot.
"""
function ffi_ccall_type(rust_type::AbstractString)
    entry = ffi_lookup(rust_type)
    return entry === nothing ? nothing : entry.ccall_type
end

"""
    ffi_surface_type(rust_type::AbstractString) -> Union{Type, Nothing}

The Julia type a caller sees for this Rust type, or `nothing` when unknown.
"""
function ffi_surface_type(rust_type::AbstractString)
    entry = ffi_lookup(rust_type)
    return entry === nothing ? nothing : entry.surface_type
end

"""
    ffi_julia_symbol(rust_type::AbstractString) -> Union{Symbol, Nothing}

How the surface type should be *spelled* in generated code (`:Cvoid`,
`:Csize_t`, ...), or `nothing` when the type is unknown.

This is the replacement for `_rust_type_to_julia_type_symbol`
(`src/julia_functions.jl:220`) and `rust_to_julia_type_sym`
(`src/structs.jl:665`) — except that both of those answer `:Any` for unknown
types, while this answers `nothing` so the caller can fail closed.
"""
function ffi_julia_symbol(rust_type::AbstractString)
    entry = ffi_lookup(rust_type)
    return entry === nothing ? nothing : entry.julia_symbol
end

"""
    ffi_ownership(rust_type::AbstractString) -> Symbol

The ownership tag of a Rust type in return position, or `:unknown`.
"""
function ffi_ownership(rust_type::AbstractString)
    entry = ffi_lookup(rust_type)
    return entry === nothing ? :unknown : entry.ownership
end

# ============================================================================
# Positional contracts
# ============================================================================

const _FFI_UNKNOWN_SLOTS = Type[]

"""
    ffi_manifest_abi_kind(abi::AbstractString) -> Union{Symbol, Nothing}

Translate the manifest `abi` column (`Arg.abi`, `Method.return_abi`; #270 and
PR #274) into an [`FFI_ABI_KINDS`] entry, given the direction it appears in.

The column is a small closed vocabulary of strings:

| column     | argument     | return          |
| ---------- | ------------ | --------------- |
| `""`       | as written   | as written      |
| `"string"` | `:ptr_len`   | `:ptr_len_cap`  |
| `"str"`    | `:ptr_len`   | `:ptr_len`      |

`""` means "the Rust type spelling decides", and is returned as `nothing`.
An unrecognised column value is an error rather than a fallback.
"""
function ffi_manifest_abi_kind(abi::AbstractString, direction::Symbol)
    _ffi_check_direction(direction)
    column = strip(abi)
    isempty(column) && return nothing
    if column == "string"
        return direction === :return ? :ptr_len_cap : :ptr_len
    elseif column == "str"
        return :ptr_len
    end
    throw(ArgumentError("unknown manifest abi column \"$column\"; expected \"\", \"string\" or \"str\""))
end

function _ffi_check_direction(direction::Symbol)
    direction === :argument || direction === :return ||
        throw(ArgumentError("direction must be :argument or :return, got :$direction"))
    return direction
end

"""
    ffi_slots(abi::Symbol) -> Vector{Type}

The C slots an ABI kind occupies, for the pointer-carrying kinds. Scalar and
pointer kinds depend on the concrete type and are filled in by
[`ffi_argument_contract`](@ref) / [`ffi_return_contract`](@ref).
"""
function ffi_slots(abi::Symbol)
    if abi === :ptr_len
        return Type[Ptr{UInt8}, Csize_t]
    elseif abi === :ptr_len_cap
        return Type[Ptr{UInt8}, Csize_t, Csize_t]
    elseif abi === :void
        return Type[]
    end
    throw(ArgumentError("ffi_slots is only defined for :void, :ptr_len and :ptr_len_cap, got :$abi"))
end

"""
    ffi_argument_contract(rust_type; abi = "") -> FFIContract

The contract for one argument position.

`abi` is the manifest `Arg.abi` column (PR #274); when non-empty it overrides
the ABI derived from the Rust spelling, which is what makes the manifest
normative (#270). When the Rust type is unknown the returned contract has
`known = false`, empty `ccall_types` and `:unknown` ownership — callers must
raise rather than substitute a default.

```julia
c = RustCall.ffi_argument_contract("&str")
c.ccall_types   # Type[Ptr{UInt8}, Csize_t]
c.ownership     # :owned_by_julia  (Julia's buffer, rooted for the call)
```
"""
function ffi_argument_contract(rust_type::AbstractString; abi::AbstractString = "")
    return _ffi_contract(rust_type, :argument, abi)
end

"""
    ffi_return_contract(rust_type; abi = "") -> FFIContract

The contract for the return position. `abi` is the manifest `Method.return_abi`
column (PR #274). See [`ffi_argument_contract`](@ref).

```julia
c = RustCall.ffi_return_contract("String")
c.abi           # :ptr_len_cap
c.ownership     # :owned_by_rust — Julia must free it through the owning library (#246)
```
"""
function ffi_return_contract(rust_type::AbstractString; abi::AbstractString = "")
    return _ffi_contract(rust_type, :return, abi)
end

function _ffi_contract(rust_type::AbstractString, direction::Symbol, abi::AbstractString)
    _ffi_check_direction(direction)
    key = String(strip(rust_type))
    override = ffi_manifest_abi_kind(abi, direction)
    entry = ffi_lookup(key)

    if entry === nothing
        override === nothing && return FFIContract(
            key, direction, :unknown, copy(_FFI_UNKNOWN_SLOTS), Any, :unknown, nothing, false,
        )
        # The manifest named the ABI even though the spelling is unknown to the
        # table: the manifest wins, which is the whole point of #270.
        return FFIContract(
            key, direction, override, ffi_slots(override),
            direction === :argument ? String : (override === :ptr_len_cap ? RustString : RustStr),
            _ffi_ownership_for(override, direction), nothing, true,
        )
    end

    kind = override === nothing ? _ffi_directional_abi(entry, direction) : override
    slots = if kind === :void
        Type[]
    elseif kind === :by_value || kind === :pointer
        Type[entry.ccall_type]
    else
        ffi_slots(kind)
    end
    ownership = if entry.abi === :by_value || entry.abi === :void || entry.abi === :pointer
        # Scalars own nothing; for a raw pointer the contract cannot know who
        # owns the pointee, so it stays `:borrowed` and the caller must say.
        entry.ownership
    else
        _ffi_ownership_for(kind, direction)
    end
    surface = direction === :argument && (kind === :ptr_len || kind === :ptr_len_cap) ?
        String : entry.surface_type
    return FFIContract(key, direction, kind, slots, surface, ownership, nothing, true)
end

# `String` and `&str` are `(ptr, len)` in argument position regardless of which
# of the two they are: the wrapper copies for `String` and borrows for `&str`.
function _ffi_directional_abi(entry::FFIType, direction::Symbol)
    if direction === :argument && entry.abi === :ptr_len_cap
        return :ptr_len
    end
    return entry.abi
end

function _ffi_ownership_for(kind::Symbol, direction::Symbol)
    kind === :void && return :none
    kind === :by_value && return :none
    direction === :argument && return :owned_by_julia
    kind === :ptr_len_cap && return :owned_by_rust
    return :borrowed
end

"""
    ffi_describe(rust_type; direction = :return, abi = "") -> String

A one-line human-readable rendering of a contract, for error messages and for
the documentation of the supported-type matrix (#245 item 4).
"""
function ffi_describe(rust_type::AbstractString; direction::Symbol = :return, abi::AbstractString = "")
    c = _ffi_contract(rust_type, direction, abi)
    c.known || return "$(c.rust_type): not in the FFI contract"
    slots = isempty(c.ccall_types) ? "no slots" : join(string.(c.ccall_types), ", ")
    return "$(c.rust_type) [$(c.direction)]: abi=$(c.abi), slots=($slots), surface=$(c.surface_type), ownership=$(c.ownership)"
end
