# Safe Rust/Julia integration

RustCall.jl is most predictable when the Rust/Julia boundary is treated as a
small, explicit API rather than as a transparent projection of an arbitrary
Rust crate. This page collects the recommended design for packages that will
ship RustCall bindings.

The broader follow-up work is tracked in [#441](https://github.com/AtelierArith/RustCall.jl/issues/441).

## Recommended architecture

Put a Rust-side facade between Julia and the crate that does the real work:

```text
Julia API
    |
RustCall generated wrapper (`#[julia]`)
    |
Rust facade with a small FFI surface
    |
Existing Rust crate and its internal types
```

The facade should expose primitive values, strings, byte buffers, and
RustCall-supported structs. Keep complex generic types, traits, lifetimes,
async state, and internal crate types on the Rust side. When an object must
remain in Rust, expose it as an opaque, owned object with explicit constructor,
operation, and destruction paths.

This design has three useful properties:

1. Rust's internal representation can change without changing the Julia API.
2. Julia does not have to reproduce Rust's borrow-checker rules.
3. The FFI contract remains small enough to test exhaustively.

Use `#[julia]` for stable package APIs whenever possible. Use `@rust` when an
explicit C-ABI call is required, and reserve `@irust` for small scalar
experiments at the REPL or in notebooks. `@irust` is intentionally not
type-stable and does not support strings, arrays, structs, or 128-bit integers.

## Worked example: `examples/SafeLedger.jl`

[`examples/SafeLedger.jl`](https://github.com/AtelierArith/RustCall.jl/tree/main/examples/SafeLedger.jl)
is a complete package built this way. Its tests run in RustCall's own suite
(`test/test_integration_example.jl`) and as a package in the Examples workflow.

**The facade** (`deps/safe_ledger/src/lib.rs`) is a crate with one `#[julia]`
struct and no `pub` field, so the Julia type RustCall generates for it is only
a handle. Its state, a `HashMap<String, i64>`, never crosses the boundary:

```rust
#[julia]
pub struct Ledger {
    balances: HashMap<String, i64>,
}

#[julia]
impl Ledger {
    #[julia]
    pub fn new() -> Self { /* ... */ }

    #[julia]
    pub fn withdraw(&mut self, account: &str, amount: i64) -> Result<i64, String> {
        // an unknown account, a non-positive amount or insufficient funds is an
        // `Err`, and leaves the ledger unchanged
    }

    #[julia]
    pub fn balance(&self, account: &str) -> Option<i64> { /* ... */ }
}
```

The crate has ordinary `#[cfg(test)]` tests, so `cargo test` checks the Rust
logic before any binding is involved.

**The binding** is one line. `@rust_crate` builds the crate and generates the
`Native` submodule while the package is precompiled:

```julia
@rust_crate joinpath(@__DIR__, "..", "deps", "safe_ledger") submodule="Native"
```

**The Julia API** keeps `Native` internal and wraps the handle in a Julia
object that owns it:

```julia
struct LedgerError <: Exception
    msg::String
end

mutable struct Ledger
    handle::Union{Native.Ledger, Nothing}
    Ledger() = new(Native.Ledger())
end

function Base.close(ledger::Ledger)          # explicit, idempotent release
    handle = ledger.handle
    handle === nothing && return nothing
    ledger.handle = nothing
    finalize(handle)                         # runs the generated destructor now
    return nothing
end

_ok(r::RustCall.RustResult) =
    RustCall.is_ok(r) ? RustCall.unwrap(r) : throw(LedgerError(r.value))

withdraw!(ledger::Ledger, account::AbstractString, amount::Integer) =
    _ok(Native.withdraw(_handle(ledger), String(account), Int64(amount)))
```

`_handle` throws `InvalidStateException` for a closed ledger. `Ledger(f)`
supports the do-block form, which closes the ledger even when its body throws.
Callers never see a `RustResult`, a raw pointer or the generated type:

```julia
SafeLedger.Ledger() do ledger
    SafeLedger.deposit!(ledger, "alice", 100)   # 100
    SafeLedger.withdraw!(ledger, "alice", 500)  # throws LedgerError("insufficient funds in alice: 100 < 500")
end                                             # the Rust allocation is freed here
```

The tests cover construction, normal use, the error path (including that a
failed operation leaves the Rust state unchanged), explicit and do-block
release, and what an object does once its library is unloaded:

- After `RustCall.unload_library(name)`, a call raises. The object still frees
  through its own destructor, because the image is retired but not unmapped.
- After the retired image is closed, a call raises a `RustError` and release
  does nothing: the object leaks rather than running unmapped code.

## Ownership and lifetime rules

- Prefer RustCall ownership types such as `RustBox`, `RustRc`, `RustArc`, and
  `RustVec` when their semantics match the API. Treat `RustSlice` separately:
  it is a borrowed pointer-and-length view and does not retain or release its
  backing allocation, so retain or preserve the owner for the whole use.
- An owned value must have one clear release path. An allocation made by one
  library must be released by that same library.
- Do not return a borrowed reference whose Rust owner can disappear while
  Julia still holds it. Return an owned value or an opaque handle instead.
- Keep Julia references alive for the whole period in which a raw pointer is
  used; use `GC.@preserve` when calling lower-level pointer-based APIs.
- Treat `unload_library(...; close = true)` as a process-level lifetime event:
  no object or call may still depend on the closed image.
- Make error and cleanup paths part of the API design, not an afterthought.

The generated struct wrappers capture the destructor and library liveness at
construction time. This makes normal finalization safer, but it does not make
an invalid Rust pointer or an incorrect ownership transfer safe.

See [The FFI Type Contract](type_contract.md) and [Panics, Visibility and
Lifetime](panics.md) for the exact ABI and loading rules.

## Keep the FFI surface boring

Good boundary types are those with an unambiguous C-compatible representation:

- integers, floating-point values, and booleans;
- `String` and `&str` through the supported RustCall lowering;
- byte buffers and slices with documented ownership;
- `Result`/`Option` where the generated wrapper supports the chosen shape;
- opaque Rust-owned objects with methods that perform the complex work in Rust.

Avoid exposing `Vec<T>` or a user-defined Rust struct merely because it happens
to compile. Check the generated manifest and the [supported type
matrix](type_contract.md) first. Unknown types fail closed by default; do not
make `RustCall.FFI_STRICT[] = :warn` a production solution for an API whose layout has
not been designed.

For callbacks, document the thread and lifetime assumptions explicitly. The
current callback path is for synchronous calls, argument-position callbacks,
and same-thread execution; it is not a general asynchronous callback system.

## Limitations at a glance

| Area | Supported | Not supported, or your responsibility | What to do instead |
| --- | --- | --- | --- |
| Scalars | integers, floats, `bool` | `i128`/`u128` on Windows (a platform ABI mismatch) | split into two `u64`, or pass behind a pointer |
| Strings | `String`/`&str` arguments and returns, copied at the boundary | invalid UTF-8 (rejected with a `RustError`) | send non-text bytes as `*const u8` plus a length |
| Collections | — | `Vec<T>`, `HashMap`, `&[T]` arguments, `Box`/`Rc`/`Arc`/`Cow` in signatures | keep them inside an opaque `#[julia]` struct and expose methods |
| Structs | `#[julia]` structs, used as handles or with `pub` fields of supported types | borrowed references into a struct that outlive it | return owned values; see `examples/SafeLedger.jl` |
| Errors | `Result<T, E>` / `Option<T>` of supported types, as `RustResult` / `RustOption` | — | turn them into Julia exceptions in your wrapper |
| Panics | caught at a generated `#[julia]` boundary, raised as `RustPanicError` | raw `#[no_mangle] extern "C"` functions, and threads Rust spawns | put every entry point behind `#[julia]` |
| Callbacks | `extern "C" fn` arguments, synchronous, on the calling thread | storing a callback for later, calling it from another thread | return control to Julia and call again |
| Threads | calls from any Julia thread | concurrent `&mut self` calls on one object (RustCall does not lock objects) | serialize access to a handle, e.g. with a `ReentrantLock` in the wrapper |
| Lifetime | finalizers, `finalize(obj)` for explicit release | use after `unload_library(...; close = true)` (the call raises, the object leaks) | close images only when nothing still uses them |
| Generics | generic functions and structs, monomorphized on demand | trait objects, explicit lifetime parameters | expose concrete facade functions |
| `@irust` | scalar snippets at the REPL | strings, arrays, structs, 128-bit integers; type stability | `rust"""..."""` or a crate with `#[julia]` |

## Build and CI practices

- Commit `Cargo.lock` for applications, fixtures, and RustCall integration
  crates where reproducibility matters.
- Warm and persist the RustCall cache in CI or distribution builds. Expect the
  first build to be slower because Rust and Cargo may be invoked and registry
  dependencies may be downloaded.
- In a downstream package, build RustCall through Julia's package manager:

  ```julia
  using Pkg
  Pkg.build("RustCall")
  ```

  The `deps/build.jl` command and `RUSTCALL_EXTRACT` override are for a
  RustCall source checkout and contributor workflow; a downstream package
  should use its normal Julia environment and RustCall's installed product
  lookup.

- Test the supported Julia/Rust/OS matrix, including Windows linker and SDK
  requirements when Windows is supported.
- Use `RUSTCALL_OFFLINE=1` in an offline CI job after prefetching the declared
  dependency closure. This catches undeclared network requirements.
- Keep Rust dependencies behind the facade. This reduces both the generated
  binding surface and the number of platform-specific build scripts that
  affect Julia users.

### Warming and persisting the caches

A cold build has three costs: downloading the Rust toolchain when there is no
system one, downloading crates, and compiling. Each is stored somewhere you can
persist between CI runs:

| What | Where | Filled by |
| --- | --- | --- |
| compiled Rust libraries, and the `Cargo.lock` of each `// cargo-deps:` set | `RustCall.get_cache_dir()`, or `RUSTCALL_CACHE_DIR` when set | the first build of each block or crate |
| crate sources from the registry | `$CARGO_HOME/registry` and `$CARGO_HOME/git` (default `~/.cargo`) | Cargo |
| Julia precompile images, including `@rust_crate` modules | the depot's `compiled/` | `Pkg.precompile()` |
| the artifact Rust toolchain, when there is no system `rustc` | the depot's `artifacts/` | RustToolChain |

`Pkg.precompile()` builds every `@rust_crate` crate, because the bindings are
generated during precompilation. An inline `rust"""` block may still compile on
first use, so run the test suite (or a script that calls each entry point once)
while warming the cache.

A GitHub Actions sketch:

```yaml
- uses: julia-actions/setup-julia@v2
- uses: julia-actions/cache@v2          # the depot: packages, artifacts, compiled/
- uses: actions/cache@v4
  with:
    path: |
      ${{ runner.temp }}/rustcall-cache
      ~/.cargo/registry
      ~/.cargo/git
    key: rustcall-${{ runner.os }}-${{ hashFiles('deps/**/Cargo.toml', 'deps/**/Cargo.lock', 'deps/**/*.rs', 'src/**/*.jl', 'Manifest.toml') }}
    restore-keys: rustcall-${{ runner.os }}-
- run: julia --project -e 'using Pkg; Pkg.instantiate(); Pkg.precompile(); Pkg.test()'
  env:
    RUSTCALL_CACHE_DIR: ${{ runner.temp }}/rustcall-cache
```

A restored cache cannot serve a stale library. Every entry's key is the
`ArtifactId` of what was built (source, dependencies, compiler identity and so
on), so a changed input is a cache miss, not a wrong hit. The outer `hashFiles`
key decides whether the rebuilt entries are **saved**: a GitHub cache is
immutable, and an exact-key hit is never written back. So the key must change
whenever a build input changes: every Rust source, `Cargo.toml` and
`Cargo.lock`, the Julia sources holding `rust"""` blocks, and the Julia
`Manifest.toml` (it pins the RustCall version). If an input is left out, every
run rebuilds the same thing and never stores the result.

### Lockfiles and reproducible builds

- A `// cargo-deps:` block builds against a persisted lockfile
  (`RustCall.lockfile_path(source)`) with `cargo build --locked`. Commit a copy
  if another machine must build the same graph. See
  [Performance](performance.md).
- `@rust_crate` builds a crate one of two ways, and they differ here:
  - A crate that declares `crate-type = ["cdylib"]`, like the example's
    facade, is built **in place**. Cargo resolves against the crate's own
    `Cargo.lock`, so committing that file pins the build. (`SafeLedger` has no
    registry dependencies, so it does not commit one.)
  - Any other crate is built through a generated **wrapper crate** that
    depends on it by path and resolves its own graph; your `Cargo.lock` does
    not pin that build. Declare `cdylib` in the facade, or pin versions in its
    `Cargo.toml` (`serde = "=1.0.210"`).
- For an offline or air-gapped build, run once online to fill the registry and
  RustCall caches, then set `RUSTCALL_OFFLINE=1`. Cargo then fails at once on
  anything it would have to download, rather than hanging.

### Toolchain and platform requirements

- Julia 1.12 or later. Rust stable; CI tests stable and beta.
- RustToolChain uses a `rustc`/`cargo` on `PATH` when there is one and
  downloads an artifact toolchain otherwise, so a machine needs no system Rust.
  The compiler's identity is part of every cache key: a toolchain upgrade
  rebuilds, it does not reuse.
- RustCall is tested on Linux x86_64, macOS aarch64 and Windows x86_64. Windows
  needs the MSVC linker (Visual Studio Build Tools). See
  [Platforms](platforms/windows.md).

## Debugging workflow

When an integration fails, identify the layer before changing the API:

1. **Toolchain/build:** inspect the same executables RustCall resolves, then
   rebuild the helpers:

   ```julia
   using Pkg
   using RustToolChain
   run(`$(RustToolChain.rustc()) --version`)
   run(`$(RustToolChain.cargo()) --version`)
   Pkg.build("RustCall")
   ```

   Inspect the Cargo/build error before clearing the cache. This matters when
   RustCall uses the artifact fallback or when the PATH compiler differs from
   the one RustToolChain selects.
2. **Rust API:** compile and test the facade as a normal Rust crate first.
3. **Manifest and ABI:** verify the generated manifest, `#[julia]` attributes,
   `extern "C"` requirements where applicable, and the type contract.
4. **Loading:** check the loaded/retired libraries and whether a call or object
   still refers to an image that was unloaded.
5. **Runtime:** reduce the failing call to a small test covering construction,
   one successful operation, one error, and cleanup.

For a Rust panic, use a generated `#[julia]` boundary when the panic should be
reported as `RustPanicError`. A raw `#[no_mangle] extern "C"` function has no
generated panic boundary and can abort the process instead. A panic in a
thread or function that RustCall did not wrap is likewise outside the Julia
exception channel.

### Troubleshooting checklist

| Symptom | Check |
| --- | --- |
| `no working rustc`, or a build that cannot find `cargo` | the `RustToolChain.rustc()` / `cargo()` versions above; on Windows, the MSVC build tools |
| a Rust compile error in code you did not write | the generated wrapper, not your facade: `RustCall.expand_inline(source).source` shows what an inline block compiles |
| `CargoBuildError` | Cargo's own message in the error; with `RUSTCALL_OFFLINE=1`, a crate missing from the registry cache |
| an unsupported-type error at wrapper generation | the [type contract](type_contract.md); move the type behind the facade |
| wrong values, but no error | the `extern "C"` signature against the Julia call: argument order, integer width (`Clong`), `bool` |
| `RustPanicError` | the Rust message it carries; reproduce in `cargo test` |
| a crash instead of `RustPanicError` | an entry point without a `#[julia]` boundary, or a panic on a thread Rust spawned |
| "attempted to use a freed ... object" | a call after `close`/`finalize`; have the wrapper check (as `SafeLedger` does) |
| "... is not loaded" / "unloaded ... object" | a library was unloaded while objects or call sites still used it |
| `RustCall.finalizer_failure_count()` grows | a `Drop` implementation that panics |
| a slow first run every time on CI | the caches in [Warming and persisting the caches](#Warming-and-persisting-the-caches) |

See [Troubleshooting](troubleshooting.md) for longer answers.

## Practical decision rule

Use RustCall when Rust supplies a self-contained, performance-sensitive or
ecosystem-rich component and the boundary can be made small. If the design
requires Julia to retain many borrowed references, exchange complex Rust
values field-by-field, or call across the boundary for every tiny operation,
move more of the workflow into the Rust facade before adding more bindings.
