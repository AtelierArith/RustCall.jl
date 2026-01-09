# Test cases converted from examples/julia_to_rust_simple.jl
using LastCall
using Test

@testset "Julia to Rust Simple" begin
    if !check_rustc_available()
        @warn "rustc not found, skipping julia_to_rust_simple tests"
        return
    end

    @testset "Passing Primitives to Generic Rust" begin
        rust"""
        pub fn sum_values<T: std::ops::Add<Output = T>>(a: T, b: T) -> T {
            a + b
        }
        """

        res_f64 = @rust sum_values(10.5, 20.5)::Float64
        @test res_f64 ≈ 31.0

        res_i32 = @rust sum_values(Int32(10), Int32(20))::Int32
        @test res_i32 == 30
    end
end
