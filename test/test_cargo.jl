# Test Cargo project generation and building for Phase 3
# Tests for src/cargoproject.jl and src/cargobuild.jl

using RustCall
using Test
using SHA: sha256

@testset "Cargo Project Generation" begin

    @testset "generate_cargo_toml" begin
        deps = [
            RustCall.DependencySpec("ndarray", version="0.15"),
            RustCall.DependencySpec("serde", version="1.0", features=["derive", "std"])
        ]

        cargo_toml = RustCall.generate_cargo_toml("test_project", deps, "2021")

        # Check package section
        @test occursin("[package]", cargo_toml)
        @test occursin("name = \"test_project\"", cargo_toml)
        @test occursin("edition = \"2021\"", cargo_toml)

        # Check lib section
        @test occursin("[lib]", cargo_toml)
        @test occursin("cdylib", cargo_toml)

        # Check dependencies
        @test occursin("[dependencies]", cargo_toml)
        @test occursin("ndarray = \"0.15\"", cargo_toml)
        @test occursin("serde", cargo_toml)
        @test occursin("features", cargo_toml)
    end

    @testset "escape_toml_string" begin
        # No escaping needed
        @test RustCall.escape_toml_string("hello") == "hello"
        @test RustCall.escape_toml_string("1.0.0") == "1.0.0"

        # Escape quotes
        @test RustCall.escape_toml_string("say \"hi\"") == "say \\\"hi\\\""

        # Escape backslashes
        @test RustCall.escape_toml_string("C:\\path") == "C:\\\\path"

        # Escape control characters
        @test RustCall.escape_toml_string("line1\nline2") == "line1\\nline2"
        @test RustCall.escape_toml_string("col1\tcol2") == "col1\\tcol2"

        # TOML injection attempt — should be safely escaped
        malicious = "1.0\"]\nother_dep = \"1.0"
        escaped = RustCall.escape_toml_string(malicious)
        @test !occursin('\n', escaped)
        @test !occursin("]\n", escaped)
    end

    @testset "escape_toml_string injection prevention (#114)" begin
        # Fuzz-style: ensure no raw control chars survive escaping
        attack_strings = [
            "",
            "a\"b",
            "a\\b",
            "a\nb\rc\td",
            "]]]\n[package]",
            "= \"pwned\"",
            "\\\"\n[evil]\nkey = \"val\"",
            "a\\\\\"b",  # escaped backslash then quote
        ]
        for s in attack_strings
            escaped = RustCall.escape_toml_string(s)
            @test !occursin('\n', escaped)
            @test !occursin('\r', escaped)
            @test !occursin('\t', escaped)
        end
    end

    @testset "format_dependency_line" begin
        # Simple version
        dep1 = RustCall.DependencySpec("ndarray", version="0.15")
        line1 = RustCall.format_dependency_line(dep1)
        @test line1 == "ndarray = \"0.15\""

        # Version with features
        dep2 = RustCall.DependencySpec("serde", version="1.0", features=["derive"])
        line2 = RustCall.format_dependency_line(dep2)
        @test occursin("serde", line2)
        @test occursin("version", line2)
        @test occursin("features", line2)
        @test occursin("derive", line2)

        # Git dependency
        dep3 = RustCall.DependencySpec("my_crate", git="https://github.com/user/repo.git")
        line3 = RustCall.format_dependency_line(dep3)
        @test occursin("git", line3)
        @test occursin("https://github.com/user/repo.git", line3)

        # Path dependency
        dep4 = RustCall.DependencySpec("local_crate", path="../local_crate")
        line4 = RustCall.format_dependency_line(dep4)
        @test occursin("path", line4)
        @test occursin("../local_crate", line4)
    end

    @testset "create_cargo_project" begin
        deps = [RustCall.DependencySpec("ndarray", version="0.15")]

        # Create a temporary project
        project = RustCall.create_cargo_project("test_cargo_project", deps)

        try
            # Check project structure
            @test isdir(project.path)
            @test isfile(joinpath(project.path, "Cargo.toml"))
            @test isdir(joinpath(project.path, "src"))
            @test isfile(joinpath(project.path, "src", "lib.rs"))

            # Check Cargo.toml contents
            cargo_toml = read(joinpath(project.path, "Cargo.toml"), String)
            @test occursin("test_cargo_project", cargo_toml)
            @test occursin("ndarray", cargo_toml)

            # Check project properties
            @test project.name == "test_cargo_project"
            @test project.edition == "2021"
            @test length(project.dependencies) == 1
        finally
            # Clean up
            RustCall.cleanup_cargo_project(project)
        end
    end

    @testset "write_rust_code_to_project" begin
        deps = [RustCall.DependencySpec("ndarray", version="0.15")]
        project = RustCall.create_cargo_project("test_write_project", deps)

        try
            code = """
            //! ```cargo
            //! [dependencies]
            //! ndarray = "0.15"
            //! ```

            use ndarray::Array1;

            #[no_mangle]
            pub extern "C" fn test() -> i32 { 42 }
            """

            RustCall.write_rust_code_to_project(project, code)

            # Check lib.rs contents
            lib_rs = read(joinpath(project.path, "src", "lib.rs"), String)

            # Should have the code without dependency comments
            @test occursin("use ndarray::Array1", lib_rs)
            @test occursin("#[no_mangle]", lib_rs)
            @test !occursin("```cargo", lib_rs)
            @test !occursin("[dependencies]", lib_rs)
        finally
            RustCall.cleanup_cargo_project(project)
        end
    end

    @testset "hash_dependencies" begin
        deps1 = [
            RustCall.DependencySpec("ndarray", version="0.15"),
            RustCall.DependencySpec("serde", version="1.0")
        ]

        deps2 = [
            RustCall.DependencySpec("serde", version="1.0"),
            RustCall.DependencySpec("ndarray", version="0.15")
        ]

        # Same dependencies in different order should produce same hash
        hash1 = RustCall.hash_dependencies(deps1)
        hash2 = RustCall.hash_dependencies(deps2)
        @test hash1 == hash2

        # Different dependencies should produce different hash
        deps3 = [RustCall.DependencySpec("ndarray", version="0.16")]
        hash3 = RustCall.hash_dependencies(deps3)
        @test hash1 != hash3
    end
