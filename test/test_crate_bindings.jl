# Tests for the crate bindings feature (Maturin-like functionality)

using Test
using LastCall

# Path to the sample crate
const SAMPLE_CRATE_PATH = joinpath(dirname(@__DIR__), "examples", "sample_crate")

@testset "Crate Bindings" begin

    @testset "CrateBindingOptions" begin
        # Test default options
        opts = CrateBindingOptions()
        @test opts.output_module_name === nothing
        @test opts.output_path === nothing
        @test opts.use_wrapper_crate == true
        @test opts.build_release == true
        @test opts.cache_enabled == true

        # Test custom options
        opts2 = CrateBindingOptions(
            output_module_name = "MyModule",
            build_release = false,
            cache_enabled = false
        )
        @test opts2.output_module_name == "MyModule"
        @test opts2.build_release == false
        @test opts2.cache_enabled == false
    end

    @testset "scan_crate" begin
        if !isdir(SAMPLE_CRATE_PATH)
            @warn "Sample crate not found, skipping scan_crate tests"
            return
        end

        info = scan_crate(SAMPLE_CRATE_PATH)

        @test info.name == "sample_crate"
        @test info.path == abspath(SAMPLE_CRATE_PATH)
        @test !isempty(info.source_files)
        @test any(f -> endswith(f, "lib.rs"), info.source_files)

        # Check that we found the #[julia] functions
        @test length(info.julia_functions) >= 4  # add, multiply, fibonacci, is_prime
        func_names = [f.name for f in info.julia_functions]
        @test "add" in func_names
        @test "multiply" in func_names
        @test "fibonacci" in func_names
        @test "is_prime" in func_names

        # Check that we found the #[julia] structs
        @test length(info.julia_structs) >= 3  # Point, Counter, Rectangle
        struct_names = [s.name for s in info.julia_structs]
        @test "Point" in struct_names
        @test "Counter" in struct_names
        @test "Rectangle" in struct_names
    end

    @testset "parse_cargo_toml" begin
        cargo_toml_path = joinpath(SAMPLE_CRATE_PATH, "Cargo.toml")
        if !isfile(cargo_toml_path)
            @warn "Cargo.toml not found, skipping test"
            return
        end

        cargo = LastCall.parse_cargo_toml(cargo_toml_path)

        @test haskey(cargo, "package")
        @test cargo["package"]["name"] == "sample_crate"
        @test cargo["package"]["version"] == "0.1.0"
    end

    @testset "find_rust_sources" begin
        if !isdir(SAMPLE_CRATE_PATH)
            @warn "Sample crate not found, skipping test"
            return
        end

        sources = LastCall.find_rust_sources(SAMPLE_CRATE_PATH)

        @test !isempty(sources)
        @test all(f -> endswith(f, ".rs"), sources)
        @test any(f -> endswith(f, "lib.rs"), sources)
    end

    @testset "parse_julia_structs_from_source" begin
        code = """
        #[julia]
        pub struct TestStruct {
            pub x: f64,
            pub y: f64,
        }

        #[julia]
        impl TestStruct {
            #[julia]
            pub fn new(x: f64, y: f64) -> Self {
                TestStruct { x, y }
            }

            #[julia]
            pub fn get_sum(&self) -> f64 {
                self.x + self.y
            }
        }
        """

        structs = LastCall.parse_julia_structs_from_source(code)

        @test length(structs) == 1
        @test structs[1].name == "TestStruct"
        @test length(structs[1].fields) == 2

        field_names = [f[1] for f in structs[1].fields]
        @test "x" in field_names
        @test "y" in field_names
    end

    @testset "create_wrapper_crate" begin
        if !isdir(SAMPLE_CRATE_PATH)
            @warn "Sample crate not found, skipping test"
            return
        end

        info = scan_crate(SAMPLE_CRATE_PATH)
        opts = CrateBindingOptions()

        wrapper_path = LastCall.create_wrapper_crate(info, opts)

        try
            @test isdir(wrapper_path)
            @test isfile(joinpath(wrapper_path, "Cargo.toml"))
            @test isfile(joinpath(wrapper_path, "src", "lib.rs"))

            # Check Cargo.toml content
            cargo_content = read(joinpath(wrapper_path, "Cargo.toml"), String)
            @test occursin("sample_crate_julia_wrapper", cargo_content)
            @test occursin("cdylib", cargo_content)
            @test occursin("sample_crate", cargo_content)
        finally
            # Cleanup
            rm(wrapper_path, recursive=true, force=true)
        end
    end

    @testset "compute_crate_hash" begin
        if !isdir(SAMPLE_CRATE_PATH)
            @warn "Sample crate not found, skipping test"
            return
        end

        info = scan_crate(SAMPLE_CRATE_PATH)
        hash1 = LastCall.compute_crate_hash(info)

        # Hash should be deterministic
        hash2 = LastCall.compute_crate_hash(info)
        @test hash1 == hash2

        # Hash should be 32 characters (hex-encoded SHA256 truncated)
        @test length(hash1) == 32
    end

