# The harness's own invariant: nothing that empties the shared Rust artifact
# cache may run in the parallel phase (#394).
#
# `test/runtests.jl` runs most files across sixteen worker processes sharing one
# cache directory. `RustCall.clear_cache()` removes all of it — including the
# `.dylib` a concurrent worker has just written and recorded a path to, which
# then fails to open. The failure lands in whichever file happened to be loading
# at that moment, so it reads as an intermittent bug in *that* file's feature
# and points at whatever change is under review. Two full-suite runs minutes
# apart on one tree failed in `test_generated_includes` and in
# `test_pyo3_public_routes`; both pass alone, and both pass against a private
# `RUSTCALL_CACHE_DIR`.
#
# Four names were already serialised when this was found, which shows the hazard
# was understood — the two that had since gained a `clear_cache()` call were
# simply missed. This file is what stops the list falling behind a third time.

using RustCall
using Test

include(joinpath(@__DIR__, "serial_tests.jl"))

# Walk the parsed file rather than grepping it. Three of the current mentions of
# `clear_cache` are in **comments** explaining the hazard, and a checker that
# cannot tell a comment from a call would either flag them or need an allowlist
# — and an allowlist is the thing that falls behind.
#
# Two shapes count, because both appear in the suite:
#   * a call whose callee is named `clear_cache`, however it is qualified; and
#   * a string that will be evaluated in a child process and contains the name.
function _clears_shared_cache(expr)
    name = "clear_cache"
    if expr isa AbstractString
        return occursin(name, expr)
    elseif expr isa Expr
        if expr.head === :call && _callee_name(expr.args[1]) == name
            return true
        end
        return any(_clears_shared_cache, expr.args)
    end
    return false
end

# The last segment of a callee: `clear_cache`, `RustCall.clear_cache` and
# `Main.RustCall.clear_cache` all answer "clear_cache".
_callee_name(f::Symbol) = String(f)
_callee_name(f::QuoteNode) = f.value isa Symbol ? String(f.value) : ""
function _callee_name(f::Expr)
    f.head === :. && length(f.args) == 2 && return _callee_name(f.args[2])
    return ""
end
_callee_name(::Any) = ""

@testset "nothing in the parallel phase clears the shared cache (#394)" begin
    @testset "the checker sees a call and ignores a comment" begin
        # Asserted before it is trusted: a guard that silently matches nothing
        # passes forever and protects nothing.
        @test _clears_shared_cache(Meta.parseall("RustCall.clear_cache()"))
        @test _clears_shared_cache(Meta.parseall("clear_cache()"))
        @test _clears_shared_cache(Meta.parseall("f(\"using RustCall; RustCall.clear_cache()\")"))
        @test !_clears_shared_cache(Meta.parseall("# RustCall.clear_cache() removes it\nx = 1"))
        @test !_clears_shared_cache(Meta.parseall("clear_lockfiles()"))
        # The fixtures above are themselves strings naming `clear_cache`, so
        # this file trips its own rule — which is why the sweep below skips it
        # by name, and this is the assertion that says the exemption is for a
        # real reason rather than a convenient one.
        @test _clears_shared_cache(Meta.parseall(read(@__FILE__, String)))
    end

    @testset "every test file that clears the cache is serialised" begin
        offenders = String[]
        unparsable = String[]
        for file in sort(readdir(@__DIR__))
            (startswith(file, "test_") && endswith(file, ".jl")) || continue
            name = file[1:(end - 3)]
            name in SERIAL_TEST_NAMES && continue
            # The checker's own fixtures; see the testset above. It calls
            # nothing, so it can safely stay in the parallel phase.
            name == "test_suite_isolation" && continue
            parsed = try
                Meta.parseall(read(joinpath(@__DIR__, file), String))
            catch err
                push!(unparsable, name)
                continue
            end
            _clears_shared_cache(parsed) && push!(offenders, name)
        end
        # Named in the failure, not just counted: the fix is to add the name to
        # `test/serial_tests.jl` with a line saying why it is there.
        @test offenders == String[]
        @test unparsable == String[]
    end

    @testset "the serial list names files that exist" begin
        # A renamed file would otherwise drop off the list silently, and
        # `runtests.jl` skips a name it does not find.
        missing_files = [name for name in SERIAL_TEST_NAMES
                         if !isfile(joinpath(@__DIR__, name * ".jl"))]
        @test missing_files == String[]
    end
end
