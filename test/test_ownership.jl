# Tests for ownership types with Rust integration

using RustCall
using Test

@testset "Ownership Types - Rust Integration" begin
    # Check if Rust helpers library is available
    # For now, we'll test the Julia-side implementation
    # Full integration tests require the Rust helpers library to be compiled

    @testset "RustBox Creation" begin
        # Test that RustBox types are defined
        @test RustBox{Int32} <: Any
        @test RustBox{Int64} <: Any
        @test RustBox{Float32} <: Any
        @test RustBox{Float64} <: Any
        @test RustBox{Bool} <: Any
    end

    @testset "RustBox Constructors" begin
        # Test that constructors exist (they may fail without Rust library)
        # We'll just check that the functions are defined
        @test hasmethod(RustBox, Tuple{Int32})
        @test hasmethod(RustBox, Tuple{Int64})
        @test hasmethod(RustBox, Tuple{Float32})
        @test hasmethod(RustBox, Tuple{Float64})
        @test hasmethod(RustBox, Tuple{Bool})
    end

    @testset "RustRc Constructors" begin
        @test hasmethod(RustRc, Tuple{Int32})
        @test hasmethod(RustRc, Tuple{Int64})
        @test hasmethod(RustRc, Tuple{Float32})
        @test hasmethod(RustRc, Tuple{Float64})
    end

    @testset "RustArc Constructors" begin
        @test hasmethod(RustArc, Tuple{Int32})
        @test hasmethod(RustArc, Tuple{Int64})
        @test hasmethod(RustArc, Tuple{Float32})
        @test hasmethod(RustArc, Tuple{Float64})
    end

    # Only run dummy pointer tests if Rust helpers library is NOT available
    # (to avoid crash when drop! tries to free invalid pointer)
    if !is_rust_helpers_available()
        @testset "RustBox State Management (No Library)" begin
            # Create a RustBox with a dummy pointer (for testing without Rust library)
            box = RustBox{Int32}(Ptr{Cvoid}(UInt(0x1000)))

            @test !box.dropped
            @test box.ptr != C_NULL
            @test is_valid(box)

            # Test drop! (will only mark as dropped, no actual Rust call)
            drop!(box)
            @test box.dropped
            @test !is_valid(box)

            # Test is_dropped
            @test is_dropped(box)
        end

        @testset "RustRc State Management (No Library)" begin
            rc = RustRc{Int32}(Ptr{Cvoid}(UInt(0x1000)))

            @test !rc.dropped
            @test rc.ptr != C_NULL
            @test is_valid(rc)

            drop!(rc)
            @test rc.dropped
            @test !is_valid(rc)
        end

        @testset "RustArc State Management (No Library)" begin
            arc = RustArc{Int32}(Ptr{Cvoid}(UInt(0x1000)))

            @test !arc.dropped
            @test arc.ptr != C_NULL
            @test is_valid(arc)

            drop!(arc)
            @test arc.dropped
            @test !is_valid(arc)
        end

        @testset "Double-drop safety (No Library)" begin
            # RustBox: drop! twice should not crash
            box = RustBox{Int32}(Ptr{Cvoid}(UInt(0x1000)))
            drop!(box)
            @test box.dropped
            # Second drop should be a no-op (no crash, no error)
            drop!(box)
            @test box.dropped

            # RustRc: drop! twice should not crash
            rc = RustRc{Int32}(Ptr{Cvoid}(UInt(0x1000)))
            drop!(rc)
            @test rc.dropped
            drop!(rc)
            @test rc.dropped

            # RustArc: drop! twice should not crash
            arc = RustArc{Int32}(Ptr{Cvoid}(UInt(0x1000)))
            drop!(arc)
            @test arc.dropped
            drop!(arc)
            @test arc.dropped
        end

        @warn "Rust helpers library not available, skipping full integration tests"
        @warn "To enable these tests, build the library with: using Pkg; Pkg.build(\"RustCall\")"
    else
        # Full integration tests with actual Rust library
        @testset "RustBox Full Integration" begin
            @testset "RustBox{Int32}" begin
                box = RustBox(Int32(42))
                @test is_valid(box)
                @test !is_dropped(box)
                @test box.ptr != C_NULL

                # Test that it can be dropped
                drop!(box)
                @test is_dropped(box)
                @test !is_valid(box)
            end

            @testset "RustBox{Int64}" begin
                box = RustBox(Int64(123456789))
                @test is_valid(box)
                drop!(box)
                @test is_dropped(box)
            end

            @testset "RustBox{Float64}" begin
                box = RustBox(Float64(3.14159))
                @test is_valid(box)
                drop!(box)
                @test is_dropped(box)
            end

            @testset "RustBox{Bool}" begin
                box = RustBox(true)
                @test is_valid(box)
                drop!(box)
                @test is_dropped(box)
            end

            @testset "Multiple Boxes" begin
                boxes = [RustBox(Int32(i)) for i in 1:5]
                @test all(is_valid, boxes)

                # Drop all
                foreach(drop!, boxes)
                @test all(is_dropped, boxes)
            end
        end

        @testset "RustRc Reference Counting" begin
            @testset "Basic Rc Operations" begin
                rc1 = RustRc(Int32(100))
                @test is_valid(rc1)

                # Clone should increment reference count
                rc2 = clone(rc1)
                @test is_valid(rc2)
                @test rc1.ptr == rc2.ptr  # Should point to same data

                # Dropping one shouldn't invalidate the other
                drop!(rc1)
                @test is_valid(rc2)  # Still valid
                @test is_dropped(rc1)

                # Drop the last reference
                drop!(rc2)
                @test is_dropped(rc2)
            end

            @testset "Multiple Rc Clones" begin
                rc1 = RustRc(Int32(200))
                rc2 = clone(rc1)
                rc3 = clone(rc2)

                @test rc1.ptr == rc2.ptr == rc3.ptr

                drop!(rc1)
                @test is_valid(rc2)
                @test is_valid(rc3)

                drop!(rc2)
                @test is_valid(rc3)

                drop!(rc3)
                @test is_dropped(rc3)
            end

            @testset "RustRc{Int64}" begin
                rc = RustRc(Int64(999))
                @test is_valid(rc)
                rc2 = clone(rc)
                drop!(rc)
                @test is_valid(rc2)
                drop!(rc2)
                @test is_dropped(rc2)
            end

            @testset "RustRc{Float32}" begin
                rc = RustRc(Float32(3.14))
                @test is_valid(rc)
                rc2 = clone(rc)
                @test rc.ptr == rc2.ptr
                drop!(rc)
                @test is_valid(rc2)
                drop!(rc2)
                @test is_dropped(rc2)
            end

            @testset "RustRc{Float64}" begin
                rc = RustRc(Float64(2.71828))
                @test is_valid(rc)
                rc2 = clone(rc)
                @test rc.ptr == rc2.ptr
                drop!(rc)
                @test is_valid(rc2)
                drop!(rc2)
                @test is_dropped(rc2)
            end
        end

        @testset "RustArc Thread-Safe Reference Counting" begin
            @testset "Basic Arc Operations" begin
                arc1 = RustArc(Int32(200))
                @test is_valid(arc1)

                arc2 = clone(arc1)
                @test is_valid(arc2)
                @test arc1.ptr == arc2.ptr

                drop!(arc1)
                @test is_valid(arc2)
                @test is_dropped(arc1)

                drop!(arc2)
                @test is_dropped(arc2)
            end

            @testset "Multiple Arc Clones" begin
                arc1 = RustArc(Int32(300))
                arc2 = clone(arc1)
                arc3 = clone(arc2)

                @test arc1.ptr == arc2.ptr == arc3.ptr

                drop!(arc1)
                @test is_valid(arc2)
                @test is_valid(arc3)

                drop!(arc2)
                @test is_valid(arc3)

                drop!(arc3)
                @test is_dropped(arc3)
            end

            @testset "RustArc{Float32}" begin
                arc = RustArc(Float32(1.41421))
                @test is_valid(arc)
                arc2 = clone(arc)
                @test arc.ptr == arc2.ptr
                drop!(arc)
                @test is_valid(arc2)
                drop!(arc2)
                @test is_dropped(arc2)
            end

            @testset "RustArc{Float64}" begin
                arc = RustArc(Float64(2.71828))
                @test is_valid(arc)
                arc2 = clone(arc)
                drop!(arc)
                @test is_valid(arc2)
                drop!(arc2)
                @test is_dropped(arc2)
            end
        end

        @testset "Memory Leak Prevention" begin
            # Create and drop many objects to check for leaks
            for i in 1:100
                box = RustBox(Int32(i))
                drop!(box)
                @test is_dropped(box)
            end

            for i in 1:50
                rc = RustRc(Int32(i))
                rc2 = clone(rc)
                drop!(rc)
                drop!(rc2)
            end

            for i in 1:50
                arc = RustArc(Int32(i))
                arc2 = clone(arc)
                drop!(arc)
                drop!(arc2)
            end
        end

        @testset "Arc Multithread Safety" begin
            # Test Arc with multiple threads
            # Arc is designed to be thread-safe with atomic reference counting

            @testset "Concurrent Clone and Drop" begin
                # Create an Arc
                arc = RustArc(Int32(42))
                @test is_valid(arc)

                # Clone it multiple times
                clones = [clone(arc) for _ in 1:10]
                @test all(is_valid, clones)
                @test all(c -> c.ptr == arc.ptr, clones)

                # Drop original
                drop!(arc)
                @test is_dropped(arc)

                # All clones should still be valid
                @test all(is_valid, clones)

                # Drop all clones
                foreach(drop!, clones)
                @test all(is_dropped, clones)
            end

            @testset "Threaded Arc Operations" begin
                # Create shared Arc
                shared_arc = RustArc(Int32(100))
                @test is_valid(shared_arc)

                # Track clones from different tasks
                n_tasks = 4
                n_clones_per_task = 5
                all_clones = Vector{RustArc{Int32}}[]

                # Each task clones the Arc and stores clones
                tasks = []
                lk = ReentrantLock()
                for _ in 1:n_tasks
                    t = Threads.@spawn begin
                        task_clones = RustArc{Int32}[]
                        for _ in 1:n_clones_per_task
                            c = clone(shared_arc)
                            push!(task_clones, c)
                        end
                        lock(lk) do
                            push!(all_clones, task_clones)
                        end
                    end
                    push!(tasks, t)
                end

                # Wait for all tasks
                foreach(wait, tasks)

                # Verify all clones are valid
                @test length(all_clones) == n_tasks
                for task_clones in all_clones
                    @test length(task_clones) == n_clones_per_task
                    @test all(is_valid, task_clones)
                end

                # Drop original
                drop!(shared_arc)
                @test is_dropped(shared_arc)

                # All clones should still be valid
                for task_clones in all_clones
                    @test all(is_valid, task_clones)
                end

                # Drop all clones from all tasks
                for task_clones in all_clones
                    foreach(drop!, task_clones)
                    @test all(is_dropped, task_clones)
                end
            end

            @testset "Arc{Int64} Multithread" begin
                arc = RustArc(Int64(999999999))
                @test is_valid(arc)

                clones = [clone(arc) for _ in 1:5]
                @test all(is_valid, clones)

                drop!(arc)
                @test all(is_valid, clones)

                foreach(drop!, clones)
                @test all(is_dropped, clones)
            end

            @testset "Arc{Float64} Multithread" begin
                arc = RustArc(Float64(3.14159265359))
                @test is_valid(arc)

                clones = [clone(arc) for _ in 1:5]
                @test all(is_valid, clones)

                drop!(arc)
                @test all(is_valid, clones)

                foreach(drop!, clones)
                @test all(is_dropped, clones)
            end
        end

        @testset "Double-drop safety (With Library)" begin
            # RustBox: drop! twice should not crash
            box = RustBox(Int32(42))
            @test is_valid(box)
            drop!(box)
            @test is_dropped(box)
            # Second drop should be a safe no-op
            drop!(box)
            @test is_dropped(box)

            # RustRc: drop! twice should not crash
            rc = RustRc(Int32(100))
            @test is_valid(rc)
            drop!(rc)
            @test is_dropped(rc)
            drop!(rc)
            @test is_dropped(rc)

            # RustArc: drop! twice should not crash
            arc = RustArc(Int32(200))
            @test is_valid(arc)
            drop!(arc)
            @test is_dropped(arc)
            drop!(arc)
            @test is_dropped(arc)
        end
    end

    @testset "No dangerous update_*_finalizer functions" begin
        # These functions were removed because they appended a second finalizer,
        # risking double-free. Verify they no longer exist.
        @test !isdefined(RustCall, :update_box_finalizer)
        @test !isdefined(RustCall, :update_rc_finalizer)
        @test !isdefined(RustCall, :update_arc_finalizer)
    end

    @testset "safe_dlsym" begin
        @test isdefined(RustCall, :safe_dlsym)

        # Test with invalid symbol on a real library (if available)
        if is_rust_helpers_available()
            lib = RustCall.get_rust_helpers_lib()
            # Valid symbol should work
            ptr = RustCall.safe_dlsym(lib, :rust_box_new_i32)
            @test ptr != C_NULL

            # Invalid symbol should throw a clear error (not segfault)
            @test_throws ErrorException RustCall.safe_dlsym(lib, :nonexistent_symbol_xyz)
            try
                RustCall.safe_dlsym(lib, :nonexistent_symbol_xyz)
            catch e
                @test occursin("not found", e.msg)
                @test occursin("Pkg.build", e.msg)
            end
        end
    end

    @testset "Deferred Drop Infrastructure" begin
        # Test that deferred drop types and functions exist
        @test isdefined(RustCall, :flush_deferred_drops)
        @test isdefined(RustCall, :deferred_drop_count)
        @test isdefined(RustCall, :_defer_drop)
        @test isdefined(RustCall, :_defer_vec_drop)
        @test isdefined(RustCall, :DEFERRED_DROPS)
        @test isdefined(RustCall, :DEFERRED_DROPS_LOCK)

        # Test deferred_drop_count returns an integer
        @test deferred_drop_count() isa Int
        @test deferred_drop_count() >= 0

        # Test flush_deferred_drops is callable
        count_before = deferred_drop_count()
        freed = flush_deferred_drops()
        @test freed isa Int
        @test freed >= 0

        # Test _defer_drop adds to the queue
        initial_count = deferred_drop_count()
        RustCall._defer_drop(Ptr{Cvoid}(UInt(0xDEAD)), "TestType", :nonexistent_drop)
        @test deferred_drop_count() == initial_count + 1

        # Test _defer_vec_drop adds to the queue
        RustCall._defer_vec_drop(Ptr{Cvoid}(UInt(0xBEEF)), UInt(10), UInt(20), "TestVecType", :nonexistent_vec_drop)
        @test deferred_drop_count() == initial_count + 2

        # flush_deferred_drops should not crash on unknown symbols
        # (deferred entries with nonexistent symbols remain in the queue)
        if is_rust_helpers_available()
            freed = flush_deferred_drops()
            # The nonexistent symbols should remain in the failed queue
            @test deferred_drop_count() >= 2  # Our test entries should still be there
        end

        # Clean up: remove our test entries
        lock(RustCall.DEFERRED_DROPS_LOCK) do
            filter!(dd -> dd.type_name != "TestType" && dd.type_name != "TestVecType", RustCall.DEFERRED_DROPS)
        end
    end
end
