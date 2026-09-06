# The FFI type contract: single source of truth (issue #276)
#
# RustCall used to decide "what does this Rust type mean at the C boundary?" in
# five independent places, each with its own table and its own domain — plus
# `RUST_TO_JULIA_TYPE_MAP`, a sixth and wider one. They disagreed: `u16` was
# `UInt16` in a free function and `Any` in a struct field, `usize` was
# `Csize_t` in two of them and `UInt64` in a third, `i128` and `char` were in
# none of them although the Rust side generates wrappers for both, and `str`
# was a `Cstring` — a NUL-terminated pointer, which a Rust string is not.
#
# This file is the one table they collapsed into (Phase B). It also makes
# explicit two things the manifest leaves implicit:
#
#   * the **C ABI form** of a value — by value, behind a pointer, as a
#     `(ptr, len)` pair, as a `(ptr, len, cap)` triple, ...
#   * **ownership** — who is responsible for releasing the memory a C slot
#     points at, and through which symbol.
#
# What remains outside it, deliberately: `is_ffi_compatible_type` /
# `is_non_ffi_type` (`deps/rustcall_core/src/types.rs`) is the *acceptance
# gate* on the Rust side — it decides whether a wrapper is generated at all,
# not what the type means — and `JULIA_TO_RUST_TYPE_MAP` covers the reverse
# direction, which a Julia type does not determine on its own.
#
# The manifest, not the Rust spelling, is the authority on how a value was
# lowered. The `abi` column (`Arg.abi`, `Function.return_abi`,
# `Method.return_abi`, `Field.abi`) takes the values `""` (as written),
# `"string"` and `"str"`; every entry point here accepts it verbatim as the
# `abi` keyword and lets it override the ABI derived from the spelling.
#
# `test/test_ffi_contract.jl` holds what were the divergence tests and are now
# the regression tests for #245, #246 and #249.

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
| `:owned_by_rust`       | Rust allocated it; Julia releases it **within the call** by calling `free_symbol` (#246) |
| `:transferred_to_julia`| the *responsibility* to release moved to Julia, which **must** do so by calling `free_symbol` — never through Julia's allocator |
| `:unknown`             | the contract does not say — callers must fail rather than assume |

# `:owned_by_rust` vs `:transferred_to_julia`

The release **mechanism is identical**: both call the Rust export named by
`free_symbol`, so the Rust destructor runs on the allocator that allocated the
value. Julia never frees Rust memory itself — not with `Libc.free`, not with its
own GC. Freeing a `Box::into_raw` handle any other way skips `Drop` and, once a
crate installs a `#[global_allocator]`, corrupts the heap (#249).

What differs is **when**, and therefore who holds the pointer:

* `:owned_by_rust` — the value does not outlive the call. The wrapper copies it
  into Julia memory and calls `free_symbol` before returning, as
  `_call_rust_owned_string` already does in a `finally`
  (`src/structs.jl:511-523`). Julia never stores the raw pointer.
* `:transferred_to_julia` — the value outlives the call. Julia keeps the handle
  (a `Box::into_raw` pointer inside a struct wrapper, `codegen.rs:386-392`) and
  is responsible for calling `free_symbol` later, from a finalizer.

Both are in [`FFI_OWNERSHIP_NEEDS_FREE`], so both always name that symbol. A
missing `free_symbol` on either is the root of #246 (leaked `String` returns)
and #249 (the drop symbol picked from the Julia-side type tag instead of from
the library that allocated the value).
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
- `julia_expr::Union{Symbol,Expr}` — how the surface type is *spelled* in
  generated code, as a Julia AST fragment ready to splice with `\$`: a `Symbol`
  for a plain name (`:Int32`, `:Cvoid`, `:RustString`) and an `Expr` for a
  parametric one (`:(Ptr{Ptr{Int32}})`). Kept separate from `surface_type`
  because Julia aliases erase spellings: `Cvoid === Nothing` and
  `Csize_t === UInt64`, and the existing generators emit `:Cvoid` / `:Csize_t`.
  Evaluating it in the `RustCall` module yields `surface_type`.
- `abi::Symbol` — one of [`FFI_ABI_KINDS`], the ABI when the type appears as a
  plain by-value argument or return.
- `ownership::Symbol` — one of [`FFI_OWNERSHIP_KINDS`].
- `note::String` — why this row is the way it is, when that is not obvious.
"""
struct FFIType
    rust::String
    ccall_type::Type
    surface_type::Type
    julia_expr::Union{Symbol, Expr}
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

_ffi_row(rust, ccall_type, surface_type, julia_expr, abi, ownership, note = "") =
    FFIType(rust, ccall_type, surface_type, julia_expr, abi, ownership, note)

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
# `i128` / `u128` do not round-trip on `x86_64-pc-windows-msvc`: MSVC has no
# native 128-bit integer, so Rust and Julia disagree on how `extern "C"` passes
# one (rust-lang/rust#54341). That is a platform ABI mismatch, not a mapping
# choice — the row below is the only honest one, and no Julia-side type would
# make the two agree.
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
# platform RustCall supports, so this agrees as a *type* with the `UInt` / `Int`
# the retired `RUST_TO_JULIA_TYPE_MAP` used, while differing as a *spelling*.
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

# -- `std::os::raw` aliases --------------------------------------------------
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
# The `surface_type` / `julia_expr` columns stay meaningful regardless: they
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
# it is a `(ptr, len)` view like `&str`, never the `Cstring` the retired
# `RUST_TO_JULIA_TYPE_MAP` claimed (#246).
_ffi_register!(FFIType(
    "str", Ptr{UInt8}, RustStr, :RustStr, :unknown, :unknown,
    "Unsized; only ever reachable behind a reference, so it travels as (ptr, len), never as a Cstring.",
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
`core::primitive::i32` resolves like `i32`. A leading `::` (the rooted form
`::core::primitive::i32`, which `type_to_string` preserves) is stripped first.

Only those two prefixes are stripped; see [`FFI_PRIMITIVE_PATH_PREFIXES`] for
why an arbitrary `mycrate::i32` — rooted or not — is not normalized even though
`rustcall_core` accepts it.
"""
function ffi_normalize_spelling(rust_type::AbstractString)
    key = String(strip(rust_type))
    # A rooted path (`::core::primitive::i32`) names the same type as the
    # unrooted one; only the primitive prefixes below act on it, so an
    # unrecognised rooted path is returned untouched and still fails closed.
    rooted = startswith(key, "::") ? key[3:end] : key
    for prefix in FFI_PRIMITIVE_PATH_PREFIXES
        if startswith(rooted, prefix)
            tail = rooted[(length(prefix) + 1):end]
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
    return FFIType(String(key), T, T, ffi_type_expr(T), :pointer, :unknown, note)
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
    ffi_julia_symbol(rust_type::AbstractString) -> Union{Symbol, Expr, Nothing}

How the surface type should be *spelled* in generated code, as a Julia AST
fragment, or `nothing` when the type is unknown.

A plain name comes back as a `Symbol` (`:Cvoid`, `:Csize_t`, `:RustString`); a
parametric one comes back as an `Expr` (`:(Ptr{Ptr{Int32}})`), never as a
`Symbol` of its printed form — `Symbol("Ptr{Int32}")` would splice into
generated code as `var"Ptr{Int32}"`, an undefined binding. Both forms can be
interpolated into a quote directly:

```julia
T = RustCall.ffi_julia_symbol("*const *mut i32")   # :(Ptr{Ptr{Int32}})
:(x::\$T)
```

Use [`ffi_julia_type`](@ref) when you want the `Type` itself rather than its
spelling.

This replaced `_rust_type_to_julia_type_symbol` (`src/julia_functions.jl`) and
`rust_to_julia_type_sym` (`src/structs.jl`), both of which answered `:Any` for
an unknown type; this answers `nothing`, so a caller can fail closed. Return
sites should call [`ffi_return_symbol_or_throw`](@ref), which does exactly
that.
"""
function ffi_julia_symbol(rust_type::AbstractString)
    entry = ffi_lookup(rust_type)
    return entry === nothing ? nothing : entry.julia_expr
end

"""
    ffi_julia_type(rust_type::AbstractString) -> Union{Type, Nothing}

The `Type` that [`ffi_julia_symbol`](@ref)'s expression names — the surface type
as a value, for callers that want to compare types without `eval`. `nothing`
when the type is unknown.

```julia
RustCall.ffi_julia_type("*const *mut i32") === Ptr{Ptr{Int32}}
```
"""
ffi_julia_type(rust_type::AbstractString) = ffi_surface_type(rust_type)

"""
    ffi_type_expr(T::Type) -> Union{Symbol, Expr}

Render a Julia type as an AST fragment that names it: `:Int32`, `:Cvoid`,
`:(Ptr{Ptr{Int32}})`. Parametric `Ptr`s are rendered recursively so the result
is always valid Julia, never a `Symbol` of a printed type.

`Cvoid` is spelled `:Cvoid` rather than `:Nothing`, matching what the existing
generators emit.
"""
function ffi_type_expr(T::Type)
    T === Cvoid && return :Cvoid
    if T <: Ptr && T !== Ptr && isconcretetype(T)
        return Expr(:curly, :Ptr, ffi_type_expr(eltype(T)))
    end
    # `nameof`, not `Symbol(T)`: the latter renders a module-qualified string for
    # types outside `Base`, which is not a `Symbol` any generated code can use.
    return T isa DataType ? nameof(T) : Symbol(T)
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
    ffi_panic_symbol(symbol::AbstractString) -> String

The panic-channel reader a generated wrapper exports next to itself:
`<wrapper symbol>_take_panic`, matching
`rustcall_core::codegen::panic_symbol` (#244).

`(out, cap) -> len` semantics: the length of the pending panic message, or 0
when the wrapper did not panic. The message is copied into `out` and the slot
cleared **only** when it fits in `cap`, so a caller that guessed too small a
buffer calls again with the length it was told. Nothing crosses the boundary
that has to be freed.

Derived from the wrapper symbol rather than carried in the manifest on
purpose: the caller already resolved the symbol to make the call, so it can
resolve the channel without a schema change. A library that predates #244
simply has no such symbol, and the lookup falls back to "no channel".
"""
ffi_panic_symbol(symbol::AbstractString) = string(symbol, "_take_panic")

"""
    ffi_struct_free_symbol(struct_name::AbstractString) -> String

The destructor of a `#[julia]` struct: `<Struct>_free`, matching what
`deps/rustcall_core/src/codegen.rs` emits (`crate_free_fn` and its inline
twin).

One place, because four call sites used to build this string by hand
(`src/structs.jl` twice, `src/crate_bindings.jl` for the in-memory module and
for the emitted template) and a finalizer that calls the wrong symbol is a
leak at best (#249, #277 Phase B4).
"""
ffi_struct_free_symbol(struct_name::AbstractString) = string(struct_name, "_free")

"""
Prefix of every exported symbol that stands in for a user-written Rust item.

`#[julia]` is additive (#279): the annotated item keeps its name and the
`extern "C"` entry point is emitted next to it under this prefix. Mirrors
`rustcall_core::codegen::SYMBOL_PREFIX`.
"""
const FFI_SYMBOL_PREFIX = "rustcall_"

"""
    ffi_method_symbol(struct_name, method_name) -> String

The exported symbol of the wrapper of the `#[julia]` method `Struct::method`
(`rustcall_<Struct>_<method>`, see `deps/rustcall_core/src/codegen.rs`).

This is the fallback for a `RustMethod` built by hand rather than read from a
manifest: its six-argument constructor cannot know the struct name, so it
records no `symbol` and the emitters derive one here. A manifest-backed method
always carries its own `symbol` and never reaches this (#279).
"""
ffi_method_symbol(struct_name::AbstractString, method_name::AbstractString) =
    string(FFI_SYMBOL_PREFIX, struct_name, "_", method_name)

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

# The free-symbol invariant

A contract whose ownership is one of [`FFI_OWNERSHIP_NEEDS_FREE`] **always**
names the `free_symbol` that releases the value; an owned value with no way to
free it is the shape of #246 and #249 and is never recorded. Concretely:

* declaring `:owned_by_rust` / `:transferred_to_julia` without a `free_symbol`
  is an `ArgumentError`;
* a *derived* owned return with no symbol available (a lowered `String` return
  where the caller named no owner) reports `:unknown` ownership rather than an
  unfreeable `:owned_by_rust`.

`owner` is the function or struct name the wrapper belongs to. It supplies only
the **string** release convention (`<owner>_free_rust_string`,
`deps/rustcall_core/src/codegen.rs:633`), so it stands in for `free_symbol` only
on a lowered owned-string return (`:ptr_len_cap`). For a pointer return — where
the releasing symbol is whatever the crate exports, e.g. `Point_free` — it does
not apply and `free_symbol` must be given.

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
    ownership === nothing || ownership in FFI_OWNERSHIP_KINDS || throw(ArgumentError(
        "unknown ownership :$ownership for $rust_type; " *
        "expected one of $(FFI_OWNERSHIP_KINDS)"))
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
    stated = (stated_ownership,
              stated_free_symbol === nothing ? nothing : String(stated_free_symbol))

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

"""
    FFI_OWNERSHIP_NEEDS_FREE

The ownership tags that oblige someone to release the value. The contract keeps
the invariant that a position tagged with one of these **always** names the
`free_symbol` that performs the release — an owned value with no way to free it
is the shape of #246 and #249, and is refused rather than recorded.
"""
const FFI_OWNERSHIP_NEEDS_FREE = (:owned_by_rust, :transferred_to_julia)

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

    # `owner` only names the *string* release convention
    # (`<owner>_free_rust_string`, deps/rustcall_core/src/codegen.rs:633), so it
    # may stand in for `free_symbol` only where that convention applies: the
    # lowered owned-string return. Every other owned value must name its own
    # symbol explicitly.
    derived_free = owner !== nothing && kind === :ptr_len_cap && direction === :return ?
        ffi_free_symbol(owner) : nothing
    free_symbol = stated_free_symbol === nothing ? derived_free : stated_free_symbol

    if final_ownership in FFI_OWNERSHIP_NEEDS_FREE && free_symbol === nothing
        if stated_ownership === nothing
            # Derived, not asserted: the ABI says the value is owned but nobody
            # named the releasing symbol. Fail closed rather than hand back an
            # owned value a consumer cannot free (#246, #249).
            final_ownership = :unknown
        else
            throw(ArgumentError(
                "ownership :$stated_ownership for $key requires an explicit free_symbol" *
                (kind === :ptr_len_cap ? " (or an owner, for the string convention)" : "") *
                ": an owned value with no way to release it cannot be recorded"))
        end
    end

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

# ============================================================================
# The one return decision (issue #276 Phase B)
# ============================================================================

"""
    FFI_STRICT :: Ref{Symbol}

What generated code does when the FFI contract cannot describe a **return**
position:

| value    | behaviour |
| -------- | --------- |
| `:error` | raise a `RustError` naming the signature (the default) |
| `:warn`  | warn once per signature and emit `Any`, the pre-#276 behaviour |
| `:none`  | emit `Any` silently |

`Any` in a `ccall` return slot was never well defined — it is the guess #245
is about — so `:warn` and `:none` exist only to get an existing crate compiling
again while its unsupported types are dealt with. `write_bindings_to_file`
binds this per call through its `strict` keyword.
"""
const FFI_STRICT = Ref{Symbol}(:error)

const _FFI_WARNED_CONTEXTS = Set{String}()

"""
    ffi_return_symbol_or_throw(rust_type, abi, ctx; strict = FFI_STRICT[]) -> Union{Symbol, Expr}

How the return position of `ctx` is spelled in generated code, as a Julia AST
fragment ready to splice.

This is the single entry point every return site uses — the `Expr` generators
of `src/crate_bindings.jl` and the source-text emitters alike — so the two
copies cannot drift apart again (#276 acceptance criterion 2). `ctx` is the
signature the position belongs to (`"mycrate::shout(s) -> String"`), and it is
what an unsupported type is reported against.

Multi-word returns are *not* handled here: a lowered `String` / `&str` return
is a `#[repr(C)]` buffer with an owner, which the caller must take from
[`ffi_return_contract`](@ref) so it also gets `free_symbol`. Asking for a
single symbol for one is treated as unsupported.

The C **slot** is what generated code needs, which is not always the surface
type: Rust `char` arrives as a `UInt32` code point and must be converted, never
reinterpreted as Julia's left-aligned UTF-8 `Char`.
"""
function ffi_return_symbol_or_throw(rust_type::AbstractString, abi::AbstractString,
                                    ctx::AbstractString; strict::Symbol = FFI_STRICT[])
    c = ffi_return_contract(rust_type; abi = abi)
    if c.known
        c.abi === :void && return :Cvoid
        if c.abi === :by_value || c.abi === :pointer
            # The **surface** spelling, not the raw C slot: `call_rust_function`
            # lowers it to the slot and converts the value back
            # (`ccall_return_type` / `convert_return` in `src/codegen.jl`), so
            # the slot-to-surface conversion lives in one place instead of at
            # every return site. Rust `char` is where the two differ.
            return something(ffi_julia_symbol(rust_type), ffi_type_expr(c.surface_type))
        end
    end
    return _ffi_unsupported_return(rust_type, abi, ctx, strict, :Any)
end

"""
    ffi_return_slot_symbol_or_throw(rust_type, abi, ctx; strict = FFI_STRICT[]) -> Union{Symbol, Expr}

The spelling of the **C slot** a return position occupies, where
[`ffi_return_symbol_or_throw`](@ref) gives the Julia surface type it is read
back as.

The two differ only for Rust `char` (a `UInt32` Unicode scalar value read back
as a `Char`), and a plain return never needs this: `call_rust_function` takes
the surface type and does the lowering itself. It is needed where the value is
a **field of a `#[repr(C)]` aggregate** — the `CResult_<fn>` / `COption_<fn>`
payloads — because the field must be declared with the type Rust actually
stored, and the conversion to the surface type happens after the call
(`convert_return`).
"""
function ffi_return_slot_symbol_or_throw(rust_type::AbstractString, abi::AbstractString,
                                         ctx::AbstractString; strict::Symbol = FFI_STRICT[])
    c = ffi_return_contract(rust_type; abi = abi)
    if c.known
        c.abi === :void && return :Cvoid
        if c.abi === :by_value || c.abi === :pointer
            return _ffi_slot_expr(rust_type, c)
        end
    end
    return _ffi_unsupported_return(rust_type, abi, ctx, strict, :Any)
end

"""
    ffi_return_type_or_throw(rust_type, abi, ctx; strict = FFI_STRICT[]) -> Type

[`ffi_return_symbol_or_throw`](@ref) as a `Type` rather than as a spelling, for
the sites that splice a concrete type into generated code instead of a name —
`src/structs.jl` used to pass a `Symbol` through the call and re-resolve it at
run time through a nine-entry table, which is how a `u16` struct field became
`Any` (#245).
"""
function ffi_return_type_or_throw(rust_type::AbstractString, abi::AbstractString,
                                  ctx::AbstractString; strict::Symbol = FFI_STRICT[])
    c = ffi_return_contract(rust_type; abi = abi)
    if c.known
        c.abi === :void && return Cvoid
        if c.abi === :by_value || c.abi === :pointer
            # The surface type; see [`ffi_return_symbol_or_throw`](@ref).
            return c.surface_type
        end
    end
    return _ffi_unsupported_return(rust_type, abi, ctx, strict, Any)
end

"""
    ffi_char_code_point(c) -> UInt32

The Unicode scalar value of a Julia `Char` (or of an integer already holding
one), as it must reach a Rust `char` slot. Julia stores a `Char` as left-aligned
UTF-8 code units, so its bit pattern is **not** the code point and
reinterpreting it would hand Rust a different character (#245).

Rejects anything that is not a Unicode scalar value: Rust's `char` has that as a
validity invariant, and constructing one from a surrogate or an out-of-range
value is undefined behaviour there.
"""
function ffi_char_code_point(c::AbstractChar)
    isvalid(c) || throw(RustError(
        "cannot pass $(repr(c)) to a Rust `char`: it is not a Unicode scalar value"))
    return UInt32(c)
end

ffi_char_code_point(x::Integer) = _ffi_checked_code_point(UInt32(x))

"""
    ffi_char_from_code_point(value) -> Char

The Julia `Char` a Rust `char` slot denotes — the inverse of
[`ffi_char_code_point`](@ref), and equally strict. A Rust `char` is always a
Unicode scalar value, so a slot that is not one did not come from a `char`; it
is refused rather than turned into an invalid `Char`.
"""
ffi_char_from_code_point(value::Integer) = Char(_ffi_checked_code_point(UInt32(value)))

function _ffi_checked_code_point(value::UInt32)
    isvalid(Char, value) || throw(RustError(
        "0x$(string(value, base = 16)) is not a Unicode scalar value and so is not a " *
        "valid Rust `char`: code points above 0x10ffff and the surrogate range " *
        "0xd800-0xdfff are excluded"))
    return value
end

"""
    ffi_slot_convert(::Type{T}, x)

Convert a Julia value into the C slot type `T` the contract recorded for its
position. Identity wherever the slot and the surface type agree; Rust `char`,
whose slot is a `UInt32` code point, is the one case that differs.

Used by the paths that convert at run time — monomorphized generics, which only
learn their argument types after specialization. The generators splice the same
conversion at macro-expansion time instead.
"""
ffi_slot_convert(::Type{UInt32}, x::AbstractChar) = ffi_char_code_point(x)
ffi_slot_convert(::Type{Any}, x) = x
ffi_slot_convert(::Type{T}, x) where {T} = convert(T, x)

# The spelling of the single C slot: the contract's own spelling (`:Csize_t`)
# when the slot and the surface type agree, the slot otherwise (`char`).
function _ffi_slot_expr(rust_type::AbstractString, c::FFIContract)
    slot = only(c.ccall_types)
    slot === c.surface_type || return ffi_type_expr(slot)
    return something(ffi_julia_symbol(rust_type), ffi_type_expr(slot))
end

function _ffi_unsupported_return(rust_type, abi, ctx, strict::Symbol, fallback)
    strict in (:error, :warn, :none) || throw(ArgumentError(
        "FFI_STRICT must be :error, :warn or :none, got :$strict"))
    strict === :none && return fallback
    detail = ffi_describe(rust_type; direction = :return, abi = abi)
    if strict === :error
        throw(RustError(
            "the FFI contract cannot describe the return type of `$ctx`: $detail. " *
            "Add a `::T` return annotation at the call site, change the Rust " *
            "signature to a supported type, or set " *
            "`RustCall.FFI_STRICT[] = :warn` to fall back to `Any` (see " *
            "https://github.com/AtelierArith/RustCall.jl/issues/276)."))
    end
    # Test and insert atomically: reading the set outside the lock let two
    # threads both see the context as new and warn twice — and raced with the
    # insert itself.
    first_time = lock(REGISTRY_LOCK) do
        key = String(ctx)
        key in _FFI_WARNED_CONTEXTS && return false
        push!(_FFI_WARNED_CONTEXTS, key)
        return true
    end
    if first_time
        @warn "the FFI contract cannot describe the return type of `$ctx`; \
               emitting `Any`, which is not a well-defined ccall return slot. \
               Set `RustCall.FFI_STRICT[] = :error` to make this fail instead." detail
    end
    return fallback
end

"""
    ffi_owned_string_return(c) -> Bool
    ffi_borrowed_string_return(c) -> Bool

Whether a return contract describes a lowered **owned** (`CRustString`,
`(ptr, len, cap)`) or **borrowed** (`CRustStr`, `(ptr, len)`) string buffer.

Every generator branches on these rather than on `return_abi == "string"`, on
`has_owned_string_helper`, or on the Rust spelling — the three vocabularies
#276 collapses. An owned contract also carries the `free_symbol` that releases
it, which is the half #246 and #249 are about.
"""
ffi_owned_string_return(c::FFIContract) = c.aggregate_type === CRustString
ffi_borrowed_string_return(c::FFIContract) = c.aggregate_type === CRustStr

"""
    ffi_signature_context(name, arg_types, return_type; owner = nothing) -> String

The human-readable signature an unsupported type is reported against:
`"Struct::method(i32, String) -> Vec<f64>"`.
"""
function ffi_signature_context(name::AbstractString, arg_types, return_type::AbstractString;
                               owner::Union{Nothing, AbstractString} = nothing)
    prefix = owner === nothing ? "" : string(owner, "::")
    args = join(arg_types, ", ")
    return string(prefix, name, "(", args, ") -> ", isempty(return_type) ? "()" : return_type)
end

# ============================================================================
# UTF-8 validity is checked on the Julia side (issue #246)
# ============================================================================

"""
    ffi_string_argument(value, arg_name, context) -> String

The `String` a `(ptr, len)` argument slot is built from, checked to be valid
UTF-8 before the pointer is handed to Rust (#246).

A Julia `String` is a byte vector: `String([0xff, 0xfe])` is a perfectly
ordinary value that is not UTF-8. The generated wrapper turns a string argument
into `slice::from_raw_parts` plus `String::from_utf8_lossy`, so an invalid byte
was silently replaced by U+FFFD and the Rust function ran on data the caller
never wrote — a wrong answer with no error anywhere. The `from_utf8_lossy` on
the Rust side stays as defence in depth (a `&str` built from invalid bytes is
undefined behaviour, and nothing may reach it); this is the check that turns
the same condition into a catchable Julia exception, at the call site, naming
the argument that carries the bad bytes.

`arg_name` is the parameter as the Rust signature spells it and `context` the
function or method it belongs to, so the message points at one argument of one
function rather than at "a string". A caller that has only the position — a
monomorphized generic, whose `FunctionInfo` records ABIs but not names — passes
an `Integer` instead, and the message says `argument #2`.
"""
ffi_string_argument(value, arg_name::AbstractString, context::AbstractString) =
    _ffi_string_argument(value, string("`", arg_name, "`"), context)

ffi_string_argument(value, position::Integer, context::AbstractString) =
    _ffi_string_argument(value, string("#", position), context)

function _ffi_string_argument(value, descriptor::AbstractString, context::AbstractString)
    s = String(value)
    isvalid(s) && return s
    bad = nothing
    for (i, c) in pairs(s)
        if !isvalid(c)
            bad = i
            break
        end
    end
    where = bad === nothing ? "" :
            " (first invalid byte at index $bad, 0x$(string(codeunit(s, bad), base = 16, pad = 2)))"
    throw(RustError(
        "argument $descriptor of `$context` is not valid UTF-8$where. Rust's " *
        "`&str` and `String` are UTF-8 by definition, and a Julia `String` is " *
        "a byte vector that need not be — the bytes would have been silently " *
        "replaced with U+FFFD on the Rust side, so the function would have run " *
        "on data you did not pass (#246). Fix the encoding before the call: " *
        "`isvalid(s)` says whether a string is UTF-8, and `String(transcode(" *
        "UInt8, transcode(UInt16, s)))` or an explicit re-encode from the bytes' " *
        "real encoding produces one that is. To send bytes that are not text at " *
        "all, take them as a `*const u8` plus a length on the Rust side; a " *
        "`&[u8]` slice argument is not lowered by the `#[julia]` pipeline."))
end

# By-value aggregates are opt-in (issue #245 item 3)
# ============================================================================

"""
    FFIByValue

Marker supertype for the `#[repr(C)]` mirror aggregates **RustCall itself
generates**: the `CResult_<fn>` / `COption_<fn>` structs the wrapper generators
emit next to a `Result`- or `Option`-returning function, in every flavour
(macro-expanded and source-emitted, crate and inline).

They need no registration at all, and must not depend on one: the generated
code may be precompiled into a downstream package, and a subtype relation is a
static property of the type — it survives because it *is* the type. (The
`ffi_by_value_layout` method table exists for the same reason, one level up: a
method is precompiled too. This is the cheaper answer for types RustCall itself
emits, because it needs no call at all.)
"""
abstract type FFIByValue end

"""
    ffi_by_value_layout(::Type{T}) -> Symbol

`:repr_c` when someone has asserted that `T` may cross the boundary **by
value**, `:unknown` otherwise. The registry of #245, expressed as a **method
table** rather than a container.

`is_supported_arg_type` used to be `isbitstype(T)`, and `ccall_arg_type` the
identity — so any isbits Julia struct or tuple was passed by value on the
assumption that its layout matches the Rust side's. Rust's default
`repr(Rust)` layout is explicitly unspecified (fields may be reordered, niches
exploited), so that assumption holds only until a rustc upgrade decides
otherwise, and then it is silent corruption rather than an error. This function
is the record of who asserted otherwise, and about which type.

# Why dispatch and not a `Set`

Because a registration has to survive precompilation. `register_ffi_struct` is
meant to be called at a package's top level, next to the struct it is about —
and a `push!` into a global that lives in **RustCall** happens during that
package's precompilation and is *not* replayed when the package is later loaded
from its cache. The assertion would hold in the session that compiled the
package and be gone in every session after it, with the by-value call failing
before it reached Rust.

A **method definition** is precompiled: `register_ffi_struct` defines
`ffi_by_value_layout(::Type{Point}) = :repr_c` in the module that owns `Point`,
so the method is stored in that module's cache image and reinstated on load,
exactly like any other method the package defines. Dispatch also expresses the
narrow and the wide assertion natively — `::Type{Point{Float64}}` for one
instantiation, `::Type{<:Point}` for all of them — which a keyed container has
to fake.

Withdrawal (`unregister_ffi_struct`) deletes the method it is about, and only
that one, so there is no exception list to keep in step with the table — and no
bookkeeping container of any kind beside it.
"""
ffi_by_value_layout(@nospecialize(::Type)) = :unknown

# RustCall's own boundary types mirror `#[repr(C)]` Rust definitions (see the
# comments beside each in `src/types.jl`), so the layout assertion #245 asks a
# user to make is one the package already makes about these. The parametric
# ones are asserted for *every* instantiation deliberately: `RustPtr{T}` is one
# pointer whatever `T` is.
ffi_by_value_layout(::Type{CRustResult}) = :repr_c
ffi_by_value_layout(::Type{CRustOption}) = :repr_c
ffi_by_value_layout(::Type{CRustString}) = :repr_c
ffi_by_value_layout(::Type{CRustStr}) = :repr_c
ffi_by_value_layout(::Type{CRustVec}) = :repr_c
ffi_by_value_layout(::Type{CRustSlice}) = :repr_c
ffi_by_value_layout(::Type{RustStr}) = :repr_c
ffi_by_value_layout(::Type{<:RustSlice}) = :repr_c
ffi_by_value_layout(::Type{<:RustPtr}) = :repr_c
ffi_by_value_layout(::Type{<:RustRef}) = :repr_c

"""
    _ffi_layout_signature(T) -> Type

The `ffi_by_value_layout` method signature `register_ffi_struct(T)` defines:
`Tuple{typeof(ffi_by_value_layout), Type{T}}`, for the one concrete type `T`
and nothing else. Reconstructed rather than remembered, so
`unregister_ffi_struct` can find a method a *previous* session defined and a
precompile cache restored.
"""
_ffi_layout_signature(@nospecialize(T::Type)) =
    Tuple{typeof(ffi_by_value_layout), Type{T}}

"""
    _ffi_layout_method(T) -> Union{Method, Nothing}

The `ffi_by_value_layout` method that `register_ffi_struct(T)` defined for
**exactly** `T`, or `nothing` when there is none.

Exactness is the point, twice over. A user registration is always for one
concrete type, but RustCall's own mirrors are asserted with covering methods
(`ffi_by_value_layout(::Type{<:RustPtr})`), and `which` alone would hand one of
those back — so a `register_ffi_struct` call could be elided as "already
asserted", or an `unregister_ffi_struct` could delete the package's own claim
about every `RustPtr{T}`. Comparing the signature to `_ffi_layout_signature`
means each operation sees only the assertion `register_ffi_struct(T)` itself
would make.

`invokelatest`, because the method may have been defined in this very world —
which is also what lets `ffi_by_value_registered` answer for a registration
made in the same top-level expression, with no bookkeeping on the side.
"""
function _ffi_layout_method(@nospecialize(T::Type))
    m = try
        Base.invokelatest(which, ffi_by_value_layout, (Type{T},))
    catch
        return nothing
    end
    return m.sig === _ffi_layout_signature(T) ? m : nothing
end

"""
    _ffi_registration_module(T) -> Module

Where the `ffi_by_value_layout` method for `T` is defined: the module that owns
`T`, so the method lands in **that** module's precompile cache and comes back
with it.

A type Julia itself owns (a `Tuple`, whose `parentmodule` is `Core`) has no
such home; the method goes to RustCall instead, and a registration of one from
a package's top level is therefore session-local. Register the struct rather
than the tuple when that matters.
"""
function _ffi_registration_module(@nospecialize(T::Type))
    owner = parentmodule(T)
    (owner === Core || owner === Base) && return @__MODULE__
    return owner
end

"""
    ffi_is_aggregate(T) -> Bool

Whether `T` is an *aggregate* at the C boundary — a struct with fields, or a
tuple — as opposed to a scalar whose ABI is fixed by its width.

Primitive types (`Int32`, `Float64`, a user `primitive type`), pointers and
zero-field singletons are not aggregates: there is nothing about them a layout
decision can change. Everything else has a field order, and Rust does not
promise one without `#[repr(C)]`.
"""
function ffi_is_aggregate(@nospecialize(T::Type))
    T <: Tuple && return true
    T <: Ptr && return false
    isconcretetype(T) || return false
    isprimitivetype(T) && return false
    isstructtype(T) || return false
    return fieldcount(T) > 0
end

"""
    register_ffi_struct(T::Type; repr_c::Bool = true) -> Type

Assert that values of `T` may be passed to and from Rust **by value**, because
the Rust type they correspond to is declared `#[repr(C)]` and its fields match
`T`'s in order and in type.

This is the opt-in issue #245 asks for. Without it, `@rust f(x)` with an
aggregate `x` raises rather than assuming the layouts agree: Rust's default
`repr(Rust)` layout is unspecified, so an unannotated Julia struct that "works"
today can be silently reordered by the next rustc.

The assertion is recorded as a **method** of `ffi_by_value_layout`, defined in
the module that owns `T`. Calling this at a package's top level therefore
survives precompilation — the method is stored in that package's cache image
and reinstated when it is loaded, in every later session:

```julia
module MyPkg
using RustCall

struct Point   # matches #[repr(C)] pub struct Point { x: f64, y: f64 }
    x::Float64
    y::Float64
end
RustCall.register_ffi_struct(Point)
end
```

You do **not** need this for:

- scalars, pointers, `Cstring`, `Char`, `Bool` — their ABI is their width;
- the struct wrappers RustCall generates from a `#[julia] struct`
  (`RustStructInfo`, `src/structs.jl`), which cross the boundary as an opaque
  handle, never as a field-by-field copy;
- RustCall's own `#[repr(C)]` mirrors: `CRustString`, `CRustSlice` and friends
  have `ffi_by_value_layout` methods here, and the `CResult_<fn>` /
  `COption_<fn>` aggregates the wrapper generators emit subtype `FFIByValue`.

`repr_c = false` is rejected: there is no layout to assert. The keyword exists
so the call site states what is being claimed.

# Concrete types only

`T` must be a concrete, immutable, `isbitstype` struct. A `UnionAll` or an
abstract type is rejected: instantiations of `Point{T}` do not share a layout —
a type parameter changes field sizes, alignment and even ABI register classes —
and subtypes of an `abstract type Shape{T}` share even less. Registering a
family would license values you never matched against a Rust struct, which is
the fail-open behaviour this opt-in exists to remove. Register each concrete
type you actually pass: `register_ffi_struct(Point{Float64})` says exactly that,
and says nothing about `Point{Int32}`.

See also `unregister_ffi_struct`, `ffi_by_value_registered`,
`ffi_by_value_layout`.
"""
function register_ffi_struct(@nospecialize(T::Type); repr_c::Bool = true)
    repr_c || throw(ArgumentError(
        "register_ffi_struct($T; repr_c = false) asserts nothing: a type may " *
        "only be passed by value when the Rust type it mirrors is declared " *
        "`#[repr(C)]`. Fix the Rust definition, or pass the value behind a " *
        "pointer instead."))
    T isa UnionAll && throw(ArgumentError(
        "register_ffi_struct($T): a `UnionAll` cannot be registered. Its " *
        "instantiations do not share a layout — a type parameter changes field " *
        "sizes, alignment and even ABI register classes — so asserting one for " *
        "the whole family would license `$T{...}` instantiations you never " *
        "matched against a Rust struct, which is the fail-open behaviour this " *
        "opt-in exists to remove. Register each concrete type you actually " *
        "pass, e.g. `register_ffi_struct($T{Float64})`."))
    (isconcretetype(T) && isstructtype(T)) || throw(ArgumentError(
        "register_ffi_struct($T): only a concrete struct type can be passed by " *
        "value — $T is $(isabstracttype(T) ? "abstract, and its subtypes share " *
                                             "no layout" : "not a concrete struct type"). " *
        "Register the concrete types you actually pass."))
    isbitstype(T) || throw(ArgumentError(
        "register_ffi_struct($T): only an `isbitstype` type can be passed by " *
        "value — $T is not one" *
        (ismutabletype(T) ? " (it is mutable; a mutable struct is a Julia heap " *
                            "object, and Rust must receive it behind a " *
                            "pointer)." : ".")))
    # The check and the method definition are **one** transaction under
    # `REGISTRY_LOCK`, paired with the one in `unregister_ffi_struct`. Split,
    # two tasks racing on the same type could both define the method, or an
    # unregister could land between them — finding no method, returning `false`,
    # and leaving the type enabled by the method the other task then installed
    # (#245 review). There is no bookkeeping beside the method table to keep in
    # step, because there is no bookkeeping.
    return lock(REGISTRY_LOCK) do
        # Skip only an *exact* duplicate. Defining the same method twice warns
        # under `--warn-overwrite=yes`, which `Pkg.test` sets; anything broader
        # that happens to cover `T` is a different assertion and must not
        # suppress this one.
        _ffi_layout_method(T) === nothing || return T
        Core.eval(_ffi_registration_module(T),
                  :($(GlobalRef(@__MODULE__, :ffi_by_value_layout))(::Type{$T}) =
                        $(QuoteNode(:repr_c))))
        return T
    end
