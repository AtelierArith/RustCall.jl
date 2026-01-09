# Advanced Examples for LastCall.jl
#
# This file demonstrates advanced usage of LastCall.jl including:
# - Generic functions
# - Array operations
# - LLVM optimization
# - Error handling
#
# Prerequisites:
#   - Rust installed (rustc in PATH)
#   - LastCall.jl package loaded

using LastCall

println("=" ^ 60)
println("LastCall.jl - Advanced Examples")
println("=" ^ 60)
println()

# ============================================================================
# Example 1: Generic Functions
# ============================================================================
println("Example 1: Generic Functions")
println("-" ^ 40)

# Define a generic function
rust"""
#[no_mangle]
pub extern "C" fn identity_i32(x: i32) -> i32 {
    x
}

#[no_mangle]
pub extern "C" fn identity_i64(x: i64) -> i64 {
    x
}

#[no_mangle]
pub extern "C" fn identity_f64(x: f64) -> f64 {
    x
}
"""

# Register as generic function (simplified - in practice, you'd parse the generic signature)
println("Generic functions registered")
println("identity_i32(42) = $(@rust identity_i32(42i32))")
println("identity_i64(123456789) = $(@rust identity_i64(123456789i64))")
println("identity_f64(3.14159) = $(@rust identity_f64(3.14159))")
println()

# ============================================================================
# Example 2: Array Operations
# ============================================================================
println("Example 2: Array Operations")
println("-" ^ 40)

rust"""
#[no_mangle]
pub extern "C" fn sum_array(ptr: *const i32, len: usize) -> i32 {
    if ptr.is_null() || len == 0 {
        return 0;
    }
    let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
    slice.iter().sum()
}

#[no_mangle]
pub extern "C" fn max_array(ptr: *const i32, len: usize) -> i32 {
    if ptr.is_null() || len == 0 {
        return 0;
    }
    let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
    *slice.iter().max().unwrap_or(&0)
}
"""

# Create a Julia array
arr = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
arr_int32 = Int32.(arr)

# Convert to pointer
ptr = pointer(arr_int32)
len = length(arr_int32)

# Call Rust functions
sum_result = @rust sum_array(ptr, len)
max_result = @rust max_array(ptr, len)

println("Array: $arr")
println("Sum: $sum_result")
println("Max: $max_result")
println()

# ============================================================================
# Example 3: LLVM Optimization
# ============================================================================
println("Example 3: LLVM Optimization")
println("-" ^ 40)

# Define a function for optimization
rust_code = """
#[no_mangle]
pub extern "C" fn optimized_compute(x: f64) -> f64 {
    let mut result = 0.0;
    for i in 0..1000 {
        result += x * (i as f64);
    }
    result
}
"""

rust"""$rust_code"""

# Get the Rust module
mod = get_rust_module(rust_code)

# Apply optimization
if mod !== nothing
    optimize_for_speed!(mod)
    println("LLVM optimization applied")
else
    println("Note: LLVM optimization requires module access")
end
println()

# ============================================================================
# Example 4: Error Handling
# ============================================================================
println("Example 4: Error Handling")
println("-" ^ 40)

rust"""
#[no_mangle]
pub extern "C" fn checked_divide(a: i32, b: i32) -> i32 {
    if b == 0 {
        -1  // Error code
    } else {
        a / b
    }
}
"""

# Test error handling
result1 = @rust checked_divide(10i32, 2i32)
result2 = @rust checked_divide(10i32, 0i32)

println("checked_divide(10, 2) = $result1")
println("checked_divide(10, 0) = $result2 (error code)")
println()

# ============================================================================
# Example 5: Complex Calculations
# ============================================================================
println("Example 5: Complex Calculations")
println("-" ^ 40)

