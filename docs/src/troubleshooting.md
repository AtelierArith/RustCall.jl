# Troubleshooting

This guide covers common issues and solutions when using LastCall.jl.

```@setup troubleshooting
using LastCall
```

## Installation and Setup

### Problem: rustc not found

**Error message:**
```
rustc not found in PATH. LastCall.jl requires Rust to be installed.
```

**Solution:**

1. Check if Rust is installed:
   ```bash
   rustc --version
   ```

2. If Rust is not installed:
   - Install from [rustup.rs](https://rustup.rs/)
   - Or use a package manager:
     ```bash
     # macOS
     brew install rust

     # Ubuntu/Debian
     sudo apt-get install rustc cargo
     ```

3. Ensure it's in PATH:
   ```bash
   echo $PATH | grep rust
   ```

### Problem: Rust helpers library build fails

**Error message:**
```
Rust helpers library not found. Ownership types (Box, Rc, Arc) will not work...
```

**Solution:**

1. Run the build:
   ```julia
   using Pkg
   Pkg.build("LastCall")
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
   clear_cache()
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
   clear_cache()
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

## FAQ

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

!!! note
    Each `rust""` block registers functions globally. Use unique function names to avoid conflicts.

### Q: Can I use Rust generics?

A: Yes, with automatic monomorphization. See [Generics](generics.md) for details.

### Q: Best practices for error handling?

A:
1. Use `Result` type on Rust side
2. Use `result_to_exception` on Julia side
3. Or use `unwrap_or` for default values

## Debugging Tips

### 1. Enable verbose logging

```julia
using Logging
# global_logger(ConsoleLogger(stderr, Logging.Debug))
```

### 2. Clear cache

```julia
clear_cache()
```

### 3. Check library status

```julia
# List cached libraries
list_cached_libraries()

# Check cache size
get_cache_size()
```

### 4. Check type information

```julia
# Check type mapping
rusttype_to_julia(:i32)  # => Int32
juliatype_to_rust(Int32)  # => "i32"
```
