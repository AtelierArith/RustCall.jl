# Component tests loaded by test_crate_bindings.jl.

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
            @test_skip "Sample crate not found, skipping scan_crate tests"
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
            @test_skip "Cargo.toml not found, skipping test"
            return
        end

        cargo = RustCall.parse_cargo_toml(cargo_toml_path)

        @test haskey(cargo, "package")
        @test cargo["package"]["name"] == "sample_crate"
        @test cargo["package"]["version"] == "0.1.0"
    end

    @testset "find_rust_sources" begin
        if !isdir(SAMPLE_CRATE_PATH)
            @test_skip "Sample crate not found, skipping test"
            return
        end

        sources = RustCall.find_rust_sources(SAMPLE_CRATE_PATH)

        @test !isempty(sources)
        @test all(f -> endswith(f, ".rs"), sources)
        @test any(f -> endswith(f, "lib.rs"), sources)
    end

    @testset "scan_crate skips include!() fragments" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc not found, skipping"
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
                use rustcall_julia_macros::julia;
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
            @test_skip "rustc not found, skipping"
        else
            code = """
            use rustcall_julia_macros::julia;

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
            @test_skip "Sample crate not found, skipping test"
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
            @test_skip "Sample crate not found, skipping test"
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
        # The feature set is in the key of every kind, the plain build's
        # included — a `--no-default-features` build is a different binary
        # from the default one (#307 review).
        @test hash1 == RustCall.artifact_key(RustCall.ArtifactId(
            kind = "crate",
            source = RustCall.crate_content_digest(info.path),
            codegen = ["profile" => "release", "features" => "", "default-features" => "true"],
            dependencies = [deps_digest],
            build_env = ["cargo-config" => RustCall._cargo_config_digest(ENV; dir = info.path)],
            extra = ["name" => info.name, "version" => info.version]))

        # The build profile is part of it.
        @test RustCall.compute_crate_hash(info; release = false) != hash1

        # The whole crate directory is an input, not just the scanned .rs files:
        # a new file in the crate changes the key. Never mutate the shared
        # sample: another worker's precompile image tracks its directory, so
        # even a temporary probe can invalidate an otherwise unchanged image.
        mktempdir() do dir
            mkpath(joinpath(dir, "src"))
            write(joinpath(dir, "Cargo.toml"), """
                [package]
                name = "isolated_hash_probe"
                version = "0.1.0"
                edition = "2021"
                """)
            write(joinpath(dir, "src", "lib.rs"), "pub fn value() -> i32 { 1 }\n")
            isolated = RustCall.scan_crate(dir)
            RustCall.compute_crate_hash(isolated) # materialize Cargo.lock
            original = RustCall.compute_crate_hash(isolated)
            probe = joinpath(dir, "rc278_probe.txt")
            try
                write(probe, "an input the scan never lists")
                RustCall._artifact_reset_digest_caches!()
                @test RustCall.compute_crate_hash(isolated) != original
            finally
                rm(probe; force = true)
                RustCall._artifact_reset_digest_caches!()
            end
            @test RustCall.compute_crate_hash(isolated) == original
        end
        @test RustCall.compute_crate_hash(info) == hash1
    end

end

# Integration test that actually builds and uses the sample crate
# This is a heavier test that requires cargo and takes longer
