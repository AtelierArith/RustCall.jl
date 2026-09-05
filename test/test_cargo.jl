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
