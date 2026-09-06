# Test cases converted from examples/julia_to_rust_struct.jl
using RustCall
using Test

@testset "Julia to Rust Struct" begin
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping julia_to_rust_struct tests"
        return
    end

    # Define Julia struct
    struct Point
        x::Float64
        y::Float64
    end

    # Passing an aggregate by value is opt-in since #245: `#[repr(C)]` on the
    # Rust side below is what makes the field order a contract, and this is
    # where that claim is recorded. Without it the call raises rather than
    # assuming the two layouts agree. `Point` is concrete, which is the only
    # thing `register_ffi_struct` accepts.
    RustCall.register_ffi_struct(Point)

    @testset "Passing Struct by Value" begin
        rust"""
        #[repr(C)]
        struct Point {
            pub x: f64,
            pub y: f64,
        }

        #[no_mangle]
        pub extern "C" fn process_point(p: Point) -> f64 {
            p.x * p.x + p.y * p.y
        }

        #[no_mangle]
        pub extern "C" fn move_point(mut p: Point, dx: f64, dy: f64) -> Point {
            p.x += dx;
            p.y += dy;
            p
        }
        """

        p = Point(3.0, 4.0)
        dist_sq = @rust process_point(p)::Float64
        @test dist_sq == 25.0

        new_p = @rust move_point(p, 1.0, 2.0)::Point
        @test new_p.x == 4.0
        @test new_p.y == 6.0
        @test new_p isa Point
    end
end
