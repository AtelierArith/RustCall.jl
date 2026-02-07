# Performance benchmarks for generic functions in RustCall.jl
# Tests monomorphization cost and performance of generic vs specialized functions

using RustCall
using BenchmarkTools

# Only run benchmarks if rustc is available
if !RustCall.check_rustc_available()
    error("rustc not found. Benchmarks require Rust to be installed.")
end

println("Setting up generic Rust functions for benchmarks...")

# Register generic functions
identity_code = """
#[no_mangle]
pub extern "C" fn identity<T>(x: T) -> T {
    x
}
"""

add_code = """
#[no_mangle]
pub extern "C" fn add<T>(a: T, b: T) -> T {
    a + b
}
"""

# Note: These generic functions need trait bounds for + operator
# For now, we'll use specialized versions for benchmarking
rust"""
#[no_mangle]
pub extern "C" fn bench_identity_i32(x: i32) -> i32 { x }

#[no_mangle]
pub extern "C" fn bench_identity_i64(x: i64) -> i64 { x }

#[no_mangle]
pub extern "C" fn bench_identity_f64(x: f64) -> f64 { x }

#[no_mangle]
pub extern "C" fn bench_add_i32(a: i32, b: i32) -> i32 { a + b }

#[no_mangle]
pub extern "C" fn bench_add_i64(a: i64, b: i64) -> i64 { a + b }

#[no_mangle]
pub extern "C" fn bench_add_f64(a: f64, b: f64) -> f64 { a + b }
"""

# Register generic functions (for monomorphization testing)
println("Registering generic functions...")
try
    register_generic_function("identity", identity_code, [:T])
    @info "Generic function 'identity' registered"
catch e
    @warn "Failed to register generic function: $e"
end

# Julia native functions for comparison
julia_identity_i32(x::Int32) = x
julia_identity_i64(x::Int64) = x
julia_identity_f64(x::Float64) = x
julia_add_i32(a::Int32, b::Int32) = a + b
julia_add_i64(a::Int64, b::Int64) = a + b
julia_add_f64(a::Float64, b::Float64) = a + b

# Benchmark suite
println("\n" * "="^60)
println("RustCall.jl Generics Performance Benchmark Suite")
println("="^60)

suite = BenchmarkGroup()

# ============================================================================
# Identity Function Benchmarks (testing monomorphization)
# ============================================================================

println("\n--- Identity Function (i32) ---")

suite["identity_i32"] = BenchmarkGroup()

test_value_i32 = Int32(42)
test_value_i64 = Int64(42)
test_value_f64 = 42.0

println("Julia native:")
suite["identity_i32"]["julia"] = @benchmark julia_identity_i32($test_value_i32)
display(suite["identity_i32"]["julia"])

println("\n@rust macro (specialized):")
suite["identity_i32"]["rust_specialized"] = @benchmark @rust bench_identity_i32($test_value_i32)::Int32
display(suite["identity_i32"]["rust_specialized"])

# Test generic function if available
if is_generic_function("identity")
    println("\n@rust macro (generic, monomorphized):")
    try
        # First call triggers monomorphization
        call_generic_function("identity", test_value_i32)
        suite["identity_i32"]["rust_generic"] = @benchmark call_generic_function("identity", $test_value_i32)
        display(suite["identity_i32"]["rust_generic"])
    catch e
        @warn "Generic function test skipped: $e"
    end
end

# ============================================================================
# Identity Function Benchmarks (i64)
# ============================================================================

println("\n--- Identity Function (i64) ---")

suite["identity_i64"] = BenchmarkGroup()

println("\nJulia native:")
suite["identity_i64"]["julia"] = @benchmark julia_identity_i64($test_value_i64)
display(suite["identity_i64"]["julia"])

println("\n@rust macro (specialized):")
suite["identity_i64"]["rust_specialized"] = @benchmark @rust bench_identity_i64($test_value_i64)::Int64
display(suite["identity_i64"]["rust_specialized"])

# ============================================================================
# Identity Function Benchmarks (f64)
# ============================================================================

println("\n--- Identity Function (f64) ---")

suite["identity_f64"] = BenchmarkGroup()

println("\nJulia native:")
suite["identity_f64"]["julia"] = @benchmark julia_identity_f64($test_value_f64)
display(suite["identity_f64"]["julia"])

