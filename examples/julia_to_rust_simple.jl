using LastCall
using Test

# 1. Define Julia struct
struct Point{T}
    x::T
    y::T
end

# 2. Rust side (True Generics and manual structs)
rust"""
use std::ops::Add;

#[repr(C)]
pub struct Point<T> {
    pub x: T,
    pub y: T,
}

// A truly generic function.
// LastCall will automatically create monomorphized C-wrappers
// when called from Julia.
pub fn sum_values<T: Add<Output = T>>(a: T, b: T) -> T {
    a + b
}

// Even if the function is not generic, we can pass bit-compatible Julia structs
// Note: We use the concrete f64 version here to demonstrate memory compatibility
#[no_mangle]
pub extern "C" fn sum_point_coords(p: Point<f64>) -> f64 {
    p.x + p.y
}
"""

println("--- Passing Primitives to Generic Rust ---")
# LastCall detects 'sum_values' is generic and generates the f64 version
res_f64 = @rust sum_values(10.5, 20.5)::Float64
println("Result (F64): ", res_f64)
@test res_f64 == 31.0

res_i32 = @rust sum_values(Int32(10), Int32(20))::Int32
println("Result (I32): ", res_i32)
@test res_i32 == 30

println("\n--- Passing Parametric Struct to Non-Generic Rust function ---")
p_f64 = Point{Float64}(10.5, 20.5)
res_p = @rust sum_point_coords(p_f64)::Float64
println("Result (Point): ", res_p)
@test res_p == 31.0
