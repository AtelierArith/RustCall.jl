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
