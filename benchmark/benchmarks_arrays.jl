# Performance benchmarks for array operations in LastCall.jl
# Tests RustVec, RustSlice, and Julia Vector performance

using LastCall
using BenchmarkTools

# Only run benchmarks if rustc is available
if !LastCall.check_rustc_available()
    error("rustc not found. Benchmarks require Rust to be installed.")
end

println("Setting up Rust functions for array benchmarks...")

# Define Rust functions for array operations
rust"""
#[no_mangle]
pub extern "C" fn bench_vec_sum_i32(ptr: *const i32, len: usize) -> i32 {
    let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
    slice.iter().sum()
}

#[no_mangle]
pub extern "C" fn bench_vec_sum_i64(ptr: *const i64, len: usize) -> i64 {
    let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
    slice.iter().sum()
}

#[no_mangle]
pub extern "C" fn bench_vec_sum_f64(ptr: *const f64, len: usize) -> f64 {
    if ptr.is_null() || len == 0 {
        return 0.0;
    }
    let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
    slice.iter().sum()
}

#[no_mangle]
pub extern "C" fn bench_vec_max_i32(ptr: *const i32, len: usize) -> i32 {
    let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
    *slice.iter().max().unwrap_or(&0)
}

#[no_mangle]
pub extern "C" fn bench_vec_dot_product(ptr1: *const f64, ptr2: *const f64, len: usize) -> f64 {
    let slice1 = unsafe { std::slice::from_raw_parts(ptr1, len) };
    let slice2 = unsafe { std::slice::from_raw_parts(ptr2, len) };
    slice1.iter().zip(slice2.iter()).map(|(a, b)| a * b).sum()
}
"""

# Julia native functions for comparison
julia_vec_sum_i32(v::Vector{Int32}) = sum(v)
julia_vec_sum_i64(v::Vector{Int64}) = sum(v)
julia_vec_sum_f64(v::Vector{Float64}) = sum(v)
julia_vec_max_i32(v::Vector{Int32}) = maximum(v)
julia_vec_dot_product(v1::Vector{Float64}, v2::Vector{Float64}) = sum(v1 .* v2)

# Benchmark suite
println("\n" * "="^60)
println("LastCall.jl Array Operations Benchmark Suite")
println("="^60)

suite = BenchmarkGroup()

# ============================================================================
# Array Sum Benchmarks (i32)
# ============================================================================

println("\n--- Array Sum (i32, size=1000) ---")

suite["vec_sum_i32"] = BenchmarkGroup()

# Prepare test data
test_vec_i32 = Int32[1:1000;]
test_vec_i64 = Int64[1:1000;]
test_vec_f64 = Float64[1.0:1000.0;]

println("Julia native (Vector{Int32}):")
suite["vec_sum_i32"]["julia"] = @benchmark julia_vec_sum_i32($test_vec_i32)
display(suite["vec_sum_i32"]["julia"])

println("\n@rust macro (passing pointer):")
# Pass Ptr{Int32} directly - ccall handles the conversion
suite["vec_sum_i32"]["rust"] = @benchmark @rust bench_vec_sum_i32(pointer($test_vec_i32), length($test_vec_i32))::Int32
display(suite["vec_sum_i32"]["rust"])

# Test RustVec if available
if LastCall.is_rust_helpers_available()
    println("\nRustVec indexing and iteration:")
    try
        rust_vec = RustVec(test_vec_i32)
        println("RustVec indexing (sequential):")
        suite["vec_sum_i32"]["rustvec_index"] = @benchmark begin
            s = Int32(0)
            for i in 1:length($rust_vec)
                s += $rust_vec[i]
            end
            s
        end
        display(suite["vec_sum_i32"]["rustvec_index"])
        
        println("\nRustVec iteration (sum):")
        suite["vec_sum_i32"]["rustvec_iter"] = @benchmark sum($rust_vec)
        display(suite["vec_sum_i32"]["rustvec_iter"])
        
        println("\nRustVec -> Julia Vector conversion:")
        suite["vec_sum_i32"]["rustvec_to_julia"] = @benchmark Vector($rust_vec)
        display(suite["vec_sum_i32"]["rustvec_to_julia"])
    catch e
        @warn "RustVec tests skipped: $e"
    end
end

# ============================================================================
# Array Sum Benchmarks (i64)
# ============================================================================

