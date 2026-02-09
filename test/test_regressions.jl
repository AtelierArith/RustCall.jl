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
        expanded = RustCall.rust_impl(@__MODULE__, qualified_call, LineNumberNode(1))
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

    @testset "extract_function_code returns nothing for nonexistent function" begin
        code = """
        fn real_function() {
            let x = 1;
        }
        """
        @test RustCall.extract_function_code(code, "nonexistent") === nothing
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

    @testset "parse_inline_constraints skips lifetime parameters" begin
        type_params, constraints = RustCall.parse_inline_constraints("'a, T: Clone, U")
        @test type_params == [:T, :U]
        @test haskey(constraints, :T)
        @test !haskey(constraints, Symbol("'a"))
    end
end
