using RustCall
using ParallelTestRunner

args = parse_args(ARGS)
testsuite = find_tests(@__DIR__)
serial_testsuite = Dict{String, Expr}()

if filter_tests!(testsuite, args)
    # Preserve the pre-migration default suite: test_phase4.jl was not in the old harness.
    delete!(testsuite, "test_phase4")
end

if haskey(testsuite, "test_cache")
    serial_testsuite["test_cache"] = pop!(testsuite, "test_cache")
end

if args.list !== nothing
    println("Available tests:")
    for test in keys(merge(copy(testsuite), serial_testsuite))
        println(" - $test")
    end
    exit(0)
end

init_code = quote
    using Test
    using RustCall
end

if !isempty(testsuite)
    runtests(RustCall, args; testsuite, init_code)
end

if !isempty(serial_testsuite)
    serial_args = ParallelTestRunner.ParsedArgs(
        Some(1),
        args.verbose,
        args.quickfail,
        nothing,
        args.custom,
        args.positionals,
    )
    runtests(RustCall, serial_args; testsuite=serial_testsuite, init_code)
end
