# SampleCrate.jl

A Julia **package** with a Rust crate embedded under `deps/sample_crate/`,
built and tested with `Pkg` like any other Julia package. It is the
package-shaped counterpart of loading a crate ad hoc with `@rust_crate`, and it
follows RustCall's documented workflow for packages
([Precompilation Support](https://atelierarith.github.io/RustCall.jl/precompilation/)).

The example is **self-contained**: everything it builds and tests is inside
this directory. The one reference outside it is the `rustcall_julia_macros` path
dependency in `deps/sample_crate/Cargo.toml` (`../../../../deps/rustcall_julia_macros`,
the proc-macro crate of this checkout), because `rustcall_julia_macros` is not on
crates.io yet.

## Layout: Rust and Julia in separate files

```
SampleCrate.jl/
├── Project.toml
├── deps/
│   ├── build.jl                  # Pkg.build: cargo build + write the bindings
│   ├── sample_crate/             # Rust: the implementation
│   │   ├── Cargo.toml
│   │   └── src/lib.rs            #   #[julia] fns, structs and impl blocks
│   └── lib/                      # the compiled library (git-ignored)
├── src/
│   ├── SampleCrate.jl            # hand-written Julia (wrappers, docstrings, exports)
│   └── generated/Bindings.jl     # written by deps/build.jl (git-ignored)
└── test/runtests.jl              # Pkg.test
```

This is the layout the documentation prescribes (`deps/<crate>/`, `deps/lib/`,
`src/generated/`). No file contains both languages: `lib.rs` is plain Rust with
`#[julia]` attributes, `SampleCrate.jl` is plain Julia. The bridge is the
generated module `SampleCrate.Bindings`, produced from the crate by
`RustCall.write_bindings_to_file` together with a copy of the compiled library
under `deps/lib/`. Both are build outputs and are not committed.

## Run the tests

From this directory, with the RustCall of this checkout:

```bash
cd examples/SampleCrate.jl
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.test()'
```

or from the repository root, `julia --project=examples/SampleCrate.jl -e 'using Pkg; Pkg.develop(path="."); Pkg.test()'`.

With a registered RustCall (`Pkg.add("RustCall")`) the `Pkg.develop` step is
unnecessary: `Pkg.instantiate()` resolves it.

`Pkg.test()` — and a plain `using SampleCrate` — work from a fresh checkout:
when `src/generated/Bindings.jl` does not exist yet, loading the package runs
`deps/build.jl` once. After editing the Rust crate, regenerate explicitly:

```julia
using Pkg
Pkg.build("SampleCrate")
```

The same tests run in CI for every push (the `Examples` workflow).

## Usage

```julia
using SampleCrate

add(Int32(2), Int32(3))            # 5
fibonacci(UInt32(10))              # 55
shout("hello")                     # "HELLO"

p = Point(3.0, 4.0)
p.x, p.y                           # 3.0, 4.0 — field access
distance_from_origin(p)            # 5.0
translate(p, 1.0, -1.0)            # &mut self: mutates p
distance(p, Point(0.0, 0.0))       # Julia-side helper on top of distance_to

c = Counter(Int32(10))
increment(c); value(c)             # 11
reset!(c); value(c)                # 0
```

### What the Julia side adds

`src/SampleCrate.jl` re-exports the generated bindings and adds a thin idiomatic
layer, which is what a real package would do:

| Rust | generated binding | Julia wrapper in `SampleCrate` |
|------|-------------------|--------------------------------|
| `fn safe_divide(f64, f64) -> Result<f64, i32>` | `Bindings.safe_divide` → `RustResult{Float64, Int32}` | `safe_divide(a, b)` → `Float64`, throws `DivideError` on `Err` |
| `fn parse_positive(i32) -> Result<u32, i32>` | `RustResult{UInt32, Int32}` | `parse_positive(n)` → `UInt32`, throws `DomainError` |
| `fn parse_int(&str) -> Result<i32, i32>` | `RustResult{Int32, Int32}` | `parse_int(s)` → `Int32`, throws `ArgumentError` |
| `fn safe_sqrt(f64) -> Option<f64>` | `RustOption{Float64}` | `safe_sqrt(x)` → `Float64` or `nothing` |
| `fn find_positive(i32, i32) -> Option<i32>` | `RustOption{Int32}` | `find_positive(a, b)` → `Int32` or `nothing` |
| `fn first_char(String) -> Option<u32>` | `RustOption{UInt32}` | `first_char(s)` → `Char` or `nothing` |
| `Point::distance_to(&self, x, y)` | `distance_to(p, x, y)` | `distance(p, q)` |
| `Counter::get` / `Counter::reset` | `Bindings.get` / `Bindings.reset` | `value(c)` / `reset!(c)` (no shadowing of `Base.get` / `Base.reset`) |

The raw `RustResult` / `RustOption` values stay reachable through
`SampleCrate.Bindings` for callers that want them.

## Notes

- `deps/build.jl` is `RustCall.write_bindings_to_file(crate, "src/generated/Bindings.jl"; relative_lib_path = "../../deps/lib")`. The generated module loads the library relative to its own location, so the built package is self-contained and precompiles normally; the module opens a private copy of the library, never the file in `deps/lib` itself, so a rebuild can always overwrite it (also on Windows).
- `deps/sample_crate` is a trimmed twin of RustCall's own test fixture `test/fixtures/sample_crate`: the fixture carries extra `#[julia]` items the test suite needs (`panicky_*`, `Divider`, `PanicCounter`, `shadow_*`); this crate has exactly what the package exports.
- The crate builds and tests on its own: `cd deps/sample_crate && cargo test`.
- A static method (no `self`) is called with the type first: `shout(Labeler, "hi")` for `Labeler::shout`. The crate also has a free `fn shout`, which keeps the bare `shout("hi")`; the two never collide (#323).
