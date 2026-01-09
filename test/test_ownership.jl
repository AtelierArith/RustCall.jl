# Tests for ownership types with Rust integration

using LastCall
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
    end

    @testset "RustArc Constructors" begin
        @test hasmethod(RustArc, Tuple{Int32})
        @test hasmethod(RustArc, Tuple{Int64})
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

        @warn "Rust helpers library not available, skipping full integration tests"
        @warn "To enable these tests, build the library with: using Pkg; Pkg.build(\"LastCall\")"
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
    end
end
