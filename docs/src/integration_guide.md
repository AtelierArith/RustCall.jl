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

## Ownership and lifetime rules

- Prefer RustCall ownership types such as `RustBox`, `RustRc`, `RustArc`,
  `RustVec`, and `RustSlice` when their semantics match the API.
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
make `FFI_STRICT = :warn` a production solution for an API whose layout has
not been designed.

For callbacks, document the thread and lifetime assumptions explicitly. The
current callback path is for synchronous calls, argument-position callbacks,
and same-thread execution; it is not a general asynchronous callback system.

## Build and CI practices

- Commit `Cargo.lock` for applications, fixtures, and RustCall integration
  crates where reproducibility matters.
- Warm and persist the RustCall cache in CI or distribution builds. Expect the
  first build to be slower because Rust and Cargo may be invoked and registry
  dependencies may be downloaded.
- Run the documented helper build before tests:

  ```bash
  julia --project deps/build.jl
  export RUSTCALL_EXTRACT=deps/rustcall_extract/target/release/rustcall-extract
  ```

- Test the supported Julia/Rust/OS matrix, including Windows linker and SDK
  requirements when Windows is supported.
- Use `RUSTCALL_OFFLINE=1` in an offline CI job after prefetching the declared
  dependency closure. This catches undeclared network requirements.
- Keep Rust dependencies behind the facade. This reduces both the generated
  binding surface and the number of platform-specific build scripts that
  affect Julia users.

## Debugging workflow

When an integration fails, identify the layer before changing the API:

1. **Toolchain/build:** run `rustc --version`, `cargo --version`, and
   `Pkg.build("RustCall")`; inspect the Cargo/build error before clearing the
   cache.
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

## Practical decision rule

Use RustCall when Rust supplies a self-contained, performance-sensitive or
ecosystem-rich component and the boundary can be made small. If the design
requires Julia to retain many borrowed references, exchange complex Rust
values field-by-field, or call across the boundary for every tiny operation,
move more of the workflow into the Rust facade before adding more bindings.
