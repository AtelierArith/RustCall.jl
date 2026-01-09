# Tests for LLVM call integration

using LastCall
using Test

@testset "LLVM Call Integration" begin
    @testset "LLVMCodeGenerator" begin
        # Test default configuration
        codegen = LastCall.get_default_codegen()
        @test codegen isa LastCall.LLVMCodeGenerator
        @test codegen.optimization_level >= 0 && codegen.optimization_level <= 3

        # Test custom configuration
        custom = LastCall.LLVMCodeGenerator(
            optimization_level=3,
            inline_threshold=300,
            enable_vectorization=true
        )
        @test custom.optimization_level == 3
        @test custom.inline_threshold == 300
        @test custom.enable_vectorization == true
    end

    @testset "RustFunctionInfo" begin
        # Test struct definition
        info = LastCall.RustFunctionInfo(
            "test_func",
            Int32,
            [Int32, Int32],
            "define i32 @test_func(i32, i32) { ret i32 0 }",
            C_NULL
        )
        @test info.name == "test_func"
        @test info.return_type == Int32
        @test info.arg_types == [Int32, Int32]
        @test info.func_ptr == C_NULL
    end

    @testset "LLVM IR Type Conversion" begin
        # Test Julia to LLVM IR type string conversion
        @test LastCall.julia_type_to_llvm_ir_string(Int32) == "i32"
        @test LastCall.julia_type_to_llvm_ir_string(Int64) == "i64"
        @test LastCall.julia_type_to_llvm_ir_string(Float32) == "float"
        @test LastCall.julia_type_to_llvm_ir_string(Float64) == "double"
        @test LastCall.julia_type_to_llvm_ir_string(Bool) == "i1"
        @test LastCall.julia_type_to_llvm_ir_string(Cvoid) == "void"
        @test LastCall.julia_type_to_llvm_ir_string(Ptr{Cvoid}) == "ptr"  # LLVM opaque pointer
    end

    @testset "LLVM IR Generation" begin
        # Test IR generation for function call
        ir = LastCall.generate_llvmcall_ir("test_add", Int32, Type[Int32, Int32])
        @test occursin("i32", ir)
        @test occursin("call", ir)
    end

    # Only run integration tests if rustc is available
    if LastCall.check_rustc_available()
        @testset "Function Registration" begin
            # Compile and register a test function
            code = """
            #[no_mangle]
            pub extern "C" fn llvm_test_add(a: i32, b: i32) -> i32 {
                a + b
            }
            """

            info = compile_and_register_rust_function(code, "llvm_test_add")
            @test info.name == "llvm_test_add"
            @test info.return_type == Int32
            @test info.arg_types == [Int32, Int32]
            @test info.func_ptr != C_NULL

            # Verify it's registered
            retrieved = LastCall.get_registered_function("llvm_test_add")
            @test retrieved !== nothing
            @test retrieved.name == "llvm_test_add"
        end

        @testset "@rust_llvm Basic Calls" begin
            # First define the functions
            rust"""
            #[no_mangle]
            pub extern "C" fn llvm_add(a: i32, b: i32) -> i32 {
                a + b
            }

            #[no_mangle]
            pub extern "C" fn llvm_mul(a: i32, b: i32) -> i32 {
                a * b
            }

            #[no_mangle]
            pub extern "C" fn llvm_add_f64(a: f64, b: f64) -> f64 {
                a + b
            }
            """

            # Register for @rust_llvm
            compile_and_register_rust_function("""
            #[no_mangle]
            pub extern "C" fn llvm_add(a: i32, b: i32) -> i32 { a + b }
            """, "llvm_add")

            compile_and_register_rust_function("""
            #[no_mangle]
            pub extern "C" fn llvm_mul(a: i32, b: i32) -> i32 { a * b }
            """, "llvm_mul")

            # Test @rust_llvm calls
            result = @rust_llvm llvm_add(Int32(10), Int32(20))
            @test result == 30

            result = @rust_llvm llvm_mul(Int32(5), Int32(6))
            @test result == 30
        end

        @testset "@rust vs @rust_llvm Consistency" begin
            # Using already registered llvm_add for consistency test
            # to avoid LLVM IR parsing issues with newer Rust compilers

            # Both should produce the same result
            for (a, b) in [(Int32(0), Int32(0)), (Int32(1), Int32(2)), (Int32(10), Int32(20))]
                rust_result = @rust llvm_add(a, b)::Int32
                llvm_result = @rust_llvm llvm_add(a, b)
                @test rust_result == llvm_result
            end
        end

        @testset "Generated Function" begin
            # Use already registered llvm_add for generated function test
            # Test generated function path
            result = LastCall.rust_call_generated(Val(:llvm_add), Int32(5), Int32(7))
            @test result == 12
        end

        @testset "Tuple Type Support" begin
            # Test tuple type conversion to LLVM IR
            @test LastCall.julia_type_to_llvm_ir_string(Tuple{Int32, Int64}) == "{i32, i64}"
            @test LastCall.julia_type_to_llvm_ir_string(Tuple{Float64, Float32}) == "{double, float}"
            @test LastCall.julia_type_to_llvm_ir_string(Tuple{}) == "{}"
            @test LastCall.julia_type_to_llvm_ir_string(Tuple{Int32, Int32, Int32}) == "{i32, i32, i32}"
        end

        @testset "Struct Type Support" begin
            # Define a test struct
            struct TestPoint
                x::Float64
                y::Float64
            end

            # Test struct type conversion to LLVM IR
            ir_str = LastCall.julia_type_to_llvm_ir_string(TestPoint)
            @test occursin("double", ir_str)
            @test occursin("{", ir_str)
            @test occursin("}", ir_str)

            # Test empty struct
            struct EmptyStruct end
            @test LastCall.julia_type_to_llvm_ir_string(EmptyStruct) == "{}"
        end

        @testset "Error Handling" begin
            # Test error for unregistered function
            @test_throws ErrorException begin
                @rust_llvm nonexistent_function(1, 2)
            end

            # Test error for argument count mismatch
            compile_and_register_rust_function("""
            #[no_mangle]
            pub extern "C" fn test_two_args(a: i32, b: i32) -> i32 { a + b }
            """, "test_two_args")

            # Test missing argument
            error_thrown = false
            try
                @rust_llvm test_two_args(Int32(1))
            catch e
                error_thrown = true
                @test e isa ErrorException
                @test occursin("Argument count mismatch", string(e))
            end
            @test error_thrown

            # Test too many arguments
            error_thrown = false
            try
                @rust_llvm test_two_args(Int32(1), Int32(2), Int32(3))
            catch e
                error_thrown = true
                @test e isa ErrorException
                @test occursin("Argument count mismatch", string(e))
            end
            @test error_thrown
        end
    else
        @warn "rustc not found, skipping LLVM integration tests"
    end
end
