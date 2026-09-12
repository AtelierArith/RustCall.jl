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

Every function/method wrapper RustCall generates for a `#[julia]` item runs the
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

### The quiet hook

Rust runs the panic **hook** before the unwind `catch_unwind` catches, so a
panic RustCall handles correctly still printed
`thread '<unnamed>' panicked at ...` to stderr first: a non-incident that looked
like a crash in every log. Since #304 a generated artifact installs a hook that
stays silent while the thread is inside a wrapper boundary and delegates to the
hook it replaced otherwise, so a panic *outside* a boundary — on a thread the
artifact's own code spawned, say — still prints exactly as before.

Mechanically: the image keeps one thread-local depth counter, every wrapper
raises it for the duration of its body, and the image exports
`__rustcall_install_panic_hook` / `__rustcall_uninstall_panic_hook`. Julia calls the
installer **once per image, immediately after `dlopen`** (`load_artifact!`), so
no first call can race another to install it, and calls the uninstaller from
`close_artifact_handle!` before the image is unmapped, so std's registry never
points at a closure whose code is gone.

**Where it applies.** To every artifact RustCall loads that has at least one
generated wrapper: inline `rust"""` blocks (both the direct-`rustc` and the Cargo
flavour), `@irust`, monomorphized generics, the generated `@rust_crate` wrapper
crate, **and a crate of your own annotated with `#[julia]`**. Nothing has to
declare that: `__rustcall_install_panic_hook` is exported exactly by those
artifacts, so the loader asks the image rather than a policy, and a door cannot
forget to opt in.

**Where the counter lives.** Two places, for one reason. The hook can only
consult the counter it captured, so every wrapper in an image must raise the
*same* one.

* When RustCall writes the whole file — the inline flavours and monomorphized
  generics — it puts the counter and the two entry points at the file's root and
  every wrapper takes its guard as `crate::__RustCallBoundary`.
* `#[julia]` cannot do that. An attribute proc macro is handed a single item and
  may only replace that item; it cannot see the crate's other `#[julia]` items,
  and has no reliable place to remember whether it already emitted shared state.
  It does not have to. Your crate already depends on `rustcall_julia_macros` —
  that is where `#[julia]` comes from — so the counter lives *there*, compiled
  once, and a wrapper names its guard `::rustcall_julia_macros::__RustCallBoundary`
  like any other path. `#[no_mangle]` items of a dependency rlib are exported
  from the `cdylib` that links it, so the image still answers to the symbol the
  loader resolves.

The generated `@rust_crate` wrapper crate is a file RustCall writes whole and
still uses the second route: it links the same `rustcall_julia_macros` rlib as
the crate it wraps, so emitting the items itself would define
`__rustcall_install_panic_hook` twice in one `cdylib` — and would give that
image two counters, neither of which the one installed hook could see in full.
One image, one hook, one counter, shared between the wrapper crate and the
`#[julia]` items of the crate it wraps.

The `rustcall_julia_macros` package is a normal library crate (its `#[julia]`
attribute is re-exported from `rustcall_julia_macros_impl`), so nothing in your
`Cargo.toml` changes. Two things to know about the dependency:

* **Do not rename it.** The generated guard names `::rustcall_julia_macros`
  literally, so a `[dependencies]` entry under another key does not compile.
* **Point it at the RustCall.jl that loads your crate** — the
  `deps/rustcall_julia_macros` of that checkout. When RustCall generates a
  wrapper crate around yours it declares the same dependency from its own tree;
  if your crate names a *different* copy, both end up in one `cdylib`, each with
  its own `#[no_mangle] __rustcall_install_panic_hook`, and the link fails with a
  duplicate symbol.

The doubled prefix is deliberate. Julia calls whatever it finds under that name
as a zero-argument `extern "C"` function, so the name has to be one the symbol
scheme can never produce for an item of yours: a wrapper is `rustcall_<stem>`, so
`#[julia] fn install_panic_hook` would otherwise have exported exactly this
symbol. **Names beginning with `__rustcall_` are reserved for RustCall** — do not
define one with `#[no_mangle]`.

**Where it does not.** Code of yours that RustCall never wrapped: a thread your
crate spawned, a `#[no_mangle]` function you exported yourself, a panic in a
constructor called outside a wrapper. Those are outside every boundary, so the
hook delegates and they print exactly as before — which is the point.

**Turning it off.** `RUSTCALL_PANIC_HOOK=default` keeps the default hook for
every artifact in the process. It is the answer to the one thing the hook costs:
a panic inside a generated artifact but outside any wrapper boundary is silent,
and there is no channel for Julia to read its message from. Reach for the
variable when a panic seems to vanish.

