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

"""
    with_isolated_cargo_cache(f)

Run `f` with RustCall's cache in a directory of its own (#306).

The Cargo cache is a **depot-level, process-shared** directory, and the two
testsets below assert on its *whole contents* — its total size after a clear,
and the number of libraries in it after one evaluation. Under `Pkg.test()`'s
parallel runner any other worker that compiles a Cargo block writes into that
same directory, so those assertions were being made about somebody else's
artifacts and failed intermittently. #275's PyO3 wrapper builds go through the
same cache, which made it far more likely.

`RUSTCALL_CACHE_DIR` is the documented override (#252) and is part of the
memo key, but the memo is also consulted by code already running, so it is
reset on the way in and on the way out.

The directory is **not** removed by `mktempdir`'s cleanup: a library this
testset loaded is mapped into the process, and Windows refuses to delete a
mapped file. It is removed best-effort instead, exactly as `clear_cargo_cache`
tolerates the same thing.
"""
function with_isolated_cargo_cache(f)
    dir = mktempdir(; cleanup = false)
    try
        withenv("RUSTCALL_CACHE_DIR" => dir) do
            RustCall._reset_cache_dir_memo!()
            f()
        end
    finally
        RustCall._reset_cache_dir_memo!()
        try
            rm(dir; recursive = true, force = true)
        catch
        end
    end
end

@testset "Cargo Cache" begin

    # The whole-directory assertions below only mean what they say when nothing
    # else is writing to that directory; see `with_isolated_cargo_cache` (#306).
    @testset "cache operations" begin
        with_isolated_cargo_cache() do
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
      # Its own cache root, so "exactly one entry" is a statement about this
      # block and not about whatever a parallel worker compiled (#306).
      with_isolated_cargo_cache() do
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
        # ... including the resolved graph: the lockfile the build persisted
        # for this dependency set is part of the identity (#256).
        id = RustCall._cargo_block_id(expanded.source, deps, build_env_key;
            cargo_config = RustCall._cargo_config_digest(ENV; dir = tempdir()),
            cargo_lock = RustCall._file_content_digest(RustCall.lockfile_path(deps)))
        key = RustCall.artifact_key(id)
        # Named by this block's own key, whatever else is in the directory:
        # the assertion the testset is really making is "this block produced
        # exactly one key", so it is also checked that way.
        @test only(cached) == key * lib_ext
        @test count(==(key * lib_ext), cached) == 1
        @test lib == "rust_cargo_$(RustCall.artifact_short_id(key, 16))"

        # A second evaluation adds nothing: it is the same key.
        RustCall._compile_and_load_rust(block, "one-key", 0)
        after = filter(f -> endswith(f, lib_ext), readdir(RustCall.get_cargo_cache_dir()))
        @test length(after) == 1
        @test count(==(key * lib_ext), after) == 1

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
        loaded = String[]
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
                    push!(loaded, lib)
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
                    push!(loaded, lib)
                    ccall(RustCall.get_function_pointer(lib, "rc287_cfg_probe"), Int32, ())
                end
                @test value2 == 1     # rebuilt, and the new cfg is visible
                @test length(unique(loaded)) == 2   # a different key, a different library
            end
        finally
            # The generated projects live *inside* the sandbox now, and their
            # cdylibs are loaded into this process. Windows will not delete a
            # mapped file, so drop the handles first and then treat the removal
            # as best effort: a leftover temporary directory is not worth
            # failing a test over, and `rm(force = true)` forgives a missing
            # file, not a locked one.
            for name in unique(loaded)
                try
                    RustCall.unload_library(name)
                catch
                end
            end
            try
                rm(sandbox; recursive = true, force = true)
            catch e
                # Warned rather than silenced on every platform: on Windows a
                # still-mapped image is the expected reason and the leftover is
                # harmless, but the same failure on unix would mean something
                # else and should not disappear.
                @warn "Could not remove the Cargo config sandbox; leaving it behind" sandbox exception = e
            end
        end
    end
end

