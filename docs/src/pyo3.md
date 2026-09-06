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
* **Phase 2 — the wrapper crate.** `@rust_crate` and
  `RustCall.write_bindings_to_file` generate a wrapper crate, build it under the
  link plan, and bind the result. **This is the part you use**; the two above
  are what it is built on, and what you reach for when it refuses.

## Using it

```julia
using RustCall
Sample = @rust_crate "examples/sample_crate_pyo3_only"

Sample.add(Int32(2), Int32(3))          # 5
Sample.shout("hello")                   # "HELLO!"
Sample.parse("42")                      # RustResult{Int32, String}(true, 42)

p = Sample.Point(3.0, 4.0)              # #[new]
Sample.norm(p)                          # 5.0
p.x                                     # 3.0, through #[pyo3(get, set)]
p.x = 6.0
Sample.label(p)                         # a String method
Sample.scaled(p, 2.0)                    # a PyResult method
```

Nothing in the crate changes. RustCall generates a **second** crate that
depends on it and exports one `extern "C"` entry point per wrappable item:

* a free `#[pyfunction]` becomes `rustcall_<name>`;
* a `#[pyclass]` becomes an opaque handle with a `<Class>_free` destructor,
  `rustcall_<Class>_<method>` for every method of every `#[pymethods]` block
  (`#[new]`, `#[staticmethod]`, `#[getter]`, `#[setter]` included), and
  `rustcall_<Class>_get_<field>` / `_set_<field>` for the fields
  `#[pyo3(get, set)]`, `get_all` or `set_all` expose.

Every one of those comes out of `rustcall_core::codegen::generate_wrapper` —
the same generator `#[julia]` goes through since #279 — so the `(ptr, len)`
string ABI, the `CResult` / `COption` aggregates and the per-wrapper panic
channel are identical to a `#[julia]` crate's, and the Julia side binds both
with the same emitters. A panic inside a wrapped item is caught and raised as
`RustCall.RustPanicError`, not an abort.

### Selecting a feature set

The wrapper is built against one feature set of the target crate, named the way
Cargo names one:

```julia
Sample = @rust_crate "path/to/crate" features=["python"] default_features=false
```

