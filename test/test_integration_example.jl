# The runnable example of docs/src/integration_guide.md (#441), run as part of
# RustCall's own suite. The Examples workflow runs the same checks through the
# package's `Pkg.test()`; here its source is included so every OS job and the
# 4-thread job exercise it against this checkout.

using Test
using RustCall

const SAFE_LEDGER_ROOT = joinpath(dirname(@__DIR__), "examples", "SafeLedger.jl")

# The facade is a `cdylib`, so `@rust_crate` builds it in place against its own
# `Cargo.lock`. Its `#[julia]` dependency reaches `syn`/`quote`/`proc-macro2`
# on crates.io, so the canonical example pins that resolution (#444 review).
@testset "SafeLedger example: the facade's lockfile is tracked" begin
    lockfile = joinpath(SAFE_LEDGER_ROOT, "deps", "safe_ledger", "Cargo.lock")
    @test isfile(lockfile)
    @test occursin("name = \"syn\"", read(lockfile, String))
    @test !any(line -> strip(line) in ("/deps/safe_ledger/Cargo.lock", "Cargo.lock"),
               readlines(joinpath(SAFE_LEDGER_ROOT, ".gitignore")))
end

if !RustCall.check_rustc_available()
    @testset "SafeLedger example" begin
        @test_skip "rustc is required"
    end
else
    include(joinpath(SAFE_LEDGER_ROOT, "src", "SafeLedger.jl"))
    include(joinpath(SAFE_LEDGER_ROOT, "test", "ledger_tests.jl"))
end
