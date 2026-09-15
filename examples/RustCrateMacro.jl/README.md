# RustCrateMacro.jl

A Julia **package** that puts RustCall's three front doors in one place and
checks that they work together:

1. a Rust crate annotated with **`#[julia]`** (`rustcall_julia_macros`), under
   [`deps/macro_crate`](./deps/macro_crate/) — the shape
   [`../SampleCrate.jl`](../SampleCrate.jl) uses;
2. the **`@rust_crate` macro** in `src/RustCrateMacro.jl`, which scans and
   builds that crate and defines the generated `Bindings` submodule while the
   package is **precompiled** — no `deps/build.jl`, no generated file, the
   shape [`../RustCrateMacroPyO3Only.jl`](../RustCrateMacroPyO3Only.jl) uses;
3. an inline **`rust"""` block** (the `@rust_str` macro) in the same file,
   which compiles a second, independent library — the shape
   [`../MyExample.jl`](../MyExample.jl) uses.

The point is not any one front door but their **coexistence**: the crate's
items (`add`, `shout`, `Point`, …) and the block's (`inline_hypot`,
`inline_join`) are all callable from one package, and `inline_norm(p::Point)`
composes them — a `Point` built by the `@rust_crate` bindings, passed to the
inline library's arithmetic.

This is the `#[julia]` counterpart of `../RustCrateMacroPyO3Only.jl`: there the
macro binds a PyO3-only crate (no `#[julia]` anywhere); here it binds the
common case, a crate that carries `#[julia]`.

## Layout

```
RustCrateMacro.jl/
├── Project.toml
├── deps/
│   └── macro_crate/                 # Rust: a #[julia] crate
│       ├── Cargo.toml               #   cdylib, depends on rustcall_julia_macros
│       └── src/lib.rs               #   #[julia] fns, Result/Option, a struct
├── src/
│   └── RustCrateMacro.jl            # @rust_crate + rust""" + Julia wrappers
└── test/runtests.jl                 # Pkg.test
```

There is no `deps/build.jl` and no `src/generated/`: `@rust_crate` generates the
bindings module in memory, straight into the package's precompile image, and
builds the crate under its own `target/`.

The example is **self-contained**: everything it builds and tests is inside
this directory. The only reference outside it is the `rustcall_julia_macros`
path dependency in `deps/macro_crate/Cargo.toml`
(`../../../../deps/rustcall_julia_macros`), because it is not on crates.io yet.
`rustcall_julia_macros` is the attribute/runtime crate this checkout publishes
for `#[julia]` crates: a normal library — not the proc macro — that re-exports
the attribute from the proc-macro crate `rustcall_julia_macros_impl` and carries
the runtime state the generated wrappers link against.

## The three lines

```julia
module RustCrateMacro

using RustCall

# 1. the crate with #[julia]
@rust_crate joinpath(@__DIR__, "..", "deps", "macro_crate") submodule="Bindings"
using .Bindings: add, multiply, shout, join_repeat, Point, translate, norm

# 2. the inline block
rust"""
#[julia]
fn inline_hypot(a: f64, b: f64) -> f64 {
    (a * a + b * b).sqrt()
}
"""

# 3. the two joined
inline_norm(p::Point)::Float64 = inline_hypot(p.x, p.y)

end
```

`submodule="Bindings"` is what **defines** the generated module in this module,
as `RustCrateMacro.Bindings`, and therefore what makes the `using .Bindings`
line possible; it is the option a package wants (#339). Without it the module
still exists, hidden inside this one, and is reached only through the value the
macro returns. See `../RustCrateMacroPyO3Only.jl` for the full discussion.

The inline block uses `inline_*` names on purpose. A `rust"""` block in the
same module that declares a name the crate exports shadows that bare name, and
two `rust"""` blocks in one module that export the same name from different
libraries are refused (#250). Keeping the namespaces disjoint lets this package
re-export both. The test suite then checks the shared-name case deliberately:
it defines a second `add` (returning `(a + b) * 1000`) in a scratch module and
verifies that it and the crate's `add` each reach their own library.

## Run the tests

```bash
cd examples/RustCrateMacro.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.test()'
```

`Pkg.develop(path="../..")` uses the RustCall of this checkout; with a
registered RustCall in the range this package's `[compat]` admits —
**0.4.x**, `RustCall = "0.4"` — `Pkg.instantiate()` is enough. (`@rust_crate`'s
`submodule=` option is older — 0.3.1 introduced it — but the examples are
pinned to the version of this release.) There is no build step to run: the first
`using` (which `Pkg.test()` performs) precompiles the package, which builds the
crate.

The `Examples` workflow runs the Julia suite above (job
`Example - RustCrateMacro.jl`); its `Pkg.test()` builds the crate through
`@rust_crate` but does **not** run the crate's `#[cfg(test)]` unit tests. Run
those separately:

```bash
cd deps/macro_crate && cargo test
```

## Usage

```julia
using RustCrateMacro

# from the crate, through @rust_crate
add(Int32(2), Int32(3))             # 5
multiply(2.0, 3.0)                  # 6.0
shout("hello")                      # "HELLO"
join_repeat("a", "b", "-", UInt32(2))  # "a-b-a-b"

p = Point(3.0, 4.0)
p.x, p.y                            # 3.0, 4.0
norm(p)                             # 5.0
translate(p, 1.0, -1.0)             # &mut self: mutates p

safe_divide(10, 4)                  # 2.5; safe_divide(1, 0) throws DivideError
safe_sqrt(16)                       # 4.0;  safe_sqrt(-1) === nothing

# from the inline rust""" block
inline_hypot(3.0, 4.0)              # 5.0
inline_join("a", "b")               # "a-b"

# the two joined
inline_norm(Point(3.0, 4.0))        # 5.0
```

## Notes

- **`@rust_crate` builds at precompile time.** The first `using` (or
  `Pkg.precompile()`) needs a Rust toolchain; later sessions load the cached
  library, and `RustCall.clear_cache()` or a change to the crate makes the
  package's cache stale so the next `using` rebuilds.
- **The crate cannot tell which front door binds it.**
  `deps/macro_crate` is interchangeable with `../SampleCrate.jl/deps/sample_crate`;
  the difference is only `@rust_crate` in `src/` versus `write_bindings_to_file`
  in `deps/build.jl`.
- **`Libdl` is not among this package's dependencies.** The generated module
  reaches it through RustCall (`import RustCall.Libdl`), so a package that uses
  `@rust_crate` needs RustCall alone.
- **The inline block is a second, independent library.** It is not part of the
  crate and does not see its symbols; the composition happens in Julia, in
  `inline_norm`.
