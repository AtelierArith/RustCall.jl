# The extractor's build identity comes from Cargo's view of the build and is
# stored beside the binary keyed by its bytes (#409); the binary reports
# nothing about itself since v0.5 (#417).

using RustCall
using Test
using TOML
using RustToolChain: cargo

const _EI_ROOT = dirname(@__DIR__)
const _EI_CRATE = joinpath(_EI_ROOT, "deps", "rustcall_extract")

_ei_toolchain() = try
    success(pipeline(`$(cargo()) --version`; stdout = devnull, stderr = devnull))
catch
    false
end

@testset "extractor identity (#409)" begin
    @testset "cargo tree lines" begin
        p = RustCall._ei_parse_tree_line("rustcall_core v0.4.0 (/some/where/deps/rustcall_core)")
        @test p.name == "rustcall_core" && p.version == "0.4.0" && p.source == "/some/where/deps/rustcall_core"
        p = RustCall._ei_parse_tree_line("syn v2.0.100")
        @test p.name == "syn" && p.version == "2.0.100" && p.source === nothing
        p = RustCall._ei_parse_tree_line("thing v0.1.0 (https://github.com/x/y#abcdef) (*)")
        @test p.name == "thing" && p.source == "https://github.com/x/y#abcdef"
        p = RustCall._ei_parse_tree_line("serde_derive v1.0.219 (proc-macro)")
        @test p.name == "serde_derive" && p.version == "1.0.219" && p.source === nothing
        p = RustCall._ei_parse_tree_line("rustcall_julia_macros_impl v0.4.0 (/x/deps/rustcall_julia_macros_impl) (proc-macro) (*)")
        @test p.name == "rustcall_julia_macros_impl" && p.source == "/x/deps/rustcall_julia_macros_impl"
        @test RustCall._ei_parse_tree_line("") === nothing
        @test RustCall._ei_parse_tree_line("not a package line") === nothing
    end

    @testset "the decision, on gathered facts" begin
        mktempdir() do dir
            # A stand-in tree: deps/{rustcall_extract,rustcall_core} with the
            # default layout, and a lockfile beside the extractor.
            deps = joinpath(dir, "deps")
            for (name, body) in (("rustcall_extract", "fn main() {}\n"), ("rustcall_core", "pub fn f() {}\n"))
                mkpath(joinpath(deps, name, "src"))
                write(joinpath(deps, name, "src", name == "rustcall_extract" ? "main.rs" : "lib.rs"), body)
                write(joinpath(deps, name, "Cargo.toml"), """
                    [package]
                    name = "$(name)"
                    version = "0.4.0"
                    edition = "2021"
                    """)
            end
            crate = joinpath(deps, "rustcall_extract")
            write(joinpath(crate, "Cargo.lock"), """
                version = 4

                [[package]]
                name = "rustcall_core"
                version = "0.4.0"

                [[package]]
                name = "rustcall_extract"
                version = "0.4.0"
                dependencies = [
                 "rustcall_core",
                 "syn",
                ]

                [[package]]
                name = "syn"
                version = "2.0.1"
                source = "registry+https://github.com/rust-lang/crates.io-index"
                checksum = "0000"
                """)
            pkg(name, version, source) = (; name, version, source)
            packages = [pkg("rustcall_extract", "0.4.0", crate),
                        pkg("rustcall_core", "0.4.0", joinpath(deps, "rustcall_core")),
                        pkg("syn", "2.0.1", nothing)]
            root = joinpath(crate, "Cargo.toml")
            none = Pair{String, String}[]
            decide(; packages = packages, workspace = root, config = none, env = Dict{String, String}()) =
                RustCall._extractor_identity_decide(crate, packages, workspace, config, env)

            good = decide()
            @test good.canonical
            @test occursin(r"^[0-9a-f]{64}$", good.digest)
            @test "crate:rustcall_extract" in good.inputs && "crate:rustcall_core" in good.inputs
            # Deterministic, and the same whichever order Cargo listed them in.
            @test decide(packages = reverse(packages)).digest == good.digest

            # A patch bump of the release crates moves nothing: their version
            # lines leave the manifests and the lockfile alike.
            for name in ("rustcall_extract", "rustcall_core")
                m = joinpath(deps, name, "Cargo.toml")
                write(m, replace(read(m, String), "0.4.0" => "0.4.1"))
            end
            write(joinpath(crate, "Cargo.lock"), replace(read(joinpath(crate, "Cargo.lock"), String),
                                                          "version = \"0.4.0\"" => "version = \"0.4.1\""))
            bumped = [pkg("rustcall_extract", "0.4.1", crate),
                      pkg("rustcall_core", "0.4.1", joinpath(deps, "rustcall_core")),
                      pkg("syn", "2.0.1", nothing)]
            @test decide(packages = bumped).digest == good.digest
            # ...while a source change, a registry bump and a lockfile edit do.
            write(joinpath(deps, "rustcall_core", "src", "lib.rs"), "pub fn f() -> i32 { 1 }\n")
            changed = decide(packages = bumped).digest
            @test changed != good.digest
            # A module behind a directory symlink inside `src` is a source
            # like any other (rustc follows the link).
            if !Sys.iswindows()
                linked = joinpath(dir, "linked_src"); mkpath(linked)
                write(joinpath(linked, "mod.rs"), "pub fn g() {}\n")
                symlink(linked, joinpath(deps, "rustcall_core", "src", "linked"); dir_target = true)
                with_link = decide(packages = bumped).digest
                @test with_link != changed
                write(joinpath(linked, "mod.rs"), "pub fn g() -> i32 { 2 }\n")
                @test decide(packages = bumped).digest != with_link
                rm(joinpath(deps, "rustcall_core", "src", "linked"))
                changed = decide(packages = bumped).digest
            end
            write(joinpath(crate, "Cargo.lock"), replace(read(joinpath(crate, "Cargo.lock"), String),
                                                          "2.0.1" => "2.0.2"))
            @test decide(packages = bumped).digest != changed

            # The closed rule (#413): a digest is claimed only for a plain
            # build. Nothing is hashed on top of the sources, so an
            # environment or a configuration that cannot shape the build
            # leaves the digest exactly where it is...
            plain = decide(packages = bumped).digest
            harmless = Dict("CARGO_HOME" => joinpath(dir, "h"), "CARGO_TARGET_DIR" => joinpath(dir, "t"),
                            "CARGO_PROFILE_RELEASE_PANIC" => "unwind", "RUSTUP_TOOLCHAIN" => "stable",
                            "RUSTUP_HOME" => "/r", "CARGO_TERM_COLOR" => "always", "CARGO_NET_OFFLINE" => "true",
                            "CARGO_INCREMENTAL" => "0", "CARGO_REGISTRIES_CRATES_IO_PROTOCOL" => "sparse",
                            "CARGO_REGISTRY_TOKEN" => "hunter2", "RUST_BACKTRACE" => "1",
                            "HOME" => "/h", "PATH" => "/bin", "JULIA_NUM_THREADS" => "4",
                            "RUSTCALL_EXTRACT" => "/e", "RUSTCALL_HELPERS" => "/l", "RUSTCALL_CACHE_DIR" => "/c")
            r = decide(packages = bumped, env = harmless)
            @test r.canonical && r.digest == plain
            @test r.inputs == ["crate:rustcall_core", "crate:rustcall_extract", "lockfile"] ||
                  Set(r.inputs) == Set(["crate:rustcall_core", "crate:rustcall_extract", "lockfile"])
            cfg = joinpath(dir, "harmless.toml")
            write(cfg, "[net]\noffline = true\n\n[term]\ncolor = \"always\"\n\n[registries.crates-io]\nprotocol = \"sparse\"\n")
            r = decide(packages = bumped, config = ["config:home:config.toml" => cfg])
            @test r.canonical && r.digest == plain
            # ...while anything Cargo or rustc would act on declines, whatever
            # its value — an *empty* RUSTFLAGS still overrides a
            # configuration file's flags — with a reason that names the
            # variable and never quotes its value.
            for (k, v) in ("RUSTFLAGS" => "-C target-cpu=native", "RUSTFLAGS" => "",
                           "CARGO_ENCODED_RUSTFLAGS" => "--cfg\x1fx", "CARGO_BUILD_RUSTFLAGS" => "-C opt-level=1",
                           "RUSTC_WRAPPER" => "sccache", "RUSTC" => "/opt/rustc", "RUSTC_BOOTSTRAP" => "1",
                           "CARGO_BUILD_RUSTC_WRAPPER" => "wrap", "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER" => "/opt/ld",
                           "CARGO_PROFILE_RELEASE_OPT_LEVEL" => "0", "CARGO_PROFILE_RELEASE_PANIC" => "abort",
                           "CARGO_SOURCE_CRATES_IO_REPLACE_WITH" => "vendored", "CARGO_UNSTABLE_BUILD_STD" => "std",
                           "CARGO_CFG_FOO" => "", "__CARGO_TEST_ROOT" => "/x", "CC" => "clang", "PYO3_PYTHON" => "/usr/bin/python3")
                r = decide(packages = bumped, env = merge(harmless, Dict(k => v)))
                @test !r.canonical && r.digest === nothing
                @test occursin(k, r.reason) && (isempty(v) || !occursin(v, r.reason))
            end
            r = decide(packages = bumped, env = Dict("RUSTFLAGS" => "", "CC" => "cc"))
            @test occursin("CC, RUSTFLAGS", r.reason)
            # A configuration file declines unless every top-level table is
            # one that cannot shape the build; the reason names the table.
            for (text, key) in (("[build]\nrustflags = [\"-C\", \"target-cpu=native\"]\n", "build"),
                                ("[build]\nrustc-wrapper = \"sccache\"\n", "build"),
                                ("[target.x86_64-unknown-linux-gnu]\nlinker = \"ld\"\n", "target"),
                                ("[env]\nFOO = \"bar\"\n", "env"),
                                ("[source.crates-io]\nreplace-with = \"vendored\"\n\n[source.vendored]\ndirectory = \"vendor\"\n", "source"),
                                ("paths = [\"/somewhere/syn\"]\n", "paths"),
                                ("include = [\"extra.toml\"]\n", "include"),
                                ("[profile.release]\nopt-level = 1\n", "profile"),
                                ("[patch.crates-io]\nsyn = { path = \"/x\" }\n", "patch"),
                                ("[unstable]\nbuild-std = [\"std\"]\n", "unstable"),
                                ("[net]\noffline = true\n\n[build]\njobs = 4\n", "build"),
                                ("[something-new]\nx = 1\n", "something-new"))
                f = joinpath(dir, "cfg.toml"); write(f, text)
                r = decide(packages = bumped, config = ["config:ancestor:0:config.toml" => f])
                @test !r.canonical && occursin("config:ancestor:0:config.toml", r.reason) && occursin("`$(key)`", r.reason)
            end
            write(joinpath(dir, "cfg.toml"), "this is not toml = [")
            r = decide(packages = bumped, config = ["config:ancestor:0:config.toml" => joinpath(dir, "cfg.toml")])
            @test !r.canonical && occursin("does not parse", r.reason)
            # Windows environment names are case-insensitive: the copy the
            # build hands over is spelled upper case before any lookup or
            # judgement, so `rustflags` declines there like `RUSTFLAGS`.
            @test RustCall._ei_normalize_env(Dict("cargo_home" => "x", "Path" => "y"); windows = true) ==
                  Dict("CARGO_HOME" => "x", "PATH" => "y")
            lower = Dict("cargo_home" => "x")
            @test RustCall._ei_normalize_env(lower; windows = false) === lower
            @test !decide(packages = bumped, env = RustCall._ei_normalize_env(Dict("rustflags" => "-C x"); windows = true)).canonical

            # Not this tree's layout: no digest, and a reason.
            fork = joinpath(dir, "fork_core"); mkpath(joinpath(fork, "src"))
            write(joinpath(fork, "Cargo.toml"), "[package]\nname = \"rustcall_core\"\nversion = \"0.4.1\"\n")
            write(joinpath(fork, "src", "lib.rs"), "")
            r = decide(packages = [bumped[1], pkg("rustcall_core", "0.4.1", fork), bumped[3]])
            @test !r.canonical && r.digest === nothing && occursin("not this tree's deps/rustcall_core", r.reason)
            helper = joinpath(deps, "helper"); mkpath(joinpath(helper, "src"))
            write(joinpath(helper, "Cargo.toml"), "[package]\nname = \"helper\"\nversion = \"0.1.0\"\n")
            r = decide(packages = vcat(bumped, [pkg("helper", "0.1.0", helper)]))
            @test !r.canonical && occursin("not one of this tree's release crates", r.reason)
            r = decide(packages = vcat(bumped, [pkg("serde", "1.0.0", "https://github.com/serde-rs/serde#abc")]))
            @test !r.canonical && occursin("not crates.io", r.reason)
            r = decide(workspace = joinpath(dir, "Cargo.toml"))
            @test !r.canonical && occursin("member of the workspace", r.reason)
            r = decide(packages = nothing)
            @test !r.canonical && occursin("cargo tree", r.reason)
            # A manifest-selected target root outside `src` — including one
            # that merely shares the `src` prefix.
            for (rel, setup) in (("../shared/lib.rs", () -> (mkpath(joinpath(deps, "shared")); write(joinpath(deps, "shared", "lib.rs"), ""))),
                                 ("src_extra/lib.rs", () -> (mkpath(joinpath(deps, "rustcall_core", "src_extra")); write(joinpath(deps, "rustcall_core", "src_extra", "lib.rs"), ""))))
                setup()
                write(joinpath(deps, "rustcall_core", "Cargo.toml"),
                      "[package]\nname = \"rustcall_core\"\nversion = \"0.4.1\"\n\n[lib]\npath = \"$(rel)\"\n")
                r = decide(packages = bumped)
                @test !r.canonical && occursin("target root", r.reason)
            end
            # ...while a root under `src` proper is the default layout.
            write(joinpath(deps, "rustcall_core", "Cargo.toml"),
                  "[package]\nname = \"rustcall_core\"\nversion = \"0.4.1\"\n\n[lib]\npath = \"src/lib.rs\"\n")
            @test decide(packages = bumped).canonical
        end
    end

    @testset "configuration files Cargo discovers" begin
        mktempdir() do dir
            crate = joinpath(dir, "deps", "rustcall_extract"); mkpath(crate)
            mkpath(joinpath(dir, ".cargo")); write(joinpath(dir, ".cargo", "config.toml"), "[build]\n")
            # A rustup override selects the compiler, not a source: it is not
            # an input and is not looked for.
            write(joinpath(dir, "rust-toolchain.toml"), "[toolchain]\nchannel = \"stable\"\n")
            found = RustCall._ei_config_files(crate, Dict("CARGO_HOME" => joinpath(dir, "nohome")))
            @test !any(f -> occursin("toolchain", first(f)), found)
            @test all(f -> startswith(first(f), "config:"), found)
            @test any(f -> first(f) == "config:ancestor:2:config.toml" &&
                           realpath(last(f)) == realpath(joinpath(dir, ".cargo", "config.toml")), found)
            @test !any(f -> startswith(first(f), "config:home"), found)
            # No `CARGO_HOME`, `HOME` or `USERPROFILE` in the environment:
            # Cargo still reads the account home's configuration, and so does
            # this — whatever `homedir()` says, not nothing.
            found = RustCall._ei_config_files(crate, Dict{String, String}())
            home_entries = filter(f -> startswith(first(f), "config:home"), found)
            @test all(f -> startswith(realpath(last(f)), realpath(joinpath(homedir(), ".cargo"))), home_entries)
            @test length(home_entries) == count(isfile, (joinpath(homedir(), ".cargo", n) for n in ("config.toml", "config")))
            # `USERPROFILE` is a Windows variable: elsewhere Cargo ignores it
            # and falls back to the account home, and so does this.
            if !Sys.iswindows()
                mkpath(joinpath(dir, "winhome", ".cargo")); write(joinpath(dir, "winhome", ".cargo", "config.toml"), "")
                found = RustCall._ei_config_files(crate, Dict("USERPROFILE" => joinpath(dir, "winhome")))
                @test !any(f -> startswith(first(f), "config:home") && occursin("winhome", last(f)), found)
            end
            # `$CARGO_HOME`, absolute...
            home = joinpath(dir, "home"); mkpath(home); write(joinpath(home, "config.toml"), "")
            found = RustCall._ei_config_files(crate, Dict("CARGO_HOME" => home))
            @test any(f -> first(f) == "config:home:config.toml" &&
                           realpath(last(f)) == realpath(joinpath(home, "config.toml")), found)
            # ...and relative: Cargo resolves it against its working directory,
            # the crate directory for the build this describes — not against
            # this process's.
            mkpath(joinpath(crate, "relhome")); write(joinpath(crate, "relhome", "config.toml"), "")
            found = RustCall._ei_config_files(crate, Dict("CARGO_HOME" => "relhome"))
            @test any(f -> first(f) == "config:home:config.toml" &&
                           realpath(last(f)) == realpath(joinpath(crate, "relhome", "config.toml")), found)
            # ...and a relative `HOME` it falls back to, the same way.
            mkpath(joinpath(crate, "relhome2", ".cargo")); write(joinpath(crate, "relhome2", ".cargo", "config.toml"), "")
            found = RustCall._ei_config_files(crate, Dict("HOME" => "relhome2"))
            @test any(f -> first(f) == "config:home:config.toml" &&
                           realpath(last(f)) == realpath(joinpath(crate, "relhome2", ".cargo", "config.toml")), found)
        end
    end

    @testset "the record beside the binary" begin
        mktempdir() do dir
            binary = joinpath(dir, "rustcall-extract")
            write(binary, "not really a binary")
            # No record: nothing to read.
            @test RustCall.read_extractor_identity(binary) === nothing
            record = Dict("format" => 1, "binary_sha256" => RustCall.bytes2hex(RustCall.sha256(read(binary))),
                          "canonical" => true, "source_digest" => "ab" ^ 32, "reason" => "", "inputs" => ["x"])
            open(joinpath(dir, RustCall.EXTRACTOR_IDENTITY_FILENAME), "w") do io
                TOML.print(io, record)
            end
            @test RustCall.read_extractor_identity(binary)["source_digest"] == "ab" ^ 32
            # And it is what the fingerprint uses for that binary...
            RustCall._reset_extractor_state!()
            try
                withenv("RUSTCALL_EXTRACT" => binary) do
                    @test RustCall.extractor_source_digest() == "ab" ^ 32
                end
                # ...until the binary changes: the record then describes
                # another binary and the bytes take over.
                RustCall._reset_extractor_state!()
                write(binary, "rebuilt")
                withenv("RUSTCALL_EXTRACT" => binary) do
                    @test RustCall.read_extractor_identity(binary) === nothing
                    @test RustCall.extractor_source_digest() == "binary:" * RustCall.extractor_digest()
                end
                # A record that declines (non-canonical build) also means bytes.
                RustCall._reset_extractor_state!()
                record["binary_sha256"] = RustCall.bytes2hex(RustCall.sha256(read(binary)))
                record["canonical"] = false; record["source_digest"] = ""
                open(joinpath(dir, RustCall.EXTRACTOR_IDENTITY_FILENAME), "w") do io
                    TOML.print(io, record)
                end
                withenv("RUSTCALL_EXTRACT" => binary) do
                    @test RustCall.extractor_source_digest() == "binary:" * RustCall.extractor_digest()
                end
            finally
                RustCall._reset_extractor_state!()
            end
        end
    end

    @testset "this tree, through Cargo" begin
        if !_ei_toolchain()
            @test_skip "needs a Rust toolchain"
        else
            identity = RustCall.extractor_build_identity(_EI_CRATE; cargo = cargo())
            @test identity.canonical
            # Under the environment `deps/build.jl` builds with, the same digest.
            build_env = copy(ENV); build_env["CARGO_PROFILE_RELEASE_PANIC"] = "unwind"
            @test RustCall.extractor_build_identity(_EI_CRATE; cargo = cargo(), env = build_env).digest == identity.digest
            @test occursin(r"^[0-9a-f]{64}$", identity.digest)
            # The extractor's own local closure: itself and `rustcall_core`
            # (the macro crates are inputs of a *user's* build, covered by the
            # `sources=` fingerprint line, not of this binary).
            @test Set(filter(startswith("crate:"), identity.inputs)) ==
                  Set(["crate:rustcall_extract", "crate:rustcall_core"])
            # A canonical build has no input beyond the sources (#413)...
            @test Set(identity.inputs) == Set(["crate:rustcall_core", "crate:rustcall_extract", "lockfile"])
            # ...and the binary no longer reports a digest of its own (#417):
            # the record beside it is the only source of the identity.
            binary = RustCall.extractor_path()
            @test !success(pipeline(`$binary source-digest`; stdout = devnull, stderr = devnull))
            # `write_extractor_identity!` produces a record `read_extractor_identity` accepts.
            mktempdir() do dir
                fake = joinpath(dir, "rustcall-extract"); write(fake, "bytes")
                written = RustCall.write_extractor_identity!(_EI_CRATE, fake; cargo = cargo())
                @test written.digest == identity.digest
                record = RustCall.read_extractor_identity(fake)
                @test record !== nothing && record["source_digest"] == identity.digest && record["canonical"]
            end
        end
    end
end
