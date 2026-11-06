# Isolate Scratch caches before importing RustCall, including direct file runs.
# The support directory is an implicit test-only environment, not a dependency.
pushfirst!(LOAD_PATH, joinpath(@__DIR__, "support"))
using RustCallTestDepot
popfirst!(LOAD_PATH)
RustCallTestDepot.isolate!()

using RustCall
using ParallelTestRunner

args = parse_args(ARGS)
testsuite = find_tests(@__DIR__)
serial_testsuite = Dict{String, Expr}()
# `test_cargo` asserts that one evaluation leaves exactly **one** entry in the
# Cargo cache directory (#287), which only holds if nothing else is writing to
# it at the same time. `test_pyo3_wrapper` builds Cargo projects and caches
# them (#275 Phase 2), so it runs here rather than in the parallel phase.
serial_test_names = ("test_cache", "test_core_api", "test_cargo", "test_pyo3_wrapper",
                     "test_pyo3_host")

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

filter_tests!(testsuite, args)

# CI runners with two workers move their longest test files to a second
# runner; all unlisted (including newly added) files stay in shard 1.
# Each runner has its own depot, so the serial cache tests remain isolated.
ci_slow_tests = Set(("test_crate_build_paths", "test_rust_crate_precompile",
                     "test_hot_reload_record", "test_build_env_snapshot",
                     "test_module_name_shadowing", "test_direct_build_target",
                     "test_pyo3_link_plan"))
shard = get(ENV, "RUSTCALL_CI_SHARD", "")
shard in ("", "1", "2") || error("Invalid RUSTCALL_CI_SHARD: $shard")
if !isempty(shard)
    for name in collect(keys(testsuite))
        in_slow_shard = name in ci_slow_tests
        if in_slow_shard != (shard == "2")
            delete!(testsuite, name)
        end
    end
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
