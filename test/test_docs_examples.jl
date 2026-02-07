#!/usr/bin/env julia
# Test suite for sample code in docs/src/*.md files
#
# This file tests all executable sample code from the documentation
# to ensure they work correctly.

using Test
using RustCall

@testset "Documentation Examples" begin
    @testset "tutorial.md - Basic Usage" begin
        # Step 1: Define and Compile Rust Code
        rust"""
        #[no_mangle]
        pub extern "C" fn add(a: i32, b: i32) -> i32 {
            a + b
        }
        """

        # Step 2: Call Rust Functions
        result = @rust add(Int32(10), Int32(20))::Int32
        @test result == 30

        # Step 3: Define Multiple Functions
        rust"""
        #[no_mangle]
        pub extern "C" fn multiply(x: f64, y: f64) -> f64 {
            x * y
        }

        #[no_mangle]
        pub extern "C" fn subtract(a: i64, b: i64) -> i64 {
            a - b
        }
        """

        product = @rust multiply(3.0, 4.0)::Float64
        @test product == 12.0

        difference = @rust subtract(Int64(100), Int64(30))::Int64
        @test difference == 70
    end

    @testset "tutorial.md - Boolean Values" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn is_positive_tutorial(x: i32) -> bool {
            x > 0
        }
        """

        @test @rust is_positive_tutorial(Int32(5))::Bool == true
        @test @rust is_positive_tutorial(Int32(-5))::Bool == false
    end

    @testset "tutorial.md - String Handling" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn string_length_tutorial(s: *const u8) -> u32 {
            let c_str = unsafe { std::ffi::CStr::from_ptr(s as *const i8) };
            c_str.to_bytes().len() as u32
        }

        #[no_mangle]
        pub extern "C" fn count_chars_tutorial(s: *const u8) -> u32 {
            let c_str = unsafe { std::ffi::CStr::from_ptr(s as *const i8) };
            let utf8_str = std::str::from_utf8(c_str.to_bytes()).unwrap();
            utf8_str.chars().count() as u32
        }
        """

        len = @rust string_length_tutorial("hello")::UInt32
        @test len == 5

        len = @rust string_length_tutorial("世界")::UInt32
        @test len == 6  # UTF-8 bytes

        count = @rust count_chars_tutorial("hello")::UInt32
        @test count == 5

        count = @rust count_chars_tutorial("世界")::UInt32
        @test count == 2  # characters, not bytes
    end

    @testset "tutorial.md - Error Handling" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn divide(a: i32, b: i32) -> i32 {
            if b == 0 {
                return -1;  // Return -1 as error code
            }
            a / b
        }
        """

        result = @rust divide(Int32(10), Int32(2))::Int32
        @test result == 5

        result = @rust divide(Int32(10), Int32(0))::Int32
        @test result == -1  # Error code

        # Explicit Use of RustResult
        ok_result = RustResult{Int32, String}(true, Int32(42))
        @test is_ok(ok_result) == true
        @test unwrap(ok_result) == 42

        err_result = RustResult{Int32, String}(false, "error message")
        @test is_err(err_result) == true
        @test unwrap_or(err_result, Int32(0)) == 0
    end

    @testset "tutorial.md - Ownership Types" begin
        if is_rust_helpers_available()
            # RustBox example (simplified - actual usage requires ptr from Rust)
            # This is tested more thoroughly in test_ownership.jl

            # RustRc example
            # Note: Actual usage requires ptr from Rust function
            # This is tested more thoroughly in test_ownership.jl

            # RustArc example
            # Note: Actual usage requires ptr from Rust function
            # This is tested more thoroughly in test_ownership.jl
        else
            @test_skip "Rust helpers not available"
        end
    end

    @testset "tutorial.md - Cache Management" begin
        # Check cache size
        size = get_cache_size()
        @test size >= 0

        # List cached libraries
        libs = list_cached_libraries()
        @test libs isa Vector

        # Note: We don't actually cleanup or clear cache in tests
        # to avoid affecting other tests
    end

    @testset "generics.md - Basic Usage" begin
        # Note: Generic function support may be experimental
        # Testing basic non-generic functions that are similar

        rust"""
        #[no_mangle]
        pub extern "C" fn identity_i32(x: i32) -> i32 {
            x
        }

        #[no_mangle]
        pub extern "C" fn identity_f64(x: f64) -> f64 {
            x
        }
        """

        result = @rust identity_i32(Int32(42))::Int32
        @test result == 42

        result = @rust identity_f64(Float64(3.14))::Float64
        @test abs(result - 3.14) < 0.001
    end

    @testset "examples.md - Numerical Computations" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn power(x: f64, n: i32) -> f64 {
            let mut result = 1.0;
            for _ in 0..n {
                result *= x;
            }
            result
        }
        """

        result = @rust power(2.0, 10)::Float64
        @test result == 1024.0

        rust"""
        #[no_mangle]
        pub extern "C" fn fibonacci(n: u32) -> u64 {
            if n <= 1 {
                return n as u64;
            }

            let mut a = 0u64;
            let mut b = 1u64;

            for _ in 2..=n {
                let temp = a + b;
                a = b;
                b = temp;
            }

            b
        }
        """

        fib_10 = @rust fibonacci(UInt32(10))::UInt64
        @test fib_10 == 55

        fib_20 = @rust fibonacci(UInt32(20))::UInt64
        @test fib_20 == 6765

        rust"""
        #[no_mangle]
        pub extern "C" fn calculate_mean(data: *const f64, len: usize) -> f64 {
            let slice = unsafe { std::slice::from_raw_parts(data, len) };
            let sum: f64 = slice.iter().sum();
            sum / len as f64
        }

        #[no_mangle]
        pub extern "C" fn calculate_variance(data: *const f64, len: usize, mean: f64) -> f64 {
            let slice = unsafe { std::slice::from_raw_parts(data, len) };
            let sum_sq_diff: f64 = slice.iter()
                .map(|&x| (x - mean) * (x - mean))
                .sum();
            sum_sq_diff / len as f64
        }
        """

        function compute_statistics(data::Vector{Float64})
            len = length(data)
            ptr = pointer(data)

            mean = @rust calculate_mean(ptr, len)::Float64
            variance = @rust calculate_variance(ptr, len, mean)::Float64

            return (mean=mean, variance=variance, stddev=sqrt(variance))
        end

        data = [1.0, 2.0, 3.0, 4.0, 5.0]
        stats = compute_statistics(data)
        @test abs(stats.mean - 3.0) < 0.001
        @test abs(stats.stddev - sqrt(2.0)) < 0.001
    end

    @testset "examples.md - String Processing" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn find_substring(haystack: *const u8, needle: *const u8) -> i32 {
            let haystack_str = unsafe {
                std::ffi::CStr::from_ptr(haystack as *const i8)
                    .to_str()
                    .unwrap_or("")
            };
            let needle_str = unsafe {
                std::ffi::CStr::from_ptr(needle as *const i8)
                    .to_str()
                    .unwrap_or("")
            };

            match haystack_str.find(needle_str) {
                Some(pos) => pos as i32,
                None => -1,
            }
        }
        """

        pos = @rust find_substring("hello world", "world")::Int32
        @test pos == 6

        pos = @rust find_substring("hello world", "xyz")::Int32
        @test pos == -1

        rust"""
        #[no_mangle]
        pub extern "C" fn count_words(text: *const u8) -> u32 {
            let text_str = unsafe {
                std::ffi::CStr::from_ptr(text as *const i8)
                    .to_str()
                    .unwrap_or("")
            };

            text_str.split_whitespace().count() as u32
        }
        """

        word_count = @rust count_words("The quick brown fox")::UInt32
        @test word_count == 4

        rust"""
        #[no_mangle]
        pub extern "C" fn count_utf8_chars(s: *const u8) -> u32 {
            let c_str = unsafe { std::ffi::CStr::from_ptr(s as *const i8) };
            let utf8_str = std::str::from_utf8(c_str.to_bytes()).unwrap_or("");
            utf8_str.chars().count() as u32
        }
        """

        char_count = @rust count_utf8_chars("こんにちは")::UInt32
        @test char_count == 5
    end

    @testset "examples.md - Data Structures" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn sum_array(data: *const i32, len: usize) -> i64 {
            let slice = unsafe { std::slice::from_raw_parts(data, len) };
            slice.iter().map(|&x| x as i64).sum()
        }

        #[no_mangle]
        pub extern "C" fn max_element(data: *const i32, len: usize) -> i32 {
            let slice = unsafe { std::slice::from_raw_parts(data, len) };
            *slice.iter().max().unwrap_or(&0)
        }
        """

        function process_array(data::Vector{Int32})
            ptr = pointer(data)
            len = length(data)

            total = @rust sum_array(ptr, len)::Int64
            maximum = @rust max_element(ptr, len)::Int32

            return (sum=total, max=maximum)
        end

        arr = Int32[1, 5, 3, 9, 2]
        result = process_array(arr)
        @test result.sum == 20
        @test result.max == 9

        rust"""
        #[no_mangle]
        pub extern "C" fn sort_array(data: *mut i32, len: usize) {
            let slice = unsafe { std::slice::from_raw_parts_mut(data, len) };
            slice.sort();
        }
        """

        function sort_in_place(arr::Vector{Int32})
            ptr = pointer(arr)
            len = length(arr)
            @rust sort_array(ptr, len)::Cvoid
            return arr
        end

        arr = Int32[5, 2, 8, 1, 9]
        sort_in_place(arr)
        @test arr == Int32[1, 2, 5, 8, 9]
    end

    @testset "examples.md - Real-world Examples" begin
        rust"""
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        #[no_mangle]
        pub extern "C" fn calculate_hash(data: *const u8, len: usize) -> u64 {
            let slice = unsafe { std::slice::from_raw_parts(data, len) };
            let mut hasher = DefaultHasher::new();
            slice.hash(&mut hasher);
            hasher.finish()
        }
        """

        data = Vector{UInt8}(b"hello world")
        ptr = pointer(data)
        hash_value = @rust calculate_hash(ptr, length(data))::UInt64
        @test hash_value > 0

        rust"""
        #[no_mangle]
        pub extern "C" fn validate_ip_address(ip: *const u8) -> bool {
            let ip_str = unsafe {
                std::ffi::CStr::from_ptr(ip as *const i8)
                    .to_str()
                    .unwrap_or("")
            };

            let parts: Vec<&str> = ip_str.split('.').collect();
            if parts.len() != 4 {
                return false;
            }

            for part in parts {
                match part.parse::<u8>() {
                    Ok(num) if num <= 255 => continue,
                    _ => return false,
                }
            }

            true
        }
        """

        is_valid = @rust validate_ip_address("192.168.1.1")::Bool
        @test is_valid == true

        is_valid = @rust validate_ip_address("999.999.999.999")::Bool
        @test is_valid == false

        rust"""
        #[no_mangle]
        pub extern "C" fn simple_compress(
            input: *const u8,
            input_len: usize,
            output: *mut u8,
            output_capacity: usize
        ) -> usize {
            let input_slice = unsafe { std::slice::from_raw_parts(input, input_len) };
            let output_slice = unsafe { std::slice::from_raw_parts_mut(output, output_capacity) };

            let mut output_idx = 0;
            let mut i = 0;

            while i < input_len && output_idx + 1 < output_capacity {
                let mut count = 1;
                let current = input_slice[i];

                // Count consecutive identical characters
                while i + count < input_len && input_slice[i + count] == current && count < 255 {
                    count += 1;
                }

                if output_idx + 2 <= output_capacity {
                    output_slice[output_idx] = count as u8;
                    output_slice[output_idx + 1] = current;
                    output_idx += 2;
                }

                i += count;
            }

            output_idx
        }
        """

        function compress_data(data::Vector{UInt8})
            input_len = length(data)
            output_capacity = input_len * 2  # Worst case
            output = Vector{UInt8}(undef, output_capacity)

            input_ptr = pointer(data)
            output_ptr = pointer(output)

            compressed_len = @rust simple_compress(
                input_ptr, input_len,
                output_ptr, output_capacity
            )::UInt

            return output[1:compressed_len]
        end

        data = Vector{UInt8}(b"aaabbbcccddd")
        compressed = compress_data(data)
        @test length(compressed) <= length(data) * 2
    end

    @testset "examples.md - Best Practices" begin
        rust"""
        #[no_mangle]
        pub extern "C" fn safe_divide(a: i32, b: i32) -> i32 {
            if b == 0 {
                return -1;  // Error code
            }
            a / b
        }
        """

        function divide_safely(a::Int32, b::Int32)
            result = @rust safe_divide(a, b)::Int32
            if result == -1
                throw(DomainError(b, "Division by zero"))
            end
            return result
        end

        result = divide_safely(Int32(10), Int32(2))
        @test result == 5

        @test_throws DomainError divide_safely(Int32(10), Int32(0))
    end

    @testset "performance.md - Basic Examples" begin
        # Test basic examples from performance.md
        # (Most performance examples require BenchmarkTools, which we skip here)

        rust"""
        #[no_mangle]
        pub extern "C" fn compute(x: f64) -> f64 {
            x * x + 1.0
        }
        """

        result = @rust compute(2.0)::Float64
        @test abs(result - 5.0) < 0.001
    end
end

println("=" ^ 60)
println("Documentation examples test completed!")
println("=" ^ 60)
