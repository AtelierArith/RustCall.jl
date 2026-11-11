# Rust for Julia Users

This page is for readers who know Julia well and have written little or no
Rust. It covers the Rust you need to read the rest of this manual and to write
your first functions, and no more. Every section starts from the Julia concept
you already have.

It is not a Rust course. When you want one, [The Rust Programming
Language](https://doc.rust-lang.org/book/) ("the book") is free and is the
standard starting point.

## The vocabulary, in Julia terms

| Rust | Closest Julia counterpart | What it is |
|------|---------------------------|------------|
| `rustc` | `julia` (the compiler half) | The Rust compiler. Turns `.rs` source into a binary, ahead of time. |
| `cargo` | `Pkg` | Build tool and package manager. Downloads dependencies and drives `rustc`. |
| crate | package | One unit of compilation: a library or an executable. |
| `Cargo.toml` | `Project.toml` | A crate's name, version and dependencies. |
| `Cargo.lock` | `Manifest.toml` | The exact dependency versions that were resolved. |
| [crates.io](https://crates.io) | the General registry | Where public crates are published. |
| module (`mod`) | `module` | A namespace inside a crate. Paths are written `a::b::c`. |
| `cdylib` | a `.so` / `.dylib` / `.dll` you would `ccall` into | A crate compiled as a C-compatible shared library. This is what RustCall builds and loads. |

You do not need to install any of this yourself. RustCall gets `rustc` and
`cargo` from [RustToolChain.jl](https://github.com/AtelierArith/RustToolChain.jl),
which uses the ones on your `PATH` if you have them and downloads a toolchain
otherwise.

## Reading a Rust function

```rust
fn scaled_sum(xs: &[f64], factor: f64) -> f64 {
    let mut total = 0.0;
    for x in xs {
        total += x * factor;
    }
    total
}
```

Line by line, against the Julia you would write:

- `fn name(arg: Type, ...) -> ReturnType { ... }` defines a function. **Every
  argument and the return value has a declared, concrete type.** There is no
  equivalent of an untyped Julia argument, and no multiple dispatch: one name is
  one function.
- `let total = 0.0;` introduces a variable. Variables are **immutable unless
  declared `let mut`**. Reassigning a plain `let` is a compile error.
- Statements end with `;`. The **last expression of a block, written without a
  semicolon, is its value**, exactly like the last expression of a Julia
  function. `total` on the last line is the return value. Writing `total;`
  instead would return nothing and fail to compile.
- `for x in xs { ... }` iterates. Ranges are `0..n` (excluding `n`) and `0..=n`
  (including it). **Indexing is zero-based**: `xs[0]` is the first element.
- `//` starts a comment. `#[...]` is an *attribute*, an annotation on the item
  that follows, similar in spirit to a macro such as `@inline` placed before a
  Julia function.
- Names ending in `!`, such as `println!`, `format!`, `vec!` and `panic!`, are
  macros. (In Julia the `!` suffix means "mutates its argument"; in Rust it
  means "this is a macro".)

Rust is compiled ahead of time, so a type error is reported when the code is
compiled, before anything runs. With RustCall that moment is when a
`rust"""..."""` block is evaluated, and the compiler's message appears as a
`RustCall.CompilationError`.

## Types

Rust's primitive types have fixed sizes and map one-to-one onto Julia types.

| Rust | Julia | Note |
|------|-------|------|
| `i8`, `i16`, `i32`, `i64` | `Int8`, `Int16`, `Int32`, `Int64` | |
| `u8`, `u16`, `u32`, `u64` | `UInt8`, `UInt16`, `UInt32`, `UInt64` | |
| `isize`, `usize` | `Int`, `UInt` | Pointer-sized. `usize` is the type of every length and index. |
| `f32`, `f64` | `Float32`, `Float64` | |
| `bool` | `Bool` | |
| `char` | `Char` | A Unicode scalar value, 4 bytes. |
| `()` | `Nothing` | "Unit": the return type of a function that returns nothing. |
| `&str` (argument) | `String` | A borrowed UTF-8 string. |
| `String` (return) | `String` | An owned UTF-8 string, copied into a Julia `String`. |
| `&[T]`, `&mut [T]` | `Vector{T}` | A borrowed view of the Julia array's memory, no copy. |
| `Result<T, E>` | `RustCall.RustResult{T, E}` | See [Errors](#Errors-are-values). |
| `Option<T>` | `RustCall.RustOption{T}` | |

Two differences from Julia matter immediately:

- **An integer literal is `i32` by default, not `Int64`.** `let n = 1;` is an
  `i32` unless the surrounding code forces another type. Write `1i64` or
  `1_u64` for a specific one.
- **There are no implicit numeric conversions.** `x + 1` does not compile when
  `x` is an `f64`; write `x + 1.0`. Convert explicitly with `as`:
  `n as f64`, `x as i32`.

The complete list of what may cross between Julia and Rust, generated from the
package itself, is on [The FFI Type Contract](type_contract.md).

## Ownership and borrowing

This is the idea Rust is known for, and the one with no Julia counterpart.

In Julia, a value lives until the garbage collector finds that nothing refers
to it. In Rust there is no garbage collector. Instead, **every value has exactly
one owner**, and the value is destroyed ("dropped") at the moment its owner goes
out of scope. The compiler inserts the cleanup for you.

To let other code use a value without giving it away, you *borrow* it:

| Written | Read as | Meaning |
|---------|---------|---------|
| `T` | "a `T`" | The value itself. Passing it **moves** ownership to the callee. |
| `&T` | "shared reference to `T`" | Read-only access. Any number may exist at once. |
| `&mut T` | "mutable reference to `T`" | Read-write access. Only one may exist, and no `&T` alongside it. |

The compiler checks these rules. This is why a Rust program without `unsafe`
cannot have a use-after-free or a data race, and why a method that modifies its
object is declared `fn increment(&mut self)` while a read-only one is
`fn get(&self)`.

What this means for you as a RustCall user:

- **A function argument of type `&[f64]` or `&str` borrows the Julia value for
  the duration of the call.** Rust reads (or, for `&mut [f64]`, writes) your
  array in place and must not keep the pointer afterwards.
- **A `#[julia]` struct is owned by Rust and held by Julia as a handle.** The
  Julia object you get back contains a pointer. When Julia's garbage collector
  finalizes it, RustCall asks Rust to drop the value. You do not free it
  yourself.
- **Heap types that own memory, such as `Vec<T>`, are not passed across the
  boundary directly.** Take a slice (`&[T]`) as an argument instead, and keep a
  `Vec` inside a `#[julia]` struct if Rust needs to own it.

`Box<T>` is an owned pointer to a heap value, `Rc<T>` and `Arc<T>` are
reference-counted ones (`Arc` is the thread-safe version). RustCall has Julia
wrappers for them (`RustBox`, `RustRc`, `RustArc`), described in the
[API reference](reference/ownership.md). Most code never needs them.

## Structs and methods

Julia separates data (`struct`) from behaviour (methods found by multiple
dispatch). Rust attaches functions to a type with an `impl` block:

```rust
pub struct Counter {
    value: i32,
}

impl Counter {
    // No `self`: an "associated function", called as `Counter::new(0)`.
    pub fn new(initial: i32) -> Self {
        Self { value: initial }
    }

    // `&mut self`: may modify the object.
    pub fn increment(&mut self) {
        self.value += 1;
    }

    // `&self`: reads the object.
    pub fn get(&self) -> i32 {
        self.value
    }
}
```

- `Self` is the type the `impl` block is for, here `Counter`.
- `new` is a convention, not a keyword. Rust has no constructors. A function
  that returns `Self` plays that role.
- In Rust you would write `counter.increment()`. RustCall generates ordinary
  Julia functions, so in Julia you write `increment(counter)` and
  `Counter(0)`.
- `pub` makes an item visible outside its module. Items are private by default.

## Errors are values

Julia signals failure by throwing an exception. Idiomatic Rust returns the
failure as an ordinary value instead:

```rust
fn safe_div(a: i32, b: i32) -> Result<i32, String> {
    if b == 0 {
        Err("division by zero".to_string())
    } else {
        Ok(a / b)
    }
}
```

- `Result<T, E>` is either `Ok(value)` or `Err(error)`. The caller must look
  at which one it got.
- `Option<T>` is either `Some(value)` or `None`. It is what Julia expresses
  with `Union{T, Nothing}`. Rust has no `nothing` or null that can hide inside
  an arbitrary type.
- Inside Rust, the `?` operator means "if this is an `Err`, return it from the
  current function now; otherwise give me the `Ok` value".

RustCall hands these to Julia as `RustCall.RustResult` and
`RustCall.RustOption`, which you inspect with `RustCall.is_ok`,
`RustCall.unwrap`, `RustCall.unwrap_or` and friends, or convert to an exception
with `RustCall.result_to_exception`. The [Tutorial](tutorial.md) shows each.

### Panics

A *panic* is Rust's version of an unrecoverable error: an out-of-bounds index,
`unwrap()` on a `None`, an explicit `panic!("...")`. It is closer to a Julia
exception, except that Rust code is not expected to catch it.

A panic inside a `#[julia]` function does not crash Julia. RustCall catches it
at the boundary and raises `RustCall.RustPanicError` with the panic message.
See [Panics, Visibility and Lifetime](panics.md) for the exact guarantees.

## Generics

A Rust generic function looks like a Julia parametric method:

```rust
fn identity<T>(x: T) -> T { x }
```

and is compiled the same way Julia compiles one: a separate specialized copy
for each concrete `T` that is used. Rust calls this *monomorphization*. The
difference is that Rust does it ahead of time, so a compiled library contains
only the copies that were requested when it was built.

A *trait* is a named set of methods a type provides, like an informal Julia
interface made explicit. `fn largest<T: PartialOrd>(...)` reads "for any `T`
that can be compared". RustCall compiles the specialization you need the first
time you call a generic function with a new type; see [Generics](generics.md).

## What makes a Rust function callable from another language

By default a Rust function can be called only from Rust. Two things stand in
the way:

1. **The calling convention.** Rust does not promise how it passes arguments.
   `extern "C"` makes a function use the platform's C convention, the one
   Julia's `ccall` speaks.
2. **The symbol name.** The compiler renames ("mangles") every function to
   something like `_ZN4demo3add17h0f2a...E`. `#[no_mangle]` keeps the name
   you wrote, so it can be looked up in the compiled library.

So the hand-written form of an exported function is:

```rust
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}
```

Only C-compatible types may appear in such a signature. A `String`, a slice or
a `Result` has no C representation, so each must be taken apart into pointers
and lengths by hand, in `unsafe` code.

RustCall's `#[julia]` attribute does all of that for you:

```rust
#[julia]
fn greet(name: &str) -> String {
    format!("Hello, {name}!")
}
```

You write a normal Rust function with normal Rust types. RustCall generates the
`extern "C"` wrapper next to it, generates the matching Julia function, and
converts the arguments and the result on both sides. **Use `#[julia]` unless
you have a reason not to.** [How RustCall Calls Rust](internals.md) shows what
is generated.

### `unsafe`

`unsafe { ... }` marks code where the compiler's guarantees are suspended and
the programmer vouches for correctness: dereferencing a raw pointer (`*const T`,
`*mut T`), or calling a C function. You will see it in hand-written
`extern "C"` examples in this manual. With `#[julia]` you rarely write it.

## Common first errors

| The compiler says | Usually means |
|-------------------|---------------|
| `mismatched types: expected f64, found integer` | No implicit conversion. Write `2.0` instead of `2`, or `n as f64`. |
| ``cannot add `{float}` to `i32` `` | The same, inside arithmetic: both operands must have one type. |
| `cannot assign twice to immutable variable` | Declare it with `let mut`. |
| `expected i32, found ()` | The last line of the function ends with `;`, so it returns nothing. Remove the semicolon. |
| `borrow of moved value` | The value was passed by value (moved) and used again. Pass `&value` instead, or call `.clone()`. |
| `cannot borrow as mutable` | The variable or the `self` receiver is not declared `mut` / `&mut`. |
| `index out of bounds` (a panic, at run time) | Indexing is zero-based. The last element is `xs[xs.len() - 1]`. |

Rust's compiler messages are long because they include the fix. Read the lines
that start with `help:`.

## Glossary

- **ABI** (application binary interface): how compiled code passes arguments
  and return values. "The C ABI" is the common language `ccall` and
  `extern "C"` share.
- **Attribute**: `#[...]` before an item. `#[julia]`, `#[no_mangle]`,
  `#[derive(Clone)]`, `#[repr(C)]`.
- **Borrow**: a reference, `&T` or `&mut T`, to a value owned elsewhere.
- **Crate**: a Rust package; also the unit `rustc` compiles.
- **Drop**: destroying a value and releasing what it owns. Automatic at end of
  scope.
- **FFI** (foreign function interface): calling code written in another
  language.
- **Lifetime** (`'a`): the compiler's name for how long a reference is valid.
  Mostly inferred; you will meet it in error messages before you need to write
  one.
- **Macro**: `name!(...)`. Expanded at compile time, like a Julia macro.
- **Monomorphization**: compiling one copy of a generic function per concrete
  type.
- **Panic**: an unrecoverable run-time error that unwinds the stack.
- **Proc macro**: a compiler plugin that rewrites the item it is attached to.
  `#[julia]` in an external crate is one.
- **`repr(C)`**: an attribute that gives a struct the field layout C would use,
  so another language can read it.
- **Trait**: a named interface that types implement.

## Next

Continue with the [Tutorial](tutorial.md), which uses only what this page
introduced.