**`-C prefer-dynamic` keeps the default hook.** With the default static `std`
every image owns its own hook registry, so one image's hook is invisible to
every other and is dropped together with the image. With a shared `std` the
registry is shared too, and then the hooks of different artifacts interleave:
closing one artifact would replace whatever hook another had installed, leaving
that one's caught panics printing again. RustCall therefore installs nothing
when the build asks for `prefer-dynamic`.

The decision is taken from the environment the artifact was **built** under —
recorded at macro-expansion time and replayed by the Cargo build — falling back
to the live environment for the doors that build in this process, and it reads
`RUSTFLAGS`, `CARGO_ENCODED_RUSTFLAGS` and the per-target
`CARGO_TARGET_<TRIPLE>_RUSTFLAGS`, tokenised, so `-C prefer-dynamic=no` counts
as the "no" it is.

A `prefer-dynamic` that reaches `rustc` some other way — `build.rustflags` in a
Cargo configuration file, which RustCall does not read anywhere — is invisible
to that check, and the hook is then installed after all. What that costs is the
interleaving above, **not** memory safety: the hook is removed from the registry
before its image is unmapped (`close_artifact_handle!`, on the last loader
reference), so no panic ever reaches a closure whose code is gone.

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
| `#[julia]` generic instantiation | direct `rustc`, or Cargo for dependency-backed blocks | `RustPanicError` |
| `#[julia]` item in a `@rust_crate` crate **without** `cdylib` | Cargo, RustCall's wrapper manifest | `RustPanicError` |
| `#[julia]` item in a `@rust_crate` crate **with** `cdylib` | Cargo, **the user's** manifest | `RustPanicError`, unless their profile pins `panic = "abort"` |
| raw `#[no_mangle] extern "C" fn` you wrote yourself | either | **abort** — RustCall generates no wrapper, so there is no boundary |
| a panic inside `Drop`, called by a generated destructor | either, with unwinding enabled | caught; a Julia finalizer increments `finalizer_failure_count()` |
| a panic in a generated field accessor or clone helper | either, with unwinding enabled | `RustPanicError` |

Cases that can still abort:

* **Raw `extern "C"`.** RustCall does not rewrite functions you export
  yourself; there is nothing between your body and the C ABI. Add `#[julia]` to
  get the boundary.
* **A crate that pins `panic = "abort"`.** RustCall does not write that crate's
  manifest and will not override the profile of a crate it merely builds. If
  you want the boundary, remove the pin from the crate's `[profile.release]`.

Generated field accessors and clone helpers use the same unwind boundary as
method wrappers. Their channel is captured before the call, and Julia reads it
before converting an owned or borrowed string result. A caught panic does not
roll back side effects: if a setter panics while dropping the old field value,
do not assume the object still contains its previous value.

A second panic during Rust's unwind cleanup can still abort; `catch_unwind`
does not make double-panicking destructors safe.

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

* **It captures, it does not look up.** The destructor pointer, its panic
  channel and the library's liveness flag are resolved from one image at
  construction time and stored on the
  object. A finalizer may run while the running thread holds
  `RustCall.REGISTRY_LOCK` — taking it would deadlock — and a `dlsym` plus
  method compilation inside a finalizer is exactly the crash class that made
  the free get disabled in the first place.
* **It cannot double-free.** The pointer is set to `C_NULL` *before* the call,
  so a second finalization is a no-op.
* **It cannot call into a closed library.** Closing an image flips its
  liveness flag, and a finalizer whose flag is `false` returns without calling.
  An object outliving its image is inert, not a jump into freed text. Merely
  *unloading* does not flip it — the image is still mapped, so the object still
  frees correctly (see "Libraries are retired, not closed").
* **A destructor panic is counted, not thrown from the finalizer.** The
  generated Rust boundary catches it. The finalizer immediately consumes the
  captured channel without allocating a Julia message buffer, then increments
  `RustCall.finalizer_failure_count()`. No registry lookup, lock or Julia log
  occurs between the destructor call and channel read. Rust's panic hook may
  still write its diagnostic to stderr.
* **A method call on a freed object raises**, rather than dereferencing a null
  pointer.

## Runtime state and lock ordering

