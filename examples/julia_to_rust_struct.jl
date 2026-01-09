# Example: Passing Julia structs to Rust
using LastCall
using Test

# 1. Define Julia struct
struct Point
    x::Float64
    y::Float64
end

# 2. Define Rust code with compatible struct
rust"""
#[repr(C)]
struct Point {
    pub x: f64,
    pub y: f64,
}

#[no_mangle]
pub extern "C" fn process_point(p: Point) -> f64 {
    println!("Rust received Point {{ x: {}, y: {} }}", p.x, p.y);
    p.x * p.x + p.y * p.y
}

#[no_mangle]
pub extern "C" fn move_point(mut p: Point, dx: f64, dy: f64) -> Point {
    p.x += dx;
    p.y += dy;
    p
}
"""

println("--- Passing Struct by Value ---")
p = Point(3.0, 4.0)

# Pass by value
# Note: Currently @rust might need help with return type inference for custom structs
dist_sq = @rust process_point(p)::Float64
println("Distance squared: ", dist_sq)
@test dist_sq == 25.0

# Return struct by value
new_p = @rust move_point(p, 1.0, 2.0)::Point
println("Moved point: ", new_p)
@test new_p.x == 4.0
@test new_p.y == 6.0
@test new_p isa Point
