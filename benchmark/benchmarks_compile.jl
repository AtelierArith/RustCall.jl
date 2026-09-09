# Compile-time benchmark for the extractor-based inline-rust pipeline (#271).
#
# Run with:
#   RUSTCALL_EXTRACT=/path/to/rustcall-extract \
#     julia --project benchmark/benchmarks_compile.jl
#
# The cold operation uses a fresh source identity on every sample, so it pays
# for extraction and rustc without a cache hit. The warm operation first builds
# one source, then unloads it and measures repeated disk-cache loads; expansion
# is memoized by that point. BenchmarkTools is used with one evaluation per
# sample because compiling a Rust cdylib is not a nanosecond-scale operation.
using BenchmarkTools
using Printf
using RustCall

RustCall.check_rustc_available() || error("rustc not found; compile benchmarks require Rust")
isempty(get(ENV, "RUSTCALL_EXTRACT", "")) &&
    @warn "RUSTCALL_EXTRACT is not set; use the release rustcall-extract binary for comparable results"

const COMPILE_BENCH_SAMPLES = 3
const WARM_BENCH_SAMPLES = 5

function _compile_bench_source(prefix::AbstractString, id::Integer)
    """
    #[julia]
    pub fn $(prefix)_$(id)() -> i32 { $(id) }
    """
end

function _compile_and_unload(source::String)
    name = RustCall._compile_and_load_rust(source, @__FILE__, 1)
    RustCall.unload_library(name; close = true)
    return nothing
end

function run_compile_benchmark()
    mktempdir() do cache
        withenv("RUSTCALL_CACHE_DIR" => cache) do
            RustCall._reset_cache_dir_memo!()

            cold_id = Ref(0)
            cold = () -> begin
                cold_id[] += 1
                _compile_and_unload(_compile_bench_source("cold_compile", cold_id[]))
            end
            cold_trial = @benchmark $cold() samples = COMPILE_BENCH_SAMPLES evals = 1

            warm_source = _compile_bench_source("warm_compile", 1)
            _compile_and_unload(warm_source)
            warm = () -> _compile_and_unload(warm_source)
            warm_trial = @benchmark $warm() samples = WARM_BENCH_SAMPLES evals = 1

            return (cold_ms = median(cold_trial).time / 1e6,
                    warm_ms = median(warm_trial).time / 1e6,
                    cold_trial = cold_trial,
                    warm_trial = warm_trial)
        end
    end
end

result = run_compile_benchmark()
println("RustCall inline compilation benchmark")
println("platform: ", Sys.KERNEL, " ", Sys.ARCH)
println("julia: ", VERSION)
println("rustc: ", RustCall.get_rustc_version())
@printf("cold (extract + rustc, no cache): %.2f ms median (%d samples)\n",
        result.cold_ms, COMPILE_BENCH_SAMPLES)
@printf("warm (disk cache + memoized expansion): %.2f ms median (%d samples)\n",
        result.warm_ms, WARM_BENCH_SAMPLES)