@testset "A generated project's output is pinned to its own target/ (#307 review)" begin
    # `build_cargo_project` looks for the library under `<project>/target`. An
    # inherited `CARGO_TARGET_DIR`, or a `[build] target-dir` in a
    # `.cargo/config.toml` Cargo discovers above the project (a PyO3 wrapper is
    # built under its target crate's `target/`, so that crate's config applies),
    # would send a successful build elsewhere and turn it into "Library not
    # found after build". The build pins the directory instead.
    if !RustCall.check_rustc_available()
        @test_skip "rustc/cargo are required to build a Cargo project"
    else
        sandbox = mktempdir()
        project_dir = joinpath(sandbox, "pinned")
        mkpath(joinpath(project_dir, "src"))
        mkpath(joinpath(project_dir, ".cargo"))
        write(joinpath(project_dir, "Cargo.toml"), """
            [package]
            name = "pinned"
            version = "0.1.0"
            edition = "2021"

            [lib]
            crate-type = ["cdylib"]

            [workspace]
            """)
        write(joinpath(project_dir, "src", "lib.rs"), """
            #[no_mangle]
            pub extern "C" fn rustcall_pinned() -> i32 { 42 }
            """)
        # Both ways of moving the output, at once.
        write(joinpath(project_dir, ".cargo", "config.toml"), """
            [build]
            target-dir = "config-elsewhere"
            """)
        foreign = joinpath(sandbox, "env-elsewhere")
        project = RustCall.CargoProject("pinned", "0.1.0", RustCall.DependencySpec[],
                                        "2021", project_dir)
        lib = withenv("CARGO_TARGET_DIR" => foreign) do
            RustCall.build_cargo_project(project; release = true)
        end
        @test isfile(lib)
        @test startswith(lib, joinpath(project_dir, "target"))
        @test !isdir(foreign)
        @test !isdir(joinpath(project_dir, "config-elsewhere"))
        rm(sandbox; recursive = true, force = true)
    end
end

