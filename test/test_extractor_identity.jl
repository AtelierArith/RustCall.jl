# The extractor's build identity comes from Cargo's view of the build, is
# stored beside the binary keyed by its bytes, and is byte-compatible with
# what v0.4.0's build.rs embedded (#409).

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
            decide(; packages = packages, workspace = root, config = none, env = none,
                     executables = Pair{String, Union{Nothing, String}}[]) =
                RustCall._extractor_identity_decide(crate, packages, workspace, config, env, executables)

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

            # Inputs the v0.4.0 script never saw: configuration and flags move
            # the digest, and are listed.
            cfg = joinpath(dir, "config.toml")
            write(cfg, "[build]\nrustflags = [\"-C\", \"target-cpu=native\"]\n")
            with_cfg = decide(packages = bumped, config = ["config:home:config.toml" => cfg])
            @test with_cfg.canonical && with_cfg.digest != decide(packages = bumped).digest
            @test "config:home:config.toml" in with_cfg.inputs
            with_env = decide(packages = bumped, env = ["RUSTFLAGS" => "-C target-cpu=native"])
            @test with_env.canonical && with_env.digest != decide(packages = bumped).digest
            @test "env:RUSTFLAGS" in with_env.inputs
            # An *empty* RUSTFLAGS is not an unset one: it overrides a config
            # file's flags where an unset variable lets them apply.
            empty_env = decide(packages = bumped, env = ["RUSTFLAGS" => ""])
            @test empty_env.digest != decide(packages = bumped).digest
            @test empty_env.digest != with_env.digest
            @test RustCall._ei_env_inputs(Dict("RUSTFLAGS" => "", "HOME" => "/x")) == ["RUSTFLAGS" => ""]
            @test isempty(RustCall._ei_env_inputs(Dict("HOME" => "/x")))
            # The same policy every artifact key applies: profile overrides
            # and rustc wrappers count, secrets never do.
            @test RustCall._ei_env_inputs(Dict("CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS" => "true",
                                               "RUSTC_WRAPPER" => "sccache",
                                               "CARGO_REGISTRY_TOKEN" => "hunter2")) ==
                  ["CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS" => "true", "RUSTC_WRAPPER" => "sccache"]
            with_profile = decide(packages = bumped, env = ["CARGO_PROFILE_RELEASE_OVERFLOW_CHECKS" => "true"])
            @test with_profile.canonical && with_profile.digest != decide(packages = bumped).digest
            # The value `deps/build.jl` pins for every build — what the
            # manifest pins too — is the baseline, not an input; any other
            # value of that variable is.
            @test isempty(RustCall._ei_env_inputs(Dict("CARGO_PROFILE_RELEASE_PANIC" => "unwind")))
            @test RustCall._ei_env_inputs(Dict("CARGO_PROFILE_RELEASE_PANIC" => "abort")) ==
                  ["CARGO_PROFILE_RELEASE_PANIC" => "abort"]

            # A wrapper Cargo runs in front of rustc is an input by its
            # *bytes*: the same RUSTC_WRAPPER value with a changed executable
            # is a different build; one that cannot be resolved declines.
            wrapper = joinpath(dir, "wrapper.sh"); write(wrapper, "#!/bin/sh\nexec \"\$@\"\n")
            with_wrapper = decide(packages = bumped, env = ["RUSTC_WRAPPER" => wrapper],
                                  executables = ["RUSTC_WRAPPER" => wrapper])
            @test with_wrapper.canonical && "executable:RUSTC_WRAPPER" in with_wrapper.inputs
            write(wrapper, "#!/bin/sh\nexec \"\$@\" -C opt-level=0\n")
            @test decide(packages = bumped, env = ["RUSTC_WRAPPER" => wrapper],
                         executables = ["RUSTC_WRAPPER" => wrapper]).digest != with_wrapper.digest
            r = decide(packages = bumped, env = ["RUSTC_WRAPPER" => "no-such-wrapper"],
                       executables = ["RUSTC_WRAPPER" => nothing])
            @test !r.canonical && occursin("could not be resolved", r.reason)
            # Resolution: absolute, relative to the crate directory, or on PATH.
            @test RustCall._ei_resolve_executable(wrapper, Dict{String, String}(), crate) == realpath(wrapper)
            @test RustCall._ei_resolve_executable("wrapper.sh", Dict("PATH" => dir), crate) == realpath(wrapper)
            @test RustCall._ei_resolve_executable("missing", Dict("PATH" => dir), crate) === nothing
            # A relative PATH entry is taken from the crate directory (where
            # Cargo runs), not from this process's working directory.
            mkpath(joinpath(crate, "tools")); write(joinpath(crate, "tools", "wrap"), "#!/bin/sh\n")
            mkpath(joinpath(dir, "tools")); write(joinpath(dir, "tools", "wrap"), "#!/bin/sh\nexit 1\n")
            cd(dir) do
                @test RustCall._ei_resolve_executable("wrap", Dict("PATH" => "tools"), crate) ==
                      realpath(joinpath(crate, "tools", "wrap"))
            end
            # Windows environment names are case-insensitive: the copy the
            # build hands over is spelled upper case before any lookup.
            @test RustCall._ei_normalize_env(Dict("cargo_home" => "x", "Path" => "y"); windows = true) ==
                  Dict("CARGO_HOME" => "x", "PATH" => "y")
            lower = Dict("cargo_home" => "x")
            @test RustCall._ei_normalize_env(lower; windows = false) === lower
            @test RustCall._ei_rustc_executables(Dict("RUSTC_WRAPPER" => wrapper, "HOME" => dir), crate) ==
                  ["RUSTC_WRAPPER" => realpath(wrapper)]
            @test isempty(RustCall._ei_rustc_executables(Dict("RUSTC_WRAPPER" => ""), crate))
            # Cargo's own spellings — the `CARGO_BUILD_*` variables and
            # `[build]` keys of a configuration file — select the same
            # executables and are hashed the same way.
            @test RustCall._ei_rustc_executables(Dict("CARGO_BUILD_RUSTC_WRAPPER" => wrapper), crate) ==
                  ["CARGO_BUILD_RUSTC_WRAPPER" => realpath(wrapper)]
            cargo_dir = joinpath(dir, "cfgroot", ".cargo"); mkpath(cargo_dir)
            write(joinpath(cargo_dir, "config.toml"), "[build]\nrustc-wrapper = \"tools/wrap.sh\"\n")
            mkpath(joinpath(dir, "cfgroot", "tools")); write(joinpath(dir, "cfgroot", "tools", "wrap.sh"), "#!/bin/sh\n")
            cfg_execs = RustCall._ei_config_executables(["config:ancestor:1:config.toml" => joinpath(cargo_dir, "config.toml")],
                                                        Dict{String, String}(), crate)
            @test cfg_execs == ["config:ancestor:1:config.toml:rustc-wrapper" => realpath(joinpath(dir, "cfgroot", "tools", "wrap.sh"))]
            r = decide(packages = bumped, executables = cfg_execs)
            @test r.canonical && "executable:config:ancestor:1:config.toml:rustc-wrapper" in r.inputs
            write(joinpath(cargo_dir, "config.toml"), "[build]\nrustc-wrapper = \"tools/missing.sh\"\n")
            missing_exec = RustCall._ei_config_executables(["config:ancestor:1:config.toml" => joinpath(cargo_dir, "config.toml")],
                                                           Dict{String, String}(), crate)
            @test only(missing_exec) == ("config:ancestor:1:config.toml:rustc-wrapper" => nothing)
            @test !decide(packages = bumped, executables = missing_exec).canonical
            # `$CARGO_HOME/config.toml` resolves the same way — from the
            # parent of the directory holding the file — even when that
            # directory is not named `.cargo`; a same-named file inside it
            # is not the one Cargo runs.
            home = joinpath(dir, "myhome"); mkpath(joinpath(home, "tools")); mkpath(joinpath(dir, "tools"))
            write(joinpath(home, "config.toml"), "[build]\nrustc-wrapper = \"tools/wrap\"\n")
            write(joinpath(home, "tools", "wrap"), "#!/bin/sh\nexit 1\n")
            write(joinpath(dir, "tools", "wrap"), "#!/bin/sh\n")
            @test RustCall._ei_config_executables(["config:home:config.toml" => joinpath(home, "config.toml")],
                                                  Dict{String, String}(), crate) ==
                  ["config:home:config.toml:rustc-wrapper" => realpath(joinpath(dir, "tools", "wrap"))]
            # A source replaced through the environment declines like one
            # replaced through a file.
            @test RustCall._ei_env_replaces_sources(Dict("CARGO_SOURCE_CRATES_IO_REPLACE_WITH" => "vendored"))
            @test !RustCall._ei_env_replaces_sources(Dict("CARGO_HOME" => "/x"))
            r = decide(packages = bumped, env = ["CARGO_SOURCE_*" => ""])
            @test !r.canonical && occursin("CARGO_SOURCE_", r.reason)

            # A configuration that redirects a source — the `cargo vendor`
            # form, or `paths` — makes the build one this identity cannot
            # describe: `cargo tree` prints a vendored package like a
            # crates.io one, so the configuration is what says.
            for text in ("[source.crates-io]\nreplace-with = \"vendored\"\n\n[source.vendored]\ndirectory = \"vendor\"\n",
                         "paths = [\"/somewhere/syn\"]\n",
                         "include = [\"extra.toml\"]\n",
                         "this is not toml = [")
                vendored = joinpath(dir, "vendored.toml"); write(vendored, text)
                r = decide(packages = bumped, config = ["config:ancestor:0:config.toml" => vendored])
                @test !r.canonical && occursin("replaces a source or includes", r.reason)
            end
            # ...while an ordinary configuration merely enters the digest.
            @test decide(packages = bumped, config = ["config:home:config.toml" => cfg]).canonical
            # A rustup override selects the toolchain that compiled the
            # binary: it enters the digest (hashed, not parsed — the legacy
            # file is a bare channel name) and does not decline.
            for (name, text) in (("rust-toolchain.toml", "[toolchain]\nchannel = \"nightly-2026-01-01\"\n"),
                                 ("rust-toolchain", "nightly-2026-01-01\n"))
                tc = joinpath(dir, name); write(tc, text)
                r = decide(packages = bumped, config = ["toolchain:ancestor:0:$(name)" => tc])
                @test r.canonical && r.digest != decide(packages = bumped).digest
                @test "toolchain:ancestor:0:$(name)" in r.inputs
            end

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
            write(joinpath(dir, "rust-toolchain.toml"), "[toolchain]\nchannel = \"stable\"\n")
            found = RustCall._ei_config_files(crate, Dict("CARGO_HOME" => joinpath(dir, "nohome")))
            @test any(f -> first(f) == "toolchain:ancestor:2:rust-toolchain.toml", found)
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
            # Byte-compatible with what the v0.4.0 build.rs embeds — the
            # cross-check that keeps every cache key across the upgrade — when
            # nothing the script never saw is present.
            extra = filter(i -> !startswith(i, "crate:") && i != "lockfile", identity.inputs)
            binary = RustCall.extractor_path()
            reported = try
                strip(read(`$binary source-digest`, String))
            catch
                ""
            end
            if isempty(extra) && occursin(r"^[0-9a-f]{64}$", reported)
                @test identity.digest == reported
            else
                @info "source-digest cross-check not applicable" extra reported
            end
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
