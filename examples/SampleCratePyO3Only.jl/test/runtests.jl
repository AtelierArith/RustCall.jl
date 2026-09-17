using SampleCratePyO3Only
using RustCall: RustResult, is_ok, is_err, unwrap
using Test
import PythonCall

# Every binding below reaches a crate that has no RustCall attribute anywhere
# and no `pub` on any item: the module under test is the host path's typed
# surface over the crate imported as a Python extension (#424).
@testset "SampleCratePyO3Only.jl" begin
    @testset "the typed bindings are a submodule of this package" begin
        @test SampleCratePyO3Only.Bindings isa Module
        @test parentmodule(SampleCratePyO3Only.Bindings) === SampleCratePyO3Only
        @test nameof(SampleCratePyO3Only.Bindings) === :Bindings
    end

    @testset "#[pyfunction]" begin
        @test add(Int32(2), Int32(3)) == 5
        @test add(Int32(-1), Int32(1)) == 0
        @test shout("hello") == "HELLO!"
        @test shout("") == "!"
    end

    @testset "PyResult<i32> -> RustResult{Int32, String}, real message" begin
        ok = SampleCratePyO3Only.Bindings.parse("42")
        @test ok isa RustResult{Int32, String}
        @test is_ok(ok)
        @test unwrap(ok) == 42
        @test SampleCratePyO3Only.Bindings.parse(" -7 ").value == -7

        bad = SampleCratePyO3Only.Bindings.parse("not a number")
        @test is_err(bad)
        # The host path has an interpreter, so this is pyo3's own message, not
        # the C-ABI path's fixed opaque sentence.
        @test occursin("invalid digit", bad.value)

        # The Julia layer: a value, or an ArgumentError naming the input.
        @test parse_int("42") == 42
        @test parse_int("42") isa Int32
        @test_throws ArgumentError parse_int("not a number")
        @test_throws ArgumentError parse_int("")
    end

    @testset "#[pyclass(get_all, set_all)] Point" begin
        # `#[new]` is the constructor.
        p = Point(3.0, 4.0)
        @test p isa Point

        # `#[staticmethod] origin` is a Julia function.
        o = origin()
        @test o isa Point
        @test (o.x, o.y) == (0.0, 0.0)
        @test norm(o) == 0.0

        # Fields, through the Python object's descriptors.
        @test (p.x, p.y) == (3.0, 4.0)
        @test propertynames(p) == (:x, :y)
        p.x = 6.0
        @test p.x == 6.0
        p.y = 8                        # converted to the field's f64 by pyo3
        @test p.y == 8.0
        @test_throws PythonCall.PyException p.z
        p.x, p.y = 3.0, 4.0

        # `&self` and `&mut self` methods; the handle is the same Python object.
        @test norm(p) == 5.0
        translate(p, 1.0, 2.0)          # mutates in place
        @test (p.x, p.y) == (4.0, 6.0)
        translate(p, -1.0, -2.0)

        # A `String`-returning method.
        @test label(p) == "(3, 4)"

        # A `PyResult` method, both ways.
        good = scaled(p, 2.0)
        @test good isa RustResult{Float64, String}
        @test is_ok(good) && unwrap(good) == 10.0
        bad = scaled(p, Inf)
        @test is_err(bad)
        @test occursin("factor must be finite", bad.value)

        # The Julia-side convenience.
        @test distance(p, origin()) == 5.0
        @test distance(Point(1.0, 1.0), Point(4.0, 5.0)) == 5.0
    end
end
