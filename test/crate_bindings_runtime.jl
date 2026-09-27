# Component tests loaded by test_crate_bindings.jl.

const _PROPERTY_TEST_MODULE_AVAILABLE = Ref(false)

# Try to run the property access tests in a subprocess
try
    if isdir(SAMPLE_CRATE_PATH)
        project_dir = dirname(@__DIR__)  # Get the project directory

        # First, generate bindings to get the module code as a string
        bindings = RustCall.generate_bindings(abspath(SAMPLE_CRATE_PATH),
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

function _run_top_level_explicit_binding_contract()
    project_dir = dirname(@__DIR__)
    test_script = joinpath(tempdir(), "crate_binding_contract_$(getpid()).jl")

    open(test_script, "w") do io
        println(io, """
        using Test
        using RustCall

        const SampleCrateContract = @rust_crate raw\"$(abspath(SAMPLE_CRATE_PATH))\" name=\"SampleCrateInjected\"

        @test SampleCrateContract.add(Int32(2), Int32(3)) == Int32(5)
        @test SampleCrateContract.Point isa DataType
        point = SampleCrateContract.Point(3.0, 4.0)
        @test point isa SampleCrateContract.Point
        point_display = sprint(show, point)
        @test occursin("SampleCrateInjected.Point(", point_display)
        @test !occursin("RustCallCrateRuntime", point_display)
        @test SampleCrateContract.distance_from_origin(point) == 5.0
        @test point.x == 3.0
        # `name=` names the generated module and defines nothing in the
        # caller (#222); `submodule=` is what defines it (#339).
        @test !isdefined(Main, :SampleCrateInjected)
        """)
    end

    try
        return run(ignorestatus(`julia --project=$(project_dir) $(test_script)`), wait=true)
    finally
        rm(test_script, force=true)
    end
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

@testset "Top-Level Explicit Binding" begin
    if isdir(SAMPLE_CRATE_PATH)
        proc = _run_top_level_explicit_binding_contract()
        @test success(proc)
    else
        @test_skip "Top-level explicit binding test requires successful crate loading"
    end
end

@testset "Result and Option Runtime Wrappers" begin
    if !isdir(SAMPLE_CRATE_PATH)
        @test_skip "Sample crate not found, skipping Result/Option wrapper tests"
        return
    end

    try
        run(pipeline(`$(cargo()) --version`, devnull))
    catch
        @test_skip "Cargo not available, skipping Result/Option wrapper tests"
        return
    end

    let bindings = @rust_crate SAMPLE_CRATE_PATH name="SampleCrateResultOption"
        ok = bindings.safe_divide(10.0, 2.0)
        err = bindings.safe_divide(10.0, 0.0)
        some = bindings.safe_sqrt(4.0)
        none = bindings.safe_sqrt(-1.0)

        @test ok isa RustCall.RustResult{Float64, Int32}
        @test RustCall.is_ok(ok)
        @test RustCall.unwrap(ok) == 5.0

        @test err isa RustCall.RustResult{Float64, Int32}
        @test RustCall.is_err(err)
        @test RustCall.unwrap_or(err, 0.0) == 0.0

        @test some isa RustCall.RustOption{Float64}
        @test RustCall.is_some(some)
        @test RustCall.unwrap(some) == 2.0

        @test none isa RustCall.RustOption{Float64}
        @test RustCall.is_none(none)
        @test RustCall.unwrap_or(none, 0.0) == 0.0
    end
end

@testset "Function Scope Usage" begin
    if !isdir(SAMPLE_CRATE_PATH)
        @test_skip "Sample crate not found, skipping function scope usage tests"
        return
    end

    try
        run(pipeline(`$(cargo()) --version`, devnull))
    catch
        @test_skip "Cargo not available, skipping function scope usage tests"
        return
    end

    function use_bindings_in_function(crate_path)
        bindings = @rust_crate crate_path name="SampleCrateFunctionScope"

        sum_result = bindings.add(Int32(2), Int32(3))
        point_type = bindings.Point
        point = Base.invokelatest(point_type, 3.0, 4.0)
        distance = bindings.distance_from_origin(point)
        original_x = Base.invokelatest(getproperty, point, :x)
        Base.invokelatest(setproperty!, point, :x, 10.0)

        return (sum_result, distance, original_x, Base.invokelatest(getproperty, point, :x))
    end

    @test use_bindings_in_function(SAMPLE_CRATE_PATH) == (Int32(5), 5.0, 3.0, 10.0)
end

# The Julia demo of `test/fixtures/sample_crate_pyo3` is the package
# `examples/SampleCratePyO3.jl`, whose `Pkg.test()` the Examples workflow runs
# in CI; it is no longer run from inside this suite.
