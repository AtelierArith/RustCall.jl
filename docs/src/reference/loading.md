# Errors and load policy

The exception types RustCall raises, and the one path through which every
compiled artifact is opened, registered, retired and unloaded
(`src/loadpolicy.jl`, #277).

## Loading and lifetime

The user-facing halves of the load path:

- `RustCall.unload_library(name; close = false)` /
  `RustCall.unload_all_libraries(; close = false)` — drop everything the
  registries record about a library. The image stays mapped by default, because
  a call may still be inside it; `close = true` reclaims it, and is the caller
  stating that none is.
- `RustCall.retired_handles()` / `RustCall.retired_handles(name)` — the images
  that have left the registry and are still mapped.
- `RustCall.list_loaded_libraries()` — the registered library names, which now
  include `@rust_crate` libraries.
- `RustCall.RustPanicError` — a Rust `panic!` caught at the FFI boundary.
- `RustCall.finalizer_failure_count()` — how many Rust destructors raised while
  being called from a finalizer (non-zero means objects leaked).

See [Panics, Visibility and Lifetime](../panics.md) for the semantics these guarantee.

## Errors (`src/exceptions.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "exceptions.jl")]
```

## Load policy (`src/loadpolicy.jl`)

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "loadpolicy.jl")]
```
