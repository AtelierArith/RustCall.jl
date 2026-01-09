# Troubleshooting

This guide covers common issues and solutions when using LastCall.jl.

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

### Problem: Dependency installation errors

**Solution:**

1. Check Julia version (1.10+ required):
   ```julia
   VERSION
   ```

2. Reinstall package:
   ```julia
   using Pkg
   Pkg.rm("LastCall")
   Pkg.add("LastCall")
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
   @rust add(Int32(10), Int32(20))::Int32

   # Wrong
   @rust add(10, 20)  # Types may not be inferred
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
   pub extern "C" fn my_function() -> i32 { 42 }
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
   # Dangerous: invalid pointer
   ptr = Ptr{Cvoid}(0x1000)

   # Safe: from valid array
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
   # Don't access beyond len
   ```

3. Check memory management (if using ownership types)

### Problem: String encoding errors

**Error message:**
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

2. Pass strings correctly from Julia:
   ```julia
   # UTF-8 strings are handled automatically
   @rust process_string("こんにちは")::UInt32
   ```

## Type-related Issues

### Problem: Type inference fails

**Solution:**

1. Specify types explicitly:
   ```julia
   # Recommended
   result = @rust add(10i32, 20i32)::Int32

   # Not recommended
   result = @rust add(10i32, 20i32)
   ```

2. Explicitly specify argument types:
   ```julia
   a = Int32(10)
   b = Int32(20)
   result = @rust add(a, b)::Int32
   ```

### Problem: Pointer type conversion errors

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
   # Julia: String (auto-converted)
   @rust process_string("hello")::UInt32
   ```

## Memory Management Issues

### Problem: Memory leaks

**Solution:**

1. For ownership types, call `drop!` properly:
   ```julia
   box = RustBox{Int32}(ptr)
   try
       # Use box
   finally
       drop!(box)  # Always cleanup
   end
   ```

2. Ensure finalizers are working correctly

### Problem: Double free errors

**Error message:**
```
double free or corruption
```

**Solution:**

1. Call `drop!` only once:
   ```julia
   box = RustBox{Int32}(ptr)
   drop!(box)
   # drop!(box)  # Error: don't call twice
   ```

2. Check state with `is_dropped`:
   ```julia
   if !is_dropped(box)
       drop!(box)
   end
   ```

### Problem: Invalid pointer access

**Solution:**

1. Check pointer validity:
   ```julia
   if box.ptr != C_NULL && !is_dropped(box)
       # Safe to use
   end
   ```

2. Use `is_valid`:
   ```julia
   if is_valid(box)
       # Safe to use
   end
   ```

## Performance Issues

### Problem: Compilation is slow

**Solution:**

1. Verify caching is working:
   ```julia
   # First compilation (slow)
   rust"""
   // Code
   """

   # Second time (fast from cache)
   rust"""
   // Same code
   """
   ```

2. Check cache status:
   ```julia
   get_cache_size()
   list_cached_libraries()
   ```

### Problem: Function calls are slow

**Solution:**

1. Try `@rust_llvm` (experimental):
   ```julia
   # Normal call
   result = @rust add(10i32, 20i32)::Int32

   # LLVM IR integration (potentially optimized)
   result = @rust_llvm add(Int32(10), Int32(20))
   ```

2. Run benchmarks to compare:
   ```bash
   julia --project benchmark/benchmarks.jl
   ```

3. Avoid type inference - specify types explicitly

## FAQ

### Q: Can I use multiple Rust libraries simultaneously?

A: Yes. Each `rust""` block is compiled as an independent library:

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

# Both usable
result1 = @rust func1()::Int32
result2 = @rust func2()::Int32
```

### Q: Can I use Rust generics?

A: Yes, with automatic monomorphization. See [Generics](@ref) for details.

### Q: Can I return Rust structs?

A: Currently, only basic types and pointers are supported. For structs, use `#[repr(C)]` and define corresponding Julia structs (experimental).

### Q: When should I clear the cache?

A: Clear the cache when:
- After modifying Rust code
- After compilation errors occur
- When unexpected behavior occurs

```julia
clear_cache()
```

### Q: Does it work on Windows?

A: Yes, it works on Windows, macOS, and Linux. Rust toolchain must be properly installed.

### Q: What about performance?

A: The `@rust` macro has standard FFI overhead. `@rust_llvm` (experimental) may offer optimizations but not in all cases. Run benchmarks to verify.

### Q: Best practices for error handling?

A:
1. Use `Result` type on Rust side
2. Use `result_to_exception` on Julia side
3. Or use `unwrap_or` for default values

```julia
result = some_rust_function()
value = unwrap_or(result, default_value)
```

## Debugging Tips

### 1. Enable verbose logging

```julia
using Logging
global_logger(ConsoleLogger(stderr, Logging.Debug))
```

### 2. Clear cache

```julia
clear_cache()
```

### 3. Test Rust code independently

```bash
cd /tmp
cat > test.rs << 'EOF'
#[no_mangle]
pub extern "C" fn test() -> i32 { 42 }
EOF
rustc --crate-type cdylib test.rs
```

### 4. Check library status

```julia
# List cached libraries
list_cached_libraries()

# Check cache size
get_cache_size()
```

### 5. Check type information

```julia
# Check type mapping
rusttype_to_julia(:i32)  # => Int32
juliatype_to_rust(Int32)  # => "i32"
```

## Getting Help

If problems persist:

1. Search existing issues on GitHub
2. Create a new issue with:
   - Julia version
   - LastCall.jl version
   - Rust version
   - Operating system
   - Full error message
   - Minimal reproducible code example
