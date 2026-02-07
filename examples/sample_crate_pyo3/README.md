# sample_crate_pyo3

A demo Rust crate showing how to create **dual bindings** for both Julia and Python using the unified `#[julia_pyo3]` macro.

## Overview

This crate demonstrates the `#[julia_pyo3]` macro that generates **both** Julia FFI bindings and Python/PyO3 bindings from a single definition - no more duplicate code!

## Architecture

```
src/lib.rs
└── All bindings use #[julia_pyo3]
    ├── fn add()           → Julia: extern "C" / Python: #[pyfunction]
    ├── fn fibonacci()     → Julia: extern "C" / Python: #[pyfunction]
    └── struct Point       → Julia: #[repr(C)] + FFI / Python: #[pyclass]
        └── impl Point     → Julia: FFI wrappers / Python: #[pymethods]
```

## The `#[julia_pyo3]` Macro

The unified macro generates **both** Julia and Python bindings from a single definition:

### For Functions

```rust
#[julia_pyo3]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
```

This generates:
- **Julia build**: `#[no_mangle] pub extern "C" fn add(...)`
- **Python build**: `#[pyfunction] fn add(...)`

### For Structs

```rust
#[julia_pyo3]
pub struct Point {
    pub x: f64,
    pub y: f64,
}
```

This generates:
- **Julia**: `#[repr(C)]` struct + FFI functions (`Point_free`, `Point_get_x`, etc.)
- **Python**: `#[pyclass(get_all, set_all)]`

### For Impl Blocks

```rust
#[julia_pyo3]
impl Point {
    pub fn new(x: f64, y: f64) -> Self { Point { x, y } }
    pub fn distance_from_origin(&self) -> f64 { ... }
}
```

This generates:
- **Julia**: FFI wrapper functions (`Point_new`, `Point_distance_from_origin`)
- **Python**: `#[pymethods]` impl with `#[new]` for constructors

## Build

### For Julia

```bash
cd examples/sample_crate_pyo3
cargo build --release
```

### For Python

```bash
cd examples/sample_crate_pyo3

# Create virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Build with maturin
pip install maturin
maturin develop --features python
```

## Usage

### From Julia (with RustCall.jl)

```julia
using RustCall

@rust_crate "/path/to/sample_crate_pyo3"

# Functions - same API as Python!
SampleCratePyo3.add(2, 3)           # => 5
SampleCratePyo3.fibonacci(10)        # => 55

# Point struct
p = SampleCratePyo3.Point(3.0, 4.0)
p.x, p.y                             # => 3.0, 4.0
SampleCratePyo3.distance_from_origin(p)  # => 5.0
SampleCratePyo3.translate(p, 1.0, 2.0)
SampleCratePyo3.scaled(p, 2.0)       # => new Point
```

Run the demo:

```bash
julia --project=../.. main.jl
```

### From Python

```python
import sample_crate_pyo3 as m

# Functions - same API as Julia!
m.add(2, 3)           # => 5
m.fibonacci(10)       # => 55

# Point class
p = m.Point(3.0, 4.0)
p.x, p.y                   # => 3.0, 4.0
p.distance_from_origin()   # => 5.0
p.translate(1.0, 2.0)
p.scaled(2.0)              # => new Point
```

Run the demo:

```bash
source .venv/bin/activate
python main.py
```

## API Reference

All APIs are generated from `#[julia_pyo3]` - **same function names** in both languages!

| Definition | Julia | Python |
|------------|-------|--------|
| `fn add(a, b)` | `add(a, b)` | `add(a, b)` |
| `fn fibonacci(n)` | `fibonacci(n)` | `fibonacci(n)` |
| `struct Point` | `Point(x, y)` | `Point(x, y)` |
| `Point.x/y` | `p.x`, `p.y` | `p.x`, `p.y` |
| `Point::distance_from_origin` | `distance_from_origin(p)` | `p.distance_from_origin()` |
| `Point::translate` | `translate(p, dx, dy)` | `p.translate(dx, dy)` |
| `Point::scaled` | `scaled(p, factor)` | `p.scaled(factor)` |

## Dependencies

```toml
[dependencies]
lastcall_macros = { path = "../../deps/lastcall_macros" }
pyo3 = { version = "0.23", features = ["extension-module"], optional = true }

[features]
default = []
python = ["pyo3", "lastcall_macros/python"]
```

## Why Feature Flags?

- **Julia build** (`cargo build`): Generates `extern "C"` functions for FFI
- **Python build** (`maturin build --features python`): Generates `#[pyfunction]` for PyO3

The builds are mutually exclusive for functions, but the **same source code** produces both!

## Files

```
sample_crate_pyo3/
├── Cargo.toml      # Crate config with feature flags
├── src/
│   └── lib.rs      # Rust code - everything uses #[julia_pyo3]
├── main.jl         # Julia demo
├── main.py         # Python demo
└── README.md       # This file
```
