# RustCall.jl

**RustCall.jl** lets you write Rust inside Julia and call it like a Julia
function. It compiles the Rust for you, loads it into the running session, and
converts arguments and results on both sides. It is inspired by
[Cxx.jl](https://github.com/JuliaInterop/Cxx.jl).

> It's the last call for headache. 🦀

```julia
using RustCall

rust"""
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

add(10, 20)  # => 30
```

You do not need to know Rust to start, and you do not need to install it:
RustCall obtains a Rust toolchain on its own when there is none on your `PATH`.

## Who this manual is for

The manual assumes you are comfortable in Julia. It does not assume Rust.

- **New to Rust?** Read [Rust for Julia Users](rust_primer.md) (ten minutes),
  then the [Tutorial](tutorial.md).
- **Know some Rust already?** Start at the [Tutorial](tutorial.md) and skim.
- **Building a package on RustCall?** Read
  [Safe Rust/Julia Integration](integration_guide.md) and
  [External Crate Bindings](crate_bindings.md).
- **Want to know how it works, or to contribute?** Read
  [How RustCall Calls Rust](internals.md).

## Why call Rust from Julia

- **Reuse the Rust ecosystem.** Parsers, codecs, cryptography, data
  structures and numerical kernels published on [crates.io](https://crates.io)
  become callable from Julia.
- **Predictable performance without a garbage collector** for a hot inner
  loop, with memory safety checked by the Rust compiler.
- **No build system to maintain.** There is no Makefile, no hand-written
  `ccall` signature and no separate compile step: the Rust source is the
  single source of truth for the interface.

## Installation

```julia
using Pkg
Pkg.add("RustCall")
```

Requirements:

- Julia 1.12 or later.
- A Rust toolchain, **which you do not have to install**. RustCall depends on
  [RustToolChain.jl](https://github.com/AtelierArith/RustToolChain.jl), which
  uses the `rustc` / `cargo` on `PATH` when there is one and otherwise installs
  an isolated toolchain through Julia's Artifacts system. On Windows the
  artifact toolchain still needs the MSVC build tools and a Windows SDK for
  linking; see the [Windows guide](platforms/windows.md).

Installing Rust yourself ([rustup.rs](https://rustup.rs/)) is optional. A
`rustc` on `PATH` is preferred over the artifact toolchain when both exist.

`Pkg.add` also builds two small native programs RustCall needs. To verify the
installation, or after an upgrade that reports a missing component:

```julia
using RustCall
RustCall.check_toolchain()          # what was found, and any problems

using Pkg; Pkg.build("RustCall")    # rebuild the native components
```

## Three ways to use it

RustCall has three entry points. They can be mixed freely in one module.

| | You write | You call | Use it for |
|-|-----------|----------|------------|
| **`rust"""` + `#[julia]`** | ordinary Rust functions and structs, inline in a Julia file | generated Julia functions | Almost everything. Start here. |
| **`rust"""` + `@rust`** | hand-written `#[no_mangle] extern "C"` functions | `@rust f(args...)::T` | Existing C-style Rust, or full control over the binary interface. |
| **`@rust_crate`** | a separate Rust crate (its own directory and `Cargo.toml`) with `#[julia]` items | a generated Julia module | Larger Rust code bases and packages. |

### 1. Inline Rust with `#[julia]`

Mark a function or a struct with `#[julia]`, and a Julia function or type of
the same name appears in the current module.

```julia
rust"""
#[julia]
fn greet(name: &str) -> String {
    format!("Hello, {name}!")
}

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

    pub fn current(&self) -> i32 {
        self.value
    }
}
"""

greet("Julia")        # => "Hello, Julia!"

counter = Counter(0)
increment(counter)
increment(counter)
current(counter)      # => 2
```

Strings, numeric arrays (as Rust slices), `Result`, `Option` and structs are
all converted for you. A Rust panic becomes a Julia exception instead of
crashing the session. The [Tutorial](tutorial.md) walks through each.

### 2. Hand-written `extern "C"` with `@rust`

When you want the classic C-ABI style, export the function yourself and call
it with `@rust`:

```julia
rust"""
#[no_mangle]
pub extern "C" fn multiply(a: i32, b: i32) -> i32 {
    a * b
}
"""

@rust multiply(Int32(5), Int32(7))::Int32  # => 35
```

No Julia function is generated and nothing is converted: you pass exactly the
types the Rust signature declares.

### 3. A separate crate with `@rust_crate`

For more than a screenful of Rust, keep it in a crate of its own:

```rust
// my_crate/src/lib.rs      (Cargo.toml depends on rustcall_julia_macros = "0.7")
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

```julia
using RustCall

const MyCrate = @rust_crate "/path/to/my_crate"

MyCrate.add(1, 2)              # => 3
p = MyCrate.Point(3.0, 4.0)
MyCrate.distance(p)            # => 5.0
p.x                            # => 3.0
```

`@rust_crate` builds the crate with Cargo and returns a Julia module of
bindings. See [External Crate Bindings](crate_bindings.md).

### Crates from crates.io in an inline block

An inline block can depend on published crates through a `// cargo-deps:`
comment. RustCall then builds the block with Cargo:

```julia
rust"""
// cargo-deps: rand = "0.8"

use rand::Rng;

#[julia]
fn roll_die() -> i32 {
    rand::thread_rng().gen_range(1..=6)
}
"""

roll_die()  # => a number from 1 to 6
```

## What crosses the boundary

| Rust | Julia |
|------|-------|
| `i8` … `i64`, `u8` … `u64` | `Int8` … `Int64`, `UInt8` … `UInt64` |
| `isize`, `usize` | `Int`, `UInt` |
| `f32`, `f64` | `Float32`, `Float64` |
| `bool`, `char` | `Bool`, `Char` |
| `()` | `Nothing` |
| `&str`, `String` | `String` |
| `&[T]`, `&mut [T]` (numeric `T`) | `Vector{T}`, borrowed without a copy |
| `Result<T, E>` | `RustCall.RustResult{T, E}` |
| `Option<T>` | `RustCall.RustOption{T}` |
| a `#[julia]` struct | a Julia type holding a handle to the Rust value |
| `extern "C" fn(A...) -> R` (argument) | a Julia function ([Callbacks](callbacks.md)) |
| `*const T`, `*mut T` | `Ptr{T}` |

A type that is not on the list is refused with an error that names it, rather
than passed with a guessed layout. The authoritative, generated table is
[The FFI Type Contract](type_contract.md).

## Finding your way around

**Getting started**

- [Rust for Julia Users](rust_primer.md): the Rust you need, in Julia terms.
- [Tutorial](tutorial.md): numbers, strings, arrays, errors and objects.
- [What's New in v0.9 and v0.10](tutorial_new_features.md): borrowing objects,
  fallible constructors, slices in depth.
- [Examples](examples.md): longer worked examples.

**User guide**

- [Safe Rust/Julia Integration](integration_guide.md): how to structure a
  real project.
- [The FFI Type Contract](type_contract.md), [Struct Mapping](struct_mapping.md),
  [Generics](generics.md), [Callbacks](callbacks.md).
- [External Crate Bindings](crate_bindings.md), [Hot Reload](hot_reload.md),
  [PyO3 Crates](pyo3.md), [Precompilation](precompilation.md).
- [Panics, Visibility and Lifetime](panics.md),
  [Performance](performance.md), [Troubleshooting](troubleshooting.md).
- [Migrating from `@irust`](migrating_from_irust.md), for code written for
  v0.8 or earlier.

**Reference**

- [API Reference](api.md) and [Project Status](status.md).

**Developer documentation**

- [How RustCall Calls Rust](internals.md): the internal architecture, from
  a `rust"""` block to a `ccall`.
- [Project Guide](project_guide.md): repository layout, tests, releases.
- [Developer Pitfalls](developer_pitfalls.md) and
  [Windows Development](developer_windows.md).

## Runnable examples in the repository

Each directory under
[`examples/`](https://github.com/AtelierArith/RustCall.jl/tree/main/examples)
is a complete Julia package with its own tests:

- `MyExample.jl`: inline `rust"""` blocks in a package.
- `SampleCrate.jl`: a package with an embedded Rust crate, bound through a
  generated bindings file.
- `RustCrateMacro.jl`: a package that binds its crate with `@rust_crate` while
  it precompiles.
- `SafeLedger.jl`: the worked example of
  [Safe Rust/Julia Integration](integration_guide.md).
- `SampleCratePyO3.jl`, `SampleCratePyO3Only.jl`, `Pyo3HostImport.jl`: crates
  that are also Python extensions ([PyO3 Crates](pyo3.md)).
- `pluto/hello.jl`: a Pluto notebook.

The [Project Guide](project_guide.md) explains how to run them.
