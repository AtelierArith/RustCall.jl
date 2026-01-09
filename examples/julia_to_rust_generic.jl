# Example: Passing Julia structs to Rust (avoiding name collision)
using LastCall
using Test

# 1. Define Julia struct
struct Point{T}
    x::T
    y::T
end

# 2. Define Rust code
# We don't use 'pub struct' if we don't want LastCall to generate a Julia wrapper
rust"""
#[repr(C)]
struct RustPoint64 {
    pub x: f64,
    pub y: f64,
}

#[no_mangle]
pub extern "C" fn process_point_f64(p: RustPoint64) -> f64 {
    p.x * p.x + p.y * p.y
}

#[no_mangle]
pub extern "C" fn move_point_f64(mut p: RustPoint64, dx: f64, dy: f64) -> RustPoint64 {
    p.x += dx;
    p.y += dy;
    p
}
"""

println("--- Passing Generic Struct (Point{Float64}) ---")
p = Point{Float64}(3.0, 4.0)

# Pass Julia struct to Rust.
# @rust will pass 'p' as its memory representation.
# Since Point{Float64} is bit-compatible with RustPoint64, it works.
result = @rust process_point_f64(p)::Float64
println("Result: ", result)
@test result == 25.0

# Return by value works similarly, though @rust needs context to know
# how to interpret the bytes returned into a Julia Point.
# ccall handles this if we specify the return type.
new_p = @rust move_point_f64(p, 1.0, 2.0)::Point{Float64}
println("Moved: ", new_p)
@test new_p.x == 4.0
@test new_p.y == 6.0
