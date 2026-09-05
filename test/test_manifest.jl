# Tests for the FFI manifest pipeline (issue #264): the rustcall-extract CLI is
# the only component that interprets Rust syntax; Julia consumes its manifest.
using RustCall
using Test
using TOML

@testset "FFI Manifest" begin
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping manifest tests"
        return
    end

    @testset "extractor is available and versioned" begin
        exe = RustCall.extractor_path()
        @test isfile(exe)
        @test strip(read(`$exe schema-version`, String)) == string(RustCall.MANIFEST_SCHEMA_VERSION)
        @test length(RustCall.extractor_digest()) == 64
        @test length(RustCall.toolchain_fingerprint()) == 64
    end

    # Golden files may be checked out with CRLF on Windows; compare with LF only.
    _lf(x::AbstractString) = replace(String(x), "\r\n" => "\n")
    _lf(x::AbstractDict) = Dict{String, Any}(k => _lf(v) for (k, v) in x)
    _lf(x::AbstractVector) = Any[_lf(v) for v in x]
    _lf(x) = x

    @testset "schema 4: return_abi, Field.abi, returns_boxed_struct (#276)" begin
        # The manifest — not the Rust spelling — is what says how a value
        # crosses the boundary. Schema 4 makes that true for free functions
        # (`return_abi`), struct fields (`abi`) and boxed returns.
        manifest = RustCall.extract_manifest("""
        #[julia]
        pub fn shout(s: String) -> String { s.to_uppercase() }
        #[julia]
        pub fn greeting() -> &'static str { "hi" }
        #[julia]
        pub fn plain(x: i32) -> i32 { x }
        #[julia]
        pub struct Tagged { tag: String, n: u16 }
        impl Tagged {
            pub fn new(tag: String) -> Self { Self { tag, n: 0 } }
            pub fn n(&self) -> u16 { self.n }
        }
        """; mode = "inline")

        sigs = RustCall.manifest_function_signatures(manifest)
        by_name = Dict(s.name => s for s in sigs)
        @test by_name["shout"].return_abi == "string"
        @test by_name["shout"].has_owned_string_helper
        @test by_name["greeting"].return_abi == "str"
        @test by_name["greeting"].has_borrowed_string_helper
        @test by_name["plain"].return_abi == ""
        # The booleans are derived from the column, never the other way round.
        for s in sigs
            @test s.has_owned_string_helper == (s.return_abi == "string")
            @test s.has_borrowed_string_helper == (s.return_abi == "str")
        end

        info = only(RustCall.manifest_struct_infos(manifest))
        @test info.field_abis["tag"] == "string"
        @test info.field_abis["n"] == ""
        @test info.has_owned_string_helper
        @test only(m for m in info.methods if m.name == "new").returns_boxed_struct
        @test only(m for m in info.methods if m.name == "n").returns_boxed_struct == false
    end

    @testset "schema 4: crate-mode String fields are lowered too (#246)" begin
        manifest = RustCall.extract_manifest("""
        use juliacall_macros::julia;
        #[julia]
        pub struct Counter { count: u32, name: String }
        """; mode = "crate")
        info = only(RustCall.manifest_struct_infos(manifest))
        @test info.field_abis["name"] == "string"
        @test info.field_abis["count"] == ""
        @test info.has_owned_string_helper
    end

    @testset "CLI output matches the golden corpus" begin
        # The corpus is the Rust-side golden test; the CLI must produce exactly
        # the same manifests so the two front ends cannot drift apart.
        corpus = joinpath(dirname(@__DIR__), "deps", "rustcall_core", "tests", "corpus")
        sources = filter(f -> endswith(f, ".rs") && !endswith(f, ".expanded.rs"), readdir(corpus))
        @test !isempty(sources)
        for src in sources
            name = first(splitext(src))
            path = joinpath(corpus, src)
            for mode in ("inline", "crate")
                golden = joinpath(corpus, "$name.$mode.toml")
                isfile(golden) || continue
                # The corpus is platform independent: no cfg filtering here.
                got = _lf(RustCall.extract_manifest([path]; mode = mode, cfg = false))
                want = _lf(TOML.parsefile(golden))
                @test got == want
            end
            expanded_golden = joinpath(corpus, "$name.expanded.rs")
            if isfile(expanded_golden)
                got = RustCall.expand_inline(_lf(read(path, String)); cfg = false).source
                @test _lf(got) == _lf(read(expanded_golden, String))
            end
        end
    end

    @testset "#[cfg]-disabled items are not reported" begin
        # `any()` is never true, `all()` always is; `unix`/`windows` follow the host.
        code = """
        #[cfg(all())]
        #[julia]
        pub fn always_on() -> i32 { 1 }

        #[cfg(any())]
        #[julia]
        pub fn never_on() -> i32 { 2 }

        #[cfg(not(windows))]
        #[julia]
        pub fn on_unix_like() -> i32 { 3 }

        #[cfg(windows)]
        #[julia]
        pub fn on_windows() -> i32 { 4 }

        #[cfg(any())]
        #[julia]
        pub struct Ghost { pub x: i32 }

        #[cfg(any())]
        mod ghost_mod {
            #[julia]
            pub fn gone() -> i32 { 5 }
        }
        """
        names(m) = String[String(f["name"]) for f in m["functions"]]

        # Without cfg filtering every item is listed with its predicate.
        raw = RustCall.extract_manifest(code; mode = "inline", cfg = false)
        @test Set(names(raw)) == Set(["always_on", "never_on", "on_unix_like", "on_windows", "gone"])
        preds = Dict(String(f["name"]) => String(f["cfg"]) for f in raw["functions"])
        @test preds["always_on"] == "all()"
        @test preds["never_on"] == "any()"
        @test preds["on_windows"] == "windows"
        @test String(only(raw["structs"])["cfg"]) == "any()"

        # With the host configuration only compiled items remain.
        host = RustCall.extract_manifest(code; mode = "inline")
        expected = Sys.iswindows() ? ["always_on", "on_windows"] : ["always_on", "on_unix_like"]
        @test Set(names(host)) == Set(expected)
        @test isempty(host["structs"])
        crate = RustCall.extract_manifest(code; mode = "crate")
        @test Set(names(crate)) == Set(expected)

        expanded = RustCall.expand_inline(code)
        @test Set(s.name for s in RustCall.manifest_function_signatures(expanded.manifest)) == Set(expected)
        @test !occursin("never_on", expanded.source)
        @test !occursin("Ghost", expanded.source)
        @test !occursin("ghost_mod", expanded.source)

        # Cache keys differ for the two views of the same source.
        @test RustCall.expand_inline(code; cfg = false).manifest != expanded.manifest
        @test RustCall.expand_inline(code) === expanded
        # ... and for a different compiler configuration: at opt-level 0
        # `debug_assertions` is set, so the same block expands differently.
        dbg_code = """
        #[cfg(debug_assertions)]
        #[julia]
        pub fn only_in_debug() -> i32 { 1 }
        """
        default_compiler = RustCall.get_default_compiler()
        try
            RustCall.set_default_compiler(RustCall.RustCompiler(optimization_level = 2))
            @test isempty(RustCall.expand_inline(dbg_code).manifest["functions"])
            RustCall.set_default_compiler(RustCall.RustCompiler(optimization_level = 0))
            @test length(RustCall.expand_inline(dbg_code).manifest["functions"]) == 1
            # A snapshot captured earlier wins over the current compiler, so the
            # macro-time and run-time expansions of a block agree.
            snapshot_o2 = RustCall._rustc_cfg_text(RustCall._cfg_rustc_flags(RustCall.RustCompiler(optimization_level = 2)))
            @test isempty(RustCall.expand_inline(dbg_code; cfg_text = snapshot_o2).manifest["functions"])
            @test RustCall._cfg_snapshot(:none) == ""
            @test RustCall._cfg_snapshot(:strict) == RustCall._rustc_cfg_text()
        finally
            RustCall.set_default_compiler(default_compiler)
        end
        @test isempty(RustCall._cfg_file_args(:strict; cfg_text = ""))

        # The cfg file handed to the extractor is `rustc --print cfg` under the
        # flags of the actual compiler invocation, written once per flag set.
        args = RustCall._cfg_file_args(:strict)
        @test length(args) == 2 && args[1] == "--cfg-file"
        @test read(args[2], String) == RustCall._rustc_cfg_text()
        @test RustCall._cfg_file_args(true) == args
        lenient_args = RustCall._cfg_file_args(:lenient)
        @test lenient_args[[1, 3]] == ["--cfg-file", "--cfg-lenient"]
        @test read(lenient_args[2], String) == RustCall._cfg_snapshot(:lenient)
        @test isempty(RustCall._cfg_file_args(false))
        @test isempty(RustCall._cfg_file_args(:none))
        @test_throws ArgumentError RustCall._cfg_file_args(:bogus)
        flags = RustCall._cfg_rustc_flags()
        @test any(startswith("--target="), flags) && "panic=abort" in flags
        # Direct rustc builds use opt-level 2 and panic=abort, so the strict set
        # must reflect that rather than the bare toolchain defaults.
        strict = RustCall._rustc_cfg_text()
        @test occursin("panic=\"abort\"", strict)
        @test !occursin("debug_assertions", strict)
        @test occursin("debug_assertions", RustCall._rustc_cfg_text(String["-C", "opt-level=0"]))

        # Profile predicates follow the real compiler flags.
        profile_code = """
        #[cfg(debug_assertions)]
        #[julia]
        pub fn dbg_only() -> i32 { 1 }
        #[cfg(panic = "abort")]
        #[julia]
        pub fn abort_only() -> i32 { 2 }
        #[cfg(feature = "extra")]
        #[julia]
        pub fn feature_only() -> i32 { 3 }
        """
        strict_names = names(RustCall.extract_manifest(profile_code; mode = "inline"))
        @test Set(strict_names) == Set(["abort_only"])
        # Lenient (Cargo builds): only target predicates are decided; feature and
        # profile predicates keep their items.
        lenient_names = names(RustCall.extract_manifest(profile_code; mode = "crate", cfg = :lenient))
        @test Set(lenient_names) == Set(["dbg_only", "abort_only", "feature_only"])
        # Cargo projects RustCall generates are fully described by the probe: no
        # build script, no declared features, the release profile RustCall writes.
        # So every predicate is decided there, against Cargo's effective
        # configuration (profile overrides in the environment and RUSTFLAGS
        # included), exactly as for a direct rustc build.
        cargo_names = names(RustCall.extract_manifest(profile_code; mode = "inline", cfg = :cargo))
        # unwind, no debug_assertions, and the generated crate has no features
        @test isempty(cargo_names)
        cargo_args = RustCall._cfg_file_args(:cargo)
        @test length(cargo_args) == 2 && cargo_args[1] == "--cfg-file"
        @test read(cargo_args[2], String) == RustCall._cfg_snapshot(:cargo)
        @test Set(names(RustCall.extract_manifest(profile_code; mode = "crate", cfg = :lenient))) ==
              Set(["dbg_only", "abort_only", "feature_only"])
        cargo_cfg = RustCall._cfg_snapshot(:cargo)
        @test occursin("panic=\"unwind\"", cargo_cfg)
        @test !occursin("debug_assertions", cargo_cfg)
        @test occursin("target_os=", cargo_cfg) && !occursin("Compiling", cargo_cfg)
        @test RustCall._cfg_snapshot(:lenient) == cargo_cfg
        withenv("CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS" => "true", "RUSTFLAGS" => "-C panic=abort") do
            overridden = RustCall._cargo_cfg_text()
            @test occursin("debug_assertions", overridden)
            @test occursin("panic=\"abort\"", overridden)
            @test Set(names(RustCall.extract_manifest(profile_code; mode = "inline", cfg = :cargo))) ==
                  Set(["dbg_only", "abort_only"])
            # The Cargo environment is recorded with Cargo-backed blocks and can
            # be restored for a reload.
            env_key = RustCall._cargo_cfg_env_key()
            @test occursin("CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS=true", env_key)
            @test occursin("RUSTFLAGS=-C panic=abort", env_key)
            restored = withenv("CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS" => nothing, "RUSTFLAGS" => "-C opt-level=1",
                               "CARGO_BUILD_RUSTC" => "other-rustc", "CARGO_TERM_COLOR" => "never") do
                RustCall._cargo_build_env(env_key)
            end
            @test restored["CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS"] == "true"
            @test restored["RUSTFLAGS"] == "-C panic=abort"
            # cfg-affecting variables not in the snapshot are dropped ...
            @test !haskey(restored, "CARGO_BUILD_RUSTC")
            # ... unrelated ones are left alone.
            @test restored["CARGO_TERM_COLOR"] == "never"
            @test haskey(restored, "PATH")

            # Credentials never enter the snapshot.
            withenv("CARGO_REGISTRIES_PRIVATE_TOKEN" => "s3cret", "CARGO_REGISTRY_TOKEN" => "s3cret",
                    "CARGO_HTTP_CAINFO" => "/tmp/ca.pem") do
                key = RustCall._cargo_cfg_env_key()
                @test !occursin("s3cret", key)
                @test !occursin("TOKEN", key)
                @test !RustCall._is_cargo_env_key("CARGO_REGISTRIES_PRIVATE_TOKEN")
                @test !RustCall._is_cargo_env_key("CARGO_REGISTRY_TOKEN")
                @test RustCall._is_cargo_env_key("CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS")
                @test RustCall._is_cargo_env_key("RUSTFLAGS")
                @test !RustCall._is_cargo_env_key("PATH")
            end

            # Per-target flags (`CARGO_TARGET_<TRIPLE>_RUSTFLAGS`) carry `--cfg`
            # and codegen options like RUSTFLAGS; the linker decides how the
            # cdylib is linked. Both are tracked; runner, target dir and
            # anything credential-like are not.
            @test RustCall._is_cargo_env_key("CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS")
            @test RustCall._is_cargo_env_key("CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER")
            @test RustCall._is_cargo_env_key("cargo_target_x86_64_unknown_linux_gnu_rustflags")
            @test !RustCall._is_cargo_env_key("CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUNNER")
            @test !RustCall._is_cargo_env_key("CARGO_TARGET_DIR")
            @test !RustCall._is_cargo_env_key("CARGO_TARGET_X_AUTH_TOKEN")
            @test !RustCall._is_cargo_env_key("CARGO_TARGET_X_TOKEN_RUSTFLAGS")
            @test !RustCall._is_cargo_env_key("CARGO_TARGET_X_SECRET_LINKER")
            withenv("CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS" => "--cfg foo",
                    "CARGO_TARGET_X_AUTH_TOKEN" => "s3cret") do
                key = RustCall._cargo_cfg_env_key()
                @test occursin("CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS=--cfg foo", key)
                @test !occursin("s3cret", key) && !occursin("AUTH_TOKEN", key)
                # ... and it is part of the library identity.
                @test RustCall._cargo_block_identity("fn f() {}", "deps", key) !=
                      RustCall._cargo_block_identity("fn f() {}", "deps", "")
            end

            # CARGO_HOME selects the Cargo configuration the probe observes
            # (`[build] rustflags`): the variable is tracked, and so is the
            # content of that configuration file.
            @test RustCall._is_cargo_env_key("CARGO_HOME")
            @test !RustCall._is_cargo_env_key("CARGO_HOME_TOKEN")
            mktempdir() do home
                write(joinpath(home, "config.toml"),
                      "[build]\nrustflags = [\"--cfg\", \"rustcall_custom_probe\"]\n")
                key_default = RustCall._cargo_cfg_env_key()
                withenv("CARGO_HOME" => home, "RUSTFLAGS" => nothing, "CARGO_ENCODED_RUSTFLAGS" => nothing) do
                    key_home = RustCall._cargo_cfg_env_key()
                    @test key_home != key_default
                    @test occursin("CARGO_HOME=$home", key_home)
                    digest = RustCall._cargo_config_digest()
                    @test digest != "absent"
                    @test occursin(RustCall._CARGO_CONFIG_LINE * digest, key_home)
                    @test RustCall._cargo_block_identity("fn f() {}", "deps", key_home) !=
                          RustCall._cargo_block_identity("fn f() {}", "deps", key_default)
                    # The probe sees the config's `--cfg`, so the block identity
                    # and the cfg text follow CARGO_HOME.
                    probe = RustCall._cargo_cfg_text()
                    @test occursin("rustcall_custom_probe", probe)
                    custom_code = "#[cfg(rustcall_custom_probe)]\n#[julia]\npub fn custom_on() -> i32 { 1 }\n"
                    @test names(RustCall.extract_manifest(custom_code; mode = "inline", cfg = :cargo)) == ["custom_on"]
                    # Editing the config changes the snapshot even under the same CARGO_HOME.
                    write(joinpath(home, "config.toml"), "[build]\nrustflags = []\n")
                    @test RustCall._cargo_cfg_env_key() != key_home
                    @test RustCall._cargo_config_digest() != digest
                    # The replayed build environment restores CARGO_HOME; the
                    # metadata line is not a variable.
                    env = RustCall._cargo_build_env(key_home)
                    @test env["CARGO_HOME"] == home
                    @test !any(k -> startswith(k, "#"), keys(env))
                end
                @test isempty(names(RustCall.extract_manifest("#[cfg(rustcall_custom_probe)]\n#[julia]\npub fn custom_on() -> i32 { 1 }\n"; mode = "inline", cfg = :cargo)))
                # Cleared when the snapshot has none.
                @test !haskey(withenv(() -> RustCall._cargo_build_env(""), "CARGO_HOME" => home), "CARGO_HOME")
                @test RustCall._cargo_config_digest(Dict("CARGO_HOME" => joinpath(home, "nowhere"))) == "absent"
            end

            # An empty snapshot is a snapshot: the block was expanded with no
            # tracked variable set, so a RUSTFLAGS present at build time must
            # be cleared, not inherited (the wrappers were generated without it).
            withenv("RUSTFLAGS" => "--cfg foo", "CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS" => "true",
                    "CARGO_TERM_COLOR" => "never") do
                env, key = RustCall._cargo_build_env_for("")
                @test key == ""
                @test env isa Dict{String, String}
                @test !haskey(env, "RUSTFLAGS")
                @test !haskey(env, "CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS")
                @test env["CARGO_TERM_COLOR"] == "never"
                @test haskey(env, "PATH")
                # Only `nothing` (no snapshot recorded) means the current environment.
                env, key = RustCall._cargo_build_env_for(nothing)
                @test env === nothing
                @test occursin("RUSTFLAGS=--cfg foo", key)
                # A non-empty snapshot restores exactly what it records.
                env, key = RustCall._cargo_build_env_for("RUSTFLAGS=-C panic=abort")
                @test env["RUSTFLAGS"] == "-C panic=abort" && key == "RUSTFLAGS=-C panic=abort"
                @test !haskey(env, "CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS")
            end
            # The macro records a real (possibly empty) snapshot for Cargo-backed
            # blocks and `nothing` for direct rustc ones.
            @test RustCall.RustBlockSnapshot("fn f() {}", "", "t", 2).cargo_env === nothing
            @test RustCall.RustBlockSnapshot("fn f() {}", "", "t", 2, "").cargo_env == ""

            # The Cargo environment is part of the library identity, so a build
            # under different flags cannot hit the cache of another one.
            id_a = RustCall._cargo_block_identity("fn f() {}", "deps", "RUSTFLAGS=-C panic=abort")
            id_b = RustCall._cargo_block_identity("fn f() {}", "deps", "RUSTFLAGS=")
            @test id_a != id_b
            @test id_a == RustCall._cargo_block_identity("fn f() {}", "deps", "RUSTFLAGS=-C panic=abort")
        end
        @test RustCall._cargo_cfg_text() == cargo_cfg   # cache keyed by environment
        lenient_host = RustCall.extract_manifest(code; mode = "crate", cfg = :lenient)
        @test Set(names(lenient_host)) == Set(expected)
        @test RustCall.expand_inline(code; cfg = :lenient).manifest != RustCall.expand_inline(code).manifest ||
              Set(names(RustCall.expand_inline(code; cfg = :lenient).manifest)) == Set(expected)
    end

    if RustCall.check_rustc_available()
        @testset "#[cfg] end to end" begin
            rust"""
            #[cfg(not(windows))]
            #[julia]
            pub fn cfg_platform_value() -> i32 { 10 }

            #[cfg(windows)]
            #[julia]
            pub fn cfg_platform_value() -> i32 { 20 }

            #[cfg(any())]
            #[julia]
            pub fn cfg_never_compiled() -> i32 { 0 }
            """
            @test cfg_platform_value() == (Sys.iswindows() ? Int32(20) : Int32(10))
            # The manifest never saw the disabled item, so no Julia wrapper exists.
            @test !isdefined(@__MODULE__, :cfg_never_compiled)

            # The macro hands its cfg snapshot *and* the compiler settings it was
            # derived from to the run-time step, so a `set_default_compiler` in
            # between cannot desynchronize wrappers and library: a block expanded
            # at opt-level 0 (debug_assertions on) is also compiled at opt-level 0.
            dbg_block = """
            #[cfg(debug_assertions)]
            #[julia]
            pub fn cfg_snapshot_debug_only() -> i32 { 11 }
            """
            o0 = RustCall.RustCompiler(optimization_level = 0)
            snapshot_o0 = RustCall._rustc_cfg_text(RustCall._cfg_rustc_flags(o0))
            @test snapshot_o0 != RustCall._cfg_snapshot(:strict)   # default is opt-level 2
            lib = RustCall._compile_and_load_rust(dbg_block, "snapshot", 0; cfg_text = snapshot_o0,
                                                  compiler_target = o0.target_triple, compiler_level = 0)
            @test RustCall.get_function_pointer(lib, "cfg_snapshot_debug_only") != C_NULL

            # The library identity includes the compiler snapshot: the same
            # source built at two opt-levels is two libraries, and the second
            # load does not alias the first. (The expanded source is identical
            # here — only the snapshot differs.)
            same_src = """
            #[no_mangle]
            pub extern "C" fn cfg_identity_is_debug() -> i32 { cfg!(debug_assertions) as i32 }
            """
            o2 = RustCall.RustCompiler(optimization_level = 2)
            snapshot_o2 = RustCall._rustc_cfg_text(RustCall._cfg_rustc_flags(o2))
            lib_o0 = RustCall._compile_and_load_rust(same_src, "identity", 0; cfg_text = snapshot_o0,
                                                     compiler_target = o0.target_triple, compiler_level = 0)
            lib_o2 = RustCall._compile_and_load_rust(same_src, "identity", 0; cfg_text = snapshot_o2,
                                                     compiler_target = o2.target_triple, compiler_level = 2)
            @test lib_o0 != lib_o2
            f0 = RustCall.get_function_pointer(lib_o0, "cfg_identity_is_debug")
            f2 = RustCall.get_function_pointer(lib_o2, "cfg_identity_is_debug")
            @test f0 != f2
            @test ccall(f0, Int32, ()) == 1
            @test ccall(f2, Int32, ()) == 0
            # A repeated load under the first snapshot is the first library.
            @test RustCall._compile_and_load_rust(same_src, "identity", 0; cfg_text = snapshot_o0,
                                                  compiler_target = o0.target_triple, compiler_level = 0) == lib_o0
            # Every part of the snapshot is in the identity: compiler settings,
            # cfg text and the rustc environment; both paths share one helper.
            @test RustCall._rustc_block_identity("x", o0, snapshot_o0) != RustCall._rustc_block_identity("x", o2, snapshot_o0)
            @test RustCall._rustc_block_identity("x", o0, snapshot_o0) != RustCall._rustc_block_identity("x", o0, snapshot_o2)
            @test RustCall._rustc_block_identity("x", o0, snapshot_o0) == RustCall._rustc_block_identity("x", o0, snapshot_o0)
            id_plain = withenv(() -> RustCall._rustc_block_identity("x", o0, snapshot_o0), "RUSTFLAGS" => nothing)
            id_flags = withenv(() -> RustCall._rustc_block_identity("x", o0, snapshot_o0), "RUSTFLAGS" => "--cfg foo")
            @test id_plain != id_flags
            @test RustCall._block_identity("x", "a" => "1") != RustCall._block_identity("x", "a" => "2")
            @test RustCall._cargo_block_identity("x", "d", "e") == RustCall._block_identity("x", "deps" => "d", "cargo-env" => "e")

            # A reload that derives another library name than the one a
            # precompiled module stored (toolchain fingerprint, compiler snapshot
            # or cfg text changed) is aliased under the stored name: the next
            # call resolves through the registry instead of reloading, and the
            # stored name looks symbols up in this library directly.
            stale_name = "rust_stale0123456789ab"
            stale_code = "#[no_mangle]\npub extern \"C\" fn stale_alias_value() -> i32 { 42 }\n"
            stale_mod = Module(:StaleLibReload)
            Core.eval(stale_mod, :(const __RUSTCALL_LIBS = Dict{String, Any}(
                $stale_name => $(RustCall.RustBlockSnapshot(stale_code, snapshot_o0, o0.target_triple, 0)))))
            Core.eval(stale_mod, :(const __RUSTCALL_ACTIVE_LIB = Ref($stale_name)))
            resolved = RustCall._resolve_lib(stale_mod, "")
            @test resolved != stale_name
            @test haskey(RustCall.RUST_LIBRARIES, resolved) && haskey(RustCall.RUST_LIBRARIES, stale_name)
            @test RustCall.RUST_LIBRARIES[stale_name] === RustCall.RUST_LIBRARIES[resolved]
            @test stale_mod.__RUSTCALL_ACTIVE_LIB[] == resolved
            # The stored key now short-circuits `ensure_loaded` (no second reload) ...
            @test RustCall.ensure_loaded(stale_name, stale_mod.__RUSTCALL_LIBS[stale_name]) == stale_name
            @test RustCall._resolve_lib(stale_mod, "") == resolved
            @test RustCall._resolve_lib(stale_mod, stale_name) == stale_name
            # ... and both names reach the symbol without the global fallback search.
            @test ccall(RustCall.get_function_pointer(stale_name, "stale_alias_value"), Int32, ()) == 42
            @test ccall(RustCall.get_function_pointer(resolved, "stale_alias_value"), Int32, ()) == 42

            # A generic whose body contains `#[cfg]`/`cfg!` is reported as such;
            # from a Cargo-backed block its lazy specialization (a direct rustc
            # build under another configuration) is refused with a clear error.
            cfg_body = """
            #[julia]
            pub fn cfg_body_generic<T: Copy>(x: T) -> T { if cfg!(panic = "unwind") { x } else { x } }
            #[julia]
            pub fn plain_generic<T: Copy>(x: T) -> T { x }
            """
            sigs = RustCall.manifest_function_signatures(RustCall.extract_manifest(cfg_body; mode = "inline"))
            @test Dict(s.name => s.body_has_cfg for s in sigs) == Dict("cfg_body_generic" => true, "plain_generic" => false)
            expanded_cfg_body = RustCall.expand_inline(cfg_body; cfg = :cargo)
            RustCall._register_manifest(expanded_cfg_body, "rust_cargo_fake_lib"; cargo_backed = true)
            @test isempty(RustCall.GENERIC_FUNCTION_REGISTRY["plain_generic"].blocked)
            @test !isempty(RustCall.GENERIC_FUNCTION_REGISTRY["cfg_body_generic"].blocked)
            @test_throws RustCall.RustError RustCall.monomorphize_function("cfg_body_generic", Dict{Symbol, Type}(:T => Int32))
            blocked_err = try
                RustCall.monomorphize_function("cfg_body_generic", Dict{Symbol, Type}(:T => Int32))
                nothing
            catch e
                e
            end
            @test blocked_err isa RustCall.RustError
            @test occursin("cfg_body_generic", blocked_err.message) && occursin("cargo-deps", blocked_err.message)
            # Direct rustc blocks are unaffected: the specialization is built by
            # the same compiler under the same cfg snapshot.
            RustCall._register_manifest(expanded_cfg_body, "rust_fake_lib"; compiler = o0)
            @test isempty(RustCall.GENERIC_FUNCTION_REGISTRY["cfg_body_generic"].blocked)
            @test RustCall.monomorphize_function("cfg_body_generic", Dict{Symbol, Type}(:T => Int32)) !== nothing

            # End to end through `@rust` on a `// cargo-deps:` block (a local
            # path dependency, so no network is needed).
            if success(pipeline(`$(RustCall.cargo()) --version`; stdout = devnull, stderr = devnull))
                mktempdir() do dep
                    mkpath(joinpath(dep, "src"))
                    write(joinpath(dep, "Cargo.toml"),
                          "[package]\nname = \"rustcall_cfg_dep\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")
                    write(joinpath(dep, "src", "lib.rs"), "pub fn one() -> i32 { 1 }\n")
                    dep_path = replace(dep, "\\" => "/")
                    block = """
                    // cargo-deps: rustcall_cfg_dep = { path = "$dep_path" }
                    #[julia]
                    pub fn cfg_dep_plain(x: i32) -> i32 { x + rustcall_cfg_dep::one() }
                    #[julia]
                    pub fn cfg_dep_generic<T: Copy>(x: T) -> T { if cfg!(panic = "unwind") { x } else { x } }
                    """
                    dep_mod = Module(:CfgDepBlock)
                    Core.eval(dep_mod, :(using RustCall))
                    Core.eval(dep_mod, Expr(:macrocall, GlobalRef(RustCall, Symbol("@rust_str")),
                                            LineNumberNode(1, :cfgdep), block))
                    @test Core.eval(dep_mod, :(cfg_dep_plain(Int32(1)))) == Int32(2)
                    @test !isempty(RustCall.GENERIC_FUNCTION_REGISTRY["cfg_dep_generic"].blocked)
                    @test_throws RustCall.RustError Core.eval(dep_mod, :(RustCall.@rust cfg_dep_generic(Int32(3))))
                end
            end

            @test RustCall._snapshot_compiler(nothing, nothing) === RustCall.get_default_compiler()
            @test RustCall._snapshot_compiler(o0.target_triple, 0).optimization_level == 0
            # Precompiled modules store the snapshot; a reload rebuilds under it.
            block = RustCall.RustBlockSnapshot(dbg_block, snapshot_o0, o0.target_triple, 0)
            reloaded = RustCall.ensure_loaded("rustcall_no_such_lib_265", block)
            @test RustCall.get_function_pointer(reloaded, "cfg_snapshot_debug_only") != C_NULL
            @test RustCall.ensure_loaded(reloaded, block) == reloaded
            @test (@__MODULE__).__RUSTCALL_LIBS isa Dict{String, Any}
            @test all(v -> v isa RustCall.RustBlockSnapshot, values((@__MODULE__).__RUSTCALL_LIBS))
            @test all(v -> v.cargo_env === nothing, values((@__MODULE__).__RUSTCALL_LIBS))   # direct rustc blocks

            # Generic functions keep the compiler they were expanded for: the
            # lazy specialization below runs while the default compiler is at
            # opt-level 2, but the block was expanded (and is compiled) at 0.
            RustCall.set_default_compiler(RustCall.RustCompiler(optimization_level = 2))
            generic_block = """
            #[cfg(debug_assertions)]
            #[julia]
            pub fn cfg_snapshot_generic_id<T: Copy>(x: T) -> T { x }
            """
            RustCall._compile_and_load_rust(generic_block, "snapshot", 0; cfg_text = snapshot_o0,
                                            compiler_target = o0.target_triple, compiler_level = 0)
            info = RustCall.GENERIC_FUNCTION_REGISTRY["cfg_snapshot_generic_id"]
            @test info.compiler !== nothing && info.compiler.optimization_level == 0
            @test RustCall.get_default_compiler().optimization_level == 2
            spec = RustCall.monomorphize_function("cfg_snapshot_generic_id", Dict(:T => Int32))
            @test spec !== nothing
        end
    end

    @testset "manifest is identical on cache hit and miss" begin
        code = """
        #[julia]
        fn manifest_twice(a: i32) -> i32 { a + 1 }
        """
        first_run = RustCall.extract_manifest(code; mode = "inline")
        second_run = RustCall.extract_manifest(code; mode = "inline")
        @test first_run == second_run
        # expand_inline memoizes per source text
        @test RustCall.expand_inline(code).manifest == first_run
    end

    @testset "failed extraction leaves nothing behind" begin
        bad = "#[julia] fn broken(a: i32 -> i32 { a }"
        @test_throws RustCall.ExtractorError RustCall.expand_inline(bad)
        @test !haskey(RustCall._EXPANSION_CACHE, bad)
        @test_throws RustCall.ExtractorError RustCall.extract_manifest(bad; mode = "crate")
        # a later, valid block is unaffected
        good = "#[julia] fn fine(a: i32) -> i32 { a }"
        @test length(RustCall.manifest_function_signatures(RustCall.expand_inline(good).manifest)) == 1
    end

    @testset "Cargo block identity includes the dependency set" begin
        src = "#[no_mangle] pub extern \"C\" fn dep_probe() -> i32 { 1 }"
        d1 = RustCall.hash_dependencies([RustCall.DependencySpec("rand", version = "0.8")])
        d2 = RustCall.hash_dependencies([RustCall.DependencySpec("rand", version = "0.9")])
        d3 = RustCall.hash_dependencies([RustCall.DependencySpec("rand", version = "0.8", features = ["small_rng"])])
        @test RustCall._cargo_block_identity(src, d1) == RustCall._cargo_block_identity(src, d1)
        @test RustCall._cargo_block_identity(src, d1) != RustCall._cargo_block_identity(src, d2)
        @test RustCall._cargo_block_identity(src, d1) != RustCall._cargo_block_identity(src, d3)
    end

    @testset "cache keys include the toolchain fingerprint" begin
        compiler = RustCall.get_default_compiler()
        code = "#[no_mangle] pub extern \"C\" fn fp_probe() -> i32 { 1 }"
        key_before = RustCall.generate_cache_key(code, compiler)
        saved = RustCall._TOOLCHAIN_FINGERPRINT[]
        try
            RustCall._TOOLCHAIN_FINGERPRINT[] = "0"^64
            key_after = RustCall.generate_cache_key(code, compiler)
            @test key_after != key_before
        finally
            RustCall._TOOLCHAIN_FINGERPRINT[] = saved
        end
        @test RustCall.generate_cache_key(code, compiler) == key_before
    end

    @testset "direct rustc fast path for plain extern \"C\" blocks" begin
        # Blocks without #[julia] still compile through rustc directly; the
        # expanded source is the original items (no wrappers injected).
        code = """
        #[no_mangle]
        pub extern "C" fn fast_path_add(a: i32, b: i32) -> i32 { a + b }
        """
        expanded = RustCall.expand_inline(code)
        @test occursin("fast_path_add", expanded.source)
        @test !occursin("CResult", expanded.source)
        sigs = RustCall.manifest_function_signatures(expanded.manifest; only_attributed = false)
        @test length(sigs) == 1 && sigs[1].attribute == :none && sigs[1].exported
        rust"""
        #[no_mangle]
        pub extern "C" fn fast_path_add(a: i32, b: i32) -> i32 { a + b }
        """
        @test (@rust fast_path_add(Int32(2), Int32(3))) == 5
    end

    @testset "Result / Option through inline #[julia] functions" begin
        rust"""
        #[julia]
        fn manifest_div(a: f64, b: f64) -> Result<f64, i32> {
            if b == 0.0 { Err(-1) } else { Ok(a / b) }
        }

        #[julia]
        fn manifest_maybe(a: i32) -> Option<i32> {
            if a > 0 { Some(a) } else { None }
        }
        """
        ok = manifest_div(1.0, 4.0)
        @test ok isa RustCall.RustResult{Float64, Int32}
        @test RustCall.is_ok(ok) && RustCall.unwrap(ok) == 0.25
        err = manifest_div(1.0, 0.0)
        @test RustCall.is_err(err) && err.value == -1
        some = manifest_maybe(3)
        @test some isa RustCall.RustOption{Int32}
        @test RustCall.is_some(some) && RustCall.unwrap(some) == 3
        @test RustCall.is_none(manifest_maybe(-1))
    end

    @testset "#[julia] items inside inline modules" begin
        rust"""
        mod api {
            #[julia]
            pub fn mod_add(a: i32, b: i32) -> i32 { a + b }

            #[julia]
            pub struct ModPoint { x: f64 }

            impl ModPoint {
                pub fn new(x: f64) -> Self { Self { x } }
                pub fn get_x(&self) -> f64 { self.x }
            }
        }
        """
        @test mod_add(Int32(2), Int32(3)) == 5
        p = ModPoint(1.5)
        @test p.x == 1.5
        @test get_x(p) == 1.5

        # Generic items inside a module are specialized in place, so sibling
        # items and `use` imports stay in scope during monomorphization.
        rust"""
        mod gen {
            use std::ops::Add;
            fn offset() -> i32 { 100 }
            pub fn mod_twice<T: Add<Output = T> + Copy>(x: T) -> T { x + x }
            fn uses_twice() -> i32 { mod_twice(2) }
            pub fn mod_offset<T: Into<i32>>(x: T) -> i32 { let v: i32 = x.into(); v + offset() }

            #[julia]
            pub struct Cell<T> { value: T }
            impl<T: Copy> Cell<T> {
                pub fn new(value: T) -> Self { Self { value } }
                pub fn get(&self) -> T { self.value }
            }
        }
        """
        @test (@rust mod_twice(Int32(21))) == 42
        @test (@rust mod_offset(Int32(5))) == 105
        c = Cell{Int64}(Int64(9))
        @test get(c) == 9

        # impl block renaming the struct parameter (impl<U> Holder<U>)
        rust"""
        #[julia]
        pub struct Holder<T> { value: T }
        impl<U: Copy> Holder<U> {
            pub fn new(value: U) -> Self { Self { value } }
            pub fn value(&self) -> U { self.value }
        }
        """
        h = Holder{Int32}(Int32(11))
        @test value(h) == 11
        @test h.value == 11
    end

    @testset "syntax that broke the old parsers (#169, #177/#201, #184, #233)" begin
        rust"""
        // #177 / #201: nested block comments inside a function body
        #[julia]
        fn nested_comment_fn(a: i32) -> i32 {
            /* outer /* inner */ } still a comment */
            let s = r#"{ not a brace "#;
            let _ = s;
            a * 2
        }

        // #233: const expression containing `<` in a type
        #[julia]
        fn const_expr_len(x: [u8; { if 1 < 2 { 3 } else { 4 } }]) -> i32 {
            x.len() as i32
        }

        // #169 / #184: where clause and nested generics on a #[julia] struct
        #[julia]
        pub struct Bag<T> where T: Copy {
            items: Vec<Option<T>>,
            first: T,
        }

        impl<T> Bag<T> where T: Copy {
            pub fn new(first: T) -> Self { Self { items: Vec::new(), first } }
            pub fn first(&self) -> T { self.first }
        }
        """
        @test nested_comment_fn(Int32(21)) == 42
        infos = RustCall.manifest_struct_infos(RustCall.expand_inline("""
        #[julia]
        pub struct Bag<T> where T: Copy { items: Vec<Option<T>>, first: T }
        impl<T> Bag<T> where T: Copy {
            pub fn new(first: T) -> Self { Self { items: Vec::new(), first } }
            pub fn first(&self) -> T { self.first }
        }
        """).manifest)
        @test only(infos).fields == [("items", "Vec<Option<T>>"), ("first", "T")]
        @test only(infos).constraints[:T].bounds[1].trait_name == "Copy"
        b = Bag{Int32}(Int32(5))
        @test first(b) == 5
    end
end
