using SampleCratePyO3Only
using RustCall: RustResult, RustError, is_ok, is_err, unwrap, PYO3_OPAQUE_ERROR
using Test

# Every binding below reaches a crate that has no RustCall attribute anywhere:
# the module under test is the generated wrapper's binding (#275 Phase 2).
@testset "SampleCratePyO3Only.jl" begin
    @testset "#[pyfunction]" begin
        @test add(Int32(2), Int32(3)) == 5
        @test add(Int32(-1), Int32(1)) == 0
        @test shout("hello") == "HELLO!"
        @test shout("") == "!"
    end

    @testset "PyResult<i32> -> RustResult{Int32, String}, opaque error" begin
        ok = SampleCratePyO3Only.Bindings.parse("42")
        @test ok isa RustResult{Int32, String}
        @test is_ok(ok)
        @test unwrap(ok) == 42
        @test SampleCratePyO3Only.Bindings.parse(" -7 ").value == -7

        bad = SampleCratePyO3Only.Bindings.parse("not a number")
        @test is_err(bad)
        # The `PyErr` is never rendered (that needs an interpreter): the error
        # payload is RustCall's fixed sentence, not pyo3's message.
        @test bad.value == PYO3_OPAQUE_ERROR
        @test !occursin("invalid digit", bad.value)

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

        # `#[staticmethod] origin` is a module-level function, in both forms
        # the generator emits: typed and bare.
        o = origin(Point)
        @test o isa Point
        @test (o.x, o.y) == (0.0, 0.0)
        @test norm(origin()) == 0.0

        # Fields, through the generated `rustcall_Point_get_x` / `_set_x`.
        @test (p.x, p.y) == (3.0, 4.0)
        @test propertynames(p) == (:x, :y)
        p.x = 6.0
        @test p.x == 6.0
        p.y = 8                        # converted to the field's f64
        @test p.y == 8.0
        @test_throws ErrorException p.z
        p.x, p.y = 3.0, 4.0

        # `&self` and `&mut self` methods.
        @test norm(p) == 5.0
        translate(p, 1.0, 2.0)          # mutates in place
        @test (p.x, p.y) == (4.0, 6.0)
        translate(p, -1.0, -2.0)

        # A `String`-returning method: the owned buffer comes back as a
        # Julia String.
        @test label(p) == "(3, 4)"

        # A `PyResult` method, both ways.
        good = scaled(p, 2.0)
        @test good isa RustResult{Float64, String}
        @test is_ok(good) && unwrap(good) == 10.0
        bad = scaled(p, Inf)
        @test is_err(bad)
        @test bad.value == PYO3_OPAQUE_ERROR

        # The Julia-side convenience.
        @test distance(p, origin()) == 5.0
        @test distance(Point(1.0, 1.0), Point(4.0, 5.0)) == 5.0
    end

    @testset "Point_free runs the Rust destructor" begin
        p = Point(1.0, 2.0)
        finalize(p)
        # After `finalize`, the handle is gone and a call is refused rather
        # than handed to Rust.
        @test_throws RustError norm(p)
        @test_throws RustError p.x
    end
end
