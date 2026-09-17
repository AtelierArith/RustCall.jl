using RustCrateMacroPyO3Only
using RustCall: RustResult, is_ok, is_err, unwrap
using Test
import PythonCall

# Every binding below reaches a crate that has no RustCall attribute anywhere
# and no `pub` on any item, through the module `@rust_crate` generated at this
# package's top level (#424 for the host path, #339 for the macro in a
# precompiled package).
@testset "RustCrateMacroPyO3Only.jl" begin
    @testset "the bindings are a submodule of this package" begin
        B = RustCrateMacroPyO3Only.Bindings
        @test B isa Module
        @test parentmodule(B) === RustCrateMacroPyO3Only
        @test nameof(B) === :Bindings
        # The module was compiled into the package's precompile image, not
        # regenerated on `using`; the crate is built and imported lazily, on the
        # first call (`_pyo3_module()`).
        @test B._PYO3_CRATE_PATH == joinpath(pkgdir(RustCrateMacroPyO3Only), "deps", "macro_pyo3_only")
    end

    @testset "#[pyfunction]" begin
        @test scale(Int32(3), Int32(4)) == 12
        @test scale(Int32(-2), Int32(5)) == -10
        @test join_words("hello", "world") == "hello world"
        @test join_words("  a  ", "  b  ") == "a b"
    end

    @testset "PyResult<i32> -> RustResult{Int32, String}, real message" begin
        ok = checked_div(Int32(7), Int32(2))
        @test ok isa RustResult{Int32, String}
        @test is_ok(ok)
        @test unwrap(ok) == 3

        bad = checked_div(Int32(1), Int32(0))
        @test is_err(bad)
        # The host path has an interpreter, so this is the exception's own
        # message, not the C-ABI path's fixed opaque sentence.
        @test occursin("division by zero", bad.value)

        # The other way an i32 division fails: the quotient of
        # `typemin(Int32) ÷ -1` does not fit. Rust's `/` panics on it even in
        # release builds, so the crate uses `checked_div` and this is an `Err`
        # like the zero divisor, not a panic.
        overflow = checked_div(typemin(Int32), Int32(-1))
        @test is_err(overflow)

        # The Julia layer: a value, or a DivideError.
        @test safe_div(7, 2) == 3
        @test safe_div(7, 2) isa Int32
        @test_throws DivideError safe_div(1, 0)
        @test_throws DivideError safe_div(typemin(Int32), -1)
    end

    @testset "#[pyclass(get_all, set_all)] Counter" begin
        # `#[new]` is the constructor.
        c = Counter(Int64(10), Int64(2))
        @test c isa Counter

        # `#[staticmethod] zeroed` is a Julia function.
        z = zeroed()
        @test z isa Counter
        @test (z.value, z.step) == (0, 1)
        @test current(z) == 0

        # Fields, through the Python object's descriptors.
        @test (c.value, c.step) == (10, 2)
        @test propertynames(c) == (:value, :step)
        c.value = 20
        @test c.value == 20
        c.step = 3                      # converted to the field's i64 by pyo3
        @test c.step == 3
        @test_throws PythonCall.PyException c.missing_field
        c.value, c.step = 10, 2

        # `&self` and `&mut self` methods; the handle is the same Python object.
        @test current(c) == 10
        @test bump(c) == 12             # mutates in place
        @test current(c) == 12

        # A `String`-returning method.
        @test describe(c) == "12 (+2)"

        # A `PyResult` method, both ways.
        good = advance(c, Int64(3))
        @test good isa RustResult{Int64, String}
        @test is_ok(good) && unwrap(good) == 18
        bad = advance(c, Int64(-1))
        @test is_err(bad)
        @test occursin("times must not be negative", bad.value)
        @test current(c) == 18          # refused, so unchanged
    end
end
