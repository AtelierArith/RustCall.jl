# rustcall_julia_macros

The `#[julia]` attribute for [RustCall.jl](https://github.com/atelierarith/RustCall.jl) - Julia-Rust FFI.

This crate is a **library**, not a proc-macro crate: the attribute itself lives
in `rustcall_julia_macros_impl` and is re-exported here, and this crate adds the
runtime state `#[julia]` wrappers need but a proc macro cannot emit — the
thread-local panic-boundary depth that keeps a caught panic from printing
`panicked at` to stderr (RustCall.jl #304). Depend on it under its own name:
the generated wrappers name `::rustcall_julia_macros` literally.

## Installation

Add this to your `Cargo.toml`:

```toml
[dependencies]
rustcall_julia_macros = "0.1"
```

## Usage

### Functions

`#[julia]` on a function keeps the function as written and adds an
`extern "C"` wrapper next to it, exported as `rustcall_<name>`:

```rust
use rustcall_julia_macros::julia;

#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
```

exports `rustcall_add(a: i32, b: i32) -> i32`, which calls `add` inside a
panic boundary: a panic is caught, recorded in a thread-local channel read
through `rustcall_add_take_panic`, and raised in Julia as a `RustPanicError`.
Your own Rust code keeps calling `add` with the signature you wrote.

### Structs

`#[julia]` on a struct adds `#[repr(C)]` and exports a destructor and field
accessors, named after the struct:

```rust
use rustcall_julia_macros::julia;

#[julia]
pub struct Point {
    pub x: f64,
    pub y: f64,
}
```

exports `Point_free`, `Point_get_x` / `Point_set_x` and `Point_get_y` /
`Point_set_y`. A field gets accessors only when its value crosses `extern "C"`
on its own. Julia constructs a struct through an exported constructor (see
below), so `Point` as written is reached only through values Rust returns.

### Methods

Mark the struct **and** the `impl` block, and each method to export. The
struct's `#[julia]` is what provides the destructor (`Counter_free`) that the
Julia object calls when it is finalized. A `#[julia] impl` on an unmarked
struct has none, and RustCall.jl's extractor refuses it with a diagnostic
naming the struct.

```rust
use rustcall_julia_macros::julia;

#[julia]
pub struct Counter {
    value: i32,
}

#[julia]
impl Counter {
    #[julia]
    pub fn new(initial: i32) -> Self {
        Self { value: initial }
    }

    #[julia]
    pub fn increment(&mut self) {
        self.value += 1;
    }

    #[julia]
    pub fn value(&self) -> i32 {
        self.value
    }
}
```

exports `rustcall_Counter_new` (the constructor, returning a `*mut Counter`),
`rustcall_Counter_increment` and `rustcall_Counter_value`, plus `Counter_free`
and the field accessors of the struct.

### Modules

An item inside an inline module is exported under a name that folds the module
path in, so two modules can each have a `run` — mark the module too:

```rust
use rustcall_julia_macros::julia;

#[julia]
pub mod geometry {
    #[julia]
    pub fn area(w: f64, h: f64) -> f64 {
        w * h
    }
}
```

exports `rustcall_geometry__area` (a `_` inside a module or item name is
spelled `_0`). A `#[julia]` item in an unmarked inline module is refused.

The symbol names are an implementation detail shared with RustCall.jl's
extractor; Julia code never spells them.

## Julia Integration

On the Julia side, `@rust_crate` builds the crate and generates bindings:

```julia
using RustCall

const MyCrate = @rust_crate "/path/to/my_crate"

MyCrate.add(1, 2)                  # 3
c = MyCrate.Counter(10)            # calls rustcall_Counter_new
MyCrate.increment(c)
MyCrate.value(c)                   # 11
MyCrate.geometry.area(2.0, 3.0)    # 6.0
```

## License

MIT