RustCall keeps mutable registries in one `Base.Lockable` state container,
`RustCall.STATE`. The older registry names are lock-taking views into that
container, so a read cannot accidentally bypass the state lock. The state lock
protects only short in-memory transactions: compilation, `dlopen`/`dlclose`,
user Julia callbacks, and Rust `ccall`s happen outside it. Finalizers do not
take locks, resolve symbols, or log. `RustBox`, `RustRc`, `RustArc`, and `RustVec`
capture their destructor and image-liveness flag at construction, and share an
atomic exactly-once claim with explicit `drop!`. The deferred-drop queue is
stored in `STATE` and is used only by explicit drops of raw-pointer wrappers
constructed without a helper target; finalizers never enqueue.

If you need the Rust object to outlive the Julia wrapper, do not let the
wrapper be collected — keep a reference, or use `GC.@preserve` around the
region where the raw pointer is used.

### Libraries are retired, not closed

A library leaves the registry two ways: a hot reload replaces it, or you call
`unload_library`. **Neither closes the image.** Everything that *reaches* the
library goes — the registry entry, the symbol tables, the return-type hints,
the monomorphizations, the panic channels, the generated modules' handles — but
the image itself stays mapped.

The reason is the same in both cases: a call can be in flight. A task that read
a function pointer a moment earlier is *inside* that image, and closing it
there is a use-after-`dlclose` — a segfault, not an error. Making the close
safe would need a reader pin on every FFI call: two atomics on the hot path,
paid by every call, to guard against something that happens at most once per
reload. A retired image costs a few hundred kilobytes instead.

While an image is retired its objects keep working. A finalizer holds the
destructor pointer of *its own* image, and that image is still mapped, so an
object allocated before a reload still frees through the code that allocated
it. That is the allocator contract below, holding by construction — and it is
why retirement does not leak: only the code is kept, not the data.

To reclaim the memory, say that nothing is in flight:

```julia
RustCall.unload_library(name; close = true)
RustCall.unload_all_libraries(; close = true)
```

`RustCall.retired_handles()` lists what is waiting, and
`RustCall.retired_handles(name)` narrows it to one library. Closing is also the
moment an image's objects become **inert**: a finalizer whose image has been
closed does nothing, leaking that object rather than jumping into unmapped
code. So `close = true` says two things at once — "no call is in flight" and
"I accept that surviving objects will not be freed".

A REPL session editing Rust in a loop never needs any of this. A long-running
process that reloads thousands of times, or a test harness, does.

#### Reclamation cost assessment (#291)

The current decision is to retain explicit reclamation, not impose a shared
reader counter on every FFI call. `benchmark/benchmarks_retirement.jl` compares
the same cached Rust call with and without two atomic read-modify-write
operations, and checks results and the final zero reader count. Run it with
`julia --threads=4 --project benchmark/benchmarks_retirement.jl`.

An illustrative local run on 2026-09-09 (Darwin x86_64, Julia 1.12.7,
rustc 1.98.0) measured these medians over 20 batches, with 50,000 calls per worker:

| Workers | Cached call | Shared reader counter |
|---|---:|---:|
| 1 | 4.45 ns/completed call | 20.74 ns/completed call |
| 4 | 0.85 ns/completed call | 37.08 ns/completed call |

These are wall-time throughput costs, not concurrent per-call latencies or a
prediction for a real application's workload. The shared counter contends when
workers call the same image. This is only a lower-bound cost probe, **not a safe
reclamation protocol**: publication/recheck ordering and live-object lifetime
pins are still required. An image with no active calls may still own an object
whose destructor must run later. Epoch or hazard-pointer designs can have
different costs; this measurement does not rule them out. Automatic reclamation
would need a complete protocol and workload-level evidence before replacing
the explicit quiescence contract above.

#### Build configuration probe cost (#291)

The Cargo cfg probe is no longer memoized: `build.rs` can read inputs that a
RustCall cache key cannot enumerate. `benchmark/benchmarks_cfg_probe.jl` measures
the cost on an isolated dependency-free crate and checks that changing a file
read by `build.rs` changes the next probe result without editing the script.
Run it with `julia --project benchmark/benchmarks_cfg_probe.jl`.

A local Darwin x86_64 / Julia 1.12.7 run on 2026-09-09 measured a 0.725 s first
probe, a 0.075 s median over ten unchanged probes (range 0.073–0.108 s), and
1.650 s after changing the build-script input. The first measurement includes
Julia compilation; the changed-input measurement includes Cargo rebuild work.
These are illustrative small-crate costs, not bounds for dependency-heavy
workspaces. The probe happens during loading/building, not on each FFI call;
the current decision accepts that cost to avoid a stale build configuration.

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
