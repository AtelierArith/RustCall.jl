# Tutorial

This tutorial takes you from an empty Julia session to calling Rust functions
that work with numbers, strings, arrays, errors and objects. It assumes you
know Julia and does not assume you know Rust. If a piece of Rust syntax is
unfamiliar, [Rust for Julia Users](rust_primer.md) explains it in Julia terms.

Every example on this page is run when the documentation is built, so the
output you see is real.

## Before you start

```julia
using Pkg
Pkg.add("RustCall")
```

You need Julia 1.12 or later. You do **not** need to install Rust: RustCall
uses the `rustc` and `cargo` on your `PATH` when they exist and otherwise
downloads a toolchain through
[RustToolChain.jl](https://github.com/AtelierArith/RustToolChain.jl). On
Windows, the linker from the MSVC build tools is also required; see the
[Windows guide](platforms/windows.md).

To check that everything is in place:

```@example tutorial
using RustCall
RustCall.check_toolchain().ok
```

If this prints `false`, look at `RustCall.check_toolchain().problems` and at
[Troubleshooting](troubleshooting.md).

## Your first Rust function

```@example tutorial
rust"""
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

add(10, 20)
```

That is the whole workflow. Three things happened:

1. `rust"""..."""` is a Julia string macro. It handed the text to the Rust
   compiler, which produced a shared library, and loaded that library into the
   running Julia session.
2. `#[julia]` marked `add` as a function to expose. For each marked function
   RustCall defines a Julia function of the same name in the current module.
3. `add(10, 20)` is an ordinary Julia call. Its arguments were converted to
   Rust's `i32` and the `i32` result came back as an `Int32`.

Reading the Rust: `fn` defines a function, `a: i32` is an argument named `a` of
type 32-bit integer, `-> i32` is the return type, and the last expression of
the body, written without a semicolon, is the returned value.

The first evaluation of a block takes a second or so because `rustc` runs.
The result is cached on disk, so the same block loads almost instantly in
every later session.

### Arguments are converted, strictly

The generated Julia function accepts anything that converts *exactly* to the
declared Rust type, and refuses the rest in Julia, before Rust is called:

```@example tutorial
typeof(add(10, 20))
```

```@example tutorial
try
    add(2^40, 1)          # does not fit in an i32
catch err
    sprint(showerror, err)
end
```

## Numbers

Rust's numeric types have fixed widths and map directly onto Julia's:
`i32` ↔ `Int32`, `i64` ↔ `Int64`, `u64` ↔ `UInt64`, `f64` ↔ `Float64`,
`bool` ↔ `Bool`, and `usize` ↔ `UInt` (the type Rust uses for every length and
index). The full table is in the [primer](rust_primer.md#Types).

A block may define any number of functions:

```@example tutorial
rust"""
#[julia]
fn sum_of_squares(n: u64) -> u64 {
    let mut total = 0;
    for i in 1..=n {
        total += i * i;
    }
    total
}

#[julia]
fn hypot2(x: f64, y: f64) -> f64 {
    (x * x + y * y).sqrt()
}

#[julia]
fn is_even(n: i64) -> bool {
    n % 2 == 0
}
"""

sum_of_squares(10), hypot2(3.0, 4.0), is_even(42)
```

New Rust in this block:

- `let mut total = 0;` declares a variable that may be reassigned. Without
  `mut` a variable is immutable.
- `1..=n` is the inclusive range, Julia's `1:n`. `1..n` would stop at `n - 1`.
- `(…).sqrt()` is a method call on an `f64`.

Note that `sum_of_squares` returns a `UInt64`, which Julia prints in
hexadecimal (`0x0000000000000181` is 385). If you want Julia's usual `Int`,
declare the Rust return type as `i64`.

## Strings

Take a string as `&str` (a borrowed UTF-8 string) and return one as `String`
(an owned one). Both are a Julia `String` on the Julia side:

```@example tutorial
rust"""
#[julia]
fn greet(name: &str) -> String {
    format!("Hello, {name}!")
}

#[julia]
fn count_chars(s: &str) -> usize {
    s.chars().count()
}
"""

greet("Julia"), count_chars("世界")
```

`format!` is Rust's `string(...)` / interpolation; `{name}` inserts the
variable. Julia strings and Rust strings are both UTF-8, so the argument is
passed without re-encoding, and the returned `String` is copied into a new
Julia `String` and then released on the Rust side for you.

## Arrays

A Rust *slice*, written `&[T]`, is a pointer and a length: a view of someone
else's contiguous memory. A `#[julia]` function that takes one receives a view
of your Julia `Vector`, with no copy. `&mut [T]` is the writable version, and
writes land in your array:

```@example tutorial
rust"""
#[julia]
fn mean(xs: &[f64]) -> f64 {
    xs.iter().sum::<f64>() / xs.len() as f64
}

#[julia]
fn scale(xs: &mut [f64], factor: f64) {
    for x in xs.iter_mut() {
        *x *= factor;
    }
}
"""

v = [1.0, 2.0, 3.0]
m = mean(v)
scale(v, 10.0)
m, v
```

New Rust: `xs.iter()` is an iterator over the elements, `xs.len()` is the
length (a `usize`, so `as f64` converts it), and `*x` writes *through* the
mutable reference `x`.

Because the memory is shared rather than copied, the element type must match
exactly. A `Vector{Int}` is not silently converted to `Float64`:

```@example tutorial
try
    mean([1, 2, 3])
catch err
    sprint(showerror, err)
end
```

The rules for views, aliasing and multi-dimensional data are in
[Julia arrays as Rust slices](tutorial_new_features.md#Julia-arrays-as-Rust-slices).

## Errors

Rust does not throw exceptions for expected failures. A function that can fail
returns a `Result<T, E>`: either `Ok(value)` or `Err(error)`. A function that
may have no answer returns an `Option<T>`: either `Some(value)` or `None`.

```@example tutorial
rust"""
#[julia]
fn safe_div(a: i32, b: i32) -> Result<i32, String> {
    if b == 0 {
        Err("division by zero".to_string())
    } else {
        Ok(a / b)
    }
}

#[julia]
fn first_positive(xs: &[i64]) -> Option<i64> {
    xs.iter().copied().find(|x| *x > 0)
}
"""

ok  = safe_div(10, 2)
err = safe_div(1, 0)
ok, err
```

These arrive in Julia as `RustCall.RustResult` and `RustCall.RustOption`.
Nothing is exported from RustCall except its macros, so the helper functions
are written with the `RustCall.` prefix (or imported with
`using RustCall: unwrap, is_ok`):

```@example tutorial
RustCall.is_ok(ok), RustCall.unwrap(ok), RustCall.is_err(err), err.value
```

```@example tutorial
RustCall.unwrap_or(err, Int32(-1))     # a default instead of the error
```

If you prefer Julia's style, turn an `Err` into an exception:

```@example tutorial
try
    RustCall.result_to_exception(err)
catch e
    sprint(showerror, e)
end
```

`Option` works the same way:

```@example tutorial
some = first_positive([-1, 0, 7])
none = first_positive([-1])
RustCall.is_some(some), RustCall.unwrap(some), RustCall.is_none(none), RustCall.unwrap_or(none, 0)
```

(`|x| *x > 0` in the Rust above is a closure, Rust's `x -> x > 0`.)

### Panics

A *panic* is Rust's unrecoverable error: an out-of-bounds index, an integer
division by zero, an explicit `panic!`. A panic inside a `#[julia]` function
does not take the Julia session down. It is caught at the boundary and raised
as a Julia exception:

```@example tutorial
rust"""
#[julia]
fn checked_sqrt(x: f64) -> f64 {
    if x < 0.0 {
        panic!("sqrt of a negative number: {}", x);
    }
    x.sqrt()
}
"""

try
    checked_sqrt(-1.0)
catch e
    sprint(showerror, e)
end
```

Use `Result` for failures the caller is expected to handle, and leave panics
for bugs. [Panics, Visibility and Lifetime](panics.md) has the details.

## Objects

Put `#[julia]` on a `struct` and RustCall creates a Julia type for it. The
functions in its `impl` block become Julia functions:

```@example tutorial
rust"""
#[julia]
pub struct Counter {
    value: i32,
}

impl Counter {
    pub fn new(initial: i32) -> Self {
        Self { value: initial }
    }

    pub fn increment(&mut self) {
        self.value += 1;
    }

    pub fn current(&self) -> i32 {
        self.value
    }
}
"""

c = Counter(0)        # calls Counter::new
increment(c)
increment(c)
current(c)
```

How the Rust maps to Julia:

| Rust | Julia |
|------|-------|
| `Counter::new(0)` (a function returning `Self`) | `Counter(0)` |
| `c.increment()` (takes `&mut self`) | `increment(c)` |
| `c.current()` (takes `&self`) | `current(c)` |
| the field `value` | `c.value`, readable and assignable |

```@example tutorial
c.value = 10
current(c)
```

The data lives on the Rust side. The Julia `Counter` holds a pointer to it, and
when Julia's garbage collector collects the Julia object, RustCall has Rust
drop the value. You never free it by hand.

!!! note "Method names are ordinary Julia functions"
    `increment` and `current` are defined in your module like any other
    function. A Rust method named `get`, `length` or `show` would therefore
    define a *new* function of that name in your module rather than extend
    `Base`'s. Choose method names that do not collide with the names you use
    from `Base` in the same module.

[Struct Mapping](struct_mapping.md) covers static methods, `Result`-returning
methods, generic structs and `Clone`.

## Using crates from crates.io

Rust's package registry is [crates.io](https://crates.io). To use a crate in a
block, name it in a `// cargo-deps:` comment on the first lines:

```julia
rust"""
// cargo-deps: rand = "0.8"

use rand::Rng;

#[julia]
fn roll_die() -> i32 {
    rand::thread_rng().gen_range(1..=6)
}
"""

roll_die()
```

RustCall then builds the block with `cargo` instead of plain `rustc`, which
downloads and compiles the dependency. The first build needs network access
and takes longer; the result is cached like any other block.

## The manual way: `extern "C"` and `@rust`

`#[julia]` is a convenience over the classic way of exposing Rust to other
languages, which you can also use directly:

```@example tutorial
rust"""
#[no_mangle]
pub extern "C" fn multiply(a: i32, b: i32) -> i32 {
    a * b
}
"""

@rust multiply(Int32(5), Int32(7))::Int32
```

- `extern "C"` makes the function use the C calling convention, and
  `#[no_mangle]` keeps its name `multiply` in the compiled library.
  ([Why both are needed](rust_primer.md#What-makes-a-Rust-function-callable-from-another-language).)
- No Julia function is generated for it. `@rust name(args...)::T` looks the
  symbol up in the loaded library and calls it.
- Nothing is converted for you: pass the exact types (`Int32(5)`, not `5`).

The `::Int32` annotation is checked against what RustCall read from the Rust
source, so a wrong one is an error instead of a misread value:

```@example tutorial
try
    @rust multiply(Int32(5), Int32(7))::Float64
catch e
    first(sprint(showerror, e), 110) * "…"
end
```

The annotation can be omitted, at a cost: the call is then resolved
dynamically and is much slower. Keep it.

When to choose which:

| | `#[julia]` | `#[no_mangle] extern "C"` + `@rust` |
|-|------------|-------------------------------------|
| Julia function generated | yes | no, call with `@rust` |
| `&str`, `String`, slices, `Result`, `Option`, structs | yes | no, C types and raw pointers only |
| Argument conversion (`10` → `i32`) | yes | no |
| A panic becomes a Julia exception | yes | **no**: a panic aborts the process |
| Use it when | almost always | you are binding existing C-style Rust, or need full control of the ABI |

Only C-compatible types can appear in a hand-written `extern "C"` signature. A
string, for example, is passed as a pointer to NUL-terminated bytes and must be
decoded in `unsafe` Rust:

```@example tutorial
rust"""
#[no_mangle]
pub extern "C" fn string_length(s: *const u8) -> u32 {
    let c_str = unsafe { std::ffi::CStr::from_ptr(s as *const i8) };
    c_str.to_bytes().len() as u32
}
"""

@rust string_length("世界")::UInt32      # bytes, not characters
```

This is the work `#[julia]` does for you.

## Things worth knowing early

**One block, one library.** Every `rust"""` block is compiled into its own
shared library. Functions in different blocks cannot call each other from
Rust, and a function that takes a `#[julia]` struct must be defined in the
same block as the struct.

**Editing a block.** Re-evaluating an *unchanged* block is free: it is the same
library. Re-evaluating a block whose Rust code changed compiles a second
library, and if it exports a function name the first one still exports,
RustCall refuses it rather than guess which of the two you mean:

```@example tutorial
lib = rust"""
#[julia]
fn answer() -> i32 { 41 }
"""

try
    @eval rust"""
    #[julia]
    fn answer() -> i32 { 42 }
    """
catch e
    first(split(sprint(showerror, e), '\n'))
end
```

The full message names the library to drop. A `rust"""` block evaluates to the
name of the library it loaded, so you can also keep it, as `lib` does above.
Unload the old library and evaluate the edited block again:

```@example tutorial
RustCall.unload_library(lib)
rust"""
#[julia]
fn answer() -> i32 { 42 }
"""

answer()
```

For an edit-compile-run loop on a real crate, [Hot Reload](hot_reload.md)
rebuilds and swaps the library when a source file changes.

**Where a block may appear.** Put blocks at the top level of a module or
script, not inside a function body. The block defines functions and types, and
inside a function those definitions would be local to it.

**The Rust edition.** A block without `// cargo-deps:` is compiled by `rustc`
directly, under `rustc`'s default edition. A few newer conveniences, such as
`panic!("{x}")` capturing a variable by name, need the form with explicit
arguments (`panic!("{}", x)`) there. `format!("{x}")` works everywhere.

**The cache.** Compiled libraries are kept in a Julia scratch space and reused
across sessions. A changed source, compiler or dependency rebuilds; nothing
else does.

```@example tutorial
RustCall.get_cache_size() > 0
```

`RustCall.clear_cache()` empties it. That is rarely the fix for a problem, but
it is always safe.

**When compilation fails.** The Rust compiler's message is shown in a
`RustCall.CompilationError`. Its `help:` lines usually contain the fix. The
[primer's table of common first errors](rust_primer.md#Common-first-errors)
translates the frequent ones.

## Using Rust in a package

A `rust"""` block works inside a package module exactly as above, and the
package precompiles. For a larger amount of Rust, keep it in a real crate with
its own `Cargo.toml`, mark the items `#[julia]`, and bind the crate from Julia:

```julia
module MyPackage
using RustCall
@rust_crate joinpath(@__DIR__, "..", "deps", "my_crate") submodule = "Bindings"
end
```

[External Crate Bindings](crate_bindings.md) explains this workflow,
[Precompilation](precompilation.md) explains how it behaves in a package, and
[Safe Rust/Julia Integration](integration_guide.md) recommends how to lay out
a project of real size.

## Where to go next

- [What's New in v0.9 and v0.10](tutorial_new_features.md): fallible
  constructors, borrowing objects, optional arguments, slices in depth.
- [Examples](examples.md): longer worked examples.
- [The FFI Type Contract](type_contract.md): exactly which types may cross the
  boundary.
- [Generics](generics.md), [Callbacks](callbacks.md), [Hot Reload](hot_reload.md).
- [How RustCall Calls Rust](internals.md): what happens underneath, for the
  curious and for contributors.
