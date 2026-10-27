# RustCall.jl

**RustCall.jl** is a Foreign Function Interface (FFI) package for calling Rust code directly from Julia, inspired by [Cxx.jl](https://github.com/JuliaInterop/Cxx.jl).

> It's the last call for headache. 🦀

## Features

### Phase 1: C-Compatible ABI ✅
- **`@rust` macro**: Call Rust functions directly from Julia
- **`rust""` string literal**: Compile and load Rust code as shared libraries
- **`@irust` macro** (deprecated, see "Migrating from `@irust`"): Execute Rust code at function scope
- **Type mapping**: Automatic conversion between Rust and Julia types
- **Result/Option support**: Handle Rust's `Result<T, E>` and `Option<T>` types
- **String support**: Pass Julia strings to Rust functions expecting C strings
- **Compilation caching**: one artifact identity (`RustCall.ArtifactId` / `artifact_key`) keys every cached library, so a changed source, compiler, cfg set, dependency or toolchain rebuilds and nothing else does

### Phase 2: Runtime and Ownership ✅
- **Ownership types**: `RustBox`, `RustRc`, `RustArc`, `RustVec`, `RustSlice`
- **Array operations**: Indexing, iteration, Julia ↔ Rust conversion
- **Generics support**: Automatic monomorphization and type parameter inference
- **Error handling**: `RustError` exception type with `result_to_exception`
- **Function registration**: Register and cache compiled Rust functions

### Phase 6: External Crate Bindings (Maturin-like) ✅
- **`rustcall_julia_macros` crate**: The `#[julia]` attribute and its runtime
- **`@rust_crate` macro**: Generate Julia bindings for external Rust crates
- **Crate scanning**: Detect `#[julia]` marked functions and structs
- **Automatic building**: Build crates and generate Julia modules

## Installation

```julia
using Pkg
Pkg.add("RustCall")
```

RustCall.jl is registered in Julia's General registry. `Pkg.add("RustCall")` installs the package and builds the helper library used by ownership-related features.

For contributor work or local edits from a checkout:

```julia
using Pkg
Pkg.develop(path="/path/to/RustCall.jl")
```

**Requirements:**
- Julia 1.12 or later
- A Rust toolchain — **no system installation required**. RustCall depends on
  [RustToolChain.jl](https://github.com/AtelierArith/RustToolChain.jl), which
  uses the `rustc`/`cargo` on `PATH` when there is one and otherwise installs
  an isolated toolchain through Julia's Artifacts system. On Windows the
  artifact toolchain still needs the MSVC build tools and a Windows SDK for
  linking (see the RustToolChain.jl README).

Installing Rust yourself ([rustup.rs](https://rustup.rs/)) is optional; a
`rustc` on `PATH` is preferred over the artifact toolchain when both exist.

### Rebuilding Rust Helpers Library

The Rust helpers library is built during package installation. If ownership types such as `RustBox`, `RustRc`, `RustArc`, `RustVec`, or `RustSlice` are unavailable, rebuild it:

```julia
using Pkg
Pkg.build("RustCall")
```

Or from the command line:

```bash
julia --project -e 'using Pkg; Pkg.build("RustCall")'
```

This will compile the Rust helpers library that provides FFI functions for ownership types.

## Project Structure

- `src/`: RustCall implementation (`src/RustCall.jl` is the entry point)
- `test/`: package tests (`test/runtests.jl` includes feature tests)
- `docs/`: Documenter project and design notes
- `deps/`: Rust helper/runtime and proc-macro crates used by build/runtime flows
- `examples/`: runnable integration examples

## Included Examples

- `examples/MyExample.jl`: Julia package using inline `rust"""..."""` blocks
- `examples/SampleCrate.jl`: Julia package with an embedded Rust crate
  (`deps/sample_crate`) using `#[julia]`, bound with `write_bindings_to_file`,
  plus a `rust"""` block in `src/inline.jl` that coexists with those bindings
- `examples/RustCrateMacro.jl`: Julia package that binds a `#[julia]` crate
  with `@rust_crate ... submodule="Bindings"` while precompiling, plus a
  `rust"""` block in the same module — all three front doors coexisting
- `examples/SampleCratePyO3.jl`: Julia package with an embedded dual
  Julia/Python crate (`deps/sample_crate_pyo3`)
- `examples/pluto/hello.jl`: Pluto notebook-style walkthrough

## Quick Start

If you are running these examples from a source checkout of this repository, instantiate the project first:

```julia
using Pkg
Pkg.instantiate()
```

### 1. Define and Call Rust Functions (Simple Way)

```julia
using RustCall

# Use #[julia] attribute - no boilerplate needed!
rust"""
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

# Call directly - wrapper is auto-generated
add(10, 20)  # => 30
```

### 2. Traditional FFI (Full Control)

```julia
using RustCall

# Traditional way with explicit FFI markers
rust"""
#[no_mangle]
pub extern "C" fn multiply(a: i32, b: i32) -> i32 {
    a * b
}
"""

# Call with @rust macro and explicit types
@rust multiply(Int32(5), Int32(7))::Int32  # => 35
```

### 3. Migrating from `@irust`

!!! warning "Deprecated"
    `@irust` and `irust"..."` are deprecated
    ([#538](https://github.com/AtelierArith/RustCall.jl/issues/538)) and will be
    removed in a later minor release. They still work. Each expansion site logs
    one deprecation warning, and `--depwarn=error` makes the warning an error.

Anything an `@irust` snippet computes can be written as a `#[julia]` function
in a `rust"""..."""` block:

1. The snippet becomes the function **body**. Its trailing expression is the
   function's value, and statements, loops and `return` stay as they are.
2. Each `$name` (or `arg1`, `arg2`, …) becomes a **typed parameter**: the Rust
   type of the Julia value you passed (`Int64` → `i64`, `Int32` → `i32`,
   `Float64` → `f64`, `Bool` → `bool`, …).
3. The type the snippet evaluated to is written as the **return type**.
4. Define the block once, at top level, and call the generated Julia function
   wherever the snippet used to be.

`@irust` decided at run time what step 3 says, with several `rustc` runs per
new snippet. That is why it handled scalars only, why a function containing it
could not be inferred, and why `$name` was a textual substitution that reached
inside Rust string literals. A `#[julia]` function has none of these limits.
It is compiled once, its call is type-stable, and it handles `String`, slices,
`Result` / `Option` and `#[julia]` structs.

Each pair below computes the same value. `test/test_irust_deprecation.jl` checks
every pair.

**A captured expression.**

```julia
# before
compute_irust(x, y) = @irust("\$x * \$y + 10")
compute_irust(Int32(3), Int32(4))   # => 22

# after
rust"""
#[julia]
fn compute(x: i32, y: i32) -> i32 {
    x * y + 10
}
"""
compute(Int32(3), Int32(4))         # => 22
```

**No captured variable** (`irust"..."`), and **explicit arguments** (`arg1`, …).

```julia
# before
irust"40 + 2"                       # => 42
x = Int64(21)
@irust("arg1 * 2", x)               # => 42

# after
rust"""
#[julia]
fn answer() -> i64 {
    40 + 2
}

#[julia]
fn twice(arg1: i64) -> i64 {
    arg1 * 2
}
"""
answer()                            # => 42
twice(x)                            # => 42
```

**Statements and loops.** The body is unchanged.

```julia
# before
k = Int64(10)
@irust("let mut s = 0i64; for i in 0..\$k { s += i; } s")   # => 45

# after
rust"""
#[julia]
fn sum_below(k: i64) -> i64 {
    let mut s = 0i64;
    for i in 0..k {
        s += i;
    }
    s
}
"""
sum_below(k)                        # => 45
```

**The return type.** `@irust` asked rustc for it. Now you write it, and it is
the Julia result type.

```julia
# before
x = Int64(7); f = 3.5
@irust("\$x as f64")                       # => 7.0  :: Float64
@irust("if \$x > 0 { 1 } else { -1 }")     # => 1    :: Int64
@irust("\$f.is_finite()")                  # => true :: Bool
@irust("(\$f * \$f).sqrt()")               # => 3.5  :: Float64

# after
rust"""
#[julia]
fn as_float(x: i64) -> f64 {
    x as f64
}

#[julia]
fn sign_of(x: i64) -> i64 {
    if x > 0 { 1 } else { -1 }
}

#[julia]
fn finite(f: f64) -> bool {
    f.is_finite()
}

#[julia]
fn magnitude(f: f64) -> f64 {
    (f * f).sqrt()
}
"""
as_float(x)                         # => 7.0  :: Float64
sign_of(x)                          # => 1    :: Int64
finite(f)                           # => true :: Bool
magnitude(f)                        # => 3.5  :: Float64
```

A nested helper `fn` inside a snippet becomes a top-level function in the same
block. A snippet that used `$$` for a `macro_rules!` metavariable writes `$`
directly, since a `rust"""` block does no substitution. A panic stays a
catchable `RustCall.RustPanicError` (see "Panics, Visibility and Lifetime").
If you would rather call through the C ABI, write `#[no_mangle] pub extern "C"`
instead of `#[julia]` and call the function with `@rust name(args...)::T`.

### 4. Use External Crates

Leverage the Rust ecosystem with automatic Cargo integration:

```julia
rust"""
// cargo-deps: rand = "0.8"

use rand::Rng;

#[no_mangle]
pub extern "C" fn random_number() -> i32 {
    rand::thread_rng().gen_range(1..=100)
}
"""

@rust random_number()::Int32  # => random number 1-100
```

### 5. Rust Structs as Julia Objects

Define Rust structs and use them as first-class Julia types:

```julia
rust"""
#[julia]
pub struct Counter {
    value: i32,
}

impl Counter {
    pub fn new(initial: i32) -> Self {
        Self { value: initial }
    }

    pub fn increment(&mut self) {
        self.value += 1;
    }

    pub fn get(&self) -> i32 {
        self.value
    }
}
"""

counter = Counter(0)
increment(counter)
increment(counter)
get(counter)  # => 2
```

### More Examples

```julia
# Float operations
rust"""
#[no_mangle]
pub extern "C" fn circle_area(radius: f64) -> f64 {
    std::f64::consts::PI * radius * radius
}
"""
@rust circle_area(2.0)::Float64  # => 12.566370614359172

# Boolean functions
rust"""
#[no_mangle]
pub extern "C" fn is_even(n: i32) -> bool {
    n % 2 == 0
}
"""
@rust is_even(Int32(42))::Bool  # => true

# Multiple variables with @irust
function quadratic(a, b, c, x)
    @irust("\$a * \$x * \$x + \$b * \$x + \$c")
end
quadratic(1.0, 2.0, 1.0, 3.0)  # => 16.0 (x² + 2x + 1 at x=3)
```

### 6. Image Processing with Rust

Process images using Rust for performance-critical operations:

If you want to run this example locally, install `Images` first:

```julia
using Pkg
Pkg.add("Images")
```

```julia
using RustCall
using Images

# Define Rust grayscale conversion
rust"""
#[no_mangle]
pub extern "C" fn grayscale_image(pixels: *mut u8, width: usize, height: usize) {
    let slice = unsafe { std::slice::from_raw_parts_mut(pixels, width * height * 3) };
    for i in 0..(width * height) {
        let r = slice[i * 3] as f32;
        let g = slice[i * 3 + 1] as f32;
        let b = slice[i * 3 + 2] as f32;
        let gray = (0.299 * r + 0.587 * g + 0.114 * b) as u8;
        slice[i * 3] = gray;
        slice[i * 3 + 1] = gray;
        slice[i * 3 + 2] = gray;
    }
}
"""

# Process image data
pixels = vec(rand(UInt8, 256 * 256 * 3))
@rust grayscale_image(pointer(pixels), UInt(256), UInt(256))::Cvoid
```

### 7. External Crate Bindings (Maturin-like)

Generate Julia bindings for external Rust crates using `@rust_crate`:

**Rust side (external crate):**
```rust
// Cargo.toml needs: rustcall_julia_macros = "0.4"
use rustcall_julia_macros::julia;

#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[julia]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[julia]
impl Point {
    #[julia]
    pub fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }

    #[julia]
    pub fn distance(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
}
```

**Julia side:**
```julia
using RustCall

const MyCrate = @rust_crate "/path/to/my_crate"

MyCrate.add(Int32(1), Int32(2))  # => 3
p = MyCrate.Point(3.0, 4.0)
MyCrate.distance(p)  # => 5.0
```

Inside a function or other local scope, capture the return value from `@rust_crate`
and call through that binding:

```julia
function load_my_crate(crate_path)
    bindings = @rust_crate crate_path name="MyCrate"
    p = bindings.Point(3.0, 4.0)
    return bindings.add(Int32(1), Int32(2)), bindings.distance(p), p.x
end
```

## Type Mapping

RustCall.jl automatically maps Rust types to Julia types:

| Rust Type | Julia Type |
|-----------|------------|
| `i8`      | `Int8`     |
| `i16`     | `Int16`    |
| `i32`     | `Int32`    |
| `i64`     | `Int64`    |
| `u8`      | `UInt8`    |
| `u16`     | `UInt16`   |
| `u32`     | `UInt32`   |
| `u64`     | `UInt64`   |
| `f32`     | `Float32`  |
| `f64`     | `Float64`  |
| `bool`    | `Bool`     |
| `usize`   | `UInt`     |
| `isize`   | `Int`      |
| `()`      | `Cvoid`    |
| `*const u8` | `Cstring` / `String` |
| `*mut u8` | `Ptr{UInt8}` |

## Contents

For repository layout, bundled examples, benchmark commands, and contributor-oriented notes, see [Project Guide](project_guide.md).

```@contents
Pages = [
    "tutorial.md",
    "examples.md",
    "struct_mapping.md",
    "crate_bindings.md",
    "generics.md",
    "performance.md",
    "troubleshooting.md",
    "project_guide.md",
    "api.md",
    "reference/artifacts.md",
    "reference/ffi_contract.md",
    "reference/compilation.md",
    "reference/codegen.md",
    "reference/manifest.md",
    "reference/cargo.md",
    "reference/crates.md",
    "reference/hot_reload.md",
    "reference/pyo3.md",
    "reference/ownership.md",
    "reference/generics.md",
    "reference/errors.md",
    "reference/loading.md",
    "status.md",
]
Depth = 2
```
