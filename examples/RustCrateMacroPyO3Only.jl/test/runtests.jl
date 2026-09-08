using RustCrateMacroPyO3Only
using RustCall: RustResult, RustError, is_ok, is_err, unwrap, PYO3_OPAQUE_ERROR
using Test

# Every binding below reaches a crate that has no RustCall attribute anywhere,
# through the module `@rust_crate` generated at this package's top level
# (#275 Phase 2 for the wrapper, #339 for the macro in a precompiled package).
@testset "RustCrateMacroPyO3Only.jl" begin
    @testset "the bindings are a submodule of this package" begin
        B = RustCrateMacroPyO3Only.Bindings
        @test B isa Module
        @test parentmodule(B) === RustCrateMacroPyO3Only
        @test nameof(B) === :Bindings
        # Loaded from the package's precompile image, not re-generated on
        # `using`: the library the module opened is a copy of the durable path
        # it carries.
        @test isfile(B._LIB_PATH)
    end

    @testset "#[pyfunction]" begin
        @test scale(Int32(3), Int32(4)) == 12
        @test scale(Int32(-2), Int32(5)) == -10
        @test join_words("hello", "world") == "hello world"
        @test join_words("  a  ", "  b  ") == "a b"
    end

    @testset "PyResult<i32> -> RustResult{Int32, String}, opaque error" begin
        ok = checked_div(Int32(7), Int32(2))
        @test ok isa RustResult{Int32, String}
        @test is_ok(ok)
        @test unwrap(ok) == 3

        bad = checked_div(Int32(1), Int32(0))
        @test is_err(bad)
        # The `PyErr` is never rendered (that needs an interpreter): the error
        # payload is RustCall's fixed sentence, not pyo3's message.
        @test bad.value == PYO3_OPAQUE_ERROR
        @test !occursin("division by zero", bad.value)

        # The Julia layer: a value, or a DivideError.
        @test safe_div(7, 2) == 3
        @test safe_div(7, 2) isa Int32
        @test_throws DivideError safe_div(1, 0)
    end

    @testset "#[pyclass(get_all, set_all)] Counter" begin
        # `#[new]` is the constructor.
        c = Counter(Int64(10), Int64(2))
        @test c isa Counter

        # `#[staticmethod] zeroed` is a module-level function, in both forms
        # the generator emits: typed and bare.
        z = zeroed(Counter)
        @test z isa Counter
        @test (z.value, z.step) == (0, 1)
        @test current(zeroed()) == 0

        # Fields, through the generated `rustcall_Counter_get_value` / `_set_value`.
        @test (c.value, c.step) == (10, 2)
        @test propertynames(c) == (:value, :step)
        c.value = 20
        @test c.value == 20
        c.step = 3                      # converted to the field's i64
        @test c.step == 3
        @test_throws ErrorException c.missing_field
        c.value, c.step = 10, 2

        # `&self` and `&mut self` methods.
        @test current(c) == 10
        @test bump(c) == 12             # mutates in place
        @test current(c) == 12

        # A `String`-returning method: the owned buffer comes back as a
        # Julia String.
        @test describe(c) == "12 (+2)"

        # A `PyResult` method, both ways.
        good = advance(c, Int64(3))
        @test good isa RustResult{Int64, String}
        @test is_ok(good) && unwrap(good) == 18
        bad = advance(c, Int64(-1))
        @test is_err(bad)
        @test bad.value == PYO3_OPAQUE_ERROR
        @test current(c) == 18          # refused, so unchanged
    end

    @testset "Counter_free runs the Rust destructor" begin
        c = Counter(Int64(1), Int64(1))
        finalize(c)
        # After `finalize`, the handle is gone and a call is refused rather
        # than handed to Rust.
        @test_throws RustError current(c)
        @test_throws RustError c.value
    end
end
