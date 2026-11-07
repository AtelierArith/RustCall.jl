# Tutorial: What's New in v0.9 and v0.10

This tutorial walks through the features added between v0.9.1 and v0.10.0,
one runnable example at a time. It assumes you have read the
[Tutorial](tutorial.md) and know how a `#[julia]` function in a
`rust"""..."""` block becomes a Julia function.

| Feature | Since | Section |
|:--|:--|:--|
| Fallible constructors (`fn new(..) -> Result<Self, E>`) | v0.9.1 | [Fallible constructors](#Fallible-constructors) |
| Passing Rust objects by reference (`&T`, `&mut T`) | v0.9.2 | [Borrowing Rust objects](#Borrowing-Rust-objects) |
| Methods that return a new object (`fn f(&self) -> Result<Self, E>`) | v0.9.2 | [Methods that return a new object](#Methods-that-return-a-new-object) |
| Optional borrows (`Option<&T>`, `Option<&mut T>`) | v0.10.0 | [Optional borrows](#Optional-borrows) |
| Julia arrays as Rust slices (`&[T]`, `&mut [T]`) | v0.10.0 | [Julia arrays as Rust slices](#Julia-arrays-as-Rust-slices) |
| Staged copies for pointer/length APIs (`with_numeric_buffer`) | v0.9.1 | [Staged numeric buffers](#Staged-numeric-buffers) |
| Concrete instances of a dependency's generic type (`generate_crate_instances`) | v0.9.1, composed in v0.10.0 | [Concrete instances of a generic crate type](#Concrete-instances-of-a-generic-crate-type) |

Every example in this page uses an inline `rust"""` block except the last
one, which builds a small Cargo workspace. The same signatures work in a
`#[julia]` crate loaded with `@rust_crate` and in bindings written by
`write_bindings_to_file`.

## Before you start

- **Rebuild after upgrading.** A minor release changes the manifest schema
  (`0.10` for v0.10.x), so an extractor built by an earlier release is refused.
  Run `Pkg.build("RustCall")` once after upgrading.
- **Update the macro crate of your `#[julia]` crates.** The new argument and
  return shapes need a matching producer: `rustcall_julia_macros = "0.7"` for
  v0.10.0 (slices, optional borrows, composed owned returns), `"0.6"` for
  v0.9.2 (borrowed objects, methods returning `Result<Self, E>`), `"0.5"` for
  v0.9.1 (fallible constructors). Bindings check a marker the producer exports and refuse an older
  library *before* calling it, with a message to rebuild. Inline `rust"""`
  blocks need nothing: RustCall generates their wrappers itself.
- **Regenerate written bindings.** A file written by `write_bindings_to_file`
  under an earlier minor release is refused with a message to regenerate it.

```@setup new_features
using RustCall
```

## Fallible constructors

A static method returning `Result<Self, E>` is bound as the struct's
constructor (v0.9.1, #559). Calling it returns a `RustResult`: `Ok` owns a new
Julia object, `Err` carries the error and allocates nothing.

```@example new_features
rust"""
#[julia]
pub struct Account { cents: i64 }

#[julia]
impl Account {
    pub fn new(cents: i64) -> Result<Self, String> {
        if cents < 0 {
            Err(format!("negative opening balance: {cents}"))
        } else {
            Ok(Self { cents })
        }
    }

    pub fn balance(&self) -> i64 { self.cents }
}
"""

opened = Account(100)
RustCall.is_ok(opened)
```

```@example new_features
acc = RustCall.unwrap(opened)
balance(acc)
```

```@example new_features
refused = Account(-5)
(RustCall.is_err(refused), refused.value)
```

A panic inside the constructor is raised in Julia as `RustCall.RustPanicError`,
as for any other `#[julia]` call.

## Borrowing Rust objects

An argument of type `&T`, `&mut T` or `&Self`, where `T` is a `#[julia]`
struct, takes that struct's Julia handle (v0.9.2, #565). The handle is passed
as the pointer it owns; nothing is copied.

```@example new_features
rust"""
#[julia]
pub struct Wallet { cents: i64 }

#[julia]
impl Wallet {
    pub fn new(cents: i64) -> Self { Self { cents } }
    pub fn cents(&self) -> i64 { self.cents }

    pub fn richer_than(&self, other: &Wallet) -> bool {
        self.cents > other.cents
    }

    pub fn take_from(&mut self, other: &mut Wallet, amount: i64) -> bool {
        if other.cents < amount {
            return false;
        }
        other.cents -= amount;
        self.cents += amount;
        true
    }
}

#[julia]
pub fn combined(a: &Wallet, b: &Wallet) -> i64 { a.cents + b.cents }
"""

alice, bob = Wallet(70), Wallet(30)
take_from(bob, alice, 10)
(cents(alice), cents(bob), richer_than(alice, bob), combined(alice, bob))
```

RustCall checks every handle before Rust sees it:

- It must be a handle of the struct the signature names. Passing another
  struct's handle, or an integer, raises `ArgumentError`.
- It must still be live. Passing an object whose finalizer has already run
  raises `RustError`.
- A `&mut` borrow may not alias another borrow of the same call, so
  `take_from(alice, alice, 1)` raises `ArgumentError`. Shared borrows may
  alias: `combined(alice, alice)` is fine.
- The handle stays rooted for the whole call, so a temporary such as
  `combined(Wallet(1), Wallet(2))` is safe.

These checks apply to handles. A required `&T` / `&mut T` position also still
accepts an explicit `Ptr{Cvoid}` (for example `combined(alice, bob.ptr)`),
which is passed through **unchecked**: its layout, liveness and aliasing are
then your responsibility. The optional positions of the next sections refuse
raw pointers altogether.

```@example new_features
try
    take_from(alice, alice, 1)
catch err
    sprint(showerror, err)
end
```

## Methods that return a new object

A method *with a receiver* returning `Result<Self, E>` keeps its own name
and returns an independent object (v0.9.2, #564). The receiver stays valid.

```@example new_features
rust"""
#[julia]
pub struct Jar { beans: i64 }

#[julia]
impl Jar {
    pub fn new(beans: i64) -> Self { Self { beans } }
    pub fn beans(&self) -> i64 { self.beans }

    pub fn split_off(&mut self, amount: i64) -> Result<Self, String> {
        if amount > self.beans {
            return Err("not enough beans".to_string());
        }
        self.beans -= amount;
        Ok(Self { beans: amount })
    }
}

// Used in the next section, "Optional borrows".
#[julia]
pub fn total_beans(a: &Jar, b: Option<&Jar>) -> i64 {
    a.beans + b.map_or(0, |b| b.beans)
}

#[julia]
pub fn refill(target: &mut Jar, donor: Option<&mut Jar>) {
    if let Some(donor) = donor {
        target.beans += donor.beans;
        donor.beans = 0;
    }
}
"""

jar = Jar(100)
small = RustCall.unwrap(split_off(jar, 30))
(beans(jar), beans(small))
```

```@example new_features
split_off(jar, 1000).value
```

The new object owns its own Rust allocation and is freed by its own
finalizer, independently of `jar`.

## Optional borrows

`Option<&T>` and `Option<&mut T>` of a `#[julia]` struct take that struct's
handle or `nothing` (v0.10.0, #571). A present handle gets the same checks
as a required borrow; `nothing` alone means `None`.

The `Jar` block of the previous section also defines two such functions:

```rust
#[julia]
pub fn total_beans(a: &Jar, b: Option<&Jar>) -> i64 {
    a.beans + b.map_or(0, |b| b.beans)
}

#[julia]
pub fn refill(target: &mut Jar, donor: Option<&mut Jar>) {
    if let Some(donor) = donor {
        target.beans += donor.beans;
        donor.beans = 0;
    }
}
```

```@example new_features
(total_beans(jar, nothing), total_beans(jar, small))
```

```@example new_features
refill(jar, small)
(beans(jar), beans(small))
```

A raw pointer is never accepted in an optional position, not even `C_NULL`:
write `nothing`.

!!! note "Declare the struct where you borrow it"
    Each `rust"""` block is compiled into its own library, so a function
    borrowing `Jar` must live in the same block as `Jar` itself. In a crate,
    RustCall must also prove which `#[julia]` struct a borrowed type names: a
    struct imported with `use`, a qualified path such as `&crate::model::Jar`,
    or an unambiguous `use super::*` all work; a type alias does not. See
    [Borrowed owners imported through module globs](crate_bindings.md) for the
    exact rules.

## Julia arrays as Rust slices

A `#[julia]` argument of type `&[T]` or `&mut [T]`, with `T` a primitive
number, borrows the Julia array directly, with no copy (v0.10.0, #570).
Writes through `&mut [T]` land in the caller's array.

```@example new_features
rust"""
#[julia]
pub fn norm2(xs: &[f64]) -> f64 {
    xs.iter().map(|x| x * x).sum::<f64>().sqrt()
}

#[julia]
pub fn axpy(a: f64, x: &[f64], y: &mut [f64]) -> Result<(), String> {
    if x.len() != y.len() {
        return Err(format!("length mismatch: {} vs {}", x.len(), y.len()));
    }
    for (xi, yi) in x.iter().zip(y.iter_mut()) {
        *yi += a * xi;
    }
    Ok(())
}
"""

y = ones(3)
axpy(2.0, [1.0, 2.0, 3.0], y)
y
```

```@example new_features
norm2([3.0, 4.0])
```

A contiguous view, such as a matrix column, is borrowed too:

```@example new_features
A = [1.0 2.0; 3.0 4.0]
norm2(@view A[:, 2])
```

What is checked before Rust runs:

- **Element type, exactly.** `&[f64]` takes `Float64` storage; there is no
  conversion, so `norm2([1, 2])` raises `ArgumentError`. The supported element
  types are `f32`, `f64`, the signed and unsigned 8–64-bit integers,
  `isize` / `usize` (`Int` / `UInt`), and `num_complex::Complex<f32>` /
  `Complex<f64>` (`ComplexF32` / `ComplexF64`).
- **Contiguous, one-dimensional storage.** A `Vector`, a unit-stride view or a
  compatible `reinterpret` is borrowed. A matrix, a reversed view or a strided
  view is refused rather than silently copied; copy it yourself, or see
  [Staged numeric buffers](#Staged-numeric-buffers).
- **No mutable aliasing.** A `&mut [T]` overlapping another slice of the same
  call is refused:

```@example new_features
try
    axpy(1.0, y, y)
catch err
    sprint(showerror, err)
end
```

What is *your* responsibility:

- The borrow lasts until Rust returns. Rust must not keep the pointer, and no
  other task may resize or write the array during the call.
- Mutable storage must be initialized (use `zeros(T, n)`, not
  `Vector{T}(undef, n)`).
- There is no rollback: if Rust writes and then returns `Err` or panics, the
  writes stay.

Use the generated Julia function (`axpy(...)`) to get these checks. Calling
the exported symbol with `@rust` or `ccall` is the raw ABI and checks nothing.

## Staged numeric buffers

Some Rust APIs take a raw pointer and a length rather than a slice.
`RustCall.with_numeric_buffer` (v0.9.1, #557) copies any numeric array —
including a non-contiguous view — into an aligned temporary, hands the
callback its pointer and length, and keeps the temporary alive until the
callback returns.

```@example new_features
rust"""
#[julia]
pub fn sum_raw(ptr: *const f64, len: usize) -> f64 {
    let xs = unsafe { std::slice::from_raw_parts(ptr, len) };
    xs.iter().sum()
}
"""

M = reshape(collect(1.0:6.0), 2, 3)
row = @view M[1, :]          # stride 2: not borrowable as a slice
RustCall.with_numeric_buffer(row; element_type = Float64) do ptr, len
    sum_raw(ptr, len)
end
```

Pass `write = true` when Rust writes through the pointer: the temporary is
copied back into the array after the callback returns normally. Throw inside
the callback to skip the copy-back. Prefer a `&[T]` / `&mut [T]` signature when
you control the Rust side: it borrows without copying and RustCall checks
the element type for you, whereas `element_type` here is only checked against
the Julia array — the Rust pointer type is your promise.

## Concrete instances of a generic crate type

A `#[julia]` item in a crate cannot be generic (generic functions and
structs are a `rust"""` feature, see [Generics](generics.md)). When a dependency exposes a generic type
such as `Accumulator<T>`, `RustCall.generate_crate_instances` writes a small
*facade* crate that wraps the concrete instances you list (v0.9.1, #558).
Since v0.10.0 (#572) the wrappers compose: an argument can borrow another
declared wrapper, and a method can return one.

Suppose a crate `stats` (in `stats/`) contains:

```rust
pub struct Accumulator<T> { total: T, count: u64 }

impl Accumulator<f64> {
    pub fn new(start: f64) -> Self { Self { total: start, count: 0 } }
    pub fn push(&mut self, x: f64) { self.total += x; self.count += 1; }
    pub fn mean(&self) -> f64 { self.total / self.count.max(1) as f64 }
    pub fn merge(&mut self, other: &Self) {
        self.total += other.total;
        self.count += other.count;
    }
    pub fn snapshot(&self) -> Summary {
        Summary { mean: self.mean(), count: self.count }
    }
    pub fn checked_snapshot(&self) -> Result<Summary, String> {
        if self.count == 0 { Err("no samples yet".into()) } else { Ok(self.snapshot()) }
    }
}

impl Accumulator<i64> {
    pub fn new(start: i64) -> Self { Self { total: start, count: 0 } }
    pub fn push(&mut self, x: i64) { self.total += x; self.count += 1; }
    pub fn total(&self) -> i64 { self.total }
}

pub struct Summary { pub mean: f64, pub count: u64 }

impl Summary {
    pub fn new(mean: f64, count: u64) -> Self { Self { mean, count } }
    pub fn mean(&self) -> f64 { self.mean }
    pub fn count(&self) -> u64 { self.count }
}
```

Declare the instances and their methods, and write the facade's source:

```julia
using RustCall

empty = Pair{String,String}[]
instances = [
    (name = "FloatAcc", rust_type = "stats::Accumulator<f64>",
     constructor = (name = "new", args = ["start" => "f64"]),
     methods = [
        (name = "push", args = ["x" => "f64"], return_type = "()", mutable = true),
        (name = "mean", args = empty, return_type = "f64", mutable = false),
        # Borrow another declared wrapper (`other: &FloatAcc`).
        (name = "merge", args = ["other" => (wrapper = :FloatAcc,)],
         return_type = "()", mutable = true),
        # Return a value owned by another declared wrapper.
        (name = "snapshot", args = empty, return_wrapper = :Summary, mutable = false),
        (name = "checked_snapshot", args = empty, return_wrapper = :Summary,
         error_type = "String", mutable = false),
     ]),
    (name = "IntAcc", rust_type = "stats::Accumulator<i64>",
     constructor = (name = "new", args = ["start" => "i64"]),
     methods = [
        (name = "push", args = ["x" => "i64"], return_type = "()", mutable = true),
        (name = "total", args = empty, return_type = "i64", mutable = false),
     ]),
    (name = "Summary", rust_type = "stats::Summary",
     constructor = (name = "new", args = ["mean" => "f64", "count" => "u64"]),
     methods = [
        (name = "mean", args = empty, return_type = "f64", mutable = false),
        (name = "count", args = empty, return_type = "u64", mutable = false),
     ]),
]

mkpath("stats_facade/src")
write("stats_facade/src/lib.rs", RustCall.generate_crate_instances(instances))
```

The generated source is ordinary `#[julia]` code. For example, the first
wrapper reads:

```rust
#[julia]
pub struct FloatAcc { inner: stats::Accumulator<f64> }
#[julia]
impl FloatAcc {
    #[julia]
    pub fn new(start: f64) -> Self {
        Self { inner: <stats::Accumulator<f64>>::new(start) }
    }
    // ...
    #[julia]
    pub fn merge(&mut self, other: &FloatAcc) -> () {
        self.inner.merge(&other.inner)
    }
    #[julia]
    #[rustcall_owned_return(Summary)]
    pub fn snapshot(&self) -> Summary {
        Summary { inner: self.inner.snapshot() }
    }
    // ...
}
```

The generator does not write a `Cargo.toml`; supply one:

```toml
# stats_facade/Cargo.toml
[package]
name = "stats_facade"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
stats = { path = "../stats" }
rustcall_julia_macros = "0.7"
```

Then load the facade like any `#[julia]` crate:

```julia
S = @rust_crate "stats_facade"

a = S.FloatAcc(0.0)
S.push(a, 1.0); S.push(a, 3.0)
b = S.FloatAcc(0.0)
S.push(b, 5.0)
S.merge(a, b)
S.mean(a)                         # 3.0

s = S.snapshot(a)                 # a `Summary`, owned by Julia
(S.mean(s), S.count(s))           # (3.0, 0x0000000000000003)

S.checked_snapshot(S.FloatAcc(0.0)).value   # "no samples yet"

i = S.IntAcc(10)
S.push(i, 5)
S.total(i)                        # 15

S.merge(a, a)                     # ArgumentError: a `&mut` borrow may not alias
S.merge(a, i)                     # ArgumentError: expected a `FloatAcc` handle
```

Points to keep in mind:

- Every method is declared explicitly. The generator inspects nothing in
  `stats`; Cargo checks the types and signatures you wrote.
- `return_wrapper` must name the wrapper that owns the returned native value
  (here `Summary` for `stats::Summary`). Add `error_type` for a
  `Result<Owner, E>`. Wrappers may be named before they are declared.
- A method's Rust call can be replaced with a trusted `expression`, emitted
  verbatim (for example `expression = "self.inner.checked_snapshot()"`).
- The same mapping works as a constructor argument, so
  `constructor = (name = "from_other", args = ["other" => (wrapper = :FloatAcc,)])`
  builds one wrapper from another.

## Where to read more

- [External Crate Bindings](crate_bindings.md): the full rules for slices,
  optional owners, scoped buffers and generated instances, including the
  manifest fields and producer markers.
- [Struct Mapping](struct_mapping.md): `Result<Self, E>` constructors and
  methods.
- [Panics, Visibility and Lifetime](panics.md): what happens to a borrow when
  Rust panics or a library is reloaded.
- [CHANGELOG](https://github.com/AtelierArith/RustCall.jl/blob/main/CHANGELOG.md):
  every change, release by release.