rust"""
#[no_mangle]
pub extern "C" fn fibonacci(n: i32) -> i32 {
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
pub extern "C" fn factorial(n: i32) -> i64 {
    if n <= 1 {
        1
    } else {
        let mut result = 1i64;
        for i in 2..=n {
            result *= i as i64;
        }
        result
    }
}
"""

println("fibonacci(10) = $(@rust fibonacci(10i32))")
println("fibonacci(20) = $(@rust fibonacci(20i32))")
println("factorial(5) = $(@rust factorial(5i32))")
println("factorial(10) = $(@rust factorial(10i32))")
println()

# ============================================================================
# Example 6: String Processing
# ============================================================================
println("Example 6: String Processing")
println("-" ^ 40)

rust"""
#[no_mangle]
pub extern "C" fn string_length(s: *const u8) -> usize {
    // Simplified - in practice, you'd use CStr
    0
}
"""

# String processing example
text = "Hello, LastCall.jl!"
result = @rust string_length(text)
println("String: \"$text\"")
println("Length (simplified): $result")
println()

# ============================================================================
# Example 7: Multiple Libraries
# ============================================================================
println("Example 7: Multiple Libraries")
println("-" ^ 40)

# Define first library
rust"""
#[no_mangle]
pub extern "C" fn lib1_function(x: i32) -> i32 {
    x * 2
}
"""

lib1_name = get_current_library()
result1 = @rust lib1_function(5i32)
println("Library 1: lib1_function(5) = $result1")

# Define second library (would be in a separate rust"" block in practice)
# For demonstration, we show the concept
println("Note: Multiple libraries can be loaded and used independently")
println()

# ============================================================================
# Example 8: Performance Optimization
# ============================================================================
println("Example 8: Performance Optimization")
println("-" ^ 40)

# Register function for faster calls
rust"""
#[no_mangle]
pub extern "C" fn fast_multiply(a: i32, b: i32) -> i32 {
    a * b
}
"""

# Register the function
register_function("fast_multiply", get_current_library(), Int32, [Int32, Int32])

# Now calls are optimized
result = @rust fast_multiply(7i32, 8i32)
println("fast_multiply(7, 8) = $result (registered function)")
println()

# ============================================================================
# Example 9: Cache Usage
# ============================================================================
println("Example 9: Cache Usage")
println("-" ^ 40)

# First compilation (will be cached)
rust"""
#[no_mangle]
pub extern "C" fn cached_function(x: i32) -> i32 {
    x + 100
}
"""

# Second call to the same code (should use cache)
# In practice, the cache is used automatically
result = @rust cached_function(42i32)
println("cached_function(42) = $result")
println("Note: Cache is used automatically for identical code")
println()

# ============================================================================
# Example 10: Integration with Julia Code
# ============================================================================
println("Example 10: Integration with Julia Code")
println("-" ^ 40)

# Define a Rust function for numerical computation
rust"""
#[no_mangle]
pub extern "C" fn compute_polynomial(x: f64, coeffs: *const f64, len: usize) -> f64 {
    if coeffs.is_null() || len == 0 {
        return 0.0;
    }
    let slice = unsafe { std::slice::from_raw_parts(coeffs, len) };
    let mut result = 0.0;
    let mut power = 1.0;
    for &coeff in slice {
        result += coeff * power;
        power *= x;
    }
    result
}
"""

# Use in Julia code
coefficients = [1.0, 2.0, 3.0, 4.0]  # 1 + 2x + 3x² + 4x³
coeffs_f64 = Float64.(coefficients)
ptr = pointer(coeffs_f64)
len = length(coeffs_f64)

# Evaluate polynomial at x = 2.0
x = 2.0
result = @rust compute_polynomial(x, ptr, len)
println("Polynomial: 1 + 2x + 3x² + 4x³")
println("At x = $x: $result")
println("Expected: $(1 + 2*2 + 3*4 + 4*8) = $(1 + 4 + 12 + 32)")
println()

println("=" ^ 60)
println("All advanced examples completed successfully!")
println("=" ^ 60)
