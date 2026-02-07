# Benchmarks for RustCall.jl
# Phase 2: Performance comparison between @rust and @rust_llvm

using RustCall
using BenchmarkTools

# Only run benchmarks if rustc is available
if !RustCall.check_rustc_available()
    error("rustc not found. Benchmarks require Rust to be installed.")
end

println("Setting up Rust functions for benchmarks...")

# Define Rust functions for benchmarking
rust"""
#[no_mangle]
pub extern "C" fn bench_add_i32(a: i32, b: i32) -> i32 {
    a + b
}

#[no_mangle]
pub extern "C" fn bench_add_i64(a: i64, b: i64) -> i64 {
    a + b
}

#[no_mangle]
pub extern "C" fn bench_add_f64(a: f64, b: f64) -> f64 {
    a + b
}

#[no_mangle]
pub extern "C" fn bench_mul_i32(a: i32, b: i32) -> i32 {
    a * b
}

#[no_mangle]
pub extern "C" fn bench_fib(n: i32) -> i32 {
    if n <= 1 {
        n
    } else {
        let mut a = 0i32;
        let mut b = 1i32;
        for _ in 2..=n {
            let c = a + b;
            a = b;
            b = c;
        }
        b
    }
}

#[no_mangle]
pub extern "C" fn bench_sum_range(n: i64) -> i64 {
    (1..=n).sum()
}
"""

# Register functions for @rust_llvm
println("Registering functions for LLVM integration...")
compile_and_register_rust_function("""
#[no_mangle]
pub extern "C" fn bench_add_i32(a: i32, b: i32) -> i32 {
    a + b
}
""", "bench_add_i32")

compile_and_register_rust_function("""
#[no_mangle]
pub extern "C" fn bench_add_f64(a: f64, b: f64) -> f64 {
    a + b
}
""", "bench_add_f64")

# Julia native functions for comparison
julia_add_i32(a::Int32, b::Int32) = a + b
julia_add_i64(a::Int64, b::Int64) = a + b
julia_add_f64(a::Float64, b::Float64) = a + b
julia_mul_i32(a::Int32, b::Int32) = a * b

function julia_fib(n::Int32)
    n <= 1 && return n
    a, b = Int32(0), Int32(1)
    for _ in 2:n
        a, b = b, a + b
    end
    return b
end

julia_sum_range(n::Int64) = sum(1:n)

# Benchmark suite
println("\n" * "="^60)
println("RustCall.jl Benchmark Suite")
println("="^60)

suite = BenchmarkGroup()

# ============================================================================
# Integer Addition Benchmarks
# ============================================================================

println("\n--- Integer Addition (i32) ---")

suite["add_i32"] = BenchmarkGroup()

println("Julia native:")
suite["add_i32"]["julia"] = @benchmark julia_add_i32(Int32(100), Int32(200))
display(suite["add_i32"]["julia"])

println("\n@rust macro:")
suite["add_i32"]["rust"] = @benchmark @rust bench_add_i32(Int32(100), Int32(200))::Int32
display(suite["add_i32"]["rust"])

println("\n@rust_llvm macro:")
suite["add_i32"]["rust_llvm"] = @benchmark @rust_llvm bench_add_i32(Int32(100), Int32(200))
display(suite["add_i32"]["rust_llvm"])

# ============================================================================
# Float Addition Benchmarks
# ============================================================================

println("\n--- Float Addition (f64) ---")

suite["add_f64"] = BenchmarkGroup()

println("Julia native:")
suite["add_f64"]["julia"] = @benchmark julia_add_f64(100.0, 200.0)
display(suite["add_f64"]["julia"])

println("\n@rust macro:")
suite["add_f64"]["rust"] = @benchmark @rust bench_add_f64(100.0, 200.0)::Float64
display(suite["add_f64"]["rust"])

println("\n@rust_llvm macro:")
suite["add_f64"]["rust_llvm"] = @benchmark @rust_llvm bench_add_f64(100.0, 200.0)
display(suite["add_f64"]["rust_llvm"])

# ============================================================================
# Fibonacci Benchmarks (more complex computation)
# ============================================================================

println("\n--- Fibonacci (n=20) ---")

suite["fib"] = BenchmarkGroup()

println("Julia native:")
suite["fib"]["julia"] = @benchmark julia_fib(Int32(20))
display(suite["fib"]["julia"])

println("\n@rust macro:")
suite["fib"]["rust"] = @benchmark @rust bench_fib(Int32(20))::Int32
display(suite["fib"]["rust"])

# ============================================================================
# Sum Range Benchmarks
# ============================================================================

println("\n--- Sum Range (n=1000) ---")

suite["sum_range"] = BenchmarkGroup()

println("Julia native:")
suite["sum_range"]["julia"] = @benchmark julia_sum_range(Int64(1000))
display(suite["sum_range"]["julia"])

println("\n@rust macro:")
suite["sum_range"]["rust"] = @benchmark @rust bench_sum_range(Int64(1000))::Int64
display(suite["sum_range"]["rust"])

# ============================================================================
# Summary
# ============================================================================

println("\n" * "="^60)
println("Benchmark Summary")
println("="^60)

println("\nInteger Addition (i32):")
println("  Julia:     $(minimum(suite["add_i32"]["julia"]).time) ns")
println("  @rust:     $(minimum(suite["add_i32"]["rust"]).time) ns")
println("  @rust_llvm:$(minimum(suite["add_i32"]["rust_llvm"]).time) ns")

println("\nFloat Addition (f64):")
println("  Julia:     $(minimum(suite["add_f64"]["julia"]).time) ns")
println("  @rust:     $(minimum(suite["add_f64"]["rust"]).time) ns")
println("  @rust_llvm:$(minimum(suite["add_f64"]["rust_llvm"]).time) ns")

println("\nFibonacci (n=20):")
println("  Julia:     $(minimum(suite["fib"]["julia"]).time) ns")
println("  @rust:     $(minimum(suite["fib"]["rust"]).time) ns")

println("\nSum Range (n=1000):")
println("  Julia:     $(minimum(suite["sum_range"]["julia"]).time) ns")
println("  @rust:     $(minimum(suite["sum_range"]["rust"]).time) ns")

println("\n" * "="^60)
