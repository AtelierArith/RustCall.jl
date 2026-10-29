# Callbacks: passing a Julia function to Rust

A `#[julia]` function or method may take a **C-ABI function pointer**, and a
Julia function — a closure included — can be passed for it
([#296](https://github.com/AtelierArith/RustCall.jl/issues/296)):

```julia
rust"""
#[julia]
pub fn apply(f: extern "C" fn(i64) -> i64, x: i64) -> i64 { f(x) + 1 }

#[julia]
pub fn each(n: u32, visit: extern "C" fn(u32, f64)) {
    for i in 0..n { visit(i, i as f64 * 0.5) }
}
"""

apply(x -> 2x, 20)                 # 41
k = 10
apply(x -> x + k, 1)               # 12 — a closure over a local works
seen = Float64[]
each(4, (i, v) -> push!(seen, v))  # seen == [0.0, 0.5, 1.0, 1.5]
```

The manifest reports the pointer's own signature (`Arg.abi = "callback"`,
`Arg.callback_args`, `Arg.callback_return`), and the wrapper builds a
`@cfunction` from it — Julia never reads the Rust spelling
([#264](https://github.com/AtelierArith/RustCall.jl/issues/264)). What the
pointer may take and return is decided by this contract, at wrapper
generation and never at call time: every parameter and the return must be a
type the table passes **by value or as a raw pointer in one slot whose slot
type is its Julia type** — the numeric primitives, `bool`, `usize` / `isize`,
`*const T` / `*mut T`, and `()` for the return. `&str`, `String`, `char`
(its slot is a `UInt32` code point), aggregates and anything outside the table
are refused with a `RustError` naming the argument. A Rust-ABI `fn(..)`
pointer is not a callback and cannot take a Julia function; only
`extern "C"` (or `unsafe extern "C"`) qualifies. Callbacks are supported in
argument position only — a Rust function handing a pointer *back* to Julia
has no owner for it — and not in generic functions.

Three rules come with the feature:

* **Synchronous borrow.** Rust may call the pointer while the call that
  passed it is on the stack, and not after. The pointer Rust receives is a
  constant — one plain slot function per callback position, compiled for
  those slot types — and the Julia function it stands for lives in a frame
  the wrapper pushes onto a task-local stack for exactly the duration of the
  call (no closure `@cfunction`, which Julia does not offer on every
  platform). Invoking the pointer after the call returned is a bug on the
  Rust side, as it would be in C; Julia does not raise inside it (that would
  unwind through Rust) but records a `RustError` that the next guarded Rust
  call on the task re-raises, and returns a zero of the return type
  (`C_NULL` for a pointer). A Rust side that wants to *keep* a
  callback — a registered handler, a `Box<dyn Fn>` stored in a struct — must
  not take it this way; keep the Julia object alive yourself and pass an
  opaque handle instead.
* **Same thread.** The pointer may be entered only on the thread that made
  the call. A `@cfunction` entered from a thread Rust spawned itself, which
  Julia's runtime does not know about, takes the process down; the type
  system cannot tell the two apart, so this is a rule for the Rust author.
* **A Julia exception never unwinds through Rust.** The generated trampoline
  catches every exception the callback throws, stores it for the calling
  task, and returns a zero of the return type (`C_NULL` for a pointer); Rust continues on that
  sentinel, and once its frames are gone the wrapper re-raises the exception
  — the same object — at the call site. A panic Rust raised *because* of the
  sentinel is consumed, not reported: the exception is the root cause. Only
  the first exception of a call is kept. This is the reverse of the panic
  channel of [Panics](panics.md), and the two are kept apart: a Rust panic
  inside a callback-driven call is a `RustPanicError`, a Julia exception from
  the callback is that exception.

The `@rust_crate` bindings and `write_bindings_to_file` emit the same
`@cfunction` for a crate's `#[julia]` items; the generated Rust wrapper passes
the pointer through as written.

