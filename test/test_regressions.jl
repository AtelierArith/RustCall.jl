# Regression reproduction tests for known issues.

using LastCall
using Test

@testset "Known Regressions" begin
    @testset "Library-scoped return type metadata" begin
        empty!(LastCall.FUNCTION_RETURN_TYPES)
        empty!(LastCall.FUNCTION_RETURN_TYPES_BY_LIB)

        code_i32 = """
        #[no_mangle]
        pub extern "C" fn same_name() -> i32 {
            1
        }
        """

        code_f64 = """
        #[no_mangle]
        pub extern "C" fn same_name() -> f64 {
            1.0
        }
        """

        LastCall._register_function_signatures(code_i32, "lib_i32")
        @test LastCall.FUNCTION_RETURN_TYPES["same_name"] == Int32
        @test LastCall.get_function_return_type("lib_i32", "same_name") == Int32

        LastCall._register_function_signatures(code_f64, "lib_f64")
        @test LastCall.FUNCTION_RETURN_TYPES["same_name"] == Float64
        @test LastCall.get_function_return_type("lib_i32", "same_name") == Int32
        @test LastCall.get_function_return_type("lib_f64", "same_name") == Float64
    end

    @testset "Library-scoped return type is used by dynamic calls" begin
        if !LastCall.check_rustc_available()
            @warn "rustc not found, skipping library-scoped dynamic call test"
            return
        end

        code_i32 = """
        #[no_mangle]
        pub extern "C" fn same_name() -> i32 {
            7
        }
        """
        code_f64 = """
        #[no_mangle]
        pub extern "C" fn same_name() -> f64 {
            2.5
        }
        """

        lib_i32 = LastCall._compile_and_load_rust(code_i32, "test_regressions", 0)
        lib_f64 = LastCall._compile_and_load_rust(code_f64, "test_regressions", 0)

        result_i32 = LastCall._rust_call_dynamic(lib_i32, "same_name")
        result_f64 = LastCall._rust_call_dynamic(lib_f64, "same_name")

        @test result_i32 isa Int32
        @test result_i32 == Int32(7)
        @test result_f64 isa Float64
        @test result_f64 == 2.5
    end

    @testset "@irust stale cache after unload_all_libraries" begin
        if !LastCall.check_rustc_available()
            @warn "rustc not found, skipping @irust regression reproduction test"
            return
        end

        empty!(LastCall.IRUST_FUNCTIONS)
        LastCall.unload_all_libraries()

        # First call compiles and caches the function.
        first_result = LastCall._compile_and_call_irust("arg1 + 1", Int32(1))
        @test first_result == Int32(2)

        # Simulate a session reset of loaded dynamic libraries only.
        LastCall.unload_all_libraries()
        @test isempty(LastCall.RUST_LIBRARIES)
        @test !isempty(LastCall.IRUST_FUNCTIONS)

        # Should detect stale cache entry and recompile transparently.
        @test LastCall._compile_and_call_irust("arg1 + 1", Int32(2)) == Int32(3)

        empty!(LastCall.IRUST_FUNCTIONS)
        LastCall.unload_all_libraries()
    end
end
