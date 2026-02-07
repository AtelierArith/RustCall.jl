# Test cases converted from examples/ownership_examples.jl
using RustCall
using Test

@testset "Ownership Examples" begin
    if !is_rust_helpers_available()
        @warn "Rust helpers library not available, skipping ownership examples tests"
        return
    end

    @testset "RustBox - Single Ownership" begin
        box_i32 = RustBox(Int32(42))
        @test is_valid(box_i32)
        @test box_i32.ptr !== C_NULL

        box_i64 = RustBox(Int64(123456789))
        box_f64 = RustBox(Float64(3.14159))
        box_bool = RustBox(true)

        @test is_valid(box_i64)
        @test is_valid(box_f64)
        @test is_valid(box_bool)

        drop!(box_i32)
        drop!(box_i64)
        drop!(box_f64)
        drop!(box_bool)

        @test is_dropped(box_i32)
    end

    @testset "RustRc - Reference Counting" begin
        rc1 = RustRc(Int32(100))
        @test is_valid(rc1)

        rc2 = clone(rc1)
        @test rc1.ptr == rc2.ptr
        @test is_valid(rc2)

        drop!(rc1)
        @test is_dropped(rc1)
        @test is_valid(rc2)  # Still valid because rc2 holds reference

        drop!(rc2)
        @test is_dropped(rc2)
    end

    @testset "RustArc - Atomic Reference Counting" begin
        arc1 = RustArc(Int32(200))
        @test is_valid(arc1)

        arc2 = clone(arc1)
        arc3 = clone(arc2)
        @test arc1.ptr == arc2.ptr == arc3.ptr

        # Test thread-safe usage
        if Threads.nthreads() > 1
            results = Int[]
            lk = ReentrantLock()

            tasks = [Threads.@spawn begin
                local_arc = clone(arc1)
                sleep(0.001)
                lock(lk) do
                    push!(results, i)
                end
                drop!(local_arc)
            end for i in 1:4]

            foreach(wait, tasks)
            @test length(results) == 4
        end

        @test is_valid(arc1)
        @test is_valid(arc2)
        @test is_valid(arc3)

        drop!(arc1)
        drop!(arc2)
        drop!(arc3)
    end

    @testset "Memory Management Patterns" begin
        # Pattern 1: Temporary allocation
        box = RustBox(Int32(42))
        try
            @test is_valid(box)
        finally
            drop!(box)
            @test is_dropped(box)
        end

        # Pattern 2: Multiple Rc references
        rc_main = RustRc(Int64(999))
        rc_refs = [clone(rc_main) for _ in 1:5]
        @test length(rc_refs) == 5
        @test all(is_valid, rc_refs)

        drop!(rc_main)
        @test all(is_valid, rc_refs)  # Still valid

        foreach(drop!, rc_refs)
        @test all(is_dropped, rc_refs)

        # Pattern 3: Arc for thread-safe shared data
        shared = RustArc(Float64(3.14159))
        workers = [clone(shared) for _ in 1:min(4, Threads.nthreads())]
        @test length(workers) >= 1
        @test all(is_valid, workers)

        drop!(shared)
        @test all(is_valid, workers)

        foreach(drop!, workers)
        @test all(is_dropped, workers)
    end

    @testset "Performance Considerations" begin
        # Benchmark Box allocation/deallocation
        n_iterations = 100

        # Warm up
        for _ in 1:10
            b = RustBox(Int32(0))
            drop!(b)
        end

        # Benchmark
        t_start = time_ns()
        for i in 1:n_iterations
            b = RustBox(Int32(i))
            drop!(b)
        end
        t_end = time_ns()
        elapsed = (t_end - t_start) / 1e6
        @test elapsed >= 0  # Just check it completes

        # Benchmark Rc clone
        rc = RustRc(Int32(42))
        clones = RustRc{Int32}[]
        for _ in 1:n_iterations
            push!(clones, clone(rc))
        end
        @test length(clones) == n_iterations
        @test all(is_valid, clones)

        foreach(drop!, clones)
        drop!(rc)
    end
end