end

"""
    unregister_ffi_struct(T::Type) -> Bool

Take back the `register_ffi_struct` assertion for `T`. Returns whether there was
one to take back.

It deletes the `ffi_by_value_layout` method that was defined for **exactly**
`T` — the narrow one for a concrete type, the `::Type{<:T}` one for a
`UnionAll` — and nothing else. So withdrawing `Point` after registering it
leaves any separate `Point{Float64}` assertion standing, and withdrawing
`Point{Float64}` does not disturb a `Point` assertion that covers its siblings.
An assertion made in a *previous* session (restored from a precompile cache) is
withdrawn just as well: the method is found by reconstructing its signature,
not by remembering it.

Deleting a method invalidates code that dispatched through it, so this is not
something to do in a loop; it is a correction, made by a test or by a user who
changed their mind. It runs under `REGISTRY_LOCK`, as one transaction with the
one in `register_ffi_struct`.
"""
function unregister_ffi_struct(@nospecialize(T::Type))
    # One transaction, paired with `register_ffi_struct`: see the comment there.
    return lock(REGISTRY_LOCK) do
        m = _ffi_layout_method(T)
        m === nothing && return false
        Base.delete_method(m)
        return true
    end
end

"""
    ffi_by_value_registered(T) -> Bool

Whether `T` carries a by-value assertion — a `ffi_by_value_layout` method
covering it, whether that method was defined in an earlier session or a moment
ago in this one.
"""
function ffi_by_value_registered(@nospecialize(T::Type))
    # `invokelatest`, and no fast path in front of it. A plain call would be
    # answered in the caller's world, which is stale in **both** directions: it
    # cannot see a method `register_ffi_struct` defined a moment ago, and — the
    # half that matters — it still sees one `unregister_ffi_struct` has already
    # deleted. Being stale-true is fail-open, which is the whole thing this
    # check exists to prevent, so the latest world is the only acceptable
    # answer. The cost lands only on aggregates that are not `FFIByValue`, next
    # to a dynamic `ccall`.
    return Base.invokelatest(ffi_by_value_layout, T) === :repr_c