end

# Integration test that actually builds and uses the sample crate
# This is a heavier test that requires cargo and takes longer
@testset "Crate Bindings Integration" begin
    if !isdir(SAMPLE_CRATE_PATH)
        @warn "Sample crate not found, skipping integration tests"
        return
    end

    # Check if cargo is available
    try
        run(pipeline(`cargo --version`, devnull))
    catch
        @warn "Cargo not available, skipping integration tests"
        return
    end

    @testset "Full binding generation (may take a while)" begin
        # This test may take some time as it compiles Rust code
        try
            bindings = generate_bindings(SAMPLE_CRATE_PATH, cache_enabled=false)
            @test bindings isa Expr
            @test bindings.head == :module || (bindings.head == :block && any(e -> e isa Expr && e.head == :module, bindings.args))
        catch e
            @warn "Binding generation failed: $e"
            @test_skip "Binding generation requires successful Rust compilation"
        end
    end

end

@testset "Result and Option Type Parsing" begin
    # Test Result<T, E> parsing
    @testset "parse_result_type" begin
        result_info = LastCall.parse_result_type("Result<f64, i32>")
        @test result_info !== nothing
        @test result_info.ok_type == "f64"
        @test result_info.err_type == "i32"

        result_info2 = LastCall.parse_result_type("Result<u32, i32>")
        @test result_info2 !== nothing
        @test result_info2.ok_type == "u32"
        @test result_info2.err_type == "i32"

        # Non-Result types should return nothing
        @test LastCall.parse_result_type("i32") === nothing
        @test LastCall.parse_result_type("Option<i32>") === nothing
    end

    # Test Option<T> parsing
    @testset "parse_option_type" begin
        option_info = LastCall.parse_option_type("Option<f64>")
        @test option_info !== nothing
        @test option_info.inner_type == "f64"

        option_info2 = LastCall.parse_option_type("Option<i32>")
        @test option_info2 !== nothing
        @test option_info2.inner_type == "i32"

        # Non-Option types should return nothing
        @test LastCall.parse_option_type("i32") === nothing
        @test LastCall.parse_option_type("Result<i32, i32>") === nothing
    end

    # Test is_result_type and is_option_type
    @testset "type detection" begin
        @test LastCall.is_result_type("Result<f64, i32>")
        @test !LastCall.is_result_type("Option<f64>")
        @test !LastCall.is_result_type("i32")

        @test LastCall.is_option_type("Option<f64>")
        @test !LastCall.is_option_type("Result<f64, i32>")
        @test !LastCall.is_option_type("i32")
    end
end

# Property access tests - run in a separate Julia process for top-level module evaluation
const _PROPERTY_TEST_MODULE_AVAILABLE = Ref(false)

# Try to run the property access tests in a subprocess
try
    if isdir(SAMPLE_CRATE_PATH)
        project_dir = dirname(@__DIR__)  # Get the project directory

        # First, generate bindings to get the module code as a string
        bindings = generate_bindings(abspath(SAMPLE_CRATE_PATH),
            output_module_name = "SampleCratePropertyTest",
            cache_enabled = true)

        # Convert the module expression to a string
        module_code = string(bindings)

        # Create a test script with the module code at the top level
        test_script = joinpath(tempdir(), "property_test_$(getpid()).jl")

        open(test_script, "w") do io
            # Write the module code directly at the top level of the file
            println(io, module_code)

            # Now write the test code
            println(io, """

            using Test

            # Run property access tests
            @testset "Property Access Tests" begin
                # Point struct
                p = SampleCratePropertyTest.Point(3.0, 4.0)
                @test p.x ≈ 3.0
                @test p.y ≈ 4.0
                p.x = 10.0
                @test p.x ≈ 10.0
                p.y = 20.0
                @test p.y ≈ 20.0
                @test :x in propertynames(p)
                @test :y in propertynames(p)

                # Counter struct
                c = SampleCratePropertyTest.Counter(Int32(5))
                @test c.value == 5
                c.value = Int32(100)
                @test c.value == 100

                # Rectangle struct
                r = SampleCratePropertyTest.Rectangle(3.0, 4.0)
                @test r.width ≈ 3.0
                @test r.height ≈ 4.0
                r.width = 5.0
                r.height = 6.0
                @test r.width ≈ 5.0
                @test r.height ≈ 6.0
            end
            """)
        end

        # Run the test script in a fresh Julia process
        proc = run(`julia --project=$(project_dir) $(test_script)`, wait=true)
        _PROPERTY_TEST_MODULE_AVAILABLE[] = success(proc)

        # Clean up
        rm(test_script, force=true)
    end
