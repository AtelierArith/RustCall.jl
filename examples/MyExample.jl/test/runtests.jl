using MyExample
using Test

@testset "MyExample.jl" begin
    @testset "Basic Numerical Computations" begin
        @test add_numbers(Int32(10), Int32(20)) == 30
        @test add_numbers(Int32(-5), Int32(5)) == 0
        
        @test multiply_numbers(3.0, 4.0) ≈ 12.0
        @test multiply_numbers(2.5, 2.0) ≈ 5.0
        
        @test fibonacci(UInt32(0)) == 0
        @test fibonacci(UInt32(1)) == 1
        @test fibonacci(UInt32(2)) == 1
        @test fibonacci(UInt32(10)) == 55
        @test fibonacci(UInt32(20)) == 6765
    end

    @testset "String Processing" begin
        @test count_words("hello") == 1
        @test count_words("The quick brown fox") == 4
        @test count_words("") == 0
        @test count_words("  multiple   spaces  ") == 2
        
        @test reverse_string("hello") == "olleh"
        @test reverse_string("") == ""
        @test reverse_string("a") == "a"
        @test reverse_string("racecar") == "racecar"  # Palindrome
        @test reverse_string("世界") == "界世"
    end

    @testset "Array Operations" begin
        @test sum_array(Int32[]) == 0
        @test sum_array([Int32(1), Int32(2), Int32(3)]) == 6
        @test sum_array([Int32(10), Int32(20), Int32(30)]) == 60
        
        @test max_in_array(Int32[]) == 0
        @test max_in_array([Int32(1), Int32(5), Int32(3)]) == 5
        @test max_in_array([Int32(10), Int32(20), Int32(30)]) == 30
        @test max_in_array([Int32(-5), Int32(-1), Int32(-10)]) == -1
    end
end
