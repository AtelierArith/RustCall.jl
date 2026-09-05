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
| `:ptr_len`       | `Ptr{UInt8}` + `Csize_t`             | `&str` and `&[T]` slices |
| `:ptr_len_cap`   | `Ptr{UInt8}` + 2 × `Csize_t`         | an owned Rust `String` / `Vec<T>` buffer |
| `:unknown`       | undefined                            | the type is not in the contract |

The two multi-word kinds reach a `ccall` differently depending on direction:
as **separate argument slots** in argument position, and as **one `#[repr(C)]`
aggregate** (`CRustStr` / `CRustString`) in return position, since a `ccall` has
exactly one return type. [`FFIContract`](@ref) records both — `ccall_types` for
the calling convention, `layout` for the word list.

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
- `ccall_types::Vector{Type}` — **what this position contributes to a `ccall`
  signature**, which is direction-dependent for the multi-word ABIs:
  * `:void` return — empty;
  * `:by_value` / `:pointer` — one entry;
  * `:ptr_len` / `:ptr_len_cap` as an *argument* — the two or three separate
    argument slots the wrapper takes;
  * `:ptr_len` / `:ptr_len_cap` as a *return* — exactly one entry, the
    `#[repr(C)]` aggregate the wrapper returns, because a `ccall` has one
    return type. See `aggregate_type`.
- `aggregate_type::Union{Nothing,Type}` — the single `#[repr(C)]` struct the C
  value *is*, when this position passes an aggregate. Set for `:ptr_len` /
  `:ptr_len_cap` in return position (`CRustStr` / `CRustString`, matching
  `<fn>_RustCallBorrowedString` / `<fn>_RustCallOwnedString` emitted by
  `deps/rustcall_core/src/codegen.rs:837-863`), `nothing` otherwise — arguments
  are expanded into separate slots, not passed as an aggregate.
- `layout::Vector{Type}` — the C field layout of the value, in order, for the
  multi-word ABIs (`[Ptr{UInt8}, Csize_t]` / `[Ptr{UInt8}, Csize_t, Csize_t]`).
  Direction-independent: it describes the value, not the calling convention.
  Empty for the single-word ABIs.
- `surface_type::Type` — the Julia type the user sees at this position.
- `ownership::Symbol` — one of [`FFI_OWNERSHIP_KINDS`].
- `free_symbol::Union{Nothing,String}` — for `:owned_by_rust`, the name of the
  symbol that releases the value. The name is per-owner
  (`<fn|Struct>_free_rust_string`, `deps/rustcall_core/src/codegen.rs:633`), so
  it is filled in only when the caller passes `owner`; `nothing` otherwise.
- `known::Bool` — `false` when the Rust spelling is not in the contract. A
  caller that must fail closed checks this instead of inspecting the fallback.
