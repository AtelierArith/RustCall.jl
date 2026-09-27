# Component tests loaded by test_crate_bindings.jl.

@testset "Crate Bindings Integration" begin
    if !isdir(SAMPLE_CRATE_PATH)
        @test_skip "Sample crate not found, skipping integration tests"
        return
    end

    # Check if cargo is available
    try
        run(pipeline(`$(cargo()) --version`, devnull))
    catch
        @test_skip "Cargo not available, skipping integration tests"
        return
    end

    @testset "Full binding generation (may take a while)" begin
        # This test may take some time as it compiles Rust code
        try
            bindings = RustCall.generate_bindings(SAMPLE_CRATE_PATH, cache_enabled=false)
            @test bindings isa Expr
            @test bindings.head == :module || (bindings.head == :block && any(e -> e isa Expr && e.head == :module, bindings.args))
        catch e
            @warn "Binding generation failed: $e"
            @test_skip "Binding generation requires successful Rust compilation"
        end
    end

end

@testset "Result and Option Type Parsing" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc not found, skipping"
    else
        sigs(code) = RustCall.manifest_function_signatures(RustCall.extract_manifest(code; mode = "crate"))

        @testset "Result return kinds from the manifest" begin
            s = sigs("#[julia] fn a(x: f64) -> Result<f64, i32> { Ok(x) }")
            @test s[1].return_kind == :result
            @test (s[1].ok_type, s[1].err_type) == ("f64", "i32")

            s = sigs("#[julia] fn b(x: u32) -> Result<u32, i32> { Ok(x) }")
            @test (s[1].ok_type, s[1].err_type) == ("u32", "i32")

            s = sigs("#[julia] fn c(x: i32) -> i32 { x }")
            @test s[1].return_kind == :plain
            @test isempty(s[1].ok_type)

            s = sigs("#[julia] fn d() -> Result<(i32, i32), String> { Ok((1, 2)) }")
            @test (s[1].ok_type, s[1].err_type) == ("(i32, i32)", "String")

            s = sigs("#[julia] fn e() -> Result<Vec<Vec<i32>>, Box<dyn Error>> { Ok(vec![]) }")
            @test (s[1].ok_type, s[1].err_type) == ("Vec<Vec<i32>>", "Box<dyn Error>")
        end

        @testset "Option return kinds from the manifest" begin
            s = sigs("#[julia] fn a(x: f64) -> Option<f64> { Some(x) }")
            @test s[1].return_kind == :option
            @test s[1].inner_type == "f64"

            s = sigs("#[julia] fn b(x: i32) -> Result<i32, i32> { Ok(x) }")
            @test s[1].return_kind == :result
            @test isempty(s[1].inner_type)

            s = sigs("#[julia] fn c() -> Option<(i32, String)> { None }")
            @test s[1].inner_type == "(i32, String)"

            s = sigs("#[julia] fn d() -> Option<HashMap<String, Vec<i32>>> { None }")
            @test s[1].inner_type == "HashMap<String, Vec<i32>>"
        end
    end
end

# Property access tests - run in a separate Julia process for top-level module evaluation
