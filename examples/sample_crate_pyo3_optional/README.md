# sample_crate_pyo3_optional

A [PyO3](https://pyo3.rs) crate whose **pyo3 dependency is optional**. RustCall
wraps it with Python entirely out of the picture — the generated wrapper cdylib
links no libpython at all (`PyO3LinkPlan` mode `:python_free`), so this is the
fixture CI exercises on every platform.

```julia
using RustCall
Sample = @rust_crate "examples/sample_crate_pyo3_optional"

Sample.add(Int32(2), Int32(3))   # 5
Sample.shout("hello")            # "HELLO!"
Sample.greeting()                # a borrowed &str
```

## Why this works without the feature

Only the **marker** is conditional:

```rust
#[cfg_attr(feature = "python", pyo3::pyfunction)]
pub fn add(a: i32, b: i32) -> i32 { a + b }
```

`add` is an ordinary `pub fn` in every build. RustCall's scan reads markers
*through* `cfg_attr`, so the item is discovered either way, and the generated
wrapper calls the function rather than its Python binding. Nothing needs pyo3 to
be in the graph.

`only_with_python` is the counter-example: there the **item** is behind
`#[cfg(feature = "python")]`, not just its marker, so the scan cannot tell
whether the build the wrapper links against has it, and it is reported as
`cfg_undecided` rather than wrapped.

## Why there is no class here

pyo3's *inner* attributes — `new`, `staticmethod`, `getter`, `setter`,
`pyo3(get, set)` — cannot be put behind `cfg_attr`: the outer macro runs before
`cfg_attr` expands, so rustc reports `cannot find attribute 'new' in this
scope`. A crate with an optional pyo3 dependency can therefore expose free
functions to Python behind a feature, but not a `#[pyclass]` with methods.

`examples/sample_crate_pyo3_only` is the other shape — pyo3 mandatory,
`:link_libpython`, with a full `#[pyclass]` — and is where the class,
accessor, `PyResult` and destructor coverage lives. See
[the PyO3 page](../../docs/src/pyo3.md) for both.