@testset "Pinned, lockfile-driven dependency builds (#256)" begin
    # A `// cargo-deps:` block used to be resolved afresh on every build, with
    # no lockfile and a cache key over the *requested* ranges: two machines
    # (or one machine a week apart) built different graphs for the same
    # source, and a cache hit could serve a binary built from a graph that no
    # longer resolves. The resolution is now persisted per dependency set and
    # its content is part of the build's identity.
    deps = [RustCall.DependencySpec("itoa"; version = "1.0")]
    same = [RustCall.DependencySpec("itoa"; version = "1.0")]
    other = [RustCall.DependencySpec("itoa"; version = "1.0.11")]

    @testset "the lockfile is named by the dependency set alone" begin
        with_isolated_cargo_cache() do
            path = RustCall.lockfile_path(deps)
            @test startswith(path, RustCall.lockfile_dir())
            @test endswith(path, ".lock")
            @test RustCall.lockfile_path(same) == path
            @test RustCall.lockfile_path(other) != path
            # The block's own comments name the same file.
            @test RustCall.lockfile_path("// cargo-deps: itoa=\"1.0\"\n") == path
            # Not the toolchain: the same declared set on another machine, with
            # another rustc, looks in the same place — that is what sharing the
            # file between machines means.
            id = RustCall.cargo_lockfile_id(deps)
            @test id.kind == "cargo-lockfile"
            @test id.toolchain == "" && id.compiler == ""
            @test id.dependencies == RustCall.artifact_dependency_strings(deps)
        end
    end

    @testset "the resolved graph is in the build key" begin
        # Same source, same requested ranges, different resolution: different
        # artifact — the cache describes what was built, not what was asked.
        base = RustCall._cargo_block_id("fn f() {}", deps, "env"; cargo_lock = "aaaa")
        @test RustCall.artifact_key(base) !=
              RustCall.artifact_key(RustCall._cargo_block_id("fn f() {}", deps, "env";
                                                             cargo_lock = "bbbb"))
        @test RustCall.artifact_key(base) !=
              RustCall.artifact_key(RustCall._cargo_block_id("fn f() {}", deps, "env"))
        @test any(p -> p == ("cargo-lock" => "aaaa"), base.extra)
    end

    @testset "--locked and --offline reach cargo" begin
        args = RustCall._cargo_build_args(true, String[], true; locked = true)
        @test "--locked" in args
        @test !("--locked" in RustCall._cargo_build_args(true, String[], true))
        withenv("RUSTCALL_OFFLINE" => nothing) do
            @test !RustCall.cargo_offline()
            @test !("--offline" in RustCall._cargo_build_args(true, String[], true))
        end
        for v in ("1", "true", "YES")
            withenv("RUSTCALL_OFFLINE" => v) do
                @test RustCall.cargo_offline()
                @test "--offline" in RustCall._cargo_build_args(true, String[], true)
            end
        end
        withenv("RUSTCALL_OFFLINE" => "0") do
            @test !RustCall.cargo_offline()
        end
    end

    if !RustCall.check_rustc_available()
        @test_skip "rustc/cargo are required for a Cargo-backed block"
    else
        @testset "one resolution, replayed byte for byte" begin
            with_isolated_cargo_cache() do
                block = """
                // cargo-deps: itoa="1.0"

                #[no_mangle]
                pub extern "C" fn rc256_pinned() -> i32 { 256 }
                """
                lockfile = RustCall.lockfile_path(block)
                @test !isfile(lockfile)
                lib = RustCall._compile_and_load_rust(block, "pinned", 0)
                @test ccall(RustCall.get_function_pointer(lib, "rc256_pinned"), Int32, ()) == 256
                # The first build resolved and persisted the set.
                @test isfile(lockfile)
                content = read(lockfile, String)
                @test occursin("name = \"itoa\"", content)
                @test occursin("name = \"$(RustCall.CARGO_BLOCK_PACKAGE)\"", content)
                # The block's cache entry is keyed with that file's content.
                expanded = RustCall.expand_inline(block; cfg = :cargo)
                _, build_env_key = RustCall._cargo_build_env_for(nothing)
                id = RustCall._cargo_block_id(expanded.source, deps, build_env_key;
                    cargo_config = RustCall._cargo_config_digest(ENV; dir = tempdir()),
                    cargo_lock = RustCall._file_content_digest(lockfile))
                @test RustCall.get_cargo_cached_library(RustCall.artifact_key(id)) !== nothing

                # A second block declaring the same set — another machine, or
                # this one later — replays the file: no re-resolution (the file
                # is untouched) and a project seeded from it carries the
                # identical bytes, which is what `--locked` then enforces.
                stamp = mtime(lockfile)
                second = replace(block, "rc256_pinned() -> i32 { 256 }" =>
                                        "rc256_again() -> i32 { 257 }")
                lib2 = RustCall._compile_and_load_rust(second, "pinned-again", 0)
                @test ccall(RustCall.get_function_pointer(lib2, "rc256_again"), Int32, ()) == 257
                @test mtime(lockfile) == stamp
                @test read(lockfile, String) == content
                project = RustCall.create_cargo_project(RustCall.CARGO_BLOCK_PACKAGE, deps)
                try
                    digest = RustCall.ensure_cargo_lockfile!(project)
                    @test digest == RustCall._file_content_digest(lockfile)
                    @test read(joinpath(project.path, "Cargo.lock"), String) == content
                finally
                    RustCall.cleanup_cargo_project(project)
                end
                # A project with no dependencies of its own has no store entry.
                bare = RustCall.create_cargo_project("rc256_bare", RustCall.DependencySpec[])
                try
                    @test RustCall.ensure_cargo_lockfile!(bare) === nothing
                finally
                    RustCall.cleanup_cargo_project(bare)
                end

                # A changed resolution is a different artifact: rewrite the
                # persisted file and the key moves, so a cache hit can never
                # answer for another graph.
                moved = RustCall._cargo_block_id(expanded.source, deps, build_env_key;
                    cargo_config = RustCall._cargo_config_digest(ENV; dir = tempdir()),
                    cargo_lock = RustCall._file_content_digest(lockfile) * "-other")
                @test RustCall.artifact_key(moved) != RustCall.artifact_key(id)

                # Offline: with the registry warm from the build above, the same
                # set builds again — `--locked --offline` — after the cache is
                # cleared; the lockfile survives `clear_cargo_cache`, being an
                # input and not an output.
                RustCall.clear_cargo_cache()
                @test isfile(lockfile)
                lib3 = withenv("RUSTCALL_OFFLINE" => "1") do
                    RustCall._compile_and_load_rust(second, "pinned-offline", 0)
                end
                @test ccall(RustCall.get_function_pointer(lib3, "rc256_again"), Int32, ()) == 257
                for name in unique([lib, lib2, lib3])
                    try
                        RustCall.unload_library(name)
                    catch
                    end
                end
            end
        end

        @testset "offline without a registry cache fails loudly, not slowly" begin
            with_isolated_cargo_cache() do
                # A package no registry has: offline resolution must come back
                # with Cargo's error at once, not hang on a download.
                missing = [RustCall.DependencySpec("rustcall-no-such-package-ever";
                                                   version = "=99.99.99")]
                project = RustCall.create_cargo_project(RustCall.CARGO_BLOCK_PACKAGE, missing)
                try
                    started = time()
                    err = withenv("RUSTCALL_OFFLINE" => "1") do
                        try
                            RustCall.ensure_cargo_lockfile!(project)
                            nothing
                        catch e
                            e
                        end
                    end
                    @test err isa RustCall.CargoBuildError
                    @test occursin("RUSTCALL_OFFLINE", sprint(showerror, err))
                    @test time() - started < 60
                    @test !isfile(RustCall.lockfile_path(missing))
                finally
                    RustCall.cleanup_cargo_project(project)
                end
            end
        end
    end
end
