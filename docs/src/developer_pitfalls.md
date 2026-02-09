# Developer Pitfalls

This page documents common Julia pitfalls that have caused bugs in this project.
Review this list when contributing new code.

## String Interpolation with Indexing

**Bug**: [#69](https://github.com/AtelierArith/RustCall.jl/issues/69)

In Julia, `"$var[i]"` does **not** index into `var`. It interpolates the value of
`var` and then appends the literal characters `[i]`. The correct form is
`"$(var[i])"`.

```julia
# WRONG — interpolates the whole array, then appends "[1]"
types = ["i32", "i64"]
s = "$types[1]"        # => "[\"i32\", \"i64\"][1]"

# CORRECT — indexes first, then interpolates the element
s = "$(types[1])"      # => "i32"
```

**Rule**: Always wrap complex expressions (indexing, field access, method calls)
in `$(...)` when interpolating into strings.

**CI check**: The `scripts/lint_interpolation.sh` script runs in CI and flags
`$identifier[` patterns. If it fails, review the flagged lines and add
parentheses where needed.

## Type Aliases

**Bug**: [#70](https://github.com/AtelierArith/RustCall.jl/issues/70)

Several Julia type names are aliases for the same underlying type. Adding
separate method specializations for aliased types causes a
`Method overwriting is not permitted during Module precompilation` error.

### Common Type Aliases

| Alias | Underlying Type | Notes |
|-------|----------------|-------|
| `Cvoid` | `Nothing` | `Cvoid === Nothing` is `true` |
| `Cstring` | `Ptr{UInt8}` | `Cstring === Ptr{UInt8}` is `true` |
| `Cwstring` | `Ptr{Cwchar_t}` | Platform-dependent character type |
| `Cuint` | `UInt32` | On most platforms |
| `Clong` | `Int64` | On 64-bit Linux/macOS; `Int32` on Windows |
| `Culong` | `UInt64` | On 64-bit Linux/macOS; `UInt32` on Windows |
| `Csize_t` | `UInt64` | On 64-bit platforms |

### How to Check

Before adding a method for a new type, verify it is not an alias:

```julia
julia> Cvoid === Nothing
true

julia> Cstring === Ptr{UInt8}
true
```

### How to Handle

Define the method for one canonical type and add a comment:

```julia
# Void type (Cvoid === Nothing in Julia, so this handles both)
julia_type_to_llvm_ir_string(::Type{Nothing}) = "void"
```

If you need to handle both names in user-facing code (e.g., dispatching on a
symbol or string), use a conditional check rather than separate methods:

```julia
if t == Cvoid || t == Nothing
    # handle void
end
```

## Platform-Dependent Type Sizes

Some C-interop types have different sizes on different platforms:

```julia
# 64-bit Linux/macOS
Clong === Int64
Culong === UInt64

# Windows (even 64-bit)
Clong === Int32
Culong === UInt32
```

When writing type-translation code, either:
1. Use the Julia alias (`Clong`) and let the platform determine the size, or
2. Explicitly check `sizeof(Clong)` if you need platform-specific behavior.
