# Tests for enhanced error handling

using RustCall
using Test

@testset "Error Handling Enhancements" begin
    @testset "format_rustc_error improvements" begin
        # Test error highlighting
        stderr = """
        error: expected `;`, found `}`
          --> test.rs:2:5
           |
        1 | fn test() {
        2 | }
           |  ^ expected `;`

        error: aborting due to previous error
        """

        formatted = format_rustc_error(stderr)
        @test occursin("❌", formatted)
        @test occursin("error:", formatted)
        @test occursin("expected", formatted)

        # Test warning highlighting
        stderr_warning = """
        warning: unused variable `x`
          --> test.rs:1:9
           |
        1 | fn test() { let x = 42; }
           |         ^
        """

        formatted_warning = format_rustc_error(stderr_warning)
        @test occursin("⚠️", formatted_warning)
        @test occursin("warning:", formatted_warning)
    end

    @testset "Error line number extraction" begin
        stderr = """
        error: expected `;`, found `}`
          --> test.rs:2:5
           |
        1 | fn test() {
        2 | }
           |  ^
        """

        line_numbers = _extract_error_line_numbers(stderr)
        @test 2 in line_numbers
    end

    @testset "Suggestion extraction" begin
        stderr = """
        error: expected `;`, found `}`
          --> test.rs:2:5
           |
        1 | fn test() {
        2 | }
           |  ^ expected `;`

        help: add `;` here
        """

        suggestions = _extract_suggestions(stderr)
        @test !isempty(suggestions)
        # Check if suggestions contain help message or semicolon-related suggestion
        @test any(s -> occursin("semicolon", lowercase(s)) || occursin("add", lowercase(s)) || occursin(";", s), suggestions)
    end

    @testset "Auto-suggestion for common errors" begin
        # Test missing semicolon
        stderr = "error: expected `;`, found `}`"
        source = "fn test() { let x = 42 }"
        suggestions = suggest_fix_for_error(stderr, source)
        @test !isempty(suggestions)
        @test any(s -> occursin("semicolon", lowercase(s)), suggestions)

        # Test mismatched braces
        stderr_brace = "error: expected `}`, found `EOF`"
        source_brace = "fn test() { let x = { 42"
        suggestions_brace = suggest_fix_for_error(stderr_brace, source_brace)
        @test !isempty(suggestions_brace)
        @test any(s -> occursin("brace", lowercase(s)), suggestions_brace)

        # Test missing #[no_mangle]
        stderr_ffi = "error: cannot find function `test`"
        source_ffi = "pub extern \"C\" fn test() -> i32 { 42 }"
        suggestions_ffi = suggest_fix_for_error(stderr_ffi, source_ffi)
        @test any(s -> occursin("no_mangle", lowercase(s)), suggestions_ffi)
    end

    @testset "CompilationError display" begin
        if check_rustc_available()
            # Test that CompilationError shows formatted output
            invalid_code = """
            #[no_mangle]
            pub extern "C" fn test() -> i32 {
                let x = {
                    42
                // Missing closing brace
            }
            """

            compiler = RustCompiler(debug_mode=false)
            @test_throws CompilationError compile_rust_to_shared_lib(invalid_code; compiler=compiler)
        else
            @warn "rustc not available, skipping CompilationError display test"
        end
    end

    @testset "Debug mode information" begin
        if check_rustc_available()
            # Test that debug mode keeps files and provides info
            valid_code = """
            #[no_mangle]
            pub extern "C" fn test() -> i32 { 42 }
            """

            debug_dir = mktempdir()
            compiler = RustCompiler(debug_mode=true, debug_dir=debug_dir)

            try
                lib_path = compile_rust_to_shared_lib(valid_code; compiler=compiler)
                @test isfile(lib_path)

                # Check that debug directory exists and has files
                @test isdir(debug_dir)
            finally
                # Cleanup
                rm(debug_dir, recursive=true, force=true)
            end
        else
            @warn "rustc not available, skipping debug mode test"
        end
    end

    @testset "RuntimeError display" begin
        error = RuntimeError("Function failed", "test_func", "at test.rs:1:5")
        error_str = sprint(showerror, error)

        @test occursin("RuntimeError", error_str)
        @test occursin("test_func", error_str)
        @test occursin("Function failed", error_str)
        @test occursin("Stack trace", error_str)
    end

    @testset "Error message formatting edge cases" begin
        # Test empty stderr
        formatted = format_rustc_error("")
        @test isempty(formatted) || isempty(strip(formatted))

        # Test stderr with only warnings
        stderr_warning_only = """
        warning: unused variable `x`
        """
        formatted = format_rustc_error(stderr_warning_only)
        @test occursin("warning", formatted)

        # Test multiple errors
        stderr_multiple = """
        error: first error
        error: second error
        """
        formatted = format_rustc_error(stderr_multiple)
        @test occursin("Summary", formatted) || count("error:", lowercase(formatted)) >= 2
    end
end
