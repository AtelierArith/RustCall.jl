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
        @test RustCall.artifact_dependency_strings(["b", "a"]) == ["a", "b"]

        # The dependency set reaches the key.
        with_deps = _id(kind = "cargo", source = "fn f() {}", dependencies = canon)
        without = _id(kind = "cargo", source = "fn f() {}")
        @test RustCall.artifact_key(with_deps) != RustCall.artifact_key(without)
    end

    @testset "Build environment snapshot" begin
        env0 = Dict("RUSTFLAGS" => "")
        env1 = Dict("RUSTFLAGS" => "-C target-cpu=native")
        snap0 = RustCall.artifact_build_env(["RUSTFLAGS", "CARGO_TARGET_DIR"]; env = env0)
        snap1 = RustCall.artifact_build_env(["RUSTFLAGS", "CARGO_TARGET_DIR"]; env = env1)

        # Absent variables are recorded, not dropped.
        @test first.(snap0) == ["CARGO_TARGET_DIR", "RUSTFLAGS"]
        @test snap0 != snap1
        @test RustCall.artifact_key(_id(kind = "cargo", build_env = snap0)) !=
              RustCall.artifact_key(_id(kind = "cargo", build_env = snap1))

        # The default list is non-empty and covers what the recent Cargo fixes added.
        @test "RUSTFLAGS" in RustCall.ARTIFACT_BUILD_ENV_VARS
        @test "CARGO_ENCODED_RUSTFLAGS" in RustCall.ARTIFACT_BUILD_ENV_VARS
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
