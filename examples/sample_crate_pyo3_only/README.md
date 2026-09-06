# sample_crate_pyo3_only

A crate written for [PyO3](https://pyo3.rs) and nothing else: it carries no
RustCall attribute anywhere. It exists so RustCall's PyO3 scan
([#275](https://github.com/AtelierArith/RustCall.jl/issues/275) Phase 1) has a
realistic target.

```julia
using RustCall
RustCall.scan_report("examples/sample_crate_pyo3_only")
```

The report lists what a Phase-2 wrapper crate will be able to wrap (`add`,
`shout`, `parse`, `Point` and its methods) and what it cannot, with a reason:

* `private_add` — not `pub`, so a wrapper crate cannot name it (rustc `E0603`);
* `describe` — takes `Python<'_>`, which needs a live interpreter;
* the `#[pymodule]` initializer — only means something to Python's importer.

`pyo3` is a plain **mandatory** dependency here (`default-features = false,
features = ["macros"]`), which is what most real crates look like: making it
optional would need `#[cfg_attr(feature = "python", …)]`, and that does not work
for pyo3's inner attributes (`new`, `staticmethod`, `getter`, `setter`,
`pyo3(get, set)`). So the link plan for this crate is `:link_libpython`. See
[the PyO3 page](../../docs/src/pyo3.md) for the three modes.

Nothing builds this crate — the scan and the link plan both read sources and
`Cargo.toml` only.
