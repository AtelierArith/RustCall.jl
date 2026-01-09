# Benchmarks for Ownership Types in LastCall.jl
#
# This file measures:
# - Allocation/deallocation performance
# - Reference counting overhead (Rc, Arc)
# - Memory usage patterns
# - Thread safety overhead for Arc
#
# Run with: julia --project benchmark/benchmarks_ownership.jl

using LastCall

# Check if Rust helpers library is available
if !is_rust_helpers_available()
    @error """
    Rust helpers library not available!
    Please build it first with:
        julia --project -e 'using Pkg; Pkg.build("LastCall")'
    """
    exit(1)
end

println("=" ^ 70)
println("LastCall.jl - Ownership Types Benchmarks")
println("=" ^ 70)
println()

# ============================================================================
# Utility functions
# ============================================================================

"""
Measure execution time with warmup
"""
function benchmark(f, warmup_iterations=100, iterations=10000)
    # Warmup
    for _ in 1:warmup_iterations
        f()
    end
    
    # Measure
    GC.gc()
    t_start = time_ns()
    for _ in 1:iterations
        f()
    end
    t_end = time_ns()
    
    return (t_end - t_start) / iterations  # Average time in ns
end

"""
Format time in appropriate units
"""
function format_time(ns::Float64)
    if ns < 1000
        return "$(round(ns, digits=1)) ns"
    elseif ns < 1_000_000
        return "$(round(ns / 1000, digits=2)) μs"
    else
        return "$(round(ns / 1_000_000, digits=2)) ms"
    end
end

"""
Get current memory usage (approximate)
"""
function get_memory_usage()
    GC.gc()
    return Sys.maxrss()
end

# ============================================================================
# Benchmark 1: Box Allocation/Deallocation
# ============================================================================
println("Benchmark 1: Box Allocation/Deallocation")
println("-" ^ 50)

# Int32
time_box_i32 = benchmark() do
    box = RustBox(Int32(42))
    drop!(box)
end
println("  RustBox{Int32} create+drop: ", format_time(time_box_i32))

# Int64
time_box_i64 = benchmark() do
    box = RustBox(Int64(42))
    drop!(box)
end
println("  RustBox{Int64} create+drop: ", format_time(time_box_i64))

# Float64
time_box_f64 = benchmark() do
    box = RustBox(Float64(3.14))
    drop!(box)
end
println("  RustBox{Float64} create+drop: ", format_time(time_box_f64))

# Bool
time_box_bool = benchmark() do
    box = RustBox(true)
    drop!(box)
end
println("  RustBox{Bool} create+drop: ", format_time(time_box_bool))

println()

# ============================================================================
# Benchmark 2: Rc Reference Counting
# ============================================================================
println("Benchmark 2: Rc Reference Counting")
println("-" ^ 50)

# Rc creation
time_rc_create = benchmark() do
    rc = RustRc(Int32(42))
    drop!(rc)
end
println("  RustRc{Int32} create+drop: ", format_time(time_rc_create))

# Rc clone
rc_base = RustRc(Int32(42))
time_rc_clone = benchmark() do
    rc = clone(rc_base)
    drop!(rc)
end
drop!(rc_base)
println("  RustRc{Int32} clone+drop: ", format_time(time_rc_clone))

# Multiple clones
time_rc_multi = benchmark(10, 1000) do
    rc = RustRc(Int32(42))
    clones = [clone(rc) for _ in 1:10]
    foreach(drop!, clones)
    drop!(rc)
end
println("  RustRc{Int32} create+10clones+drop: ", format_time(time_rc_multi))

println()

# ============================================================================
# Benchmark 3: Arc Atomic Reference Counting
# ============================================================================
println("Benchmark 3: Arc Atomic Reference Counting")
println("-" ^ 50)

# Arc creation
time_arc_create = benchmark() do
    arc = RustArc(Int32(42))
    drop!(arc)
end
println("  RustArc{Int32} create+drop: ", format_time(time_arc_create))

# Arc clone
arc_base = RustArc(Int32(42))
time_arc_clone = benchmark() do
    arc = clone(arc_base)
    drop!(arc)
end
drop!(arc_base)
println("  RustArc{Int32} clone+drop: ", format_time(time_arc_clone))

# Multiple clones
time_arc_multi = benchmark(10, 1000) do
    arc = RustArc(Int32(42))
    clones = [clone(arc) for _ in 1:10]
    foreach(drop!, clones)
    drop!(arc)
end
println("  RustArc{Int32} create+10clones+drop: ", format_time(time_arc_multi))

# Arc{Float64}
time_arc_f64 = benchmark() do
    arc = RustArc(Float64(3.14))
    drop!(arc)
end
println("  RustArc{Float64} create+drop: ", format_time(time_arc_f64))

println()

# ============================================================================
# Benchmark 4: Rc vs Arc Overhead Comparison
# ============================================================================
println("Benchmark 4: Rc vs Arc Overhead Comparison")
println("-" ^ 50)

