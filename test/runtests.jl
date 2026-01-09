using LastCall
using Test

@testset "LastCall.jl" begin

    @testset "Type Mappings" begin
        # Test Rust to Julia type conversion
        @test rusttype_to_julia(:i32) == Int32
        @test rusttype_to_julia(:i64) == Int64
        @test rusttype_to_julia(:f32) == Float32
        @test rusttype_to_julia(:f64) == Float64
        @test rusttype_to_julia(:bool) == Bool
        @test rusttype_to_julia(:u8) == UInt8
        @test rusttype_to_julia(:usize) == UInt

        # Test Julia to Rust type conversion
        @test juliatype_to_rust(Int32) == "i32"
        @test juliatype_to_rust(Int64) == "i64"
        @test juliatype_to_rust(Float32) == "f32"
        @test juliatype_to_rust(Float64) == "f64"
        @test juliatype_to_rust(Bool) == "bool"

        # Test string form
        @test rusttype_to_julia("i32") == Int32
        @test rusttype_to_julia("*const i32") == Ptr{Int32}
        @test rusttype_to_julia("*mut f64") == Ptr{Float64}

        # Test string types
        @test rusttype_to_julia("String") == RustString
        @test rusttype_to_julia("&str") == Cstring
        @test rusttype_to_julia("str") == Cstring
        @test rusttype_to_julia("*const u8") == Cstring
        @test rusttype_to_julia("*mut u8") == Ptr{UInt8}
        @test juliatype_to_rust(String) == "*const u8"
        @test juliatype_to_rust(Cstring) == "*const u8"
        @test juliatype_to_rust(RustString) == "String"
    end

    @testset "RustResult" begin
        ok_result = RustResult{Int32, String}(true, Int32(42))
        err_result = RustResult{Int32, String}(false, "error")

        @test is_ok(ok_result)
        @test !is_err(ok_result)
        @test unwrap(ok_result) == 42
        @test unwrap_or(ok_result, Int32(0)) == 42

        @test !is_ok(err_result)
        @test is_err(err_result)
        @test_throws ErrorException unwrap(err_result)
        @test unwrap_or(err_result, Int32(0)) == 0
    end

    @testset "RustOption" begin
        some_opt = RustOption{Int32}(true, Int32(42))
        none_opt = RustOption{Int32}(false, nothing)

        @test is_some(some_opt)
        @test !is_none(some_opt)
        @test unwrap(some_opt) == 42
        @test unwrap_or(some_opt, Int32(0)) == 42

        @test !is_some(none_opt)
        @test is_none(none_opt)
        @test_throws ErrorException unwrap(none_opt)
        @test unwrap_or(none_opt, Int32(0)) == 0
    end

    @testset "String Conversions" begin
        # Test julia_string_to_cstring
        s = "hello"
        cs = julia_string_to_cstring(s)
        # cconvert returns the original string, unsafe_convert converts to Cstring
        @test cs isa String  # cconvert returns String, unsafe_convert is called at ccall time

        # Test cstring_to_julia_string (with a mock Cstring)
        # Note: This requires a valid Cstring pointer, so we'll skip direct testing
        # The conversion will be tested in actual Rust function calls

        # Test julia_string_to_rust
        rs = julia_string_to_rust("world")
        @test rs isa RustStr
        @test rs.len == 5

        # Test rust_str_to_julia
        s3 = rust_str_to_julia(rs)
        @test s3 == "world"
    end

    @testset "Compiler Configuration" begin
        # Test default compiler creation
        compiler = LastCall.RustCompiler()
        @test compiler.optimization_level == 2
        @test compiler.emit_debug_info == false

        # Test custom compiler
        custom_compiler = LastCall.RustCompiler(
            optimization_level=3,
            emit_debug_info=true
        )
        @test custom_compiler.optimization_level == 3
        @test custom_compiler.emit_debug_info == true

        # Test target detection
        target = LastCall.get_default_target()
        @test !isempty(target)
        @test occursin("-", target)  # Target triples contain dashes
    end

    # Only run rustc tests if rustc is available
    if LastCall.check_rustc_available()
        @testset "Rust Compilation" begin
            @testset "Basic Function" begin
                # Define a simple Rust function
                rust"""
                #[no_mangle]
                pub extern "C" fn test_add(a: i32, b: i32) -> i32 {
                    a + b
                }
                """

                # Test the function call
                result = @rust test_add(Int32(10), Int32(20))::Int32
                @test result == 30
            end

            @testset "Float Operations" begin
                rust"""
                #[no_mangle]
                pub extern "C" fn test_multiply(a: f64, b: f64) -> f64 {
                    a * b
                }
                """

                result = @rust test_multiply(3.0, 4.0)::Float64
                @test result ≈ 12.0
            end

            @testset "Boolean Return" begin
                rust"""
                #[no_mangle]
                pub extern "C" fn test_is_positive(x: i32) -> bool {
                    x > 0
                }
                """

                @test @rust(test_is_positive(Int32(5))::Bool) == true
                @test @rust(test_is_positive(Int32(-5))::Bool) == false
            end
        end

        @testset "Library Management" begin
            libs = LastCall.list_loaded_libraries()
            @test isa(libs, Vector{String})
        end

        @testset "irust String Literal" begin
            # Simple multiplication
            function test_double(x)
                @irust("arg1 * 2", x)
            end

            result = test_double(Int32(21))
            @test result == 42

            # Addition
            function test_add(a, b)
                @irust("arg1 + arg2", a, b)
            end

            result = test_add(Int32(10), Int32(20))
            @test result == 30

            # Float multiplication
            function test_float_mult(x, y)
                @irust("arg1 * arg2", x, y)
            end

            result = test_float_mult(3.0, 4.0)
            @test result ≈ 12.0
        end

        @testset "String Support" begin
            # Test C string (const u8) input - simple length function
            rust"""
            #[no_mangle]
            pub extern "C" fn string_length(s: *const u8) -> u32 {
                let c_str = unsafe { std::ffi::CStr::from_ptr(s as *const i8) };
                c_str.to_bytes().len() as u32
            }
            """

            # Test string length function with String argument
            result = @rust string_length("hello")::UInt32
            @test result == 5

            result = @rust string_length("世界")::UInt32
            @test result == 6  # UTF-8 bytes for 世界

            # Test with empty string
            result = @rust string_length("")::UInt32
            @test result == 0
        end
    else
        @warn "rustc not found, skipping compilation tests"
    end
end