println("\n--- Array Sum (i64, size=1000) ---")

suite["vec_sum_i64"] = BenchmarkGroup()

println("\nJulia native (Vector{Int64}):")
suite["vec_sum_i64"]["julia"] = @benchmark julia_vec_sum_i64($test_vec_i64)
display(suite["vec_sum_i64"]["julia"])

println("\n@rust macro (passing pointer):")
suite["vec_sum_i64"]["rust"] = @benchmark @rust bench_vec_sum_i64(pointer($test_vec_i64), length($test_vec_i64))::Int64
display(suite["vec_sum_i64"]["rust"])

# ============================================================================
# Array Sum Benchmarks (f64)
# ============================================================================

println("\n--- Array Sum (f64, size=1000) ---")

suite["vec_sum_f64"] = BenchmarkGroup()

println("\nJulia native (Vector{Float64}):")
suite["vec_sum_f64"]["julia"] = @benchmark julia_vec_sum_f64($test_vec_f64)
display(suite["vec_sum_f64"]["julia"])

println("\n@rust macro (passing pointer):")
# Pass Ptr{Float64} directly - ccall handles the conversion
suite["vec_sum_f64"]["rust"] = @benchmark @rust bench_vec_sum_f64(pointer($test_vec_f64), length($test_vec_f64))::Float64
display(suite["vec_sum_f64"]["rust"])

# ============================================================================
# Array Maximum Benchmarks
# ============================================================================

println("\n--- Array Maximum (i32, size=1000) ---")

suite["vec_max_i32"] = BenchmarkGroup()

println("\nJulia native (Vector{Int32}):")
suite["vec_max_i32"]["julia"] = @benchmark julia_vec_max_i32($test_vec_i32)
display(suite["vec_max_i32"]["julia"])

println("\n@rust macro (passing pointer):")
suite["vec_max_i32"]["rust"] = @benchmark @rust bench_vec_max_i32(pointer($test_vec_i32), length($test_vec_i32))::Int32
display(suite["vec_max_i32"]["rust"])

# ============================================================================
# Dot Product Benchmarks
# ============================================================================

println("\n--- Dot Product (f64, size=1000) ---")

suite["vec_dot_product"] = BenchmarkGroup()

test_vec_f64_2 = Float64[1.0:1000.0;] .* 2.0

println("\nJulia native (Vector{Float64}):")
suite["vec_dot_product"]["julia"] = @benchmark julia_vec_dot_product($test_vec_f64, $test_vec_f64_2)
display(suite["vec_dot_product"]["julia"])

println("\n@rust macro (passing pointers):")
suite["vec_dot_product"]["rust"] = @benchmark @rust bench_vec_dot_product(
    pointer($test_vec_f64), 
    pointer($test_vec_f64_2), 
    length($test_vec_f64)
)::Float64
display(suite["vec_dot_product"]["rust"])

# ============================================================================
# RustVec Indexing Performance
# ============================================================================

if LastCall.is_rust_helpers_available()
    println("\n--- RustVec Indexing Performance ---")
    
    suite["rustvec_indexing"] = BenchmarkGroup()
    
    try
        rust_vec = RustVec(test_vec_i32)
        
        println("RustVec indexing (sequential access):")
        suite["rustvec_indexing"]["sequential"] = @benchmark begin
            s = Int32(0)
            for i in 1:length($rust_vec)
                s += $rust_vec[i]
            end
            s
        end
        display(suite["rustvec_indexing"]["sequential"])
        
        println("\nRustVec indexing (random access):")
        suite["rustvec_indexing"]["random"] = @benchmark begin
            s = Int32(0)
            indices = [1, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000]
            for i in indices
                if i <= length($rust_vec)
                    s += $rust_vec[i]
                end
            end
            s
        end
        display(suite["rustvec_indexing"]["random"])
        
        println("\nJulia Vector indexing (for comparison):")
        suite["rustvec_indexing"]["julia_vector"] = @benchmark begin
            s = Int32(0)
            for i in 1:length($test_vec_i32)
                s += $test_vec_i32[i]
            end
            s
        end
        display(suite["rustvec_indexing"]["julia_vector"])
    catch e
        @warn "RustVec indexing tests skipped: $e"
    end
end