"""
struct FFIContract
    rust_type::String
    direction::Symbol
    abi::Symbol
    ccall_types::Vector{Type}
    aggregate_type::Union{Nothing, Type}
    layout::Vector{Type}
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
# **The spelling does not determine the ABI. Only the manifest does.**
#
# On `main`, string lowering is not uniform across wrapper flavours:
#
#   * `transform_simple_function` (`deps/rustcall_core/src/codegen.rs:53-58`)
#     only marks a free `#[julia] fn ... -> String` signature `extern "C"` — the
#     Rust types are forwarded as written, with no `(ptr, len)` pair and no
#     `CRustString`;
#   * `generate_method_wrapper_crate` (`:378`, `:414`, `:443`) likewise forwards
#     the original argument and return types;
#   * only `inline_method_wrapper` (`:774-863`) actually lowers strings, into
#     `(ptr, len)` arguments and a `<fn>_RustCallOwnedString` /
#     `<fn>_RustCallBorrowedString` return.
#
# PR #274 makes the lowering uniform *and* records it in the manifest as
# `Arg.abi` / `Method.return_abi`. So the rule that is correct both before and
# after #274 is: **the manifest `abi` column is the only authority on whether
# lowering happened.** These rows therefore carry `:unknown` — a bare `String`
# spelling with `abi == ""` fails closed rather than describing a lowering the
# wrapper may not have performed. `abi = "string"` / `"str"` selects the lowered
# form, and only then does the contract name the slots, the aggregate and the
# ownership:
#
#   * as an argument, both arrive as `(ptr, len)` bytes — Julia owns the buffer
#     and must keep it rooted for the call; the wrapper copies (`String`) or
#     borrows (`&str`);
#   * as a return, `"string"` is an owned `(ptr, len, cap)` buffer that Julia
#     must hand back to the library that allocated it, and `"str"` is a borrowed
#     `(ptr, len)` view.
#
# The `surface_type` / `julia_symbol` columns stay meaningful regardless: they
# describe the Julia-visible type, not the calling convention.
_ffi_register!(FFIType(
    "String", Ptr{UInt8}, RustString, :RustString, :unknown, :unknown,
    "Owned Rust buffer, never a Cstring (#246) — but only the manifest abi column says whether the wrapper lowered it.",
))
_ffi_register!(FFIType(
    "&str", Ptr{UInt8}, RustStr, :RustStr, :unknown, :unknown,
    "Fat pointer (ptr, len) when lowered; the manifest abi column says whether it was.",
))
# Bare `str` is unsized and cannot cross the boundary by value; the existing
# `RUST_TO_JULIA_TYPE_MAP` maps it to `Cstring`, which is recorded here so the
# divergence tests can see it.
_ffi_register!(FFIType(
    "str", Ptr{UInt8}, RustStr, :RustStr, :unknown, :unknown,
    "Unsized; only ever reachable behind a reference. RUST_TO_JULIA_TYPE_MAP says Cstring.",
))

# ============================================================================
# Lookup
# ============================================================================

const _FFI_PTR_CONST_PREFIX = "*const "
const _FFI_PTR_MUT_PREFIX = "*mut "

# The only path prefixes under which a trailing primitive segment is guaranteed
# to *be* that primitive. `rustcall_core::types::is_ffi_compatible_type`
# (`deps/rustcall_core/src/types.rs:85`) is laxer: it matches on `last_ident`
# alone, so it also accepts `mycrate::i32`, where `i32` may be a user type
# alias with a completely different layout. The contract deliberately does not
# follow it that far — an unqualified last segment is not evidence — so
# `mycrate::i32` stays unknown and fails closed. That gap is a recorded
# divergence in `test/test_ffi_contract.jl`, and closing it needs the extractor
# to resolve the path (#270), not a wider guess here.
const FFI_PRIMITIVE_PATH_PREFIXES = ("core::primitive::", "std::primitive::")

"""
    ffi_normalize_spelling(rust_type::AbstractString) -> String

The table key for a Rust type spelling: whitespace trimmed, and a
`core::primitive::` / `std::primitive::` qualifier stripped so that
`core::primitive::i32` resolves like `i32`.

Only those two prefixes are stripped; see [`FFI_PRIMITIVE_PATH_PREFIXES`] for
why an arbitrary `mycrate::i32` is not normalized even though
`rustcall_core` accepts it.
"""
function ffi_normalize_spelling(rust_type::AbstractString)
    key = String(strip(rust_type))
    for prefix in FFI_PRIMITIVE_PATH_PREFIXES
        if startswith(key, prefix)
            tail = key[(length(prefix) + 1):end]
            # Only a bare final segment: `core::primitive::i32`, never
            # `core::primitive::foo::bar`.
            occursin("::", tail) && return key
            return tail
        end
    end
    return key
end

"""
    ffi_lookup(rust_type::AbstractString) -> Union{FFIType, Nothing}

The contract row for a Rust type spelling, or `nothing` when the contract does
not cover it. The spelling is normalized with [`ffi_normalize_spelling`](@ref)
first, so `core::primitive::u8` resolves like `u8`.

Raw pointer spellings (`*const T`, `*mut T`) are synthesised on demand: they map
to `Ptr{J}` where `J` is the pointee's Julia type. The pointee is resolved
*recursively* through `ffi_lookup`, so `*const *mut i32` is `Ptr{Ptr{Int32}}`;
only a pointee the contract genuinely cannot map (an opaque handle, or a
multi-word type like `String` that has no single-word C form) degrades to
`Ptr{Cvoid}`. This mirrors `rustcall_core`'s `Type::Ptr => true`
(`deps/rustcall_core/src/types.rs:91`), which accepts every pointer wholesale.

