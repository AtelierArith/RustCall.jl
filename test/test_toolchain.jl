# The suite's own precondition (issue #259).
#
# Around sixty testsets in this suite begin with `check_rustc_available() ||
# (@warn ...; return)`. That is right on a developer machine without Rust, and
# wrong in CI: if RustToolChain.jl ever fails to provision a compiler on some
# platform, every one of those testsets would step aside and the suite would
# report green while asserting almost nothing about the FFI core.
#
# So in CI the toolchain is not a precondition to be skipped around but a
# claim to be tested. `Pkg.build("RustCall")` runs in every Julia CI job
# (`julia-actions/julia-buildpkg`), so the helpers library must be there too:
# without it the ownership types silently stop working, which is the degraded
# mode behind the leaks of #77 / #150.
#
# `RUSTCALL_REQUIRE_TOOLCHAIN` forces the same assertions off CI, for anyone
# who wants the suite to fail loudly rather than skip.

using RustCall
using RustToolChain: cargo
using Test

const _REQUIRE_TOOLCHAIN =
    get(ENV, "CI", "false") == "true" ||
    get(ENV, "RUSTCALL_REQUIRE_TOOLCHAIN", "false") == "true"

@testset "Rust toolchain" begin
    rustc_ok = RustCall.check_rustc_available()

    if _REQUIRE_TOOLCHAIN
        @testset "rustc is provisioned" begin
            @test rustc_ok
        end

        @testset "cargo is provisioned" begin
            cargo_ok = try
                run(pipeline(`$(cargo()) --version`, devnull))
                true
            catch
                false
            end
            @test cargo_ok
        end

        @testset "the helpers library was built" begin
            # `Pkg.build` runs before the tests in CI, so a missing library is
            # a build failure that went unnoticed, not a machine without Rust.
            @test RustCall.is_rust_helpers_available()
        end
    else
        @testset "rustc is provisioned" begin
            if rustc_ok
                @test rustc_ok
            else
                @test_skip "no rustc: set CI=true or RUSTCALL_REQUIRE_TOOLCHAIN=true to require one"
            end
        end
    end
end
