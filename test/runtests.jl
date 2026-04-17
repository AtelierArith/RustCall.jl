using RustCall
using ParallelTestRunner

args = parse_args(ARGS)
testsuite = find_tests(@__DIR__)

if filter_tests!(testsuite, args)
    # Preserve the pre-migration default suite: test_phase4.jl was not in the old harness.
    delete!(testsuite, "test_phase4")
end

runtests(RustCall, args; testsuite, init_code=quote
    using Test
    using RustCall
end)