end

@testset "Dependency Resolution" begin

    @testset "validate_dependencies" begin
        # Valid dependencies
        deps_valid = [
            RustCall.DependencySpec("ndarray", version="0.15"),
            RustCall.DependencySpec("my_crate", git="https://github.com/user/repo.git")
        ]
        @test_nowarn RustCall.validate_dependencies(deps_valid)

        # Invalid: no version, git, or path
        deps_invalid = [RustCall.DependencySpec("bad_dep")]
        @test_throws RustCall.DependencyResolutionError RustCall.validate_dependencies(deps_invalid)
    end

    @testset "resolve_version_conflict" begin
        dep1 = RustCall.DependencySpec("serde", version="1.0", features=["derive"])
        dep2 = RustCall.DependencySpec("serde", version="1.0", features=["std"])

        resolved = RustCall.resolve_version_conflict(dep1, dep2)

        @test resolved.name == "serde"
        @test resolved.version == "1.0"
        @test "derive" in resolved.features
        @test "std" in resolved.features
    end

    @testset "version_specificity" begin
        @test RustCall.version_specificity("1") == 1
        @test RustCall.version_specificity("1.0") == 2
        @test RustCall.version_specificity("1.0.5") == 3
        @test RustCall.version_specificity("1.0.5-beta") == 4

        # Compound version constraints (#104)
        @test RustCall.version_specificity(">=1.0,<2.0") == 2
        @test RustCall.version_specificity(">=1.0.0, <2.0.0") == 3
        @test RustCall.version_specificity(">=1.0, <2.0.0") == 3
        @test RustCall.version_specificity(">=1,<2") == 1

        # Version with operators
        @test RustCall.version_specificity("^1.0") == 2
        @test RustCall.version_specificity("~1.0.5") == 3
        @test RustCall.version_specificity(">=1.0.0") == 3
    end
