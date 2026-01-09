# Test cases converted from examples/julia_to_rust_generic.jl
using LastCall
using Test

@testset "Julia to Rust Generic" begin
    if !check_rustc_available()
        @warn "rustc not found, skipping julia_to_rust_generic tests"
        return
    end

    # Define Julia struct
    struct Point{T}
        x::T
        y::T
    end

    @testset "Passing Generic Struct" begin
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

        p = Point{Float64}(3.0, 4.0)
        result = @rust process_point_f64(p)::Float64
        @test result == 25.0

        new_p = @rust move_point_f64(p, 1.0, 2.0)::Point{Float64}
        @test new_p.x == 4.0
        @test new_p.y == 6.0
    end
end
