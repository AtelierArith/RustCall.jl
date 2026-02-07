# RustCall.jl Troubleshooting Guide

This guide explains common problems and their solutions when using RustCall.jl.

## Table of Contents

1. [Installation and Setup](#installation-and-setup)
2. [Compilation Errors](#compilation-errors)
3. [Runtime Errors](#runtime-errors)
4. [Type-Related Issues](#type-related-issues)
5. [Memory Management Problems](#memory-management-problems)
6. [Performance Issues](#performance-issues)
7. [Frequently Asked Questions](#frequently-asked-questions)

## Installation and Setup

### Problem: rustc Not Found

**Error Message:**
```
rustc not found in PATH. RustCall.jl requires Rust to be installed.
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

3. Check if it's added to PATH:
   ```bash
   echo $PATH | grep rust
   ```

### Problem: Rust Helpers Library Cannot Be Built

**Error Message:**
```
Rust helpers library not found. Ownership types (Box, Rc, Arc) will not work...
```

**Solution:**

1. Run build:
   ```julia
   using Pkg
   Pkg.build("RustCall")
   ```

2. Check if Cargo is available:
   ```bash
   cargo --version
   ```

3. Check build log:
   ```bash
   cat deps/build.log
   ```

4. Build manually:
   ```bash
   cd deps/rust_helpers
   cargo build --release
   ```

### Problem: Dependency Installation Error

**Solution:**

1. Check Julia version (1.10+ required):
   ```julia
   VERSION
   ```

2. Reinstall package:
   ```julia
   using Pkg
   Pkg.rm("RustCall")
   Pkg.add("RustCall")
   ```

## Compilation Errors

### Problem: Rust Code Compilation Error

**Error Message:**
```
error: expected one of ...
```

**Solution:**

1. Check Rust code syntax:
   - Is `#[no_mangle]` attribute present?
   - Is `pub extern "C"` correctly specified?
   - Is the function signature correct?

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

### Problem: Link Error

**Error Message:**
```
undefined symbol: ...
```

**Solution:**

1. Check if function name is correct (`#[no_mangle]` is required)
2. Check if library is correctly loaded:
   ```julia
   using RustCall
   # Reload library
   ```

3. Check platform-specific issues:
   - macOS: Does `.dylib` file exist?
   - Linux: Does `.so` file exist?
   - Windows: Does `.dll` file exist?

### Problem: Type Mismatch Error

**Error Message:**
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
   @rust add(Int32(10), Int32(20))::Int32

   # Wrong
   @rust add(10, 20)  # Type may not be inferred
   ```

3. Check type mapping table (see [README.md](../README.md))

## Runtime Errors

### Problem: Function Not Found

**Error Message:**
```
Function 'my_function' not found in library
```

**Solution:**

1. Check function name spelling
2. Check if `#[no_mangle]` attribute is present
3. Check if library is correctly compiled:
   ```julia
   clear_cache()
   rust"""
   #[no_mangle]
   pub extern "C" fn my_function() -> i32 { 42 }
   """
   ```

### Problem: Segmentation Fault

**Error Message:**
```
signal (11): Segmentation fault
```

**Solution:**

1. Check pointer validity:
   ```julia
   # Dangerous: Invalid pointer
   ptr = Ptr{Cvoid}(0x1000)

   # Safe: Get from valid array
   arr = [1, 2, 3]
   ptr = pointer(arr)
   GC.@preserve arr begin
       # Use ptr
   end
   ```

2. Check array bounds:
   ```julia
   arr = [1, 2, 3]
   len = length(arr)
   # Don't access indices beyond len
   ```

3. Check memory management (if using ownership types)

### Problem: String Encoding Error

**Error Message:**
```
invalid UTF-8 sequence
```

**Solution:**

1. Handle UTF-8 strings correctly:
   ```rust
   let c_str = unsafe { std::ffi::CStr::from_ptr(s as *const i8) };
   let utf8_str = std::str::from_utf8(c_str.to_bytes())
       .unwrap_or("");  // Error handling
   ```

2. Pass strings correctly from Julia side:
   ```julia
   # UTF-8 strings are automatically handled
   @rust process_string("こんにちは")::UInt32
   ```

## Type-Related Issues

### Problem: Type Inference Fails

**Solution:**

1. Specify types explicitly:
   ```julia
   # Recommended
   result = @rust add(10i32, 20i32)::Int32

   # Not recommended
   result = @rust add(10i32, 20i32)
   ```

2. Specify argument types explicitly:
   ```julia
   a = Int32(10)
   b = Int32(20)
   result = @rust add(a, b)::Int32
   ```

### Problem: Pointer Type Conversion Error

**Solution:**

1. Use correct pointer types:
   ```julia
   # Rust: *const i32
   # Julia: Ptr{Int32}

   arr = Int32[1, 2, 3]
   ptr = pointer(arr)
   ```

2. For C strings, use `String` directly:
   ```julia
   # Rust: *const u8
   # Julia: String (automatic conversion)
   @rust process_string("hello")::UInt32
   ```

## Memory Management Problems

### Problem: Memory Leak

**Solution:**

1. If using ownership types, call `drop!` appropriately:
   ```julia
   box = RustBox{Int32}(ptr)
   try
       # Use box
   finally
       drop!(box)  # Always cleanup
   end
   ```

2. Check if finalizers are working correctly

### Problem: Double Free Error

**Error Message:**
```
double free or corruption
```

**Solution:**

1. Call `drop!` only once:
   ```julia
   box = RustBox{Int32}(ptr)
   drop!(box)
   # drop!(box)  # Error: Don't call twice
   ```

2. Check state with `is_dropped`:
   ```julia
   if !is_dropped(box)
       drop!(box)
   end
   ```

### Problem: Invalid Pointer Access

**Solution:**

1. Check pointer validity:
   ```julia
   if box.ptr != C_NULL && !is_dropped(box)
       # Use safely
   end
   ```

2. Use `is_valid`:
   ```julia
   if is_valid(box)
       # Use safely
   end
   ```

## Performance Issues

### Problem: Slow Compilation

**Solution:**

1. Check if cache is working:
   ```julia
   # First compilation (slow)
   rust"""
   // code
   """

   # Second time onwards (fast from cache)
   rust"""
   // same code
   """
   ```

2. Check cache status:
   ```julia
   get_cache_size()
   list_cached_libraries()
   ```

### Problem: Slow Function Calls

**Solution:**

1. Try `@rust_llvm` (experimental):
   ```julia
   # Normal call
   result = @rust add(10i32, 20i32)::Int32

   # LLVM IR integration (potential optimization)
   result = @rust_llvm add(Int32(10), Int32(20))
   ```

2. Run benchmarks to compare:
   ```bash
   julia --project benchmark/benchmarks.jl
   ```

3. Avoid type inference and specify types explicitly

## Frequently Asked Questions

### Q: Can I use multiple Rust libraries simultaneously?

A: Yes, it's possible. Each `rust""` block is compiled as an independent library:

```julia
rust"""
// Library 1
#[no_mangle]
pub extern "C" fn func1() -> i32 { 1 }
"""

rust"""
// Library 2
#[no_mangle]
pub extern "C" fn func2() -> i32 { 2 }
"""

# Both can be used
result1 = @rust func1()::Int32
result2 = @rust func2()::Int32
```

### Q: Can I use Rust generics?

A: Currently, generics are not directly supported. `extern "C"` functions need to use concrete types. We are considering support in the future.

### Q: Can I return Rust structs?

A: Currently, only basic types and pointer types are supported. To return structs, you need to use `#[repr(C)]` and define corresponding structs on the Julia side (experimental).

### Q: Can I compile in debug mode?

A: Yes, you can change `RustCompiler` settings (internal implementation). Normally it compiles at optimization level 2.

### Q: When should I clear the cache?

A: Clear the cache in the following cases:
- After modifying Rust code
- After compilation errors occur
- After unexpected behavior occurs

```julia
clear_cache()
```

### Q: Does it work on Windows?

A: Yes, it works on Windows, macOS, and Linux. However, the Rust toolchain must be correctly installed.

### Q: What about performance?

A: The `@rust` macro has standard FFI overhead. `@rust_llvm` (experimental) has optimization potential but doesn't speed up all cases. Run benchmarks to verify.

### Q: What are the best practices for error handling?

A:
1. Use `Result` type on Rust side
2. Use `result_to_exception` on Julia side to convert to exceptions
3. Or provide default values with `unwrap_or`

```julia
result = some_rust_function()
value = unwrap_or(result, default_value)
```

## Additional Help

If problems persist:

1. Search existing Issues on [GitHub Issues](https://github.com/your-repo/RustCall.jl/issues)
2. Create a new Issue (include error messages, reproducible code, environment information)
3. Check [Documentation](../README.md)
4. Refer to [Tutorial](tutorial.md)

## Debugging Tips

### 1. Enable Detailed Logging

```julia
using Logging
global_logger(ConsoleLogger(stderr, Logging.Debug))
```

### 2. Clear Cache

```julia
clear_cache()
```

### 3. Test Rust Code Individually

```bash
cd /tmp
cat > test.rs << 'EOF'
#[no_mangle]
pub extern "C" fn test() -> i32 { 42 }
EOF
rustc --crate-type cdylib test.rs
```

### 4. Check Library Status

```julia
# List cached libraries
list_cached_libraries()

# Check cache size
get_cache_size()
```

### 5. Check Type Information

```julia
# Check type mapping
rusttype_to_julia(:i32)  # => Int32
juliatype_to_rust(Int32)  # => "i32"
```

## Summary

If this troubleshooting guide doesn't solve your problem, please ask on GitHub Issues. When reporting issues, include the following information:

- Julia version
- RustCall.jl version
- Rust version
- Operating system
- Full error message
- Minimal reproducible code example
