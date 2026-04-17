using RustCall
using ParallelTestRunner

testsuite = find_tests(@__DIR__)
# Preserve the pre-migration default suite: test_phase4.jl was not in the old harness.
delete!(testsuite, "test_phase4")

runtests(RustCall, ARGS; testsuite, init_code=quote
    using Test
    using RustCall
end)
