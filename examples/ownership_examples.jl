# Ownership Types Examples for LastCall.jl
# 
# This file demonstrates how to use Rust ownership types (Box, Rc, Arc) from Julia.
# These types provide safe memory management with Rust's ownership semantics.
#
# Prerequisites:
#   - Build Rust helpers library: julia --project -e 'using Pkg; Pkg.build("LastCall")'

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

println("=" ^ 60)
println("LastCall.jl - Ownership Types Examples")
println("=" ^ 60)
println()

# ============================================================================
# Example 1: RustBox - Single Ownership
# ============================================================================
println("Example 1: RustBox - Single Ownership")
println("-" ^ 40)

# RustBox represents Rust's Box<T> - heap-allocated value with single ownership
# When the box is dropped, the memory is freed

# Create a Box containing an Int32
box_i32 = RustBox(Int32(42))
println("Created RustBox{Int32} with value 42")
println("  is_valid: ", is_valid(box_i32))
println("  ptr: ", box_i32.ptr)

# Create boxes with different types
box_i64 = RustBox(Int64(123456789))
box_f64 = RustBox(Float64(3.14159))
box_bool = RustBox(true)

println("Created multiple boxes:")
println("  RustBox{Int64}: ", is_valid(box_i64))
println("  RustBox{Float64}: ", is_valid(box_f64))
println("  RustBox{Bool}: ", is_valid(box_bool))

# Drop boxes (free memory)
drop!(box_i32)
drop!(box_i64)
drop!(box_f64)
drop!(box_bool)

println("After drop!:")
println("  RustBox{Int32} is_dropped: ", is_dropped(box_i32))
println()

# ============================================================================
# Example 2: RustRc - Reference Counting (Single-threaded)
# ============================================================================
println("Example 2: RustRc - Reference Counting (Single-threaded)")
println("-" ^ 40)

# RustRc represents Rust's Rc<T> - reference-counted pointer
# Multiple Rc can point to the same data, data is freed when last Rc is dropped
# Note: Rc is NOT thread-safe, use Arc for multi-threaded scenarios

# Create an Rc
rc1 = RustRc(Int32(100))
println("Created RustRc{Int32} with value 100")
println("  rc1 is_valid: ", is_valid(rc1))

# Clone the Rc (increment reference count)
rc2 = clone(rc1)
println("Cloned rc1 to rc2")
println("  rc1 ptr: ", rc1.ptr)
println("  rc2 ptr: ", rc2.ptr)
println("  Same pointer: ", rc1.ptr == rc2.ptr)

# Drop rc1 (rc2 still holds a reference)
drop!(rc1)
println("After dropping rc1:")
println("  rc1 is_dropped: ", is_dropped(rc1))
println("  rc2 is_valid: ", is_valid(rc2))

# Drop rc2 (last reference, memory freed)
drop!(rc2)
println("After dropping rc2:")
println("  rc2 is_dropped: ", is_dropped(rc2))
println()

# ============================================================================
# Example 3: RustArc - Atomic Reference Counting (Thread-safe)
# ============================================================================
println("Example 3: RustArc - Atomic Reference Counting (Thread-safe)")
println("-" ^ 40)

# RustArc represents Rust's Arc<T> - atomically reference-counted pointer
# Safe to share across threads

# Create an Arc
arc1 = RustArc(Int32(200))
println("Created RustArc{Int32} with value 200")

# Clone multiple times
arc2 = clone(arc1)
arc3 = clone(arc2)
println("Created 3 Arc references")
println("  All point to same data: ", arc1.ptr == arc2.ptr == arc3.ptr)

# Use Arc in multiple tasks (thread-safe)
println("\nUsing Arc across multiple tasks...")

# Spawn tasks that clone and use the Arc
n_tasks = 4
tasks = []
lk = ReentrantLock()
results = Int[]

for i in 1:n_tasks
    t = Threads.@spawn begin
        # Each task clones the Arc
        local_arc = clone(arc1)
        
        # Simulate some work
        sleep(0.01 * i)
        
        # Record result
        lock(lk) do
            push!(results, i)
        end
        
        # Drop the local clone
        drop!(local_arc)
    end
    push!(tasks, t)
end

# Wait for all tasks
foreach(wait, tasks)
println("All tasks completed: ", sort(results))

# Original Arcs still valid
println("Original Arcs still valid: ", is_valid(arc1), ", ", is_valid(arc2), ", ", is_valid(arc3))

# Clean up
drop!(arc1)
drop!(arc2)
drop!(arc3)
println("All Arcs dropped")
println()

# ============================================================================
# Example 4: Memory Management Patterns
# ============================================================================
println("Example 4: Memory Management Patterns")
println("-" ^ 40)

# Pattern 1: Temporary allocation
println("\nPattern 1: Temporary allocation with try-finally")
box = RustBox(Int32(42))
try
    # Use the box...
    println("  Working with box, is_valid: ", is_valid(box))
finally
    drop!(box)
    println("  Box dropped in finally block")
end

# Pattern 2: Multiple references with cleanup
println("\nPattern 2: Multiple Rc references")
rc_main = RustRc(Int64(999))
rc_refs = [clone(rc_main) for _ in 1:5]
println("  Created main Rc + 5 clones")

# Use references...
# ...

# Cleanup all references
drop!(rc_main)
foreach(drop!, rc_refs)
println("  All Rc references dropped")

# Pattern 3: Thread-safe shared data
println("\nPattern 3: Arc for thread-safe shared data")
shared = RustArc(Float64(3.14159))
workers = [clone(shared) for _ in 1:Threads.nthreads()]
println("  Created Arc + $(length(workers)) worker clones")

# Workers use their clones...
# ...

# Cleanup
drop!(shared)
foreach(drop!, workers)
println("  All Arc references dropped")
println()

# ============================================================================
# Example 5: Performance Considerations
# ============================================================================
println("Example 5: Performance Considerations")
println("-" ^ 40)

# Measure allocation/deallocation time
println("\nBenchmarking Box allocation/deallocation:")
n_iterations = 1000

# Warm up
for _ in 1:100
    b = RustBox(Int32(0))
    drop!(b)
end

# Benchmark
t_start = time_ns()
for i in 1:n_iterations
    b = RustBox(Int32(i))
    drop!(b)
end
t_end = time_ns()
println("  $n_iterations Box create/drop: $(round((t_end - t_start) / 1e6, digits=2)) ms")
println("  Average per operation: $(round((t_end - t_start) / n_iterations, digits=2)) ns")

# Benchmark Rc clone
println("\nBenchmarking Rc clone:")
rc = RustRc(Int32(42))
t_start = time_ns()
clones = RustRc{Int32}[]
for _ in 1:n_iterations
    push!(clones, clone(rc))
end
t_clone = time_ns()
foreach(drop!, clones)
drop!(rc)
t_end = time_ns()
println("  $n_iterations Rc clones: $(round((t_clone - t_start) / 1e6, digits=2)) ms")
println("  Drop all: $(round((t_end - t_clone) / 1e6, digits=2)) ms")

println()
println("=" ^ 60)
println("All examples completed successfully!")
println("=" ^ 60)
