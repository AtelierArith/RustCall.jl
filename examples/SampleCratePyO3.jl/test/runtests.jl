using SampleCratePyO3
using Test

# The same checks as ../../sample_crate_pyo3/main.py makes on the Python side:
# one Rust definition, the same names and results in both languages.
@testset "SampleCratePyO3.jl" begin
    @testset "Functions (#[julia] + #[pyfunction] on one item)" begin
        @test add(Int32(2), Int32(3)) == 5
        @test fibonacci(UInt32(10)) == 55
        @test fibonacci(UInt32(20)) == 6765
        @test shout("hello") == "HELLO"
        @test shout_twice("hi") == "HI HI"
    end

    @testset "Point (#[julia] + #[pyclass] on one struct)" begin
        p = Point(3.0, 4.0)
        @test p isa Point
        @test (p.x, p.y) == (3.0, 4.0)
        @test distance_from_origin(p) == 5.0
        @test norm(p) == 5.0

        translate(p, 1.0, 2.0)          # mutates in place
        @test (p.x, p.y) == (4.0, 6.0)

        q = scaled(p, 2.0)              # returns a new Point
        @test q isa Point
        @test (q.x, q.y) == (8.0, 12.0)
        @test (p.x, p.y) == (4.0, 6.0)  # the original is untouched

        p.x = 10.0                      # setters
        p.y = 20.0
        @test (p.x, p.y) == (10.0, 20.0)
    end
end
