# Integration tests for external crate support (ndarray, etc.)
# Phase 3: These tests require network access to download crates on first run

using LastCall
using Test

# Heavy ndarray tests (they take more time) - run by default unless disabled
const RUN_HEAVY_INTEGRATION_TESTS = get(ENV, "LASTCALL_RUN_HEAVY_INTEGRATION_TESTS", "true") == "true"

# Lightweight integration tests with small crates (libc, etc.) - run by default
@testset "External Crate Integration" begin

    @testset "Simple crate usage (libc)" begin
        # Test with libc (lightweight, commonly available)
        rust"""
        //! ```cargo
        //! [dependencies]
        //! libc = "0.2"
        //! ```

        use libc::c_int;

        #[no_mangle]
        pub extern "C" fn test_libc_integration(x: c_int) -> c_int {
            x * 2
        }
        """

        result = @rust test_libc_integration(Int32(21))::Int32
        @test result == 42
    end

    @testset "cargo-deps format" begin
        # Test the single-line cargo-deps format
        rust"""
        // cargo-deps: libc="0.2"

        use libc::c_int;

        #[no_mangle]
        pub extern "C" fn test_cargo_deps_format(x: c_int) -> c_int {
            x + 100
        }
        """

        result = @rust test_cargo_deps_format(Int32(42))::Int32
        @test result == 142
    end

    @testset "Caching works" begin
        # First compilation (or cache hit)
        rust"""
        //! ```cargo
        //! [dependencies]
        //! libc = "0.2"
        //! ```

        #[no_mangle]
        pub extern "C" fn cache_test_func() -> i32 {
            123
        }
        """

        result1 = @rust cache_test_func()::Int32

        # Second compilation should use cache (same code)
        rust"""
        //! ```cargo
        //! [dependencies]
        //! libc = "0.2"
        //! ```

        #[no_mangle]
        pub extern "C" fn cache_test_func() -> i32 {
            123
        }
        """

        result2 = @rust cache_test_func()::Int32

        @test result1 == result2 == 123
    end
end

# Heavy integration tests (ndarray, bitflags, etc.) - optional
if RUN_HEAVY_INTEGRATION_TESTS
    @testset "Heavy Crate Integration" begin
        @testset "Crate with features (bitflags)" begin
            rust"""
            //! ```cargo
            //! [dependencies]
            //! bitflags = "2.0"
            //! ```

            use bitflags::bitflags;

            bitflags! {
                #[repr(C)]
                pub struct Flags: u32 {
                    const A = 0b00000001;
                    const B = 0b00000010;
                    const C = 0b00000100;
                }
            }

            #[no_mangle]
            pub extern "C" fn test_bitflags(a: bool, b: bool, c: bool) -> u32 {
                let mut flags = Flags::empty();
                if a { flags |= Flags::A; }
                if b { flags |= Flags::B; }
                if c { flags |= Flags::C; }
                flags.bits()
            }
            """

            @test @rust(test_bitflags(true, false, false)::UInt32) == 0b001
            @test @rust(test_bitflags(false, true, false)::UInt32) == 0b010
            @test @rust(test_bitflags(true, true, false)::UInt32) == 0b011
            @test @rust(test_bitflags(true, true, true)::UInt32) == 0b111
        end

        @testset "ndarray Integration" begin
            rust"""
            //! ```cargo
            //! [dependencies]
            //! ndarray = "0.15"
            //! ```

            use ndarray::Array1;

            #[no_mangle]
            pub extern "C" fn ndarray_sum(ptr: *const f64, len: usize) -> f64 {
                let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
                let arr = Array1::from(slice.to_vec());
                arr.sum()
            }
            """

            data = [1.0, 2.0, 3.0, 4.0, 5.0]
            result = @rust ndarray_sum(pointer(data), length(data))::Float64
            @test result ≈ 15.0
        end
    end
else
    @testset "Heavy Crate Integration (skipped)" begin
        @test_skip "Set LASTCALL_RUN_HEAVY_INTEGRATION_TESTS=true to run heavy integration tests"
    end
end

# Lightweight tests that don't require network/cargo builds
@testset "External Crate Detection" begin

    @testset "Dependency detection in rust\"\" strings" begin
        # These tests just verify the parsing works, no actual compilation

        code_with_deps = """
        //! ```cargo
        //! [dependencies]
        //! ndarray = "0.15"
        //! ```

        use ndarray::Array1;
        """

        @test has_dependencies(code_with_deps)

        deps = parse_dependencies_from_code(code_with_deps)
        @test length(deps) == 1
        @test deps[1].name == "ndarray"
        @test deps[1].version == "0.15"
    end

    @testset "No false positives" begin
        # Regular code without dependencies
        code_without_deps = """
        #[no_mangle]
        pub extern "C" fn simple_add(a: i32, b: i32) -> i32 {
            a + b
        }
        """

        @test !has_dependencies(code_without_deps)

        deps = parse_dependencies_from_code(code_without_deps)
        @test isempty(deps)
    end

    @testset "Comments that look like but aren't dependencies" begin
        # Regular comments that might be mistaken for cargo-deps
        code_with_comments = """
        // This is a cargo project
        // deps: this is not a dependency line

        #[no_mangle]
        pub extern "C" fn test() -> i32 { 42 }
        """

        @test !has_dependencies(code_with_comments)
    end
end
