# The FFI type contract

Every decision of the form *"what does this Rust type mean at the C boundary?"*
is answered in one place, `src/ffi_contract.jl`. Wrapper generation, argument
conversion, return-slot selection and the choice of release symbol all read this
one table (issue #276); there is no second table to disagree with it and no
fallback guess when it has no answer.

## What the contract records

For a Rust type spelling, in a direction (argument or return), the contract
gives:

* the **C ABI form** — by value, behind a pointer, as a `(ptr, len)` pair, as a
  `(ptr, len, cap)` triple, or nothing at all for the unit type;
* the **`ccall` slots** that form occupies, which differ by direction: a
  multi-word value is expanded into separate *argument* slots but returned as a
  single `#[repr(C)]` aggregate, because a `ccall` has exactly one return type;
* the **Julia surface type** a caller sees;
* **ownership** — who must release the memory a slot points at — and, when a
  release is required, the **symbol that performs it**.

```julia
julia> RustCall.ffi_return_contract("String"; abi = "string", owner = "shout")
```

gives `abi = :ptr_len_cap`, one `CRustString` return slot, a `RustString`
surface type, `:owned_by_rust` ownership and the free symbol
`shout_free_rust_string` — which is exactly what the generated wrapper calls.

## The manifest decides, not the spelling

A Rust `String` can cross the boundary in more than one shape, so the *spelling*
alone never selects one. The manifest column produced by `rustcall-extract`
(`Arg.abi`, `Function.return_abi`, `Method.return_abi`, `Field.abi`) is the
authority, and the contract takes it verbatim as the `abi` keyword. A bare
`"String"` with no column is deliberately **unknown**: it fails closed rather
than describing a lowering the wrapper may not have performed.

## Unknown types fail closed

A spelling the contract does not cover has no Julia type. `RustCall.FFI_STRICT[]`
says what generated code does then:

| value    | behaviour |
| -------- | --------- |
| `:error` | raise a `RustError` naming the signature (the default) |
| `:warn`  | warn once per signature and emit `Any` |
| `:none`  | emit `Any` silently |

`Any` in a `ccall` slot was never well defined, so `:warn` and `:none` exist
only to get an existing crate building again while its unsupported types are
dealt with. `write_bindings_to_file(...; strict = :warn)` selects it per call.

## Supported types

Generated from `RustCall.FFI_TYPE_TABLE` and `RustCall.ffi_describe`; do not
edit by hand.

| Rust | ABI (return) | argument slots | return slot | Julia | ownership (return) | released by |
| ---- | ------------ | -------------- | ----------- | ----- | ------------------ | ----------- |
| `&str` | ptr_len | `Ptr{UInt8}`, `UInt64` | `RustCall.CRustStr` | `RustCall.RustStr` | borrowed | — |
| `()` | void | — | — | `Nothing` | none | — |
| `String` | ptr_len_cap | `Ptr{UInt8}`, `UInt64` | `RustCall.CRustString` | `RustCall.RustString` | owned_by_rust | `<owner>_free_rust_string` |
| `bool` | by_value | `Bool` | `Bool` | `Bool` | none | — |
| `c_char` | by_value | `Int8` | `Int8` | `Int8` | none | — |
| `c_double` | by_value | `Float64` | `Float64` | `Float64` | none | — |
| `c_float` | by_value | `Float32` | `Float32` | `Float32` | none | — |
| `c_int` | by_value | `Int32` | `Int32` | `Int32` | none | — |
| `c_long` | by_value | `Int64` | `Int64` | `Int64` | none | — |
| `c_longlong` | by_value | `Int64` | `Int64` | `Int64` | none | — |
| `c_uint` | by_value | `UInt32` | `UInt32` | `UInt32` | none | — |
| `c_ulong` | by_value | `UInt64` | `UInt64` | `UInt64` | none | — |
| `c_ulonglong` | by_value | `UInt64` | `UInt64` | `UInt64` | none | — |
| `char` | by_value | `UInt32` | `UInt32` | `Char` | none | — |
| `f32` | by_value | `Float32` | `Float32` | `Float32` | none | — |
| `f64` | by_value | `Float64` | `Float64` | `Float64` | none | — |
| `i128` | by_value | `Int128` | `Int128` | `Int128` | none | — |
| `i16` | by_value | `Int16` | `Int16` | `Int16` | none | — |
| `i32` | by_value | `Int32` | `Int32` | `Int32` | none | — |
| `i64` | by_value | `Int64` | `Int64` | `Int64` | none | — |
| `i8` | by_value | `Int8` | `Int8` | `Int8` | none | — |
| `isize` | by_value | `Int64` | `Int64` | `Int64` | none | — |
| `str` | ptr_len | `Ptr{UInt8}`, `UInt64` | `RustCall.CRustStr` | `RustCall.RustStr` | borrowed | — |
| `u128` | by_value | `UInt128` | `UInt128` | `UInt128` | none | — |
| `u16` | by_value | `UInt16` | `UInt16` | `UInt16` | none | — |
| `u32` | by_value | `UInt32` | `UInt32` | `UInt32` | none | — |
| `u64` | by_value | `UInt64` | `UInt64` | `UInt64` | none | — |
| `u8` | by_value | `UInt8` | `UInt8` | `UInt8` | none | — |
| `usize` | by_value | `UInt64` | `UInt64` | `UInt64` | none | — |

### Raw pointers

`*const T` and `*mut T` are accepted for every `T` and resolved recursively, so
`*const *mut i32` is `Ptr{Ptr{Int32}}`. A pointee the contract cannot map — an
opaque handle, or a multi-word type with no single-word C form — degrades to
`Ptr{Cvoid}`, which is still a well-defined slot.

Ownership of a raw pointer is **not** derivable from its spelling: a generated
constructor returns a `Box::into_raw` handle Julia must free, while another
`*mut T` may point into memory Rust keeps. The contract answers `:unknown` and a
consumer that has the metadata states it:

```julia
RustCall.ffi_return_contract("*mut Point"; ownership = :transferred_to_julia,
                             free_symbol = "Point_free")
```

Declaring an owned position without naming the symbol that releases it is an
`ArgumentError`: an owned value with no way to free it is the shape of #246 and
#249, and the contract refuses to record one.

### Slot and surface can differ

The `ccall` slot is not always the type a caller sees. Rust `char` is the case
in the table above: it crosses as a `UInt32` Unicode scalar value, while the
Julia surface type is `Char` — whose bit pattern is left-aligned UTF-8 and
therefore *not* the code point. RustCall converts, in one place
(`ccall_return_type` / `convert_return` and their argument counterparts in
`src/codegen.jl`), so no generated call site carries the conversion and no
position can reinterpret one for the other. A slot that is not a Unicode scalar
value — above `0x10FFFF`, or in the surrogate range — is refused rather than
turned into an invalid `Char`.

### 128-bit integers on Windows

`i128` / `u128` are in the contract and map to `Int128` / `UInt128`, but they do
**not** round-trip on `x86_64-pc-windows-msvc`: MSVC has no native 128-bit
integer type, so Rust and Julia disagree on how to pass one across `extern "C"`
there (rust-lang/rust#54341). This is a platform ABI mismatch, not a mapping
choice — no Julia-side type can fix it. Split the value into two `u64`s, or pass
it behind a pointer, if the code must run on Windows.

### Path qualifiers

`core::primitive::i32` and `std::primitive::i32` resolve like `i32`, rooted
(`::core::primitive::i32`) or not. No other qualifier is stripped: an
unqualified last segment is not evidence, so `mycrate::i32` — which may be a
type alias with a completely different layout — stays unknown.

### Types the contract deliberately refuses

`Vec<T>`, `HashMap`, `Box`, `Rc`, `Arc`, `Cow` and any user type not listed
above have no C representation RustCall can derive. Pass them behind a pointer
(`*mut MyType`), or expose a `#[julia]` struct whose accessors return supported
types.

### String arguments must be valid UTF-8

A Julia `String` is a byte vector, and `String([0xff, 0xfe])` is a perfectly
ordinary value that is not UTF-8. Rust's `&str` and `String` are UTF-8 by
definition, so the two are not the same domain, and passing one to the other is
checked rather than assumed (issue
[#246](https://github.com/AtelierArith/RustCall.jl/issues/246)):

```julia
rust"""
#[julia]
pub fn shout(name: &str) -> String { name.to_uppercase() }
"""

shout("héllo")                  # "HÉLLO"
shout(String([0xff, 0xfe]))
# ERROR: RustError: argument `name` of `shout` is not valid UTF-8 (first
# invalid byte at index 1, 0xff). ...
```

The error names the argument by the name the Rust signature gives it, the
function it belongs to, and the first byte that is wrong. Struct methods take
the same path.

Without the check the bytes reached `String::from_utf8_lossy` in the generated
wrapper, which **replaces** each invalid byte with U+FFFD — the Rust function
then ran on data the caller never passed, and returned a wrong answer with no
error anywhere. That `from_utf8_lossy` is still there as defence in depth,
because a `&str` built from invalid bytes is undefined behaviour and nothing
may reach it; the Julia-side check is what turns the condition into a catchable
exception at the call site.

Fixing the encoding is the Julia-side answer when the value *is* text:
`isvalid(s)` says whether a string is UTF-8, and `transcode` (or an explicit
re-encode from whatever the bytes really are) produces one that is. To send
bytes that are **not** text at all, take them on the Rust side as a
`*const u8` plus a length — a `&[u8]` slice argument is not lowered by the
`#[julia]` pipeline, so there is no `Vec{UInt8}` argument to pass.

## Passing a Julia struct to Rust by value is opt-in

A Julia struct is not a C type. `@rust f(p)` with an `isbits` struct `p` used to
copy its fields straight into the argument registers on the assumption that the
Rust struct on the other side has the same layout — but Rust's default
`repr(Rust)` layout is **explicitly unspecified**: the compiler may reorder
fields and exploit niches, and is free to change its mind between versions. An
unannotated struct that "works" today is a silent miscompile waiting for a
toolchain upgrade, which is why RustCall refuses it (issue
[#245](https://github.com/AtelierArith/RustCall.jl/issues/245)):

```julia
struct Point
    x::Float64
    y::Float64
end

@rust process_point(Point(3.0, 4.0))::Float64
# ERROR: RustError: cannot pass `Point` to Rust by value as argument 1:
# RustCall has no layout assertion for it (#245). ...
```

Declare the Rust struct `#[repr(C)]` — which *does* fix the field order — and
record the claim once:

```julia
@register_ffi_struct Point

@rust process_point(Point(3.0, 4.0))::Float64   # 25.0
```

`register_ffi_struct` asserts that the corresponding Rust type is `#[repr(C)]`
and that its fields line up with the Julia struct's in order and in type.
RustCall cannot check that for you; the call is where you take responsibility
for it. The assertion is recorded as a **method** of
`RustCall.ffi_by_value_layout`.

At a package's top level, use the macro:

```julia
@register_ffi_struct Point
@register_ffi_struct Tuple{Int32, Float64}
```

It expands in the *calling* module, so Julia stores the method in that module's
precompile cache and reinstates it on load, like any other method the package
defines. The function form, `register_ffi_struct(Point)`, defines the method in
`parentmodule(T)` — the same thing for a struct the package itself defines, but
for a type Julia owns (a `Tuple`, whose `parentmodule` is `Core`) it lands in
RustCall, and a cross-module mutation of a dependency is not replayed from a
downstream package's cache. Keep the function for the REPL, a script, or inside
a function; use the macro when the registration has to survive precompilation.

Registration is for **concrete types only**. `register_ffi_struct(Point)` on a
parametric struct, or on an abstract type, is an error: instantiations of
`Point{T}` do not share a layout — a type parameter changes field sizes,
alignment and even ABI register classes — and subtypes of an abstract family
share even less, so a family-wide assertion would license values you never
matched against a Rust struct. Register each concrete type you actually pass;
`register_ffi_struct(Point{Float64})` says exactly that, and says nothing about
`Point{Int32}`. `RustCall.unregister_ffi_struct(T)` withdraws an assertion, and
`repr_c = false` is rejected — without `#[repr(C)]` there is nothing to assert.

You do **not** need it for:

- scalars, pointers, `Cstring`, `Char` and `Bool` — their ABI is their width;
- the struct wrappers RustCall generates from a `#[julia] struct` (see
  [Struct mapping](struct_mapping.md)), which cross the boundary as an opaque
  handle rather than as a field-by-field copy;
- RustCall's own `#[repr(C)]` mirrors: `CRustString`, `CRustSlice` and friends
  have `ffi_by_value_layout` methods written in the package itself — including
  covering ones such as `::Type{<:RustPtr}`, which is a claim RustCall may make
  about its own types (a `RustPtr{T}` really is one pointer whatever `T` is)
  and which `register_ffi_struct` will not make on your behalf. The
  `CResult_<fn>` / `COption_<fn>` aggregates the wrapper generators emit are
  subtypes of `RustCall.FFIByValue`, an assertion that needs no call at all.

If the Rust struct is not `#[repr(C)]`, do not register it. Pass the value
behind a pointer, or define it with `#[julia]` and let RustCall generate the
handle-based wrapper.

## A return annotation may not contradict the manifest

`::T` at a call site exists to supply a return type RustCall does not know. When
the manifest *does* record one, a differing annotation is an error rather than
an override — reading a 32-bit return slot as a `Float64` is undefined
behaviour, not a cast:

```julia
rust"""
#[julia]
pub fn double(a: i32) -> i32 { a * 2 }
"""

@rust double(Int32(21))            # Int32(42) — the manifest decides
@rust double(Int32(21))::Int32     # Int32(42) — agreeing is fine
@rust double(Int32(21))::Float64
# ERROR: RustError: return type annotation `::Float64` on `@rust double(...)`
# disagrees with the manifest, which records `Int32` ...
```

Convert on the Julia side if you wanted a `Float64`.

Agreement is *the same `ccall` return slot*, not the same Julia type, because
the manifest records the slot while an annotation names the surface type. Rust
`char` is a `UInt32` code point in the slot and a `Char` on the surface, so
`::Char` and `::UInt32` both agree with a `-> char` and `::Int32` does not.
