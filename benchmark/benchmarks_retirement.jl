# Lower-bound cost probe for automatic image reclamation (#291).
# Run: julia --threads=4 --project benchmark/benchmarks_retirement.jl
# This is NOT a reclamation implementation: a correct protocol also needs
# publication/recheck ordering, live-object pins, and safe finalizer handling.
using BenchmarkTools
using Printf
using RustCall
using Test

@noinline _retirement_raw(ptr, value) = ccall(ptr, Int32, (Int32,), value)

@noinline function _retirement_pinned(ptr, value, readers)
    Threads.atomic_add!(readers, 1)
    try
        return _retirement_raw(ptr, value)
    finally
        Threads.atomic_sub!(readers, 1)
    end
end

function _retirement_batch(ptr, readers, pinned, workers, calls)
    tasks = @sync map(1:workers) do _
        Threads.@spawn begin
            total = Int64(0)
            for _ in 1:calls
                total += pinned ? _retirement_pinned(ptr, Int32(41), readers) :
                                  _retirement_raw(ptr, Int32(41))
            end
            total
        end
    end
    return sum(fetch, tasks)
end

function run_retirement_benchmark()
    name = RustCall._compile_and_load_rust("""
        #[julia]
        pub fn retirement_probe(value: i32) -> i32 { value + 1 }
        """, @__FILE__, 1)
    try
        ptr = RustCall.get_function_pointer(name, "retirement_probe")
        readers = Threads.Atomic{Int}(0)
        calls = 50_000
        @testset "reader-pin cost probe preserves results (#291)" begin
            @test _retirement_raw(ptr, Int32(41)) == 42
            @test _retirement_pinned(ptr, Int32(41), readers) == 42
            @test readers[] == 0
            for workers in unique((1, Threads.nthreads()))
                expected = Int64(42) * workers * calls
                @test _retirement_batch(ptr, readers, false, workers, calls) == expected
                @test _retirement_batch(ptr, readers, true, workers, calls) == expected
                @test readers[] == 0
            end
        end
        println("platform: ", Sys.KERNEL, " ", Sys.ARCH)
        println("julia: ", VERSION, "; rustc: ", RustCall.get_rustc_version())
        for workers in unique((1, Threads.nthreads()))
            raw = @benchmark _retirement_batch($ptr, $readers, false, $workers, $calls) samples=20 evals=1
            pinned = @benchmark _retirement_batch($ptr, $readers, true, $workers, $calls) samples=20 evals=1
            count = workers * calls
            # Wall time / completed calls measures throughput, not individual
            # call latency when workers overlap.
            @printf("%d worker(s), wall ns/completed call: raw %.2f; shared reader pin %.2f; ratio %.2fx\n",
                    workers, median(raw).time / count, median(pinned).time / count,
                    median(pinned).time / median(raw).time)
            @test readers[] == 0
        end
    finally
        # All spawned calls have joined before this explicit close.
        RustCall.unload_library(name; close = true)
    end
end

run_retirement_benchmark()