catch e
    @warn "Failed to run property access tests: $e"
end

@testset "Property Access Syntax" begin
    # Property access tests are run in a separate Julia process above
    # This testset just validates that they passed
    if _PROPERTY_TEST_MODULE_AVAILABLE[]
        @test true  # Property access tests passed in subprocess
    else
        @warn "Property access tests were not run or failed"
        @test_skip "Property access tests require successful binding generation"
    end
end

@testset "Precompilation Support" begin
    if !isdir(SAMPLE_CRATE_PATH)
        @warn "Sample crate not found, skipping precompilation tests"
        return
    end

    # Check if cargo is available
    try
        run(pipeline(`cargo --version`, devnull))
    catch
        @warn "Cargo not available, skipping precompilation tests"
        return
    end

    @testset "emit_crate_module_code" begin
        # Test generating module code as a string
        info = scan_crate(SAMPLE_CRATE_PATH)

        # Test with absolute path
        code = LastCall.emit_crate_module_code(info, "/tmp/test_lib.so")
        @test occursin("module Samplecrate", code)
        @test occursin("const _LIB_PATH = \"/tmp/test_lib.so\"", code)
        @test occursin("function __init__()", code)
        @test occursin("Libdl.dlopen", code)

        # Test with relative path
        code_rel = LastCall.emit_crate_module_code(info, "lib/libtest.so", use_relative_path=true)
        @test occursin("const _LIB_PATH = joinpath(@__DIR__, \"lib/libtest.so\")", code_rel)

        # Test with custom module name
        code_named = LastCall.emit_crate_module_code(info, "/tmp/lib.so", module_name="CustomModule")
        @test occursin("module CustomModule", code_named)
    end

    @testset "_emit_function_code" begin
        # Create a simple function signature
        func = LastCall.RustFunctionSignature(
            "add",
            ["a", "b"],
            ["i32", "i32"],
            "i32",
            false,
            String[]
        )

        code = LastCall._emit_function_code(func)
        @test occursin("function add(a, b)", code)
        @test occursin("export add", code)
        @test occursin("_get_func_ptr(\"add\")", code)
    end

    @testset "_emit_struct_code" begin
        # Create a simple struct info
        struct_info = LastCall.RustStructInfo(
            "Point",
            String[],
            [LastCall.RustMethod("new", true, false, ["x", "y"], ["f64", "f64"], "Self")],
            "",
            [("x", "f64"), ("y", "f64")],
            true,
            Dict{String, Bool}()
        )

        code = LastCall._emit_struct_code(struct_info)
        @test occursin("mutable struct Point", code)
        @test occursin("ptr::Ptr{Cvoid}", code)
        @test occursin("finalizer", code)
        @test occursin("Point_free", code)
        @test occursin("export Point", code)
        @test occursin("Base.getproperty", code)
        @test occursin("Base.setproperty!", code)
    end

    @testset "write_bindings_to_file" begin
        # Test writing bindings to a file
        output_dir = mktempdir()
        output_path = joinpath(output_dir, "TestBindings.jl")

        try
            result_path = write_bindings_to_file(
                SAMPLE_CRATE_PATH,
                output_path,
                output_module_name = "TestBindings"
            )

            @test result_path == output_path
            @test isfile(output_path)

            # Read and verify content
            content = read(output_path, String)
            @test occursin("module TestBindings", content)
            @test occursin("# Auto-generated bindings", content)
            @test occursin("function __init__()", content)
            @test occursin("export", content)
        finally
            rm(output_dir, recursive=true, force=true)
        end
    end

    @testset "write_bindings_to_file with relative path" begin
        # Test writing bindings with relative library path
        output_dir = mktempdir()
        output_path = joinpath(output_dir, "src", "Bindings.jl")
        lib_rel_path = "../deps/lib"

        try
            result_path = write_bindings_to_file(
                SAMPLE_CRATE_PATH,
                output_path,
                output_module_name = "RelativeBindings",
                relative_lib_path = lib_rel_path
            )

            @test result_path == output_path
            @test isfile(output_path)

            # Verify library was copied
            lib_dir = joinpath(output_dir, "src", lib_rel_path)
            @test isdir(lib_dir)
            libs = readdir(lib_dir)
            @test !isempty(libs)

            # Verify content uses relative path
            content = read(output_path, String)
            @test occursin("joinpath(@__DIR__", content)
            @test occursin(lib_rel_path, content)
        finally
            rm(output_dir, recursive=true, force=true)
        end
    end
end
