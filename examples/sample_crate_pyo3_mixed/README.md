# sample_crate_pyo3_mixed

A crate that carries **both** kinds of marker: RustCall's own `#[julia]` and
PyO3's `#[pyfunction]` / `#[pyclass]`. It exists so the two are proved to
survive together ([#275](https://github.com/AtelierArith/RustCall.jl/issues/275)
Phase 2).

```julia
using RustCall
Mixed = @rust_crate "examples/sample_crate_pyo3_mixed"

Mixed.julia_double(Int32(21))          # 42   -- #[julia]
Mixed.julia_shout("hey")               # HEY! -- #[julia], string ABI
Mixed.shared_add(Int32(2), Int32(3))   # 5    -- marked both ways; #[julia] owns it
Mixed.py_triple(Int32(4))              # 12   -- #[pyfunction]

t = Mixed.Tally(Int64(7))              # #[pyclass] with #[new]
Mixed.doubled(t)                       # 14
t.count                                # 7    -- #[pyo3(get, set)]
```

Two things it pins down:

* **Both origins reach one module.** `#[julia]` is additive since #279 and
  exports `rustcall_<name>` from *this* crate; the generated wrapper crate emits
  entry points for the PyO3 items and links the `#[julia]` ones. Binding only
  the PyO3 origins silently dropped every `#[julia]` item of such a crate.
* **`[lib] name` is what Rust code uses.** This crate's package is
  `sample_crate_pyo3_mixed` but its library target is `mixed_pyo3_sample`, so
  the wrapper must generate `mixed_pyo3_sample::py_triple`. A generated
  `sample_crate_pyo3_mixed::py_triple` is an unresolved-crate error in code the
  user never wrote.

`pyo3` is mandatory here, so the link plan is `:link_libpython` and the wrapper
needs an interpreter's library directory at build and load time. See
[the PyO3 page](../../docs/src/pyo3.md).
