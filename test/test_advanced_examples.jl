# Test cases converted from examples/advanced_examples.jl
using RustCall
using Test

@testset "Advanced Examples" begin
    if !check_rustc_available()
        @warn "rustc not found, skipping advanced examples tests"
        return
    end

    @testset "Generic Functions" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn identity_i32(x: i32) -> i32 {
            x
        }

        #[no_mangle]
        pub extern "C" fn identity_i64(x: i64) -> i64 {
            x
        }

        #[no_mangle]
        pub extern "C" fn identity_f64(x: f64) -> f64 {
            x
        }
        """

        @test @rust identity_i32(Int32(42)) == 42
        @test @rust identity_i64(Int64(123456789)) == 123456789
        @test @rust identity_f64(3.14159) ≈ 3.14159
    end

    @testset "Array Operations" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn sum_array(ptr: *const i32, len: usize) -> i32 {
            if ptr.is_null() || len == 0 {
                return 0;
            }
            let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
            slice.iter().sum()
        }

        #[no_mangle]
        pub extern "C" fn max_array(ptr: *const i32, len: usize) -> i32 {
            if ptr.is_null() || len == 0 {
                return 0;
            }
            let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
            *slice.iter().max().unwrap_or(&0)
        }
        """

        arr = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        arr_int32 = Int32.(arr)
        ptr = pointer(arr_int32)
        len = length(arr_int32)

        sum_result = @rust sum_array(ptr, len)
        max_result = @rust max_array(ptr, len)

        @test sum_result == 55
        @test max_result == 10
    end

    @testset "LLVM Optimization" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn optimized_compute(x: f64) -> f64 {
            let mut result = 0.0;
            for i in 0..1000 {
                result += x * (i as f64);
            }
            result
        }
        """

        result = @rust optimized_compute(2.0)
        expected = 2.0 * sum(0:999)
        @test result ≈ expected
    end

    @testset "Error Handling" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn checked_divide(a: i32, b: i32) -> i32 {
            if b == 0 {
                -1  // Error code
            } else {
                a / b
            }
        }
        """

        @test @rust checked_divide(Int32(10), Int32(2)) == 5
        @test @rust checked_divide(Int32(10), Int32(0)) == -1
    end

    @testset "Complex Calculations" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn fibonacci(n: i32) -> i32 {
            if n <= 1 {
                n
            } else {
                let mut a = 0i32;
                let mut b = 1i32;
                for _ in 2..=n {
                    let c = a + b;
                    a = b;
                    b = c;
                }
                b
            }
        }

        #[no_mangle]
        pub extern "C" fn factorial(n: i32) -> i64 {
            if n <= 1 {
                1
            } else {
                let mut result = 1i64;
                for i in 2..=n {
                    result *= i as i64;
                }
                result
            }
        }
        """

        @test @rust fibonacci(Int32(10)) == 55
        @test @rust fibonacci(Int32(20)) == 6765
        @test @rust factorial(Int32(5)) == 120
        @test @rust factorial(Int32(10)) == 3628800
    end

    @testset "String Processing" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn string_length(s: *const u8) -> usize {
            // Simplified - returns 0
            0
        }
        """

        text = "Hello, RustCall.jl!"
        result = @rust string_length(text)::UInt
        @test result == 0  # Simplified implementation
    end

    @testset "Multiple Functions in One Library" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn lib1_function(x: i32) -> i32 {
            x * 2
        }

        #[no_mangle]
        pub extern "C" fn lib1_square(x: i32) -> i32 {
            x * x
        }
        """

        @test @rust lib1_function(Int32(5)) == 10
        @test @rust lib1_square(Int32(5)) == 25
    end

    @testset "Performance Optimization" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn fast_multiply(a: i32, b: i32) -> i32 {
            a * b
        }
        """

        @test @rust fast_multiply(Int32(7), Int32(8)) == 56
    end

    @testset "Cache Usage" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn cached_function(x: i32) -> i32 {
            x + 100
        }
        """

        @test @rust cached_function(Int32(42)) == 142
    end

    @testset "Integration with Julia Code" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn compute_polynomial(x: f64, coeffs: *const f64, len: usize) -> f64 {
            if coeffs.is_null() || len == 0 {
                return 0.0;
            }
            let slice = unsafe { std::slice::from_raw_parts(coeffs, len) };
            let mut result = 0.0;
            let mut power = 1.0;
            for &coeff in slice {
                result += coeff * power;
                power *= x;
            }
            result
        }
        """

        coefficients = [1.0, 2.0, 3.0, 4.0]  # 1 + 2x + 3x² + 4x³
        coeffs_f64 = Float64.(coefficients)
        ptr = pointer(coeffs_f64)
        len = length(coeffs_f64)

        x = 2.0
        result = @rust compute_polynomial(x, ptr, len)
        expected = 1 + 2*2 + 3*4 + 4*8  # 1 + 4 + 12 + 32 = 49
        @test result ≈ expected
    end
end
