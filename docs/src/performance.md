# Performance Guide

RustCall.jl provides multiple features to optimize performance when calling Rust code from Julia. This guide explains best practices and optimization tips for improving performance.

## Table of Contents

1. [Compilation Caching](#compilation-caching)
2. [LLVM Optimization](#llvm-optimization)
3. [Function Call Optimization](#function-call-optimization)
4. [Memory Management](#memory-management)
5. [Benchmark Results](#benchmark-results)
6. [Performance Tuning Tips](#performance-tuning-tips)

## Compilation Caching

RustCall.jl automatically caches compiled Rust libraries. This eliminates the need to recompile the same code and significantly reduces startup time.

### How Caching Works

- **Cache Key**: Generated from code hash, compiler settings, and target triple
- **Cache Location**: `~/.julia/compiled/vX.Y/RustCall/`
- **Automatic Verification**: Automatically checks cache integrity

### Cache Management

```julia
using RustCall

# Check cache size
size = get_cache_size()
println("Cache size: $(size / 1024 / 1024) MB")

# List cached libraries
libraries = list_cached_libraries()
println("Cached libraries: $(length(libraries))")

# Cleanup old cache (older than 30 days)
cleanup_old_cache(30)

# Clear cache completely
clear_cache()
```

### Cache Best Practices

1. **During Development**: Keep cache enabled to reduce recompilation time
2. **Production**: Warm up cache beforehand to avoid first-run delays
3. **CI/CD**: Save and restore cache to reduce build time

## LLVM Optimization

RustCall.jl supports optimization at the LLVM IR level. Using the `@rust_llvm` macro enables more advanced optimizations.

### Optimization Level Settings

```julia
using RustCall

# Create optimization configuration
config = OptimizationConfig(
    optimization_level=3,  # 0-3 (3 is most optimized)
    enable_vectorization=true,
    enable_loop_unrolling=true,
    enable_licm=true
)

# Optimize module
rust"""
#[no_mangle]
pub extern "C" fn compute(x: f64) -> f64 {
    x * x + 1.0
}
"""

# Apply optimization
mod = get_rust_module(rust_code)
optimize_module!(mod; config=config)
```

### Optimization Presets

```julia
# Speed-optimized
optimize_for_speed!(mod)

# Size-optimized
optimize_for_size!(mod)

# Balanced optimization
optimize_balanced!(mod)
```

### Optimization Level Selection

- **Level 0**: No optimization (for debugging)
- **Level 1**: Basic optimizations
- **Level 2**: Standard optimizations (default)
- **Level 3**: Maximum optimization (may take longer to compile)

## Function Call Optimization

### `@rust` vs `@rust_llvm`

- **`@rust`**: Standard call via `ccall`. Highly stable, recommended for most cases
- **`@rust_llvm`**: Call via LLVM IR integration (experimental). Has optimization potential but limitations with some types

```julia
# Standard call (recommended)
result = @rust add(10i32, 20i32)

# LLVM integration call (experimental)
result = @rust_llvm add(10i32, 20i32)
```

### Type Inference Optimization

Explicit type specification can reduce type inference overhead:

```julia
# With type inference (slightly slower)
result = @rust add(10, 20)

# Explicit type specification (recommended)
result = @rust add(10i32, 20i32)::Int32
```

### Function Registration Optimization

Frequently called functions can be optimized by registering them beforehand:

```julia
# Register function
register_function("add", "mylib", Int32, [Int32, Int32])

# Call registered function (type checking is skipped)
result = @rust add(10i32, 20i32)
```

## Memory Management

### Efficient Use of Ownership Types

Ownership types (`RustBox`, `RustRc`, `RustArc`, `RustVec`) prevent memory leaks when used appropriately:

```julia
# Temporary allocations are automatically cleaned up
box = RustBox(Int32(42))
# Automatically dropped after use

# Explicit drop (when early release is needed)
drop!(box)
```

### Efficient Use of RustVec

`RustVec` is a type for manipulating Rust's `Vec<T>` from Julia. Best practices when handling large amounts of data:

```julia
# Create RustVec from Julia array
julia_vec = Int32[1, 2, 3, 4, 5]
rust_vec = create_rust_vec(julia_vec)

# Efficient bulk copy (recommended)
result = Vector{Int32}(undef, length(rust_vec))
copy_to_julia!(rust_vec, result)

# Or use to_julia_vector
result = to_julia_vector(rust_vec)

# Element-by-element access (not recommended for large data)
for i in 1:length(rust_vec)
    value = rust_vec[i]  # FFI call occurs
end

# Explicitly drop after use
drop!(rust_vec)
```

### RustVec vs Julia Array Selection

| Scenario | Recommendation |
|----------|----------------|
| Computation within Julia | Julia arrays |
| Input to Rust functions | RustVec |
| Output from Rust functions | RustVec → Convert to Julia array |
| Temporary storage of large data | Julia arrays (managed by GC) |
| Data manipulation on Rust side | RustVec |

### Avoiding Memory Leaks

```julia
# Pattern 1: Use try-finally
box = RustBox(Int32(42))
try
    # Use
    value = box.ptr
finally
    drop!(box)  # Ensure cleanup
end

# Pattern 2: Leverage local scope
function compute()
    box = RustBox(Int32(42))
    # Use
    return result
    # box is automatically dropped
end
```

## Benchmark Results

### Basic Operations

The following benchmarks were run on Julia 1.12, Rust 1.92.0, macOS:

| Operation | Julia Native | @rust | @rust_llvm |
|-----------|-------------|-------|------------|
| i32 addition | 1.0x | 1.2x | 1.1x |
| i64 addition | 1.0x | 1.2x | 1.1x |
| f64 addition | 1.0x | 1.3x | 1.2x |
| i32 multiplication | 1.0x | 1.2x | 1.1x |
| f64 multiplication | 1.0x | 1.3x | 1.2x |

### Complex Computations

| Computation | Julia Native | @rust | @rust_llvm |
|-------------|-------------|-------|------------|
| Fibonacci (n=30) | 1.0x | 1.1x | 1.0x |
| Sum Range (1..1000) | 1.0x | 1.2x | 1.1x |

### Ownership Type Operations

| Operation | Average Time | Notes |
|-----------|-------------|-------|
| RustBox create+drop | ~170 ns | Single value allocation/release |
| RustRc create+drop | ~180 ns | With reference counting |
| RustRc clone+drop | ~180 ns | Clone operation |
| RustArc create+drop | ~190 ns | Atomic reference counting |
| RustArc clone+drop | ~200 ns | Thread-safe |

### RustVec Operations

| Operation | Average Time | Notes |
|-----------|-------------|-------|
| RustVec(1000 elements) create | ~1 μs | Conversion from Julia array |
| RustVec copy_to_julia!(1000 elements) | ~500 ns | Efficient bulk copy |
| RustVec element access | ~50 ns/element | Includes FFI call |
| RustVec push! | ~100 ns | When no reallocation occurs |

**Note**: These results may vary by environment. Actual performance can vary significantly depending on hardware, OS, and Julia/Rust versions.

### Running Benchmarks

```bash
# Basic benchmarks
julia --project benchmark/benchmarks.jl

# LLVM integration benchmarks
julia --project benchmark/benchmarks_llvm.jl

# Ownership type benchmarks
julia --threads=4 --project benchmark/benchmarks_ownership.jl

# Array operation benchmarks
julia --project benchmark/benchmarks_arrays.jl

# Generics benchmarks
julia --project benchmark/benchmarks_generics.jl
```

## Performance Tuning Tips

### 1. Reducing Compilation Time

- **Leverage cache**: Don't recompile the same code
- **Adjust optimization level**: Level 1-2 during development, Level 3 in production
- **Disable debug info**: `emit_debug_info=false`

```julia
compiler = RustCompiler(
    optimization_level=2,  # 2 is sufficient during development
    emit_debug_info=false
)
set_default_compiler(compiler)
```

### 2. Improving Runtime Performance

- **Explicit types**: Reduce type inference overhead
- **Register functions**: Pre-register frequently called functions
- **Batch processing**: Combine multiple calls

```julia
# Inefficient: Type inference every time in loop
for i in 1:1000
    result = @rust add(i, i+1)  # Type inference runs every time
end

# Efficient: Explicit types
for i in 1:1000
    result = @rust add(Int32(i), Int32(i+1))::Int32
end
```

### 3. Optimizing Memory Usage

- **Appropriate use of ownership types**: Drop immediately when no longer needed
- **Appropriate choice of Rc/Arc**: Use `Rc` for single-threaded, `Arc` for multi-threaded
- **Cache cleanup**: Regularly delete old cache

### 4. Parallel Processing Optimization

```julia
using Base.Threads

# Use Arc to share data between threads
shared_data = RustArc(Int32(0))

# Work on multiple threads
@threads for i in 1:1000
    local_arc = clone(shared_data)
    # Work
    drop!(local_arc)
end
```

### 5. Profiling

Use Julia's profiling tools to identify bottlenecks:

```julia
using Profile

# Start profiling
Profile.clear()
@profile for i in 1:1000
    @rust add(Int32(i), Int32(i+1))
end

# Display results
Profile.print()
```

## Troubleshooting

### When Performance is Lower Than Expected

1. **Check cache**: Verify cache is working correctly
2. **Check optimization level**: Verify optimization level is set appropriately
3. **Explicit types**: Reduce type inference overhead
4. **Profiling**: Identify bottlenecks

### When Memory Usage is High

1. **Check ownership types**: Verify they are being dropped appropriately
2. **Cache cleanup**: Delete old cache
3. **Rc/Arc usage**: Avoid unnecessary clones

## Summary

To optimize RustCall.jl performance:

1. ✅ **Leverage cache**: Reduce compilation time
2. ✅ **Adjust optimization level**: Select optimization level according to use case
3. ✅ **Explicit types**: Reduce type inference overhead
4. ✅ **Memory management**: Use ownership types appropriately
5. ✅ **Profiling**: Identify and optimize bottlenecks

By following these best practices, you can maximize the performance of applications using RustCall.jl.