`RustCall.pyo3_feature_candidates` says which features activate pyo3 and which
of those also pull `extension-module`; see [Choosing a feature
set](#Choosing-a-feature-set) below. The feature set is part of the artifact
identity, so two builds of one crate under different features are two different
cached libraries and two different registry entries.

### What is not wrapped, and why

The scan refuses what a wrapper crate could not *name* (a non-`pub` item, a
signature mentioning a type that needs a live interpreter, a generic, a
`#[pymodule]`). The generator then refuses what it could not *lower*:

| reason | meaning |
| --- | --- |
| `unsupported_arg:<T>` | an argument that is neither FFI-compatible nor a `String` / `&str` |
| `unsupported_return:<T>` | a return value that does not cross the C ABI as a single value (a `Vec`, a struct by value, a `Result` payload that is one of those) |
| `py_result_payload:<T>` | a `PyResult` whose `Ok` type does not fit in the `CResult` aggregate — `PyResult<String>`, `PyResult<Self>`. Widening this is tracked in [#303](https://github.com/AtelierArith/RustCall.jl/issues/303) |
| `unsupported_return:Result<…>` on a **method** | a plain `Result` / `Option` is wrapped into a `CResult` / `COption` for a free function only. `#[julia]`'s method wrappers have never lowered one either, so Julia's method emitters have no branch that decodes such an aggregate; emitting the symbol anyway would be worse than not wrapping the method. #303 owns widening it on both paths at once |
| `cfg_undecided:<predicate>` | the item is behind a `#[cfg]` the scan could not decide, so whether the build the wrapper links against has it is unknown |

`scan_report` prints both lists, and the second one with the symbol each wrapped
item is exported under:

```julia
RustCall.scan_report("examples/sample_crate_pyo3_only")
```

Nothing is guessed: an item that is not listed under "Wrapper crate exports" has
no symbol, and no Julia definition is generated for it.

### `PyResult<T>`: an opaque error, on purpose

A `PyResult<T>` becomes a Julia `RustResult{T, String}`. On the `Err` side the
value is always the same sentence:

```julia
RustCall.PYO3_OPAQUE_ERROR
# "PyErr (Python-side error; message unavailable without an interpreter)"
```

The `CResult_<owner>` mirror the Julia side declares for that aggregate
subtypes `RustCall.FFIByValue` — RustCall's own layout assertion about a
`#[repr(C)]` type it generated itself
([#245](https://github.com/AtelierArith/RustCall.jl/issues/245)), the same one
the `#[julia]` path makes about its `CResult_*` mirrors. Returning an aggregate
by value without such an assertion is refused since #295.

That is not laziness. Creating and dropping a `PyErr` without a Python
interpreter is safe, but **rendering** one is not: `Display`/`Debug` on a
`PyErr` asserts inside pyo3 that the interpreter is initialized, and the
resulting panic crossing `extern "C"` aborts the process. Reading only the
exception *type* would need a `Python` token, which a wrapper crate by
definition does not have. So the generated code drops the `PyErr` without ever
looking at it and reports a fixed code, and Julia turns that into the sentence
above. A `PyResult<()>` reports success or failure the same way, with `nothing`
as its `Ok` value.

### Scanning is lenient, calling is not

The wrapper calls the **item**, not its Python binding, and those can be gated
differently: `#[cfg_attr(feature = "python", pyfunction)]` makes the *marker*
conditional while `add` stays an ordinary `pub fn` in every build. So the scan
that feeds the generator is lenient — otherwise a crate with an optional pyo3
dependency would report nothing to wrap in the very build where wrapping it is
most useful.

The price is that an item whose **own** `#[cfg]` predicate is undecided cannot
be called safely, so it is refused with `cfg_undecided` rather than guessed at.
When Cargo resolved the build's configuration (`plan.resolved`), that predicate
is decided and nothing is refused for this reason.

`examples/sample_crate_pyo3_optional` is exactly this shape, and its wrapper
links **no** libpython at all.

## Scanning a crate

```julia
using RustCall
RustCall.scan_report("examples/sample_crate_pyo3_only")
```

```text
Crate sample_crate_pyo3_only v0.1.0 (…/examples/sample_crate_pyo3_only)
  Build scanned: default features
  RustCall items (wrapped today): 0
  PyO3 items the scan can name: 13
    fn add -> i32 [py_function]
    fn shout -> String [py_function]
    fn parse -> PyResult<i32> [py_function]
    struct Point [py_class]
    method new -> Self
    method norm -> f64
    method origin -> Self
    method sum -> f64
    …
  Wrapper crate exports: 13
    fn add -> i32 [py_function] -> rustcall_add
    struct Point [py_class] -> Point_free
    method new -> Self -> rustcall_Point_new
    …
  PyO3 items skipped: 3
    fn private_add -> i32 [py_function] — not `pub`, so a wrapper crate cannot name it (rustc E0603)
    fn describe -> i32 [py_function] — the signature uses a type that needs a live Python interpreter (Python<'_>)
    fn sample_crate_pyo3_only -> PyResult<()> [py_module] — a `#[pymodule]` initializer: it only means something to Python's import machinery
  Link plan: link_libpython — pyo3 is a mandatory dependency, so the wrapper cdylib links libpython; … is added as an rpath at wrapper-build time
```

The scan needs no build and no Python: it runs `rustcall-extract` over the
crate's sources and reads its `Cargo.toml`. Generating the wrapper's `lib.rs` —
which is what the "Wrapper crate exports" column reports — compiles nothing
either; pass `generate = false` for the Phase-1-only report.
`RustCall.scan_crate` returns the same information programmatically, in the
`pyo3_functions` and `pyo3_structs` fields of the `CrateInfo`.

## What the manifest records

Manifest schema 5 adds, for every function, struct and method:

| column | meaning |
| --- | --- |
| `attribute` | the *origin* of the entry: `julia` / `julia_pyo3` for a RustCall attribute, `py_function` / `py_class` / `py_methods` / `py_module` for the PyO3 scan |
| `vis` | visibility as written: `pub`, `pub(crate)`, `pub(super)`, `pub(in path)`, or empty for a private item |
| `skip_reason` | why the item cannot be wrapped, empty when it can |
| `python_name` | the name PyO3 exposes it under, when `#[pyo3(name = "...")]` renames it |
| `accessor` | `getter` / `setter` for a `#[getter]` / `#[setter]` method |
| `return_kind` + `ok_type` / `err_type` / `inner_type` | on methods too, not just free functions: a `#[pymethods]` method returning `PyResult<T>` is `py_result` with `T`, so Phase 2 never re-reads the Rust type spelling |

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
| `symbol_collision:<owner>` | another item already claims the symbol this one would get. The scheme is `rustcall_<name>` (#279) and carries no module path, so two `pub fn run` in different modules both want `rustcall_run`; `#[julia]` has the identical collision, so the scheme changes for both kinds at once — tracked in [#300](https://github.com/AtelierArith/RustCall.jl/issues/300) |

`not_public` is the reason you will see most often, and it is worth knowing why:
pyo3 does not require `pub` anywhere. `#[pyfunction] fn add(...)` and a
`#[pymethods]` block full of `fn`s without `pub` work perfectly for Python,
because pyo3 generates the wrapper *inside* the crate. A RustCall wrapper crate
is compiled outside it and hits `E0603`, which is a compile error, not something
to work around — so the scan reports those items rather than dropping them, and
adding `pub` in the target crate is the fix.

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
them, with `#[pyo3(get)]` / `#[pyo3(get, set)]`, **and only when they are
`pub`**: pyo3 generates its descriptor inside the crate, so `#[pyo3(get)]` works
on a private field, but a wrapper crate compiled outside cannot read
`Struct::field`. A private one is still listed, with no getter and no setter. Methods are collected from
*every* `#[pymethods]` block for the type: `#[new]` becomes the constructor,
`#[staticmethod]` and `#[classmethod]` are static, `#[getter]` / `#[setter]`
are accessors. (A `#[classmethod]` takes a `&Bound<'_, PyType>` first argument,
so it is normally skipped for using a pyo3 type.)

### Modules are followed, not guessed

An item's `module_path` is what a wrapper crate has to write
(`user_crate::api::item`), so it has to be right. The extractor therefore
follows the crate's module tree from `src/lib.rs` (`rustcall-extract manifest
--crate-root`) rather than treating each `.rs` file as its own root:
`pub mod api;` backed by `src/api.rs`, `src/deep/mod.rs`, `#[path = "..."]`
overrides, and an out-of-line module declared inside an inline one
(`mod outer { pub mod child; }` → `src/outer/child.rs`) are all resolved the
way rustc resolves them. That is also how a private parent is caught — a
`mod hidden;` without `pub` makes everything inside it `not_public`, however
`pub` the items themselves are.

The root is the crate's library root: `[lib] path` when the manifest sets one,
otherwise `src/lib.rs`. A `mod` declaration whose file does not exist (behind a
pruned `#[cfg]`, or generated at build time) is skipped rather than failing the
scan.

### One file, two modules

`#[path = "shared.rs"] pub mod a;` and the same for `b` compile one file as two
distinct modules, and both are reported — under their own module paths, and
colliding with each other on the wrapper symbols, which the scan says.

### `#[pymethods]` is matched crate-wide

An inherent `impl C` is legal in any module that has `C` in scope, and in a
multi-file crate the `#[pyclass]` and its `#[pymethods]` blocks routinely live
in different files. Classes and blocks are therefore collected across the whole
crate and married at the end: a block is attached to the class in its own
module, or — failing that — to the one class of that name anywhere in the
crate. Two things settle it exactly when several classes share a name: an
explicit qualifier (`impl a::C`, resolved relative to the block's own module and
then from the crate root) and the import that brought the name into scope
(`use crate::a::C;`, including `as` aliases). Only when nothing disambiguates is
the block dropped rather than attached to a guess.

### An item marked both ways belongs to `#[julia]`

Since #279 `#[julia]` is additive, so an item may carry `#[julia]` **and**
`#[pyfunction]` and get a Julia wrapper *and* a Python one. When both are
present, `#[julia]` owns the C entry point: it already exports
`rustcall_<name>`, so the PyO3 scan skips the item rather than describing a
second wrapper under the same symbol.

## The link plan

Before a wrapper crate can be built, one question has to be answered: will the
resulting cdylib link, and will it load? That depends on whether pyo3 ends up in
the build's dependency graph and with which features — which is Cargo's job, not
RustCall's.

A build is named the way Cargo names one: a feature list and whether default
features are on.

```julia
plan = RustCall.pyo3_link_plan("path/to/crate")                        # default features
plan = RustCall.pyo3_link_plan(crate; features = ["python"],
                                      default_features = false)        # a specific build

plan.mode                        # :python_free | :link_libpython | :unlinkable
plan.feature_flags               # the Cargo flags that select this build
plan.crate_features              # the crate's features, as Cargo resolved them
plan.pyo3_features               # pyo3's resolved features (empty when absent)
plan.dependency_default_features # what its [dependencies] entry must say
plan.cfg_text                    # the configuration the crate is scanned under
plan.rpath                       # the interpreter's library directory
plan.resolved                    # whether Cargo answered
plan.reason                      # why this mode was chosen
```

| mode | when | what the wrapper build does |
| --- | --- | --- |
| `:python_free` | pyo3 is not in this build's resolved graph | nothing links libpython |
| `:link_libpython` | pyo3 is resolved | the cdylib hard-links libpython; the interpreter's library directory is added as `-L` and as an rpath, or the build refuses |
| `:unlinkable` | pyo3's resolved features include `extension-module` | nothing usable can be built: refuse, with a message saying how to pick a different feature set |

`RustCall.pyo3_dependency_toml(plan, name, path)` renders the
`[dependencies.<name>]` entry the wrapper crate must write. That entry — not a
build flag — is where a target crate's default features are switched off:
`cargo build --no-default-features` applies to the **package being built**, so
from the wrapper it disables the *wrapper's* defaults and leaves the target
crate's (and therefore pyo3) enabled.

### Cargo resolves the features, RustCall does not

Feature activation is transitive (`api = ["python"]`, `python = ["dep:pyo3"]`),
target-dependent (`[target.'cfg(windows)'.dependencies]`) and renameable
(`python = { package = "pyo3" }`), and a `#[cfg]` predicate has Boolean
structure (`all`, `any`, `not`). Re-implementing any of that in Julia gets it
wrong in a new way for every crate shape, so the plan asks Cargo:

* `cargo tree -e features,normal` gives the **resolved** feature set of the root
  package and of pyo3 itself — transitive closure, target tables and renames
  already applied. The edge filter matters: a wrapper depends on the target
  crate's *library*, so the target's dev- and build-dependencies are not in the
  graph it builds, and a dev-dependency on pyo3 with `extension-module` must not
  make the plan unlinkable.
* `cargo rustc -- --print cfg` gives the configuration that build compiles
  under, which `scan_report` hands to the extractor so the crate is scanned in
  **strict** mode. `#[cfg]` and `#[cfg_attr]` on functions, structs, impls,
  methods and fields are then evaluated by the extractor's own evaluator, and
  the manifest contains exactly the items that build has.

### Choosing a feature set

The plan answers for the build you name; it does not go hunting for a better
one. `RustCall.pyo3_feature_candidates(crate)` says which features to consider,
again from Cargo — one resolution per feature:

```julia
RustCall.pyo3_feature_candidates(crate)
# [(feature = "python",    activates_pyo3 = true, extension_module = false),
#  (feature = "extension", activates_pyo3 = true, extension_module = true)]
```

That matters for a crate like this one:

```toml
[features]
default = ["extension"]
python = ["dep:pyo3"]
extension = ["python", "pyo3/extension-module"]
```

Its default build is `:unlinkable` (`extension` pulls in `extension-module`),
and so is `--all-features`. Turning defaults off gives `:python_free` — but that
build compiles none of the crate's `#[cfg(feature = "python")]` API, so there is
nothing to wrap. The build that works is neither of the obvious ones:

```julia
plan = RustCall.pyo3_link_plan(crate; features = ["python"], default_features = false)
plan.mode   # :link_libpython
RustCall.scan_report(crate; features = ["python"], default_features = false)
```

Enumerating "none / default / all" would never find it, which is why the feature
set is the caller's to state and the candidates are there to inform the choice.

### Without Cargo

When Cargo is unavailable or the crate does not resolve, the plan falls back to
a deliberately conservative read of `Cargo.toml` that performs **no** feature
resolution: any pyo3 declaration listing `extension-module` is `:unlinkable`,
any other pyo3 declaration is `:link_libpython`, and only a crate with no pyo3
declaration at all is `:python_free`. `plan.resolved` is `false` and the reason
says so. Renamed dependencies and `[target.…]` tables are still found — that is
a manifest lookup, not resolution.

### Why `:link_libpython` exists

Turning off `extension-module` is *not* enough to get a Python-free build.
Verified in the #275 MWE on macOS: any build whose graph contains pyo3 links
libpython — `otool -L` shows
`@rpath/Python3.framework/Versions/3.9/Python3` — and the cdylib then fails to
`dlopen` unless the loader can find it. The only genuinely Python-free build is
one in which pyo3 is not resolved at all — confirmed on Linux too: with the
feature off, `ldd` on the wrapper `.so` shows only libc and libgcc.

### Why `:unlinkable` refuses outright

`extension-module` tells pyo3 to leave libpython's symbols unresolved, for the
Python interpreter to supply when it imports the module. A wrapper cdylib is
never loaded that way, and the failure looks different on each platform —
neither of them recoverable:

* **macOS**: the wrapper does not even link. pyo3 emits
  `-undefined dynamic_lookup` through `cargo:rustc-cdylib-link-arg` from its own
  build script, and that does not reach a dependent crate (which is why maturin
  sets the flag itself). Forcing the link produces a library that fails `dlopen`
  under `RTLD_NOW` *and* `RTLD_LAZY`, because the missing symbols include data
  symbols (`_PyBaseObject_Type`, `PyExc_*`) that bind eagerly.
* **Linux**: the wrapper links — ELF tolerates undefined symbols in a shared
  object — but `dlopen` fails under both flags with
  `undefined symbol: _Py_Dealloc`.

So the plan refuses before the build rather than producing an artifact that
cannot be loaded.

### Windows is not Unix here

Two platform differences that the plan and the link flags both encode:

* **`extension-module` is a Unix-only blocker.** A DLL must resolve every import
  at link time, so pyo3 links the interpreter's import library on Windows
  whether or not the feature is on, and the wrapper loads like any other
  `:link_libpython` build. `RustCall.extension_module_is_linkable()` is the
  predicate.
* **Windows has no rpath.** `pyo3_link_rustflags` emits only `-L native=<dir>`
  there; the interpreter's DLL directory has to be on `PATH` when the wrapper is
  loaded. On Unix an rpath is recorded in the library itself and nothing else is
  needed.

On macOS a framework build of Python is linked as
`@rpath/Python3.framework/Versions/3.x/Python3`, so
`RustCall.python_library_dir()` returns the directory *containing* the
`.framework` rather than `LIBDIR`, which sits one level inside it.

## Making pyo3 optional: the `cfg_attr` limitation

The `:python_free` mode is the clean path, but it is rarer than it looks.
`#[cfg_attr(feature = "python", ...)]` works for the *item* attributes:

```rust
#[cfg_attr(feature = "python", pyfunction)]
pub fn add(a: i32, b: i32) -> i32 { a + b }
```

The scan reads markers through `cfg_attr` (to any nesting depth), because the
crate scan evaluates `#[cfg]` leniently — a `feature` predicate is deliberately
left undecided — so a gated `#[pyfunction]` is found rather than silently
skipped.

`cfg_attr` does **not** work for pyo3's inner attributes — `new`,
`staticmethod`, `classmethod`, `getter`, `setter`, `pyo3(get, set)`:

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

The consequence for Phase 2 is concrete: a crate whose pyo3 dependency is
optional can expose **free functions** behind a feature and be wrapped with no
Python at all, but it cannot have a `#[pyclass]` with methods, because those
inner attributes cannot be gated. So `:python_free` wrappers are free-function
wrappers, and a class always arrives through a `:link_libpython` build.

## Example

`examples/sample_crate_pyo3_only` is a crate that carries only PyO3 attributes:
a mandatory pyo3 dependency with `default-features = false, features =
["macros"]`, wrappable and skipped functions, a `#[pyclass]` with `#[new]`,
`#[staticmethod]`, `#[getter]`, `#[setter]`, a `String` method, a `PyResult`
method and `#[pyo3(get, set)]` fields, and a `#[pymodule]`. Its link plan is
`:link_libpython`. It is what `test/test_manifest.jl`,
`test/test_pyo3_link_plan.jl` and `test/test_pyo3_wrapper.jl` use.

`examples/sample_crate_pyo3_optional` is the `:python_free` counterpart: pyo3 is
an optional dependency and only the `#[pyfunction]` markers are behind a
feature, so the wrapper builds with pyo3 out of the graph entirely and links no
libpython. That is the fixture CI exercises everywhere.

Note that a class needs **one** `#[pymethods]` block unless the crate enables
pyo3's `multiple-pymethods` feature; the scan matches every block it finds, but
the crate has to compile for a wrapper to be built against it.

`examples/sample_crate_pyo3` is the older, different example: a crate that uses
RustCall's own `#[julia_pyo3]` attribute for dual Julia/Python bindings. That
attribute is unchanged by #275.
