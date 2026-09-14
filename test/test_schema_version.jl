# The manifest compatibility identifier is the release's MAJOR.MINOR (#372).
#
# Through v0.3.x it was an integer bumped on every manifest edit, kept in step
# by hand between `rustcall_core::manifest::SCHEMA_VERSION` and
# `RustCall.MANIFEST_SCHEMA_VERSION`. Since v0.4 both derive it from the
# release: Julia from `Project.toml`, Rust from its own `Cargo.toml` version. The
# hand-kept part that remains is that the manifest crates' versions equal the
# package version, and that is what this file pins.

using RustCall
using Test
using TOML

const _ROOT = dirname(@__DIR__)
const _MANIFEST_CRATES = ("rustcall_core", "rustcall_extract",
                          "rustcall_julia_macros", "rustcall_julia_macros_impl")

@testset "manifest schema identifier follows the release (#372)" begin
    project = TOML.parsefile(joinpath(_ROOT, "Project.toml"))
    release = VersionNumber(project["version"])

    @testset "Julia derives it from Project.toml" begin
        @test RustCall.MANIFEST_SCHEMA_VERSION == "$(release.major).$(release.minor)"
        @test RustCall.MANIFEST_SCHEMA_VERSION isa String
    end

    @testset "every manifest crate carries the package version" begin
        # Rust derives its identifier from `CARGO_PKG_VERSION`, so the crates
        # that produce or embed a manifest must be versioned as the release.
        # `rustcall_helpers` is deliberately not on this list: it has no
        # manifest and ships as its own JLL (#404).
        for crate in _MANIFEST_CRATES
            toml = TOML.parsefile(joinpath(_ROOT, "deps", crate, "Cargo.toml"))
            @test VersionNumber(toml["package"]["version"]) == release
        end
    end

    @testset "the extractor reports the same identifier" begin
        if !RustCall.check_rustc_available()
            @test_skip "needs the rustcall-extract binary"
        else
            exe = RustCall.extractor_path()
            @test strip(read(`$exe schema-version`, String)) == RustCall.MANIFEST_SCHEMA_VERSION
        end
    end

    @testset "a manifest from another release is refused, and says why" begin
        current = "schema_version = $(repr(RustCall.MANIFEST_SCHEMA_VERSION))\nmode = \"inline\"\n"
        @test RustCall._parse_manifest(current)["schema_version"] == RustCall.MANIFEST_SCHEMA_VERSION

        # The integer a pre-v0.4 extractor writes.
        legacy = try
            RustCall._parse_manifest("schema_version = 13\nmode = \"inline\"\n")
            nothing
        catch err
            err
        end
        @test legacy isa RustCall.ExtractorError
        message = sprint(showerror, legacy)
        @test occursin("schema 13", message)
        @test occursin("v0.3.x", message)
        @test occursin(repr(RustCall.MANIFEST_SCHEMA_VERSION), message)
        @test occursin("Pkg.build", message)

        # Another release's identifier — a patch never changes it, a minor
        # always does, so this is what a v0.5 extractor against v0.4 looks like.
        other = try
            RustCall._parse_manifest("schema_version = \"99.0\"\nmode = \"inline\"\n")
            nothing
        catch err
            err
        end
        @test other isa RustCall.ExtractorError
        @test occursin("\"99.0\"", sprint(showerror, other))
    end

    @testset "the identifier is part of every cache key" begin
        # A minor release must move every cache key and a patch release must
        # not: that follows from the identifier being an input of
        # `toolchain_fingerprint`, which every artifact identity folds in.
        src = read(joinpath(_ROOT, "src", "manifest.jl"), String)
        @test occursin("\"schema=\$(MANIFEST_SCHEMA_VERSION)\"", src)
        if RustCall.check_rustc_available()
            @test length(RustCall.toolchain_fingerprint()) == 64
        end
    end
end
