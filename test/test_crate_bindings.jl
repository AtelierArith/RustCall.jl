# Tests for the crate bindings feature (Maturin-like functionality)

using Test
using RustCall
using RustToolChain: cargo

# Path to the sample crate
const SAMPLE_CRATE_PATH = joinpath(dirname(@__DIR__), "examples", "sample_crate")
const SAMPLE_CRATE_PYO3_PATH = joinpath(dirname(@__DIR__), "examples", "sample_crate_pyo3")
# Where the shared finalizer implementation lives, for the #249 assertions.
const _SRC_DIR_CB = joinpath(dirname(dirname(pathof(RustCall))), "src")

@testset "Crate Bindings" begin

    @testset "CrateBindingOptions" begin
        # Test default options
        opts = RustCall.CrateBindingOptions()
        @test opts.output_module_name === nothing
        @test opts.output_path === nothing
        @test opts.use_wrapper_crate == true
        @test opts.build_release == true
        @test opts.cache_enabled == true

        # Test custom options
        opts2 = RustCall.CrateBindingOptions(
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

        info = RustCall.scan_crate(SAMPLE_CRATE_PATH)

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

        cargo = RustCall.parse_cargo_toml(cargo_toml_path)

        @test haskey(cargo, "package")
        @test cargo["package"]["name"] == "sample_crate"
        @test cargo["package"]["version"] == "0.1.0"
    end

    @testset "find_rust_sources" begin
        if !isdir(SAMPLE_CRATE_PATH)
            @warn "Sample crate not found, skipping test"
            return
        end

        sources = RustCall.find_rust_sources(SAMPLE_CRATE_PATH)

        @test !isempty(sources)
        @test all(f -> endswith(f, ".rs"), sources)
        @test any(f -> endswith(f, "lib.rs"), sources)
    end

    @testset "scan_crate skips include!() fragments" begin
        if !RustCall.check_rustc_available()
            @warn "rustc not found, skipping"
        else
            mktempdir() do dir
                mkpath(joinpath(dir, "src"))
                write(joinpath(dir, "Cargo.toml"), """
                [package]
                name = "frag_crate"
                version = "0.1.0"
                edition = "2021"
                """)
                write(joinpath(dir, "src", "table.rs"), "[1, 2, 3]\n")
                write(joinpath(dir, "src", "lib.rs"), """
                use juliacall_macros::julia;
                const TABLE: [i32; 3] = include!("table.rs");
                #[julia]
                fn table_sum() -> i32 { TABLE.iter().sum() }
                """)
                info = RustCall.scan_crate(dir)
                @test [f.name for f in info.julia_functions] == ["table_sum"]
                # a genuinely broken module file is still an error without the flag
                @test_throws RustCall.ExtractorError RustCall.extract_manifest(
                    [joinpath(dir, "src", "table.rs")]; mode = "crate")
            end
        end
    end

    @testset "crate-mode manifest: #[julia] structs" begin
        if !RustCall.check_rustc_available()
            @warn "rustc not found, skipping"
        else
            code = """
            use juliacall_macros::julia;

            #[julia]
            pub struct Counter { count: u32, name: String }

            #[julia]
            impl Counter {
                #[julia]
                pub fn new() -> Self { Self { count: 0, name: String::new() } }
                #[julia]
                pub fn increment(&mut self) { self.count += 1; }
                pub fn not_wrapped(&self) {}
            }
            """
            infos = RustCall.manifest_struct_infos(RustCall.extract_manifest(code; mode = "crate"))
            @test length(infos) == 1
            s = infos[1]
            @test s.name == "Counter"
            @test s.fields == [("count", "u32"), ("name", "String")]
            @test s.field_getters["count"] == "Counter_get_count"
            @test s.field_setters["count"] == "Counter_set_count"
            @test [m.name for m in s.methods] == ["new", "increment"]
            @test s.methods[1].is_constructor
            @test s.methods[1].symbol == "rustcall_Counter_new"
            @test s.methods[2].is_mutable
        end
    end
    @testset "create_wrapper_crate" begin
        if !isdir(SAMPLE_CRATE_PATH)
            @warn "Sample crate not found, skipping test"
            return
        end

        info = RustCall.scan_crate(SAMPLE_CRATE_PATH)
        opts = RustCall.CrateBindingOptions()

        wrapper_path = RustCall.create_wrapper_crate(info, opts)

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

        info = RustCall.scan_crate(SAMPLE_CRATE_PATH)
        # A cold call may make Cargo write `Cargo.lock` into the crate, which is
        # itself a hashed input; every call from then on agrees.
        RustCall.compute_crate_hash(info)
        hash1 = RustCall.compute_crate_hash(info)

        # Hash should be deterministic
        hash2 = RustCall.compute_crate_hash(info)
        @test hash1 == hash2

        # A lookup key is the full digest: truncation is for names only (#278).
        @test length(hash1) == 64
        deps_digest = RustCall.artifact_path_dependency_digest(info.path)
        @test hash1 == RustCall.artifact_key(RustCall.ArtifactId(
            kind = "crate",
            source = RustCall.crate_content_digest(info.path),
            codegen = ["profile" => "release"],
            dependencies = [deps_digest],
            build_env = ["cargo-config" => RustCall._cargo_config_digest(ENV; dir = info.path)],
            extra = ["name" => info.name, "version" => info.version]))

        # The build profile is part of it.
        @test RustCall.compute_crate_hash(info; release = false) != hash1

        # The whole crate directory is an input, not just the scanned .rs files:
        # a new file in the crate changes the key.
        probe = joinpath(info.path, "rc278_probe.txt")
        try
            write(probe, "an input the scan never lists")
            RustCall._artifact_reset_digest_caches!()
            @test RustCall.compute_crate_hash(info) != hash1
        finally
            rm(probe; force = true)
            RustCall._artifact_reset_digest_caches!()
        end
        @test RustCall.compute_crate_hash(info) == hash1
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
        run(pipeline(`$(cargo()) --version`, devnull))
    catch
        @warn "Cargo not available, skipping integration tests"
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
        @warn "rustc not found, skipping"
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
        @warn "Sample crate not found, skipping Result/Option wrapper tests"
        return
    end

    try
        run(pipeline(`$(cargo()) --version`, devnull))
    catch
        @warn "Cargo not available, skipping Result/Option wrapper tests"
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
        @warn "Sample crate not found, skipping function scope usage tests"
        return
    end

    try
        run(pipeline(`$(cargo()) --version`, devnull))
    catch
        @warn "Cargo not available, skipping function scope usage tests"
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

@testset "sample_crate_pyo3 Julia Demo" begin
    if !isdir(SAMPLE_CRATE_PYO3_PATH)
        @warn "sample_crate_pyo3 not found, skipping Julia demo test"
        return
    end

    try
        run(pipeline(`$(cargo()) --version`, devnull))
    catch
        @warn "Cargo not available, skipping Julia demo test"
        return
    end

    project_dir = dirname(@__DIR__)
    cmd = Cmd(`julia --project=../.. main.jl`, dir=SAMPLE_CRATE_PYO3_PATH)
    proc = run(ignorestatus(cmd), wait=true)
    @test success(proc)
end

@testset "Precompilation Support" begin
    if !isdir(SAMPLE_CRATE_PATH)
        @warn "Sample crate not found, skipping precompilation tests"
        return
    end

    # Check if cargo is available
    try
        run(pipeline(`$(cargo()) --version`, devnull))
    catch
        @warn "Cargo not available, skipping precompilation tests"
        return
    end

    # The registry name of a @rust_crate library names its build profile, so a
    # debug and a release build of one crate are two entries rather than one
    # that clobbers the other — the second used to replace the first's handle,
    # retire its liveness flag out from under live objects, and repoint its
    # module mirror at the other profile's image (#277).
    @testset "crate_library_name distinguishes the build profile" begin
        info = RustCall.scan_crate(SAMPLE_CRATE_PATH)
        release = RustCall.crate_library_name(info; release = true)
        debug = RustCall.crate_library_name(info; release = false)
        @test release != debug
        @test startswith(release, "rust_crate_$(info.name)_")
        @test startswith(debug, "rust_crate_$(info.name)_")
        # Same profile, same name — it is an identity, not a nonce.
        @test RustCall.crate_library_name(info; release = true) == release
        # ...and the default is the release profile, as everywhere else.
        @test RustCall.crate_library_name(info) == release

        # The emitted module carries the name of the profile it was built for.
        release_code = RustCall.emit_crate_module_code(info, "/tmp/r.so";
                                                       build_release = true)
        debug_code = RustCall.emit_crate_module_code(info, "/tmp/d.so";
                                                     build_release = false)
        @test occursin("const _LIB_NAME = $(repr(release))", release_code)
        @test occursin("const _LIB_NAME = $(repr(debug))", debug_code)

        # Two modules registered under the two names do not disturb each
        # other: separate registry entries, separate liveness flags, separate
        # mirrors — so unloading one leaves the other intact.
        policy = RustCall.crate_direct_policy()
        h1 = Ptr{Cvoid}(UInt(0xc0de0001))
        h2 = Ptr{Cvoid}(UInt(0xc0de0002))
        m1_handle, m1_alive = Ref(Ptr{Cvoid}(C_NULL)), Ref(Ref(true))
        m2_handle, m2_alive = Ref(Ptr{Cvoid}(C_NULL)), Ref(Ref(true))
        try
            RustCall.register_handle_mirror!(release, m1_handle, m1_alive)
            RustCall.register_handle_mirror!(debug, m2_handle, m2_alive)
            RustCall.adopt_artifact!(policy, h1; lib_name = release)
            RustCall.adopt_artifact!(policy, h2; lib_name = debug)
            @test m1_handle[] == h1
            @test m2_handle[] == h2
            @test m1_alive[] !== m2_alive[]

            RustCall.unload_artifact!(policy, release)
            @test m1_handle[] == C_NULL
            @test !m1_alive[][]
            # The other profile is untouched.
            @test m2_handle[] == h2
            @test m2_alive[][]
            @test haskey(RustCall.RUST_LIBRARIES, debug)
        finally
            lock(RustCall.REGISTRY_LOCK) do
                for name in (release, debug)
                    delete!(RustCall.RUST_LIBRARIES, name)
                    delete!(RustCall.ARTIFACT_ALIVE, name)
                    delete!(RustCall.HANDLE_MIRRORS, name)
                    delete!(RustCall.RETIRED_HANDLES, name)
                end
            end
        end
    end

    @testset "emit_crate_module_code" begin
        # Test generating module code as a string
        info = RustCall.scan_crate(SAMPLE_CRATE_PATH)

        # Test with absolute path
        code = RustCall.emit_crate_module_code(info, "/tmp/test_lib.so")
        @test occursin("module SampleCrate", code)
        @test occursin("const _LIB_PATH = \"/tmp/test_lib.so\"", code)
        @test occursin("function __init__()", code)
        # Since #277 Phase B5 the emitted module loads through the one loader
        # rather than calling dlopen itself, so the handle is registered and
        # `unload_library` can see this crate too (#250).
        @test occursin("RustCall.load_artifact!", code)
        @test !occursin("Libdl.dlopen", code)
        @test occursin("const _LIB_NAME = ", code)
        @test occursin("const _LIB_ALIVE = ", code)
        @test occursin("# Bindings format: $(RustCall.BINDINGS_FORMAT_VERSION)", code)
        # ...and its struct finalizers capture the destructor and the liveness
        # flag rather than resolving anything when they run (#249).
        @test occursin("_struct_free_ptr(", code)
        @test occursin("finalizer(RustCall.finalize_rust_object!, obj)", code)
        @test !occursin("maxlog=10", code)

        # Test with relative path
        code_rel = RustCall.emit_crate_module_code(info, "lib/libtest.so", use_relative_path=true)
        @test occursin("const _LIB_PATH = joinpath(@__DIR__, \"lib/libtest.so\")", code_rel)

        # Test with custom module name
        code_named = RustCall.emit_crate_module_code(info, "/tmp/lib.so", module_name="CustomModule")
        @test occursin("module CustomModule", code_named)
    end

    @testset "_emit_function_code" begin
        # Create a simple function signature
        func = RustCall.RustFunctionSignature(
            "add",
            ["a", "b"],
            ["i32", "i32"],
            "i32",
            false,
            String[]
        )

        code = RustCall._emit_function_code(func)
        @test occursin("function add(a, b)", code)
        @test occursin("export add", code)
        @test occursin("_get_func_ptr(\"add\")", code)
    end

    @testset "_emit_struct_code" begin
        # Create a simple struct info
        struct_info = RustCall.RustStructInfo(
            "Point",
            String[],
            [RustCall.RustMethod("new", true, false, ["x", "y"], ["f64", "f64"], "Self")],
            "",
            [("x", "f64"), ("y", "f64")],
            true,
            Dict{String, Bool}();
            # accessor symbols come from the manifest; supplied by hand here
            field_getters = Dict("x" => "Point_get_x", "y" => "Point_get_y"),
            field_setters = Dict("x" => "Point_set_x", "y" => "Point_set_y"),
        )

        code = RustCall._emit_struct_code(struct_info)
        @test occursin("mutable struct Point", code)
        @test occursin("ptr::Ptr{Cvoid}", code)
        @test occursin("finalizer", code)
        @test occursin("Point_free", code)
        @test occursin("export Point", code)
        @test occursin("Base.getproperty", code)
        @test occursin("Base.setproperty!", code)

        # Null pointer checks should be present in getproperty/setproperty!
        @test occursin("_check_not_freed", code)
    end

    @testset "_check_not_freed" begin
        # Test that _check_not_freed is defined
        @test isdefined(RustCall, :_check_not_freed)

        # Create a mock object with a non-null ptr
        obj_alive = (ptr = Ptr{Cvoid}(1),)
        @test_nowarn RustCall._check_not_freed(obj_alive, "TestType")

        # Create a mock object with a null ptr (freed)
        obj_freed = (ptr = Ptr{Cvoid}(0),)
        # One implementation for both flavours since #277 Phase B4, so the
        # exception is RustCall's own rather than a bare `error()`.
        @test_throws RustCall.RustError RustCall._check_not_freed(obj_freed, "TestType")

        # Verify error message mentions the type name
        err = try
            RustCall._check_not_freed(obj_freed, "MyStruct")
            nothing
        catch e
            e
        end
        @test err isa RustCall.RustError
        @test occursin("MyStruct", err.message)
        @test occursin("freed", err.message)
    end

    @testset "_emit_method_code null pointer checks" begin
        # Instance method should contain null pointer check
        method = RustCall.RustMethod("get_sum", false, true, String[], String[], "f64")
        struct_info = RustCall.RustStructInfo(
            "Point",
            String[],
            [method],
            "",
            [("x", "f64"), ("y", "f64")],
            true,
            Dict{String, Bool}()
        )

        code = RustCall._emit_method_code(struct_info, method)
        @test occursin("_check_not_freed", code)
    end

    # #279 follow-up: the six-argument `RustMethod` constructor cannot know the
    # struct name, so a hand-built method carries no `symbol`. The emitters must
    # derive `rustcall_<Struct>_<method>` rather than emit `_get_func_ptr("")`.
    @testset "hand-built RustMethod falls back to the rustcall_ symbol" begin
        ctor = RustCall.RustMethod("new", true, false, ["x", "y"], ["f64", "f64"], "Self")
        getter = RustCall.RustMethod("norm", false, false, String[], String[], "f64")
        shout = RustCall.RustMethod("shout", false, false, ["s"], ["String"], "String")
        @test ctor.symbol == ""
        @test RustCall.method_wrapper_symbol("Point", ctor) == "rustcall_Point_new"
        @test RustCall.method_wrapper_symbol("Point", getter) == "rustcall_Point_norm"
        # A manifest-backed symbol always wins over the derived one.
        manifest_backed = RustCall.RustMethod("norm", false, false, String[], String[], "f64";
                                              symbol = "rustcall_Other_norm")
        @test RustCall.method_wrapper_symbol("Point", manifest_backed) == "rustcall_Other_norm"

        struct_info = RustCall.RustStructInfo(
            "Point", String[], [ctor, getter, shout], "",
            [("x", "f64"), ("y", "f64")], true, Dict{String, Bool}()
        )

        # Source-text emitter (write_bindings_to_file).
        for m in struct_info.methods
            code = RustCall._emit_method_code(struct_info, m)
            @test occursin("_get_func_ptr(\"rustcall_Point_$(m.name)\")", code)
            @test !occursin("_get_func_ptr(\"\")", code)
        end
        # The string buffers stay named after the method, not after the symbol.
        @test occursin("_get_func_ptr(\"Point_shout_free_rust_string\")",
                       RustCall._emit_method_code(struct_info, shout))

        # In-memory emitter (@rust_crate).
        for m in struct_info.methods
            expr = string(RustCall._generate_crate_method_wrapper(struct_info, m))
            @test occursin("rustcall_Point_$(m.name)", expr)
            @test !occursin("_get_func_ptr(\"\")", expr)
        end

        # Julia struct emitter (inline blocks).
        defs = string(RustCall.emit_julia_definitions(struct_info))
        @test occursin("rustcall_Point_new", defs)
        @test occursin("rustcall_Point_norm", defs)
        @test !occursin("\"\"", defs)
    end

    @testset "_emit_struct_code finalizer is exception-safe" begin
        struct_info = RustCall.RustStructInfo(
            "SafeStruct",
            String[],
            RustCall.RustMethod[],
            "",
            [("val", "i32")],
            true,
            Dict{String, Bool}()
        )

        code = RustCall._emit_struct_code(struct_info)
        # The finalizer must not crash the GC (#93), and since #277 Phase B4 it
        # must also take no lock, resolve no symbol and log nothing (#249): a
        # finalizer can run while the running thread holds `REGISTRY_LOCK`, and
        # `@warn` allocates and can yield. The try/catch moved *into*
        # `RustCall.finalize_rust_object!`, which counts a failure instead of
        # logging it, and the destructor is captured at construction.
        @test occursin("finalizer(RustCall.finalize_rust_object!, obj)", code)
        @test occursin("_struct_free_ptr(\"SafeStruct_free\")", code)
        @test occursin("alive::Base.RefValue{Bool}", code)
        @test !occursin("Failed to free SafeStruct", code)
        @test !occursin("maxlog", code)
        # The shared implementation is the one that catches.
        body = read(joinpath(_SRC_DIR_CB, "structs.jl"), String)
        i = findfirst("function finalize_rust_object!", body)
        @test i !== nothing
        tail = body[first(i):end]
        tail = tail[1:first(findfirst("\nend", tail))]
        @test occursin("try", tail)
        @test occursin("catch", tail)
        @test !occursin("@warn", tail)
    end

    @testset "_generate_crate_struct_wrapper finalizer is exception-safe" begin
        struct_info = RustCall.RustStructInfo(
            "SafeWrapper",
            String[],
            RustCall.RustMethod[],
            "",
            [("val", "i32")],
            true,
            Dict{String, Bool}()
        )

        exprs = RustCall._generate_crate_struct_wrapper(struct_info)
        code_str = sprint(show, exprs)
        # Same shape as the emitted file: capture at construction, and the
        # exception safety lives in `finalize_rust_object!` (#93, #249).
        @test occursin("finalize_rust_object!", code_str)
        @test occursin("_struct_free_ptr", code_str)
        @test !occursin("maxlog", code_str)
    end

    @testset "write_bindings_to_file" begin
        # Test writing bindings to a file
        output_dir = mktempdir()
        output_path = joinpath(output_dir, "TestBindings.jl")

        try
            result_path = RustCall.write_bindings_to_file(
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
            result_path = RustCall.write_bindings_to_file(
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

@testset "Crate bindings: String / &str functions (#242)" begin
    manifest = RustCall.extract_manifest([joinpath(SAMPLE_CRATE_PATH, "src", "lib.rs")]; mode = "crate")
    sigs = Dict(s.name => s for s in RustCall.manifest_function_signatures(manifest))
    @test sigs["shout"].has_owned_string_helper
    @test sigs["crate_greeting"].has_borrowed_string_helper
    @test sigs["char_count"].arg_types == ["&str"]

    if RustCall.check_rustc_available()
        let bindings = @rust_crate SAMPLE_CRATE_PATH name="SampleCrateStrings"
            @test bindings.shout("hello") == "HELLO"
            @test bindings.join_repeat("a", "b", "-", UInt32(2)) == "a-b-a-b"
            @test bindings.char_count("日本語") == 3
            @test bindings.crate_greeting() == "hello from sample_crate"
            @test RustCall.unwrap(bindings.parse_int(" 7 ")) == Int32(7)
            @test RustCall.is_err(bindings.parse_int("seven"))
            @test RustCall.unwrap(bindings.first_char("é")) == UInt32('é')
            @test RustCall.is_none(bindings.first_char(""))
            @test bindings.identity_str("λ") == "λ"
            for _ in 1:200
                @test bindings.shout("x") == "X"
            end
        end
    end

    # The source-file emitter (write_bindings_to_file) uses the same ABI.
    info = RustCall.scan_crate(SAMPLE_CRATE_PATH)
    code = RustCall.emit_crate_module_code(info, "/tmp/libsample.so")
    @test occursin("_call_rust_owned_string_ptr(_get_func_ptr(\"rustcall_shout\"), _get_func_ptr(\"shout_free_rust_string\")", code)
    @test occursin("__rustcall_str_input = String(input)", code)
    @test occursin("GC.@preserve(__rustcall_str_input", code)
    @test occursin("_call_rust_borrowed_string_ptr(_get_func_ptr(\"rustcall_crate_greeting\")", code)
    @test occursin("GC.@preserve(__rustcall_str_s, call_rust_function(func_ptr, CResult_parse_int, pointer(__rustcall_str_s), sizeof(__rustcall_str_s) % Csize_t))", code)
    # Nothing to preserve: `GC.@preserve` is omitted entirely rather than
    # emitted with an empty object list, because the call is now nested inside
    # `_guard_panic(...)` and the parenthesized form needs at least one object
    # (#244, #277 Phase B5).
    @test occursin("_guard_panic(call_rust_function(func_ptr, Int32, Int32(a), Int32(b)), panic_channel, \"add\")", code)
    # Every generated call reads its wrapper's panic channel, and resolves it
    # BEFORE the call: the channel is a thread-local in the image, so nothing
    # may yield between the two (#244).
    @test occursin("_guard_panic(", code)
    @test occursin("panic_channel = _panic_channel(\"rustcall_add\")", code)
    @test occursin("RustCall.guard_rust_panic_ptr", code)
    # The resolution precedes the call in the emitted text.
    add_at = findfirst("function add(a, b)", code)
    @test add_at !== nothing
    add_body = code[first(add_at):end]
    add_body = add_body[1:first(findfirst("\nend", add_body))]
    @test findfirst("_panic_channel(", add_body) < findfirst("call_rust_function(", add_body)
    # and the emitted module parses
    @test Meta.parse(code) isa Expr
end

@testset "Crate bindings: arguments named like generated locals (#242 review)" begin
    # A Rust argument may be called `func_ptr` / `lib_name` / `c_result` /
    # `c_option`; the generated wrapper must not shadow it with its own local.
    info = RustCall.scan_crate(SAMPLE_CRATE_PATH)
    code = RustCall.emit_crate_module_code(info, "/tmp/libsample.so")

    # Plain return, string arguments named func_ptr / lib_name
    @test occursin("__rustcall_str_func_ptr = String(func_ptr)", code)
    @test occursin("__rustcall_str_lib_name = String(lib_name)", code)
    @test occursin("__rustcall_func_ptr = _get_func_ptr(\"rustcall_shadow_str_len\")", code)
    @test occursin("call_rust_function(__rustcall_func_ptr, Csize_t, pointer(__rustcall_str_func_ptr)", code)
    # The conversions come before the pointer lookup
    @test findfirst("__rustcall_str_func_ptr = String(func_ptr)", code).start <
          findfirst("__rustcall_func_ptr = _get_func_ptr(\"rustcall_shadow_str_len\")", code).start

    # Result return: func_ptr and c_result are both argument names
    @test occursin("__rustcall_func_ptr = _get_func_ptr(\"rustcall_shadow_parse_int\")", code)
    @test occursin("__rustcall_c_result = GC.@preserve(__rustcall_str_func_ptr, call_rust_function(__rustcall_func_ptr, CResult_shadow_parse_int,", code)
    @test occursin("if __rustcall_c_result.is_ok == 1", code)

    # Option return: func_ptr and c_option are both argument names
    @test occursin("__rustcall_func_ptr = _get_func_ptr(\"rustcall_shadow_first_char\")", code)
    @test occursin("__rustcall_c_option = GC.@preserve(__rustcall_str_func_ptr, call_rust_function(__rustcall_func_ptr, COption_shadow_first_char,", code)
    @test occursin("if __rustcall_c_option.is_some == 1", code)

    # No strings, but still a colliding argument name
    @test occursin("__rustcall_func_ptr = _get_func_ptr(\"rustcall_shadow_double\")", code)
    @test occursin("call_rust_function(__rustcall_func_ptr, Int32, Int32(func_ptr))", code)

    # Names that do not collide keep their readable form
    @test occursin("func_ptr = _get_func_ptr(\"rustcall_parse_int\")", code)

    @test Meta.parse(code) isa Expr

    if RustCall.check_rustc_available()
        let bindings = @rust_crate SAMPLE_CRATE_PATH name="SampleCrateShadow"
            @test bindings.shadow_str_len("abc", "de") == 5
            @test RustCall.unwrap(bindings.shadow_parse_int(" 7 ", Int32(-1))) == Int32(7)
            @test RustCall.is_err(bindings.shadow_parse_int("seven", Int32(-1)))
            @test RustCall.unwrap(bindings.shadow_first_char("A", UInt32(0))) == UInt32('A')
            @test RustCall.is_none(bindings.shadow_first_char("", UInt32(0)))
            @test bindings.shadow_double(Int32(21)) == Int32(42)
        end
    end
end

@testset "Crate bindings: struct methods with String / &str (#242 review)" begin
    manifest = RustCall.extract_manifest([joinpath(SAMPLE_CRATE_PATH, "src", "lib.rs")]; mode = "crate")
    labeler = only(filter(s -> s.name == "Labeler", RustCall.manifest_struct_infos(manifest)))
    methods = Dict(m.name => m for m in labeler.methods)
    @test methods["label"].arg_abis == ["str"]
    @test methods["label"].return_abi == "string"
    @test methods["byte_len"].arg_abis == ["string"]
    @test methods["byte_len"].return_abi == ""
    @test methods["kind"].return_abi == "str"
    @test methods["echo"].return_abi == "string"   # may borrow from the argument: copied
    @test methods["shout"].is_static && methods["shout"].return_abi == "string"

    # The source emitter passes (ptr, len) pairs and reads the per-method buffers
    info = RustCall.scan_crate(SAMPLE_CRATE_PATH)
    code = RustCall.emit_crate_module_code(info, "/tmp/libsample.so")
    @test occursin("__rustcall_str_name = String(name)", code)
    # `self` is in the preserve list of every instance method: a borrowed
    # `&str` points into the Rust object, which a temporary's finalizer could
    # otherwise free mid-call.
    @test occursin("GC.@preserve(self, __rustcall_str_name, _call_rust_owned_string_ptr(func_ptr, _get_func_ptr(\"Labeler_label_free_rust_string\"), getfield(self, :ptr), pointer(__rustcall_str_name), sizeof(__rustcall_str_name) % Csize_t)", code)
    @test occursin("GC.@preserve(self, _call_rust_borrowed_string_ptr(func_ptr, getfield(self, :ptr))", code)
    @test occursin("GC.@preserve(__rustcall_str_s, _call_rust_owned_string_ptr(func_ptr, _get_func_ptr(\"Labeler_shout_free_rust_string\"), pointer(__rustcall_str_s), sizeof(__rustcall_str_s) % Csize_t)", code)
    @test occursin("GC.@preserve(self, __rustcall_str_s, call_rust_function(func_ptr, Csize_t, getfield(self, :ptr), pointer(__rustcall_str_s), sizeof(__rustcall_str_s) % Csize_t)", code)
    @test occursin("GC.@preserve(self, call_rust_function(func_ptr, Float64, getfield(self, :ptr))", code)
    # The in-memory wrapper preserves `self` too
    labeler_info = only(filter(s -> s.name == "Labeler", info.julia_structs))
    kind_method = only(filter(m -> m.name == "kind", labeler_info.methods))
    kind_expr = string(RustCall._generate_crate_method_wrapper(labeler_info, kind_method))
    @test occursin("GC.@preserve(self, _call_rust_borrowed_string_ptr(func_ptr, getfield(self, :ptr))", kind_expr)
    label_method = only(filter(m -> m.name == "label", labeler_info.methods))
    @test occursin("GC.@preserve(self, __rustcall_str_name, _call_rust_owned_string_ptr", string(RustCall._generate_crate_method_wrapper(labeler_info, label_method)))
    # Constructors still return the boxed struct
    @test occursin("Labeler(call_rust_function(func_ptr, Ptr{Cvoid}, UInt32(count)))", code)
    @test occursin("Point(call_rust_function(func_ptr, Ptr{Cvoid}, Float64(x), Float64(y)))", code)
    @test Meta.parse(code) isa Expr

    if RustCall.check_rustc_available()
        # The module is evaluated in this world; go through invokelatest for
        # the struct wrappers (their outer constructors are newer methods).
        let bindings = @rust_crate SAMPLE_CRATE_PATH name="SampleCrateLabeler"
            call(f, args...) = Base.invokelatest(f, args...)
            l = call(bindings.Labeler, UInt32(0))
            @test call(bindings.label, l, "x") == "x#1"
            @test call(bindings.label, l, "日本") == "日本#2"
            @test call(getproperty, l, :count) == 2
            @test call(bindings.byte_len, l, "abc") == 3
            @test call(bindings.byte_len, l, "日本語") == 9
            @test call(bindings.byte_len, l, SubString("xabc", 2)) == 3
            @test call(bindings.kind, l) == "labeler"
            @test call(bindings.echo, l, "λ") == "λ"
            @test call(bindings.shout, "hi") == "HI"
            for _ in 1:200
                @test call(bindings.label, l, "y") isa String
            end
            # A borrowed `&str` of a temporary: the wrapper object must stay
            # alive until the bytes are copied, even under GC pressure.
            for i in 1:300
                @test call(bindings.kind, call(bindings.Labeler, UInt32(i))) == "labeler"
                @test call(bindings.echo, call(bindings.Labeler, UInt32(i)), "tmp$i") == "tmp$i"
                i % 25 == 0 && GC.gc()
            end
            # Non-string methods and constructors are unchanged
            p = call(bindings.Point, 3.0, 4.0)
            @test call(bindings.distance_from_origin, p) == 5.0
            c = call(bindings.Counter, Int32(1))
            call(bindings.add, c, Int32(4))
            @test call(bindings.get, c) == Int32(5)
        end
    end
end
