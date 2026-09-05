# Generates `docs/src/type_contract.md` from the FFI contract itself
# (`src/ffi_contract.jl`), so the documented matrix cannot drift from the table
# generated code actually consults (#276, #245 item 4).
#
# Run automatically by `docs/make.jl`. The result is checked in so the page is
# reviewable in a diff.

using RustCall

const _MATRIX_HEADER = """
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

"""

const _MATRIX_FOOTER = """

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
"""

function _matrix_rows()
    rows = String[]
    for key in sort!(collect(keys(RustCall.FFI_TYPE_TABLE)))
        entry = RustCall.FFI_TYPE_TABLE[key]
        # Strings only have an ABI once the manifest says so; show the lowered
        # form, which is what a wrapper actually uses.
        abi = entry.abi === :unknown ?
              (entry.surface_type === RustCall.RustString ? "string" : "str") : ""
        arg = RustCall.ffi_argument_contract(key; abi = abi)
        ret = RustCall.ffi_return_contract(key; abi = abi, owner = "Owner")
        slots(c) = isempty(c.ccall_types) ? "—" :
                   join(("`" * string(t) * "`" for t in c.ccall_types), ", ")
        free = ret.free_symbol === nothing ? "—" : "`<owner>_free_rust_string`"
        push!(rows, string(
            "| `", key, "` | ", string(ret.abi), " | ", slots(arg), " | ", slots(ret),
            " | `", string(ret.surface_type), "` | ", string(ret.ownership), " | ",
            free, " |"))
    end
    return rows
end

function generate_type_matrix(path)
    table = String[
        "| Rust | ABI (return) | argument slots | return slot | Julia | ownership (return) | released by |",
        "| ---- | ------------ | -------------- | ----------- | ----- | ------------------ | ----------- |",
    ]
    append!(table, _matrix_rows())
    open(path, "w") do io
        print(io, _MATRIX_HEADER)
        println(io, join(table, "\n"))
        print(io, _MATRIX_FOOTER)
    end
    return path
end