`nothing` is the fail-closed answer. Callers must not substitute a default for
it; that is the guess this file exists to remove (#245 item 1).
"""
function ffi_lookup(rust_type::AbstractString)
    key = ffi_normalize_spelling(rust_type)
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
    # Recursive: the pointee may itself be a pointer spelling.
    inner = ffi_lookup(pointee)
    T = if inner === nothing || !(inner.abi === :by_value || inner.abi === :pointer)
        Ptr{Cvoid}
    else
        Ptr{inner.ccall_type}
    end
    note = inner === nothing ? "Opaque pointee: the contract does not know $(pointee)." : ""
    # Ownership of a raw pointer is NOT derivable from the spelling. A generated
    # constructor returns `Box::into_raw` (`deps/rustcall_core/src/codegen.rs:386-392`),
    # which Julia owns and must free, while another `*mut T` may be a pointer
    # into memory Rust keeps. `:borrowed` — valid only for the duration of the
    # call — is reserved for `&T` / `&mut T` references, which `rustcall_core`
    # rejects as non-FFI anyway (`types.rs:104`). So the default is `:unknown`,
    # and a consumer that has the metadata states it: see
    # [`ffi_return_contract`](@ref)'s `ownership` / `free_symbol` keywords.
    return FFIType(String(key), T, T, Symbol(T), :pointer, :unknown, note)
end

"""
    ffi_known(rust_type::AbstractString) -> Bool

Whether the contract has a row for this Rust type spelling.

Note that a row is not by itself enough to build a call: the string rows carry
`abi === :unknown` because the spelling does not say whether the wrapper lowered
them (see the Strings section above). Use
[`ffi_argument_contract`](@ref) / [`ffi_return_contract`](@ref), whose `known`
field answers the question a call site actually asks — "can I build this
position?" — and is `false` for a string spelling without a manifest `abi`.
"""
ffi_known(rust_type::AbstractString) = ffi_lookup(rust_type) !== nothing

"""
    ffi_ccall_type(rust_type::AbstractString) -> Union{Type, Nothing}

The Julia type of the single C slot this Rust type occupies, or `nothing` when
the contract cannot say — either because the type is unknown, or because the
spelling alone does not determine its ABI (the string rows). For multi-word
ABIs use [`ffi_argument_contract`](@ref) / [`ffi_return_contract`](@ref).
"""
function ffi_ccall_type(rust_type::AbstractString)
    entry = ffi_lookup(rust_type)
    entry === nothing && return nothing
    entry.abi === :unknown && return nothing
    return entry.ccall_type
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

The C field layout of a multi-word ABI kind, in order. Direction-independent:
it describes the value, not the calling convention. For how those words reach a
`ccall` — separate argument slots, or one aggregate return type — see
[`ffi_argument_contract`](@ref) / [`ffi_return_contract`](@ref).

Scalar and pointer kinds depend on the concrete type and have no fixed layout
here.
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
    ffi_aggregate_type(abi::Symbol) -> Union{Type, Nothing}

The `#[repr(C)]` struct a multi-word ABI kind is returned as: `CRustStr` for
`:ptr_len`, `CRustString` for `:ptr_len_cap`, `nothing` for every single-word
kind.

These mirror the `<fn>_RustCallBorrowedString { ptr, len }` and
`<fn>_RustCallOwnedString { ptr, len, cap }` helpers the wrapper generator emits
(`deps/rustcall_core/src/codegen.rs:837-863`) and that `_call_rust_owned_string`
/ `_call_rust_borrowed_string` already receive (`src/structs.jl:511-528`).
"""
function ffi_aggregate_type(abi::Symbol)
    abi === :ptr_len && return CRustStr
    abi === :ptr_len_cap && return CRustString
    return nothing
end

"""
    ffi_free_symbol(owner::AbstractString) -> String

The name of the symbol that releases an `:owned_by_rust` string produced by
`owner` (a function or struct name): `<owner>_free_rust_string`, matching
`deps/rustcall_core/src/codegen.rs:633`.
"""
ffi_free_symbol(owner::AbstractString) = string(owner, "_free_rust_string")

"""
    ffi_argument_contract(rust_type; abi = "") -> FFIContract

The contract for one argument position. Multi-word values are **expanded into
separate argument slots** here, because that is how the generated wrapper takes
them.

`abi` is the manifest `Arg.abi` column (PR #274); when non-empty it overrides
the ABI derived from the Rust spelling, which is what makes the manifest
normative (#270). It is also the *only* thing that selects the lowered string
form: `ffi_argument_contract("String")` is unknown, `abi = "string"` makes it
`:ptr_len`.

When the position cannot be described the returned contract has `known = false`,
empty `ccall_types` and `:unknown` ownership — callers must raise rather than
substitute a default.

```julia
c = RustCall.ffi_argument_contract("&str"; abi = "str")
c.ccall_types     # Type[Ptr{UInt8}, Csize_t]  — two argument slots
c.aggregate_type  # nothing
c.ownership       # :owned_by_julia  (Julia's buffer, rooted for the call)
```
"""
function ffi_argument_contract(rust_type::AbstractString; abi::AbstractString = "")
    return _ffi_contract(rust_type, :argument, abi, nothing, nothing, nothing)
end

"""
    ffi_return_contract(rust_type; abi = "", owner = nothing,
                        ownership = nothing, free_symbol = nothing) -> FFIContract

The contract for the return position. `abi` is the manifest `Method.return_abi`
column (PR #274). See [`ffi_argument_contract`](@ref).

A `ccall` has exactly one return type, so a multi-word value is **not** expanded
here: `ccall_types` holds the single `#[repr(C)]` aggregate the wrapper returns
(also available as `aggregate_type`), and `layout` holds its fields.

# Stating ownership the spelling cannot express

A raw-pointer return defaults to `:unknown` ownership, because the spelling does
not say: a generated constructor returns `Box::into_raw`
(`deps/rustcall_core/src/codegen.rs:386-392`), which Julia owns and must free,
while another `*mut T` may point into memory Rust keeps. A consumer that *has*
the metadata states it with `ownership` (and, where a release is required, the
`free_symbol` that performs it):

```julia
c = RustCall.ffi_return_contract("*mut Point";
                                 ownership = :transferred_to_julia,
                                 free_symbol = "Point_free")
c.ownership    # :transferred_to_julia
c.free_symbol  # "Point_free"
```

Declaring `:owned_by_rust` or `:transferred_to_julia` without naming a
`free_symbol` (directly, or via `owner` for the string convention) is an
`ArgumentError`: an owned value with no way to release it is the shape of #246
and #249, and the contract refuses to record it.

`owner` is the function or struct name the wrapper belongs to; when given, an
`:owned_by_rust` string return carries its [`ffi_free_symbol`](@ref).

```julia
c = RustCall.ffi_return_contract("String"; abi = "string", owner = "shout")
c.abi             # :ptr_len_cap
c.ccall_types     # Type[CRustString]  — one return type
c.layout          # Type[Ptr{UInt8}, Csize_t, Csize_t]
c.ownership       # :owned_by_rust — Julia must free it through the owning library (#246)
c.free_symbol     # "shout_free_rust_string"
```
"""
function ffi_return_contract(rust_type::AbstractString; abi::AbstractString = "",
                             owner::Union{Nothing, AbstractString} = nothing,
                             ownership::Union{Nothing, Symbol} = nothing,
                             free_symbol::Union{Nothing, AbstractString} = nothing)
    return _ffi_contract(rust_type, :return, abi, owner, ownership, free_symbol)
end

"""
    ffi_return_ccall_type(rust_type; abi = "") -> Union{Type, Nothing}

The single Julia type to put in the return slot of a `ccall` for this Rust type,
or `nothing` when the contract cannot describe the position (`Cvoid` for `()`).
"""
function ffi_return_ccall_type(rust_type::AbstractString; abi::AbstractString = "")
    c = ffi_return_contract(rust_type; abi = abi)
    c.known || return nothing
    c.abi === :void && return Cvoid
    return only(c.ccall_types)
end

function _ffi_contract(rust_type::AbstractString, direction::Symbol, abi::AbstractString,
                       owner::Union{Nothing, AbstractString},
                       stated_ownership::Union{Nothing, Symbol},
                       stated_free_symbol::Union{Nothing, AbstractString})
    _ffi_check_direction(direction)
    key = ffi_normalize_spelling(rust_type)
    override = ffi_manifest_abi_kind(abi, direction)
    entry = ffi_lookup(key)
    stated = _ffi_check_stated_ownership(key, stated_ownership, stated_free_symbol, owner)

    if entry === nothing
        override === nothing && return _ffi_unknown_contract(key, direction)
        # The manifest named the ABI even though the spelling is unknown to the
        # table: the manifest wins, which is the whole point of #270.
        ownership = _ffi_ownership_for(override, direction)
        surface = direction === :argument ? String :
            (override === :ptr_len_cap ? RustString : RustStr)
        return _ffi_positional(key, direction, override, surface, ownership, owner,
                               nothing, stated...)
    end

    kind = override === nothing ? _ffi_directional_abi(entry, direction) : override
    # No manifest column and a spelling whose ABI it does not determine (the
    # string rows): fail closed instead of describing a lowering the wrapper may
    # never have performed.
    kind === :unknown && return _ffi_unknown_contract(key, direction)

    ownership = if entry.abi === :by_value || entry.abi === :void || entry.abi === :pointer
        # Scalars own nothing; for a raw pointer the contract cannot know who
        # owns the pointee, so it stays `:unknown` until a consumer states it.
        entry.ownership
    else
        _ffi_ownership_for(kind, direction)
    end
    surface = direction === :argument && (kind === :ptr_len || kind === :ptr_len_cap) ?
        String : entry.surface_type
    return _ffi_positional(key, direction, kind, surface, ownership, owner,
                           entry.ccall_type, stated...)
end

_ffi_unknown_contract(key, direction) = FFIContract(
    key, direction, :unknown, copy(_FFI_UNKNOWN_SLOTS), nothing,
    copy(_FFI_UNKNOWN_SLOTS), Any, :unknown, nothing, false,
)

# An explicitly stated ownership must be a known tag, and one that implies a
# release must name the symbol that performs it.
function _ffi_check_stated_ownership(key, ownership, free_symbol, owner)
    if ownership !== nothing
        ownership in FFI_OWNERSHIP_KINDS || throw(ArgumentError(
            "unknown ownership :$ownership for $key; expected one of $(FFI_OWNERSHIP_KINDS)"))
        if ownership === :owned_by_rust || ownership === :transferred_to_julia
            free_symbol === nothing && owner === nothing && throw(ArgumentError(
                "ownership :$ownership for $key requires a free_symbol (or an owner): " *
                "an owned value with no way to release it cannot be recorded"))
        end
    end
    return (ownership, free_symbol === nothing ? nothing : String(free_symbol))
end

# Turn an ABI kind into the ccall slots / aggregate / layout for one position.
function _ffi_positional(key, direction, kind, surface, ownership, owner,
                         scalar_type::Union{Nothing, Type} = nothing,
                         stated_ownership::Union{Nothing, Symbol} = nothing,
                         stated_free_symbol::Union{Nothing, String} = nothing)
    layout = kind === :ptr_len || kind === :ptr_len_cap ? ffi_slots(kind) : Type[]
    aggregate = direction === :return ? ffi_aggregate_type(kind) : nothing
    slots = if kind === :void
        Type[]
    elseif kind === :by_value || kind === :pointer
        Type[scalar_type === nothing ? Ptr{Cvoid} : scalar_type]
    elseif aggregate !== nothing
        # One return type, not N words: `ccall` has a single return slot.
        Type[aggregate]
    else
        copy(layout)
    end
    # A stated ownership wins over the derived one: the consumer has metadata
    # the spelling does not carry (a constructor's `Box::into_raw`, say).
    final_ownership = stated_ownership === nothing ? ownership : stated_ownership
    derived_free = final_ownership === :owned_by_rust && owner !== nothing ?
        ffi_free_symbol(owner) : nothing
    free_symbol = stated_free_symbol === nothing ? derived_free : stated_free_symbol
    return FFIContract(key, direction, kind, slots, aggregate, layout, surface,
                       final_ownership, free_symbol, true)
end

# When the manifest says `"string"` for an argument, the wrapper takes the words
# as `(ptr, len)` — `ffi_manifest_abi_kind` already resolves that. This only
# handles the (now unreachable for strings) case of a table row whose own ABI is
# `:ptr_len_cap`, kept so future owned-aggregate rows behave consistently.
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
    # A lowered `&str` return: a view into memory Rust keeps, valid only for as
    # long as the callee guarantees. This is the one place `:borrowed` is
    # derived — a raw pointer never is.
    kind === :ptr_len && return :borrowed
    return :unknown
end

"""
    ffi_describe(rust_type; direction = :return, abi = "") -> String

A one-line human-readable rendering of a contract, for error messages and for
the documentation of the supported-type matrix (#245 item 4).
"""
function ffi_describe(rust_type::AbstractString; direction::Symbol = :return, abi::AbstractString = "")
    c = _ffi_contract(rust_type, direction, abi, nothing, nothing, nothing)
    c.known || return "$(c.rust_type): not in the FFI contract"
    slots = isempty(c.ccall_types) ? "no slots" : join(string.(c.ccall_types), ", ")
    return "$(c.rust_type) [$(c.direction)]: abi=$(c.abi), slots=($slots), surface=$(c.surface_type), ownership=$(c.ownership)"
end
