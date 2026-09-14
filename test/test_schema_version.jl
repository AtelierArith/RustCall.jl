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

    @testset "a patch bump of the crates does not move the cache" begin
        # The promise is that a patch release keeps every cached artifact
        # valid. The four manifest crates are versioned as the release, so a
        # patch release rewrites their `[package] version` — and
        # `_rust_sources_digest` hashes `Cargo.toml`. That key alone is
        # therefore left out of the digest; a dependency's version is not,
        # because it can change what the generator emits (#372 review).
        mktempdir() do dir
            a, b, c = joinpath(dir, "a"), joinpath(dir, "b"), joinpath(dir, "c")
            for root in (a, b, c)
                mkpath(joinpath(root, "src"))
                write(joinpath(root, "src", "lib.rs"), "pub fn f() {}\n")
            end
            write(joinpath(a, "Cargo.toml"), """
                [package]
                name = "probe"
                version = "0.4.0"
                edition = "2021"

                [dependencies]
                syn = { version = "2.0", features = ["full"] }
                """)
            write(joinpath(b, "Cargo.toml"), replace(read(joinpath(a, "Cargo.toml"), String),
                                                     "version = \"0.4.0\"" => "version = \"0.4.1\""))
            write(joinpath(c, "Cargo.toml"), replace(read(joinpath(a, "Cargo.toml"), String),
                                                     "version = \"2.0\"" => "version = \"2.1\""))
            @test RustCall._rust_sources_digest(a) == RustCall._rust_sources_digest(b)
            @test RustCall._rust_sources_digest(a) != RustCall._rust_sources_digest(c)
            # ...and a source change still moves it.
            write(joinpath(b, "src", "lib.rs"), "pub fn f() -> i32 { 1 }\n")
            @test RustCall._rust_sources_digest(a) != RustCall._rust_sources_digest(b)
        end
    end

    @testset "release-only version fields are out of every file digest" begin
        # `_identity_file_digest` is what every artifact identity hashes a file
        # through — `crate_content_digest` for a crate's inputs, the workspace
        # root manifest and lock in `compute_crate_hash`. (`_file_content_digest`
        # stays byte for byte: the persisted-lockfile store compares it to mean
        # "exactly the same file".) A `Cargo.toml` enters
        # without `[package] version`; a `Cargo.lock` without the `version` of
        # any package that has no `source` (the root and every path
        # dependency). A registry package's version pins its content and stays
        # (#372 review).
        mktempdir() do dir
            digest(name, text) = (write(joinpath(dir, name), text); RustCall._identity_file_digest(joinpath(dir, name)))
            toml(v, dep) = """
                [package]
                name = "probe"
                version = "$(v)"
                edition = "2021"

                [dependencies]
                syn = "$(dep)"
                """
            @test digest("Cargo.toml", toml("0.4.0", "2.0")) == digest("Cargo.toml", toml("0.4.1", "2.0"))
            @test digest("Cargo.toml", toml("0.4.0", "2.0")) != digest("Cargo.toml", toml("0.4.0", "2.1"))
            lock(pathv, regv) = """
                version = 4

                [[package]]
                name = "probe"
                version = "$(pathv)"
                dependencies = ["rustcall_julia_macros", "syn"]

                [[package]]
                name = "rustcall_julia_macros"
                version = "$(pathv)"

                [[package]]
                name = "syn"
                version = "$(regv)"
                source = "registry+https://github.com/rust-lang/crates.io-index"
                checksum = "0000"
                """
            @test digest("Cargo.lock", lock("0.4.0", "2.0.1")) == digest("Cargo.lock", lock("0.4.1", "2.0.1"))
            @test digest("Cargo.lock", lock("0.4.0", "2.0.1")) != digest("Cargo.lock", lock("0.4.0", "2.0.2"))
            # Any other file, and a manifest that does not parse, hash as they are.
            @test digest("lib.rs", "pub fn a() {}") != digest("lib.rs", "pub fn b() {}")
            @test digest("Cargo.toml", "not = [toml") == RustCall._file_content_digest(joinpath(dir, "Cargo.toml"))
            # ...and the byte-exact digest the lockfile store relies on still
            # sees a version-only change.
            write(joinpath(dir, "Cargo.lock"), lock("0.4.0", "2.0.1"))
            raw_a = RustCall._file_content_digest(joinpath(dir, "Cargo.lock"))
            write(joinpath(dir, "Cargo.lock"), lock("0.4.1", "2.0.1"))
            @test RustCall._file_content_digest(joinpath(dir, "Cargo.lock")) != raw_a
        end
    end

    @testset "a @rust_crate key survives a patch bump of a path dependency" begin
        # End to end through `compute_crate_hash`: a crate with a local path
        # dependency, whose version — and the lockfile lines recording it — is
        # bumped as a patch release would bump `rustcall_julia_macros`. The key
        # must not move; a source change in the dependency must move it.
        if !RustCall.check_rustc_available()
            @test_skip "needs cargo to resolve the local dependency graph"
        else
            mktempdir() do dir
                dep = joinpath(dir, "probe_dep"); crate = joinpath(dir, "probe_crate")
                for (root, name, body) in ((dep, "probe_dep", "pub fn helper() -> i32 { 1 }"),
                                           (crate, "probe_crate", "pub fn answer() -> i32 { 42 }"))
                    mkpath(joinpath(root, "src"))
                    write(joinpath(root, "src", "lib.rs"), body)
                end
                manifest(v) = """
                    [package]
                    name = "probe_dep"
                    version = "$(v)"
                    edition = "2021"

                    [lib]
                    crate-type = ["rlib"]
                    """
                write(joinpath(dep, "Cargo.toml"), manifest("0.4.0"))
                write(joinpath(crate, "Cargo.toml"), """
                    [package]
                    name = "probe_crate"
                    version = "0.1.0"
                    edition = "2021"

                    [lib]
                    crate-type = ["cdylib"]

                    [dependencies]
                    probe_dep = { path = "../probe_dep" }
                    """)
                resolve() = for root in (dep, crate)
                    run(pipeline(Cmd(`cargo generate-lockfile --offline`; dir = root); stdout = devnull, stderr = devnull))
                end
                resolve()
                info = RustCall.scan_crate(crate)
                key = RustCall.compute_crate_hash(info)
                @test occursin("0.4.0", read(joinpath(crate, "Cargo.lock"), String))

                # The patch bump: manifest version and both lockfiles.
                write(joinpath(dep, "Cargo.toml"), manifest("0.4.1"))
                resolve()
                @test occursin("0.4.1", read(joinpath(crate, "Cargo.lock"), String))
                RustCall._artifact_reset_digest_caches!()
                @test RustCall.compute_crate_hash(RustCall.scan_crate(crate)) == key

                # ...and a real change to the dependency still moves it.
                write(joinpath(dep, "src", "lib.rs"), "pub fn helper() -> i32 { 2 }")
                RustCall._artifact_reset_digest_caches!()
                @test RustCall.compute_crate_hash(RustCall.scan_crate(crate)) != key
            end
        end
    end

    @testset "the identifier is part of every cache key, the extractor binary is not" begin
        # A minor release must move every cache key and a patch release must
        # not: the identifier is an input of `toolchain_fingerprint`, which
        # every artifact identity folds in — and the extractor *executable* is
        # not, because a patch release bumps its crate version, Cargo folds
        # that into `-C metadata`, and the same sources give different bytes
        # (#372 review). Its sources are what count, version left out.
        parts, _ = RustCall._toolchain_fingerprint_inputs()
        @test "schema=$(RustCall.MANIFEST_SCHEMA_VERSION)" in parts
        @test !any(p -> startswith(p, "extractor="), parts)
        deps = joinpath(_ROOT, "deps")
        expected = RustCall._rust_sources_digest(
            (joinpath(deps, c) for c in RustCall._FINGERPRINT_CRATES)...)
        @test "sources=$(expected)" in parts
        @test "rustcall_extract" in RustCall._FINGERPRINT_CRATES
        if RustCall.check_rustc_available()
            @test length(RustCall.toolchain_fingerprint()) == 64
        end
    end
end