end

"""
    ffi_by_value_allowed(T) -> Bool

Whether a value of `T` may cross the boundary by value: true for everything
that is not an aggregate, for RustCall's own generated mirrors (`FFIByValue`),
and for other aggregates only once asserted.
"""
function ffi_by_value_allowed(@nospecialize(T::Type))
    return !ffi_is_aggregate(T) || T <: FFIByValue || ffi_by_value_registered(T)
end

"""
    ffi_by_value_error(T, position) -> RustError

The error raised when an unregistered aggregate reaches the boundary by value.
`position` names where it appeared, e.g. `"argument 2"` or `"the return type"`.
"""
function ffi_by_value_error(@nospecialize(T::Type), position::AbstractString)
    fields = join(["$(fieldname(T, i))::$(fieldtype(T, i))" for i in 1:fieldcount(T)], ", ")
    return RustError(
        "cannot pass `$T` to Rust by value as $position: RustCall has no " *
        "layout assertion for it (#245). Rust's default `repr(Rust)` layout " *
        "is unspecified — field order and niche placement may change between " *
        "compiler versions — so matching `$T`'s fields ($fields) against a " *
        "Rust struct is a claim only you can make.\n" *
        "If the Rust side declares that struct `#[repr(C)]` and its fields " *
        "line up in order and in type, opt in with " *
        "`RustCall.register_ffi_struct($T)`. Otherwise pass the value behind " *
        "a pointer, or define the struct on the Rust side with `#[julia]` and " *
        "let RustCall generate the wrapper (`RustStructInfo`, `src/structs.jl`), " *
        "which crosses as an opaque handle. The supported-type matrix is in " *
        "the type-mapping documentation.")
end

"""
    ffi_check_by_value(R, arg_types)

Fail closed on any unregistered aggregate in a call's signature, before a
`ccall` is generated for it. Called from `call_rust_function`, the one runtime
entry point every `@rust` call goes through — not from the `@generated` body
below it, because a generated method is not re-generated when
`register_ffi_struct` is called later.
"""
function ffi_check_by_value(@nospecialize(R::Type), arg_types)
    ffi_by_value_allowed(R) || throw(ffi_by_value_error(R, "the return type"))
    for (i, T) in enumerate(arg_types)
        ffi_by_value_allowed(T) || throw(ffi_by_value_error(T, "argument $i"))
    end
    return nothing
end

