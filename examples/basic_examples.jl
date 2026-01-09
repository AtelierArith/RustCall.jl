# Basic Examples for LastCall.jl
#
# This file demonstrates basic usage of LastCall.jl for calling Rust functions from Julia.
#
# Prerequisites:
#   - Rust installed (rustc in PATH)
#   - LastCall.jl package loaded

using LastCall

println("=" ^ 60)
println("LastCall.jl - Basic Examples")
println("=" ^ 60)
println()

# ============================================================================
# Example 1: Simple Function Call
# ============================================================================
println("Example 1: Simple Function Call")
println("-" ^ 40)

# Define a simple Rust function
rust"""
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

# Call the function
result = @rust add(10i32, 20i32)
println("add(10, 20) = $result")
println()

# ============================================================================
# Example 2: Multiple Functions
# ============================================================================
println("Example 2: Multiple Functions")
println("-" ^ 40)

rust"""
#[no_mangle]
pub extern "C" fn multiply(a: i32, b: i32) -> i32 {
    a * b
}

#[no_mangle]
pub extern "C" fn subtract(a: i32, b: i32) -> i32 {
    a - b
}

#[no_mangle]
pub extern "C" fn divide(a: f64, b: f64) -> f64 {
    if b != 0.0 {
        a / b
    } else {
        0.0
    }
}
"""

println("multiply(5, 7) = $(@rust multiply(5i32, 7i32))")
println("subtract(20, 8) = $(@rust subtract(20i32, 8i32))")
println("divide(10.0, 3.0) = $(@rust divide(10.0, 3.0))")
println()

# ============================================================================
# Example 3: Type Inference
# ============================================================================
println("Example 3: Type Inference")
println("-" ^ 40)

rust"""
#[no_mangle]
pub extern "C" fn square(x: i64) -> i64 {
    x * x
}
"""

# Type inference from arguments
result1 = @rust square(5i64)
println("square(5) = $result1")

# Explicit return type annotation
result2 = @rust square(10i64)::Int64
println("square(10) = $result2")
println()

# ============================================================================
# Example 4: String Arguments
# ============================================================================
println("Example 4: String Arguments")
println("-" ^ 40)

rust"""
#[no_mangle]
pub extern "C" fn greet(name: *const u8) -> i32 {
    // Simple function that returns the length
    // In a real application, you'd process the string
    0
}
"""

# String arguments are automatically converted to Cstring
result = @rust greet("Julia")
println("greet(\"Julia\") = $result")
println()

# ============================================================================
# Example 5: Boolean and Void Functions
# ============================================================================
println("Example 5: Boolean and Void Functions")
println("-" ^ 40)

rust"""
#[no_mangle]
pub extern "C" fn is_even(n: i32) -> bool {
    n % 2 == 0
}

#[no_mangle]
pub extern "C" fn print_hello() {
    // Void function - does nothing in this example
}
"""

println("is_even(4) = $(@rust is_even(4i32))")
println("is_even(5) = $(@rust is_even(5i32))")
@rust print_hello()
println("print_hello() called")
println()

# ============================================================================
# Example 6: Using @irust for Inline Functions
# ============================================================================
println("Example 6: Using @irust for Inline Functions")
println("-" ^ 40)

# @irust allows defining and calling functions in one step
result = @irust("""
#[no_mangle]
pub extern "C" fn compute(x: i32, y: i32) -> i32 {
    x * y + 10
}
""", 5i32, 3i32)

println("@irust compute(5, 3) = $result")
println()

# ============================================================================
# Example 7: Error Handling with Result Types
# ============================================================================
println("Example 7: Error Handling with Result Types")
println("-" ^ 40)

rust"""
#[no_mangle]
pub extern "C" fn safe_divide(a: f64, b: f64) -> i32 {
    if b == 0.0 {
        1  // Error code
    } else {
        0  // Success code
    }
}
"""

# In a real application, you'd use RustResult<T, E>
# For now, we use a simple error code
error_code = @rust safe_divide(10.0, 0.0)
if error_code == 0
    println("Division successful")
else
    println("Division by zero error")
end
println()

# ============================================================================
# Example 8: Compiler Configuration
# ============================================================================
println("Example 8: Compiler Configuration")
println("-" ^ 40)

# Create a custom compiler configuration
compiler = RustCompiler(
    optimization_level=3,  # Maximum optimization
    emit_debug_info=false,
    debug_mode=false
)

# Set as default
set_default_compiler(compiler)

println("Compiler configured with optimization level 3")
println("rustc version: $(get_rustc_version())")
println()

# ============================================================================
# Example 9: Cache Management
# ============================================================================
println("Example 9: Cache Management")
println("-" ^ 40)

# Check cache size
cache_size = get_cache_size()
println("Cache size: $(cache_size / 1024) KB")

# List cached libraries
cached_libs = list_cached_libraries()
println("Cached libraries: $(length(cached_libs))")

# Clean up old cache (older than 30 days)
removed = cleanup_old_cache(30)
println("Removed $removed old cache entries")
println()

# ============================================================================
# Example 10: Performance Comparison
# ============================================================================
println("Example 10: Performance Comparison")
println("-" ^ 40)

rust"""
#[no_mangle]
pub extern "C" fn fast_add(a: i32, b: i32) -> i32 {
    a + b
}
"""

# Julia native implementation
function julia_add(a::Int32, b::Int32)::Int32
    return a + b
end

# Benchmark (simple timing)
n = 1_000_000

# Julia native
t1 = time_ns()
for i in 1:n
    julia_add(Int32(i), Int32(i+1))
end
t2 = time_ns()
julia_time = (t2 - t1) / 1e9

# Rust call
t1 = time_ns()
for i in 1:n
    @rust fast_add(Int32(i), Int32(i+1))
end
t2 = time_ns()
rust_time = (t2 - t1) / 1e9

println("Julia native: $(round(julia_time, digits=4)) seconds")
println("Rust call: $(round(rust_time, digits=4)) seconds")
println("Overhead: $(round((rust_time / julia_time - 1) * 100, digits=2))%")
println()

println("=" ^ 60)
println("All examples completed successfully!")
println("=" ^ 60)
