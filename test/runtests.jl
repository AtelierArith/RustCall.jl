using RustCall
using ParallelTestRunner

args = parse_args(ARGS)
testsuite = find_tests(@__DIR__)
serial_testsuite = Dict{String, Expr}()
serial_test_names = ("test_cache", "test_core_api", "test_cargo")

for test_name in collect(keys(testsuite))
    basename = split(test_name, '/')[end]
    if !startswith(basename, "test_")
        delete!(testsuite, test_name)
    end
end

if args.list !== nothing
    println("Available tests:")
    for test in sort(collect(keys(testsuite)))
        println(" - $test")
    end
    exit(0)
end

if filter_tests!(testsuite, args)
    # Preserve the pre-migration default suite: test_phase4.jl was not in the old harness.
    delete!(testsuite, "test_phase4")
end

for test_name in serial_test_names
    if haskey(testsuite, test_name)
        serial_testsuite[test_name] = pop!(testsuite, test_name)
    end
end

init_code = quote
    using Test
    using RustCall
end

parallel_error = Ref{Any}(nothing)
serial_error = Ref{Any}(nothing)

if !isempty(testsuite)
    try
        runtests(RustCall, args; testsuite, init_code)
    catch err
        parallel_error[] = err
    end
end

if !isempty(serial_testsuite)
    serial_argv = String["--jobs=1"]
    args.verbose !== nothing && push!(serial_argv, "--verbose")
    args.quickfail !== nothing && push!(serial_argv, "--quickfail")
    append!(serial_argv, args.positionals)
    serial_args = parse_args(serial_argv)
    try
        runtests(RustCall, serial_args; testsuite=serial_testsuite, init_code)
    catch err
        serial_error[] = err
    end
end

if parallel_error[] !== nothing && serial_error[] !== nothing
    throw(CompositeException(Any[parallel_error[], serial_error[]]))
elseif parallel_error[] !== nothing
    throw(parallel_error[])
elseif serial_error[] !== nothing
    throw(serial_error[])
end