println("\n@rust macro (specialized):")
suite["identity_f64"]["rust_specialized"] = @benchmark @rust bench_identity_f64($test_value_f64)::Float64
display(suite["identity_f64"]["rust_specialized"])

# ============================================================================
# Add Function Benchmarks
# ============================================================================

println("\n--- Add Function (i32) ---")

suite["add_i32"] = BenchmarkGroup()

test_a_i32 = Int32(10)
test_b_i32 = Int32(20)

println("\nJulia native:")
suite["add_i32"]["julia"] = @benchmark julia_add_i32($test_a_i32, $test_b_i32)
display(suite["add_i32"]["julia"])

println("\n@rust macro (specialized):")
suite["add_i32"]["rust_specialized"] = @benchmark @rust bench_add_i32($test_a_i32, $test_b_i32)::Int32
display(suite["add_i32"]["rust_specialized"])

# ============================================================================
# Monomorphization Cost Benchmark
# ============================================================================

if is_generic_function("identity")
    println("\n--- Monomorphization Cost ---")

    suite["monomorphization"] = BenchmarkGroup()

        println("First monomorphization (includes compilation):")
        try
            # Clear cache to measure first-time cost
            # Note: This is approximate as we can't easily clear the monomorphization cache
            suite["monomorphization"]["first_call"] = @benchmark begin
                # This will trigger compilation if not cached
                call_generic_function("identity", Int32(42))
            end
            display(suite["monomorphization"]["first_call"])

            println("\nSubsequent calls (cached):")
            suite["monomorphization"]["cached_call"] = @benchmark call_generic_function("identity", Int32(42))
            display(suite["monomorphization"]["cached_call"])

            println("\nSpecialized function call (for comparison):")
            suite["monomorphization"]["specialized"] = @benchmark @rust bench_identity_i32(Int32(42))::Int32
            display(suite["monomorphization"]["specialized"])
        catch e
            @warn "Monomorphization cost test skipped: $e"
        end
end

# ============================================================================
# Type Parameter Performance Comparison
# ============================================================================

println("\n--- Type Parameter Performance Comparison ---")

suite["type_params"] = BenchmarkGroup()

println("\ni32 specialization:")
suite["type_params"]["i32"] = @benchmark @rust bench_identity_i32(Int32(42))::Int32
display(suite["type_params"]["i32"])

println("\ni64 specialization:")
suite["type_params"]["i64"] = @benchmark @rust bench_identity_i64(Int64(42))::Int64
display(suite["type_params"]["i64"])

println("\nf64 specialization:")
suite["type_params"]["f64"] = @benchmark @rust bench_identity_f64(42.0)::Float64
display(suite["type_params"]["f64"])

# ============================================================================
# Summary
# ============================================================================

println("\n" * "="^60)
println("Generics Performance Benchmark Summary")
println("="^60)

if haskey(suite, "identity_i32")
    println("\nIdentity Function (i32):")
    if haskey(suite["identity_i32"], "julia")
        println("  Julia:          $(minimum(suite["identity_i32"]["julia"]).time) ns")
    end
    if haskey(suite["identity_i32"], "rust_specialized")
        println("  @rust (spec):   $(minimum(suite["identity_i32"]["rust_specialized"]).time) ns")
    end
    if haskey(suite["identity_i32"], "rust_generic")
        println("  Generic:        $(minimum(suite["identity_i32"]["rust_generic"]).time) ns")
    end
end

if haskey(suite, "monomorphization")
    println("\nMonomorphization Cost:")
    if haskey(suite["monomorphization"], "first_call")
        println("  First call:     $(minimum(suite["monomorphization"]["first_call"]).time) ns")
    end
    if haskey(suite["monomorphization"], "cached_call")
        println("  Cached call:    $(minimum(suite["monomorphization"]["cached_call"]).time) ns")
    end
    if haskey(suite["monomorphization"], "specialized")
        println("  Specialized:    $(minimum(suite["monomorphization"]["specialized"]).time) ns")
    end
end

if haskey(suite, "type_params")
    println("\nType Parameter Performance:")
    if haskey(suite["type_params"], "i32")
        println("  i32:            $(minimum(suite["type_params"]["i32"]).time) ns")
    end
    if haskey(suite["type_params"], "i64")
        println("  i64:            $(minimum(suite["type_params"]["i64"]).time) ns")
    end
    if haskey(suite["type_params"], "f64")
        println("  f64:            $(minimum(suite["type_params"]["f64"]).time) ns")
    end
end

println("\n" * "="^60)
