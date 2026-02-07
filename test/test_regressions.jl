# Regression reproduction tests for known issues.

using RustCall
using Test

@testset "Known Regressions" begin
    @testset "Library-scoped return type metadata" begin
        empty!(RustCall.FUNCTION_RETURN_TYPES)
        empty!(RustCall.FUNCTION_RETURN_TYPES_BY_LIB)

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

        RustCall._register_function_signatures(code_i32, "lib_i32")
        @test RustCall.FUNCTION_RETURN_TYPES["same_name"] == Int32
        @test RustCall.get_function_return_type("lib_i32", "same_name") == Int32

        RustCall._register_function_signatures(code_f64, "lib_f64")
        @test RustCall.FUNCTION_RETURN_TYPES["same_name"] == Float64
        @test RustCall.get_function_return_type("lib_i32", "same_name") == Int32
        @test RustCall.get_function_return_type("lib_f64", "same_name") == Float64
    end

    @testset "Library-scoped return type is used by dynamic calls" begin
        if !RustCall.check_rustc_available()
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

        lib_i32 = RustCall._compile_and_load_rust(code_i32, "test_regressions", 0)
        lib_f64 = RustCall._compile_and_load_rust(code_f64, "test_regressions", 0)

        result_i32 = RustCall._rust_call_dynamic(lib_i32, "same_name")
        result_f64 = RustCall._rust_call_dynamic(lib_f64, "same_name")

        @test result_i32 isa Int32
        @test result_i32 == Int32(7)
        @test result_f64 isa Float64
        @test result_f64 == 2.5
    end

    @testset "@rust supports library-qualified call syntax" begin
        if !RustCall.check_rustc_available()
            @warn "rustc not found, skipping library-qualified call syntax test"
            return
        end

        code = """
        #[no_mangle]
        pub extern "C" fn multiply(a: i32, b: i32) -> i32 {
            a * b
        }
        """

        lib_name = RustCall._compile_and_load_rust(code, "test_regressions", 0)

        result_untyped = eval(Meta.parse("@rust $(lib_name)::multiply(Int32(3), Int32(4))"))
        result_typed = eval(Meta.parse("@rust $(lib_name)::multiply(Int32(5), Int32(6))::Int32"))

        @test result_untyped == Int32(12)
        @test result_typed == Int32(30)
    end

    @testset "Functions without return annotation are treated as Cvoid" begin
        if !RustCall.check_rustc_available()
            @warn "rustc not found, skipping Cvoid return inference test"
            return
        end

        code = """
        #[no_mangle]
        pub extern "C" fn do_nothing(x: i32) {
            let _ = x;
        }
        """

        lib_name = RustCall._compile_and_load_rust(code, "test_regressions", 0)
        result = RustCall._rust_call_dynamic(lib_name, "do_nothing", Int32(7))
        @test result === nothing
    end

    @testset "@irust stale cache after unload_all_libraries" begin
        if !RustCall.check_rustc_available()
            @warn "rustc not found, skipping @irust regression reproduction test"
            return
        end

        empty!(RustCall.IRUST_FUNCTIONS)
        RustCall.unload_all_libraries()

        # First call compiles and caches the function.
        first_result = RustCall._compile_and_call_irust("arg1 + 1", Int32(1))
        @test first_result == Int32(2)

        # Simulate a session reset of loaded dynamic libraries only.
        RustCall.unload_all_libraries()
        @test isempty(RustCall.RUST_LIBRARIES)
        @test !isempty(RustCall.IRUST_FUNCTIONS)

        # Should detect stale cache entry and recompile transparently.
        @test RustCall._compile_and_call_irust("arg1 + 1", Int32(2)) == Int32(3)

        empty!(RustCall.IRUST_FUNCTIONS)
        RustCall.unload_all_libraries()
    end
end
