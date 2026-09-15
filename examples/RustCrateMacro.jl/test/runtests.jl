using RustCrateMacro
using RustCall
using RustCall: RustResult
using Test

# The package binds a `#[julia]` crate with `@rust_crate` (during
# precompilation) and compiles an inline `rust"""` block beside it. Every
# binding below therefore reaches one of two independent libraries; the tests
# pin that both are live and that a shared name resolves per module (#250).
@testset "RustCrateMacro.jl" begin
    @testset "the @rust_crate bindings are a submodule" begin
        B = RustCrateMacro.Bindings
        @test B isa Module
        @test parentmodule(B) === RustCrateMacro
        @test nameof(B) === :Bindings
        # `@rust_crate` generated the module at precompile time; at load time
        # the module opens the cached library, it does not rebuild the crate.
        @test isfile(B._LIB_PATH)
    end

    @testset "#[julia] functions from the crate" begin
        @test add(Int32(2), Int32(3)) == 5
        @test add(Int32(-1), Int32(1)) == 0
        @test multiply(2.0, 3.0) == 6.0
        @test shout("hello") == "HELLO"
        @test join_repeat("a", "b", "-", UInt32(2)) == "a-b-a-b"
    end

    @testset "Result / Option from the crate" begin
        @test safe_divide(10, 4) == 2.5
        @test_throws DivideError safe_divide(1.0, 0.0)
        @test safe_sqrt(16) == 4.0
        @test safe_sqrt(-1) === nothing

        # The raw values stay reachable through the generated module.
        r = RustCrateMacro.Bindings.safe_divide(1.0, 0.0)
        @test r isa RustResult{Float64, Int32}
        @test RustCall.is_err(r)
    end

    @testset "Point from the crate" begin
        p = Point(3.0, 4.0)
        @test p isa Point
        @test p.x == 3.0 && p.y == 4.0
        @test norm(p) == 5.0
        translate(p, 1.0, -1.0)
        @test (p.x, p.y) == (4.0, 3.0)
    end

    @testset "inline rust\"\"\" block" begin
        @test inline_hypot(3.0, 4.0) == 5.0
        @test inline_hypot(5.0, 12.0) == 13.0
        @test inline_join("a", "b") == "a-b"
        @test inline_join("left", "right") == "left-right"
    end

    @testset "the two libraries compose" begin
        # `inline_norm` takes a `Point` built by the `@rust_crate` bindings and
        # computes its length in the inline library.
        @test inline_norm(Point(3.0, 4.0)) == 5.0
        @test inline_norm(Point(0.0, 0.0)) == 0.0
        # Both stay callable, interleaved, in either order.
        @test add(Int32(1), Int32(2)) == 3
        @test inline_hypot(6.0, 8.0) == 10.0
        @test shout("hi") == "HI"
        @test inline_join("hi", "there") == "hi-there"
    end

    @testset "a name shared by two libraries resolves per module" begin
        # The crate's `add` is `a + b`. This scratch module's inline `add` is
        # `(a + b) * 1000`; each reaches its own library, and neither captures
        # the other regardless of call order.
        inline_mod = Module(:RustCrateMacroInlineCoexist)
        Core.eval(inline_mod, :(using RustCall))
        Core.eval(inline_mod, quote
            rust"""
            #[julia]
            fn add(a: i32, b: i32) -> i32 { (a + b) * 1000 }
            """
        end)
        @test Core.eval(inline_mod, :(add(Int32(2), Int32(3)))) == Int32(5000)
        @test add(Int32(2), Int32(3)) == Int32(5)
        @test RustCrateMacro.add(Int32(2), Int32(3)) == Int32(5)
        @test Core.eval(inline_mod, :(add(Int32(1), Int32(4)))) == Int32(5000)
    end
end
