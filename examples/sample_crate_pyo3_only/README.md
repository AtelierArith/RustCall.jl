# sample_crate_pyo3_only

A crate written for [PyO3](https://pyo3.rs) and nothing else: it carries no
RustCall attribute anywhere. RustCall scans it, generates a wrapper crate that
depends on it, builds that, and binds the result
([#275](https://github.com/AtelierArith/RustCall.jl/issues/275)).

```julia
using RustCall
Sample = @rust_crate "examples/sample_crate_pyo3_only"

Sample.add(Int32(2), Int32(3))     # 5
Sample.shout("hello")              # "HELLO!"
Sample.parse("42")                 # RustResult{Int32, String}(true, 42)

p = Sample.Point(3.0, 4.0)         # #[new]
Sample.norm(p)                     # 5.0
p.x                                # 3.0, through #[pyo3(get, set)]
Sample.sum(p)                      # a #[getter]
Sample.set_both(p, 1.0)            # a #[setter]
Sample.label(p)                    # a String method
Sample.scaled(p, 2.0)              # a PyResult method
```

`RustCall.scan_report("examples/sample_crate_pyo3_only")` lists what the
wrapper exports and what it cannot, with a reason:

* `private_add` — not `pub`, so a wrapper crate cannot name it (rustc `E0603`);
* `describe` — takes `Python<'_>`, which needs a live interpreter;
* the `#[pymodule]` initializer — only means something to Python's importer.

`pyo3` is a plain **mandatory** dependency here (`default-features = false,
features = ["macros"]`), which is what most real crates look like: making it
optional would need `#[cfg_attr(feature = "python", …)]`, and that does not work
for pyo3's inner attributes (`new`, `staticmethod`, `getter`, `setter`,
`pyo3(get, set)`). So the link plan for this crate is `:link_libpython`: the
wrapper cdylib links libpython and needs the interpreter's library directory at
build and load time. `examples/sample_crate_pyo3_optional` is the
`:python_free` counterpart. See [the PyO3 page](../../docs/src/pyo3.md) for the
three modes.

The class has exactly **one** `#[pymethods]` block: more than one needs pyo3's
`multiple-pymethods` feature, and this crate is compiled by
`test/test_pyo3_wrapper.jl`. `dropped_points` counts `Point` destructions, so a
test can prove the generated `Point_free` really runs the Rust destructor, and
`boom` panics so the wrapper's panic channel can be exercised.
