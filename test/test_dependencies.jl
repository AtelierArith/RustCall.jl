# Test dependency parsing for Phase 3
# Tests for src/dependencies.jl

using RustCall
using Test

@testset "Dependency Parsing" begin

    @testset "DependencySpec struct" begin
        # Test basic constructor
        dep = DependencySpec("ndarray", version="0.15")
        @test dep.name == "ndarray"
        @test dep.version == "0.15"
        @test isempty(dep.features)
        @test isnothing(dep.git)
        @test isnothing(dep.path)

        # Test with features
        dep2 = DependencySpec("serde", version="1.0", features=["derive", "std"])
        @test dep2.name == "serde"
        @test dep2.features == ["derive", "std"]

        # Test with git
        dep3 = DependencySpec("my_crate", git="https://github.com/user/repo.git")
        @test dep3.git == "https://github.com/user/repo.git"
        @test isnothing(dep3.version)

        # Test with path
        dep4 = DependencySpec("local_crate", path="../local_crate")
        @test dep4.path == "../local_crate"
    end

    @testset "extract_cargo_block" begin
        # Test basic cargo block extraction
        code1 = """
        //! ```cargo
        //! [dependencies]
        //! ndarray = "0.15"
        //! ```

        use ndarray::Array1;

        #[no_mangle]
        pub extern "C" fn test() -> i32 { 42 }
        """

        block = RustCall.extract_cargo_block(code1)
        @test !isnothing(block)
        @test occursin("[dependencies]", block)
        @test occursin("ndarray", block)

        # Test with no cargo block
        code2 = """
        #[no_mangle]
        pub extern "C" fn test() -> i32 { 42 }
        """

        block2 = RustCall.extract_cargo_block(code2)
        @test isnothing(block2)

        # Test with multiple dependencies
        code3 = """
        //! ```cargo
        //! [dependencies]
        //! serde = { version = "1.0", features = ["derive"] }
        //! ndarray = "0.15"
        //! tokio = { version = "1.0", features = ["full"] }
        //! ```
        """

        block3 = RustCall.extract_cargo_block(code3)
        @test !isnothing(block3)
        @test occursin("serde", block3)
        @test occursin("ndarray", block3)
        @test occursin("tokio", block3)
    end

    @testset "extract_cargo_deps_line" begin
        # Test single-line format
        code1 = """
        // cargo-deps: ndarray="0.15", serde="1.0"

        #[no_mangle]
        pub extern "C" fn test() -> i32 { 42 }
        """

        line = RustCall.extract_cargo_deps_line(code1)
        @test !isnothing(line)
        @test occursin("ndarray", line)
        @test occursin("serde", line)

        # Test with no cargo-deps line
        code2 = """
        #[no_mangle]
        pub extern "C" fn test() -> i32 { 42 }
        """

        line2 = RustCall.extract_cargo_deps_line(code2)
        @test isnothing(line2)
    end

    @testset "parse_dependencies_from_code - cargo block format" begin
        code = """
        //! ```cargo
        //! [dependencies]
        //! ndarray = "0.15"
        //! serde = { version = "1.0", features = ["derive"] }
        //! ```

        use ndarray::Array1;
        use serde::Serialize;
        """

        deps = parse_dependencies_from_code(code)
        @test length(deps) == 2

        # Find ndarray
        ndarray_dep = filter(d -> d.name == "ndarray", deps)
        @test length(ndarray_dep) == 1
        @test ndarray_dep[1].version == "0.15"

        # Find serde
        serde_dep = filter(d -> d.name == "serde", deps)
        @test length(serde_dep) == 1
        @test serde_dep[1].version == "1.0"
        @test "derive" in serde_dep[1].features
    end

    @testset "parse_dependencies_from_code - cargo-deps format" begin
        code = """
        // cargo-deps: ndarray="0.15", serde="1.0"

        #[no_mangle]
        pub extern "C" fn test() -> i32 { 42 }
        """

        deps = parse_dependencies_from_code(code)
        @test length(deps) == 2

        dep_names = Set([d.name for d in deps])
        @test "ndarray" in dep_names
        @test "serde" in dep_names
    end

    @testset "parse_dependencies_from_code - complex cargo-deps format" begin
        code = """
        // cargo-deps: ndarray="0.15", serde={version="1.0", features=["derive"]}
        """

        deps = parse_dependencies_from_code(code)
        @test length(deps) == 2

        # Find serde with features
        serde_dep = filter(d -> d.name == "serde", deps)
        @test length(serde_dep) == 1
        @test serde_dep[1].version == "1.0"
        @test "derive" in serde_dep[1].features
    end

    @testset "has_dependencies" begin
        # Code with cargo block
        code1 = """
        //! ```cargo
        //! [dependencies]
        //! ndarray = "0.15"
        //! ```
        """
        @test has_dependencies(code1)

        # Code with cargo-deps line
        code2 = """
        // cargo-deps: ndarray="0.15"
        """
        @test has_dependencies(code2)

        # Code without dependencies
        code3 = """
        #[no_mangle]
        pub extern "C" fn test() -> i32 { 42 }
        """
        @test !has_dependencies(code3)
    end

    @testset "merge_dependencies" begin
        deps = [
            DependencySpec("serde", version="1.0", features=["derive"]),
            DependencySpec("serde", version="1.0", features=["std"]),
            DependencySpec("ndarray", version="0.15")
        ]

        merged = RustCall.merge_dependencies(deps)
        @test length(merged) == 2

        # Check serde has merged features
        serde_dep = filter(d -> d.name == "serde", merged)
        @test length(serde_dep) == 1
        @test "derive" in serde_dep[1].features
        @test "std" in serde_dep[1].features
    end

    @testset "remove_dependency_comments" begin
        code = """
        //! ```cargo
        //! [dependencies]
        //! ndarray = "0.15"
        //! ```

        // cargo-deps: serde="1.0"

        use ndarray::Array1;

        #[no_mangle]
        pub extern "C" fn test() -> i32 { 42 }
        """

        clean = RustCall.remove_dependency_comments(code)

        # Should not contain cargo block
        @test !occursin("```cargo", clean)
        @test !occursin("[dependencies]", clean)

        # Should not contain cargo-deps line
        @test !occursin("cargo-deps", clean)

        # Should keep the actual code
        @test occursin("use ndarray::Array1", clean)
        @test occursin("#[no_mangle]", clean)
        @test occursin("pub extern", clean)
    end

    @testset "_count_trailing_backslashes" begin
        @test RustCall._count_trailing_backslashes("") == 0
        @test RustCall._count_trailing_backslashes("hello") == 0
        @test RustCall._count_trailing_backslashes("hello\\") == 1
        @test RustCall._count_trailing_backslashes("hello\\\\") == 2
        @test RustCall._count_trailing_backslashes("hello\\\\\\") == 3
        @test RustCall._count_trailing_backslashes("\\") == 1
    end

    @testset "split_cargo_deps handles escaped quotes" begin
        # Simple case — no escaping
        result = RustCall.split_cargo_deps("ndarray=\"0.15\", serde=\"1.0\"")
        @test length(result) == 2
        @test result[1] == "ndarray=\"0.15\""
        @test result[2] == "serde=\"1.0\""

        # Double backslash before quote — quote is NOT escaped
        # (the backslash itself is escaped, so the quote is real)
        result2 = RustCall.split_cargo_deps("a={path=\"C:\\\\\"}, b=\"1.0\"")
        @test length(result2) == 2

        # Single backslash before quote — quote IS escaped (stays in string)
        result3 = RustCall.split_cargo_deps("a=\"val\\\"ue\", b=\"1.0\"")
        @test length(result3) == 2
    end
end