end

@testset "Cargo Cache" begin

    @testset "cache operations" begin
        # Test cache directory creation
        cache_dir = RustCall.get_cargo_cache_dir()
        @test isdir(cache_dir)

        # Test clearing cache
        RustCall.clear_cargo_cache()
        @test isdir(cache_dir)  # Directory should still exist

        # Test cache size (should be 0 after clear)
        size = RustCall.get_cargo_cache_size()
        @test size == 0
    end
end

@testset "Cargo block identity (#278)" begin
    src = "#[no_mangle]\npub extern \"C\" fn rc278_cargo() -> i32 { 1 }\n"
    plain = RustCall.DependencySpec[RustCall.DependencySpec("serde", "1.0")]

    id = RustCall._cargo_block_id(src, plain, "")
    @test id.kind == "cargo"
    @test id.codegen == ["profile" => "release"]
    @test length(RustCall.artifact_key(id)) == 64
    @test RustCall.artifact_key(id) == RustCall.artifact_key(RustCall._cargo_block_id(src, plain, ""))

    # The build environment and the dependency set are both part of it.
    @test RustCall.artifact_key(id) !=
          RustCall.artifact_key(RustCall._cargo_block_id(src, plain, "RUSTFLAGS=--cfg foo"))
    @test RustCall.artifact_key(id) != RustCall.artifact_key(
        RustCall._cargo_block_id(src, RustCall.DependencySpec[RustCall.DependencySpec("serde", "2.0")], ""))

    # A block that declares no `path =` dependency never resolves a dependency
    # graph, so it never spawns `cargo tree` (#278 §8: the warm path must not
    # pay for path-dependency hashing it does not need).
    RustCall._artifact_reset_digest_caches!()
    before = RustCall.CARGO_TREE_INVOCATIONS[]
    RustCall._cargo_block_id(src, plain, "")
    RustCall._cargo_block_id(src, plain, "")
    @test RustCall.CARGO_TREE_INVOCATIONS[] == before

    # A block that *does* declare one resolves the graph exactly once.
    dir = mktempdir()
    try
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "Cargo.toml"),
              "[package]\nname = \"rc278_local\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")
        write(joinpath(dir, "src", "lib.rs"), "pub fn f() -> i32 { 1 }\n")
        local_dep = RustCall.DependencySpec[RustCall.DependencySpec("rc278_local", nothing, String[], nothing, dir)]

        RustCall._artifact_reset_digest_caches!()
        cold_start = RustCall.CARGO_TREE_INVOCATIONS[]
        key_cold = RustCall.artifact_key(RustCall._cargo_block_id(src, local_dep, ""))
        after_cold = RustCall.CARGO_TREE_INVOCATIONS[]

        key_warm = RustCall.artifact_key(RustCall._cargo_block_id(src, local_dep, ""))
        @test key_warm == key_cold
        @test RustCall.CARGO_TREE_INVOCATIONS[] == after_cold   # warm: no process spawn
        @test after_cold >= cold_start

        # The dependency is identified by content: editing it rebuilds.
        sleep(0.01)
        write(joinpath(dir, "src", "lib.rs"), "pub fn f() -> i32 { 2 }\n")
        RustCall._artifact_reset_digest_caches!()
        @test RustCall.artifact_key(RustCall._cargo_block_id(src, local_dep, "")) != key_cold
    finally
        rm(dir; recursive = true, force = true)
    end
end

