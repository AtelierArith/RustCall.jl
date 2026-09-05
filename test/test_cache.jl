# Tests for compilation caching

using RustCall
using Test

@testset "Compilation Caching" begin
    # Clear cache before testing
    RustCall.clear_cache()

    @testset "Cache Directory Management" begin
        cache_dir = RustCall.get_cache_dir()
        @test isdir(cache_dir)
        @test occursin("RustCall", cache_dir)

        metadata_dir = RustCall.get_metadata_dir()
        @test isdir(metadata_dir)
    end

    @testset "Cache format namespace (#278)" begin
        # Every cached artifact lives under a directory named for the on-disk
        # cache format, so a key-formula change (#278 Phase B) cannot serve a
        # hit written by the previous format.
        cache_dir = RustCall.get_cache_dir()
        @test basename(cache_dir) == "v$(RustCall.CACHE_FORMAT_VERSION)"
        @test basename(RustCall._cache_format_root()) == "RustCall"
        @test dirname(cache_dir) == RustCall._cache_format_root()

        # The Cargo and metadata trees nest under the versioned directory.
        @test startswith(RustCall.get_metadata_dir(), cache_dir)
        @test startswith(RustCall.get_cargo_cache_dir(), cache_dir)

        # Older siblings are swept best-effort; newer ones are left alone.
        root = RustCall._cache_format_root()
        old_dir = joinpath(root, "v1")
        new_dir = joinpath(root, "v$(RustCall.CACHE_FORMAT_VERSION + 1)")
        mkpath(old_dir)
        mkpath(new_dir)
        write(joinpath(old_dir, "x.txt"), "old")
        try
            stale = RustCall._stale_cache_format_dirs()
            @test old_dir in stale
            @test !(new_dir in stale)
            @test !(cache_dir in stale)

            RustCall.sweep_stale_cache_formats()
            @test !isdir(old_dir)
            @test isdir(new_dir)      # a future format's cache is not ours to delete
            @test isdir(cache_dir)
        finally
            rm(new_dir; recursive = true, force = true)
            rm(old_dir; recursive = true, force = true)
        end
    end

    @testset "The sweep never deletes what RustCall did not write (#287 review)" begin
        # `_cache_format_root()` is `.../compiled/vX.Y/RustCall` — *Julia's own*
        # package precompile directory for RustCall, where it keeps `<slug>.ji`
        # and `<slug>.dylib` native images. Deleting every regular file there
        # would throw away fresh precompilation output and could race another
        # Julia process writing it.
        root = RustCall._cache_format_root()
        mkpath(root)

        # Named exactly as Julia names them (a package slug: mixed case and an
        # underscore, so `_LEGACY_CACHE_FILE` cannot match).
        julia_ji = joinpath(root, "qLtCw_2ChqG.ji")
        julia_img = joinpath(root, "qLtCw_2ChqG." * (Sys.iswindows() ? "dll" :
                                                     Sys.isapple() ? "dylib" : "so"))
        unrelated = joinpath(root, "notes.txt")
        # ... and a genuine v1 artifact: a `stable_content_hash` key plus the
        # library extension, which is all v1 ever wrote loose in this directory.
        v1_key = RustCall.stable_content_hash("a v1 cache entry")
        legacy_lib = joinpath(root, v1_key * RustCall.get_library_extension())
        legacy_sum = legacy_lib * ".sha256"
        legacy_ir = joinpath(root, v1_key * ".ll")

        for f in (julia_ji, julia_img, unrelated, legacy_lib, legacy_sum, legacy_ir)
            write(f, "x")
        end
        try
            # The classifier is the safety property: only ours match.
            listed = RustCall._legacy_cache_files()
            @test legacy_lib in listed
            @test legacy_sum in listed
            @test legacy_ir in listed
            @test !(julia_ji in listed)
            @test !(julia_img in listed)
            @test !(unrelated in listed)

            # Off by default: a plain sweep touches no loose file at all, and
            # neither does an age-based cleanup.
            RustCall.sweep_stale_cache_formats()
            @test all(isfile, (julia_ji, julia_img, unrelated, legacy_lib, legacy_sum, legacy_ir))
            RustCall.cleanup_old_cache(0)
            @test all(isfile, (julia_ji, julia_img, unrelated, legacy_lib, legacy_sum, legacy_ir))

            # Explicitly requested: only the RustCall artifacts go.
            RustCall.sweep_stale_cache_formats(; legacy_files = true)
            @test !isfile(legacy_lib)
            @test !isfile(legacy_sum)
            @test !isfile(legacy_ir)
            @test isfile(julia_ji)      # Julia's precompile output survives
            @test isfile(julia_img)
            @test isfile(unrelated)
        finally
            for f in (julia_ji, julia_img, unrelated, legacy_lib, legacy_sum, legacy_ir)
                rm(f; force = true)
            end
        end

        # The pattern itself, stated directly.
        @test occursin(RustCall._LEGACY_CACHE_FILE, "$(RustCall.stable_content_hash("k")).ll")
        for name in ("qLtCw_2ChqG.ji", "qLtCw_2ChqG.dylib", "qLtCw_2ChqG.so",
                     "notes.txt", "Manifest.toml", "ABCDEF0123456789.dylib",
                     "deadbeef.stale", "libfoo.dylib")
            @test !occursin(RustCall._LEGACY_CACHE_FILE, name)
        end
    end

    @testset "Cache Key Generation" begin
        code1 = """
        #[no_mangle]
        pub extern "C" fn test1() -> i32 { 42 }
        """

        code2 = """
        #[no_mangle]
        pub extern "C" fn test2() -> i32 { 42 }
        """

        compiler = RustCall.get_default_compiler()

        key1 = RustCall.generate_cache_key(code1, compiler)
        key2 = RustCall.generate_cache_key(code2, compiler)

        @test key1 != key2  # Different code should produce different keys
        @test length(key1) == 64  # SHA256 produces 64 hex characters
        @test length(key2) == 64

        # Same code should produce same key (deterministic)
        key1_again = RustCall.generate_cache_key(code1, compiler)
        @test key1 == key1_again

        # The key is `artifact_key` of an ArtifactId and nothing else (#278):
        # there is no second formula to keep in sync here.
        expected_id = RustCall.ArtifactId(
            kind = "rustc",
            source = code1,
            target_triple = compiler.target_triple,
            codegen = RustCall.artifact_codegen_options(compiler),
            cfg = String[RustCall.stable_content_hash(RustCall._cfg_snapshot(:strict))],
            build_env = RustCall.artifact_build_env(RustCall.RUSTC_BUILD_ENV_NAMES),
        )
        @test key1 == RustCall.artifact_key(expected_id)

        # Compiler settings are part of the key.
        @test key1 != RustCall.generate_cache_key(
            code1, RustCall.RustCompiler(optimization_level = 0))

        # The cfg snapshot is part of the key, and an explicit snapshot wins.
        @test RustCall.generate_cache_key(code1, compiler; cfg_text = "target_os=\"nowhere\"") != key1
    end

    @testset "The compiler in the key is the compiler that runs (#252)" begin
        # `artifact_compiler_identity` reads RustToolChain.rustc()/cargo() —
        # the very commands src/compiler.jl and src/cargobuild.jl invoke — and
        # raises rather than degrading to the string "unknown".
        @test !isdefined(RustCall, :_get_rustc_version)
        @test !isdefined(RustCall, :_cached_rustc_version)
        @test !isdefined(RustCall, :_get_cargo_version)

        identity_ok = try
            RustCall.artifact_compiler_identity()
            true
        catch
            false
        end
        if !identity_ok
            @info "Skipping #252 key test: RustToolChain rustc/cargo unavailable"
        else
            identity_str = RustCall.artifact_compiler_identity()
            @test !occursin("unknown", identity_str)

            # Acceptance test from the issue: a changed toolchain fingerprint
            # must produce a cache miss, not a stale hit.
            code = "#[no_mangle]\npub extern \"C\" fn fingerprint_probe() -> i32 { 1 }\n"
            compiler = RustCall.get_default_compiler()
            key_before = RustCall.generate_cache_key(code, compiler)
            saved = RustCall._TOOLCHAIN_FINGERPRINT[]
            try
                RustCall._TOOLCHAIN_FINGERPRINT[] = RustCall.stable_content_hash("a different toolchain")
                key_after = RustCall.generate_cache_key(code, compiler)
                @test key_after != key_before
                @test !RustCall.is_cache_valid(key_before, code, compiler)
            finally
                RustCall._TOOLCHAIN_FINGERPRINT[] = saved
                RustCall._reset_extractor_state!()
            end
            @test RustCall.generate_cache_key(code, compiler) == key_before
        end
    end

    @testset "stable_content_hash utility" begin
        # stable_content_hash must be deterministic and session-stable
        h1 = RustCall.stable_content_hash("hello")
        h2 = RustCall.stable_content_hash("hello")
        @test h1 == h2
        @test length(h1) == 64  # SHA-256 → 64 hex chars

        # Different inputs produce different hashes
        h3 = RustCall.stable_content_hash("world")
        @test h1 != h3
    end

    @testset "Cross-process cache key stability" begin
        # Verify that generate_cache_key and stable_content_hash produce
        # identical results in a separate Julia process (guards against
        # accidental use of session-randomized hash()).
        code = "fn test() -> i32 { 42 }"
        compiler = RustCall.get_default_compiler()
        key_here = RustCall.generate_cache_key(code, compiler)

        project_dir = pkgdir(RustCall)
        key_subprocess = readchomp(`$(Base.julia_cmd()) --project=$project_dir -e "
            using RustCall
            code = \"fn test() -> i32 { 42 }\"
            compiler = RustCall.get_default_compiler()
            print(RustCall.generate_cache_key(code, compiler))
        "`)

        @test key_here == key_subprocess

        # Also verify stable_content_hash directly
        hash_here = RustCall.stable_content_hash("cross-process test data")
        hash_subprocess = readchomp(`$(Base.julia_cmd()) --project=$project_dir -e "
            using RustCall
            print(RustCall.stable_content_hash(\"cross-process test data\"))
        "`)

        @test hash_here == hash_subprocess
    end

    @testset "Cache Operations" begin
        # Test cache size
        initial_size = RustCall.get_cache_size()
        @test initial_size >= 0

        # Test listing cached libraries (should be empty initially)
        cached_libs = RustCall.list_cached_libraries()
        @test isa(cached_libs, Vector{String})
    end

    @testset "Cache Metadata Round-trip (issue #90)" begin
        using Dates

        test_key = "test_metadata_roundtrip_key_0123456789abcdef"
        test_metadata = RustCall.CacheMetadata(
            test_key,
            "abcdef1234567890abcdef1234567890",
            "2_false_x86_64-unknown-linux-gnu",
            "x86_64-unknown-linux-gnu",
            DateTime(2025, 6, 15, 12, 30, 0),
            ["add", "multiply", "divide"]
        )

        # Save metadata
        RustCall.save_cache_metadata(test_key, test_metadata)

        # Load it back
        loaded = RustCall.load_cache_metadata(test_key)
        @test loaded !== nothing
        @test loaded.cache_key == test_key
        @test loaded.code_hash == "abcdef1234567890abcdef1234567890"
        @test loaded.compiler_config == "2_false_x86_64-unknown-linux-gnu"
        @test loaded.target_triple == "x86_64-unknown-linux-gnu"
        @test loaded.created_at == DateTime(2025, 6, 15, 12, 30, 0)
        @test loaded.functions == ["add", "multiply", "divide"]

        # Non-existent key returns nothing
        @test RustCall.load_cache_metadata("nonexistent_key_xyz") === nothing

        # Empty functions list round-trips
        test_key2 = "test_metadata_empty_funcs"
        test_metadata2 = RustCall.CacheMetadata(
            test_key2, "hash2", "config2", "triple2",
            DateTime(2025, 1, 1), String[]
        )
        RustCall.save_cache_metadata(test_key2, test_metadata2)
        loaded2 = RustCall.load_cache_metadata(test_key2)
        @test loaded2 !== nothing
        @test loaded2.functions == String[]

        # Clean up test metadata files
        metadata_dir = RustCall.get_metadata_dir()
        for k in [test_key, test_key2]
            p = joinpath(metadata_dir, "$(k).json")
            isfile(p) && rm(p)
        end
    end

    @testset "Concurrent cache access (issue #91)" begin
        using Dates

        # Verify CACHE_LOCK exists
        @test isdefined(RustCall, :CACHE_LOCK)
        @test RustCall.CACHE_LOCK isa ReentrantLock

        # Run concurrent save/load operations to verify no corruption
        n_tasks = 4
        n_ops = 5
        results = Vector{Bool}(undef, n_tasks)
        test_keys = ["concurrent_test_$(t)_$(i)" for t in 1:n_tasks for i in 1:n_ops]

        tasks = []
        for t in 1:n_tasks
            task = Threads.@spawn begin
                for i in 1:n_ops
                    key = "concurrent_test_$(t)_$(i)"
                    meta = RustCall.CacheMetadata(
                        key, "hash_$(t)_$(i)", "config", "triple",
                        Dates.now(), ["func_$(t)_$(i)"]
                    )
                    RustCall.save_cache_metadata(key, meta)
                    loaded = RustCall.load_cache_metadata(key)
                    if loaded === nothing || loaded.cache_key != key
                        return false
                    end
                end
                return true
            end
            push!(tasks, task)
        end

        for (i, task) in enumerate(tasks)
            results[i] = fetch(task)
        end
        @test all(results)

        # Clean up test metadata files
        metadata_dir = RustCall.get_metadata_dir()
        for key in test_keys
            p = joinpath(metadata_dir, "$(key).json")
            isfile(p) && rm(p)
        end
    end

    # Only run rustc tests if rustc is available
    if RustCall.check_rustc_available()
        @testset "Cache Hit/Miss" begin
            # Clear cache
            RustCall.clear_cache()

            # First compilation (cache miss)
            rust"""
            #[no_mangle]
            pub extern "C" fn cached_add(a: i32, b: i32) -> i32 {
                a + b
            }
            """

            # Call the function to ensure it works
            result1 = @rust cached_add(Int32(10), Int32(20))::Int32
            @test result1 == 30

            # Check that cache was created
            cached_libs = RustCall.list_cached_libraries()
            @test length(cached_libs) > 0

            # Clear in-memory cache
            RustCall.unload_all_libraries()
            empty!(RustCall.RUST_LIBRARIES)
            RustCall.CURRENT_LIB[] = ""

            # Second compilation (should use cache)
            rust"""
            #[no_mangle]
            pub extern "C" fn cached_add(a: i32, b: i32) -> i32 {
                a + b
            }
            """

            # Should still work
            result2 = @rust cached_add(Int32(15), Int32(25))::Int32
            @test result2 == 40
        end

        @testset "Cache Validation" begin
            code = """
            #[no_mangle]
            pub extern "C" fn validation_test() -> i32 { 100 }
            """

            compiler = RustCall.get_default_compiler()
            cache_key = RustCall.generate_cache_key(code, compiler)

            # Test validation with non-existent cache
            @test !RustCall.is_cache_valid(cache_key, code, compiler)

            # After compilation, cache should be valid
            rust"""
            #[no_mangle]
            pub extern "C" fn validation_test() -> i32 { 100 }
            """

            # The library is compiled from the extractor-expanded source
            wrapped_code = RustCall.wrap_rust_code(RustCall.expand_inline(code).source)
            cache_key = RustCall.generate_cache_key(wrapped_code, compiler)
            @test RustCall.is_cache_valid(cache_key, wrapped_code, compiler)
        end

        @testset "Cache Cleanup" begin
            # Test cleanup function exists and runs without error
            removed_count = RustCall.cleanup_old_cache(0)  # Remove all files older than 0 days
            @test removed_count >= 0

            # Test cache size
            cache_size = RustCall.get_cache_size()
            @test cache_size >= 0
        end

        @testset "Cache Clear" begin
            # Ensure we have some cache
            rust"""
            #[no_mangle]
            pub extern "C" fn clear_test() -> i32 { 999 }
            """

            cached_before = RustCall.list_cached_libraries()
            @test length(cached_before) > 0
            cache_size_before = RustCall.get_cache_size()

            # Clear cache
            RustCall.clear_cache()

            cached_after = RustCall.list_cached_libraries()
            cache_size_after = RustCall.get_cache_size()

            # On Windows, DLL files may be locked and cannot be deleted immediately
            # if they are currently loaded by Julia. Allow some files to remain.
            if Sys.iswindows()
                # On Windows, some files may remain locked
                # Check that at least some files were deleted
                @test length(cached_after) < length(cached_before) || length(cached_after) == 0
                @test cache_size_after < cache_size_before || cache_size_after == 0
            else
                # On Unix-like systems, all files should be deleted
                @test length(cached_after) == 0
                @test cache_size_after == 0
            end
        end
    else
        @warn "rustc not found, skipping cache integration tests"
    end
end
