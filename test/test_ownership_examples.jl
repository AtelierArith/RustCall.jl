# Originally derived from the deleted `examples/ownership_examples.jl` (removed in #9); the tests below are the reference.
using RustCall
using Test

@testset "Ownership Examples" begin
    if !RustCall.is_rust_helpers_available()
        @warn "Rust helpers library not available, skipping ownership examples tests"
        return
    end

    @testset "RustBox - Single Ownership" begin
        box_i32 = RustCall.RustBox(Int32(42))
        @test RustCall.is_valid(box_i32)
        @test box_i32.ptr !== C_NULL

        box_i64 = RustCall.RustBox(Int64(123456789))
        box_f64 = RustCall.RustBox(Float64(3.14159))
        box_bool = RustCall.RustBox(true)

        @test RustCall.is_valid(box_i64)
        @test RustCall.is_valid(box_f64)
        @test RustCall.is_valid(box_bool)

        RustCall.drop!(box_i32)
        RustCall.drop!(box_i64)
        RustCall.drop!(box_f64)
        RustCall.drop!(box_bool)

        @test RustCall.is_dropped(box_i32)
    end

    @testset "RustRc - Reference Counting" begin
        rc1 = RustCall.RustRc(Int32(100))
        @test RustCall.is_valid(rc1)

        rc2 = RustCall.clone(rc1)
        @test rc1.ptr == rc2.ptr
        @test RustCall.is_valid(rc2)

        RustCall.drop!(rc1)
        @test RustCall.is_dropped(rc1)
        @test RustCall.is_valid(rc2)  # Still valid because rc2 holds reference

        RustCall.drop!(rc2)
        @test RustCall.is_dropped(rc2)
    end

    @testset "RustArc - Atomic Reference Counting" begin
        arc1 = RustCall.RustArc(Int32(200))
        @test RustCall.is_valid(arc1)

        arc2 = RustCall.clone(arc1)
        arc3 = RustCall.clone(arc2)
        @test arc1.ptr == arc2.ptr == arc3.ptr

        # Test thread-safe usage
        if Threads.nthreads() > 1
            results = Int[]
            lk = ReentrantLock()

            tasks = [Threads.@spawn begin
                local_arc = RustCall.clone(arc1)
                sleep(0.001)
                lock(lk) do
                    push!(results, i)
                end
                RustCall.drop!(local_arc)
            end for i in 1:4]

            foreach(wait, tasks)
            @test length(results) == 4
        end

        @test RustCall.is_valid(arc1)
        @test RustCall.is_valid(arc2)
        @test RustCall.is_valid(arc3)

        RustCall.drop!(arc1)
        RustCall.drop!(arc2)
        RustCall.drop!(arc3)
    end

    @testset "Memory Management Patterns" begin
        # Pattern 1: Temporary allocation
        box = RustCall.RustBox(Int32(42))
        try
            @test RustCall.is_valid(box)
        finally
            RustCall.drop!(box)
            @test RustCall.is_dropped(box)
        end

        # Pattern 2: Multiple Rc references
        rc_main = RustCall.RustRc(Int64(999))
        rc_refs = [RustCall.clone(rc_main) for _ in 1:5]
        @test length(rc_refs) == 5
        @test all(RustCall.is_valid, rc_refs)

        RustCall.drop!(rc_main)
        @test all(RustCall.is_valid, rc_refs)  # Still valid

        foreach(RustCall.drop!, rc_refs)
        @test all(RustCall.is_dropped, rc_refs)

        # Pattern 3: Arc for thread-safe shared data
        shared = RustCall.RustArc(Float64(3.14159))
        workers = [RustCall.clone(shared) for _ in 1:min(4, Threads.nthreads())]
        @test length(workers) >= 1
        @test all(RustCall.is_valid, workers)

        RustCall.drop!(shared)
        @test all(RustCall.is_valid, workers)

        foreach(RustCall.drop!, workers)
        @test all(RustCall.is_dropped, workers)
    end

    @testset "Performance Considerations" begin
        # Benchmark Box allocation/deallocation
        n_iterations = 100

        # Warm up
        for _ in 1:10
            b = RustCall.RustBox(Int32(0))
            RustCall.drop!(b)
        end

        # Benchmark
        t_start = time_ns()
        for i in 1:n_iterations
            b = RustCall.RustBox(Int32(i))
            RustCall.drop!(b)
        end
        t_end = time_ns()
        elapsed = (t_end - t_start) / 1e6
        @test elapsed >= 0  # Just check it completes

        # Benchmark Rc clone
        rc = RustCall.RustRc(Int32(42))
        clones = RustCall.RustRc{Int32}[]
        for _ in 1:n_iterations
            push!(clones, RustCall.clone(rc))
        end
        @test length(clones) == n_iterations
        @test all(RustCall.is_valid, clones)

        foreach(RustCall.drop!, clones)
        RustCall.drop!(rc)
    end
end
