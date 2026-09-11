# Tests for ownership types with Rust integration

using RustCall
using Test

@testset "Ownership Types - Rust Integration" begin
    # Check if Rust helpers library is available
    # For now, we'll test the Julia-side implementation
    # Full integration tests require the Rust helpers library to be compiled

    @testset "RustBox Creation" begin
        # Test that RustBox types are defined
        @test RustCall.RustBox{Int32} <: Any
        @test RustCall.RustBox{Int64} <: Any
        @test RustCall.RustBox{Float32} <: Any
        @test RustCall.RustBox{Float64} <: Any
        @test RustCall.RustBox{Bool} <: Any
    end

    @testset "RustBox Constructors" begin
        # Test that constructors exist (they may fail without Rust library)
        # We'll just check that the functions are defined
        @test hasmethod(RustCall.RustBox, Tuple{Int32})
        @test hasmethod(RustCall.RustBox, Tuple{Int64})
        @test hasmethod(RustCall.RustBox, Tuple{Float32})
        @test hasmethod(RustCall.RustBox, Tuple{Float64})
        @test hasmethod(RustCall.RustBox, Tuple{Bool})
    end

    @testset "RustRc Constructors" begin
        @test hasmethod(RustCall.RustRc, Tuple{Int32})
        @test hasmethod(RustCall.RustRc, Tuple{Int64})
        @test hasmethod(RustCall.RustRc, Tuple{Float32})
        @test hasmethod(RustCall.RustRc, Tuple{Float64})
    end

    @testset "RustArc Constructors" begin
        @test hasmethod(RustCall.RustArc, Tuple{Int32})
        @test hasmethod(RustCall.RustArc, Tuple{Int64})
        @test hasmethod(RustCall.RustArc, Tuple{Float32})
        @test hasmethod(RustCall.RustArc, Tuple{Float64})
    end

    # Only run dummy pointer tests if Rust helpers library is NOT available
    # (to avoid crash when drop! tries to free invalid pointer)
    if !RustCall.is_rust_helpers_available()
        @testset "RustBox State Management (No Library)" begin
            # Create a RustBox with a dummy pointer (for testing without Rust library)
            box = RustCall.RustBox{Int32}(Ptr{Cvoid}(UInt(0x1000)))

            @test !box.dropped
            @test box.ptr != C_NULL
            @test RustCall.is_valid(box)

            # Test drop! (will only mark as dropped, no actual Rust call)
            RustCall.drop!(box)
            @test box.dropped
            @test !RustCall.is_valid(box)

            # Test is_dropped
            @test RustCall.is_dropped(box)
        end

        @testset "RustRc State Management (No Library)" begin
            rc = RustCall.RustRc{Int32}(Ptr{Cvoid}(UInt(0x1000)))

            @test !rc.dropped
            @test rc.ptr != C_NULL
            @test RustCall.is_valid(rc)

            RustCall.drop!(rc)
            @test rc.dropped
            @test !RustCall.is_valid(rc)
        end

        @testset "RustArc State Management (No Library)" begin
            arc = RustCall.RustArc{Int32}(Ptr{Cvoid}(UInt(0x1000)))

            @test !arc.dropped
            @test arc.ptr != C_NULL
            @test RustCall.is_valid(arc)

            RustCall.drop!(arc)
            @test arc.dropped
            @test !RustCall.is_valid(arc)
        end

        @testset "Double-drop safety (No Library)" begin
            # RustBox: drop! twice should not crash
            box = RustCall.RustBox{Int32}(Ptr{Cvoid}(UInt(0x1000)))
            RustCall.drop!(box)
            @test box.dropped
            # Second drop should be a no-op (no crash, no error)
            RustCall.drop!(box)
            @test box.dropped

            # RustRc: drop! twice should not crash
            rc = RustCall.RustRc{Int32}(Ptr{Cvoid}(UInt(0x1000)))
            RustCall.drop!(rc)
            @test rc.dropped
            RustCall.drop!(rc)
            @test rc.dropped

            # RustArc: drop! twice should not crash
            arc = RustCall.RustArc{Int32}(Ptr{Cvoid}(UInt(0x1000)))
            RustCall.drop!(arc)
            @test arc.dropped
            RustCall.drop!(arc)
            @test arc.dropped
        end

        @testset "Deferred drop tracking for memory leak visibility (#120)" begin
            # get_deferred_drop_count should be defined and return an Int
            @test isdefined(RustCall, :get_deferred_drop_count)
            count = RustCall.get_deferred_drop_count()
            @test count isa Int
            @test count >= 0
        end

        @testset "update_*_finalizer dead code removed (#116)" begin
            # update_box_finalizer, update_rc_finalizer, update_arc_finalizer
            # were dangerous because Julia's finalizer() appends (doesn't replace).
            # They must not exist in the module.
            @test !isdefined(RustCall, :update_box_finalizer)
            @test !isdefined(RustCall, :update_rc_finalizer)
            @test !isdefined(RustCall, :update_arc_finalizer)
        end

        @test_skip "Rust helpers library not available, skipping full integration tests"
        @warn "To enable these tests, build the library with: using Pkg; Pkg.build(\"RustCall\")"
    else
        # Full integration tests with actual Rust library
        @testset "RustBox Full Integration" begin
            @testset "RustBox{Int32}" begin
                box = RustCall.RustBox(Int32(42))
                @test RustCall.is_valid(box)
                @test !RustCall.is_dropped(box)
                @test box.ptr != C_NULL

                # Test that it can be dropped
                RustCall.drop!(box)
                @test RustCall.is_dropped(box)
                @test !RustCall.is_valid(box)
            end

            @testset "RustBox{Int64}" begin
                box = RustCall.RustBox(Int64(123456789))
                @test RustCall.is_valid(box)
                RustCall.drop!(box)
                @test RustCall.is_dropped(box)
            end

            @testset "RustBox{Float64}" begin
                box = RustCall.RustBox(Float64(3.14159))
                @test RustCall.is_valid(box)
                RustCall.drop!(box)
                @test RustCall.is_dropped(box)
            end

            @testset "RustBox{Bool}" begin
                box = RustCall.RustBox(true)
                @test RustCall.is_valid(box)
                RustCall.drop!(box)
                @test RustCall.is_dropped(box)
            end

            @testset "Multiple Boxes" begin
                boxes = [RustCall.RustBox(Int32(i)) for i in 1:5]
                @test all(RustCall.is_valid, boxes)

                # Drop all
                foreach(RustCall.drop!, boxes)
                @test all(RustCall.is_dropped, boxes)
            end
        end

        @testset "RustRc Reference Counting" begin
            @testset "Basic Rc Operations" begin
                rc1 = RustCall.RustRc(Int32(100))
                @test RustCall.is_valid(rc1)

                # Clone should increment reference count
                rc2 = RustCall.clone(rc1)
                @test RustCall.is_valid(rc2)
                @test rc1.ptr == rc2.ptr  # Should point to same data

                # Dropping one shouldn't invalidate the other
                RustCall.drop!(rc1)
                @test RustCall.is_valid(rc2)  # Still valid
                @test RustCall.is_dropped(rc1)

                # Drop the last reference
                RustCall.drop!(rc2)
                @test RustCall.is_dropped(rc2)
            end

            @testset "Multiple Rc Clones" begin
                rc1 = RustCall.RustRc(Int32(200))
                rc2 = RustCall.clone(rc1)
                rc3 = RustCall.clone(rc2)

                @test rc1.ptr == rc2.ptr == rc3.ptr

                RustCall.drop!(rc1)
                @test RustCall.is_valid(rc2)
                @test RustCall.is_valid(rc3)

                RustCall.drop!(rc2)
                @test RustCall.is_valid(rc3)

                RustCall.drop!(rc3)
                @test RustCall.is_dropped(rc3)
            end

            @testset "RustRc{Int64}" begin
                rc = RustCall.RustRc(Int64(999))
                @test RustCall.is_valid(rc)
                rc2 = RustCall.clone(rc)
                RustCall.drop!(rc)
                @test RustCall.is_valid(rc2)
                RustCall.drop!(rc2)
                @test RustCall.is_dropped(rc2)
            end

            @testset "RustRc{Float32}" begin
                rc = RustCall.RustRc(Float32(3.14))
                @test RustCall.is_valid(rc)
                rc2 = RustCall.clone(rc)
                @test rc.ptr == rc2.ptr
                RustCall.drop!(rc)
                @test RustCall.is_valid(rc2)
                RustCall.drop!(rc2)
                @test RustCall.is_dropped(rc2)
            end

            @testset "RustRc{Float64}" begin
                rc = RustCall.RustRc(Float64(2.71828))
                @test RustCall.is_valid(rc)
                rc2 = RustCall.clone(rc)
                @test rc.ptr == rc2.ptr
                RustCall.drop!(rc)
                @test RustCall.is_valid(rc2)
                RustCall.drop!(rc2)
                @test RustCall.is_dropped(rc2)
            end
        end

        @testset "RustArc Thread-Safe Reference Counting" begin
            @testset "Basic Arc Operations" begin
                arc1 = RustCall.RustArc(Int32(200))
                @test RustCall.is_valid(arc1)

                arc2 = RustCall.clone(arc1)
                @test RustCall.is_valid(arc2)
                @test arc1.ptr == arc2.ptr

                RustCall.drop!(arc1)
                @test RustCall.is_valid(arc2)
                @test RustCall.is_dropped(arc1)

                RustCall.drop!(arc2)
                @test RustCall.is_dropped(arc2)
            end

            @testset "Multiple Arc Clones" begin
                arc1 = RustCall.RustArc(Int32(300))
                arc2 = RustCall.clone(arc1)
                arc3 = RustCall.clone(arc2)

                @test arc1.ptr == arc2.ptr == arc3.ptr

                RustCall.drop!(arc1)
                @test RustCall.is_valid(arc2)
                @test RustCall.is_valid(arc3)

                RustCall.drop!(arc2)
                @test RustCall.is_valid(arc3)

                RustCall.drop!(arc3)
                @test RustCall.is_dropped(arc3)
            end

            @testset "RustArc{Float32}" begin
                arc = RustCall.RustArc(Float32(1.41421))
                @test RustCall.is_valid(arc)
                arc2 = RustCall.clone(arc)
                @test arc.ptr == arc2.ptr
                RustCall.drop!(arc)
                @test RustCall.is_valid(arc2)
                RustCall.drop!(arc2)
                @test RustCall.is_dropped(arc2)
            end

            @testset "RustArc{Float64}" begin
                arc = RustCall.RustArc(Float64(2.71828))
                @test RustCall.is_valid(arc)
                arc2 = RustCall.clone(arc)
                RustCall.drop!(arc)
                @test RustCall.is_valid(arc2)
                RustCall.drop!(arc2)
                @test RustCall.is_dropped(arc2)
            end
        end

        @testset "Memory Leak Prevention" begin
            # Create and drop many objects to check for leaks
            for i in 1:100
                box = RustCall.RustBox(Int32(i))
                RustCall.drop!(box)
                @test RustCall.is_dropped(box)
            end

            for i in 1:50
                rc = RustCall.RustRc(Int32(i))
                rc2 = RustCall.clone(rc)
                RustCall.drop!(rc)
                RustCall.drop!(rc2)
            end

            for i in 1:50
                arc = RustCall.RustArc(Int32(i))
                arc2 = RustCall.clone(arc)
                RustCall.drop!(arc)
                RustCall.drop!(arc2)
            end
        end

        @testset "Arc Multithread Safety" begin
            # Test Arc with multiple threads
            # Arc is designed to be thread-safe with atomic reference counting

            @testset "Concurrent Clone and Drop" begin
                # Create an Arc
                arc = RustCall.RustArc(Int32(42))
                @test RustCall.is_valid(arc)

                # Clone it multiple times
                clones = [RustCall.clone(arc) for _ in 1:10]
                @test all(RustCall.is_valid, clones)
                @test all(c -> c.ptr == arc.ptr, clones)

                # Drop original
                RustCall.drop!(arc)
                @test RustCall.is_dropped(arc)

                # All clones should still be valid
                @test all(RustCall.is_valid, clones)

                # Drop all clones
                foreach(RustCall.drop!, clones)
                @test all(RustCall.is_dropped, clones)
            end

            @testset "Threaded Arc Operations" begin
                # Create shared Arc
                shared_arc = RustCall.RustArc(Int32(100))
                @test RustCall.is_valid(shared_arc)

                # Track clones from different tasks
                n_tasks = 4
                n_clones_per_task = 5
                all_clones = Vector{RustCall.RustArc{Int32}}[]

                # Each task clones the Arc and stores clones
                tasks = []
                lk = ReentrantLock()
                for _ in 1:n_tasks
                    t = Threads.@spawn begin
                        task_clones = RustCall.RustArc{Int32}[]
                        for _ in 1:n_clones_per_task
                            c = RustCall.clone(shared_arc)
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
                    @test all(RustCall.is_valid, task_clones)
                end

                # Drop original
                RustCall.drop!(shared_arc)
                @test RustCall.is_dropped(shared_arc)

                # All clones should still be valid
                for task_clones in all_clones
                    @test all(RustCall.is_valid, task_clones)
                end

                # Drop all clones from all tasks
                for task_clones in all_clones
                    foreach(RustCall.drop!, task_clones)
                    @test all(RustCall.is_dropped, task_clones)
                end
            end

            @testset "Arc{Int64} Multithread" begin
                arc = RustCall.RustArc(Int64(999999999))
                @test RustCall.is_valid(arc)

                clones = [RustCall.clone(arc) for _ in 1:5]
                @test all(RustCall.is_valid, clones)

                RustCall.drop!(arc)
                @test all(RustCall.is_valid, clones)

                foreach(RustCall.drop!, clones)
                @test all(RustCall.is_dropped, clones)
            end

            @testset "Arc{Float64} Multithread" begin
                arc = RustCall.RustArc(Float64(3.14159265359))
                @test RustCall.is_valid(arc)

                clones = [RustCall.clone(arc) for _ in 1:5]
                @test all(RustCall.is_valid, clones)

                RustCall.drop!(arc)
                @test all(RustCall.is_valid, clones)

                foreach(RustCall.drop!, clones)
                @test all(RustCall.is_dropped, clones)
            end
        end

        @testset "Double-drop safety (With Library)" begin
            # RustBox: drop! twice should not crash
            box = RustCall.RustBox(Int32(42))
            @test RustCall.is_valid(box)
            RustCall.drop!(box)
            @test RustCall.is_dropped(box)
            # Second drop should be a safe no-op
            RustCall.drop!(box)
            @test RustCall.is_dropped(box)

            # RustRc: drop! twice should not crash
            rc = RustCall.RustRc(Int32(100))
            @test RustCall.is_valid(rc)
            RustCall.drop!(rc)
            @test RustCall.is_dropped(rc)
            RustCall.drop!(rc)
            @test RustCall.is_dropped(rc)

            # RustArc: drop! twice should not crash
            arc = RustCall.RustArc(Int32(200))
            @test RustCall.is_valid(arc)
            RustCall.drop!(arc)
            @test RustCall.is_dropped(arc)
            RustCall.drop!(arc)
            @test RustCall.is_dropped(arc)
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
        if RustCall.is_rust_helpers_available()
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
        @test RustCall.deferred_drop_count() isa Int
        @test RustCall.deferred_drop_count() >= 0

        # Test flush_deferred_drops is callable
        count_before = RustCall.deferred_drop_count()
        freed = RustCall.flush_deferred_drops()
        @test freed isa Int
        @test freed >= 0

        # Test _defer_drop adds to the queue
        initial_count = RustCall.deferred_drop_count()
        RustCall._defer_drop(Ptr{Cvoid}(UInt(0xDEAD)), "TestType", :nonexistent_drop)
        @test RustCall.deferred_drop_count() == initial_count + 1

        # Test _defer_vec_drop adds to the queue
        RustCall._defer_vec_drop(Ptr{Cvoid}(UInt(0xBEEF)), UInt(10), UInt(20), "TestVecType", :nonexistent_vec_drop)
        @test RustCall.deferred_drop_count() == initial_count + 2

        # flush_deferred_drops should not crash on unknown symbols
        # (deferred entries with nonexistent symbols remain in the queue)
        if RustCall.is_rust_helpers_available()
            freed = RustCall.flush_deferred_drops()
            # The nonexistent symbols should remain in the failed queue
            @test RustCall.deferred_drop_count() >= 2  # Our test entries should still be there
        end

        # Clean up: remove our test entries
        lock(RustCall.DEFERRED_DROPS_LOCK) do
            filter!(dd -> dd.type_name != "TestType" && dd.type_name != "TestVecType", RustCall.DEFERRED_DROPS)
        end
    end
end
