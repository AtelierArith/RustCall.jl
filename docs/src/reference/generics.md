# Generics and `#[julia]` functions

The generic function registry and monomorphization through
`rustcall-extract specialize`, and the Julia wrappers generated for `#[julia]`
free functions (Result/Option aware). See [Generics](../generics.md) for the
user-facing guide.

## Generics (`src/generics.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "generics.jl")]
```

## `#[julia]` functions (`src/julia_functions.jl`)

### Strings in `#[julia]` functions

`#[julia]` free functions may take `String` / `&str` arguments and return
`String` / `&str` (#242). The generated `extern "C"` wrapper — `rustcall_<fn>`,
emitted next to the function, which is itself left untouched (#279) —
receives every
string as a `(ptr, len)` UTF-8 byte pair (no NUL terminator, embedded NULs
allowed), returns `String` as an owned buffer that the Julia wrapper copies
and releases through `<fn>_free_rust_string`, and returns `&str` as a
borrowed view that is copied immediately. The Julia wrapper accepts any
`AbstractString` and returns a `String`; this works for inline `rust\"\"\"`
blocks and for `@rust_crate` alike. `String` inside `Result` / `Option` is
not supported yet.

```julia
rust\"\"\"
#[julia]
pub fn shout(input: String) -> String { input.to_uppercase() }
\"\"\"
shout("hello")  # "HELLO"
```

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "julia_functions.jl")]
```
