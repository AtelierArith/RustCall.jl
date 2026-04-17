using RustCall
using ParallelTestRunner

testsuite = find_tests(@__DIR__)

runtests(RustCall, ARGS; testsuite, init_code=quote
    using Test
    using RustCall
end)
