# Tests for the single artifact-identity function (issue #278, Phase A).
#
# Two kinds of tests live here:
#
# 1. Tests of the new `ArtifactId` / `artifact_key` machinery: injectivity,
#    order sensitivity of type parameters, toolchain sensitivity.
# 2. Tests that *document the current defects* of the eight ad-hoc cache-key
#    sites. Those assert today's (wrong) behaviour on purpose, with the issue
#    number in a comment, so that Phase B — which migrates the call sites onto
#    `artifact_key` — turns them into regression tests by flipping the
#    assertion. Nothing here changes existing behaviour.

using RustCall
using SHA: sha256
using Test

# A toolchain/compiler pair that does not require the extractor or a Rust
# toolchain to be present, so the pure-encoding tests always run.
const _FAKE_TOOLCHAIN = "toolchain-fingerprint-aaaa"
const _FAKE_COMPILER = "rustc=rustc 1.90.0 (deadbeef 2026-01-01)\ncargo=cargo 1.90.0"

_id(; kwargs...) = RustCall.ArtifactId(;
    toolchain = _FAKE_TOOLCHAIN, compiler = _FAKE_COMPILER, kwargs...)

@testset "Artifact identity (#278)" begin

    @testset "Key shape and determinism" begin
        id = _id(kind = "rustc", source = "fn f() {}")
        key = RustCall.artifact_key(id)

        @test length(key) == 64
        @test all(c -> c in "0123456789abcdef", key)
        # Deterministic across calls and across equal records.
        @test key == RustCall.artifact_key(id)
        @test key == RustCall.artifact_key(_id(kind = "rustc", source = "fn f() {}"))
        @test id == _id(kind = "rustc", source = "fn f() {}")
    end

    @testset "Encoding is injective (no concatenation collisions)" begin
        # The classic failure of naive concatenation: "a" * "bc" == "ab" * "c".
        # Netstring framing makes it impossible.
        a = _id(kind = "a", source = "bc")
        b = _id(kind = "ab", source = "c")
        @test RustCall.artifact_encoding(a) != RustCall.artifact_encoding(b)
        @test RustCall.artifact_key(a) != RustCall.artifact_key(b)

        # Separator smuggling: a payload containing the framing characters must
        # not be able to imitate a field boundary.
        c = _id(kind = "x", source = "3:abc,")
        d = _id(kind = "x3:abc,", source = "")
        @test RustCall.artifact_key(c) != RustCall.artifact_key(d)

        # Empty vs missing must differ where it matters, and list boundaries
        # must be unambiguous.
        e = _id(kind = "k", cfg = ["ab", "c"])
        f = _id(kind = "k", cfg = ["a", "bc"])
        g = _id(kind = "k", cfg = ["abc"])
        @test length(unique([RustCall.artifact_key(x) for x in (e, f, g)])) == 3
    end

    @testset "Every field participates in the key" begin
        # Property-style: changing any single field changes the key.
        base = _id(
            kind = "rustc",
            source = "fn f() {}",
            type_params = ["T" => "i32"],
            target_triple = "x86_64-unknown-linux-gnu",
            codegen = ["opt_level" => "2"],
            cfg = ["feature=\"std\""],
            dependencies = ["name=serde version=1.0"],
            features = ["derive"],
            build_env = ["RUSTFLAGS" => ""],
            extra = ["profile" => "release"],
        )
        base_key = RustCall.artifact_key(base)

        mutations = [
            "kind" => _id(kind = "cargo", source = base.source, type_params = base.type_params,
                target_triple = base.target_triple, codegen = base.codegen, cfg = base.cfg,
                dependencies = base.dependencies, features = base.features,
                build_env = base.build_env, extra = base.extra),
            "source" => _id(kind = base.kind, source = "fn g() {}", type_params = base.type_params,
                target_triple = base.target_triple, codegen = base.codegen, cfg = base.cfg,
                dependencies = base.dependencies, features = base.features,
                build_env = base.build_env, extra = base.extra),
            "type_params" => _id(kind = base.kind, source = base.source, type_params = ["T" => "i64"],
                target_triple = base.target_triple, codegen = base.codegen, cfg = base.cfg,
                dependencies = base.dependencies, features = base.features,
                build_env = base.build_env, extra = base.extra),
            "target_triple" => _id(kind = base.kind, source = base.source, type_params = base.type_params,
                target_triple = "aarch64-apple-darwin", codegen = base.codegen, cfg = base.cfg,
                dependencies = base.dependencies, features = base.features,
                build_env = base.build_env, extra = base.extra),
            "codegen" => _id(kind = base.kind, source = base.source, type_params = base.type_params,
                target_triple = base.target_triple, codegen = ["opt_level" => "3"], cfg = base.cfg,
                dependencies = base.dependencies, features = base.features,
                build_env = base.build_env, extra = base.extra),
            "cfg" => _id(kind = base.kind, source = base.source, type_params = base.type_params,
                target_triple = base.target_triple, codegen = base.codegen, cfg = String[],
                dependencies = base.dependencies, features = base.features,
                build_env = base.build_env, extra = base.extra),
            "dependencies" => _id(kind = base.kind, source = base.source, type_params = base.type_params,
                target_triple = base.target_triple, codegen = base.codegen, cfg = base.cfg,
                dependencies = ["name=serde version=1.1"], features = base.features,
                build_env = base.build_env, extra = base.extra),
            "features" => _id(kind = base.kind, source = base.source, type_params = base.type_params,
                target_triple = base.target_triple, codegen = base.codegen, cfg = base.cfg,
                dependencies = base.dependencies, features = String[],
                build_env = base.build_env, extra = base.extra),
            "build_env" => _id(kind = base.kind, source = base.source, type_params = base.type_params,
                target_triple = base.target_triple, codegen = base.codegen, cfg = base.cfg,
                dependencies = base.dependencies, features = base.features,
                build_env = ["RUSTFLAGS" => "-C target-cpu=native"], extra = base.extra),
            "extra" => _id(kind = base.kind, source = base.source, type_params = base.type_params,
                target_triple = base.target_triple, codegen = base.codegen, cfg = base.cfg,
                dependencies = base.dependencies, features = base.features,
                build_env = base.build_env, extra = ["profile" => "debug"]),
            "toolchain" => RustCall.ArtifactId(kind = base.kind, source = base.source,
                type_params = base.type_params, target_triple = base.target_triple,
                codegen = base.codegen, cfg = base.cfg, dependencies = base.dependencies,
                features = base.features, build_env = base.build_env, extra = base.extra,
                toolchain = "toolchain-fingerprint-bbbb", compiler = _FAKE_COMPILER),
            "compiler" => RustCall.ArtifactId(kind = base.kind, source = base.source,
                type_params = base.type_params, target_triple = base.target_triple,
                codegen = base.codegen, cfg = base.cfg, dependencies = base.dependencies,
                features = base.features, build_env = base.build_env, extra = base.extra,
                toolchain = _FAKE_TOOLCHAIN, compiler = "rustc=rustc 1.91.0\ncargo=cargo 1.91.0"),
        ]

        for (field, mutated) in mutations
            @test RustCall.artifact_key(mutated) != base_key
        end
        # All twelve mutations are distinct from each other too.
        @test length(unique([RustCall.artifact_key(m) for (_, m) in mutations])) == length(mutations)
    end

    @testset "Type parameters are order preserving (#247)" begin
        forward = _id(kind = "monomorphization", source = "pub fn pair<T, U>()",
            type_params = ["T" => "Int32", "U" => "Int64"])
        reversed = _id(kind = "monomorphization", source = "pub fn pair<T, U>()",
            type_params = ["T" => "Int64", "U" => "Int32"])
        @test RustCall.artifact_key(forward) != RustCall.artifact_key(reversed)

        # And the name a parameter carries matters, not just the multiset of types.
        renamed = _id(kind = "monomorphization", source = "pub fn pair<T, U>()",
            type_params = ["U" => "Int32", "T" => "Int64"])
        @test RustCall.artifact_key(renamed) != RustCall.artifact_key(forward)

        # artifact_type_params keeps declaration order regardless of Dict order.
        bindings = Dict{Symbol, Type}(:U => Int64, :T => Int32)
        @test RustCall.artifact_type_params([:T, :U], bindings) == ["T" => "Int32", "U" => "Int64"]
        @test RustCall.artifact_type_params([:U, :T], bindings) == ["U" => "Int64", "T" => "Int32"]
        @test RustCall.artifact_type_params([:T, :U], bindings) !=
              RustCall.artifact_type_params([:U, :T], bindings)
        @test_throws ArgumentError RustCall.artifact_type_params([:T, :V], bindings)

        # Positional form.
        @test RustCall.artifact_type_params(["T", "U"], [Int32, Int64]) ==
              ["T" => "Int32", "U" => "Int64"]
        @test_throws ArgumentError RustCall.artifact_type_params(["T"], [Int32, Int64])
    end

    @testset "Truncation happens in exactly one place" begin
        id = _id(kind = "rustc", source = "fn f() {}")
        key = RustCall.artifact_key(id)

        @test RustCall.artifact_short_id(id) == key[1:RustCall.ARTIFACT_SHORT_ID_LEN]
        @test RustCall.artifact_short_id(key) == RustCall.artifact_short_id(id)
        @test RustCall.artifact_short_id(id, 12) == key[1:12]
        @test length(RustCall.artifact_short_id(id)) == RustCall.ARTIFACT_SHORT_ID_LEN
        @test_throws ArgumentError RustCall.artifact_short_id(id, 0)
        @test_throws ArgumentError RustCall.artifact_short_id(id, 65)
    end

    @testset "Dependency canonicalization" begin
        d1 = RustCall.DependencySpec("serde", "1.0", ["derive"])
        d2 = RustCall.DependencySpec("rand", "0.8")
        canon = RustCall.artifact_dependency_strings([d1, d2])
        @test length(canon) == 2
        @test issorted(canon)                        # order of the input is irrelevant
        @test canon == RustCall.artifact_dependency_strings([d2, d1])

        # Distinct specs never collapse onto one string.
        @test RustCall.artifact_dependency_strings([RustCall.DependencySpec("serde", "1.0")]) !=
              RustCall.artifact_dependency_strings([RustCall.DependencySpec("serde", "1.1")])
        @test RustCall.artifact_dependency_strings([RustCall.DependencySpec("serde", "1.0", ["derive"])]) !=
              RustCall.artifact_dependency_strings([RustCall.DependencySpec("serde", "1.0")])

        # Plain strings pass through, so the helper is usable anywhere.
        raws = RustCall.artifact_dependency_strings(["b", "a"])
        @test length(raws) == 2 && issorted(raws) && allunique(raws)

        # The dependency set reaches the key.
        with_deps = _id(kind = "cargo", source = "fn f() {}", dependencies = canon)
        without = _id(kind = "cargo", source = "fn f() {}")
        @test RustCall.artifact_key(with_deps) != RustCall.artifact_key(without)
    end

    @testset "Local path dependencies are identified by content" begin
        # Review finding (3): a `path = "..."` dependency identified by its path
        # text alone means editing its sources leaves the key unchanged.
        function make_crate(dir, body; name = "helper", extra_manifest = "")
            mkpath(joinpath(dir, "src"))
            write(joinpath(dir, "Cargo.toml"),
                "[package]\nname = \"$(name)\"\nversion = \"0.1.0\"\n$(extra_manifest)")
            write(joinpath(dir, "src", "lib.rs"), body)
            return dir
        end

        a = make_crate(mktempdir(), "pub fn f() -> i32 { 1 }")
        b = make_crate(mktempdir(), "pub fn f() -> i32 { 2 }")   # one byte differs
        c = make_crate(mktempdir(), "pub fn f() -> i32 { 1 }")   # same content, other dir

        try
            dig_a = RustCall.artifact_path_dependency_digest(a)
            dig_b = RustCall.artifact_path_dependency_digest(b)
            dig_c = RustCall.artifact_path_dependency_digest(c)

            @test dig_a != dig_b                       # editing sources changes the digest
            @test dig_a == dig_c                       # location is NOT part of identity
            @test dig_a == RustCall.artifact_path_dependency_digest(a)  # deterministic

            # Files added under src/ count, and target/ artifacts are ignored.
            write(joinpath(a, "src", "extra.rs"), "pub fn g() {}")
            @test RustCall.artifact_path_dependency_digest(a) != dig_a
            dig_a2 = RustCall.artifact_path_dependency_digest(a)
            mkpath(joinpath(a, "target", "release"))
            write(joinpath(a, "target", "release", "junk"), "noise")
            @test RustCall.artifact_path_dependency_digest(a) == dig_a2

            # The digest reaches the dependency string, and hence the key.
            spec_a = RustCall.DependencySpec("helper", nothing, String[], nothing, a)
            spec_b = RustCall.DependencySpec("helper", nothing, String[], nothing, b)
            spec_c = RustCall.DependencySpec("helper", nothing, String[], nothing, c)
            key(spec) = RustCall.artifact_key(_id(kind = "cargo",
                dependencies = RustCall.artifact_dependency_strings([spec])))
            @test key(spec_a) != key(spec_b)
            @test key(spec_b) != key(spec_c)
            @test RustCall.artifact_dependency_strings([spec_a]) !=
                  RustCall.artifact_dependency_strings([spec_b])

            # A nested path dependency is followed.
            nested_parent = mktempdir()
            child = make_crate(joinpath(nested_parent, "child"), "pub fn h() {}"; name = "child")
            parent = make_crate(nested_parent, "pub fn p() {}";
                name = "parent",
                extra_manifest = "\n[dependencies]\nchild = { path = \"child\" }\n")
            dig_parent = RustCall.artifact_path_dependency_digest(parent)
            write(joinpath(child, "src", "lib.rs"), "pub fn h() -> i32 { 7 }")
            @test RustCall.artifact_path_dependency_digest(parent) != dig_parent

            # A missing crate is recorded, not silently ignored, and never throws.
            missing_dig = RustCall.artifact_path_dependency_digest(joinpath(a, "nope"))
            @test length(missing_dig) == 64
            @test missing_dig != dig_a
        finally
            for d in (a, b, c)
                rm(d; force = true, recursive = true)
            end
        end
    end

    @testset "Build environment: presence and prefix capture" begin
        # Review finding (1): unset and empty must not collide. Cargo treats an
        # empty RUSTFLAGS as "suppress inherited rustflags", not as "unset".
        unset = Dict{String, String}()
        empty_val = Dict("RUSTFLAGS" => "")
        set_val = Dict("RUSTFLAGS" => "-C target-cpu=native")

        snap_unset = RustCall.artifact_build_env(["RUSTFLAGS"]; env = unset)
        snap_empty = RustCall.artifact_build_env(["RUSTFLAGS"]; env = empty_val)
        snap_set = RustCall.artifact_build_env(["RUSTFLAGS"]; env = set_val)

        @test snap_unset[1] == ("RUSTFLAGS" => RustCall.ARTIFACT_ENV_ABSENT)
        @test snap_empty[1] == ("RUSTFLAGS" => "present:")
        @test snap_unset != snap_empty
        keys3 = [RustCall.artifact_key(_id(kind = "cargo", build_env = s))
                 for s in (snap_unset, snap_empty, snap_set)]
        @test length(unique(keys3)) == 3

        # A value that literally reads "absent" cannot imitate the absent marker.
        literal = RustCall.artifact_build_env(["RUSTFLAGS"]; env = Dict("RUSTFLAGS" => "absent"))
        @test literal != snap_unset

        # Review finding (2): profile overrides are tracked by prefix, not by an
        # enumeration that has to be patched for every new key.
        for n in ("CARGO_PROFILE_RELEASE_OPT_LEVEL", "CARGO_PROFILE_RELEASE_CODEGEN_UNITS",
                  "CARGO_PROFILE_RELEASE_PANIC", "CARGO_PROFILE_RELEASE_DEBUG",
                  "CARGO_PROFILE_RELEASE_STRIP", "CARGO_PROFILE_RELEASE_LTO",
                  "CARGO_PROFILE_DEV_OPT_LEVEL", "CARGO_BUILD_RUSTFLAGS",
                  "CARGO_BUILD_TARGET", "CARGO_CFG_TARGET_FEATURE",
                  "CARGO_ENCODED_RUSTFLAGS", "RUSTFLAGS", "RUSTC", "RUSTC_WRAPPER",
                  "RUSTDOCFLAGS", "RUSTUP_TOOLCHAIN",
                  "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS",
                  "CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER")
            @test RustCall.artifact_build_env_captured(n)
        end

        # Not build-affecting: output location and unrelated variables.
        for n in ("CARGO_TARGET_DIR", "PATH", "HOME", "JULIA_DEPOT_PATH", "CARGO_HOME")
            @test !RustCall.artifact_build_env_captured(n)
        end

        # HARD SECURITY REQUIREMENT: credentials are rejected before the
        # allowlist is consulted and can never enter a key.
        for n in ("CARGO_REGISTRY_TOKEN", "CARGO_REGISTRIES_MYREG_TOKEN",
                  "CARGO_REGISTRIES_X_TOKEN", "CARGO_BUILD_SECRET",
                  "CARGO_PROFILE_RELEASE_AUTH", "RUSTFLAGS_TOKEN",
                  "AWS_SECRET_ACCESS_KEY", "MY_PASSWORD", "GH_CREDENTIALS",
                  "cargo_registry_token")
            @test !RustCall.artifact_build_env_captured(n)
        end
        secret_env = Dict(
            "CARGO_REGISTRY_TOKEN" => "s3cret",
            "CARGO_REGISTRIES_X_TOKEN" => "s3cret2",
            "RUSTFLAGS" => "-C opt-level=3",
        )
        captured = RustCall.artifact_build_env(; env = secret_env)
        @test first.(captured) == ["RUSTFLAGS"]
        @test !any(p -> occursin("s3cret", last(p)), captured)
        # Even when named explicitly, a credential is skipped.
        @test isempty(RustCall.artifact_build_env(["CARGO_REGISTRY_TOKEN"]; env = secret_env))

        # Scanning the environment is sorted and deterministic.
        scan_env = Dict("RUSTFLAGS" => "a", "CARGO_BUILD_TARGET" => "b",
                        "CARGO_PROFILE_RELEASE_OPT_LEVEL" => "z", "PATH" => "/bin")
        scanned = RustCall.artifact_build_env(; env = scan_env)
        @test first.(scanned) ==
              ["CARGO_BUILD_TARGET", "CARGO_PROFILE_RELEASE_OPT_LEVEL", "RUSTFLAGS"]
        @test scanned == RustCall.artifact_build_env(; env = scan_env)

        # Changing any captured variable changes the key.
        base_env = Dict("RUSTFLAGS" => "-C opt-level=2")
        mutated_env = Dict("RUSTFLAGS" => "-C opt-level=2",
                           "CARGO_PROFILE_RELEASE_CODEGEN_UNITS" => "1")
        @test RustCall.artifact_key(_id(kind = "cargo",
                  build_env = RustCall.artifact_build_env(; env = base_env))) !=
              RustCall.artifact_key(_id(kind = "cargo",
                  build_env = RustCall.artifact_build_env(; env = mutated_env)))
    end

    @testset "Codegen options come from the compiler config" begin
        compiler = RustCall.get_default_compiler()
        opts = RustCall.artifact_codegen_options(compiler)
        @test first.(opts) == ["opt_level", "debug_info"]
        @test opts[1][2] == string(compiler.optimization_level)
    end

    # ------------------------------------------------------------------
    # Defect documentation: these assert the CURRENT behaviour of the
    # existing key sites. Phase B flips them into regression tests.
    # ------------------------------------------------------------------

    @testset "DEFECT #247: monomorphization key loses parameter order" begin
        # Verbatim reproduction of src/generics.jl:191-193 as of this commit:
        #
        #     sorted_types = sort(collect(values(type_params)), by=string)
        #     type_params_tuple = tuple(sorted_types...)
        #     cache_key = (func_name, type_params_tuple)
        #
        # Sorting the *values* discards which parameter got which type, so
        # pair<T=i32, U=i64> and pair<T=i64, U=i32> share one cache entry and
        # the second call runs the first one's machine code (#247).
        current_key(func_name, type_params) = begin
            sorted_types = sort(collect(values(type_params)), by = string)
            (func_name, tuple(sorted_types...))
        end

        a = Dict{Symbol, Type}(:T => Int32, :U => Int64)
        b = Dict{Symbol, Type}(:T => Int64, :U => Int32)

        # Current behaviour: COLLISION. This @test is expected to fail (and to
        # be inverted) once Phase B migrates monomorphize_function.
        @test current_key("pair", a) == current_key("pair", b)

        # The same is true of the symbol suffix built at src/generics.jl:208-224
        # from the same sorted values, so the two instantiations also want the
        # same monomorphized symbol name.
        suffix(tp) = join([string(t) for t in sort(collect(values(tp)), by = string)], "_")
        @test suffix(a) == suffix(b)

        # The replacement does not collide.
        key_a = RustCall.artifact_key(_id(kind = "monomorphization", source = "pair",
            type_params = RustCall.artifact_type_params([:T, :U], a)))
        key_b = RustCall.artifact_key(_id(kind = "monomorphization", source = "pair",
            type_params = RustCall.artifact_type_params([:T, :U], b)))
        @test key_a != key_b
    end

    @testset "DEFECT #252: the rustc in the key is not the rustc that compiles" begin
        # src/cache.jl:97-106 shells out to a bare `rustc` from PATH and returns
        # "unknown" when that fails, while compilation goes through
        # RustToolChain.rustc() (src/compiler.jl:212). A key built from the
        # former therefore need not change when the real toolchain changes.

        # Warm the memoized values before touching PATH, so this test only
        # observes the divergence and does not perturb anything.
        toolchain_ok = try
            RustCall.artifact_compiler_identity()
            true
        catch
            false
        end

        if !toolchain_ok
            @info "Skipping #252 divergence test: RustToolChain rustc/cargo unavailable"
        else
            identity_str = RustCall.artifact_compiler_identity()
            @test occursin("rustc=", identity_str)
            @test occursin("cargo=", identity_str)
            # Never the "unknown" sentinel: an unidentifiable compiler is an error.
            @test !occursin("rustc=unknown", identity_str)

            saved = RustCall._cached_rustc_version[]
            empty_dir = mktempdir()
            try
                # With no `rustc` on PATH, the cache-key version degrades to
                # "unknown" while the compiler that would actually run is
                # unchanged — that is exactly the divergence of #252.
                RustCall._cached_rustc_version[] = ""
                path_version = withenv("PATH" => empty_dir) do
                    RustCall._get_rustc_version()
                end
                @test path_version == "unknown"                       # #252, current behaviour
                @test !occursin(path_version, RustCall.artifact_compiler_identity())
            finally
                RustCall._cached_rustc_version[] = saved
                rm(empty_dir; force = true, recursive = true)
            end
        end
    end

    @testset "DEFECT: existing key sites truncate inconsistently" begin
        # Inventory of the truncation lengths currently in use (issue #278).
        # The new function truncates in one place only, and never for lookup.
        code = "fn f() -> i32 { 1 }"

        @test length(RustCall.stable_content_hash(code)[1:16]) == 16   # src/ruststr.jl:227
        @test length(bytes2hex(sha256("$(code)_deps_release"))[1:32]) == 32  # src/ruststr.jl:381

        # artifact_key is full length; only artifact_short_id truncates.
        @test length(RustCall.artifact_key(_id(kind = "rustc", source = code))) == 64
    end

    @testset "toolchain_fingerprint() is folded in by default" begin
        # Requires the extractor binary; skip gracefully when absent.
        fp = try
            RustCall.toolchain_fingerprint()
        catch
            nothing
        end
        if fp === nothing
            @info "Skipping toolchain_fingerprint test: rustcall-extract unavailable"
        else
            id = RustCall.ArtifactId(kind = "rustc", source = "fn f() {}",
                compiler = _FAKE_COMPILER)
            @test id.toolchain == fp
            other = RustCall.ArtifactId(kind = "rustc", source = "fn f() {}",
                compiler = _FAKE_COMPILER, toolchain = "different")
            @test RustCall.artifact_key(id) != RustCall.artifact_key(other)
        end
    end
end
