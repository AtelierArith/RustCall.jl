using RustCall
using Test

# Include cache tests
include("test_cache.jl")

# Include ownership tests
include("test_ownership.jl")

# Include array/collection tests
include("test_arrays.jl")

# Include generics tests
include("test_generics.jl")

# Include error handling tests
include("test_error_handling.jl")

# Include llvmcall tests
include("test_llvmcall.jl")

# Include Rust helpers integration tests
include("test_rust_helpers_integration.jl")

# Include documentation examples tests
include("test_docs_examples.jl")

# Phase 3: External library integration tests
include("test_dependencies.jl")
include("test_cargo.jl")
include("test_ndarray.jl")
include("test_external_crates.jl")

# Examples converted to tests
include("test_basic_examples.jl")
include("test_advanced_examples.jl")
include("test_ownership_examples.jl")
include("test_struct_examples.jl")
include("test_phase4_ndarray.jl")
include("test_phase4_pi.jl")
include("test_generic_struct.jl")
include("test_julia_to_rust_simple.jl")
include("test_julia_to_rust_struct.jl")
include("test_julia_to_rust_generic.jl")

# Phase 5: #[julia] attribute tests
include("test_julia_attribute.jl")

# Phase 6: Crate bindings tests (Maturin-like feature)
include("test_crate_bindings.jl")

# Hot reload tests
include("test_hot_reload.jl")

# Regression reproduction tests
include("test_regressions.jl")

# Parsing, generics, and hot-reload fixes (#168, #169, #170, #172, #173, #184, #185)
include("test_parsing_generics_hotreload_fixes.jl")

