# Panics, Symbol Visibility and Object Lifetime

Three properties of a compiled artifact used to depend on which door it came
through. They no longer do. This page states each one, says what changed, and
gives the matrix of cases that remain genuinely different — because they belong
to the user's crate rather than to RustCall.

## Panics

A Rust `panic!` inside a function you call from Julia raises
[`RustCall.RustPanicError`](@ref). The panic message comes with it, and the
Julia session survives.

```julia
rust"""
#[julia]
fn checked_div(a: i32, b: i32) -> i32 {
    assert!(b != 0, "division by zero");
    a / b
}
"""

checked_div(Int32(10), Int32(2))    # 5

try
    checked_div(Int32(1), Int32(0))
catch e
    e isa RustCall.RustPanicError && println(e.message)
    # "checked_div panicked: division by zero"
end

checked_div(Int32(9), Int32(3))     # 3 — the library is still usable
```

### How it works

Every `extern "C"` wrapper RustCall generates for a `#[julia]` item runs the
body inside `std::panic::catch_unwind`. On a panic the wrapper:

1. records the message in a **thread-local channel of its own**, and
2. returns a sentinel of the right shape — a zeroed primitive, a null pointer,
   an empty string buffer, the `Err`/`None` discriminant of a `CResult_*` /
   `COption_*`.

Julia reads that channel immediately after the call — one `ccall` into a
thread-local read that normally returns 0 — and raises before the sentinel is
ever used. The channel is exported as `<wrapper symbol>_take_panic`, resolved
once per wrapper and cached with the library.

Each wrapper carries its own channel rather than the library sharing one. A
proc macro sees one item at a time and cannot reliably emit anything "once per
crate", and a shared item in one module could not be named from another — a
`#[no_mangle]` symbol is not a Rust path. Per-wrapper channels need no
crate-wide coordination, and they make every generated library self-contained.

### Why unwinding is pinned

`catch_unwind` can only catch a panic that unwinds. RustCall therefore pins
`panic = "unwind"` for everything it builds — twice:

* on the `rustc` command line (`-C panic=unwind`),
* in every `Cargo.toml` it generates, **and** in `CARGO_PROFILE_<PROFILE>_PANIC`
  in the environment it runs Cargo under.

Both, because a manifest key beats an inherited environment variable and an
explicit variable beats a surprising default. Without either, a
`CARGO_PROFILE_RELEASE_PANIC=abort` somewhere in a user's shell profile would
silently produce a library whose boundary can never fire, and the same source
would kill the session instead of raising.

Before this, the direct-`rustc` path passed `-C panic=abort` (a panic killed
the session outright) and the Cargo path took Cargo's default — the same
`rust"""` block, two different failure modes.

### The matrix

| What you wrote | Built by | On a panic |
|---|---|---|
| `#[julia] fn` in `rust"""` | direct `rustc` | `RustPanicError` |
| `#[julia] fn` in `rust"""` with `// cargo-deps:` | Cargo, RustCall's manifest | `RustPanicError` |
| `#[julia]` method / constructor | either | `RustPanicError` |
| `#[julia]` generic instantiation | direct `rustc` | `RustPanicError` |
| `#[julia]` item in a `@rust_crate` crate **without** `cdylib` | Cargo, RustCall's wrapper manifest | `RustPanicError` |
| `#[julia]` item in a `@rust_crate` crate **with** `cdylib` | Cargo, **the user's** manifest | `RustPanicError`, unless their profile pins `panic = "abort"` |
| raw `#[no_mangle] extern "C" fn` you wrote yourself | either | **abort** — RustCall generates no wrapper, so there is no boundary |
| a panic inside a `Drop` impl, or in a generated field accessor | either | **abort** |

Two rows abort, and both are visible from the source:

* **Raw `extern "C"`.** RustCall does not rewrite functions you export
  yourself; there is nothing between your body and the C ABI. Add `#[julia]` to
  get the boundary.
* **A crate that pins `panic = "abort"`.** RustCall does not write that crate's
  manifest and will not override the profile of a crate it merely builds. If
  you want the boundary, remove the pin from the crate's `[profile.release]`.

`RustCall.must_assume_unwind(policy)` answers "could a panic from this door
reach Julia uncaught?" for any policy.

## Symbol visibility

Every artifact is opened `RTLD_LOCAL | RTLD_NOW`. Nothing RustCall loads
publishes its symbols into the process-global namespace.

Two `rust"""` blocks that both export `f` therefore no longer shadow one
another: which `f` a call reaches is decided by the handle it is resolved
through, not by load order. `@rust f(...)` still finds a function defined in
another block — the search walks the loaded libraries by handle
(`RustCall._resolve_call`), which is what it always did.

Before this, a dependency-free block was `RTLD_LOCAL` and the *same* block with
a `// cargo-deps:` line was `RTLD_GLOBAL`. That is the divergence that is gone.

!!! warning "Deprecated escape hatch"
    `RUSTCALL_DLOPEN_GLOBAL=1` restores the old process-global behaviour for
    one minor release, with a warning. It exists only so code that accidentally
    relied on global symbol resolution has time to move to `@rust`. It will be
    removed.

On Windows there is nothing to configure: `LoadLibrary` has no LOCAL/GLOBAL
distinction, and RustCall's behaviour there is unchanged.

## Object lifetime

A `#[julia]` struct handed to Julia is owned by Julia. Its finalizer calls the
Rust destructor `<Struct>_free`, which drops the `Box` the constructor leaked.
This is now true for inline `rust"""` structs as well as `@rust_crate` structs;
inline struct finalizers used to leak, with a comment saying the free had been
disabled to diagnose a segfault.

The rules the finalizer follows, and why:

* **It captures, it does not look up.** The destructor pointer and the
  library's liveness flag are resolved at construction time and stored on the
  object. A finalizer may run while the running thread holds
  `RustCall.REGISTRY_LOCK` — taking it would deadlock — and a `dlsym` plus
  method compilation inside a finalizer is exactly the crash class that made
  the free get disabled in the first place.
* **It cannot double-free.** The pointer is set to `C_NULL` *before* the call,
  so a second finalization is a no-op.
* **It cannot call into an unloaded library.** `unload_library` flips the
  library's liveness flag, and a finalizer whose flag is `false` returns
  without calling. An object outliving its library is inert, not a jump into
  freed text.
* **A method call on a freed object raises**, rather than dereferencing a null
  pointer.

If you need the Rust object to outlive the Julia wrapper, do not let the
wrapper be collected — keep a reference, or use `GC.@preserve` around the
region where the raw pointer is used.

### The allocator contract

An allocation made by one library must be released by **that same library**. A
`Vec` allocated by `librust_a` and freed through `librust_b` is undefined
behaviour even when both were built by the same `rustc`: each `cdylib` links
its own copy of the allocator shim.

RustCall follows this by construction — every release symbol is resolved on the
handle that produced the value:

| Value | Released by | Resolved on |
|---|---|---|
| `#[julia]` struct handle | `<Struct>_free` | the library that constructed it |
| owned `String` return | `<owner>_free_rust_string` | the library that returned it |
| `RustBox` / `RustVec` / `RustArc` payload | `deps/rust_helpers` | the helper library that allocated it |

The consequence for your own code: never hand a pointer obtained from one
`rust"""` block to a free function in another, and never construct a
`RustBox`-family value without the helper library — doing so raises
immediately, with the `Pkg.build("RustCall")` instruction, rather than
producing a value that will crash later.
