# Changelog

All notable changes to RustCall.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`@rust_crate` binds a PyO3 crate that carries no RustCall attribute**
  ([#275](https://github.com/AtelierArith/RustCall.jl/issues/275), Phase 2).
  RustCall generates a *second* crate that depends on the target, emits one
  `extern "C"` entry point per wrappable item, builds it under the Phase-1.5
  link plan and loads the result. A `#[pyfunction]` becomes `rustcall_<name>`;
  a `#[pyclass]` becomes an opaque handle with `<Class>_free`, one wrapper per
  `#[pymethods]` method (`#[new]`, `#[staticmethod]`, `#[getter]`, `#[setter]`
  included) and accessors for the fields `#[pyo3(get, set)]` / `get_all` /
  `set_all` expose. Every entry point comes out of
  `rustcall_core::codegen::generate_wrapper`, the generator `#[julia]` has used
  since #279, so the string ABI, the `CResult`/`COption` aggregates and the
  per-wrapper panic channel are identical and the Julia emitters bind both
  kinds the same way. `write_bindings_to_file` takes the same path.

  A `PyResult<T>` becomes `RustResult{T, String}` whose error is always
  `RustCall.PYO3_OPAQUE_ERROR`: creating and dropping a `PyErr` without an
  interpreter is safe, but rendering one panics inside pyo3 and the panic
  crossing `extern "C"` aborts the process, so the generated code drops it
  without looking at it.

  A crate carrying **both** kinds of marker keeps both: the wrapper generates
  entry points for the PyO3 items and links the `#[julia]` ones the crate
  already exports, and one `@rust_crate` module exposes them together. The
  Rust path in generated calls is the crate's **library target** name
  (`[lib] name`), not its package name.

  The scan that feeds the generator runs under the configuration the wrapper is
  compiled with whenever Cargo could resolve it, so a `#[cfg]`-gated item that
  the requested feature set enables is wrapped rather than refused; a build that
  exposes nothing to PyO3 (every marker behind a feature that is off) falls back
  to the pre-#275 binding path instead of producing an empty cdylib.

  `@rust_crate` gains `features=` and `default_features=`, which select the
  feature set the wrapper is built against and are part of the artifact
  identity (`ArtifactId` kind `pyo3-wrapper`), together with the build
  environment the wrapper inherits (`artifact_build_env()`, the #282
  allowlist, which now captures the `PYO3_*` namespace, plus the contents of
  `PYO3_CONFIG_FILE`) and, for a `:link_libpython` build, the interpreter
  `PYO3_PYTHON` is pinned to — its path and what it reports about itself
  (`plan.interpreter_config`: implementation, version, ABI tag, library), so a
  Python upgraded in place is a different wrapper. That interpreter and the
  library directory are decided together (`python_link_source()`,
  `plan.interpreter`): a caller's own `PYO3_PYTHON` is honoured rather than
  replaced by the first `python3` on `PATH`, and the cfg probe follows the
  build profile (`pyo3_link_plan(crate; release = false)`). `#[pyo3(get)]` and
  `#[pyo3(set)]` are independent — a `set`-only field is a setter with no
  getter. A `#[pymethods]` method is boxed as the class only as a `#[new]` or
  a `Self` return, never for being named `new`; a class member whose own
  `#[cfg]` the scan could not decide is refused (`cfg_undecided`) like an
  item; `impl super::C` is resolved against the parent module (and a `use
  super::C` disambiguates a bare `impl C`) instead of falling back to a
  same-named local class; and the panic reader `<symbol>_take_panic` is a
  reserved symbol, so an item that would *be* one is reported as a
  `symbol_collision`. A `&str` returned by an item that takes a string leaves
  as an owned copy (it may point into the argument the wrapper built), a
  `Vec<T>` field gets no accessor (there is no owned-vector ABI on the Julia
  side yet), the cfg probe runs the crate as the wrapper's
  dependency rather than as its own Cargo root, and the feature set a caller
  asks for is honoured — and is in the artifact identity — on the plain
  `@rust_crate` path as well. The wrapper and the probe are built under the
  crate's own `target/` with its `Cargo.lock` and `[patch]` table carried
  over, so the crate's `.cargo/config.toml`, pins and overrides apply as they
  do to the crate (for a workspace member, from its workspace root, whose
  manifest and lockfile are then part of the member's artifact identity; a
  package the workspace `exclude`s is its own root; both generated manifests
  declare an empty `[workspace]` so they are roots of their own); the probe
  runs under the wrapper's panic policy and its memo follows the root's
  manifest and lockfile; a PyO3 crate that exposes nothing under the
  requested build falls back to the plain path **under that build's
  configuration**, so a `#[julia]` item the selected features disable is not
  bound; the wrapper's link options travel in a generated `build.rs` rather
  than in `RUSTFLAGS` (which `CARGO_ENCODED_RUSTFLAGS` overrides and which
  replaced a crate's `[build] rustflags`); a `std::`-anchored return type is
  never mistaken for a class of the same name; the string helpers a wrapper
  declares (`<owner>_RustCallOwnedString` and friends) are reserved per owner
  like every other symbol, as is the case-folded panic slot two items whose
  names differ only by case would share; and
  `PYO3_CROSS_LIB_DIR` or a `PYO3_CONFIG_FILE`'s `lib_dir` names the link
  directory ahead of any interpreter. Anything the generator cannot
  lower is reported with a reason (`unsupported_arg`, `unsupported_return`,
  `py_result_payload`, `cfg_undecided`) instead of being emitted — including a
  plain `Result` / `Option` on a `#[pymethods]` **method**, which the `#[julia]`
  method wrappers have never lowered either. `scan_report`
  gains a "wrapper crate exports" column naming each symbol. The generated
  `CResult_*` mirrors subtype `RustCall.FFIByValue`, the layout assertion #245
  requires and #295 enforces, exactly as the `#[julia]` path's do. New extractor
  subcommand `rustcall-extract wrap`; new example
  `examples/sample_crate_pyo3_optional`, a crate whose wrapper links no
  libpython at all.

- **`Result` and `Option` returns on `#[julia]` struct methods**
  ([#268](https://github.com/AtelierArith/RustCall.jl/issues/268)). A method
  returning `Result<T, E>` / `Option<T>` is now lowered exactly like a free
  function: the wrapper returns a `#[repr(C)]` `CResult_<Struct>_<method>` /
  `COption_<Struct>_<method>` aggregate (private fields, `MaybeUninit`
  payloads, `new` / `is_ok` / `is_some` / `ok` / `err` / `some` / `panicked`
  accessors) and Julia hands back a `RustResult` / `RustOption`. It used to
  return the `Result` as written — not FFI-safe — and the manifest reported
  `return_kind = plain`, so the Julia emitters raised under the default
  `FFI_STRICT = :error`. Both wrapper flavours (inline `rust"""` and the
  `@rust_crate` proc-macro) and all three Julia emitters (`src/structs.jl`,
  the in-memory `@rust_crate` emitter and `write_bindings_to_file`) now agree,
  with `#[cfg]` / `#[cfg_attr]` propagated to every generated item and the
  panic channel read before either payload is decoded.

- **`String` / `&str` payloads inside `Result` and `Option`**
  ([#268](https://github.com/AtelierArith/RustCall.jl/issues/268)). A string
  payload is lowered to the owned buffer the string ABI already uses —
  `<owner>_RustCallOwnedString { ptr, len, cap }`, released through
  `<owner>_free_rust_string` — so the `Result` lowering and the string lowering
  compose and `Result<String, String>` works. Julia copies the active payload
  out and releases it through the release function resolved in the **same**
  generation snapshot as the call; the inactive payload is never touched. This
  lifts the compile error `#[julia]` used to emit for a `String` payload on a
  free function too. A `&str` payload is copied rather than borrowed. Payloads
  the aggregate cannot carry (`Vec<T>`, `Box<T>`, …) are unchanged: a compile
  error on a free function, returned as written on a method.

### Changed
- **Manifest schema 5 → 6** (`RustCall.MANIFEST_SCHEMA_VERSION`,
  `rustcall_core::manifest::SCHEMA_VERSION`), bundling two changes that neither
  shipped separately ([#268](https://github.com/AtelierArith/RustCall.jl/issues/268),
  [#275](https://github.com/AtelierArith/RustCall.jl/issues/275) Phase 2).
  `Method.return_kind` now reports `result` / `option` where it always said
  `plain`, which is an **ABI change** for those methods and not merely a richer
  description: a schema-5 consumer would read a two-payload aggregate as the
  scalar it used to be. `Function` and `Method` also gain `ok_abi` / `err_abi` /
  `inner_abi`, which say whether a payload travels as an owned string buffer.
  Separately, a `py_*` entry can now be `exported` with a `return_abi`, a
  lowered `PyResult` reports the `i32` code in `err_type`, and the skip-reason
  vocabulary gains the four reasons the wrapper *generator* uses; a schema-5
  consumer would read a wrapper manifest as a scan and never call anything.
  Rebuild the extractor (`Pkg.build("RustCall")`) after upgrading.

- **Bindings format 5** ([#268](https://github.com/AtelierArith/RustCall.jl/issues/268)).
  A file written by `write_bindings_to_file` now imports
  `RustCall._result_payload`, which older RustCall versions do not define.
  Regenerate after upgrading.

### Fixed
- **`test_cargo.jl`'s Cargo-cache assertions no longer race the parallel runner**
  ([#306](https://github.com/AtelierArith/RustCall.jl/issues/306)). The Cargo
  cache is a depot-level directory shared by every worker, and two testsets
  asserted on its whole contents — its size after a clear, and the number of
  libraries in it after one evaluation — so any other worker compiling a Cargo
  block in the meantime failed them. Both now run under a cache root of their
  own (`RUSTCALL_CACHE_DIR`), and the "exactly one key" assertion is also made
  key-specifically, which is what it actually means.

- **`extension-module` is no longer called unlinkable on Windows**
  ([#275](https://github.com/AtelierArith/RustCall.jl/issues/275)). A DLL
  resolves every import at link time, so pyo3 links the interpreter's import
  library there regardless of the feature and the wrapper loads like any other
  `:link_libpython` build; only Unix leaves the symbols undefined.
  `RustCall.extension_module_is_linkable()` is the predicate — applied on the
  resolved path and on the conservative `Cargo.toml` fallback alike, so the two
  cannot disagree about one crate — and
  `pyo3_link_rustflags` no longer emits `-Wl,-rpath` — which `link.exe` rejects
  — on Windows, where the interpreter's DLL directory belongs on `PATH`
  instead.

- **A link plan whose `--print cfg` probe failed no longer claims to be
  resolved** ([#275](https://github.com/AtelierArith/RustCall.jl/issues/275)).
  `cargo tree` can answer while `cargo rustc -- --print cfg` does not; the plan
  then had an empty `cfg_text` with `resolved = true`, and `scan_report`
  silently fell back to a lenient scan. Such a plan is now `resolved = false`
  with the probe failure in its `reason`.

- **macOS framework builds of Python get the right rpath**
  ([#275](https://github.com/AtelierArith/RustCall.jl/issues/275)). A framework
  build is linked as `@rpath/Python3.framework/Versions/3.x/Python3`, so
  `python_library_dir()` now returns the directory *containing* the
  `.framework` rather than `LIBDIR`, which sits one level inside it and
  produced a cdylib that could not be loaded.

- **`#[pymethods]` matching keeps the anchor of a written path**
  ([#275](https://github.com/AtelierArith/RustCall.jl/issues/275)).
  `impl crate::a::C` inside module `m` was matched against `m::a::C` first,
  because the `crate::` prefix was stripped before matching; when both classes
  existed the block attached to the wrong one. `crate::` now resolves only at
  the crate root, `self::` only in the enclosing module, and the same
  distinction applies to `use` paths.

- **Re-aliasing a library under a name it already has no longer declares it
  dead** ([#291](https://github.com/AtelierArith/RustCall.jl/issues/291)).
  `alias_artifact!` retired whatever was registered under the target name —
  correct when that name pointed at a *different* image, and destructive when
  it already pointed at this one, because then the retired flag is this image's
  own. Every object holding it went inert, its destructor never ran, and every
  `alive[]` check turned a working call into an error.
  `_alias_reloaded_library` runs on every `_resolve_lib`, so the second call
  through one precompiled module reached exactly this. Aliasing a name that
  already names the same handle with the same flag is now a no-op for
  liveness; aliasing over a name that pointed elsewhere still retires it.

- **One liveness flag per image, even under two live names**
  ([#291](https://github.com/AtelierArith/RustCall.jl/issues/291)). Loading the
  same path under a second name while the first is still registered minted a
  second flag for one image — `dlopen` refcounts and answers with the same
  handle, so it is one lifetime with two registry rows. `unload_artifact!`
  retires the image with **one** of those flags and drops the other from
  `ARTIFACT_ALIVE` without ever flipping it, so every object that captured the
  dropped flag believed itself live after `close = true` had unmapped the code
  its destructor calls into. `load_artifact!` now adopts the flag the image
  already has (`registered_alive_for_handle`).

- **Invalid UTF-8 in a string argument now raises instead of being silently
  substituted** ([#246](https://github.com/AtelierArith/RustCall.jl/issues/246)).
  A Julia `String` is a byte vector and need not be UTF-8; Rust's `&str` is
  UTF-8 by definition. The generated wrapper built the `&str` with
  `String::from_utf8_lossy`, which *replaces* an invalid byte with U+FFFD — so
  `f(String([0xff, 0xfe]))` ran the Rust function on data the caller never
  passed and returned a wrong answer with no error anywhere.

  The check now happens on the Julia side, before the pointer exists, and
  raises a `RustError` naming the argument (by its Rust name), the function it
  belongs to and the first offending byte. The Rust-side `from_utf8_lossy`
  stays as defence in depth: a `&str` built from invalid bytes is undefined
  behaviour, and nothing may reach it. Free functions, struct methods and
  monomorphized generics share the path; a generic names the argument by
  position (`argument #1`), since a `FunctionInfo` records ABIs and not
  parameter names. `BINDINGS_FORMAT_VERSION` goes to `3`: a written-out
  bindings file now imports `RustCall.ffi_string_argument`, a name an older
  RustCall does not have, so regenerate after upgrading.

### Breaking
- **The compilation cache moved out of `~/.julia/compiled/`**
  ([#252](https://github.com/AtelierArith/RustCall.jl/issues/252)). RustCall
  used to write compiled `.dylib`/`.so`/`.dll` files, their `.sha256`
  checksums, the `metadata/` tree and the Cargo build products into
  `$(DEPOT_PATH[1])/compiled/vX.Y/RustCall` — **Julia's own package precompile
  directory**, which Pkg neither tracks nor garbage-collects for foreign files
  and which is read-only in common deployments (shared/HPC depots, baked
  container images), where `mkpath` threw and RustCall was simply unusable.

  `RustCall.get_cache_dir()` is now a [Scratch.jl](https://github.com/JuliaPackaging/Scratch.jl)
  space, `<depot>/scratchspaces/<RustCall UUID>/cache-v2` — writable by
  construction, accounted for by `Pkg.gc()`, and removable with
  `Pkg.Scratch.clear_scratchspaces!`. The space name folds in
  `CACHE_FORMAT_VERSION`, so RustCalls that disagree about the on-disk layout
  keep separate trees. Three consequences:

  - **Nothing is written under `~/.julia/compiled/` any more.** That directory
    is read *only* by the opt-in legacy sweep and is never created by RustCall.
    `RustCall.clear_cache(sweep_legacy = true)` removes the tree the old layout
    left behind (its `v<n>` and `cargo`/`metadata` directories and loose files
    matching the exact pre-#278 naming) and nothing else — Julia's `.ji` and
    native images in the same directory are left alone.
  - **A read-only `DEPOT_PATH[1]` is no longer fatal.** `Scratch` defaults to
    the first depot; RustCall scans `DEPOT_PATH` for the first *writable* one.
    With no writable depot at all the failure is a named `RustError` naming the
    depots tried, not an `IOError` from inside a file copy.
  - **`RUSTCALL_CACHE_DIR` overrides the location entirely**, for air-gapped
    and CI setups that need the cache in a specific place.

  Existing caches are not migrated: the first compile after upgrading rebuilds.

- **Passing a Julia struct to Rust by value is opt-in**
  ([#245](https://github.com/AtelierArith/RustCall.jl/issues/245)).
  `is_supported_arg_type(::Type{T}) = isbitstype(T)` accepted *any* isbits Julia
  struct or tuple as a by-value argument or return, and `ccall_arg_type` passed
  it through unchanged — assuming its layout matched the Rust side's. Rust's
  default `repr(Rust)` layout is explicitly unspecified (fields may be
  reordered, niches exploited), so an unannotated struct that works today is a
  silent miscompile waiting for a toolchain upgrade.

  An aggregate now needs a layout assertion, and `RustCall.register_ffi_struct`
  is where it is made:

  ```julia
  struct Point            # matches #[repr(C)] pub struct Point { x: f64, y: f64 }
      x::Float64
      y::Float64
  end
  @register_ffi_struct Point
  ```

  Without it the call raises a `RustError` naming the type, its fields and the
  opt-in. Registration is for **concrete types only**: `Point{Float64}` says
  nothing about `Point{Int32}` — a parameter changes sizes, alignment and
  register classes — and registering the `UnionAll` `Point`, or an abstract
  type, is an error rather than a family-wide claim. `@register_ffi_struct` is
  the form to use at a package's top level: it expands in the calling module, so
  the method it defines is carried by that package's precompile cache whatever
  `T` is — including a `Tuple`, whose `parentmodule` is `Core` and for which the
  function form has no home but RustCall itself. Scalars, pointers,
  `Cstring`, `Char` and
  `Bool` are unaffected — their ABI is their width. So are the wrappers
  RustCall generates from a `#[julia] struct`, which cross as opaque handles,
  and RustCall's own `#[repr(C)]` mirrors: `CRustString`, `CRustSlice` and
  friends have `ffi_by_value_layout` methods in the package, and the
  `CResult_<fn>` / `COption_<fn>` aggregates the wrapper generators emit
  subtype `RustCall.FFIByValue`. The assertion is a **method**, defined in the
  module that owns the type, so `register_ffi_struct` at a package's top level
  is carried by that package's precompile cache and holds in every later
  session — a mutated global would not be. `unregister_ffi_struct` withdraws an
  assertion; `repr_c = false` is rejected, because then there is nothing to
  assert. The supported-type matrix and the opt-in are documented on the FFI
  type contract page. `BINDINGS_FORMAT_VERSION` goes to `4`: a written-out
  bindings file now imports `RustCall.FFIByValue`, a name an older RustCall does
  not have, so regenerate after upgrading.

- **A `::T` return annotation may no longer contradict the manifest**
  ([#245](https://github.com/AtelierArith/RustCall.jl/issues/245)). `@rust
  f(x)::Float64` on a function the manifest records as `-> i32` used to win, and
  the `ccall` then read a 32-bit return slot as a `Float64` — silent garbage.
  An annotation supplies a return type RustCall does not know; when one *is*
  recorded, a differing annotation raises a `RustError` naming both types.
  Agreement is *the same `ccall` return slot*, not the same Julia type — the
  manifest records the slot while an annotation names the surface type, so
  `::Char` and `::UInt32` both agree with a `-> char` and `::Int32` does not.
  Annotations on symbols with no recorded type are unchanged. Convert on the
  Julia side if you wanted the other type.

- **One load/registration path** ([#277](https://github.com/AtelierArith/RustCall.jl/issues/277),
  Phase B). Twelve `dlopen` sites with four different flag sets and eight
  open-coded `RUST_LIBRARIES[...] = ...` writes became one:
  `RustCall.load_artifact!` (`src/loadpolicy.jl`), with `unload_artifact!` and
  `alias_artifact!` as the reverse and the aliasing operations.
  `scripts/lint_load_path.sh` keeps it that way in CI. Five user-visible
  consequences:

  - **Every artifact is `RTLD_LOCAL` now**
    ([#250](https://github.com/AtelierArith/RustCall.jl/issues/250)). A
    compiled block no longer publishes its symbols into the process-global
    namespace, so two `rust"""` blocks that both export `f` stop shadowing one
    another and which one a call reaches no longer depends on load order. It
    also stops depending on whether the block happened to declare
    `// cargo-deps:`, which used to flip the same construct from `RTLD_LOCAL`
    to `RTLD_GLOBAL`. Calling across blocks does not need global symbols —
    `@rust f(...)` searches the loaded libraries by handle. Code that relied
    on the old behaviour can set `RUSTCALL_DLOPEN_GLOBAL=1` for one minor
    release, with a warning; the variable will be removed. On Windows nothing
    changes: `LoadLibrary` has no LOCAL/GLOBAL distinction.

  - **A Rust panic is now a catchable Julia exception**
    ([#244](https://github.com/AtelierArith/RustCall.jl/issues/244)). A
    `panic!`, a failed `assert!`, an `unwrap()` on `None` or an out-of-bounds
    index inside a `#[julia]` function raises `RustCall.RustPanicError` with
    the panic message, and the Julia session survives — it used to abort the
    process. Every generated `extern "C"` wrapper runs the body inside
    `catch_unwind` and exports a `<symbol>_take_panic` channel Julia reads
    after each call.

    **This changes what RustCall builds, so the first run after upgrading
    recompiles everything.** `-C panic=abort` is gone from the direct-`rustc`
    path and `panic = "unwind"` is pinned in every `Cargo.toml` RustCall
    generates and in `CARGO_PROFILE_<PROFILE>_PANIC` in the environment it
    passes to Cargo — `catch_unwind` can only catch a panic that unwinds, and
    an inherited `CARGO_PROFILE_RELEASE_PANIC=abort` would otherwise silently
    disable the boundary. Two cases still abort, both visible from the source
    and documented in `docs/src/panics.md`: a raw `#[no_mangle] extern "C" fn`
    you wrote yourself (RustCall generates no wrapper for it, so there is no
    boundary — add `#[julia]`), and a `@rust_crate` crate whose own profile
    pins `panic = "abort"`.

  - **Finalizers of inline `#[julia]` structs now free the Rust allocation**
    ([#249](https://github.com/AtelierArith/RustCall.jl/issues/249)). They
    used to leak — the free was disabled with a "diagnose segfault" comment —
    while the same construct from a `@rust_crate` crate freed. If your code
    depended on an inline struct's Rust object outliving its Julia wrapper,
    keep a reference to the wrapper or use `GC.@preserve`. The finalizer is
    safe to run by construction: it captures the destructor pointer and the
    library's liveness flag at construction time, so it takes no lock,
    resolves no symbol and logs nothing; a failure is counted
    (`RustCall.finalizer_failure_count()`). A method or field access on a
    finalized object now raises instead of dereferencing `C_NULL`, and an
    object whose library was unloaded goes inert rather than calling into a
    closed image.

  - **Libraries are retired, not closed.** A hot reload replacing a library
    and `unload_library` dropping one both remove everything that *reaches*
    the library and leave the image mapped. A call that started a moment
    earlier may still be inside it, and closing it there is a
    use-after-`dlclose`; RustCall has no per-call reader pin, and adding one
    would put two atomics on every FFI call. The image costs a few hundred
    kilobytes until you say it is safe to reclaim:
    `unload_library(name; close = true)` or
    `unload_all_libraries(; close = true)`. `RustCall.retired_handles()` lists
    what is waiting.

    While an image is retired its objects keep working — a finalizer holds its
    own image's destructor and that image is still mapped, so an object
    allocated before a reload still frees through the code that allocated it.
    Closing is the moment objects of that image become inert (they leak rather
    than jumping into unmapped code), so `close = true` says both "no call is
    in flight" and "I accept that surviving objects will not be freed".

  - **A failed hot reload keeps the previous library**
    ([#255](https://github.com/AtelierArith/RustCall.jl/issues/255)). The
    rebuild, the rescan and the `dlopen` all complete before anything is
    swapped, so saving a file with a compile error leaves the loaded library
    working instead of emptying the registry; the error is reported once per
    distinct failure rather than on every watch tick. Each reload opens its own
    `<lib>.<generation>.<ext>` copy, which is what makes reloading a *loaded*
    library work on Windows. The watcher is event-driven
    (`FileWatching.watch_folder`) with a 100 ms debounce instead of an mtime
    poll, so an idle watch costs nothing and a burst of saves is one rebuild;
    `enable_hot_reload(...; poll = true)` restores polling for filesystems the
    kernel will not watch.

  - **`unload_library` now purges everything a library owns.** Its
    `RUST_LIBRARIES` entry and pointer cache, its symbol mappings and
    return-type hints, its `FUNCTION_REGISTRY` rows, the monomorphizations
    whose pointers point into it, its `@irust` memos and its panic channels —
    and it flips the library's liveness flag, retiring objects it produced. An
    `@irust` snippet no longer leaves a stale memo behind. `@rust_crate`
    libraries are visible to it for the first time: the generated module
    publishes its handle through the loader instead of keeping it only in a
    module-local `Ref`.

### Changed
- **A call cannot straddle a hot reload.** Every FFI entry point resolves what
  it needs — function pointer, panic channel, owned-`String` release function,
  struct destructor, liveness flag and **return ABI** — in one locked step and
  then uses only that snapshot, so a library replaced mid-call can no longer
  have the call enter the retired image while the `free`, the panic channel or
  the return type belongs to its replacement. In practice this fixes a reload
  racing a call that returns a `String` (the buffer was released through the
  wrong image's allocator), a reload racing a struct construction (the object
  could capture one generation's destructor and another's liveness flag), and a
  reload racing an untyped `@rust` call (the result of one generation could be
  read with another's return type — a scalar as a struct). A cached record is a
  snapshot too: a monomorphized generic's `FunctionInfo` carries the panic
  channel and the image it was built against, so a panic is still raised after
  its library has been unloaded, rather than returning the wrapper's zero
  sentinel as a result. `scripts/lint_generation_snapshot.sh` fails CI if a new
  entry point resolves a piece on its own. A constructor is part of this: the
  object it returns captures the destructor and the liveness flag of the
  generation that **allocated** it, taken from the constructor call's own
  snapshot, so a reload between the allocation and the object's construction
  can no longer bind a pointer from the retired image to the replacement's
  `free`. The same holds for a **generic** struct: its constructor resolves the
  instantiated destructor in the same step that allocates, preferring the
  constructor's own image and otherwise taking the destructor's own image's
  flag, so the flag always describes the image the finalizer will call into.
  (Each generic instantiation is still its own artifact, so a generic object
  can be allocated by one image and freed through another: [#291](https://github.com/AtelierArith/RustCall.jl/issues/291).)
- Two `rust"""` blocks in **one module** may no longer export the same name.
  The second block raises, naming the symbol and the library that already owns
  it. Previously the second Julia wrapper silently replaced the first while
  both libraries stayed loaded ([#250](https://github.com/AtelierArith/RustCall.jl/issues/250)).
- A generated wrapper resolves through **its own module's** library rather than
  through whichever block was compiled last in the session, so two modules that
  each define `add` call their own `add`.
- A generated `@rust_crate` module keeps its state in one immutable record
  (`_LIB_GEN`) instead of separate `_LIB_HANDLE` / `_LIB_ALIVE` `Ref`s, so a
  wrapper reads handle, liveness flag and generation as one value. Regenerate
  bindings files after upgrading (`# Bindings format: 2`).
- Bindings files written by `write_bindings_to_file` carry
  `# Bindings format: 2`. Files generated by an older RustCall still work but
  do not get the unload, panic or lifetime guarantees — regenerate after
  upgrading.
- **One mapped image, one liveness flag — across an unload and a reopen.**
  `unload_library(name)` retires an image without closing it, so it stays
  mapped and the objects it produced hold its flag; the next load of the same
  path gets that same image back from the loader and now keeps that same flag,
  instead of minting a fresh one that nothing would ever flip.
- **Closing a retired image closes what the retirement owned**, recorded when
  it was retired, rather than draining the live counter — a task reopening the
  same path while the close runs keeps its own reference.
- **An idle hot-reload watcher now really is idle.** `watch_folder` returning
  "the wait expired" was treated as a filesystem event, so a watched project
  with nothing happening still `stat`ed every source file every interval. A
  timeout is now ignored and only a real event triggers a scan;
  `RustCall.source_scan_count()` exposes the number so the behaviour is
  checkable. `enable_hot_reload(...; poll = true)` still polls, as it must.
- **The crate `#[cfg]` probe is memoized on what decides it**, not on the crate
  path alone: its `Cargo.toml`, its `build.rs`, and the `.cargo/config.toml`
  chain. Turning a default feature on or off between two reloads used to reuse
  the previous answer, so the rescan described `#[cfg]` items the new build did
  not have and registered the wrong ABI for them. A **hot reload re-probes
  unconditionally** rather than trusting that digest: a `build.rs` can emit a
  different `cargo::rustc-cfg` from inputs no digest can enumerate, and a
  reload has just run a full build anyway.
- **Closing a retired image drains its loader references.** One file loaded
  under two names is one image with two `dlopen`s; retirement discarded the
  record after a single `dlclose`, leaving the last reference unreclaimable and
  the image mapped for the life of the process. `close_retired_handles!` and
  `unload_all_libraries(; close = true)` now close once per owned open.
- Hot reload no longer needs `Cargo.lock` to be stable. The check that the
  sources did not change under the rescan hashes the scan's own inputs (the
  Rust sources and `Cargo.toml`); it used to hash the whole crate, including
  the `Cargo.lock` that the very `cargo build` it straddles writes, so on a
  fresh checkout the rescan was always discarded and the reloaded library was
  registered with no symbol mappings.
- `RustCall.scan_crate` accepts `cfg` / `cfg_text`, and hot reload probes the
  crate's real build configuration (`cargo rustc --release --lib -- --print
  cfg` in the crate) before rescanning, so mutually exclusive
  `#[cfg(feature = ...)]` variants of one `#[julia] fn` collapse to the one
  that was built and its return type is registered. An unavailable probe falls
  back to the previous lenient scan.
- `RustCall.load_cached_library` returns the verified cache *path* instead of
  opening the library.
- A `@rust_crate` library's registry name includes its build profile, so a
  `build_release = false` and a `build_release = true` module of one crate are
  two entries rather than one that clobbers the other.
- Ownership operations (`RustBox`, `RustRc`, `RustArc`, `RustVec`) refuse to
  construct a value when the helper library is missing, naming the operation
  and the `Pkg.build("RustCall")` that fixes it.

### Added
- **PyO3 crates without a RustCall attribute: the scan and the link plan**
  ([#275](https://github.com/AtelierArith/RustCall.jl/issues/275), Phases 1 and
  1.5). A crate that only carries `#[pyfunction]` / `#[pyclass]` /
  `#[pymethods]` is now reported by the extractor:
  `RustCall.scan_report(crate_path)` prints which items a wrapper crate will be
  able to wrap and why the others cannot be, and `RustCall.scan_crate` returns
  them in the new `pyo3_functions` / `pyo3_structs` fields of `CrateInfo`.
  Manifest schema 5 adds a PyO3 `attribute` origin (`py_function`, `py_class`,
  `py_methods`, `py_module`), `vis`, `skip_reason`, `python_name` and
  `accessor` columns, and the `py_result` return kind. An item carrying both
  `#[julia]` and `#[pyfunction]` is owned by `#[julia]`, which already exports
  `rustcall_<name>` (#279), and is skipped by the scan.
  `RustCall.pyo3_link_plan(crate_path)` decides from `Cargo.toml` alone whether
  a wrapper cdylib can be linked and loaded — `:python_free`,
  `:link_libpython` or `:unlinkable` — and `RustCall.pyo3_link_rustflags`
  turns that into build flags or a precise `RustError`. Generating the wrapper
  crate is Phase 2 and is not implemented yet. `#[julia_pyo3]` is unchanged.
  See `docs/src/pyo3.md` and `examples/sample_crate_pyo3_only`.
- `docs/src/panics.md`: the panic semantics matrix, the symbol-visibility rule
  and the object-lifetime/allocator contract.
- `test/test_panics.jl`, `test/test_finalizers.jl`,
  `test/test_load_conformance.jl`, `test/test_hot_reload_transaction.jl`,
  `test/test_pyo3_link_plan.jl`.


### Breaking
- **One artifact identity** ([#278](https://github.com/AtelierArith/RustCall.jl/issues/278),
  Phase B). Twelve places answered "which compiled artifact corresponds to this
  request?", each with its own component list, its own concatenation format and
  its own truncation. Every one of them now builds a `RustCall.ArtifactId` and
  calls `artifact_key` (`src/artifact_id.jl`). Five user-visible consequences:

  - **The cache directory is now `.../RustCall/v2`.** `CACHE_FORMAT_VERSION = 2`
    namespaces the on-disk layout, and `get_metadata_dir()` /
    `get_cargo_cache_dir()` nest under it. Nothing is silently served from the
    old layout; `clear_cache()` and `cleanup_old_cache()` sweep older `v*`
    siblings and the unversioned pre-#278 tree best effort. A *newer* sibling is
    left alone.
  - **Every on-disk key changes value**, so the first build after upgrading
    recompiles. Keys are the full 64-hex digest now: truncation happens only in
    `artifact_short_id`, and only for names a human reads (library names,
    temporary Cargo project directories, log lines).
  - **A missing toolchain is an error on compile paths.** `_get_rustc_version()`
    (a bare `rustc` from `PATH`, degrading to the string `"unknown"`) and
    `_get_cargo_version()` are deleted; keys name the compiler
    `RustToolChain.rustc()` / `cargo()` resolves to
    (`RustCall.artifact_compiler_identity()`), and an unidentifiable compiler
    raises `RustError` instead of caching everything under one sentinel
    ([#252](https://github.com/AtelierArith/RustCall.jl/issues/252)).
    `toolchain_fingerprint()` itself stays total.
  - **Monomorphized names changed.** A specialization is now
    `<name>_<types in declaration order>_<8 hex>` and its library is
    `rust_generic_<16 hex>`. The old key sorted the type *values*, so
    `pair<T=i32, U=i64>` and `pair<T=i64, U=i32>` shared one cache entry and the
    second call ran the first one's machine code
    ([#247](https://github.com/AtelierArith/RustCall.jl/issues/247)); each
    instantiation also used to register under one colliding `RUST_LIBRARIES`
    key.
  - **`RustBlockSnapshot` has an `artifact_schema` field** (defaulted by an
    inner constructor). A snapshot from an older RustCall is recomputed and then
    aliased, never an error.

- **One FFI type contract** ([#276](https://github.com/AtelierArith/RustCall.jl/issues/276)).
  Five independent tables decided "what does this Rust type mean at the C
  boundary?", and they disagreed with each other. Every call site now reads
  `src/ffi_contract.jl`; `_rust_type_to_julia_conversion_type`,
  `_rust_type_to_julia_type_symbol`, `_RUST_PRIMITIVE_TO_JULIA`,
  `rust_to_julia_type_sym`, `julia_sym_to_type` and `RUST_TO_JULIA_TYPE_MAP`
  are deleted. Four user-visible consequences:

  - **Manifest schema 3 → 4.** `Function.return_abi`, `Field.abi` and
    `Method.returns_boxed_struct` are new; the `has_*_string_helper` booleans
    stay for one release, derived from `return_abi`. Run
    `Pkg.build("RustCall")` to rebuild the extractor — a stale binary is
    refused with that hint. Every cache key includes the schema, so artifacts
    are rebuilt.
  - **`str` and `*const u8` are no longer `Cstring`.** `rusttype_to_julia("str")`
    is `RustStr` and `rusttype_to_julia("*const u8")` is `Ptr{UInt8}`. A Rust
    `str` is an unsized UTF-8 slice reached through a `(ptr, len)` fat pointer
    and a `*const u8` is a plain byte pointer; neither is a NUL-terminated C
    string, and treating them as one is
    [#246](https://github.com/AtelierArith/RustCall.jl/issues/246).
    `julia_to_c_type(::Type{RustString})` / `(::Type{RustStr})` are gone for the
    same reason.
  - **Unknown types raise instead of becoming `Any`.** A type the contract
    cannot describe now stops wrapper generation with a message naming the
    signature. `RustCall.FFI_STRICT[]` selects `:error` (default), `:warn` (one
    warning per signature, then `Any` — the pre-#276 behaviour, kept for one
    minor release) or `:none`. `write_bindings_to_file(...; strict = :warn)` and
    `emit_crate_module_code(...; strict)` thread it explicitly, so concurrent
    calls with different settings do not interfere. Monomorphized generic
    returns obey it too; they used to become `Any` silently.
    Generated crate bindings also change text: `usize` is
    spelled `Csize_t`, `*mut i32` is `Ptr{Int32}`, and a `String` field is read
    as an owned buffer rather than `Any`.
  - **A `String` field on the crate path is lowered.** Its getter returns an
    owned `<Struct>_RustCallOwnedString` buffer released through
    `<Struct>_free_rust_string`, as the inline path already did; it used to be
    read as `Any` and leaked
    ([#246](https://github.com/AtelierArith/RustCall.jl/issues/246)).

### Changed
- Cargo-backed blocks fold the **effective Cargo configuration** into the key:
  the project-local `.cargo/config.toml` chain Cargo searches, not only
  `$CARGO_HOME/config.toml` (`RustCall._cargo_config_digest(env; dir)`).
- Local **path dependencies are identified by content**, so editing one rebuilds
  while moving the checkout does not. Every byte of every input is read on every
  call — file contents are never memoized, because a `(mtime, size)` stamp can
  alias distinct contents and the cost of being wrong is running the wrong
  machine code. What *is* memoized is the resolved dependency graph (the
  `cargo tree` process spawn), validated against the **content digests** of
  every manifest that can decide the graph — each crate's `Cargo.toml` /
  `Cargo.lock` *and* the workspace root each crate belongs to, since a member
  can inherit a path from `[workspace.dependencies]` in a manifest that is not
  a package at all — including one named by an explicit
  `[package] workspace = "../elsewhere"`, which need not be an ancestor. A block
  that declares no `path =` dependency never resolves a graph, so a warm
  `rust"""` re-evaluation spawns no `cargo tree`.
- `clear_cache` gains `sweep_legacy` (default `false`). RustCall's cache root is
  `.../compiled/vX.Y/RustCall`, which is **Julia's own precompile directory for
  RustCall** — its `.ji` and native images live there. The pre-#278 layout's
  loose files are removed only on explicit request and only when they match the
  exact naming that layout used; `cleanup_old_cache` never removes them at all,
  and nothing else in that directory is ever touched.
- `build_cargo_project_cached(project, id::ArtifactId; ...)` takes the artifact
  identity instead of a code-hash string, and uses `artifact_key(id)` unchanged:
  a Cargo block has exactly one key for its in-memory name, its disk lookup, its
  build and its save. The effective Cargo configuration is folded in by the
  caller, once, so a `.cargo/config.toml` change rebuilds instead of matching
  the pre-change binary. A profile disagreeing with the identity is an error.
- `generate_cache_key` and `is_cache_valid` take a `cfg_text` keyword, so the
  disk key and the in-memory library name of a `rust"""` block are one value.
- New CI lint: `scripts/lint_artifact_identity.sh` fails when Julia source
  outside `src/artifact_id.jl` concatenates key material, truncates a digest, or
  names an artifact with Julia's session-randomized `hash()`.


### Deprecated
- `call_rust_function_infer` guessed the **return** type from the type of the
  **first argument** — `Float64` for `fn f(x: f64) -> i32`, `Cstring` for a
  string argument, `Int64` otherwise. None of that is derivable from an
  argument, and reading a return slot at the wrong width is undefined
  behaviour. It now emits a `Base.depwarn` and raises a `RustError` naming the
  fix ([#245](https://github.com/AtelierArith/RustCall.jl/issues/245),
  [#246](https://github.com/AtelierArith/RustCall.jl/issues/246)). Pass the
  return type: `call_rust_function(func_ptr, T, args...)`, or annotate the call
  site `@rust f(x)::T`. `@rust f(x)` on a function with no manifest-recorded
  return type raises with the same advice instead of guessing.

### Fixed
- `i128`, `u128`, `char`, the `std::os::raw` aliases and raw pointers cross the
  boundary correctly in every position — free functions, methods, struct fields
  and monomorphized generics. `char` crosses as its `UInt32` Unicode scalar
  value and is converted back to a Julia `Char` — never reinterpreted from
  Julia's left-aligned UTF-8 bit pattern — in both directions and on every path,
  including monomorphized generics, whose `ccall` signature now comes from the
  slots the manifest recorded rather than from the runtime Julia argument types.
  A slot that is not a Unicode scalar value is refused rather than turned into
  an invalid `Char`. `Result<char, E>` and `Option<char>` payloads convert too:
  the `CResult_*` / `COption_*` field is declared with the C slot Rust stored
  and the active payload is read back as its surface type
  ([#245](https://github.com/AtelierArith/RustCall.jl/issues/245)). The one
  exception is `i128` / `u128` on `x86_64-pc-windows-msvc`, where MSVC has no
  native 128-bit integer and Rust and Julia disagree on how `extern "C"` passes
  one (rust-lang/rust#54341) — a platform ABI mismatch no Julia-side mapping can
  fix.
- Small-integer and platform-sized struct fields (`u16`, `usize`, …) resolve to
  their own type instead of `Any`
  ([#245](https://github.com/AtelierArith/RustCall.jl/issues/245)).
- Every owned string return names the symbol that releases it, and that symbol
  is resolved inside the library that allocated the buffer — so two libraries
  exporting the same `<owner>_free_rust_string` no longer free through each
  other's allocator
  ([#246](https://github.com/AtelierArith/RustCall.jl/issues/246),
  [#249](https://github.com/AtelierArith/RustCall.jl/issues/249)).

- `#[julia]` is **additive**: the annotated item is kept exactly as written
  (minus the attribute itself) and the `extern "C"` entry point is emitted
  *next to it* under a distinct symbol
  ([#279](https://github.com/AtelierArith/RustCall.jl/issues/279)).
  The export-symbol scheme, documented at the top of
  `deps/rustcall_core/src/codegen.rs`, is:

  | generated item | symbol |
  |---|---|
  | free function `f` | `rustcall_f` |
  | method / constructor `Struct::m` | `rustcall_Struct_m` |
  | specialized generic instantiation `f_i32` | `rustcall_f_i32` |
  | destructor / accessors / clone | `Struct_free`, `Struct_get_x`, `Struct_set_x`, `Struct_clone` (unchanged) |
  | `Result` / `Option` payloads | `CResult_f`, `COption_f` (unchanged) |
  | string buffers | `<owner>_RustCallOwnedString`, `<owner>_free_rust_string`, `<owner>_RustCallBorrowedString` (unchanged) |

  Nothing changes for Julia users: `add(1, 2)`, `@rust add(...)`, `@rust_crate`
  and `write_bindings_to_file` all go through the manifest's `symbol` field.
  What changes is that `fn shout(s: String) -> String` still *exists* in Rust
  after expansion, so `#[julia]` now composes with `#[pyfunction]`, with
  in-crate callers, with `#[test]`s and with `pub use` re-exports. Anyone who
  `dlsym`ed the Rust name directly must switch to the `rustcall_`-prefixed
  symbol, and any generated bindings (e.g. a `write_bindings_to_file` module)
  must be regenerated.
- The FFI manifest schema is now version 3
  ([#279](https://github.com/AtelierArith/RustCall.jl/issues/279)):
  `Function.symbol` and `Method.symbol` differ from `name` for *every* wrapped
  item, not only for generic instantiations. A RustCall.jl expecting schema 2
  refuses a version-3 manifest and vice versa. **Rebuild the extractor** with
  `Pkg.build("RustCall")` after updating.
- The FFI manifest schema was version 2 (`rustcall_core::manifest::SCHEMA_VERSION`,
  `RustCall.MANIFEST_SCHEMA_VERSION`): the string ABI columns `abi`,
  `return_abi` and the `has_owned_string_helper` / `has_borrowed_string_helper`
  flags change how the exported symbols must be called, so a RustCall.jl that
  expects schema 1 refuses a version-2 manifest and vice versa. Rebuild the
  extractor with `Pkg.build("RustCall")` after updating.

### Deprecated
- The LLVM IR integration path is deprecated and will be removed in a future
  breaking release ([#265](https://github.com/AtelierArith/RustCall.jl/issues/265)).
  Affected entry points emit `Base.depwarn` and keep working unchanged:
  `@rust_llvm`, `compile_and_register_rust_function`, `get_registered_function`,
  `compile_rust_to_llvm_ir`, `load_llvm_ir`, `get_function_signature`,
  `get_or_compile_function`, `OptimizationConfig`, `set_default_opt_config`,
  `optimize_module!`, `optimize_function!`, `optimize_for_speed!`,
  `optimize_for_size!`, `optimize_balanced!`.
  Reasons: `@rust_llvm` performs the same function-pointer `ccall` as `@rust`,
  and rustc tracks a newer LLVM than the one bundled with Julia, so the emitted
  IR cannot be parsed reliably. Use `@rust` instead.

### Added
- `#[julia]` functions accept `String` / `&str` arguments and return `String` /
  `&str` ([#242](https://github.com/AtelierArith/RustCall.jl/issues/242)):
  the wrapper uses the same `(ptr, len)` ABI and `<fn>_RustCallOwnedString` /
  `<fn>_free_rust_string` helpers as struct methods, the manifest records
  `has_owned_string_helper` / `has_borrowed_string_helper`, and the Julia
  wrappers (inline blocks and `@rust_crate`) convert transparently.
- CI/CD pipeline with GitHub Actions
- Support for multiple Julia versions (1.10, 1.11, nightly)
- Cross-platform testing (Linux, macOS, Windows)
- CompatHelper integration for dependency updates
- TagBot integration for automated version tagging

### Changed
- Rust syntax is no longer parsed on the Julia side. `rust"""` blocks,
  `@rust_crate` and generics go through the `rustcall-extract` CLI
  (`deps/rustcall_core`, `deps/rustcall_extract`), which emits a TOML FFI
  manifest ([#264](https://github.com/AtelierArith/RustCall.jl/issues/264),
  [#266](https://github.com/AtelierArith/RustCall.jl/pull/266)).
- `#[cfg(...)]`-disabled items are no longer reported by the FFI manifest:
  `rustcall-extract manifest`/`expand` take `--cfg-file` (the output of
  `rustc --print cfg`), evaluate `all`/`any`/`not`/`name`/`name = "value"`
  predicates on items, impl methods, struct fields and inline modules, and drop
  what rustc would not compile. Every reported item records its predicate in a
  new `cfg` field. For direct `rustc` builds Julia queries the configuration
  with the same target and codegen flags as the compilation (`:strict`); for
  the Cargo projects RustCall generates (`// cargo-deps:` blocks) it evaluates
  the same way against Cargo's effective configuration, probed with a throwaway
  crate (`:cargo`). Only external crates (`@rust_crate`), whose features and
  build script RustCall does not control, decide target predicates alone
  (`--cfg-lenient`, `:lenient`). The cfg set is part of the toolchain fingerprint (follow-up of #264).
- Function parameters carrying their own `#[cfg]`
  (`fn f(a: i32, #[cfg(any())] b: i32)`) are pruned like items, so the manifest
  and the generated wrapper match the C ABI rustc actually compiles
  (follow-up of #264).
- Crate-level `#![cfg(...)]` / `#![cfg_attr(...)]` is evaluated before the
  items: a block or crate disabled at file level compiles to nothing, so
  nothing is reported instead of emitting bindings for symbols that never
  exist (follow-up of #264).
- `cfg_attr` expansion runs until nothing changes, so any nesting depth
  reaches its `cfg`; the remaining safety limit (64 levels) is an error, never
  a partial expansion (follow-up of #264).
- Cargo-backed `rust"""` blocks record the tracked Cargo environment as a
  snapshot that is authoritative even when empty: a build or precompiled
  reload clears a `RUSTFLAGS` / profile override that was not set at
  expansion time instead of inheriting it. `CARGO_TARGET_<TRIPLE>_RUSTFLAGS`
  and `CARGO_TARGET_<TRIPLE>_LINKER` are now tracked as well (credential-like
  names stay excluded).
- The in-memory identity of a direct-`rustc` block (`rust_<hash>`) now covers
  the compiler snapshot (target, opt-level, debug info), the cfg text and the
  rustc environment (`RUSTFLAGS`, `RUSTUP_TOOLCHAIN`), through the same
  `_block_identity` helper Cargo-backed blocks use, so the same source built
  under two configurations is two libraries and a lookup never returns the
  other build.
- `#[cfg]`-disabled generic parameters (`fn f<#[cfg(any())] T, U>`, lifetimes
  and const generics, on functions, impls, structs, enums and traits) are
  pruned like items and function parameters (follow-up of #264).
- `--cfg-file` values are parsed as Rust string literals and unescaped exactly
  once, so `custom="\"quoted\""` is no longer conflated with
  `custom="quoted"`; a malformed value is an error.
- `CARGO_HOME` is part of the tracked Cargo environment, together with a
  digest of the effective `$CARGO_HOME/config.toml` (whose `[build] rustflags`
  the cfg probe observes), so a block precompiled under one Cargo home is
  rebuilt rather than reused under another.
- Generic functions of a `// cargo-deps:` block whose body contains `#[cfg]`
  or `cfg!` (reported by the new `body_has_cfg` manifest field) refuse lazy
  specialization with a `RustError`: the specialization is a direct `rustc`
  build under a different configuration than the Cargo build, so the body
  could take another branch. Move such code out of the generic body.
- After a reload that derives a new library name (toolchain or snapshot
  changed since precompilation), the loaded handle is aliased under the
  stored name and the module's active library is updated, so later calls no
  longer reload on every call or fall back to the global symbol search.
- The `CResult_<fn>` / `COption_<fn>` wrappers store the inactive payload as
  `MaybeUninit<T>`, so zero-filling it is no longer undefined behaviour for
  types with invalid zero bit patterns (`NonZeroU32`, references). The C
  layout is unchanged. Rust code reading the wrappers must use the new
  `ok()`, `err()` and `some()` accessors instead of the raw fields
  (follow-up of #264).
- `#[julia]` functions returning `Result`/`Option` keep their `#[cfg]`
  attributes on every generated item (wrapper struct, inner fn, extern fn),
  including the `#[cfg_attr(pred, cfg(...))]` form, which decides whether the
  function is compiled just like a direct `#[cfg]`.
- `rustcall-extract` reads its arguments as `OsString`, so non-UTF-8 file
  paths work on Windows (follow-up of #264).


## [0.1.0] - 2026-01-XX

### Added
- **Phase 1: C-Compatible ABI**
  - `@rust` macro for calling Rust functions
  - `rust""` string literal for compiling and loading Rust code
  - `@irust` macro for function-scope Rust execution
  - Type mapping between Rust and Julia types
  - `RustResult<T, E>` and `RustOption<T>` support
  - String type support (`*const u8`, `Cstring`)
  - Compilation caching system (SHA256-based)

- **Phase 2: LLVM IR Integration**
  - `@rust_llvm` macro (experimental)
  - LLVM optimization passes
  - Ownership types: `RustBox`, `RustRc`, `RustArc`, `RustVec`, `RustSlice`
  - Array operations (indexing, iteration, conversion)
  - Generics support with automatic monomorphization
  - Enhanced error handling with `RustError` exception type
  - Function registration and caching system

- **Phase 3: External Library Integration**
  - Cargo dependency management
  - Support for `//! ```cargo ... ``` ` and `// cargo-deps:` formats
  - Automatic crate downloading and building
  - Integration with popular crates (ndarray, serde, rand, etc.)

- **Phase 4: Rust Structs as Julia Objects**
  - Automatic struct detection and Julia wrapper generation
  - C-FFI wrapper generation for Rust methods
  - Dynamic Julia type generation at macro expansion time
  - Automatic memory management with finalizers
  - Managed lifecycle for Rust objects in Julia

### Documentation
- Comprehensive API documentation
- Design documents (Phase1-4)
- Usage examples and tutorials
- Performance benchmarks
- Troubleshooting guide

### Testing
- 750+ tests covering all major features
- Test suites for cache, ownership, arrays, generics, error handling
- Integration tests for Rust helpers library
- Documentation examples tests

[Unreleased]: https://github.com/atelierarith/RustCall.jl/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/atelierarith/RustCall.jl/releases/tag/v0.1.0