# ============================================================================
# RustVec Iteration Performance
# ============================================================================

if LastCall.is_rust_helpers_available()
    println("\n--- RustVec Iteration Performance ---")
    
    suite["rustvec_iteration"] = BenchmarkGroup()
    
    try
        rust_vec = RustVec(test_vec_i32)
        
        println("RustVec iteration (for loop):")
        suite["rustvec_iteration"]["for_loop"] = @benchmark begin
            s = Int32(0)
            for x in $rust_vec
                s += x
            end
            s
        end
        display(suite["rustvec_iteration"]["for_loop"])
        
        println("\nRustVec iteration (sum):")
        suite["rustvec_iteration"]["sum"] = @benchmark sum($rust_vec)
        display(suite["rustvec_iteration"]["sum"])
        
        println("\nJulia Vector iteration (for comparison):")
        suite["rustvec_iteration"]["julia_vector"] = @benchmark begin
            s = Int32(0)
            for x in $test_vec_i32
                s += x
            end
            s
        end
        display(suite["rustvec_iteration"]["julia_vector"])
    catch e
        @warn "RustVec iteration tests skipped: $e"
    end
end

# ============================================================================
# Array Conversion Performance
# ============================================================================

if LastCall.is_rust_helpers_available()
    println("\n--- Array Conversion Performance ---")
    
    suite["array_conversion"] = BenchmarkGroup()
    
    try
        println("Julia Vector -> RustVec conversion:")
        suite["array_conversion"]["julia_to_rustvec"] = @benchmark RustVec($test_vec_i32)
        display(suite["array_conversion"]["julia_to_rustvec"])
        
        rust_vec = RustVec(test_vec_i32)
        println("\nRustVec -> Julia Vector conversion:")
        suite["array_conversion"]["rustvec_to_julia"] = @benchmark Vector($rust_vec)
        display(suite["array_conversion"]["rustvec_to_julia"])
        
        println("\nJulia Vector copy (for comparison):")
        suite["array_conversion"]["julia_copy"] = @benchmark copy($test_vec_i32)
        display(suite["array_conversion"]["julia_copy"])
    catch e
        @warn "Array conversion tests skipped: $e"
    end
end

# ============================================================================
# Summary
# ============================================================================

println("\n" * "="^60)
println("Array Operations Benchmark Summary")
println("="^60)

if haskey(suite, "vec_sum_i32")
    println("\nArray Sum (i32, size=1000):")
    if haskey(suite["vec_sum_i32"], "julia")
        println("  Julia:     $(minimum(suite["vec_sum_i32"]["julia"]).time) ns")
    end
    if haskey(suite["vec_sum_i32"], "rust")
        println("  @rust:     $(minimum(suite["vec_sum_i32"]["rust"]).time) ns")
    end
    if haskey(suite["vec_sum_i32"], "rustvec_index")
        println("  RustVec[index]: $(minimum(suite["vec_sum_i32"]["rustvec_index"]).time) ns")
    end
    if haskey(suite["vec_sum_i32"], "rustvec_iter")
        println("  RustVec[iter]:  $(minimum(suite["vec_sum_i32"]["rustvec_iter"]).time) ns")
    end
end

if haskey(suite, "rustvec_indexing")
    println("\nRustVec Indexing:")
    if haskey(suite["rustvec_indexing"], "sequential")
        println("  Sequential: $(minimum(suite["rustvec_indexing"]["sequential"]).time) ns")
    end
    if haskey(suite["rustvec_indexing"], "julia_vector")
        println("  Julia Vector: $(minimum(suite["rustvec_indexing"]["julia_vector"]).time) ns")
    end
end

if haskey(suite, "array_conversion")
    println("\nArray Conversion:")
    if haskey(suite["array_conversion"], "julia_to_rustvec")
        println("  Julia -> RustVec: $(minimum(suite["array_conversion"]["julia_to_rustvec"]).time) ns")
    end
    if haskey(suite["array_conversion"], "rustvec_to_julia")
        println("  RustVec -> Julia: $(minimum(suite["array_conversion"]["rustvec_to_julia"]).time) ns")
    end
    if haskey(suite["array_conversion"], "julia_copy")
        println("  Julia copy: $(minimum(suite["array_conversion"]["julia_copy"]).time) ns")
    end
end

println("\n" * "="^60)
