using SampleCrate
using Test

@testset "SampleCrate.jl" begin
    @testset "Functions" begin
        @test add(Int32(2), Int32(3)) == 5
        @test add(Int32(-1), Int32(1)) == 0
        @test multiply(2.0, 3.0) == 6.0
        @test fibonacci(UInt32(0)) == 0
        @test fibonacci(UInt32(1)) == 1
        @test fibonacci(UInt32(10)) == 55
        @test is_prime(UInt32(7))
        @test !is_prime(UInt32(8))
    end

    @testset "Strings" begin
        @test shout("hello") == "HELLO"
        @test join_repeat("a", "b", "-", UInt32(2)) == "a-b-a-b"
        @test char_count("日本語") == 3
        @test crate_greeting() == "hello from sample_crate"
        @test identity_str("same") == "same"
    end

    @testset "Result -> value or exception" begin
        @test safe_divide(10, 4) == 2.5
        @test_throws DivideError safe_divide(1.0, 0.0)
        @test parse_positive(7) === UInt32(7)
        @test_throws DomainError parse_positive(-3)
        @test parse_int(" 42 ") === Int32(42)
        @test_throws ArgumentError parse_int("forty-two")
        # The raw Result is still there for callers that want it.
        r = SampleCrate.Bindings.safe_divide(1.0, 0.0)
        @test r isa SampleCrate.RustResult{Float64, Int32}
        @test SampleCrate.is_err(r)
    end

    @testset "Option -> value or nothing" begin
        @test safe_sqrt(16) == 4.0
        @test safe_sqrt(-1) === nothing
        @test find_positive(-1, 5) === Int32(5)
        @test find_positive(-1, -5) === nothing
        @test first_char("日本") == '日'
        @test first_char("") === nothing
    end

    @testset "Point" begin
        p = Point(3.0, 4.0)
        @test p isa Point
        @test p.x == 3.0 && p.y == 4.0
        @test distance_from_origin(p) == 5.0
        @test distance_to(p, 0.0, 0.0) == 5.0
        @test distance(p, Point(0.0, 0.0)) == 5.0
        translate(p, 1.0, -1.0)
        @test (p.x, p.y) == (4.0, 3.0)
        p.x = 0.0
        @test p.x == 0.0
    end

    @testset "Counter" begin
        c = Counter(Int32(10))
        increment(c)
        increment(c)
        decrement(c)
        @test value(c) == 11
        # `Counter::add` shares its name with the free function `add`; the
        # generated module dispatches on the first argument.
        add(c, Int32(5))
        @test c.value == 16
        @test SampleCrate.Bindings.get(c) == 16
        @test reset!(c) === c
        @test value(c) == 0
    end

    @testset "Labeler" begin
        l = Labeler(UInt32(0))
        @test label(l, "x") == "x#1"
        @test label(l, "y") == "y#2"
        @test l.count == 2
        @test byte_len(l, "日本") == 6
        @test kind(l) == "labeler"
        @test echo(l, "back") == "back"
        # `Labeler::shout` is a static method (no `self`): it dispatches on the
        # type, and the crate's free `fn shout` keeps the bare name (#323).
        @test shout(Labeler, "hi") == "HI"
        @test shout("hi") == "HI"
    end

    @testset "Rectangle" begin
        r = Rectangle(2.0, 3.0)
        @test area(r) == 6.0
        @test perimeter(r) == 10.0
        @test !is_square(r)
        scale(r, 2.0)
        @test (r.width, r.height) == (4.0, 6.0)
        @test is_square(Rectangle(1.0, 1.0))
    end
end
