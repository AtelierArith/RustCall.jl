# The manifest compatibility identifier is the release's MAJOR.MINOR (#372).
#
# Through v0.3.x it was an integer bumped on every manifest edit, kept in step
# by hand between `rustcall_julia_core::manifest::SCHEMA_VERSION` and
# `RustCall.MANIFEST_SCHEMA_VERSION`. Since v0.4 both name the release: `MANIFEST_SCHEMA_VERSION`
# is computed from `Project.toml` here, and `SCHEMA_VERSION` is the same string
# kept as a literal in Rust; the two are cross-checked through the extractor's
# `schema-version` output below. The crates' `[package] version`, by contrast,
# is their own semver once they are published on crates.io, so this file pins it
# separately, as a set.

using RustCall
using Test
using TOML

const _ROOT = dirname(@__DIR__)
const _PUBLISHED_CRATES = ("rustcall_julia_core", "rustcall_julia_macros",
                           "rustcall_julia_macros_impl")

@testset "manifest schema identifier follows the release (#372)" begin
    project = TOML.parsefile(joinpath(_ROOT, "Project.toml"))
    release = VersionNumber(project["version"])

    @testset "Julia derives it from Project.toml" begin
        @test RustCall.MANIFEST_SCHEMA_VERSION == "$(release.major).$(release.minor)"
        @test RustCall.MANIFEST_SCHEMA_VERSION isa String
    end

    @testset "the published crates share one version" begin
        # `rustcall_julia_core`, `rustcall_julia_macros` and `rustcall_julia_macros_impl`
        # are on crates.io and versioned as a set, independent of the package's
        # release: their version says what the crates' own API promises, while
        # the identifier above says what manifest the release speaks.
        # `rustcall_extract` is not published — it ships inside the package and
        # its version enters no contract, so it is not on this list.
        # `rustcall_helpers` likewise: no manifest, its own JLL (#404).
        versions = map(_PUBLISHED_CRATES) do crate
            toml = TOML.parsefile(joinpath(_ROOT, "deps", crate, "Cargo.toml"))
            VersionNumber(toml["package"]["version"])
        end
        @test length(unique(versions)) == 1
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
        # The promise is that a version bump of RustCall's own crates keeps
        # every cached artifact valid: their behaviour is their sources, and a
        # version alone moves nothing. `_rust_sources_digest` hashes
        # `Cargo.toml`, so for those crates — this package's own
        # `deps/<name>`, not a same-named crate anywhere else — that key is
        # left out of the digest; a dependency's version is not, because it can
        # change what the generator emits, and any other crate's own version is
        # not either, because that crate may read `env!("CARGO_PKG_VERSION")`
        # (#372 review).
        for crate in RustCall.RUSTCALL_RELEASE_CRATES
            real = joinpath(_ROOT, "deps", crate)
            version = TOML.parsefile(joinpath(real, "Cargo.toml"))["package"]["version"]
            as_hashed = String(RustCall._identity_file_bytes(joinpath(real, "Cargo.toml")))
            # The `[package] version` line leaves; a `version` inside a
            # dependency's inline table stays (it pins a dependency, and only
            # the crate's own version is release-insensitive), so the check is
            # anchored to the package name.
            @test !occursin("name = \"$(crate)\"\nversion = \"$(version)\"", as_hashed)
            @test occursin("name = \"$(crate)\"", as_hashed)
        end
        mktempdir() do dir
            a, b, c, d, e = (joinpath(dir, n) for n in ("a", "b", "c", "d", "e"))
            for root in (a, b, c, d, e)
                mkpath(joinpath(root, "src"))
                write(joinpath(root, "src", "lib.rs"), "pub fn f() {}\n")
            end
            manifest(name, v, dep) = """
                [package]
                name = "$(name)"
                version = "$(v)"
                edition = "2021"

                [dependencies]
                syn = { version = "$(dep)", features = ["full"] }
                """
            write(joinpath(a, "Cargo.toml"), manifest("rustcall_julia_core", "0.4.0", "2.0"))
            write(joinpath(b, "Cargo.toml"), manifest("rustcall_julia_core", "0.4.1", "2.0"))
            write(joinpath(c, "Cargo.toml"), manifest("rustcall_julia_core", "0.4.0", "2.1"))
            write(joinpath(d, "Cargo.toml"), manifest("probe", "0.4.0", "2.0"))
            write(joinpath(e, "Cargo.toml"), manifest("probe", "0.4.1", "2.0"))
            # A crate *named* `rustcall_julia_core` outside this tree is a fork, and
            # a fork's version is in its key like anyone else's.
            @test RustCall._rust_sources_digest(a) != RustCall._rust_sources_digest(b)
            @test RustCall._rust_sources_digest(a) != RustCall._rust_sources_digest(c)
            @test RustCall._rust_sources_digest(d) != RustCall._rust_sources_digest(e)
            # ...and a source change moves it.
            same = RustCall._rust_sources_digest(a)
            write(joinpath(a, "src", "lib.rs"), "pub fn f() -> i32 { 1 }\n")
            @test RustCall._rust_sources_digest(a) != same
        end
    end

    @testset "release-only version fields are out of every file digest" begin
        # `_identity_file_digest` is what every artifact identity hashes a file
        # through — `crate_content_digest` for a crate's inputs, the workspace
        # root manifest and lock in `compute_crate_hash`. (`_file_content_digest`
        # stays byte for byte: the persisted-lockfile store compares it to mean
        # "exactly the same file".) Only this package's own release crates
        # lose their `[package] version`, and only their path-resolved lockfile
        # entries lose `version`: any other crate can read
        # `env!("CARGO_PKG_VERSION")`, so its version stays in the key, and a
        # registry package's version pins its content (#372 review).
        mktempdir() do dir
            digest(name, text) = (write(joinpath(dir, name), text); RustCall._identity_file_digest(joinpath(dir, name)))
            toml(crate, v, dep) = """
                [package]
                name = "$(crate)"
                version = "$(v)"
                edition = "2021"

                [dependencies]
                syn = "$(dep)"
                """
            # A crate merely *named* like a RustCall release crate, living
            # somewhere else, keeps its version: a name is not provenance.
            @test digest("Cargo.toml", toml("rustcall_julia_macros", "0.4.0", "2.0")) !=
                  digest("Cargo.toml", toml("rustcall_julia_macros", "0.4.1", "2.0"))
            # Anyone else's crate: its version is part of what it compiles to.
            @test digest("Cargo.toml", toml("probe", "0.4.0", "2.0")) !=
                  digest("Cargo.toml", toml("probe", "0.4.1", "2.0"))
            # The real one — this package's own `deps/rustcall_julia_macros` —
            # is the crate whose version a release rewrites, and its version is
            # what is left out. Checked on the manifest as it is, with only the
            # version rewritten in a temporary copy that keeps its place by
            # being hashed through the provenance check on the *original*.
            real = joinpath(_ROOT, "deps", "rustcall_julia_macros")
            @test RustCall._is_rustcall_release_crate(real, "rustcall_julia_macros")
            @test !RustCall._is_rustcall_release_crate(dir, "rustcall_julia_macros")
            @test !RustCall._is_rustcall_release_crate(real, "probe")
            lock(rcv, userv, regv) = """
                version = 4

                [[package]]
                name = "probe"
                version = "$(userv)"
                dependencies = ["rustcall_julia_macros", "syn"]

                [[package]]
                name = "rustcall_julia_macros"
                version = "$(rcv)"

                [[package]]
                name = "syn"
                version = "$(regv)"
                source = "registry+https://github.com/rust-lang/crates.io-index"
                checksum = "0000"
                """
            # The lockfile's own crate takes `rustcall_julia_macros` by path
            # from this package's `deps/`: that entry's version may go.
            write(joinpath(dir, "Cargo.toml"), """
                [package]
                name = "probe"
                version = "0.1.0"
                edition = "2021"

                [dependencies]
                rustcall_julia_macros = { path = $(repr(real)) }
                syn = "2.0"
                """)
            # ...and the release crates behind it, which its lockfile records
            # too (#372 review).
            three = Set(["rustcall_julia_macros", "rustcall_julia_macros_impl", "rustcall_julia_core"])
            @test RustCall._rustcall_release_names_in(dir) == three
            # ...also when declared for one platform only (#372 review).
            write(joinpath(dir, "Cargo.toml"), """
                [package]
                name = "probe"
                version = "0.1.0"
                edition = "2021"

                [target.'cfg(unix)'.dependencies]
                rustcall_julia_macros = { path = $(repr(real)) }

                [target.'cfg(windows)'.build-dependencies]
                rustcall_julia_core = { path = $(repr(joinpath(_ROOT, "deps", "rustcall_julia_core"))) }
                """)
            @test RustCall._rustcall_release_names_in(dir) == three
            write(joinpath(dir, "Cargo.toml"), """
                [package]
                name = "probe"
                version = "0.1.0"
                edition = "2021"

                [dependencies]
                rustcall_julia_macros = { path = $(repr(real)) }
                syn = "2.0"
                """)
            base = digest("Cargo.lock", lock("0.4.0", "0.1.0", "2.0.1"))
            @test digest("Cargo.lock", lock("0.4.1", "0.1.0", "2.0.1")) == base   # RustCall path dep
            @test digest("Cargo.lock", lock("0.4.0", "0.1.1", "2.0.1")) != base   # the user's own crate
            @test digest("Cargo.lock", lock("0.4.0", "0.1.0", "2.0.2")) != base   # a registry package
            # ...but if that name resolved to a fork elsewhere, nothing goes.
            fork = joinpath(dir, "fork"); mkpath(fork); write(joinpath(fork, "Cargo.toml"), toml("rustcall_julia_macros", "0.4.0", "2.0"))
            write(joinpath(dir, "Cargo.toml"), """
                [package]
                name = "probe"
                version = "0.1.0"
                edition = "2021"

                [dependencies]
                rustcall_julia_macros = { path = "fork" }
                """)
            @test isempty(RustCall._rustcall_release_names_in(dir))
            @test digest("Cargo.lock", lock("0.4.1", "0.1.0", "2.0.1")) !=
                  digest("Cargo.lock", lock("0.4.0", "0.1.0", "2.0.1"))
            # A file with nothing to remove enters byte for byte: a crate can
            # read its own manifest (`include_str!("../Cargo.toml")`), so a
            # comment or a reordering is a change to what it compiles to
            # (#372 review). The lockfile of a crate with no RustCall path
            # dependency likewise.
            plain = toml("probe", "0.1.0", "2.0")
            @test digest("Cargo.toml", plain) == RustCall._file_content_digest(joinpath(dir, "Cargo.toml"))
            @test digest("Cargo.toml", plain * "# a comment\n") != digest("Cargo.toml", plain)
            @test digest("Cargo.toml", "[package]\nversion = \"0.1.0\"\nname = \"probe\"\nedition = \"2021\"\n\n[dependencies]\nsyn = { version = \"2.0\", features = [\"full\"] }\n") !=
                  digest("Cargo.toml", plain)
            @test digest("Cargo.lock", lock("0.4.0", "0.1.0", "2.0.1")) ==
                  RustCall._file_content_digest(joinpath(dir, "Cargo.lock"))
            @test digest("Cargo.lock", lock("0.4.0", "0.1.0", "2.0.1") * "# trailing\n") !=
                  digest("Cargo.lock", lock("0.4.0", "0.1.0", "2.0.1"))
            # ...while a file that did lose a line loses exactly that line and
            # keeps every other byte (#372 review): the real dependency's
            # manifest enters as its raw text minus `version = "..."`.
            real_manifest = joinpath(real, "Cargo.toml")
            raw_manifest = read(real_manifest, String)
            @test RustCall._identity_file_digest(real_manifest) != RustCall._file_content_digest(real_manifest)
            # ...and the `version = "..."` requirement it puts on the sibling it
            # takes by path goes with it (#451): the two are bumped together.
            without_pins = line -> RustCall._without_inline_version(line, Set(["rustcall_julia_macros_impl"]))
            @test String(RustCall._identity_file_bytes(real_manifest)) ==
                  join(map(without_pins, filter(l -> !startswith(l, "version = "), split(raw_manifest, '\n'))), '\n')
            @test occursin("rustcall_julia_macros_impl = { path = \"../rustcall_julia_macros_impl\", version = ", raw_manifest)
            @test occursin("rustcall_julia_macros_impl = { path = \"../rustcall_julia_macros_impl\" }\n",
                           String(RustCall._identity_file_bytes(real_manifest)))
            # A registry pin in the same manifest is not a release-coupled line
            # and stays (`pyo3 = { version = "0.29", ... }` in the dev-dependencies).
            @test occursin("pyo3 = { version = ", String(RustCall._identity_file_bytes(real_manifest)))
            # The line surgery itself: the element and one comma go, the rest
            # of the line is kept byte for byte; a registry pin and a line for
            # another key are untouched.
            pins = Set(["rustcall_julia_core"])
            @test RustCall._without_inline_version(
                      "rustcall_julia_core = { path = \"../rustcall_julia_core\", version = \"0.1.0\" }", pins) ==
                  "rustcall_julia_core = { path = \"../rustcall_julia_core\" }"
            @test RustCall._without_inline_version(
                      "rustcall_julia_core = { version = \"0.1.0\", path = \"../rustcall_julia_core\", optional = true }", pins) ==
                  "rustcall_julia_core = { path = \"../rustcall_julia_core\", optional = true }"
            @test RustCall._without_inline_version("syn = { version = \"2.0\", features = [\"full\"] }", pins) ==
                  "syn = { version = \"2.0\", features = [\"full\"] }"
            @test RustCall._release_dependency_table("[dependencies.rustcall_julia_core]", pins)
            @test RustCall._release_dependency_table("[target.'cfg(unix)'.build-dependencies.rustcall_julia_core]", pins)
            @test !RustCall._release_dependency_table("[dependencies.syn]", pins)
            @test !RustCall._release_dependency_table("[package]", pins)
            # A lockfile with a line to lose keeps its comments and order too.
            write(joinpath(dir, "Cargo.toml"), """
                [package]
                name = "probe"
                version = "0.1.0"
                edition = "2021"

                [dependencies]
                rustcall_julia_macros = { path = $(repr(real)) }
                """)
            commented = "# This file is automatically @generated by Cargo.\n" * lock("0.4.0", "0.1.0", "2.0.1")
            @test digest("Cargo.lock", commented) != digest("Cargo.lock", lock("0.4.0", "0.1.0", "2.0.1"))
            digest("Cargo.lock", commented)
            @test String(RustCall._identity_file_bytes(joinpath(dir, "Cargo.lock"))) ==
                  replace(commented, "name = \"rustcall_julia_macros\"\nversion = \"0.4.0\"\n" =>
                                     "name = \"rustcall_julia_macros\"\n")
            # Two packages of one name in a graph — this package's crate and a
            # fork — make Cargo qualify the references to them; the one that
            # names this package's crate at its current version enters as the
            # bare name (it is the same reference before and after a bump),
            # the fork's keeps its qualification (#372 review).
            core_version = TOML.parsefile(joinpath(_ROOT, "deps", "rustcall_julia_core", "Cargo.toml"))["package"]["version"]
            two = """
                version = 4

                [[package]]
                name = "probe"
                version = "0.2.0"
                dependencies = [
                 "rustcall_julia_core $(core_version)",
                 "rustcall_julia_core 0.3.9",
                 "rustcall_julia_macros",
                ]

                [[package]]
                name = "rustcall_julia_core"
                version = "$(core_version)"

                [[package]]
                name = "rustcall_julia_core"
                version = "0.3.9"
                source = "registry+https://github.com/rust-lang/crates.io-index"
                checksum = "0000"

                [[package]]
                name = "rustcall_julia_macros"
                version = "$(core_version)"
                """
            digest("Cargo.lock", two)
            @test String(RustCall._identity_file_bytes(joinpath(dir, "Cargo.lock"))) ==
                  replace(two, " \"rustcall_julia_core $(core_version)\",\n" => " \"rustcall_julia_core\",\n",
                               "name = \"rustcall_julia_core\"\nversion = \"$(core_version)\"\n" => "name = \"rustcall_julia_core\"\n",
                               "name = \"rustcall_julia_macros\"\nversion = \"$(core_version)\"\n" => "name = \"rustcall_julia_macros\"\n")
            # The version that is unqualified is the one *this lockfile*
            # records for the path crate, not the one installed now: a lock
            # written under the previous release hashes as it did then, so
            # the two identities are equal (#372 review).
            previous = replace(two, core_version => "0.0.1")
            @test digest("Cargo.lock", previous) == digest("Cargo.lock", two)
            # A lockfile resolved under an earlier patch release replays
            # `--locked` under this one: the release crates' version lines,
            # and the qualified references to them, are brought to the
            # current versions on the way in — nothing else (#372 review).
            stale = """
                # This file is automatically @generated by Cargo.
                version = 4

                [[package]]
                name = "probe"
                version = "0.1.0"
                dependencies = [
                 "rustcall_julia_macros 0.0.1",
                 "rustcall_julia_macros 0.3.9",
                 "syn",
                ]

                [[package]]
                name = "rustcall_julia_macros"
                version = "0.0.1"

                [[package]]
                name = "rustcall_julia_macros"
                version = "0.3.9"
                source = "registry+https://github.com/rust-lang/crates.io-index"
                checksum = "1111"

                [[package]]
                name = "syn"
                version = "2.0.1"
                source = "registry+https://github.com/rust-lang/crates.io-index"
                checksum = "0000"
                """
            # Only the path entry's old version is rewritten, in its table and
            # in the references; the same-named registry package keeps both.
            refreshed = replace(stale, "\"rustcall_julia_macros 0.0.1\"" => "\"rustcall_julia_macros $(core_version)\"",
                                       "name = \"rustcall_julia_macros\"\nversion = \"0.0.1\"" =>
                                       "name = \"rustcall_julia_macros\"\nversion = \"$(core_version)\"")
            write(joinpath(dir, "Cargo.lock"), stale)
            @test RustCall._refresh_release_versions!(joinpath(dir, "Cargo.lock")) === :refreshed
            @test read(joinpath(dir, "Cargo.lock"), String) == refreshed
            @test RustCall._refresh_release_versions!(joinpath(dir, "Cargo.lock")) === :unchanged
            # The set's release crates, from its dependency specs — what a
            # file in the store, with no manifest beside it, is refreshed and
            # hashed with.
            specs = [RustCall.DependencySpec("rustcall_julia_macros", nothing, String[], nothing, real)]
            @test RustCall._release_names_for_dependencies(specs) == three
            @test isempty(RustCall._release_names_for_dependencies(
                [RustCall.DependencySpec("rustcall_julia_macros", nothing, String[], nothing, fork)]))
            @test isempty(RustCall._release_names_for_dependencies(
                [RustCall.DependencySpec("syn", "2.0", String[], nothing, nothing)]))
            # The store's copy is refreshed in place, under the claim, and the
            # identity is release-insensitive either way.
            mktempdir() do store
                stored = joinpath(store, "set.lock")
                write(stored, stale)
                RustCall._refresh_stored_lockfile!(stored, three)
                @test read(stored, String) == refreshed
                @test !isfile(stored * ".claim")
                @test RustCall._identity_file_digest(stored; release_names = three) ==
                      RustCall._identity_file_digest(joinpath(dir, "Cargo.lock"); release_names = three)
                # A same-named path package beside RustCall's crate cannot be
                # told from it by name: the file is not guessed at but removed,
                # and the set resolves afresh.
                write(stored, stale * "\n[[package]]\nname = \"rustcall_julia_macros\"\nversion = \"0.0.2\"\n")
                @test RustCall._refresh_release_versions!(stored; release_names = three) === :ambiguous
                RustCall._refresh_stored_lockfile!(stored, three)
                @test !isfile(stored)
                @test !isfile(stored * ".claim")
                # Nothing to refresh: untouched, and no claim taken.
                write(stored, refreshed)
                RustCall._refresh_stored_lockfile!(stored, three)
                @test read(stored, String) == refreshed
                RustCall._refresh_stored_lockfile!(stored, Set{String}())
                @test read(stored, String) == refreshed
                # A claim held past the wait is an error, not a file to use.
                touch(stored * ".claim")
                try
                    @test_throws RustCall.CargoBuildError RustCall._refresh_stored_lockfile!(stored, three; wait = 0.2)
                finally
                    rm(stored * ".claim"; force = true)
                end
            end
            # The release crates behind a `#[julia]` crate's one path
            # dependency are release crates too: the fixture names only
            # `rustcall_julia_macros`, its lockfile records all three, and a
            # patch release bumps all three (#372 review).
            fixture = joinpath(_ROOT, "test", "fixtures", "sample_crate")
            @test RustCall._rustcall_release_names_in(fixture) ==
                  Set(["rustcall_julia_macros", "rustcall_julia_macros_impl", "rustcall_julia_core"])
            fixture_lock = read(joinpath(fixture, "Cargo.lock"), String)
            real_version = TOML.parsefile(joinpath(real, "Cargo.toml"))["package"]["version"]
            # A Windows checkout may carry CRLF line endings; whichever the
            # file has, only the version lines leave and every other byte stays.
            nl = occursin("\r\n", fixture_lock) ? "\r\n" : "\n"
            expected = fixture_lock
            for crate in ("rustcall_julia_macros", "rustcall_julia_macros_impl", "rustcall_julia_core")
                @test occursin("name = \"$(crate)\"$(nl)version = \"$(real_version)\"$(nl)", expected)
                expected = replace(expected, "name = \"$(crate)\"$(nl)version = \"$(real_version)\"$(nl)" =>
                                             "name = \"$(crate)\"$(nl)")
            end
            @test String(RustCall._identity_file_bytes(joinpath(fixture, "Cargo.lock"))) == expected
            # ...and the same file with the other line ending is treated alike.
            mktempdir() do crlf_dir
                other_nl = nl == "\n" ? "\r\n" : "\n"
                # The fixture's manifest points at `deps/` relatively; here
                # the same dependency by absolute path.
                write(joinpath(crlf_dir, "Cargo.toml"), """
                    [package]
                    name = "sample_crate"
                    version = "0.1.0"
                    edition = "2021"

                    [dependencies]
                    rustcall_julia_macros = { path = $(repr(real)) }
                    """)
                write(joinpath(crlf_dir, "Cargo.lock"), replace(fixture_lock, nl => other_nl))
                @test String(RustCall._identity_file_bytes(joinpath(crlf_dir, "Cargo.lock"))) ==
                      replace(expected, nl => other_nl)
            end
            # Any other file, and a manifest that does not parse, hash as they are.
            @test digest("lib.rs", "pub fn a() {}") != digest("lib.rs", "pub fn b() {}")
            @test digest("Cargo.toml", "not = [toml") == RustCall._file_content_digest(joinpath(dir, "Cargo.toml"))
            # ...and the byte-exact digest the lockfile store relies on still
            # sees a version-only change.
            write(joinpath(dir, "Cargo.lock"), lock("0.4.0", "0.1.0", "2.0.1"))
            raw_a = RustCall._file_content_digest(joinpath(dir, "Cargo.lock"))
            write(joinpath(dir, "Cargo.lock"), lock("0.4.1", "0.1.0", "2.0.1"))
            @test RustCall._file_content_digest(joinpath(dir, "Cargo.lock")) != raw_a
        end
    end

    @testset "a @rust_crate key survives a patch bump of a path dependency" begin
        # End to end through `compute_crate_hash`. A crate takes the *real*
        # `deps/rustcall_julia_macros` by path — what a user crate does — and
        # its lockfile records that crate's version; rewriting that one line
        # as a patch release would must not move the key. A second path
        # dependency is a fork *named* `rustcall_julia_macros`: a name is not
        # provenance, so bumping it moves the key, as does bumping any other
        # path dependency, as does a source change.
        if !RustCall.check_rustc_available()
            @test_skip "needs cargo to resolve the local dependency graph"
        else
            mktempdir() do dir
                dep = joinpath(dir, "fork_macros"); crate = joinpath(dir, "probe_crate")
                other = joinpath(dir, "probe_dep")
                real = joinpath(_ROOT, "deps", "rustcall_julia_macros")
                for (root, name, body) in ((dep, "rustcall_julia_macros", "pub fn helper() -> i32 { 1 }"),
                                           (other, "probe_dep", "pub fn other() -> i32 { 1 }"),
                                           (crate, "probe_crate", "pub fn answer() -> i32 { 42 }"))
                    mkpath(joinpath(root, "src"))
                    write(joinpath(root, "src", "lib.rs"), body)
                end
                manifest(name, v) = """
                    [package]
                    name = "$(name)"
                    version = "$(v)"
                    edition = "2021"

                    [lib]
                    crate-type = ["rlib"]
                    """
                write(joinpath(dep, "Cargo.toml"), manifest("rustcall_julia_macros", "0.4.0"))
                write(joinpath(other, "Cargo.toml"), manifest("probe_dep", "0.1.0"))
                write(joinpath(crate, "Cargo.toml"), """
                    [package]
                    name = "probe_crate"
                    version = "0.1.0"
                    edition = "2021"

                    [lib]
                    crate-type = ["cdylib"]

                    [dependencies]
                    rustcall_julia_macros = { path = $(repr(real)) }
                    fork_macros = { path = "../fork_macros", package = "rustcall_julia_macros" }
                    probe_dep = { path = "../probe_dep" }
                    """)
                # Two packages named `rustcall_julia_macros` cannot share one
                # graph, so the fork is renamed at the manifest level too.
                write(joinpath(dep, "Cargo.toml"), manifest("fork_macros", "0.4.0"))
                write(joinpath(crate, "Cargo.toml"), replace(read(joinpath(crate, "Cargo.toml"), String),
                    "fork_macros = { path = \"../fork_macros\", package = \"rustcall_julia_macros\" }" =>
                    "fork_macros = { path = \"../fork_macros\" }"))
                resolve() = for root in (dep, other, crate)
                    run(pipeline(Cmd(`cargo generate-lockfile --offline`; dir = root); stdout = devnull, stderr = devnull))
                end
                resolve()
                info = RustCall.scan_crate(crate)
                key = RustCall.compute_crate_hash(info)
                lockfile = joinpath(crate, "Cargo.lock")
                real_version = TOML.parsefile(joinpath(real, "Cargo.toml"))["package"]["version"]
                @test occursin("name = \"rustcall_julia_macros\"\nversion = \"$(real_version)\"", read(lockfile, String))

                # The patch bump, as it reaches a user's crate: its lockfile now
                # records the next version of RustCall's crate. Nothing else.
                write(lockfile, replace(read(lockfile, String),
                    "name = \"rustcall_julia_macros\"\nversion = \"$(real_version)\"" =>
                    "name = \"rustcall_julia_macros\"\nversion = \"99.0.0\""))
                RustCall._artifact_reset_digest_caches!()
                @test RustCall.compute_crate_hash(RustCall.scan_crate(crate)) == key

                # A version bump of any *other* path dependency moves it: that
                # crate may read `env!("CARGO_PKG_VERSION")`. So does a bump
                # of the fork, whatever it is called.
                write(joinpath(other, "Cargo.toml"), manifest("probe_dep", "0.1.1"))
                resolve()
                RustCall._artifact_reset_digest_caches!()
                bumped_other = RustCall.compute_crate_hash(RustCall.scan_crate(crate))
                @test bumped_other != key
                write(joinpath(dep, "Cargo.toml"), manifest("fork_macros", "0.4.1"))
                resolve()
                RustCall._artifact_reset_digest_caches!()
                bumped_fork = RustCall.compute_crate_hash(RustCall.scan_crate(crate))
                @test bumped_fork != bumped_other

                # ...and a source change in a path dependency still moves it.
                write(joinpath(dep, "src", "lib.rs"), "pub fn helper() -> i32 { 2 }")
                RustCall._artifact_reset_digest_caches!()
                @test RustCall.compute_crate_hash(RustCall.scan_crate(crate)) != bumped_fork

                # A workspace member takes the real crate through the root's
                # `[workspace.dependencies]`, and the lockfile is the root's:
                # the release crates whose lines leave the identity are found
                # from the member and the root together, so a patch bump
                # recorded in the root lock moves nothing (#372 review).
                ws = joinpath(dir, "ws"); member = joinpath(ws, "member")
                mkpath(joinpath(member, "src"))
                write(joinpath(member, "src", "lib.rs"), "pub fn answer() -> i32 { 42 }")
                write(joinpath(ws, "Cargo.toml"), """
                    [workspace]
                    members = ["member"]
                    resolver = "2"

                    [workspace.dependencies]
                    rustcall_julia_macros = { path = $(repr(real)) }
                    """)
                write(joinpath(member, "Cargo.toml"), """
                    [package]
                    name = "ws_member"
                    version = "0.1.0"
                    edition = "2021"

                    [lib]
                    crate-type = ["cdylib"]

                    [dependencies]
                    rustcall_julia_macros = { workspace = true }
                    """)
                run(pipeline(Cmd(`cargo generate-lockfile --offline`; dir = ws); stdout = devnull, stderr = devnull))
                @test RustCall._rustcall_release_names_in(ws) ==
                      Set(["rustcall_julia_macros", "rustcall_julia_macros_impl", "rustcall_julia_core"])
                @test isempty(RustCall._rustcall_release_names_in(member))
                RustCall._artifact_reset_digest_caches!()
                ws_key = RustCall.compute_crate_hash(RustCall.scan_crate(member))
                ws_lock = joinpath(ws, "Cargo.lock")
                pinned = "name = \"rustcall_julia_macros\"\nversion = \"$(real_version)\""
                @test occursin(pinned, read(ws_lock, String))
                write(ws_lock, replace(read(ws_lock, String),
                                       pinned => "name = \"rustcall_julia_macros\"\nversion = \"99.0.0\""))
                RustCall._artifact_reset_digest_caches!()
                @test RustCall.compute_crate_hash(RustCall.scan_crate(member)) == ws_key
                # ...while any other change to the root lock still moves it.
                write(ws_lock, read(ws_lock, String) * "# trailing\n")
                RustCall._artifact_reset_digest_caches!()
                @test RustCall.compute_crate_hash(RustCall.scan_crate(member)) != ws_key
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
        deps = joinpath(_ROOT, "deps")
        expected = RustCall._rust_sources_digest(
            (joinpath(deps, c) for c in RustCall._FINGERPRINT_CRATES)...)
        @test "sources=$(expected)" in parts
        # The extractor is identified by what the *selected binary* reports it
        # was built from — so `RUSTCALL_EXTRACT` pointing at another build
        # moves the key, and a version-only rebuild does not — never by its
        # bytes (`extractor_digest`) and never by this tree's copy of its
        # sources alone.
        extractor_line = only(filter(p -> startswith(p, "extractor="), parts))
        @test extractor_line != "extractor=$(RustCall.extractor_digest())"
        # A selected extractor that cannot report a source digest is identified
        # by its bytes — never by this checkout's sources, which say nothing
        # about what that executable emits (#372 review). Played with a real
        # executable that has no identity record beside it: the Julia binary
        # itself. A text file dressed as an `.exe` is not used — spawning one
        # hung the Windows CI job. Only the fingerprint input is read, so the
        # schema check the stub would also fail is not reached.
        stub = joinpath(Sys.BINDIR, Base.julia_exename())
        @test isfile(stub)
        RustCall._reset_extractor_state!()
        try
            withenv("RUSTCALL_EXTRACT" => stub) do
                @test RustCall.extractor_path() == stub
                @test RustCall.extractor_source_digest() ==
                      "binary:" * RustCall.extractor_digest()
                stub_parts, _ = RustCall._toolchain_fingerprint_inputs()
                stub_line = only(filter(p -> startswith(p, "extractor="), stub_parts))
                @test stub_line == "extractor=binary:" * RustCall.extractor_digest()
                @test stub_line != extractor_line
            end
        finally
            RustCall._reset_extractor_state!()
        end
        # The fingerprint's extractor line is the identity record's digest
        # when the selected binary has one (a build by `deps/build.jl` /
        # `Pkg.build`), and the bytes form otherwise (a raw `cargo build`, or
        # a `RUSTCALL_EXTRACT` binary from elsewhere) — never a value the
        # binary reports about itself (#409).
        # Read the record and the fingerprint together, after the reset above:
        # another test file in the same session (`test_native_layout` runs
        # `deps/build.jl`) may rewrite the record, and a line memoized before
        # that must not be compared with a record read after it.
        RustCall._reset_extractor_state!()
        fresh_parts, _ = RustCall._toolchain_fingerprint_inputs()
        fresh_line = only(filter(p -> startswith(p, "extractor="), fresh_parts))
        record = RustCall.read_extractor_identity(RustCall.extractor_path())
        if record === nothing || record["canonical"] !== true
            @test fresh_line == "extractor=binary:$(RustCall.extractor_digest())"
        else
            @test fresh_line == "extractor=$(record["source_digest"])"
            # A canonical build has no input beyond the sources (#413); the
            # binary's own `source-digest` self-report is gone (#417).
            @test all(i -> startswith(i, "crate:") || i == "lockfile", record["inputs"])
        end
        @test length(RustCall.toolchain_fingerprint()) == 64
    end
end
