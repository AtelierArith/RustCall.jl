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

        # Same code should produce same key
        key1_again = RustCall.generate_cache_key(code1, compiler)
        @test key1 == key1_again
    end

    @testset "Cache Operations" begin
        # Test cache size
        initial_size = get_cache_size()
        @test initial_size >= 0

        # Test listing cached libraries (should be empty initially)
        cached_libs = list_cached_libraries()
        @test isa(cached_libs, Vector{String})
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
