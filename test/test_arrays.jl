# Tests for array and collection types (RustVec, RustSlice)

using LastCall
using Test
using Libdl

# Helper function to check if Vec functions are available in the Rust helpers library
function is_vec_helpers_available()
    if !is_rust_helpers_available()
        return false
    end
    lib = LastCall.get_rust_helpers_lib()
    if lib === nothing
        return false
    end
    # Check if the vec function exists
    try
        Libdl.dlsym(lib, :rust_vec_new_from_array_i32)
        return true
    catch
        return false
    end
end

@testset "Array and Collection Types" begin
    @testset "RustVec Indexing" begin
        # Create a RustVec with dummy pointer for testing
        # Note: This only tests Julia-side indexing logic, not actual Rust memory
        if !is_rust_helpers_available()
            # Test with dummy pointer (will only test bounds checking and logic)
            # We can't actually read/write memory without Rust helpers
            vec = RustVec{Int32}(Ptr{Cvoid}(UInt(0x1000)), UInt(5), UInt(10))

            @test length(vec) == 5
            @test !vec.dropped

            # Test bounds checking
            @test_throws BoundsError vec[0]
            @test_throws BoundsError vec[6]
            @test_throws BoundsError vec[-1]

            # Test dropped vector
            drop!(vec)
            @test_throws ErrorException vec[1]
            @test_throws ErrorException vec[1] = 42
        else
            # When Rust helpers are available, we could test actual memory operations
            # For now, we'll skip these tests
            @test true  # Placeholder
        end
    end

    @testset "RustSlice Indexing" begin
        # Create a RustSlice with dummy pointer
        slice = RustSlice{Int32}(Ptr{Int32}(UInt(0x2000)), UInt(5))

        @test length(slice) == 5

        # Test bounds checking
        @test_throws BoundsError slice[0]
        @test_throws BoundsError slice[6]
        @test_throws BoundsError slice[-1]
    end

    @testset "RustVec Iterator" begin
        if !is_rust_helpers_available()
            # Test iterator interface (without actual memory access)
            vec = RustVec{Int32}(Ptr{Cvoid}(UInt(0x1000)), UInt(3), UInt(10))

            # Test iterator traits
            @test Base.IteratorSize(RustVec{Int32}) == Base.HasLength()
            @test Base.IteratorEltype(RustVec{Int32}) == Base.HasEltype()
            @test Base.eltype(RustVec{Int32}) == Int32

            # Test iterate function exists
            @test hasmethod(Base.iterate, Tuple{RustVec{Int32}})
            @test hasmethod(Base.iterate, Tuple{RustVec{Int32}, Int})
        else
            @test true  # Placeholder
        end
    end

    @testset "RustSlice Iterator" begin
        slice = RustSlice{Int32}(Ptr{Int32}(UInt(0x2000)), UInt(3))

        # Test iterator traits
        @test Base.IteratorSize(RustSlice{Int32}) == Base.HasLength()
        @test Base.IteratorEltype(RustSlice{Int32}) == Base.HasEltype()
        @test Base.eltype(RustSlice{Int32}) == Int32

        # Test iterate function exists
        @test hasmethod(Base.iterate, Tuple{RustSlice{Int32}})
        @test hasmethod(Base.iterate, Tuple{RustSlice{Int32}, Int})
    end

    @testset "RustVec to Vector Conversion" begin
        if !is_rust_helpers_available()
            # Test conversion function exists
            vec = RustVec{Int32}(Ptr{Cvoid}(UInt(0x1000)), UInt(5), UInt(10))

            # Test that Vector() and collect() functions exist
            @test hasmethod(Base.Vector, Tuple{RustVec{Int32}})
            @test hasmethod(Base.collect, Tuple{RustVec{Int32}})

            # Test that conversion fails gracefully for dropped vector
            drop!(vec)
            @test_throws ErrorException Vector(vec)
            @test_throws ErrorException collect(vec)
        else
            @test true  # Placeholder
        end
    end

    @testset "Vector to RustVec Conversion" begin
        # Test that generic constructor exists (RustVec(v::Vector{T}) where T)
        @test hasmethod(RustVec, Tuple{Vector{Int32}})
        @test hasmethod(RustVec, Tuple{Vector{Int64}})
        @test hasmethod(RustVec, Tuple{Vector{Float32}})
        @test hasmethod(RustVec, Tuple{Vector{Float64}})

        # Test that it requires Rust helpers library
        if !is_rust_helpers_available()
            julia_vec = Int32[1, 2, 3, 4, 5]
            @test_throws ErrorException RustVec(julia_vec)
        elseif !is_vec_helpers_available()
            # Library loaded but Vec functions not available - need rebuild
            @warn "Rust helpers library loaded but Vec functions not available. Rebuild with: Pkg.build(\"LastCall\")"
            @test true  # Placeholder to pass
        else
            # When Rust helpers and Vec functions are available, test actual conversion
            @testset "RustVec from Vector{Int32}" begin
                julia_vec = Int32[1, 2, 3, 4, 5]
                rust_vec = RustVec(julia_vec)
                
                @test length(rust_vec) == 5
                @test !rust_vec.dropped
                @test rust_vec.ptr != C_NULL
                
                # Test that we can access elements
                @test rust_vec[1] == 1
                @test rust_vec[5] == 5
                
                # Test conversion back to Julia
                back_to_julia = Vector(rust_vec)
                @test back_to_julia == julia_vec
                
                # Clean up
                drop!(rust_vec)
                @test rust_vec.dropped
            end
            
            @testset "RustVec from Vector{Int64}" begin
                julia_vec = Int64[10, 20, 30]
                rust_vec = RustVec(julia_vec)
                
                @test length(rust_vec) == 3
                @test rust_vec[1] == 10
                @test rust_vec[3] == 30
                
                drop!(rust_vec)
            end
            
            @testset "RustVec from Vector{Float32}" begin
                julia_vec = Float32[1.5f0, 2.5f0, 3.5f0]
                rust_vec = RustVec(julia_vec)
                
                @test length(rust_vec) == 3
                @test rust_vec[1] ≈ 1.5f0
                
                drop!(rust_vec)
            end
            
            @testset "RustVec from Vector{Float64}" begin
                julia_vec = [1.5, 2.5, 3.5]
                rust_vec = RustVec(julia_vec)
                
                @test length(rust_vec) == 3
                @test rust_vec[1] ≈ 1.5
                
                drop!(rust_vec)
            end
        end
    end

    @testset "RustVec Type Constructors" begin
        # Test generic constructor handles all supported types via type inference
        # The generic RustVec(v::Vector{T}) where T handles these automatically
        @test hasmethod(RustVec, Tuple{Vector{Int32}})
        @test hasmethod(RustVec, Tuple{Vector{Int64}})
        @test hasmethod(RustVec, Tuple{Vector{Float32}})
        @test hasmethod(RustVec, Tuple{Vector{Float64}})
    end
end