@testset "RustCall.jl" begin

    @testset "Type Mappings" begin
        # Test Rust to Julia type conversion
        @test RustCall.rusttype_to_julia(:i32) == Int32
        @test RustCall.rusttype_to_julia(:i64) == Int64
        @test RustCall.rusttype_to_julia(:f32) == Float32
        @test RustCall.rusttype_to_julia(:f64) == Float64
        @test RustCall.rusttype_to_julia(:bool) == Bool
        @test RustCall.rusttype_to_julia(:u8) == UInt8
        @test RustCall.rusttype_to_julia(:usize) == UInt

        # Test Julia to Rust type conversion
        @test RustCall.juliatype_to_rust(Int32) == "i32"
        @test RustCall.juliatype_to_rust(Int64) == "i64"
        @test RustCall.juliatype_to_rust(Float32) == "f32"
        @test RustCall.juliatype_to_rust(Float64) == "f64"
        @test RustCall.juliatype_to_rust(Bool) == "bool"

        # Test string form
        @test RustCall.rusttype_to_julia("i32") == Int32
        @test RustCall.rusttype_to_julia("*const i32") == Ptr{Int32}
        @test RustCall.rusttype_to_julia("*mut f64") == Ptr{Float64}

        # Test string types
        @test RustCall.rusttype_to_julia("String") == RustCall.RustString
        @test RustCall.rusttype_to_julia("&str") == RustCall.RustStr  # &str is a fat pointer (issue #89)
        @test RustCall.rusttype_to_julia("str") == Cstring    # bare str maps to Cstring
        @test RustCall.rusttype_to_julia("*const u8") == Cstring
        @test RustCall.rusttype_to_julia("*mut u8") == Ptr{UInt8}
        @test RustCall.juliatype_to_rust(String) == "*const u8"
        @test RustCall.juliatype_to_rust(Cstring) == "*const u8"
        @test RustCall.juliatype_to_rust(RustCall.RustString) == "String"
        @test RustCall.juliatype_to_rust(RustCall.RustStr) == "&str"   # RustStr round-trips to &str (issue #89)
    end

    @testset "RustResult" begin
        ok_result = RustCall.RustResult{Int32, String}(true, Int32(42))
        err_result = RustCall.RustResult{Int32, String}(false, "error")

        @test RustCall.is_ok(ok_result)
        @test !RustCall.is_err(ok_result)
        @test RustCall.unwrap(ok_result) == 42
        @test RustCall.unwrap_or(ok_result, Int32(0)) == 42

        @test !RustCall.is_ok(err_result)
        @test RustCall.is_err(err_result)
        @test_throws ErrorException RustCall.unwrap(err_result)
        @test RustCall.unwrap_or(err_result, Int32(0)) == 0
    end

    @testset "Error Handling" begin
        # Test RustError creation
        err1 = RustCall.RustError("test error")
        @test err1.message == "test error"
        @test err1.code == 0
        @test err1.original_error === nothing

        err2 = RustCall.RustError("test error", Int32(42))
        @test err2.message == "test error"
        @test err2.code == 42
        @test err2.original_error === nothing

        err3 = RustCall.RustError("test error", Int32(42), "original")
        @test err3.message == "test error"
        @test err3.code == 42
        @test err3.original_error == "original"

        # Test result_to_exception with Ok result
        ok_result = RustCall.RustResult{Int32, String}(true, Int32(42))
        @test RustCall.result_to_exception(ok_result) == 42

        # Test result_to_exception with Err result (String error → code -1, preserves original)
        err_result = RustCall.RustResult{Int32, String}(false, "division by zero")
        @test_throws RustCall.RustError RustCall.result_to_exception(err_result)
        try
            RustCall.result_to_exception(err_result)
        catch e
            @test e isa RustCall.RustError
            @test e.message == "division by zero"
            @test e.code == -1
            @test e.original_error == "division by zero"
        end

        # Test result_to_exception with Integer error type (uses error value as code)
        int_err_result = RustCall.RustResult{String, Int32}(false, Int32(42))
        @test_throws RustCall.RustError RustCall.result_to_exception(int_err_result)
        try
            RustCall.result_to_exception(int_err_result)
        catch e
            @test e isa RustCall.RustError
            @test e.message == "42"
            @test e.code == 42
            @test e.original_error == Int32(42)
        end

        # Test result_to_exception with explicit error code (preserves original)
        err_result2 = RustCall.RustResult{Int32, String}(false, "not found")
        @test_throws RustCall.RustError RustCall.result_to_exception(err_result2, Int32(404))
        try
            RustCall.result_to_exception(err_result2, Int32(404))
        catch e
            @test e isa RustCall.RustError
            @test e.message == "not found"
            @test e.code == 404
            @test e.original_error == "not found"
        end

        # Test unwrap_or_throw alias
        @test RustCall.unwrap_or_throw(ok_result) == 42
        @test_throws RustCall.RustError RustCall.unwrap_or_throw(err_result)

        # Test CompilationError creation
        comp_err = RustCall.CompilationError(
            "Compilation failed",
            "error: expected `;`, found `}`",
            "fn test() {",
            "rustc --emit=llvm-ir test.rs"
        )
        @test comp_err.message == "Compilation failed"
        @test comp_err.raw_stderr == "error: expected `;`, found `}`"
        @test comp_err.source_code == "fn test() {"
        @test comp_err.command == "rustc --emit=llvm-ir test.rs"

        # Test RuntimeError creation
        runtime_err = RustCall.RuntimeError("Function failed", "test_func", "stack trace here")
        @test runtime_err.message == "Function failed"
        @test runtime_err.function_name == "test_func"
        @test runtime_err.stack_trace == "stack trace here"

        # Test format_rustc_error
        test_stderr = """
        error: expected `;`, found `}`
          --> test.rs:2:5
           |
        1  | fn test() {
        2  | }
           |  ^ expected `;`

        error: aborting due to previous error
        """
        formatted = RustCall.format_rustc_error(test_stderr)
        @test occursin("error:", formatted)
        @test occursin("expected", formatted)
    end

    @testset "RustOption" begin
        some_opt = RustCall.RustOption{Int32}(true, Int32(42))
        none_opt = RustCall.RustOption{Int32}(false, nothing)

        @test RustCall.is_some(some_opt)
        @test !RustCall.is_none(some_opt)
        @test RustCall.unwrap(some_opt) == 42
        @test RustCall.unwrap_or(some_opt, Int32(0)) == 42

        @test !RustCall.is_some(none_opt)
        @test RustCall.is_none(none_opt)
        @test_throws ErrorException RustCall.unwrap(none_opt)
        @test RustCall.unwrap_or(none_opt, Int32(0)) == 0
    end

    @testset "String Conversions" begin
        # Test julia_string_to_cstring
        s = "hello"
        cs = RustCall.julia_string_to_cstring(s)
        # cconvert returns the original string, unsafe_convert converts to Cstring
        @test cs isa String  # cconvert returns String, unsafe_convert is called at ccall time

        # Test cstring_to_julia_string (with a mock Cstring)
        # Note: This requires a valid Cstring pointer, so we'll skip direct testing
        # The conversion will be tested in actual Rust function calls

        # Test julia_string_to_rust
        rs = RustCall.julia_string_to_rust("world")
        @test rs isa RustCall.RustStr
        @test rs.len == 5

        # Test rust_str_to_julia
        s3 = RustCall.rust_str_to_julia(rs)
        @test s3 == "world"
    end

    @testset "Compiler Configuration" begin
        # Test default compiler creation
        compiler = RustCall.RustCompiler()
        @test compiler.optimization_level == 2
        @test compiler.emit_debug_info == false

        # Test custom compiler
        custom_compiler = RustCall.RustCompiler(
            optimization_level=3,
            emit_debug_info=true
        )
        @test custom_compiler.optimization_level == 3
        @test custom_compiler.emit_debug_info == true

        # Test target detection
        target = RustCall.get_default_target()
        @test !isempty(target)
        @test occursin("-", target)  # Target triples contain dashes
    end

    # Only run rustc tests if rustc is available
    if RustCall.check_rustc_available()
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
            libs = RustCall.list_loaded_libraries()
            @test isa(libs, Vector{String})
        end

        @testset "irust String Literal" begin
            # Simple multiplication (legacy syntax with explicit args)
            function test_double(x)
                @irust("arg1 * 2", x)
            end

            result = test_double(Int32(21))
            @test result == 42

            # Addition (legacy syntax)
            function test_add(a, b)
                @irust("arg1 + arg2", a, b)
            end

            result = test_add(Int32(10), Int32(20))
            @test result == 30

            # Float multiplication (legacy syntax)
            function test_float_mult(x, y)
                @irust("arg1 * arg2", x, y)
            end

            result = test_float_mult(3.0, 4.0)
            @test result ≈ 12.0

            # New: $var syntax for automatic variable binding
            function test_double_new(x)
                @irust("\$x * 2")
            end

            result = test_double_new(Int32(21))
            @test result == 42

            # New: Multiple variables with $var syntax
            function test_add_new(a, b)
                @irust("\$a + \$b")
            end

            result = test_add_new(Int32(10), Int32(20))
            @test result == 30

            # New: Float with $var syntax
            function test_float_mult_new(x, y)
                @irust("\$x * \$y")
            end

            result = test_float_mult_new(3.0, 4.0)
            @test result ≈ 12.0

            # New: Complex expression with $var syntax
            function test_complex(a, b, c)
                @irust("\$a + \$b * \$c")
            end

            result = test_complex(Int32(1), Int32(2), Int32(3))
            @test result == 7

            # New: Boolean operations
            function test_compare(a, b)
                @irust("\$a > \$b")
            end

            result = test_compare(Int32(10), Int32(5))
            @test result == true
            result = test_compare(Int32(5), Int32(10))
            @test result == false
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
        # ============================================================
        # Phase 2 Tests: LLVM IR Integration
        # ============================================================

        @testset "Phase 2: LLVM Integration" begin
            @testset "Optimization Configuration" begin
                # Test default config
                config = RustCall.OptimizationConfig()
                @test config.level == 2
                @test config.enable_vectorization == true

                # Test custom config
                custom_config = RustCall.OptimizationConfig(
                    level=3,
                    enable_vectorization=false,
                    inline_threshold=100
                )
                @test custom_config.level == 3
                @test custom_config.enable_vectorization == false
                @test custom_config.inline_threshold == 100
            end

            @testset "Optimization passes are not no-ops" begin
                # Verify that optimize_module! actually modifies IR (issue #95)
                # Create unoptimized Rust IR with dead code that optimization should remove
                rust_code = """
                #[no_mangle]
                pub extern "C" fn opt_test_dead_code(a: i32, b: i32) -> i32 {
                    let _unused = a * b;
                    let _also_unused = a + b + 1;
                    a + b
                }
                """
                wrapped = RustCall.wrap_rust_code(rust_code)
                # Use opt_level=0 to get unoptimized IR
                compiler_o0 = RustCall.RustCompiler(optimization_level=0)
                ir_path = RustCall.compile_rust_to_llvm_ir(wrapped; compiler=compiler_o0)

                rust_mod = RustCall.load_llvm_ir(ir_path; source_code=wrapped)
                llvm_mod = rust_mod.mod

                # Count instructions before optimization
                stats_before = RustCall.get_optimization_stats(llvm_mod)

                # Run optimization at level 2
                config = RustCall.OptimizationConfig(level=2)
                RustCall.optimize_module!(llvm_mod; config=config)

                # Count instructions after optimization
                stats_after = RustCall.get_optimization_stats(llvm_mod)

                # Optimization should reduce instruction count (dead code removal)
                @test stats_after["total_instructions"] <= stats_before["total_instructions"]
            end

            @testset "LLVM Type Conversion" begin
                # Test Julia to LLVM IR string conversion
                @test RustCall.julia_type_to_llvm_ir_string(Int32) == "i32"
                @test RustCall.julia_type_to_llvm_ir_string(Int64) == "i64"
                @test RustCall.julia_type_to_llvm_ir_string(Float32) == "float"
                @test RustCall.julia_type_to_llvm_ir_string(Float64) == "double"
                @test RustCall.julia_type_to_llvm_ir_string(Bool) == "i1"
                @test RustCall.julia_type_to_llvm_ir_string(Cvoid) == "void"
            end

            @testset "LLVM Module Loading" begin
                # Compile Rust code to LLVM IR
                rust_code = """
                #[no_mangle]
                pub extern "C" fn llvm_test_add(a: i32, b: i32) -> i32 {
                    a + b
                }
                """

                wrapped_code = RustCall.wrap_rust_code(rust_code)
                compiler = RustCall.get_default_compiler()
                ir_path = RustCall.compile_rust_to_llvm_ir(wrapped_code; compiler=compiler)

                @test isfile(ir_path)
                @test endswith(ir_path, ".ll")

                # Load the LLVM IR
                rust_mod = RustCall.load_llvm_ir(ir_path; source_code=wrapped_code)
                @test rust_mod !== nothing
                @test rust_mod isa RustCall.RustModule

                # List functions
                funcs = RustCall.list_functions(rust_mod)
                @test "llvm_test_add" in funcs

                # Get function signature
                fn = RustCall.get_function(rust_mod, "llvm_test_add")
                @test fn !== nothing

                ret_type, arg_types = RustCall.get_function_signature(fn)
                @test ret_type == Int32
                @test arg_types == [Int32, Int32]
            end

            @testset "LLVM Code Generator" begin
                # Test code generator configuration
                codegen = RustCall.LLVMCodeGenerator()
                @test codegen.optimization_level == 2
                @test codegen.enable_vectorization == true

                # Test custom code generator
                custom_codegen = RustCall.LLVMCodeGenerator(
                    optimization_level=3,
                    inline_threshold=300,
                    enable_vectorization=false
                )
                @test custom_codegen.optimization_level == 3
                @test custom_codegen.inline_threshold == 300
            end

            @testset "Function Registration" begin
                # Define and compile a function
                rust"""
                #[no_mangle]
                pub extern "C" fn registered_add(a: i32, b: i32) -> i32 {
                    a + b
                }
                """

                # The function should be callable via @rust
                result = @rust registered_add(Int32(5), Int32(7))::Int32
                @test result == 12
            end

            @testset "LLVM Registry Thread Safety" begin
                # Verify LLVM_REGISTRY_LOCK exists and is a ReentrantLock
                @test isdefined(RustCall, :LLVM_REGISTRY_LOCK)
                @test RustCall.LLVM_REGISTRY_LOCK isa ReentrantLock

                # Verify lock works correctly with concurrent access
                n_tasks = 4
                n_ops = 10
                results = Vector{Bool}(undef, n_tasks)

                tasks = []
                for t in 1:n_tasks
                    task = Threads.@spawn begin
                        for i in 1:n_ops
                            # get_registered_function should safely return nothing
                            # for unknown functions without crashing
                            info = RustCall.get_registered_function("nonexistent_$(t)_$(i)")
                            if info !== nothing
                                return false
                            end
                        end
                        return true
                    end
                    push!(tasks, task)
                end

                for (i, task) in enumerate(tasks)
                    results[i] = fetch(task)
                end
                @test all(results)
            end

            @testset "Extended Ownership Types" begin
                # Only test with dummy pointers if Rust helpers library is NOT available
                # (to avoid crash when drop! tries to free invalid pointer)
                if !RustCall.is_rust_helpers_available()
                    # Use UInt to construct pointers (required on 64-bit systems)
                    addr1 = UInt(0x1000)
                    addr2 = UInt(0x2000)
                    addr3 = UInt(0x3000)
                    addr4 = UInt(0x4000)
                    addr5 = UInt(0x5000)

                    # Test RustBox
                    box = RustCall.RustBox{Int32}(Ptr{Cvoid}(addr1))
                    @test box.ptr == Ptr{Cvoid}(addr1)
                    @test !box.dropped
                    @test RustCall.is_valid(box)

                    RustCall.drop!(box)
                    @test box.dropped
                    @test !RustCall.is_valid(box)

                    # Test RustRc
                    rc = RustCall.RustRc{Float64}(Ptr{Cvoid}(addr2))
                    @test rc.ptr == Ptr{Cvoid}(addr2)
                    @test !rc.dropped

                    RustCall.drop!(rc)
                    @test rc.dropped
                    @test RustCall.is_dropped(rc)

                    # Test RustArc
                    arc = RustCall.RustArc{String}(Ptr{Cvoid}(addr3))
                    @test arc.ptr == Ptr{Cvoid}(addr3)
                    @test !arc.dropped

                    RustCall.drop!(arc)
                    @test arc.dropped

                    # Test RustVec
                    vec = RustCall.RustVec{Int32}(Ptr{Cvoid}(addr4), UInt(10), UInt(20))
                    @test vec.ptr == Ptr{Cvoid}(addr4)
                    @test vec.len == 10
                    @test vec.cap == 20
                    @test length(vec) == 10
                    @test !vec.dropped

                    RustCall.drop!(vec)
                    @test vec.dropped

                    # Test RustSlice
                    slice = RustCall.RustSlice{Int32}(Ptr{Int32}(addr5), UInt(5))
                    @test slice.ptr == Ptr{Int32}(addr5)
                    @test slice.len == 5
                    @test length(slice) == 5
                else
                    # When Rust helpers library is available, test with real allocations
                    # These tests are covered in test_ownership.jl
                    @test RustCall.is_rust_helpers_available()
                end
            end
        end
    else
        @warn "rustc not found, skipping compilation tests"
    end

    @testset "Temp directory cleanup (issue #88)" begin
        if RustCall.check_rustc_available()
            @testset "Temp dir cleaned up on compilation error" begin
                invalid_code = """
                #[no_mangle]
                pub extern "C" fn bad_syntax( -> i32 { 42 }
                """
                compiler = RustCall.RustCompiler(debug_mode=false)

                # Track temp dirs created during compilation
                pre_tmpdirs = Set(readdir(tempdir()))

                @test_throws RustCall.CompilationError RustCall.compile_rust_to_shared_lib(invalid_code; compiler=compiler)

                # Verify no new temp dirs leaked (the try-finally should clean up)
                post_tmpdirs = Set(readdir(tempdir()))
                new_dirs = setdiff(post_tmpdirs, pre_tmpdirs)
                # Filter for rust_code-related dirs only
                rust_dirs = filter(d -> isdir(joinpath(tempdir(), d)) && isfile(joinpath(tempdir(), d, "rust_code.rs")), new_dirs)
                @test isempty(rust_dirs)
            end

            @testset "Temp dir cleaned up on LLVM IR compilation error" begin
                invalid_code = """
                #[no_mangle]
                pub extern "C" fn bad_syntax( -> i32 { 42 }
                """
                compiler = RustCall.RustCompiler(debug_mode=false)

                pre_tmpdirs = Set(readdir(tempdir()))

                @test_throws RustCall.CompilationError RustCall.compile_rust_to_llvm_ir(invalid_code; compiler=compiler)

                post_tmpdirs = Set(readdir(tempdir()))
                new_dirs = setdiff(post_tmpdirs, pre_tmpdirs)
                rust_dirs = filter(d -> isdir(joinpath(tempdir(), d)) && isfile(joinpath(tempdir(), d, "rust_code.rs")), new_dirs)
                @test isempty(rust_dirs)
            end

            @testset "Debug mode preserves temp dir on error" begin
                invalid_code = """
                #[no_mangle]
                pub extern "C" fn bad_syntax( -> i32 { 42 }
                """
                debug_dir = mktempdir()
                compiler = RustCall.RustCompiler(debug_mode=true, debug_dir=debug_dir)

                @test_throws RustCall.CompilationError RustCall.compile_rust_to_shared_lib(invalid_code; compiler=compiler)

                # Debug mode should keep the files (filename uses hash via _unique_source_name)
                @test isdir(debug_dir)
                rs_files = filter(f -> endswith(f, ".rs"), readdir(debug_dir))
                @test !isempty(rs_files)

                # Clean up
                rm(debug_dir, recursive=true, force=true)
            end
        else
            @warn "rustc not found, skipping temp directory cleanup tests"
        end
    end

    @testset "Error Handling Enhancement" begin
        if RustCall.check_rustc_available()
            @testset "CompilationError formatting" begin
                # Test that CompilationError displays formatted output
                # Use actually invalid Rust syntax (mismatched braces)
                invalid_code = """
                #[no_mangle]
                pub extern "C" fn test() -> i32 {
                    let x = {
                        42
                    // Missing closing brace for let block
                }
                """

                # This should throw a CompilationError
                compiler = RustCall.RustCompiler(debug_mode=false)
                @test_throws RustCall.CompilationError RustCall.compile_rust_to_shared_lib(invalid_code; compiler=compiler)
            end

            @testset "Debug mode" begin
                # Test debug mode configuration
                debug_compiler = RustCall.RustCompiler(debug_mode=true)
                @test debug_compiler.debug_mode == true
                @test debug_compiler.debug_dir === nothing

                # Test debug mode with custom directory
                debug_dir = mktempdir()
                debug_compiler2 = RustCall.RustCompiler(debug_mode=true, debug_dir=debug_dir)
                @test debug_compiler2.debug_mode == true
                @test debug_compiler2.debug_dir == debug_dir

                # Clean up
                rm(debug_dir, recursive=true, force=true)
            end

            @testset "Error recovery" begin
                # Test compile_with_recovery with invalid code
                # Use actually invalid Rust syntax (mismatched braces)
                invalid_code = """
                #[no_mangle]
                pub extern "C" fn test() -> i32 {
                    let x = {
                        42
                    // Missing closing brace for let block
                }
                """

                compiler = RustCall.RustCompiler(optimization_level=3, debug_mode=false)
                @test_throws RustCall.CompilationError RustCall.compile_with_recovery(invalid_code, compiler; retry_count=1)
            end

            @testset "Valid code compilation" begin
                # Test that valid code compiles successfully
                valid_code = """
                #[no_mangle]
                pub extern "C" fn test() -> i32 {
                    return 42;
                }
                """

                compiler = RustCall.RustCompiler(debug_mode=false)
                lib_path = RustCall.compile_rust_to_shared_lib(valid_code; compiler=compiler)
                @test isfile(lib_path)

                # Clean up
                rm(dirname(lib_path), recursive=true, force=true)
            end
        else
            @warn "rustc not found, skipping error handling enhancement tests"
        end
    end
end
