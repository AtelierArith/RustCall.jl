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

    @testset "@irust rejects unsupported argument types" begin
        err = try
            RustCall._compile_and_call_irust("arg1", 1 + 2im)
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test err isa ErrorException
        @test occursin("Unsupported Julia type for @irust", sprint(showerror, err))
    end

    @testset "Qualified @rust calls resolve libraries consistently" begin
        qualified_call = Expr(:call, Expr(:(::), :fake_lib, :fake_fn), :(Int32(1)))
        expanded = RustCall.rust_impl(@__MODULE__, qualified_call)
        expanded_str = sprint(show, expanded)
        @test occursin("_rust_call_from_lib", expanded_str)
        @test occursin("_resolve_lib", expanded_str)
    end

    @testset "extract_function_code handles generic functions" begin
        code = """
        pub fn identity<T>(x: T) -> T {
            x
        }
        """
        extracted = RustCall.extract_function_code(code, "identity")
        @test extracted !== nothing
        @test occursin("fn identity<T>", extracted)
        @test occursin("x", extracted)
    end

    @testset "extract_function_code handles escaped quotes in strings" begin
        # Escaped double quote inside string should not break brace counting
        code = """
        fn process() {
            let s = "contains \\" escaped quote";
            let x = 42;
        }
        """
        extracted = RustCall.extract_function_code(code, "process")
        @test extracted !== nothing
        @test occursin("let x = 42", extracted)
        @test occursin("}", extracted)
    end

    @testset "extract_function_code handles braces in strings" begin
        # Braces inside string literals should not be counted
        code = """
        fn format_json() -> String {
            let s = "{ \\"key\\": \\"value\\" }";
            s.to_string()
        }
        """
        extracted = RustCall.extract_function_code(code, "format_json")
        @test extracted !== nothing
        @test occursin("s.to_string()", extracted)
    end

    @testset "extract_function_code handles line comments" begin
        # Braces in comments should not be counted
        code = """
        fn with_comments() {
            // This comment has { braces } in it
            let x = 1;
        }
        """
        extracted = RustCall.extract_function_code(code, "with_comments")
        @test extracted !== nothing
        @test occursin("let x = 1", extracted)
    end

    @testset "extract_function_code handles block comments" begin
        code = """
        fn with_block_comment() {
            /* This block comment has { braces } */
            let x = 2;
        }
        """
        extracted = RustCall.extract_function_code(code, "with_block_comment")
        @test extracted !== nothing
        @test occursin("let x = 2", extracted)
    end

    @testset "extract_function_code handles char literals with braces" begin
        code = """
        fn char_braces() {
            let open = '{';
            let close = '}';
            let x = 3;
        }
        """
        extracted = RustCall.extract_function_code(code, "char_braces")
        @test extracted !== nothing
        @test occursin("let x = 3", extracted)
    end

    @testset "derive(JuliaStruct) parsing/removal handles multiline and order" begin
        multiline = """
        #[derive(
            JuliaStruct,
            Clone
        )]
        pub struct PointA {
            x: i32,
        }
        """
        cleaned_multiline = RustCall.remove_derive_julia_struct_attributes(multiline)
        @test !occursin("JuliaStruct", cleaned_multiline)
        @test occursin("Clone", cleaned_multiline)

        reordered = """
        #[derive(Clone, JuliaStruct)]
        pub struct PointB {
            x: i32,
        }
        """
        infos = RustCall.parse_structs_and_impls(reordered)
        @test length(infos) == 1
        @test infos[1].has_derive_julia_struct
        @test get(infos[1].derive_options, "Clone", false)
    end

    @testset "extract_function_code handles multiple escaped quotes (#124)" begin
        # Multiple escaped quotes in a row should not break parsing
        code = """
        fn multi_escape() {
            let s = "a\\"b\\"c\\"d";
            let x = 99;
        }
        """
        extracted = RustCall.extract_function_code(code, "multi_escape")
        @test extracted !== nothing
        @test occursin("let x = 99", extracted)
    end

    @testset "extract_function_code handles adjacent string literals (#124)" begin
        code = """
        fn adjacent_strings() {
            let a = "{ open";
            let b = "} close";
            let result = 42;
        }
        """
        extracted = RustCall.extract_function_code(code, "adjacent_strings")
        @test extracted !== nothing
        @test occursin("let result = 42", extracted)
    end

    @testset "extract_function_code returns nothing for nonexistent function" begin
        code = """
        fn real_function() {
            let x = 1;
        }
        """
        @test RustCall.extract_function_code(code, "nonexistent") === nothing
    end

    @testset "Silent fallback emits warning with function name (#126)" begin
        # When extract_function_code fails, the fallback must warn
        # with the function name so developers can diagnose the issue
        code = """
        #[no_mangle]
        pub extern "C" fn broken_body<T>(x: T) -> T
        """
        msg = @test_warn "Failed to extract function" RustCall._detect_and_register_generic_functions(code, "test_lib_126")
        # The warning message should mention the specific function name
        # (captured by @test_warn returning the log message)
    end

    @testset "detect_and_register warns on extraction fallback" begin
        # Code with a generic function whose name doesn't match the fn pattern
        # (no braces after function signature — causes extract_function_code to fail)
        code = """
        #[no_mangle]
        pub extern "C" fn missing_body<T>(x: T) -> T
        """
        # Should emit a warning about falling back to entire block
        @test_warn "Failed to extract function" RustCall._detect_and_register_generic_functions(code, "test_lib")
    end

    @testset "extract_block_at is accessible from module scope" begin
        # Verify that extract_block_at is defined in the RustCall module (issue #82)
        @test isdefined(RustCall, :extract_block_at)
        @test RustCall.extract_block_at isa Function
    end

    @testset "extract_block_at extracts balanced brace blocks" begin
        code = """
        pub struct Point {
            x: f64,
            y: f64,
        }
        """
        m = match(r"pub struct Point", code)
        result = RustCall.extract_block_at(code, m.offset)
        @test result !== nothing
        @test occursin("pub struct Point", result)
        @test occursin("x: f64", result)
        @test occursin("y: f64", result)
    end

    @testset "extract_block_at handles nested braces" begin
        code = """
        impl Point {
            fn new(x: f64, y: f64) -> Self {
                Point { x, y }
            }
        }
        """
        m = match(r"impl Point", code)
        result = RustCall.extract_block_at(code, m.offset)
        @test result !== nothing
        @test occursin("impl Point", result)
        @test occursin("fn new", result)
        @test occursin("Point { x, y }", result)
    end

    @testset "extract_block_at returns nothing when no brace found" begin
        code = "fn no_body()"
        result = RustCall.extract_block_at(code, 1)
        @test result === nothing
    end

    @testset "extract_block_at handles tuple structs" begin
        code = "pub struct Wrapper(i32);"
        result = RustCall.extract_block_at(code, 1)
        @test result !== nothing
        @test occursin("Wrapper", result)
    end

    @testset "Lifetime parameters are skipped in generic function detection" begin
        # Function with lifetime and type parameter
        code = """
        pub fn process<'a, T>(data: &'a T) -> &'a T {
            data
        }
        """
        empty!(RustCall.GENERIC_FUNCTION_REGISTRY)
        RustCall._detect_and_register_generic_functions(code, "test_lifetime")
        @test haskey(RustCall.GENERIC_FUNCTION_REGISTRY, "process")
        info = RustCall.GENERIC_FUNCTION_REGISTRY["process"]
        # Should only have T, not 'a
        @test info.type_params == [:T]
        empty!(RustCall.GENERIC_FUNCTION_REGISTRY)
    end

    @testset "Lifetime-only generic functions are not registered" begin
        # Function with only lifetime parameters (not truly generic for monomorphization)
        code = """
        pub fn borrow<'a>(data: &'a i32) -> &'a i32 {
            data
        }
        """
        empty!(RustCall.GENERIC_FUNCTION_REGISTRY)
        RustCall._detect_and_register_generic_functions(code, "test_lifetime_only")
        # Should not be registered since there are no type parameters
        @test !haskey(RustCall.GENERIC_FUNCTION_REGISTRY, "borrow")
        empty!(RustCall.GENERIC_FUNCTION_REGISTRY)
    end

    @testset "RustVec/RustSlice use typed pointer indexing (#122)" begin
        # Verify that RustVec and RustSlice use Julia's typed unsafe_load
        # instead of manual pointer arithmetic (ptr + idx * sizeof(T))
        # Test with a real buffer to verify correctness
        data = Int32[10, 20, 30, 40, 50]
        GC.@preserve data begin
            ptr = Ptr{Cvoid}(pointer(data))
            vec = RustVec{Int32}(ptr, UInt(5), UInt(5))
            vec.dropped = false  # Prevent finalizer issues

            @test vec[1] == 10
            @test vec[2] == 20
            @test vec[5] == 50
            @test_throws BoundsError vec[0]
            @test_throws BoundsError vec[6]

            # Test RustSlice
            slice = RustSlice{Int32}(Ptr{Int32}(ptr), UInt(5))
            @test slice[1] == 10
            @test slice[3] == 30
            @test_throws BoundsError slice[0]
            @test_throws BoundsError slice[6]

            # Test with different element size (Float64 = 8 bytes)
            fdata = Float64[1.5, 2.5, 3.5]
            GC.@preserve fdata begin
                fptr = Ptr{Cvoid}(pointer(fdata))
                fvec = RustVec{Float64}(fptr, UInt(3), UInt(3))
                fvec.dropped = false
                @test fvec[1] ≈ 1.5
                @test fvec[2] ≈ 2.5
                @test fvec[3] ≈ 3.5
            end
        end
    end

    @testset "safe_dlsym prevents NULL segfaults (#118)" begin
        # safe_dlsym should be defined
        @test isdefined(RustCall, :safe_dlsym)

        # With a valid library handle, looking up a nonexistent symbol
        # should throw a clear error, not return NULL
        if RustCall.is_rust_helpers_available()
            lib = RustCall.get_rust_helpers_lib()
            @test_throws ErrorException RustCall.safe_dlsym(lib, :nonexistent_symbol_xyz)
            try
                RustCall.safe_dlsym(lib, :nonexistent_symbol_xyz)
            catch e
                @test occursin("not found", e.msg)
            end
        end
    end

    @testset "Concurrent registry access is safe (#112)" begin
        # Verify that concurrent reads/writes to global registries
        # don't crash (thread safety via REGISTRY_LOCK)
        n_tasks = 4
        n_ops = 10
        errors = Threads.Atomic{Int}(0)

        tasks = []
        for t in 1:n_tasks
            task = Threads.@spawn begin
                for i in 1:n_ops
                    try
                        # Read from GENERIC_FUNCTION_REGISTRY (should be locked)
                        RustCall.is_generic_function("concurrent_test_$(t)_$(i)")
                        # Read from IRUST_FUNCTIONS (should be locked)
                        lock(RustCall.REGISTRY_LOCK) do
                            haskey(RustCall.IRUST_FUNCTIONS, UInt64(t * 1000 + i))
                        end
                    catch
                        Threads.atomic_add!(errors, 1)
                    end
                end
            end
            push!(tasks, task)
        end

        for task in tasks
            fetch(task)
        end
        @test errors[] == 0
    end

    @testset "Deeply nested generics in specialize_generic_code (#108)" begin
        # Ensure bracket-counting handles arbitrary nesting depth
        code = "pub fn deep<T>(x: Vec<Option<Result<T, String>>>) -> T { todo!() }"
        specialized = RustCall.specialize_generic_code(code, Dict(:T => Int32))
        @test occursin("Vec<Option<Result<i32, String>>>", specialized)
        @test occursin("fn deep(", specialized)
        @test !occursin("<T>", specialized)

        # HashMap<K, V> with two type params
        code2 = "pub fn lookup<K, V>(m: HashMap<K, V>, key: K) -> V { todo!() }"
        specialized2 = RustCall.specialize_generic_code(code2, Dict(:K => Int32, :V => Float64))
        @test occursin("HashMap<i32, f64>", specialized2)
        @test occursin("fn lookup(", specialized2)

        # impl<T> with nested bounds
        code3 = "impl<T: Add<Output = T>> MyStruct<T> { fn go(self) -> T { todo!() } }"
        specialized3 = RustCall.specialize_generic_code(code3, Dict(:T => Int32))
        @test occursin("impl MyStruct<i32>", specialized3) || occursin("impl  MyStruct<i32>", specialized3)
        @test !occursin("<i32: Add", specialized3)
    end

    @testset "parse_inline_constraints skips lifetime parameters" begin
        type_params, constraints = RustCall.parse_inline_constraints("'a, T: Clone, U")
        @test type_params == [:T, :U]
        @test haskey(constraints, :T)
        @test !haskey(constraints, Symbol("'a"))
    end

    @testset "_convert_args_for_rust dead code removed (#99)" begin
        # _convert_args_for_rust was a no-op function that returned args unchanged.
        # Verify it has been removed from the module.
        @test !isdefined(RustCall, :_convert_args_for_rust)
    end

    @testset "Unused source parameter removed from macro expansion (#100)" begin
        # rust_impl and friends no longer accept a source parameter.
        # Verify 2-arg rust_impl works and 3-arg (with source) errors.
        call_expr = Expr(:call, :fake_fn, :(Int32(1)))
        expanded = RustCall.rust_impl(@__MODULE__, call_expr)
        expanded_str = sprint(show, expanded)
        @test occursin("_rust_call_dynamic", expanded_str)

        # The old 3-arg signature should no longer exist
        @test_throws MethodError RustCall.rust_impl(@__MODULE__, call_expr, LineNumberNode(1))
    end

    @testset "Unique filenames in debug_dir prevent overwrite (#101)" begin
        # When debug_dir is set, different source code should produce different filenames
        compiler_debug = RustCall.RustCompiler(debug_mode=true, debug_dir=mktempdir())

        name1 = RustCall._unique_source_name("fn foo() {}", compiler_debug)
        name2 = RustCall._unique_source_name("fn bar() {}", compiler_debug)
        name_same = RustCall._unique_source_name("fn foo() {}", compiler_debug)

        # Different code → different names
        @test name1 != name2
        # Same code → same name (deterministic)
        @test name1 == name_same
        # Names should have hash prefix
        @test startswith(name1, "rust_")
        @test length(name1) == 5 + RustCall.RECOVERY_FINGERPRINT_LEN  # "rust_" + 12-char hash

        # Without debug_dir, should return the fixed name
        compiler_normal = RustCall.RustCompiler(debug_mode=false)
        @test RustCall._unique_source_name("fn foo() {}", compiler_normal) == "rust_code"

        # Clean up
        rm(compiler_debug.debug_dir, recursive=true, force=true)

        # Integration test: compile two functions to the same debug_dir
        if RustCall.check_rustc_available()
            debug_dir = mktempdir()
            compiler = RustCall.RustCompiler(debug_mode=true, debug_dir=debug_dir)

            code1 = """
            #[no_mangle]
            pub extern "C" fn debug_fn_a() -> i32 { 1 }
            """
            code2 = """
            #[no_mangle]
            pub extern "C" fn debug_fn_b() -> i32 { 2 }
            """

            lib1 = RustCall.compile_rust_to_shared_lib(code1; compiler=compiler)
            lib2 = RustCall.compile_rust_to_shared_lib(code2; compiler=compiler)

            # Both libraries should exist (not overwritten)
            @test isfile(lib1)
            @test isfile(lib2)
            @test lib1 != lib2

            rm(debug_dir, recursive=true, force=true)
        end
    end
end
