# Migrating from `@irust`

!!! note "Removed in 0.9.0"
    `@irust` and `irust"..."` were deprecated in 0.8.0 and removed in 0.9.0
    ([#538](https://github.com/AtelierArith/RustCall.jl/issues/538)). Code
    that still uses them fails with ``UndefVarError: `@irust` not defined``.

Anything an `@irust` snippet computed can be written as a `#[julia]` function
in a `rust"""..."""` block:

1. The snippet becomes the function **body**. Its trailing expression is the
   function's value, and statements, loops and `return` stay as they are.
2. Each `$name` (or `arg1`, `arg2`, …) becomes a **typed parameter**: the Rust
   type of the Julia value you passed (`Int64` → `i64`, `Int32` → `i32`,
   `Float64` → `f64`, `Bool` → `bool`, …).
3. The type the snippet evaluated to is written as the **return type**.
4. Define the block once, at top level, and call the generated Julia function
   wherever the snippet used to be.

`@irust` decided at run time what step 3 says, with several `rustc` runs per
new snippet. That is why it handled scalars only, why a function containing it
could not be inferred, and why `$name` was a textual substitution that reached
inside Rust string literals. A `#[julia]` function has none of these limits.
It is compiled once, its call is type-stable, and it handles `String`, slices,
`Result` / `Option` and `#[julia]` structs.

Each block below shows the removed form as a comment, then its replacement.
`test/test_irust_migration.jl` runs every replacement and checks the values.

**A captured expression.**

```julia
# before (0.8 and earlier)
# compute_irust(x, y) = @irust("\$x * \$y + 10")
# compute_irust(Int32(3), Int32(4))   # 22

# after
rust"""
#[julia]
fn compute(x: i32, y: i32) -> i32 {
    x * y + 10
}
"""
compute(Int32(3), Int32(4))         # => 22
```

**No captured variable** (`irust"..."`), and **explicit arguments** (`arg1`, …).

```julia
# before (0.8 and earlier)
# irust"40 + 2"                     # 42
# @irust("arg1 * 2", x)             # 42

# after
rust"""
#[julia]
fn answer() -> i64 {
    40 + 2
}

#[julia]
fn twice(arg1: i64) -> i64 {
    arg1 * 2
}
"""
x = Int64(21)
answer()                            # => 42
twice(x)                            # => 42
```

**Statements and loops.** The body is unchanged.

```julia
# before (0.8 and earlier)
# @irust("let mut s = 0i64; for i in 0..\$k { s += i; } s")   # 45

# after
rust"""
#[julia]
fn sum_below(k: i64) -> i64 {
    let mut s = 0i64;
    for i in 0..k {
        s += i;
    }
    s
}
"""
k = Int64(10)
sum_below(k)                        # => 45
```

**The return type.** `@irust` asked rustc for it. Now you write it, and it is
the Julia result type.

```julia
# before (0.8 and earlier)
# @irust("\$x as f64")                       # 7.0  :: Float64
# @irust("if \$x > 0 { 1 } else { -1 }")     # 1    :: Int64
# @irust("\$f.is_finite()")                  # true :: Bool
# @irust("(\$f * \$f).sqrt()")               # 3.5  :: Float64

# after
rust"""
#[julia]
fn as_float(x: i64) -> f64 {
    x as f64
}

#[julia]
fn sign_of(x: i64) -> i64 {
    if x > 0 { 1 } else { -1 }
}

#[julia]
fn finite(f: f64) -> bool {
    f.is_finite()
}

#[julia]
fn magnitude(f: f64) -> f64 {
    (f * f).sqrt()
}
"""
x = Int64(7); f = 3.5
as_float(x)                         # => 7.0  :: Float64
sign_of(x)                          # => 1    :: Int64
finite(f)                           # => true :: Bool
magnitude(f)                        # => 3.5  :: Float64
```

A nested helper `fn` inside a snippet becomes a top-level function in the same
block. A snippet that used `$$` for a `macro_rules!` metavariable writes `$`
directly, since a `rust"""` block does no substitution. A panic stays a
catchable `RustCall.RustPanicError` (see [Panics, Visibility and Lifetime](panics.md)).
If you would rather call through the C ABI, write `#[no_mangle] pub extern "C"`
instead of `#[julia]` and call the function with `@rust name(args...)::T`.