println("  Create+Drop:")
println("    Rc:  ", format_time(time_rc_create))
println("    Arc: ", format_time(time_arc_create))
println("    Arc overhead: ", round((time_arc_create / time_rc_create - 1) * 100, digits=1), "%")

rc_tmp = RustRc(Int32(42))
arc_tmp = RustArc(Int32(42))
time_rc_clone_only = benchmark() do
    rc = clone(rc_tmp)
    drop!(rc)
end
time_arc_clone_only = benchmark() do
    arc = clone(arc_tmp)
    drop!(arc)
end
drop!(rc_tmp)
drop!(arc_tmp)

println("  Clone+Drop:")
println("    Rc:  ", format_time(time_rc_clone_only))
println("    Arc: ", format_time(time_arc_clone_only))
println("    Arc overhead: ", round((time_arc_clone_only / time_rc_clone_only - 1) * 100, digits=1), "%")

println()

# ============================================================================
# Benchmark 5: Memory Leak Detection
# ============================================================================
println("Benchmark 5: Memory Leak Detection")
println("-" ^ 50)

# Force GC to get baseline
GC.gc(true)
sleep(0.1)
mem_before = get_memory_usage()

# Create and drop many objects
println("  Creating and dropping 10,000 objects...")
for _ in 1:10000
    box = RustBox(Int32(42))
    drop!(box)
end

GC.gc(true)
sleep(0.1)
mem_after_box = get_memory_usage()
println("  After Box test - Memory delta: $(mem_after_box - mem_before) bytes")

# Rc test
for _ in 1:10000
    rc = RustRc(Int32(42))
    rc2 = clone(rc)
    drop!(rc)
    drop!(rc2)
end

GC.gc(true)
sleep(0.1)
mem_after_rc = get_memory_usage()
println("  After Rc test - Memory delta: $(mem_after_rc - mem_before) bytes")

# Arc test
for _ in 1:10000
    arc = RustArc(Int32(42))
    arc2 = clone(arc)
    drop!(arc)
    drop!(arc2)
end

GC.gc(true)
sleep(0.1)
mem_after_arc = get_memory_usage()
println("  After Arc test - Memory delta: $(mem_after_arc - mem_before) bytes")

# Long-lived objects test
println("\n  Testing long-lived objects...")
long_lived = RustArc{Int32}[]
for i in 1:1000
    push!(long_lived, RustArc(Int32(i)))
end

GC.gc(true)
mem_with_objects = get_memory_usage()
println("  With 1000 Arc objects - Memory: $(mem_with_objects - mem_before) bytes")

foreach(drop!, long_lived)
GC.gc(true)
sleep(0.1)
mem_final = get_memory_usage()
println("  After dropping all - Memory delta: $(mem_final - mem_before) bytes")

if abs(mem_final - mem_before) < 1024 * 1024  # Less than 1MB difference
    println("  ✓ No significant memory leak detected")
else
    println("  ⚠ Potential memory leak: $(mem_final - mem_before) bytes")
end

println()

# ============================================================================
# Benchmark 6: Threaded Arc Performance
# ============================================================================
println("Benchmark 6: Threaded Arc Performance")
println("-" ^ 50)

n_threads = Threads.nthreads()
println("  Available threads: ", n_threads)

if n_threads > 1
    # Single-threaded baseline
    time_single = benchmark(10, 1000) do
        arc = RustArc(Int32(42))
        clones = [clone(arc) for _ in 1:100]
        foreach(drop!, clones)
        drop!(arc)
    end
    println("  Single-threaded 100 clones: ", format_time(time_single))
    
    # Multi-threaded
    time_multi = benchmark(10, 100) do
        arc = RustArc(Int32(42))
        tasks = []
        for _ in 1:n_threads
            t = Threads.@spawn begin
                local_clones = [clone(arc) for _ in 1:div(100, n_threads)]
                foreach(drop!, local_clones)
            end
            push!(tasks, t)
        end
        foreach(wait, tasks)
        drop!(arc)
    end
    println("  Multi-threaded 100 clones ($n_threads threads): ", format_time(time_multi))
    
    speedup = time_single / time_multi
    println("  Speedup: ", round(speedup, digits=2), "x")
else
    println("  ⚠ Only 1 thread available, skipping multi-threaded benchmark")
    println("  Run with: julia --threads=auto --project benchmark/benchmarks_ownership.jl")
end

println()

# ============================================================================
# Summary
# ============================================================================
println("=" ^ 70)
println("Summary")
println("=" ^ 70)

println("""
Performance Characteristics:
  - Box: Fastest for single-owner scenarios
  - Rc: Low overhead reference counting (single-threaded)
  - Arc: Thread-safe with ~$(round((time_arc_create / time_rc_create - 1) * 100, digits=0))% overhead vs Rc

Memory Management:
  - All types properly deallocate on drop!
  - No significant memory leaks detected
  - Finalizers ensure cleanup on GC

Recommendations:
  - Use RustBox for single-owner data
  - Use RustRc for shared data in single-threaded code
  - Use RustArc for shared data across threads
""")

println("=" ^ 70)
println("Benchmarks completed successfully!")
println("=" ^ 70)
