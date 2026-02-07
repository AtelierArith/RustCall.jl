# Test cases converted from examples/basic_examples.jl
using RustCall
using Test

@testset "Basic Examples" begin
    if !check_rustc_available()
        @warn "rustc not found, skipping basic examples tests"
        return
    end

    @testset "Simple Function Call" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn add(a: i32, b: i32) -> i32 {
            a + b
        }
        """

        result = @rust add(Int32(10), Int32(20))
        @test result == 30
    end

    @testset "Multiple Functions" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn multiply(a: i32, b: i32) -> i32 {
            a * b
        }

        #[no_mangle]
        pub extern "C" fn subtract(a: i32, b: i32) -> i32 {
            a - b
        }

        #[no_mangle]
        pub extern "C" fn divide(a: f64, b: f64) -> f64 {
            if b != 0.0 {
                a / b
            } else {
                0.0
            }
        }
        """

        @test @rust multiply(Int32(5), Int32(7)) == 35
        @test @rust subtract(Int32(20), Int32(8)) == 12
        @test @rust divide(10.0, 3.0) ≈ 10.0 / 3.0
    end

    @testset "Type Inference" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn square(x: i64) -> i64 {
            x * x
        }
        """

        result1 = @rust square(Int64(5))
        @test result1 == 25

        result2 = @rust square(Int64(10))::Int64
        @test result2 == 100
    end

    @testset "String Arguments" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn greet(name: *const u8) -> i32 {
            // Simple function that returns 0
            0
        }
        """

        result = @rust greet("Julia")::Int32
        @test result == 0
    end

    @testset "Boolean and Void Functions" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn is_even(n: i32) -> bool {
            n % 2 == 0
        }

        #[no_mangle]
        pub extern "C" fn print_hello() {
            // Void function - does nothing
        }
        """

        @test @rust is_even(Int32(4)) == true
        @test @rust is_even(Int32(5)) == false
        @rust print_hello()  # Should not throw
    end

    @testset "Compute Function" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn compute(x: i32, y: i32) -> i32 {
            x * y + 10
        }
        """

        result = @rust compute(Int32(5), Int32(3))
        @test result == 25
    end

    @testset "Error Handling" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn safe_divide(a: f64, b: f64) -> i32 {
            if b == 0.0 {
                1  // Error code
            } else {
                0  // Success code
            }
        }
        """

        error_code = @rust safe_divide(10.0, 0.0)::Int32
        @test error_code == 1

        success_code = @rust safe_divide(10.0, 2.0)::Int32
        @test success_code == 0
    end

    @testset "Compiler Configuration" begin
        compiler = RustCompiler(
            optimization_level=3,
            emit_debug_info=false,
            debug_mode=false
        )

        set_default_compiler(compiler)
        @test get_default_compiler().optimization_level == 3

        version = get_rustc_version()
        @test !isempty(version)
    end

    @testset "Cache Management" begin
        cache_size = get_cache_size()
        @test cache_size >= 0

        cached_libs = list_cached_libraries()
        @test isa(cached_libs, Vector{String})

        # Clean up old cache (older than 30 days) - should not throw
        removed = cleanup_old_cache(30)
        @test removed >= 0
    end

    @testset "Performance Comparison" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn fast_add(a: i32, b: i32) -> i32 {
            a + b
        }
        """

        function julia_add(a::Int32, b::Int32)::Int32
            return a + b
        end

        # Test that both work correctly
        @test julia_add(Int32(1), Int32(2)) == 3
        @test @rust fast_add(Int32(1), Int32(2)) == 3
    end
end
