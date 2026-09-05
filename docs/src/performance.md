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

- **Cache key**: `RustCall.artifact_key` of a `RustCall.ArtifactId` — the single
  identity function of the package (`src/artifact_id.jl`). The record names
  everything that can change the produced binary: the expanded source, generic
  type parameters *in declaration order*, target triple, codegen options, the
  `#[cfg]` snapshot, the dependency set (a local `path =` dependency contributes
  its **content**, not its location), crate features, the tracked build
  environment, the toolchain fingerprint, and the identity of the `rustc` /
  `cargo` that actually runs. Fields are netstring-framed, so no two different
  requests can concatenate to the same bytes.
- **Cache location**: `~/.julia/compiled/vX.Y/RustCall/v\$(CACHE_FORMAT_VERSION)/`.
  `CACHE_FORMAT_VERSION` names the on-disk layout; bumping it namespaces a new
  tree rather than serving or deleting the old one, and
  `RustCall.sweep_stale_cache_formats()` (called by `clear_cache` and
  `cleanup_old_cache`) removes older siblings best effort.
- **Cost**: every input byte is read and hashed on every key computation —
  file contents are never memoized, because a `(mtime, size)` stamp can alias
  distinct contents and the cost of being wrong is running machine code built
  from source that no longer exists. Only the resolved Cargo dependency graph is
  cached (that is the expensive part: a `cargo tree` process spawn), and it is
  invalidated by a manifest change in *any* crate of that graph.
- **Truncation**: keys are never truncated. `RustCall.artifact_short_id` is the
  only truncation in the design and exists solely for names a human reads —
  library names, temporary Cargo project directories, log lines.
- **Automatic verification**: cached libraries carry a SHA-256 checksum, checked
  before loading.

### What is not in the key

Two inputs are tracked **best effort** and are documented limits, not proofs:

- **Build environment.** `RustCall.artifact_build_env` captures a documented
  allowlist (`RUSTFLAGS`, `CARGO_PROFILE_*`, `CC`, `PKG_CONFIG_PATH`, …; never
  anything that looks like a credential). A build script may read any variable it
  likes, and the only exhaustive answer is Cargo's own fingerprint. Extend
  `ARTIFACT_BUILD_ENV_*` in `src/artifact_id.jl` — the one place — if you need
  more.
- **Files outside a package directory.** A `#[path = "../../elsewhere.rs"]`
  module or an `include_str!` above the crate root is compiled in but does not
  change the path-dependency digest.

A change in either means "stale" and forces a rebuild; no change does not by
itself license reuse.

### A missing toolchain is an error

The compiler in the key is the compiler that runs: versions come from
`RustToolChain.rustc()` / `cargo()`, the very commands RustCall invokes. A
toolchain that cannot be identified raises a `RustError` on any path about to
compile, rather than caching everything under the string `"unknown"`.

### Cache Management

```julia
using RustCall

# Check cache size
size = RustCall.get_cache_size()
println("Cache size: $(size / 1024 / 1024) MB")

# List cached libraries
libraries = RustCall.list_cached_libraries()
println("Cached libraries: $(length(libraries))")

# Cleanup old cache (older than 30 days)
RustCall.cleanup_old_cache(30)

# Clear cache completely
RustCall.clear_cache()
```

### Cache Best Practices

1. **During Development**: Keep cache enabled to reduce recompilation time
2. **Production**: Warm up cache beforehand to avoid first-run delays
3. **CI/CD**: Save and restore cache to reduce build time

## LLVM Optimization

