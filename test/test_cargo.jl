# Test Cargo project generation and building for Phase 3
# Tests for src/cargoproject.jl and src/cargobuild.jl

using RustCall
using Test

@testset "Cargo Project Generation" begin

    @testset "generate_cargo_toml" begin
        deps = [
            DependencySpec("ndarray", version="0.15"),
            DependencySpec("serde", version="1.0", features=["derive", "std"])
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

    @testset "format_dependency_line" begin
        # Simple version
        dep1 = DependencySpec("ndarray", version="0.15")
        line1 = RustCall.format_dependency_line(dep1)
        @test line1 == "ndarray = \"0.15\""

        # Version with features
        dep2 = DependencySpec("serde", version="1.0", features=["derive"])
        line2 = RustCall.format_dependency_line(dep2)
        @test occursin("serde", line2)
        @test occursin("version", line2)
        @test occursin("features", line2)
        @test occursin("derive", line2)

        # Git dependency
        dep3 = DependencySpec("my_crate", git="https://github.com/user/repo.git")
        line3 = RustCall.format_dependency_line(dep3)
        @test occursin("git", line3)
        @test occursin("https://github.com/user/repo.git", line3)

        # Path dependency
        dep4 = DependencySpec("local_crate", path="../local_crate")
        line4 = RustCall.format_dependency_line(dep4)
        @test occursin("path", line4)
        @test occursin("../local_crate", line4)
    end

    @testset "create_cargo_project" begin
        deps = [DependencySpec("ndarray", version="0.15")]

        # Create a temporary project
        project = create_cargo_project("test_cargo_project", deps)

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
        deps = [DependencySpec("ndarray", version="0.15")]
        project = create_cargo_project("test_write_project", deps)

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
            DependencySpec("ndarray", version="0.15"),
            DependencySpec("serde", version="1.0")
        ]

        deps2 = [
            DependencySpec("serde", version="1.0"),
            DependencySpec("ndarray", version="0.15")
        ]

        # Same dependencies in different order should produce same hash
        hash1 = RustCall.hash_dependencies(deps1)
        hash2 = RustCall.hash_dependencies(deps2)
        @test hash1 == hash2

        # Different dependencies should produce different hash
        deps3 = [DependencySpec("ndarray", version="0.16")]
        hash3 = RustCall.hash_dependencies(deps3)
        @test hash1 != hash3
    end
end

@testset "Dependency Resolution" begin

    @testset "validate_dependencies" begin
        # Valid dependencies
        deps_valid = [
            DependencySpec("ndarray", version="0.15"),
            DependencySpec("my_crate", git="https://github.com/user/repo.git")
        ]
        @test_nowarn RustCall.validate_dependencies(deps_valid)

        # Invalid: no version, git, or path
        deps_invalid = [DependencySpec("bad_dep")]
        @test_throws DependencyResolutionError RustCall.validate_dependencies(deps_invalid)
    end

    @testset "resolve_version_conflict" begin
        dep1 = DependencySpec("serde", version="1.0", features=["derive"])
        dep2 = DependencySpec("serde", version="1.0", features=["std"])

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
    end
end

@testset "Cargo Cache" begin

    @testset "cache operations" begin
        # Test cache directory creation
        cache_dir = RustCall.get_cargo_cache_dir()
        @test isdir(cache_dir)

        # Test clearing cache
        clear_cargo_cache()
        @test isdir(cache_dir)  # Directory should still exist

        # Test cache size (should be 0 after clear)
        size = get_cargo_cache_size()
        @test size == 0
    end
end
