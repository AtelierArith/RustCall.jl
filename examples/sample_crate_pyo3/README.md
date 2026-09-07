# sample_crate_pyo3

A demo Rust crate with **dual bindings** — Julia through RustCall.jl, Python
through PyO3 — from one definition of each item, with pyo3 as an *optional*
dependency.

> This example used to be written with RustCall's own `#[julia_pyo3]` macro.
> That macro is **deprecated** (#275 Phase 3); the crate now shows the shape it
> is deprecated in favour of. See "Migrating from `#[julia_pyo3]`" below.

## Overview

`#[julia]` is **additive** (#279): it keeps the annotated item exactly as
written and emits the `extern "C"` entry point next to it. PyO3's attributes
keep the item too. So both can sit on the same definition:

```
src/lib.rs
├── fn add()            #[julia] + #[cfg_attr(feature = "python", pyo3::pyfunction)]
├── fn fibonacci()      #[julia] + #[cfg_attr(feature = "python", pyo3::pyfunction)]
├── fn shout()          #[julia] + #[cfg_attr(feature = "python", pyo3::pyfunction)]   (String in, String out)
├── struct Point        #[julia] + #[cfg_attr(feature = "python", pyo3::pyclass(get_all, set_all))]
├── impl Point          #[julia] on the block and on each method  → Julia wrappers
└── impl Point          #[cfg(feature = "python")] #[pyo3::pymethods] → Python methods
```

## The pattern

### Functions

```rust
#[julia]
#[cfg_attr(feature = "python", pyo3::pyfunction)]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
```

- **Julia**: `#[julia]` emits `#[no_mangle] pub extern "C" fn rustcall_add(...)`
  next to `add`, and RustCall binds it as `add`.
- **Python**: with `--features python`, `#[pyfunction]` wraps the very same
  `fn add`.

`cfg_attr` works for the *item* attribute, so with the feature off the crate
does not mention pyo3 at all.

### Structs

```rust
#[julia]
#[cfg_attr(feature = "python", pyo3::pyclass(get_all, set_all))]
pub struct Point {
    pub x: f64,
    pub y: f64,
}
```

- **Julia**: `#[repr(C)]` plus `Point_free`, `Point_get_x`, `Point_set_x`, …
- **Python**: `#[pyclass(get_all, set_all)]` exposes the same fields.

### Methods

```rust
#[julia]
impl Point {
    #[julia]
    pub fn new(x: f64, y: f64) -> Self { Point { x, y } }
    #[julia]
    pub fn distance_from_origin(&self) -> f64 { ... }
}

#[cfg(feature = "python")]
#[pyo3::pymethods]
impl Point {
    #[new]
    fn py_new(x: f64, y: f64) -> Self { Point::new(x, y) }
    #[pyo3(name = "distance_from_origin")]
    fn py_distance_from_origin(&self) -> f64 { self.distance_from_origin() }
}
```

- **Julia**: one wrapper per `#[julia]` method (`rustcall_Point_new`,
  `rustcall_Point_distance_from_origin`, …); the block itself is left as
  written.
- **Python**: written as PyO3 code. Two facts shape it:
  - pyo3's *inner* attributes (`#[new]`, `#[getter]`, …) cannot be gated with
    `cfg_attr` — the outer macro runs before `cfg_attr` expands — so a crate
    that keeps pyo3 optional writes the `#[pymethods]` block separately under
    `#[cfg(feature = "python")]`. A crate whose pyo3 dependency is mandatory
    can put `#[julia]` and `#[pymethods]` on **one** block instead, with
    `#[julia]` next to `#[new]` on each method.
  - a type has one inherent method of a given name, so the Python impl uses
    `py_` Rust names, restores the Python names with `#[pyo3(name = "...")]`,
    and delegates in one line.

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

const SampleCratePyo3 = @rust_crate "/path/to/sample_crate_pyo3"

SampleCratePyo3.add(2, 3)           # => 5
SampleCratePyo3.fibonacci(10)        # => 55
SampleCratePyo3.shout("hello")       # => "HELLO"

p = SampleCratePyo3.Point(3.0, 4.0)
p isa SampleCratePyo3.Point          # => true
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

m.add(2, 3)           # => 5
m.fibonacci(10)       # => 55
m.shout("hello")      # => "HELLO"

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

**Same names** in both languages:

| Definition | Julia | Python |
|------------|-------|--------|
| `fn add(a, b)` | `add(a, b)` | `add(a, b)` |
| `fn fibonacci(n)` | `fibonacci(n)` | `fibonacci(n)` |
| `fn shout(s)` | `shout(s)` | `shout(s)` |
| `struct Point` | `Point(x, y)` | `Point(x, y)` |
| `Point.x/y` | `p.x`, `p.y` | `p.x`, `p.y` |
| `Point::distance_from_origin` | `distance_from_origin(p)` | `p.distance_from_origin()` |
| `Point::translate` | `translate(p, dx, dy)` | `p.translate(dx, dy)` |
| `Point::scaled` | `scaled(p, factor)` | `p.scaled(factor)` |

## Dependencies

```toml
[dependencies]
juliacall_macros = { path = "../../deps/juliacall_macros" }
pyo3 = { version = "0.29", features = ["extension-module"], optional = true }

[features]
default = []
python = ["pyo3", "juliacall_macros/python"]
```

## Why the feature flag?

- **Julia build** (`cargo build`): pyo3 is not in the dependency graph at all;
  RustCall's link plan for this crate is `:python_free`.
- **Python build** (`maturin build --features python`): pyo3 with
  `extension-module`, the shape a Python extension needs.

The same source produces both; only the feature decides which half is compiled
in. (RustCall can also bind a crate that has *only* PyO3 attributes and no
`#[julia]` at all — see `examples/sample_crate_pyo3_only` and
`docs/src/pyo3.md`.)

## Migrating from `#[julia_pyo3]`

| you wrote | write instead |
|-----------|---------------|
| `#[julia_pyo3] fn add(...)` | `#[julia] #[cfg_attr(feature = "python", pyo3::pyfunction)] fn add(...)` |
| `#[julia_pyo3] pub struct Point {...}` | `#[julia] #[cfg_attr(feature = "python", pyo3::pyclass(get_all, set_all))] pub struct Point {...}` |
| `#[julia_pyo3] impl Point {...}` | `#[julia] impl Point { #[julia] pub fn ... }` plus a `#[cfg(feature = "python")] #[pyo3::pymethods] impl Point { ... }` as above |

`#[julia_pyo3]` still compiles (with a `use of deprecated macro` warning) until
the next breaking release. The full write-up is in `docs/src/pyo3.md`,
"Migrating from `#[julia_pyo3]`".

## Files

```
sample_crate_pyo3/
├── Cargo.toml      # Crate config with the `python` feature
├── src/
│   └── lib.rs      # Rust code: #[julia] + PyO3 attributes
├── main.jl         # Julia demo
├── main.py         # Python demo
└── README.md       # This file
```
