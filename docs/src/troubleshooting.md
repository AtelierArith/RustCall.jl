# Troubleshooting

This guide covers common issues and solutions when using RustCall.jl.

```@setup troubleshooting
using RustCall
```

## Installation and Setup

### Problem: no working rustc

**Error message:**
```
No working rustc found. RustCall.jl resolves the compiler through RustToolChain.jl, ...
```

RustCall does not look up `rustc` itself. It asks
[RustToolChain.jl](https://github.com/AtelierArith/RustToolChain.jl), which
uses a `rustc` on `PATH` when there is one and otherwise downloads a toolchain
through Julia's Artifacts system. The warning means neither could be run, so
"not on `PATH`" is only one of the possible causes.

**Solution:**

1. Reproduce the resolution and read the underlying error:
   ```julia
   using RustToolChain
   run(`$(RustToolChain.rustc()) --version`)
   ```

2. If you want a system Rust, install it from [rustup.rs](https://rustup.rs/)
   (or a package manager) and make sure `rustc --version` works in the shell
   that starts Julia. A `rustc` on `PATH` takes precedence over the artifact.

3. If you rely on the artifact toolchain, the usual causes are no network
   access or a read-only depot during the first download; fix that and retry.
   On Windows the artifact toolchain also needs the MSVC build tools (a
   linker); see the RustToolChain.jl README.

4. Check Julia itself: RustCall requires Julia 1.12 or later (`VERSION`).

### Problem: Rust helpers library build fails

**Error message:**
```
Rust helpers library not found. Ownership types (Box, Rc, Arc) will not work...
```

**Solution:**

1. Run the build:
   ```julia
   using Pkg
   Pkg.build("RustCall")
   ```

2. Check Cargo availability:
   ```bash
   cargo --version
   ```

3. Check build log:
   ```bash
   cat deps/build.log
   ```

4. Manual build:
   ```bash
   cd deps/rust_helpers
   cargo build --release
   ```

## Compilation Errors

### Problem: Rust code syntax errors

**Error message:**
```
error: expected one of ...
```

**Solution:**

1. Check Rust code syntax:
   - Has `#[no_mangle]` attribute
   - Correctly specifies `pub extern "C"`
   - Function signature is correct

2. Correct example:
   ```rust
   #[no_mangle]
   pub extern "C" fn my_function(x: i32) -> i32 {
       x * 2
   }
   ```

3. Check error message in detail:
   ```julia
   # Clear cache and recompile
   RustCall.clear_cache()
   rust"""
   // Fixed code
   """
   ```

### Problem: Linking errors

**Error message:**
```
undefined symbol: ...
```

**Solution:**

1. Check function name is correct (`#[no_mangle]` required)
2. Verify library is loaded correctly
3. Check platform-specific issues:
   - macOS: `.dylib` file exists
   - Linux: `.so` file exists
   - Windows: `.dll` file exists

### Problem: Type mismatch errors

**Error message:**
```
ERROR: type mismatch
```

**Solution:**

1. Check Rust function signature:
   ```rust
   pub extern "C" fn add(a: i32, b: i32) -> i32
   ```

2. Use correct types on Julia side:
   ```julia
   # Correct
   # @rust add(Int32(10), Int32(20))::Int32
   ```

3. Review the type mapping table

## Runtime Errors

### Problem: Function not found

**Error message:**
```
Function 'my_function' not found in library
```

**Solution:**

1. Check function name spelling
2. Ensure `#[no_mangle]` attribute is present
3. Verify library compiled correctly:
   ```julia
   RustCall.clear_cache()
   rust"""
   #[no_mangle]
   pub extern "C" fn my_test_function() -> i32 { 42 }
   """
   ```

### Problem: Segmentation fault

**Error message:**
```
signal (11): Segmentation fault
```

**Solution:**

1. Check pointer validity:
   ```julia
   # Warning: Don't use invalid or Julia-managed pointers with Rust ownership types
   ```

2. Check array bounds

3. Check memory management (if using ownership types)

## Memory Management Problems

### Problem: Memory leak

**Solution:**

1. An ownership wrapper (`RustBox`, `RustRc`, `RustArc`, `RustVec`) is
   released by its finalizer, but a finalizer runs whenever the GC gets to
   it. Release eagerly with `RustCall.drop!` when the lifetime matters:
   ```julia
   box = RustCall.RustBox(Int32(42))
   try
       # use box
   finally
       RustCall.drop!(box)
   end
   ```

2. `RustCall.drop!` is idempotent: a second call on the same wrapper is a
   no-op, so an eager `drop!` never conflicts with the finalizer.

### Problem: Double free

**Error message:**
```
double free or corruption
```

**Solution:**

A wrapper's own `drop!` cannot double free (see above). A double free means
the same allocation is owned twice: the one raw pointer was handed to two
owning wrappers, or the Rust side freed what a Julia wrapper also owns. Give
every allocation exactly one owner; on the Rust side, return ownership with
`Box::into_raw` and never free it again.

### Problem: Invalid pointer access

**Solution:**

`RustCall.is_valid` and `RustCall.is_dropped` report the *wrapper's* state
only: `is_valid` is false once the wrapper was dropped or its pointer is null.
Neither can tell where a pointer came from or whether the Rust side has
already freed the allocation, so a wrapper built from an arbitrary or dangling
raw pointer passes both checks and still segfaults or double frees. Use them to
catch use-after-`drop!` on a wrapper whose ownership you established (one that
RustCall allocated, or a pointer Rust handed over with `Box::into_raw` and
never freed), not as a substitute for that ownership:
```julia
if RustCall.is_valid(box)
    # not dropped on the Julia side; ownership is still your guarantee
end
RustCall.is_dropped(box)  # true after drop!
```

## FAQ

### Q: When should I clear the cache?

A: Normally never: the cache key covers the source, the toolchain and the
build environment, so a change to any of them compiles fresh. Clearing
(`RustCall.clear_cache()`) is a diagnostic step when a compiled artifact is
suspected to be corrupt or when reclaiming disk space.

### Q: Does it work on Windows?

A: Yes, on Windows, macOS and Linux, given a working Rust toolchain (see
above) and, on Windows, the MSVC build tools. See [Windows](platforms/windows.md).

### Q: Can I use multiple Rust libraries simultaneously?

A: Yes. You can define multiple functions in a single `rust""` block or use multiple blocks:

```@example troubleshooting
# Multiple functions in one block
rust"""
#[no_mangle]
pub extern "C" fn calc_add(a: i32, b: i32) -> i32 { a + b }

#[no_mangle]
pub extern "C" fn calc_mul(a: i32, b: i32) -> i32 { a * b }
"""

result1 = @rust calc_add(Int32(10), Int32(20))::Int32
result2 = @rust calc_mul(Int32(3), Int32(4))::Int32
println("add result = $result1, mul result = $result2")
```

!!! note "Function Name Uniqueness"
    Use unique function names across all `rust""` blocks. If the same function name exists in multiple libraries, an ambiguity error will be raised.

### Q: Can I use Rust generics?

A: Yes, with automatic monomorphization. See [Generics](generics.md) for details.

### Q: Best practices for error handling?

A:
1. Use `Result` type on Rust side
2. Use `result_to_exception` on Julia side
3. Or use `unwrap_or` for default values

## Debugging Tips

### 1. Enable debug logging

RustCall.jl uses Julia's built-in Logging module with `@debug`, `@info`, `@warn`, and `@error` macros.

**Option A: Environment variable (recommended)**

Run Julia with the `JULIA_DEBUG` environment variable:

```bash
JULIA_DEBUG=RustCall julia -e 'using RustCall; ...'
```

Or set it within Julia before loading RustCall:

```julia
ENV["JULIA_DEBUG"] = "RustCall"
using RustCall
```

**Option B: Global logger**

```julia
using Logging
global_logger(ConsoleLogger(stderr, Logging.Debug))
using RustCall
```

Debug logging shows detailed information about:
- Rust code compilation
- Library loading and caching
- Generic function registration and monomorphization
- Function pointer resolution
- Error recovery attempts

### 2. Clear cache

```julia
RustCall.clear_cache()
```

### 3. Check library status

```julia
# List cached libraries
RustCall.list_cached_libraries()

# Check cache size
RustCall.get_cache_size()
```

### 4. Check type information

```julia
# Check type mapping
RustCall.rusttype_to_julia(:i32)  # => Int32
RustCall.juliatype_to_rust(Int32)  # => "i32"

# What the FFI contract says about a position, including its ABI, its ccall
# slots and who releases it
RustCall.ffi_describe("String"; direction = :return, abi = "string")
```

### 5. "The FFI contract cannot describe the return type of ..."

RustCall no longer guesses a return type it cannot derive. The message names the
signature and what the contract knows about the type; see
[The FFI Type Contract](type_contract.md) for the supported spellings.

Three fixes, in order of preference:

1. change the Rust signature to a supported type — pass an aggregate behind a
   pointer (`*mut MyType`) rather than by value;
2. annotate the Julia call site: `@rust f(x)::T`, which bypasses inference
   entirely;
3. for `write_bindings_to_file`, pass `strict = :warn` to fall back to `Any` and
   keep the rest of the crate building while you deal with the offending type.
   `Any` in a `ccall` slot is not well defined, so treat this as temporary.

### 6. "cannot call a Rust function without a return type"

`@rust f(x)` without `::T` needs a return type from the manifest. A plain
`#[no_mangle] extern "C"` function compiled outside a `rust"""` block has none;
either annotate the call (`@rust f(x)::Int32`) or mark the function `#[julia]`
so the extractor reports its signature.

RustCall used to guess here — the return type was taken from the type of the
*first argument*, defaulting to `Int64`. That guess is not derivable from an
argument and reading a return slot at the wrong width is undefined behaviour, so
it was removed (#245, #246).