@testset "Effective Cargo configuration digest (#278)" begin
    # `.cargo/config.toml` can set `[build] rustflags`, which changes what is
    # produced, so the project-local chain Cargo searches is part of the key —
    # not just `$CARGO_HOME/config.toml` (deferred item from #272).
    root = mktempdir()
    try
        project = joinpath(root, "workspace", "member")
        mkpath(project)
        home = joinpath(root, "cargo_home")
        mkpath(home)

        withenv("CARGO_HOME" => home) do
            @test RustCall._cargo_config_digest(ENV) == "absent"
            @test RustCall._cargo_config_digest(ENV; dir = project) == "absent"

            # A config in an ancestor of the project directory is found.
            mkpath(joinpath(root, "workspace", ".cargo"))
            write(joinpath(root, "workspace", ".cargo", "config.toml"),
                  "[build]\nrustflags = [\"--cfg\", \"rc278\"]\n")
            with_ancestor = RustCall._cargo_config_digest(ENV; dir = project)
            @test with_ancestor != "absent"
            # ... and only when a directory is given.
            @test RustCall._cargo_config_digest(ENV) == "absent"

            # Editing it changes the digest.
            write(joinpath(root, "workspace", ".cargo", "config.toml"),
                  "[build]\nrustflags = []\n")
            @test RustCall._cargo_config_digest(ENV; dir = project) != with_ancestor

            # A project-local config wins its own slot, distinct from the
            # ancestor's, so the two chains cannot collide.
            mkpath(joinpath(project, ".cargo"))
            write(joinpath(project, ".cargo", "config.toml"), "[build]\nrustflags = []\n")
            both = RustCall._cargo_config_digest(ENV; dir = project)
            @test both != RustCall._cargo_config_digest(ENV; dir = joinpath(root, "workspace"))

            # The Cargo home file still counts.
            write(joinpath(home, "config.toml"), "[build]\njobs = 1\n")
            @test RustCall._cargo_config_digest(ENV; dir = project) != both
            # With no project chain the value is the home digest itself, which
            # keeps the `#cargo-config=` snapshot line shape unchanged.
            @test RustCall._cargo_config_digest(ENV) ==
                  bytes2hex(sha256(read(joinpath(home, "config.toml"))))
        end

        # The search walks up from the directory, nearest first.
        dirs = RustCall._cargo_config_search_dirs(project)
        @test first(dirs) == abspath(project)
        @test abspath(joinpath(root, "workspace")) in dirs
        @test last(dirs) == dirname(last(dirs)) || length(dirs) > 1
    finally
        rm(root; recursive = true, force = true)
    end
end


@testset "A Cargo block has exactly one key (#287 review)" begin
    # The outer lookup/save used the base block identity while
    # `build_cargo_project_cached` derived a *richer* one (it folded in the
    # effective `.cargo/config.toml` chain). Two keys for one artifact: after a
    # Cargo-config change the outer lookup still matched the pre-change binary.
    #
    # Observable without any test hook: one evaluation must leave exactly one
    # entry in the Cargo cache, named after the block's own key. Two keys leave
    # two.
    if !RustCall.check_rustc_available()
        @test_skip "rustc/cargo are required for a Cargo-backed block"
    else
        block = """
        // cargo-deps: itoa="1.0"

        #[no_mangle]
        pub extern "C" fn rc287_one_key() -> i32 { 7 }
        """
        RustCall.clear_cargo_cache()
        lib = RustCall._compile_and_load_rust(block, "one-key", 0)
        @test ccall(RustCall.get_function_pointer(lib, "rc287_one_key"), Int32, ()) == 7

        lib_ext = RustCall.get_library_extension()
        cached = filter(f -> endswith(f, lib_ext), readdir(RustCall.get_cargo_cache_dir()))
        @test length(cached) == 1

        # ... and that one entry is the key the block itself computes, so the
        # lookup, the build and the save all agree.
        expanded = RustCall.expand_inline(block; cfg = :cargo)
        deps = RustCall.parse_dependencies_from_code(block)
        _, build_env_key = RustCall._cargo_build_env_for(nothing)
        id = RustCall._cargo_block_id(expanded.source, deps, build_env_key;
            cargo_config = RustCall._cargo_config_digest(ENV; dir = tempdir()))
        @test only(cached) == RustCall.artifact_key(id) * lib_ext
        @test lib == "rust_cargo_$(RustCall.artifact_short_id(RustCall.artifact_key(id), 16))"

        # A second evaluation adds nothing: it is the same key.
        RustCall._compile_and_load_rust(block, "one-key", 0)
        @test length(filter(f -> endswith(f, lib_ext),
                            readdir(RustCall.get_cargo_cache_dir()))) == 1

        # The builder refuses a profile that disagrees with the identity it was
        # handed, rather than quietly caching under a second key.
        project = RustCall.create_cargo_project("rc287_probe", RustCall.DependencySpec[])
        try
            @test_throws ArgumentError RustCall.build_cargo_project_cached(
                project, id; release = false)
        finally
            RustCall.cleanup_cargo_project(project)
        end
    end
