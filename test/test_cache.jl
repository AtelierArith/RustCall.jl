# Tests for compilation caching

using RustCall
using Test

@testset "Compilation Caching" begin
    # Clear cache before testing
    clear_cache()

    @testset "Cache Directory Management" begin
        cache_dir = RustCall.get_cache_dir()
        @test isdir(cache_dir)
        @test occursin("RustCall", cache_dir)

        metadata_dir = RustCall.get_metadata_dir()
        @test isdir(metadata_dir)
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

        # Key must be deterministic (session-stable) — verify by computing expected SHA256
        using SHA
        config_str = "$(compiler.optimization_level)_$(compiler.emit_debug_info)_$(compiler.target_triple)"
        expected_key = bytes2hex(sha256("$(code1)\n---\n$(config_str)"))
        @test key1 == expected_key
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
        initial_size = get_cache_size()
        @test initial_size >= 0

        # Test listing cached libraries (should be empty initially)
        cached_libs = list_cached_libraries()
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
            clear_cache()

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
            cached_libs = list_cached_libraries()
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

            wrapped_code = RustCall.wrap_rust_code(code)
            cache_key = RustCall.generate_cache_key(wrapped_code, compiler)
            @test RustCall.is_cache_valid(cache_key, wrapped_code, compiler)
        end

        @testset "Cache Cleanup" begin
            # Test cleanup function exists and runs without error
            removed_count = cleanup_old_cache(0)  # Remove all files older than 0 days
            @test removed_count >= 0

            # Test cache size
            cache_size = get_cache_size()
            @test cache_size >= 0
        end

        @testset "Cache Clear" begin
            # Ensure we have some cache
            rust"""
            #[no_mangle]
            pub extern "C" fn clear_test() -> i32 { 999 }
            """

            cached_before = list_cached_libraries()
            @test length(cached_before) > 0
            cache_size_before = get_cache_size()

            # Clear cache
            clear_cache()

            cached_after = list_cached_libraries()
            cache_size_after = get_cache_size()

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
