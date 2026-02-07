# lastcall_macros

Proc macros for [RustCall.jl](https://github.com/atelierarith/RustCall.jl) - Julia-Rust FFI.

## Installation

Add this to your `Cargo.toml`:

```toml
[dependencies]
lastcall_macros = "0.1"
```

## Usage

### Functions

The `#[julia]` attribute on functions makes them FFI-compatible:

```rust
use lastcall_macros::julia;

#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
```

This expands to:

```rust
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}
```

### Structs

The `#[julia]` attribute on structs adds `#[repr(C)]` and generates FFI accessor functions:

```rust
use lastcall_macros::julia;

#[julia]
pub struct Point {
    pub x: f64,
    pub y: f64,
}
```

This generates:
- `Point_free(ptr: *mut Point)` - Free the struct
- `Point_get_x(ptr: *const Point) -> f64` - Get the `x` field
- `Point_set_x(ptr: *mut Point, value: f64)` - Set the `x` field
- `Point_get_y(ptr: *const Point) -> f64` - Get the `y` field
- `Point_set_y(ptr: *mut Point, value: f64)` - Set the `y` field

### Methods

Use `#[julia]` on impl blocks to generate FFI wrappers for methods:

```rust
use lastcall_macros::julia;

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
    pub fn get_value(&self) -> i32 {
        self.value
    }
}
```

This generates:
- `Counter_new(initial: i32) -> *mut Counter` - Constructor
- `Counter_increment(ptr: *mut Counter)` - Increment method
- `Counter_get_value(ptr: *const Counter) -> i32` - Getter method

## Julia Integration

On the Julia side, use `@rust_crate` to automatically generate bindings:

```julia
using RustCall

@rust_crate "/path/to/my_crate"

# Now you can use the functions and types
result = MyCrate.add(1, 2)
p = MyCrate.Point(1.0, 2.0)
```

## License

MIT
