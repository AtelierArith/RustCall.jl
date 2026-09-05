# Tests for LLVM call integration

using RustCall
using Test

@testset "LLVM Call Integration" begin
    @testset "RUST_MODULES uses String keys (#102)" begin
        # RUST_MODULES should use String (SHA256 hex) keys, not UInt64
        @test keytype(RustCall.RUST_MODULES) == String
    end

    @testset "FUNCTION_CACHE removed (#103)" begin
        # FUNCTION_CACHE was dead code (never populated) and has been removed
        @test !isdefined(RustCall, :FUNCTION_CACHE)
    end

    @testset "LLVMCodeGenerator" begin
        # Test default configuration
        codegen = RustCall.get_default_codegen()
        @test codegen isa RustCall.LLVMCodeGenerator
        @test codegen.optimization_level >= 0 && codegen.optimization_level <= 3

        # Test custom configuration
        custom = RustCall.LLVMCodeGenerator(
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
        info = RustCall.RustFunctionInfo(
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
        @test RustCall.julia_type_to_llvm_ir_string(Int32) == "i32"
        @test RustCall.julia_type_to_llvm_ir_string(Int64) == "i64"
        @test RustCall.julia_type_to_llvm_ir_string(Float32) == "float"
        @test RustCall.julia_type_to_llvm_ir_string(Float64) == "double"
        @test RustCall.julia_type_to_llvm_ir_string(Bool) == "i8"  # C ABI uses i8 (#165)
        @test RustCall.julia_type_to_llvm_ir_string(Cvoid) == "void"
        @test RustCall.julia_type_to_llvm_ir_string(Ptr{Cvoid}) == "ptr"  # LLVM opaque pointer
    end

    @testset "Cvoid === Nothing type alias safety (#110)" begin
        # Cvoid is an alias for Nothing in Julia. A single method handles both.
        @test Cvoid === Nothing
        @test RustCall.julia_type_to_llvm_ir_string(Cvoid) == "void"
        @test RustCall.julia_type_to_llvm_ir_string(Nothing) == "void"
        # Both should return the exact same result (same method)
        @test RustCall.julia_type_to_llvm_ir_string(Cvoid) === RustCall.julia_type_to_llvm_ir_string(Nothing)
    end

    @testset "LLVM IR Generation" begin
        # Test IR generation for function call
        ir = RustCall.generate_llvmcall_ir("test_add", Int32, Type[Int32, Int32])
        @test occursin("i32", ir)
        @test occursin("call", ir)

        # Verify correct interpolation: args should be "i32 %0, i32 %1", not "["i32", "i32"][1] %0"
        @test occursin("i32 %0", ir)
        @test occursin("i32 %1", ir)
        @test !occursin("[", ir)  # No array-like syntax in the IR

        # Test void return type
        ir_void = RustCall.generate_llvmcall_ir("test_void", Cvoid, Type[Int32])
        @test occursin("call ccc void", ir_void)  # C calling convention (#166)
        @test occursin("ret void", ir_void)

        # Test with mixed argument types
        ir_mixed = RustCall.generate_llvmcall_ir("test_mixed", Float64, Type[Int32, Float64])
        @test occursin("i32 %0", ir_mixed)
        @test occursin("double %1", ir_mixed)
    end

    # Only run integration tests if rustc is available
    if RustCall.check_rustc_available()
        @testset "Function Registration" begin
            # Compile and register a test function
            code = """
            #[no_mangle]
            pub extern "C" fn llvm_test_add(a: i32, b: i32) -> i32 {
                a + b
            }
            """

            info = RustCall.compile_and_register_rust_function(code, "llvm_test_add")
            @test info.name == "llvm_test_add"
            @test info.return_type == Int32
            @test info.arg_types == [Int32, Int32]
            @test info.func_ptr != C_NULL

            # Verify it's registered
            retrieved = RustCall.get_registered_function("llvm_test_add")
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
            RustCall.compile_and_register_rust_function("""
            #[no_mangle]
            pub extern "C" fn llvm_add(a: i32, b: i32) -> i32 { a + b }
            """, "llvm_add")

            RustCall.compile_and_register_rust_function("""
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
            result = RustCall.rust_call_generated(Val(:llvm_add), Int32(5), Int32(7))
            @test result == 12
        end

        @testset "Tuple Type Support" begin
            # Test tuple type conversion to LLVM IR
            @test RustCall.julia_type_to_llvm_ir_string(Tuple{Int32, Int64}) == "{i32, i64}"
            @test RustCall.julia_type_to_llvm_ir_string(Tuple{Float64, Float32}) == "{double, float}"
            @test RustCall.julia_type_to_llvm_ir_string(Tuple{}) == "{}"
            @test RustCall.julia_type_to_llvm_ir_string(Tuple{Int32, Int32, Int32}) == "{i32, i32, i32}"
        end

        @testset "Struct Type Support" begin
            # Define a test struct
            struct TestPoint
                x::Float64
                y::Float64
            end

            # Test struct type conversion to LLVM IR
            ir_str = RustCall.julia_type_to_llvm_ir_string(TestPoint)
            @test occursin("double", ir_str)
            @test occursin("{", ir_str)
            @test occursin("}", ir_str)

            # Test empty struct
            struct EmptyStruct end
            @test RustCall.julia_type_to_llvm_ir_string(EmptyStruct) == "{}"
        end

        @testset "Error Handling" begin
            # Test error for unregistered function
            @test_throws ErrorException begin
                @rust_llvm nonexistent_function(1, 2)
            end

            # Test error for argument count mismatch
            RustCall.compile_and_register_rust_function("""
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

primitive type _Dep265Prim 8 end
struct _Dep265Wrap
    x::_Dep265Prim
end
struct _Dep265Pair
    v::Tuple{Float32, Float32}
end
primitive type _Dep265Int <: Integer 8 end

@testset "LLVM path deprecation (#265)" begin
    # Every public entry point of the LLVM IR integration path emits a
    # deprecation warning but keeps working. `@test_deprecated` checks the
    # warning under --depwarn=yes (Pkg.test) and just runs the expression
    # otherwise.
    config = @test_deprecated RustCall.OptimizationConfig(level=1)
    @test config isa RustCall.OptimizationConfig
    @test config.level == 1

    # Positional construction bypasses the keyword wrapper but must warn too.
    positional = @test_deprecated RustCall.OptimizationConfig(2, 0, 225, true, true, true)
    @test positional.inline_threshold == 225
    # Convertible argument types still construct (Julia's default converting
    # constructor is suppressed by the typed inner constructor).
    converting = @test_deprecated RustCall.OptimizationConfig(Int8(2), Int8(0), Int16(225), true, true, true)
    @test converting == positional

    @test_deprecated RustCall.set_default_opt_config(RustCall._optimization_config())
    @test_deprecated RustCall.get_registered_function("no_such_function_265")
    @test (@test_deprecated RustCall.julia_type_to_llvm_ir_string(Int32)) == "i32"

    # Downstream extensions of the public name still apply to nested conversions
    # (tuple elements, struct fields) even though recursion goes through the
    # private helper.
    @eval RustCall.julia_type_to_llvm_ir_string(::Type{$(Symbol("_Dep265Prim"))}) = "i8"
    @test RustCall._julia_type_to_llvm_ir_string(Tuple{_Dep265Prim}) == "{i8}"
    @test RustCall._julia_type_to_llvm_ir_string(_Dep265Wrap) == "{i8}"
    @test RustCall._julia_type_to_llvm_ir_string(Tuple{Int32, _Dep265Prim}) == "{i32, i8}"
    # A downstream override of an already supported signature (e.g. a SIMD ABI
    # for a tuple) also wins, at top level and nested, as it did when the
    # built-ins were methods of the public name.
    @eval RustCall.julia_type_to_llvm_ir_string(::Type{Tuple{Float32, Float32}}) = "<2 x float>"
    @test RustCall._llvm_ir_type(Tuple{Float32, Float32}) == "<2 x float>"
    @test RustCall._llvm_ir_type(Tuple{Int32, Tuple{Float32, Float32}}) == "{i32, <2 x float>}"
    @test RustCall._llvm_ir_type(_Dep265Pair) == "{<2 x float>}"
    @test occursin("<2 x float>", RustCall.generate_llvmcall_ir("f", Tuple{Float32, Float32}, Type[Int32]))
    # Built-ins are untouched
    @test RustCall._llvm_ir_type(Tuple{Float64, Float64}) == "{double, double}"
    # A broad downstream method does not override more specific built-ins
    # (original dispatch ordering), but applies to types it alone covers.
    @eval RustCall.julia_type_to_llvm_ir_string(::Type{T}) where {T<:Integer} = "broad"
    @test RustCall._llvm_ir_type(Int32) == "i32"
    @test RustCall._llvm_ir_type(Tuple{Int64, UInt8}) == "{i64, i8}"
    @test RustCall._llvm_ir_type(_Dep265Int) == "broad"
    @test RustCall._llvm_ir_type(Tuple{Int32, _Dep265Int}) == "{i32, broad}"
    @test occursin("i32", RustCall.generate_llvmcall_ir("g", Int32, Type[Int64]))
    @test !occursin("broad", RustCall.generate_llvmcall_ir("g", Int32, Type[Int64]))
    # Built-in signatures still warn through the public name.
    @test (@test_deprecated RustCall.julia_type_to_llvm_ir_string(Tuple{Int32})) == "{i32}"
    @test (@test_deprecated RustCall.julia_type_to_llvm_ir_string(Ptr{Cvoid})) == "ptr"
    # Calls that hit a downstream method dispatch to it directly and therefore do
    # not warn (documented exception).
    if Base.JLOptions().depwarn != 0
        @test_logs RustCall.julia_type_to_llvm_ir_string(_Dep265Prim)
    end

    # Internal helpers used by @rust and by the deprecated wrappers stay silent.
    if Base.JLOptions().depwarn != 0
        @test_logs RustCall._optimization_config()
        @test_logs RustCall._get_registered_function("no_such_function_265")
        @test_logs RustCall._julia_type_to_llvm_ir_string(Int32)
    end

    if RustCall.check_rustc_available()
        rust"""
        #[no_mangle]
        pub extern "C" fn dep265_add(a: i32, b: i32) -> i32 { a + b }
        """
        result = @test_deprecated @rust_llvm dep265_add(Int32(1), Int32(2))
        @test result == Int32(3)
        # The non-deprecated equivalent
        @test (@rust dep265_add(Int32(1), Int32(2))::Int32) == Int32(3)

        wrapped = RustCall.wrap_rust_code("""
        #[no_mangle]
        pub extern "C" fn dep265_mul(a: i32, b: i32) -> i32 { a * b }
        """)
        compiler = RustCall.get_default_compiler()
        ir_path = @test_deprecated RustCall.compile_rust_to_llvm_ir(wrapped; compiler=compiler)
        @test isfile(ir_path)
        rust_mod = @test_deprecated RustCall.load_llvm_ir(ir_path; source_code=wrapped)
        @test rust_mod isa RustCall.RustModule
        fn = RustCall.get_function(rust_mod, "dep265_mul")
        if fn !== nothing
            sig = @test_deprecated RustCall.get_function_signature(fn)
            @test sig == (Int32, [Int32, Int32])
            @test_deprecated RustCall.optimize_module!(rust_mod.mod)
            @test_deprecated RustCall.optimize_for_speed!(rust_mod.mod)
        end
        info = @test_deprecated RustCall.compile_and_register_rust_function("""
        #[no_mangle]
        pub extern "C" fn dep265_sub(a: i32, b: i32) -> i32 { a - b }
        """, "dep265_sub")
        @test info.name == "dep265_sub"
    end
end
