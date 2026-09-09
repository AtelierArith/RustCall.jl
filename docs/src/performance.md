# Performance Guide

RustCall.jl provides multiple features to optimize performance when calling Rust code from Julia. This guide explains best practices and optimization tips for improving performance.

## Table of Contents

1. [Compilation Caching](#compilation-caching)
2. [LLVM Optimization (removed)](#llvm-optimization-removed)
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
- **Cache location**: a [Scratch.jl](https://github.com/JuliaPackaging/Scratch.jl)
  space, `<depot>/scratchspaces/<RustCall UUID>/cache-v\$(CACHE_FORMAT_VERSION)/`
  — writable by construction and accounted for by `Pkg.gc()`. RustCall writes
  nothing under `~/.julia/compiled/`, which is Julia's own precompile directory
  (issue #252). `<depot>` is the first **writable** entry of `DEPOT_PATH`, so a
  read-only first depot is not fatal, and `RUSTCALL_CACHE_DIR` overrides the
  location outright. `CACHE_FORMAT_VERSION` names the on-disk layout; bumping it
  namespaces a new space rather than serving or deleting the old one, and
  `RustCall.sweep_stale_cache_formats()` (called by `clear_cache` and
  `cleanup_old_cache`) removes older `cache-v<n>` siblings best effort.
- **Cost**: every input byte is read and hashed on every key computation —
  file contents are never memoized, because a `(mtime, size)` stamp can alias
  distinct contents and the cost of being wrong is running machine code built
  from source that no longer exists. Only the resolved Cargo dependency graph is
  cached (that is the expensive part: a `cargo tree` process spawn), and it is
  invalidated by a content change in *any* manifest that decides the graph —
  every crate in it, plus the workspace root each crate belongs to.
- **Truncation**: keys are never truncated. `RustCall.artifact_short_id` is the
  only truncation in the design and exists solely for names a human reads —
  library names, temporary Cargo project directories, log lines.
- **Automatic verification**: cached libraries carry a SHA-256 checksum, checked
  before loading.

### What is not in the key

Two inputs are tracked **best effort** and are documented limits, not proofs:

- **Build environment.** `RustCall.artifact_build_env` captures a documented
  allowlist (`RUSTFLAGS`, `CARGO_PROFILE_*`, `PYO3_*`, `CC`, `PKG_CONFIG_PATH`, …; never
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

### Pinned, lockfile-driven dependency builds

A `// cargo-deps:` block names version *ranges*; what Cargo resolves them to is
a separate fact, and it is the fact that decides the binary. RustCall therefore
persists one `Cargo.lock` per dependency set and builds against it (issue #256):

- **Where.** `RustCall.lockfile_path(deps)` — or `lockfile_path(source)` for a
  block's source text — is `<cache dir>/lockfiles/<key>.lock`, where the key is
  `artifact_key(cargo_lockfile_id(deps))`: the declared dependency set and
  nothing else (no toolchain), so the same set on any machine looks in the same
  place. The generated project's package is named from the set
  (`RustCall.cargo_block_package(deps)`), so one lockfile fits every block
  declaring it, and no fixed name is reserved that your own crate might use. A
  stored file that does not name that package — a hand-edited file, or one
  written under an older naming scheme — is not this set's resolution and is
  resolved afresh rather than replayed.
- **First build.** With no persisted lockfile, `cargo generate-lockfile`
  resolves the set once and the result is stored. Every later build — of this
  block or any other with the same dependencies — copies the file in and runs
  `cargo build --locked`, so Cargo builds exactly the pinned graph or fails; it
  never re-resolves behind the cache key.
- **Identity.** The lockfile's *content* is part of the block's `ArtifactId`
  (`cargo-lock`). A changed resolution is a different artifact; a cache hit can
  never answer for another graph.
- **Sharing and refreshing.** Copy or commit the file to reproduce a build on
  another machine; delete it to resolve afresh. `clear_cache` leaves lockfiles
  alone — they are inputs of a build, not outputs — and
  `RustCall.clear_lockfiles()` is the one operation that discards them all.
- **One resolution wins.** Two processes (or machines sharing the store) that
  both find it empty publish through an exclusive-create claim file beside the
  entry: the first to claim publishes, the other waits and replays the
  published file, so both build one graph. A claim is never expired by age; if
  a build ever reports that another process holds the claim and nothing was
  published, and no other process is resolving that set, a previous one died
  holding it — delete the named `.claim` file (or run `clear_lockfiles()`).
- **Offline.** `RUSTCALL_OFFLINE=1` adds `--offline` to every Cargo invocation.
  With a warm registry cache the pinned build succeeds without the network; with
  a cold one Cargo fails at once with its own message (surfaced as a
  `CargoBuildError`), rather than hanging on a download.

`@rust_crate` wrapper crates depend on your crate by path and are built as their
own Cargo root; a PyO3 wrapper carries your crate's `Cargo.lock` and `[patch]`
table (see [PyO3 crates](pyo3.md)). Persisting *their* resolution is not covered
here.

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

# Also remove the tree the pre-#252 layout left in `~/.julia/compiled/`. Off by
# default: that directory is Julia's own precompile directory for RustCall, so
# RustCall only ever deletes entries it can prove it wrote, and never the
# directory itself.
RustCall.clear_cache(sweep_legacy = true)
```

### Cache Best Practices

1. **During Development**: Keep cache enabled to reduce recompilation time
2. **Production**: Warm up cache beforehand to avoid first-run delays
3. **CI/CD**: Save and restore cache to reduce build time

## LLVM Optimization (removed)

`@rust_llvm` and the LLVM IR integration path — `compile_rust_to_llvm_ir`,
`load_llvm_ir`, `compile_and_register_rust_function`, `OptimizationConfig`,
`optimize_module!` and friends — were deprecated in 0.2.0 and **removed in
0.3.0** ([#265](https://github.com/AtelierArith/RustCall.jl/issues/265)).
RustCall no longer depends on `LLVM.jl`. Use `@rust`.

The path was an experiment inspired by Cxx.jl: load the LLVM IR that rustc emits
into Julia's LLVM and optimize across the language boundary. It was removed for
two reasons, quoting the issue:

- **The call path was equivalent to `@rust`.** `@rust_llvm` called the Rust
  function through a function pointer with a plain `ccall`; no Rust IR was ever
  inlined into Julia code, so there was no performance difference.
- **rustc and Julia do not share an LLVM version.** rustc follows LLVM releases
  every six weeks while Julia pins a major version per release (Julia 1.12 ships
  LLVM 18, rustc 1.98 emits LLVM 22 IR). The textual IR format is not forward
  compatible, so newer rustc output could not be parsed reliably by Julia's LLVM
  — the path already stripped attributes it did not know by regex before
  parsing, and there is no way to make rustc emit an older IR format.

Optimization of the Rust code itself belongs to `rustc` (`-C opt-level`, see
`RustCall.RustCompiler`).

## Function Call Optimization

### One call mechanism

Every `@rust` call is a `ccall` through a function pointer resolved from the
library's own handle (one snapshot per call, see the project guide). There is no
second, faster call path: the former `@rust_llvm` used the very same `ccall`
and was removed in 0.3.0 (see above).

```julia
# Standard call (recommended)
result = @rust add(Int32(10), Int32(20))::Int32
```

### Type Inference Optimization

Explicit type specification can reduce type inference overhead:

```julia
# With type inference (slightly slower)
result = @rust add(10, 20)

# Explicit type specification (recommended)
result = @rust add(Int32(10), Int32(20))::Int32
```

### No registration step

`rust"""..."""` blocks compile once and are cached, and the manifest registers
every function's symbol and return type when the library is loaded, so there is
nothing to pre-register. (`compile_and_register_rust_function`, the registration
step of the removed LLVM path, is gone.) Prefer `@rust` with explicit argument
and return types.

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

The following benchmarks were run on Julia 1.12, Rust 1.92.0, macOS.

| Operation | Julia Native | @rust |
|-----------|-------------|-------|
| i32 addition | 1.0x | 1.2x |
| i64 addition | 1.0x | 1.2x |
| f64 addition | 1.0x | 1.3x |
| i32 multiplication | 1.0x | 1.2x |
| f64 multiplication | 1.0x | 1.3x |

### Complex Computations

| Computation | Julia Native | @rust |
|-------------|-------------|-------|
| Fibonacci (n=30) | 1.0x | 1.1x |
| Sum Range (1..1000) | 1.0x | 1.2x |

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
# Extractor + rustc compile-time benchmark (cold and warm)
RUSTCALL_EXTRACT=/path/to/rustcall-extract \
  julia --project benchmark/benchmarks_compile.jl

# Basic benchmarks
julia --project benchmark/benchmarks.jl

# Ownership type benchmarks
julia --threads=4 --project benchmark/benchmarks_ownership.jl

# Array operation benchmarks
julia --project benchmark/benchmarks_arrays.jl

# Generics benchmarks
julia --project benchmark/benchmarks_generics.jl
```

### Inline compilation benchmark (#271)

`benchmark/benchmarks_compile.jl` measures the extractor-based inline pipeline
with one Rust cdylib per sample. Cold samples use a new source identity, so
they include extraction and `rustc` with no compiled-artifact cache hit. Warm
samples reuse one source after unloading its image, so they exercise the disk
cache and the memoized expansion without measuring an FFI call.

The first recorded run was on macOS (`Darwin x86_64`, Julia 1.12.7, rustc
1.98.0):

| Platform | Cold: extract + rustc | Warm: cache + memoized expansion |
|---|---:|---:|
| macOS x86_64 | 406.56 ms | 1.63 ms |

CI measurements from commit `f6e84bd` on 2026-09-09 (Julia 1.12.7,
rustc 1.98.1; 3 cold samples and 5 warm samples):

| Platform | Cold: extract + rustc | Warm: cache + memoized expansion |
|---|---:|---:|
| [Linux x86_64](https://github.com/AtelierArith/RustCall.jl/actions/runs/34303413582/job/102314990683) | 140.06 ms | 35.08 ms |
| [macOS aarch64](https://github.com/AtelierArith/RustCall.jl/actions/runs/34303413582/job/102314990577) | 264.79 ms | 3.62 ms |
| [Windows x86_64](https://github.com/AtelierArith/RustCall.jl/actions/runs/34303413582/job/102314990769) | 256.59 ms | 1.18 ms |

These are runner-specific measurements, not controlled comparisons between
operating systems. The script prints the platform, Julia version, rustc version,
and medians so subsequent runs can be compared with their environment recorded.

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