!!! warning "Deprecated"
    The LLVM IR integration path (`@rust_llvm`, `compile_rust_to_llvm_ir`,
    `load_llvm_ir`, `OptimizationConfig`, `optimize_module!` and friends) is
    deprecated and will be removed in a future release. Every entry point now
    emits a deprecation warning. See [#265](https://github.com/AtelierArith/RustCall.jl/issues/265).

The path was an experiment inspired by Cxx.jl: load the LLVM IR that rustc emits
into Julia's LLVM and optimize across the language boundary. It is being removed
for two reasons.

- **The call path is equivalent to `@rust`.** `@rust_llvm` calls the Rust
  function through a function pointer with a plain `ccall`; no Rust IR is inlined
  into Julia code, so there is no performance difference.
- **rustc and Julia do not share an LLVM version.** rustc follows LLVM releases
  every six weeks while Julia pins a major version per release (Julia 1.12 ships
  LLVM 18, rustc 1.98 emits LLVM 22 IR). The textual IR format is not forward
  compatible, so newer rustc output cannot be parsed reliably by Julia's LLVM.

Use `@rust` for all calls. Optimization of the Rust code itself belongs to
`rustc` (`-C opt-level`, see `RustCall.RustCompiler`).

## Function Call Optimization

### `@rust` vs `@rust_llvm`

- **`@rust`**: Standard call via `ccall`. Highly stable, recommended for all cases
- **`@rust_llvm`**: Deprecated (see [#265](https://github.com/AtelierArith/RustCall.jl/issues/265)). Internally it performs the same
  `ccall` as `@rust`, so it has no performance benefit, and it emits a deprecation warning

```julia
# Standard call (recommended)
result = @rust add(Int32(10), Int32(20))::Int32

# Deprecated: same call mechanism, plus a deprecation warning
result = @rust_llvm add(Int32(10), Int32(20))
```

### Type Inference Optimization

Explicit type specification can reduce type inference overhead:

```julia
# With type inference (slightly slower)
result = @rust add(10, 20)

# Explicit type specification (recommended)
result = @rust add(Int32(10), Int32(20))::Int32
```

### Function Registration Optimization

`RustCall.compile_and_register_rust_function` registered a function for the
deprecated LLVM path. It is no longer recommended: `rust"""..."""` blocks
already compile once and are cached, so an explicit registration step buys
nothing. Prefer `@rust` with explicit argument and return types.

## Memory Management

### Efficient Use of Ownership Types

Ownership types (`RustBox`, `RustRc`, `RustArc`, `RustVec`) prevent memory leaks when used appropriately:

```julia
# Temporary allocations are automatically cleaned up
box = RustCall.RustBox(Int32(42))
# Automatically dropped after use

# Explicit drop (when early release is needed)
RustCall.drop!(box)
```

### Efficient Use of RustVec

`RustVec` is a type for manipulating Rust's `Vec<T>` from Julia. Best practices when handling large amounts of data:

```julia
# Create RustVec from Julia array
julia_vec = Int32[1, 2, 3, 4, 5]
rust_vec = RustCall.create_rust_vec(julia_vec)

# Efficient bulk copy (recommended)
result = Vector{Int32}(undef, length(rust_vec))
RustCall.copy_to_julia!(rust_vec, result)

# Or use to_julia_vector
result = RustCall.to_julia_vector(rust_vec)

# Element-by-element access (not recommended for large data)
for i in 1:length(rust_vec)
    value = rust_vec[i]  # FFI call occurs
end

# Explicitly drop after use
RustCall.drop!(rust_vec)
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
box = RustCall.RustBox(Int32(42))
try
    # Use
    value = box.ptr
finally
    RustCall.drop!(box)  # Ensure cleanup
end

# Pattern 2: Leverage local scope
function compute()
    box = RustCall.RustBox(Int32(42))
    # Use
    return result
    # box is automatically dropped
end
```

## Benchmark Results

### Basic Operations

The following benchmarks were run on Julia 1.12, Rust 1.92.0, macOS. The
`@rust_llvm` column is kept for reference only; the macro is deprecated and uses the
same call mechanism as `@rust`.

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

# LLVM integration benchmarks (deprecated path, emits deprecation warnings)
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
compiler = RustCall.RustCompiler(
    optimization_level=2,  # 2 is sufficient during development
    emit_debug_info=false
)
RustCall.set_default_compiler(compiler)
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
shared_data = RustCall.RustArc(Int32(0))

# Work on multiple threads
@threads for i in 1:1000
    local_arc = RustCall.clone(shared_data)
    # Work
    RustCall.drop!(local_arc)
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
