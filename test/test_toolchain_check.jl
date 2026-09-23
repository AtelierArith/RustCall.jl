# `RustCall.check_toolchain()` (#490): one preflight that names the `rustc` /
# `cargo` RustToolChain resolves, the supported floor, and the extractor's
# status — building nothing and raising nothing.

using RustCall
using RustToolChain: cargo
using Test

const TC_ROOT = dirname(@__DIR__)

# A stand-in for a RustToolChain getter: a command whose `--version` prints
# `line`. `sh` where there is one (the `--version` the check appends becomes
# `$0`); elsewhere Julia itself, slower to start, with `--` keeping the
# `--version` away from Julia's own options.
_tc_fake_tool(line) = Sys.iswindows() ?
    (() -> `$(Base.julia_cmd()) --startup-file=no -e $("print($(repr(line)))") --`) :
    (() -> `sh -c $("printf '%s' '$(line)'")`)
_tc_failing_tool() = Sys.iswindows() ?
    (() -> `$(Base.julia_cmd()) --startup-file=no -e "exit(3)" --`) :
    (() -> `sh -c "exit 3"`)

@testset "the release is read from a --version line (#490)" begin
    @test RustCall._toolchain_release("rustc 1.85.0 (4d91de4e4 2025-02-17)") == v"1.85.0"
    @test RustCall._toolchain_release("cargo 1.98.1 (797e8a9bc 2026-08-05)") == v"1.98.1"
    @test RustCall._toolchain_release("rustc 1.99.0-nightly (abc 2026-09-20)") == v"1.99.0-nightly"
    @test RustCall._toolchain_release("rustc") === nothing
    @test RustCall._toolchain_release("rustc unknown") === nothing
end

@testset "the floor is the extractor's declared rust-version (#490)" begin
    floor = RustCall.minimum_supported_rustc()
    @test floor isa VersionNumber
    @test floor == v"1.85"
end

# The declaration is only as good as the graph it summarises: Cargo's own view
# of the committed lockfile says which dependency sets the floor. Needs the
# locked crates in the registry cache (a built extractor put them there).
@testset "the declared floor matches the locked dependency graph (#490)" begin
    crate = joinpath(TC_ROOT, "deps", "rustcall_extract")
    metadata = try
        read(setenv(`$(cargo()) metadata --format-version 1 --locked --offline`,
                    ENV; dir = crate), String)
    catch
        nothing
    end
    if metadata === nothing
        @test_skip "cargo metadata --locked --offline unavailable (no registry cache)"
    else
        packages = RustCall.parse_json(metadata)["packages"]
        declared = VersionNumber[]
        for p in packages
            v = get(p, "rust_version", nothing)
            v isa AbstractString && push!(declared, VersionNumber(v))
        end
        # The extractor's own declaration is in the graph; the highest one is
        # the floor, and it is the extractor's.
        @test maximum(declared) == RustCall.minimum_supported_rustc()
    end
end

@testset "check_toolchain reports the resolved toolchain (#490)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc unavailable"
    else
        r = RustCall.check_toolchain(; io = devnull)
        @test r.rustc.error === nothing
        @test startswith(r.rustc.version, "rustc ")
        @test r.rustc.release isa VersionNumber
        @test r.cargo.error === nothing
        @test startswith(r.cargo.version, "cargo ")
        @test r.minimum_rustc == RustCall.minimum_supported_rustc()
        @test r.rustc_supported === true
        # The same string every cache key folds in.
        @test r.compiler_identity == RustCall.artifact_compiler_identity()
        @test r.extractor.error === nothing
        @test r.extractor.path == RustCall.extractor_path()
        @test r.extractor.schema == RustCall.MANIFEST_SCHEMA_VERSION
        @test r.extractor.identity == RustCall.extractor_source_digest()
        @test r.ok
        @test isempty(r.problems)
        text = sprint(io -> RustCall.check_toolchain(; io))
        @test occursin("RustCall toolchain check: ok", text)
        @test occursin("minimum supported: $(r.minimum_rustc)", text)
    end
end

@testset "an old or missing toolchain is a problem, not an exception (#490)" begin
    ok_cargo = _tc_fake_tool("cargo 1.98.1 (797e8a9bc 2026-08-05)")

    old = RustCall._check_toolchain(devnull, _tc_fake_tool("rustc 1.70.0 (90c541806 2023-05-31)"),
                                    ok_cargo)
    @test old.rustc.release == v"1.70.0"
    @test old.rustc_supported === false
    @test !old.ok
    @test any(p -> occursin("older than the minimum supported", p), old.problems)

    # A pre-release counts as its release.
    nightly = RustCall._check_toolchain(devnull,
        _tc_fake_tool("rustc $(RustCall.minimum_supported_rustc())-nightly (abc 2025-01-01)"),
        ok_cargo)
    @test nightly.rustc_supported === true

    missing_rustc = RustCall._check_toolchain(devnull, _tc_failing_tool(), ok_cargo)
    @test missing_rustc.rustc.error isa String
    @test missing_rustc.rustc_supported === nothing
    @test !missing_rustc.ok
    @test any(p -> startswith(p, "rustc: "), missing_rustc.problems)

    unresolvable = RustCall._check_toolchain(devnull, () -> error("no toolchain"), ok_cargo)
    @test occursin("could not resolve", unresolvable.rustc.error)

    garbled = RustCall._check_toolchain(devnull, _tc_fake_tool("rustc ???"), ok_cargo)
    @test garbled.rustc.release === nothing
    @test any(p -> occursin("cannot read a release", p), garbled.problems)

    text = sprint(io -> RustCall._check_toolchain(io, _tc_failing_tool(), ok_cargo))
    @test occursin("problem(s)", text)
    @test occursin("rustc: unavailable", text)
end

# An extractor from another release: reported, not raised. A fresh process, so
# the override is what `extractor_path()` sees first.
@testset "an extractor speaking another schema is a problem (#490)" begin
    if !Sys.isunix()
        @test_skip "the stand-in extractor is a shell script"
    else
        mktempdir() do dir
            fake = joinpath(dir, "rustcall-extract")
            write(fake, "#!/bin/sh\necho 0.0\n")
            chmod(fake, 0o755)
            script = """
                using RustCall
                r = RustCall.check_toolchain(; io = devnull)
                println(r.ok)
                println(r.extractor.schema)
                println(any(p -> startswith(p, "extractor: "), r.problems))
                """
            out = withenv("RUSTCALL_EXTRACT" => fake,
                          "RUSTCALL_SUPPRESS_HELPERS_WARNING" => "1") do
                readchomp(`$(Base.julia_cmd()) --startup-file=no --project=$(TC_ROOT) -e $script`)
            end
            @test split(out, '\n') == ["false", "0.0", "true"]
        end
    end
end