end

@testset "A Cargo config change rebuilds the block (#287 review)" begin
    # `.cargo/config.toml` above the directory the build runs in can set
    # `[build] rustflags`, so it changes the binary. With two keys the outer
    # lookup did not see the change and handed back the old library.
    if !RustCall.check_rustc_available()
        @test_skip "rustc/cargo are required for a Cargo-backed block"
    else
        sandbox = mktempdir()
        # Generated projects are created with `mktempdir()`, whose default
        # parent is `tempdir()`, so redirecting the temporary directory puts
        # them under one whose `.cargo/` chain this test controls.
        #
        # Which variable does that is platform-dependent, and the sets barely
        # overlap: `tempdir()` is libuv's `uv_os_tmpdir`, which reads
        # TMPDIR, TMP, TEMP, TEMPDIR on unix but only TMP, TEMP, USERPROFILE on
        # Windows. Setting `TMPDIR` alone therefore redirects on unix and is
        # ignored on Windows — which is exactly how the first version of this
        # test passed everywhere but Windows, where it silently exercised the
        # real temp directory and then asserted a rebuild that had no reason to
        # happen.
        #
        # So: set all three, and *verify* the redirect took effect instead of
        # assuming it. The digest assertion below likewise names `tempdir()` —
        # the directory the product actually builds its key from — rather than
        # `sandbox`, which is what hid the problem the first time.
        redirect = ("TMPDIR" => sandbox, "TMP" => sandbox, "TEMP" => sandbox)
        try
            block = """
            // cargo-deps: itoa="1.0"

            #[no_mangle]
            pub extern "C" fn rc287_cfg_probe() -> i32 { if cfg!(rc287_flag) { 1 } else { 0 } }
            """
            config_dir = joinpath(sandbox, ".cargo")
            mkpath(config_dir)

            redirected = withenv(redirect...) do
                realpath(tempdir()) == realpath(sandbox)
            end

            if !redirected
                @test_skip "cannot redirect tempdir() on this platform"
                @info "Skipping Cargo config rebuild test: tempdir() is not redirectable" tempdir_seen =
                    withenv(() -> tempdir(), redirect...)
            else
                value = withenv(redirect...) do
                    lib = RustCall._compile_and_load_rust(block, "cfg-probe", 0)
                    ccall(RustCall.get_function_pointer(lib, "rc287_cfg_probe"), Int32, ())
                end
                @test value == 0

                # Now the same block under a config that adds `--cfg rc287_flag`.
                write(joinpath(config_dir, "config.toml"),
                      "[build]\nrustflags = [\"--cfg\", \"rc287_flag\"]\n")
                value2 = withenv(redirect...) do
                    # The config is genuinely on the chain the key is built from.
                    @test RustCall._cargo_config_digest(ENV; dir = tempdir()) != "absent"
                    lib = RustCall._compile_and_load_rust(block, "cfg-probe", 0)
                    ccall(RustCall.get_function_pointer(lib, "rc287_cfg_probe"), Int32, ())
                end
                @test value2 == 1     # rebuilt, and the new cfg is visible
            end
        finally
            rm(sandbox; recursive = true, force = true)
        end
    end
end
