# Performance benchmarks specifically for @rust_llvm
# Tests quantitative performance improvements over @rust

using RustCall
using BenchmarkTools

# Only run benchmarks if rustc is available
if !RustCall.check_rustc_available()
    error("rustc not found. Benchmarks require Rust to be installed.")
end

println("Setting up Rust functions for @rust_llvm benchmarks...")

# Define Rust functions for benchmarking
rust"""
#[no_mangle]
pub extern "C" fn llvm_bench_add_i32(a: i32, b: i32) -> i32 {
    a + b
}

#[no_mangle]
pub extern "C" fn llvm_bench_add_i64(a: i64, b: i64) -> i64 {
    a + b
}

#[no_mangle]
pub extern "C" fn llvm_bench_add_f64(a: f64, b: f64) -> f64 {
    a + b
}

#[no_mangle]
pub extern "C" fn llvm_bench_mul_i32(a: i32, b: i32) -> i32 {
    a * b
}

#[no_mangle]
pub extern "C" fn llvm_bench_mul_f64(a: f64, b: f64) -> f64 {
    a * b
}

#[no_mangle]
pub extern "C" fn llvm_bench_fib(n: i32) -> i32 {
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
pub extern "C" fn llvm_bench_sum_array(ptr: *const i32, len: usize) -> i32 {
    if ptr.is_null() || len == 0 {
        return 0;
    }
    let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
    slice.iter().sum()
}
"""

# Register all functions for @rust_llvm
println("Registering functions for LLVM integration...")
for func_name in ["llvm_bench_add_i32", "llvm_bench_add_i64", "llvm_bench_add_f64",
                  "llvm_bench_mul_i32", "llvm_bench_mul_f64", "llvm_bench_fib", "llvm_bench_sum_array"]
    code = """
    #[no_mangle]
    pub extern "C" fn $func_name"""

    if func_name == "llvm_bench_add_i32"
        code *= "(a: i32, b: i32) -> i32 { a + b }"
    elseif func_name == "llvm_bench_add_i64"
        code *= "(a: i64, b: i64) -> i64 { a + b }"
    elseif func_name == "llvm_bench_add_f64"
        code *= "(a: f64, b: f64) -> f64 { a + b }"
    elseif func_name == "llvm_bench_mul_i32"
        code *= "(a: i32, b: i32) -> i32 { a * b }"
    elseif func_name == "llvm_bench_mul_f64"
        code *= "(a: f64, b: f64) -> f64 { a * b }"
    elseif func_name == "llvm_bench_fib"
        code *= """(n: i32) -> i32 {
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
        }"""
    elseif func_name == "llvm_bench_sum_array"
        code *= """(ptr: *const i32, len: usize) -> i32 {
            if ptr.is_null() || len == 0 {
                return 0;
            }
            let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
            slice.iter().sum()
        }"""
    end

    try
        RustCall.compile_and_register_rust_function(code, func_name)
        println("✓ Registered $func_name")
    catch e
        @warn "Failed to register $func_name: $e"
    end
end

# Julia native functions for comparison
julia_add_i32(a::Int32, b::Int32) = a + b
julia_add_i64(a::Int64, b::Int64) = a + b
julia_add_f64(a::Float64, b::Float64) = a + b
julia_mul_i32(a::Int32, b::Int32) = a * b
julia_mul_f64(a::Float64, b::Float64) = a * b

function julia_fib(n::Int32)
    n <= 1 && return n
    a, b = Int32(0), Int32(1)
    for _ in 2:n
        a, b = b, a + b
    end
    return b
end

julia_sum_array(v::Vector{Int32}) = sum(v)

# Benchmark suite
println("\n" * "="^70)
println("RustCall.jl @rust_llvm Performance Benchmark Suite")
println("="^70)

suite = BenchmarkGroup()

# ============================================================================
# Simple Arithmetic Operations
# ============================================================================

println("\n--- Simple Arithmetic: Addition (i32) ---")
suite["add_i32"] = BenchmarkGroup()

println("Julia native:")
suite["add_i32"]["julia"] = @benchmark julia_add_i32(Int32(100), Int32(200))
display(suite["add_i32"]["julia"])

println("\n@rust macro:")
suite["add_i32"]["rust"] = @benchmark @rust llvm_bench_add_i32(Int32(100), Int32(200))::Int32
display(suite["add_i32"]["rust"])

println("\n@rust_llvm macro:")
suite["add_i32"]["rust_llvm"] = @benchmark @rust_llvm llvm_bench_add_i32(Int32(100), Int32(200))
display(suite["add_i32"]["rust_llvm"])

println("\n--- Simple Arithmetic: Addition (f64) ---")
suite["add_f64"] = BenchmarkGroup()

println("Julia native:")
suite["add_f64"]["julia"] = @benchmark julia_add_f64(100.0, 200.0)
display(suite["add_f64"]["julia"])

println("\n@rust macro:")
suite["add_f64"]["rust"] = @benchmark @rust llvm_bench_add_f64(100.0, 200.0)::Float64
display(suite["add_f64"]["rust"])

