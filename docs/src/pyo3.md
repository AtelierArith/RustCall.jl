# PyO3 Crates

A crate written for [PyO3](https://pyo3.rs) exposes its API to Python with
`#[pyfunction]`, `#[pyclass]` and `#[pymethods]`, and knows nothing about
RustCall. From Rust's point of view those are ordinary items: a wrapper crate
can call them exactly like any other dependency. RustCall uses that to bind
such a crate **without asking its author to add a single RustCall attribute**
(issue #275).

This page describes what is available today:

* **Phase 1 — the scan.** `RustCall.scan_report` reports every PyO3 item the
  crate declares, which of them a wrapper crate will be able to wrap, and why
  the others cannot be.
* **Phase 1.5 — the link plan.** `RustCall.pyo3_link_plan` decides, from the
  crate's `Cargo.toml` alone, whether a wrapper cdylib can be linked and loaded
  at all, and under which flags.

Generating and building the wrapper crate itself is Phase 2 and is not
implemented yet.

## Scanning a crate

```julia
using RustCall
RustCall.scan_report("examples/sample_crate_pyo3_only")
```

```text
Crate sample_crate_pyo3_only v0.1.0 (…/examples/sample_crate_pyo3_only)
  RustCall items (wrapped today): 0
  PyO3 items wrappable by Phase 2: 8
    fn add -> i32 [py_function]
    fn shout -> String [py_function]
    fn parse -> PyResult<i32> [py_function]
    struct Point [py_class]
    method new -> Self
    method norm -> f64
    method origin -> Self
    method sum -> f64
  PyO3 items skipped: 3
    fn private_add -> i32 [py_function] — not `pub`, so a wrapper crate cannot name it (rustc E0603)
    fn describe -> i32 [py_function] — the signature uses a type that needs a live Python interpreter (Python<'_>)
    fn sample_crate_pyo3_only -> PyResult<()> [py_module] — a `#[pymodule]` initializer: it only means something to Python's import machinery
  Link plan: link_libpython — pyo3 is a mandatory dependency, so the wrapper cdylib links libpython; … is added as an rpath at wrapper-build time
```

The scan needs no build and no Python: it runs `rustcall-extract` over the
crate's sources and reads its `Cargo.toml`. `RustCall.scan_crate` returns the
same information programmatically, in the `pyo3_functions` and `pyo3_structs`
fields of the `CrateInfo`.

## What the manifest records

Manifest schema 5 adds, for every function, struct and method:

| column | meaning |
| --- | --- |
| `attribute` | the *origin* of the entry: `julia` / `julia_pyo3` for a RustCall attribute, `py_function` / `py_class` / `py_methods` / `py_module` for the PyO3 scan |
| `vis` | visibility as written: `pub`, `pub(crate)`, `pub(super)`, `pub(in path)`, or empty for a private item |
| `skip_reason` | why the item cannot be wrapped, empty when it can |
| `python_name` | the name PyO3 exposes it under, when `#[pyo3(name = "...")]` renames it |
| `accessor` | `getter` / `setter` for a `#[getter]` / `#[setter]` method |

A scanned item's `symbol` is the wrapper a Phase-2 wrapper crate *will* export —
`rustcall_<name>` for a function, `rustcall_<Struct>_<method>` for a method, the
same scheme `#[julia]` uses since #279 — and `exported` is `false`, because
nothing emits it yet. The manifest describes what Phase 2 will generate.

### Skip reasons

| reason | meaning |
| --- | --- |
| `not_public` | the item is not `pub`, so a wrapper crate compiled outside the scanned crate cannot name it (rustc `E0603`). A `pub` item inside a private `mod` counts as private. |
| `pyo3_type:<T>` | the signature mentions `<T>`, which only exists with a live interpreter: `PyObject`, `Py<T>`, `Bound<'_, T>`, `&PyAny`, `Python<'_>`, `PyRef`, `PyRefMut`, anything under `pyo3::` |
| `pymodule` | a `#[pymodule]` initializer: it exists to be called by Python's import machinery |
| `generic` | a generic item; monomorphizing PyO3 items is out of scope |
| `owner_skipped:<reason>` | a method whose `#[pyclass]` is itself skipped for `<reason>` |

### `PyResult<T>` is wrapped, not skipped

`PyResult<T>` is recorded as return kind `py_result` with the `Ok` type in
`ok_type`, and is **not** a skip reason. Creating and dropping a `PyErr`
without an interpreter is safe; only *rendering* one is not — `Display`/`Debug`
on a `PyErr` panics inside pyo3, and a panic crossing `extern "C"` aborts the
process. Phase 2 will therefore lower it to an opaque error flag, and generated
code must never format a `PyErr`.

### `#[pyclass]` structs are opaque handles

A `#[pyclass]` is never `#[repr(C)]` — pyo3 owns its layout — so it is always
boxed and reached through accessors. Fields are exposed only when pyo3 exposes
them, with `#[pyo3(get)]` / `#[pyo3(get, set)]`. Methods are collected from
*every* `#[pymethods]` block for the type: `#[new]` becomes the constructor,
`#[staticmethod]` and `#[classmethod]` are static, `#[getter]` / `#[setter]`
are accessors. (A `#[classmethod]` takes a `&Bound<'_, PyType>` first argument,
so it is normally skipped for using a pyo3 type.)

### An item marked both ways belongs to `#[julia]`

Since #279 `#[julia]` is additive, so an item may carry `#[julia]` **and**
`#[pyfunction]` and get a Julia wrapper *and* a Python one. When both are
present, `#[julia]` owns the C entry point: it already exports
`rustcall_<name>`, so the PyO3 scan skips the item rather than describing a
second wrapper under the same symbol.

## The link plan

Before a wrapper crate can be built, one question has to be answered from the
target crate's `Cargo.toml`: will the resulting cdylib link, and will it load?

```julia
plan = RustCall.pyo3_link_plan("path/to/crate")
plan.mode          # :python_free | :link_libpython | :unlinkable
plan.feature_flags # Cargo flags the wrapper build must pass
plan.rpath         # the interpreter's library directory, for :link_libpython
plan.reason        # why this mode was chosen
```

| mode | when | what the wrapper build does |
| --- | --- | --- |
| `:python_free` | the crate has no pyo3 dependency, or an **optional** one | build with the feature off; nothing links libpython |
| `:link_libpython` | pyo3 is a **mandatory** dependency | the cdylib hard-links libpython; the interpreter's library directory is added as `-L` and as an rpath, or the build refuses |
| `:unlinkable` | the crate enables pyo3's `extension-module` feature unconditionally | nothing can be built: refuse with a message saying how to make the feature optional |

`RustCall.pyo3_link_rustflags(plan)` turns a plan into the `RUSTFLAGS` pieces a
wrapper build needs, and raises `RustError` for the two failure modes — an
unlinkable crate, or a `:link_libpython` crate whose interpreter library
directory could not be found. `pyo3_link_plan` itself never raises, so a crate
can be inspected and reported without committing to building it.

The library directory comes from `RustCall.python_library_dir`, which consults,
in order: `ENV["RUSTCALL_PYTHON_LIBDIR"]`, CondaPkg's environment when
`CondaPkg` is already loaded (PythonCall users), `python3-config --ldflags`, and
`sysconfig.get_config_var("LIBDIR")`.

### Why `:link_libpython` exists

Turning off `extension-module` is *not* enough to get a Python-free build.
Verified in the #275 MWE on macOS: any build of a crate with a non-optional
pyo3 dependency links libpython — `otool -L` shows
`@rpath/Python3.framework/Versions/3.9/Python3` — and the cdylib then fails to
`dlopen` unless the loader can find it. The only genuinely Python-free case is a
crate whose pyo3 dependency is *itself* optional.

### Why `:unlinkable` is a build error, not a load error

With `extension-module` on, a downstream cdylib does not even link: pyo3 emits
`-undefined dynamic_lookup` through `cargo:rustc-cdylib-link-arg` from its own
build script, and that does not reach a dependent crate (which is why maturin
sets the flag itself). Forcing the link produces a library that fails
`dlopen` under `RTLD_NOW` *and* under `RTLD_LAZY`, because the missing symbols
include data symbols (`_PyBaseObject_Type`, `PyExc_*`) that bind eagerly.

## Making pyo3 optional: the `cfg_attr` limitation

The `:python_free` mode is the clean path, but it is rarer than it looks.
`#[cfg_attr(feature = "python", ...)]` works for the *item* attributes:

```rust
#[cfg_attr(feature = "python", pyfunction)]
pub fn add(a: i32, b: i32) -> i32 { a + b }
```

It does **not** work for pyo3's inner attributes — `new`, `staticmethod`,
`classmethod`, `getter`, `setter`, `pyo3(get, set)`:

```rust
#[cfg_attr(feature = "python", pymethods)]
impl Point {
    #[cfg_attr(feature = "python", new)]      // error: cannot find attribute `new`
    pub fn new(x: f64) -> Self { … }
}
```

The outer macro runs before `cfg_attr` expands, so rustc reports
`cannot find attribute 'new' in this scope` (and, for a static method,
`static method needs #[staticmethod] attribute`). Real crates therefore make
pyo3 mandatory, or duplicate items under `#[cfg]` — which makes
`:link_libpython` the common case. Do not document `cfg_attr` as the way to
make a crate's pyo3 dependency optional.

## Example

`examples/sample_crate_pyo3_only` is a crate that carries only PyO3 attributes:
a mandatory pyo3 dependency with `default-features = false, features =
["macros"]`, wrappable and skipped functions, a `#[pyclass]` with two
`#[pymethods]` blocks, and a `#[pymodule]`. It is what the tests in
`test/test_manifest.jl` and `test/test_pyo3_link_plan.jl` scan.

`examples/sample_crate_pyo3` is the older, different example: a crate that uses
RustCall's own `#[julia_pyo3]` attribute for dual Julia/Python bindings. That
attribute is unchanged by #275.
