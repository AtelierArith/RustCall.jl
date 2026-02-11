# Tests for hot reload functionality

using Test
using RustCall
using RustToolChain: cargo

# Path to the sample crate
const SAMPLE_CRATE_PATH = joinpath(dirname(@__DIR__), "examples", "sample_crate")

@testset "Hot Reload" begin

    @testset "File discovery" begin
        if !isdir(SAMPLE_CRATE_PATH)
            @warn "Sample crate not found, skipping file discovery tests"
            return
        end

        # Test finding Rust source files
        files = RustCall.find_rust_source_files(SAMPLE_CRATE_PATH)
        @test !isempty(files)
        @test all(f -> endswith(f, ".rs"), files)
        @test any(f -> endswith(f, "lib.rs"), files)
    end

    @testset "File modification time" begin
        # Test getting modification time
        mtime = RustCall.get_file_mtime(@__FILE__)
        @test mtime > 0.0

        # Non-existent file should return 0.0
        @test RustCall.get_file_mtime("/nonexistent/file.rs") == 0.0
    end

    @testset "Hot reload state" begin
        # Test creating a hot reload state
        state = RustCall.HotReloadState(
            "/tmp/test_crate",
            "/tmp/lib.so",
            "TestLib",
            ["/tmp/test_crate/src/lib.rs"],
            Dict{String, Float64}(),
            nothing,
            false,
            nothing
        )

        @test state.crate_path == "/tmp/test_crate"
        @test state.lib_name == "TestLib"
        @test !state.enabled
    end

    @testset "Hot reload registry" begin
        # Clear the registry first
        empty!(RustCall.HOT_RELOAD_REGISTRY)

        # Initially no crates should be registered
        @test isempty(RustCall.list_hot_reload_crates())

        # Test global enable/disable
        RustCall.set_hot_reload_global(true)
        @test RustCall.HOT_RELOAD_ENABLED[]

        RustCall.set_hot_reload_global(false)
        @test !RustCall.HOT_RELOAD_ENABLED[]

        # Re-enable for other tests
        RustCall.set_hot_reload_global(true)
    end

    @testset "Library filename" begin
        # Test platform-specific library filename generation
        filename = RustCall._get_library_filename("my_crate")

        if Sys.iswindows()
            @test filename == "my_crate.dll"
        elseif Sys.isapple()
            @test filename == "libmy_crate.dylib"
        else
            @test filename == "libmy_crate.so"
        end

        # Test hyphen to underscore conversion
        filename2 = RustCall._get_library_filename("my-rust-crate")
        if Sys.isapple()
            @test filename2 == "libmy_rust_crate.dylib"
        end
    end

    @testset "is_hot_reload_enabled" begin
        # Clear registry
        empty!(RustCall.HOT_RELOAD_REGISTRY)

        # Non-registered crate should return false
        @test !RustCall.is_hot_reload_enabled("NonExistentLib")
    end

    @testset "Per-library reload lock" begin
        # Verify _get_reload_lock returns a ReentrantLock
        lock1 = RustCall._get_reload_lock("test_lib_a")
        @test lock1 isa ReentrantLock

        # Same library name returns the same lock instance
        lock2 = RustCall._get_reload_lock("test_lib_a")
        @test lock1 === lock2

        # Different library names return different locks
        lock3 = RustCall._get_reload_lock("test_lib_b")
        @test lock1 !== lock3

        # Clean up
        lock(RustCall.RELOAD_LOCKS_LOCK) do
            delete!(RustCall.RELOAD_LOCKS, "test_lib_a")
            delete!(RustCall.RELOAD_LOCKS, "test_lib_b")
        end
    end

    @testset "Per-library lock serializes reload across tasks" begin
        # Verify that acquiring the lock blocks other tasks
        lib_lock = RustCall._get_reload_lock("test_serialization")
        order = Int[]

        lock(lib_lock)
        try
            # Spawn a task that tries to acquire the same lock
            t = @async begin
                lock(lib_lock)
                try
                    push!(order, 2)
                finally
                    unlock(lib_lock)
                end
            end

            # Give the async task time to attempt the lock
            sleep(0.1)
            # Task should be blocked — order should still be empty
            @test isempty(order)
            push!(order, 1)
        finally
            unlock(lib_lock)
        end

        # Now the async task should complete
        sleep(0.1)
        @test order == [1, 2]

        # Clean up
        lock(RustCall.RELOAD_LOCKS_LOCK) do
            delete!(RustCall.RELOAD_LOCKS, "test_serialization")
        end
    end

end

# Integration tests with actual crate (slower)
@testset "Hot Reload Integration" begin
    if !isdir(SAMPLE_CRATE_PATH)
        @warn "Sample crate not found, skipping hot reload integration tests"
        return
    end

    # Check if cargo is available
    try
        run(pipeline(`$(cargo()) --version`, devnull))
    catch
        @warn "Cargo not available, skipping hot reload integration tests"
        return
    end

    @testset "Enable and disable hot reload" begin
        # Clear registry
        empty!(RustCall.HOT_RELOAD_REGISTRY)

        try
            # Enable hot reload
            state = RustCall.enable_hot_reload("SampleCrateHotReload", SAMPLE_CRATE_PATH)

            @test state !== nothing
            @test state.enabled
            @test haskey(RustCall.HOT_RELOAD_REGISTRY, "SampleCrateHotReload")
            @test RustCall.is_hot_reload_enabled("SampleCrateHotReload")
            @test "SampleCrateHotReload" in RustCall.list_hot_reload_crates()

            # Disable hot reload
            RustCall.disable_hot_reload("SampleCrateHotReload")
            sleep(0.1)  # Give task time to stop

            @test !RustCall.HOT_RELOAD_REGISTRY["SampleCrateHotReload"].enabled

        finally
            # Clean up
            RustCall.disable_all_hot_reload()
            sleep(0.1)
            empty!(RustCall.HOT_RELOAD_REGISTRY)
        end
    end

    @testset "Check for changes" begin
        # Clear registry
        empty!(RustCall.HOT_RELOAD_REGISTRY)

        try
            state = RustCall.enable_hot_reload("SampleCrateCheck", SAMPLE_CRATE_PATH)

            # Initially no changes (we just recorded the times)
            @test !RustCall.check_for_changes(state)

            # Simulate a change by modifying the mtime record
            if !isempty(state.source_files)
                first_file = first(state.source_files)
                state.last_modified[first_file] = 0.0  # Reset to old time
                @test RustCall.check_for_changes(state)
            end

        finally
            RustCall.disable_all_hot_reload()
            sleep(0.1)
            empty!(RustCall.HOT_RELOAD_REGISTRY)
        end
    end

    @testset "Callback support" begin
        empty!(RustCall.HOT_RELOAD_REGISTRY)

        callback_called = Ref(false)
        callback_lib_name = Ref("")

        function my_callback(lib_name, success, error)
            callback_called[] = true
            callback_lib_name[] = lib_name
        end

        try
            state = RustCall.enable_hot_reload(
                "SampleCrateCallback",
                SAMPLE_CRATE_PATH,
                callback = my_callback
            )

            @test state.rebuild_callback !== nothing
            @test state.rebuild_callback === my_callback

        finally
            RustCall.disable_all_hot_reload()
            sleep(0.1)
            empty!(RustCall.HOT_RELOAD_REGISTRY)
        end
    end

end