println("\n@rust_llvm macro:")
suite["add_f64"]["rust_llvm"] = @benchmark @rust_llvm llvm_bench_add_f64(100.0, 200.0)
display(suite["add_f64"]["rust_llvm"])

println("\n--- Simple Arithmetic: Multiplication (i32) ---")
suite["mul_i32"] = BenchmarkGroup()

println("Julia native:")
suite["mul_i32"]["julia"] = @benchmark julia_mul_i32(Int32(100), Int32(200))
display(suite["mul_i32"]["julia"])

println("\n@rust macro:")
suite["mul_i32"]["rust"] = @benchmark @rust llvm_bench_mul_i32(Int32(100), Int32(200))::Int32
display(suite["mul_i32"]["rust"])

println("\n@rust_llvm macro:")
suite["mul_i32"]["rust_llvm"] = @benchmark @rust_llvm llvm_bench_mul_i32(Int32(100), Int32(200))
display(suite["mul_i32"]["rust_llvm"])

# ============================================================================
# Complex Computation: Fibonacci
# ============================================================================

println("\n--- Complex Computation: Fibonacci (n=20) ---")
suite["fib"] = BenchmarkGroup()

println("Julia native:")
suite["fib"]["julia"] = @benchmark julia_fib(Int32(20))
display(suite["fib"]["julia"])

println("\n@rust macro:")
suite["fib"]["rust"] = @benchmark @rust llvm_bench_fib(Int32(20))::Int32
display(suite["fib"]["rust"])

println("\n@rust_llvm macro:")
suite["fib"]["rust_llvm"] = @benchmark @rust_llvm llvm_bench_fib(Int32(20))
display(suite["fib"]["rust_llvm"])

# ============================================================================
# Array Operations
# ============================================================================

println("\n--- Array Operations: Sum (size=1000) ---")
suite["sum_array"] = BenchmarkGroup()

test_array = Int32[1:1000;]

println("Julia native:")
suite["sum_array"]["julia"] = @benchmark julia_sum_array($test_array)
display(suite["sum_array"]["julia"])

println("\n@rust macro:")
suite["sum_array"]["rust"] = @benchmark @rust llvm_bench_sum_array(pointer($test_array), length($test_array))::Int32
display(suite["sum_array"]["rust"])

println("\n@rust_llvm macro:")
suite["sum_array"]["rust_llvm"] = @benchmark @rust_llvm llvm_bench_sum_array(pointer($test_array), length($test_array))
display(suite["sum_array"]["rust_llvm"])

# ============================================================================
# Performance Summary and Analysis
# ============================================================================

println("\n" * "="^70)
println("Performance Summary and Analysis")
println("="^70)

function print_comparison(name, julia_time, rust_time, rust_llvm_time)
    julia_ns = minimum(julia_time).time
    rust_ns = minimum(rust_time).time
    rust_llvm_ns = minimum(rust_llvm_time).time

    rust_overhead = (rust_ns / julia_ns - 1.0) * 100
    rust_llvm_overhead = (rust_llvm_ns / julia_ns - 1.0) * 100
    improvement = ((rust_ns - rust_llvm_ns) / rust_ns) * 100

    println("\n$name:")
    println("  Julia native:     $(round(julia_ns, digits=2)) ns")
    println("  @rust:            $(round(rust_ns, digits=2)) ns ($(round(rust_overhead, digits=1))% overhead)")
    println("  @rust_llvm:       $(round(rust_llvm_ns, digits=2)) ns ($(round(rust_llvm_overhead, digits=1))% overhead)")
    if improvement > 0
        println("  @rust_llvm improvement over @rust: $(round(improvement, digits=1))%")
    else
        println("  @rust_llvm overhead over @rust: $(round(-improvement, digits=1))%")
    end
end

if haskey(suite, "add_i32") && haskey(suite["add_i32"], "rust_llvm")
    print_comparison("Integer Addition (i32)",
                     suite["add_i32"]["julia"],
                     suite["add_i32"]["rust"],
                     suite["add_i32"]["rust_llvm"])
end

if haskey(suite, "add_f64") && haskey(suite["add_f64"], "rust_llvm")
    print_comparison("Float Addition (f64)",
                     suite["add_f64"]["julia"],
                     suite["add_f64"]["rust"],
                     suite["add_f64"]["rust_llvm"])
end

if haskey(suite, "mul_i32") && haskey(suite["mul_i32"], "rust_llvm")
    print_comparison("Integer Multiplication (i32)",
                     suite["mul_i32"]["julia"],
                     suite["mul_i32"]["rust"],
                     suite["mul_i32"]["rust_llvm"])
end

if haskey(suite, "fib") && haskey(suite["fib"], "rust_llvm")
    print_comparison("Fibonacci (n=20)",
                     suite["fib"]["julia"],
                     suite["fib"]["rust"],
                     suite["fib"]["rust_llvm"])
end

if haskey(suite, "sum_array") && haskey(suite["sum_array"], "rust_llvm")
    print_comparison("Array Sum (size=1000)",
                     suite["sum_array"]["julia"],
                     suite["sum_array"]["rust"],
                     suite["sum_array"]["rust_llvm"])
end

println("\n" * "="^70)
println("Benchmark completed!")
println("="^70)
