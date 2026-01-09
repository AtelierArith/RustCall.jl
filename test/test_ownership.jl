# Tests for ownership types with Rust integration

using LastCall
using Test

@testset "Ownership Types - Rust Integration" begin
    # Check if Rust helpers library is available
    # For now, we'll test the Julia-side implementation
    # Full integration tests require the Rust helpers library to be compiled

    @testset "RustBox Creation" begin
        # Test that RustBox types are defined
        @test RustBox{Int32} <: Any
        @test RustBox{Int64} <: Any
        @test RustBox{Float32} <: Any
        @test RustBox{Float64} <: Any
        @test RustBox{Bool} <: Any
    end

    @testset "RustBox Constructors" begin
        # Test that constructors exist (they may fail without Rust library)
        # We'll just check that the functions are defined
        @test hasmethod(RustBox, Tuple{Int32})
        @test hasmethod(RustBox, Tuple{Int64})
        @test hasmethod(RustBox, Tuple{Float32})
        @test hasmethod(RustBox, Tuple{Float64})
        @test hasmethod(RustBox, Tuple{Bool})
    end

    @testset "RustRc Constructors" begin
        @test hasmethod(RustRc, Tuple{Int32})
        @test hasmethod(RustRc, Tuple{Int64})
    end

    @testset "RustArc Constructors" begin
        @test hasmethod(RustArc, Tuple{Int32})
        @test hasmethod(RustArc, Tuple{Int64})
        @test hasmethod(RustArc, Tuple{Float64})
    end

    # Only run dummy pointer tests if Rust helpers library is NOT available
    # (to avoid crash when drop! tries to free invalid pointer)
    if !is_rust_helpers_available()
        @testset "RustBox State Management (No Library)" begin
            # Create a RustBox with a dummy pointer (for testing without Rust library)
            box = RustBox{Int32}(Ptr{Cvoid}(UInt(0x1000)))

            @test !box.dropped
            @test box.ptr != C_NULL
            @test is_valid(box)

            # Test drop! (will only mark as dropped, no actual Rust call)
            drop!(box)
            @test box.dropped
            @test !is_valid(box)

            # Test is_dropped
            @test is_dropped(box)
        end

        @testset "RustRc State Management (No Library)" begin
            rc = RustRc{Int32}(Ptr{Cvoid}(UInt(0x1000)))

            @test !rc.dropped
            @test rc.ptr != C_NULL
            @test is_valid(rc)

            drop!(rc)
            @test rc.dropped
            @test !is_valid(rc)
        end

        @testset "RustArc State Management (No Library)" begin
            arc = RustArc{Int32}(Ptr{Cvoid}(UInt(0x1000)))

            @test !arc.dropped
            @test arc.ptr != C_NULL
            @test is_valid(arc)

            drop!(arc)
            @test arc.dropped
            @test !is_valid(arc)
        end

        @warn "Rust helpers library not available, skipping full integration tests"
        @warn "To enable these tests, build the library with: using Pkg; Pkg.build(\"LastCall\")"
    else
        # Full integration tests with actual Rust library
        @testset "RustBox Full Integration" begin
            box = RustBox(Int32(42))
            @test is_valid(box)

            # Test that it can be dropped
            drop!(box)
            @test is_dropped(box)
        end

        @testset "RustRc Reference Counting" begin
            rc1 = RustRc(Int32(100))
            @test is_valid(rc1)

            # Clone should increment reference count
            rc2 = clone(rc1)
            @test is_valid(rc2)
            @test rc1.ptr == rc2.ptr  # Should point to same data

            # Dropping one shouldn't invalidate the other
            drop!(rc1)
            @test is_valid(rc2)  # Still valid

            # Drop the last reference
            drop!(rc2)
            @test is_dropped(rc2)
        end

        @testset "RustArc Thread-Safe Reference Counting" begin
            arc1 = RustArc(Int32(200))
            @test is_valid(arc1)

            arc2 = clone(arc1)
            @test is_valid(arc2)
            @test arc1.ptr == arc2.ptr

            drop!(arc1)
            @test is_valid(arc2)

            drop!(arc2)
            @test is_dropped(arc2)
        end
    end
end
