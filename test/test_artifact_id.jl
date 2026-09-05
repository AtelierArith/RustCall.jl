# Tests for the single artifact-identity function (issue #278).
#
# Two kinds of tests live here:
#
# 1. Tests of the `ArtifactId` / `artifact_key` machinery: injectivity, order
#    sensitivity of type parameters, toolchain sensitivity, memoization.
# 2. Regression tests for the defects the twelve ad-hoc key formulas caused.
#    In Phase A these asserted the *wrong* behaviour on purpose, marked
#    `DEFECT #<issue>`; Phase B migrated the call sites and flipped them, so
#    they are named `FIXED #<issue>` and assert the property instead.

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

    @testset "Path dependency inputs come from Cargo, not from a layout guess" begin
        # Review finding (1): hashing only Cargo.toml + src/ misses build.rs, a
        # [lib]/[[bin]] path outside src/, #[path] modules and Cargo.lock.
        function crate_with(dir; manifest_extra = "", files = Dict{String, String}())
            mkpath(dir)
            write(joinpath(dir, "Cargo.toml"),
                "[package]\nname = \"probe\"\nversion = \"0.1.0\"\nedition = \"2021\"\n$(manifest_extra)")
            for (rel, body) in files
                mkpath(dirname(joinpath(dir, rel)))
                write(joinpath(dir, rel), body)
            end
            return dir
        end

        # (a) build.rs is an input.
        bs = crate_with(mktempdir();
            manifest_extra = "\n[lib]\npath = \"src/lib.rs\"\n",
            files = Dict("src/lib.rs" => "pub fn f() {}",
                         "build.rs" => "fn main() { println!(\"cargo:rustc-cfg=x\"); }"))
        # (b) a [lib] path outside src/.
        outside = crate_with(mktempdir();
            manifest_extra = "\n[lib]\npath = \"lib/entry.rs\"\n",
            files = Dict("lib/entry.rs" => "pub fn f() -> i32 { 1 }"))

        try
            dig_bs = RustCall.artifact_path_dependency_digest(bs)
            write(joinpath(bs, "build.rs"), "fn main() { println!(\"cargo:rustc-cfg=y\"); }")
            @test RustCall.artifact_path_dependency_digest(bs) != dig_bs   # build.rs counts

            dig_out = RustCall.artifact_path_dependency_digest(outside)
            write(joinpath(outside, "lib", "entry.rs"), "pub fn f() -> i32 { 2 }")
            @test RustCall.artifact_path_dependency_digest(outside) != dig_out  # outside src/

            # Cargo.lock is an input like any other file. Asserted through the
            # pure helpers: `artifact_path_dependency_digest` may ask Cargo to
            # resolve, and Cargo rewrites the lockfile when it does.
            write(joinpath(outside, "Cargo.lock"), "version = 3\n")
            strategy_lock, files_lock = RustCall.crate_input_files(outside)
            @test strategy_lock == "walk"
            @test "Cargo.lock" in files_lock
            lock_dig = RustCall.crate_content_digest(outside)
            write(joinpath(outside, "Cargo.lock"), "version = 4\n")
            @test RustCall.crate_content_digest(outside) != lock_dig

            # The walk is the only file strategy, and it sees everything under
            # the package directory — including files `cargo package --list`
            # would never report.
            ws = mktempdir()
            write(joinpath(ws, "Cargo.toml"), "[workspace]\nmembers = []\n")
            mkpath(joinpath(ws, "odd"))
            write(joinpath(ws, "odd", "thing.txt"), "content")
            ws_strategy, ws_files = RustCall.crate_input_files(ws)
            @test ws_strategy == "walk"
            @test "odd/thing.txt" in ws_files                # the walk sees everything
            @test "Cargo.toml" in ws_files
            dig_ws = RustCall.artifact_path_dependency_digest(ws)
            write(joinpath(ws, "odd", "thing.txt"), "changed")
            @test RustCall.artifact_path_dependency_digest(ws) != dig_ws

            # The walk skips build output and VCS metadata.
            mkpath(joinpath(ws, "target", "debug"))
            write(joinpath(ws, "target", "debug", "junk"), "noise")
            mkpath(joinpath(ws, ".git"))
            write(joinpath(ws, ".git", "HEAD"), "ref: refs/heads/main")
            _, ws_files2 = RustCall.crate_input_files(ws)
            @test !any(f -> startswith(f, "target/") || startswith(f, ".git/"), ws_files2)
            @test "target" in RustCall.CRATE_INPUT_VCS_DIRS
            @test ".git" in RustCall.CRATE_INPUT_VCS_DIRS
            # `target` is build output only at the package root; VCS metadata is
            # excluded at every level.
            @test !("target" in RustCall.CRATE_INPUT_VCS_DIRS_ANY_LEVEL)
            @test ".git" in RustCall.CRATE_INPUT_VCS_DIRS_ANY_LEVEL
            rm(ws; force = true, recursive = true)

            # Round-four review finding (1): a module directory named
            # src/target/ is ordinary source and must not be pruned.
            nested_target = crate_with(mktempdir();
                files = Dict("src/lib.rs" => "mod target;",
                             "src/target/mod.rs" => "pub fn t() -> i32 { 1 }"))
            _, nt_files = RustCall.crate_input_files(nested_target)
            @test "src/target/mod.rs" in nt_files
            dig_nt = RustCall.crate_content_digest(nested_target)
            write(joinpath(nested_target, "src", "target", "mod.rs"), "pub fn t() -> i32 { 2 }")
            @test RustCall.crate_content_digest(nested_target) != dig_nt
            @test RustCall.artifact_path_dependency_digest(nested_target) !=
                  RustCall.artifact_path_dependency_digest(bs)
            # The root target/ is still ignored ...
            dig_nt2 = RustCall.crate_content_digest(nested_target)
            mkpath(joinpath(nested_target, "target", "debug"))
            write(joinpath(nested_target, "target", "debug", "junk"), "noise")
            @test RustCall.crate_content_digest(nested_target) == dig_nt2
            # ... and a .git anywhere is still ignored.
            mkpath(joinpath(nested_target, "src", ".git"))
            write(joinpath(nested_target, "src", ".git", "HEAD"), "ref")
            @test RustCall.crate_content_digest(nested_target) == dig_nt2
            rm(nested_target; force = true, recursive = true)

            # Review finding (1) of the third round: files that a *distributable
            # package* omits are still compiled, so they must still count.
            #
            # (a) a gitignored module pulled in with #[path].
            ignored = crate_with(mktempdir();
                files = Dict("src/lib.rs" => "#[path = \"generated.rs\"] mod generated;",
                             "src/generated.rs" => "pub fn gen() -> i32 { 1 }",
                             ".gitignore" => "src/generated.rs\n"))
            dig_ignored = RustCall.artifact_path_dependency_digest(ignored)
            write(joinpath(ignored, "src", "generated.rs"), "pub fn gen() -> i32 { 2 }")
            @test RustCall.artifact_path_dependency_digest(ignored) != dig_ignored
            _, ignored_files = RustCall.crate_input_files(ignored)
            @test "src/generated.rs" in ignored_files

            # (b) a file removed from the package by `exclude`.
            excluded = crate_with(mktempdir();
                manifest_extra = "exclude = [\"notes/*\"]\n",
                files = Dict("src/lib.rs" => "pub fn f() {}",
                             "notes/design.md" => "v1"))
            dig_excluded = RustCall.artifact_path_dependency_digest(excluded)
            write(joinpath(excluded, "notes", "design.md"), "v2")
            @test RustCall.artifact_path_dependency_digest(excluded) != dig_excluded
            _, excluded_files = RustCall.crate_input_files(excluded)
            @test "notes/design.md" in excluded_files

            rm(ignored; force = true, recursive = true)
            rm(excluded; force = true, recursive = true)
        finally
            for d in (bs, outside)
                rm(d; force = true, recursive = true)
            end
        end
    end

    @testset "Local crates come from Cargo's resolved graph" begin
        # Review finding (2) of the third round: parsing only the three
        # root-level dependency tables misses [target.'cfg(...)'.dependencies]
        # and workspace-inherited deps.
        function crate(dir, name, body; manifest_extra = "")
            mkpath(joinpath(dir, "src"))
            write(joinpath(dir, "Cargo.toml"),
                "[package]\nname = \"$(name)\"\nversion = \"0.1.0\"\nedition = \"2021\"\n$(manifest_extra)")
            write(joinpath(dir, "src", "lib.rs"), body)
            return dir
        end

        root = mktempdir()
        try
            grand = crate(joinpath(root, "grand"), "grand", "pub fn g() {}")
            child = crate(joinpath(root, "child"), "child", "pub fn c() {}";
                manifest_extra = "\n[dependencies]\ngrand = { path = \"../grand\" }\n")
            parent = crate(joinpath(root, "parent"), "parent", "pub fn p() {}";
                manifest_extra = "\n[target.'cfg(unix)'.dependencies]\nchild = { path = \"../child\" }\n")

            strategy, dirs = RustCall.local_path_dependency_dirs(parent)
            canon = Set(realpath.(dirs))

            # A cfg-gated dependency is found ...
            @test realpath(child) in canon
            # ... and so is a dependency of that dependency.
            @test realpath(grand) in canon

            # Editing either one changes the key.
            dig0 = RustCall.artifact_path_dependency_digest(parent)
            write(joinpath(child, "src", "lib.rs"), "pub fn c() -> i32 { 9 }")
            dig1 = RustCall.artifact_path_dependency_digest(parent)
            @test dig1 != dig0
            write(joinpath(grand, "src", "lib.rs"), "pub fn g() -> i32 { 9 }")
            @test RustCall.artifact_path_dependency_digest(parent) != dig1

            # The strategy is recorded and reaches the digest.
            @test strategy in ("cargo-tree", "manifest-toml")
            if strategy != "cargo-tree"
                @info "cargo tree unavailable; only the manifest fallback exercised"
            end

            # The fallback finds the same cfg-gated and transitive crates.
            fb_dirs = String[parent]
            RustCall._collect_manifest_path_deps!(fb_dirs, parent, Set{String}())
            fb_canon = Set(realpath.(fb_dirs))
            @test realpath(child) in fb_canon
            @test realpath(grand) in fb_canon

            # Target-specific and workspace-inherited tables are both traversed
            # by the fallback manifest reader.
            @test "../child" in RustCall._declared_path_dependencies(joinpath(parent, "Cargo.toml"))

            # Round-four review finding (2): an inherited `path` is relative to
            # the manifest that declares [workspace.dependencies], not to the
            # member that inherits it. Joining it to the member directory would
            # look for `member/shared`, which does not exist.
            wsroot = mktempdir()
            member = crate(joinpath(wsroot, "member"), "member", "pub fn m() {}";
                manifest_extra = "\n[dependencies]\nshared = { workspace = true }\n")
            shared = crate(joinpath(wsroot, "shared"), "shared", "pub fn s() {}")
            write(joinpath(wsroot, "Cargo.toml"),
                "[workspace]\nmembers = [\"member\", \"shared\"]\n" *
                "\n[workspace.dependencies]\nshared = { path = \"shared\" }\n")

            inherited = RustCall._declared_path_dependencies(joinpath(member, "Cargo.toml"))
            @test length(inherited) == 1
            @test realpath(only(inherited)) == realpath(shared)
            @test !isdir(joinpath(member, "shared"))     # the naive join would miss

            # The fallback collector reaches the shared crate from the member ...
            ws_fb = String[member]
            RustCall._collect_manifest_path_deps!(ws_fb, member, Set{String}())
            @test realpath(shared) in Set(realpath.(ws_fb))

            # ... and, forcing the fallback (no cargo resolution for a bare
            # member of a workspace whose lock cannot be produced offline is not
            # guaranteed, so drive the digest through the collector's own
            # crates), editing the shared crate changes what is hashed.
            shared_dig = RustCall.crate_content_digest(shared)
            write(joinpath(shared, "src", "lib.rs"), "pub fn s() -> i32 { 42 }")
            @test RustCall.crate_content_digest(shared) != shared_dig
            member_dig = RustCall.artifact_path_dependency_digest(member)
            write(joinpath(shared, "src", "lib.rs"), "pub fn s() -> i32 { 43 }")
            @test RustCall.artifact_path_dependency_digest(member) != member_dig
            rm(wsroot; force = true, recursive = true)

            # Metadata failure is exercised: a directory with no manifest at all
            # cannot be resolved by cargo, so the fallback answers.
            bare = mktempdir()
            write(joinpath(bare, "notes.txt"), "no manifest here")
            bare_strategy, bare_dirs = RustCall.local_path_dependency_dirs(bare)
            @test bare_strategy == "manifest-toml"
            @test length(bare_dirs) == 1
            rm(bare; force = true, recursive = true)

            # A dependency cycle terminates.
            cyc = mktempdir()
            x = crate(joinpath(cyc, "x"), "x", "pub fn x() {}";
                manifest_extra = "\n[dependencies]\ny = { path = \"../y\" }\n")
            crate(joinpath(cyc, "y"), "y", "pub fn y() {}";
                manifest_extra = "\n[dependencies]\nx = { path = \"../x\" }\n")
            cyc_dirs = String[x]
            RustCall._collect_manifest_path_deps!(cyc_dirs, x, Set{String}())
            @test length(unique(realpath.(cyc_dirs))) == 2
            @test length(RustCall.artifact_path_dependency_digest(x)) == 64
            rm(cyc; force = true, recursive = true)
        finally
            rm(root; force = true, recursive = true)
        end
    end

    @testset "Build-script environment inputs are captured" begin
        # Review finding (2): CC/CFLAGS/PKG_CONFIG_PATH and friends reach the
        # build scripts of dependencies (cc-rs, pkg-config, cmake, bindgen) and
        # change the native objects linked into the artifact.
        for n in ("CC", "CXX", "AR", "LD", "RANLIB", "STRIP", "NM",
                  "CFLAGS", "CXXFLAGS", "LDFLAGS", "ASFLAGS", "CPPFLAGS",
                  "PKG_CONFIG", "PKG_CONFIG_PATH", "PKG_CONFIG_ALLOW_CROSS",
                  "CMAKE_TOOLCHAIN_FILE", "BINDGEN_EXTRA_CLANG_ARGS",
                  "LIBCLANG_PATH", "CLANG_PATH",
                  "TARGET_CFLAGS", "HOST_CFLAGS", "CARGO_FEATURE_DEFAULT")
            @test RustCall.artifact_build_env_captured(n)
        end

        # cc-rs accepts both per-target spellings.
        @test RustCall.artifact_build_env_captured("x86_64_unknown_linux_gnu_CC")
        @test RustCall.artifact_build_env_captured("CC_x86_64-unknown-linux-gnu")
        @test RustCall.artifact_build_env_captured("aarch64_apple_darwin_CFLAGS")
        @test RustCall.artifact_build_env_captured("CFLAGS_aarch64-apple-darwin")
        @test RustCall.artifact_build_env_captured("x86_64_unknown_linux_gnu_LINKER")

        # Secret rejection still runs first, over the build-script allowlist too.
        for n in ("PKG_CONFIG_AUTH_TOKEN", "PKG_CONFIG_SECRET", "CC_PASSWORD",
                  "BINDGEN_API_KEY", "CMAKE_CREDENTIAL_HELPER", "TARGET_AUTH")
            @test !RustCall.artifact_build_env_captured(n)
        end
        @test RustCall.artifact_build_env_captured("PKG_CONFIG_PATH")

        # Unrelated variables stay out.
        for n in ("EDITOR", "LANG", "TERM", "SHELL", "PWD")
            @test !RustCall.artifact_build_env_captured(n)
        end

        # A build-script variable reaches the key.
        env_a = Dict("CC" => "clang")
        env_b = Dict("CC" => "gcc")
        @test RustCall.artifact_key(_id(kind = "cargo",
                  build_env = RustCall.artifact_build_env(; env = env_a))) !=
              RustCall.artifact_key(_id(kind = "cargo",
                  build_env = RustCall.artifact_build_env(; env = env_b)))
        # ... and unset CC differs from CC="".
        @test RustCall.artifact_build_env(["CC"]; env = Dict{String, String}()) !=
              RustCall.artifact_build_env(["CC"]; env = Dict("CC" => ""))

        # A scan never leaks a credential even when build-script vars are present.
        mixed = Dict("CC" => "clang", "PKG_CONFIG_PATH" => "/opt/lib/pkgconfig",
                     "PKG_CONFIG_AUTH_TOKEN" => "s3cret", "CARGO_REGISTRY_TOKEN" => "s3cret")
        captured = RustCall.artifact_build_env(; env = mixed)
        @test first.(captured) == ["CC", "PKG_CONFIG_PATH"]
        @test !any(p -> occursin("s3cret", last(p)), captured)
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
                  "RUSTC_WORKSPACE_WRAPPER",
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

        # Round-four review finding (3): RUSTC_WORKSPACE_WRAPPER sits between
        # Cargo and rustc exactly like RUSTC_WRAPPER and must be captured.
        @test "RUSTC_WORKSPACE_WRAPPER" in RustCall.ARTIFACT_BUILD_ENV_NAMES
        @test "RUSTC_WRAPPER" in RustCall.ARTIFACT_BUILD_ENV_NAMES
        wrapper_env = Dict("RUSTC_WORKSPACE_WRAPPER" => "/usr/bin/sccache")
        wrapper_snap = RustCall.artifact_build_env(; env = wrapper_env)
        @test first.(wrapper_snap) == ["RUSTC_WORKSPACE_WRAPPER"]
        @test RustCall.artifact_key(_id(kind = "cargo", build_env = wrapper_snap)) !=
              RustCall.artifact_key(_id(kind = "cargo",
                  build_env = RustCall.artifact_build_env(; env = Dict{String, String}())))
        # ... and it is part of the identity of the compiler that runs, too.
        if !occursin("rustc=unknown", (try RustCall.artifact_compiler_identity() catch; "rustc=unknown" end))
            ident = RustCall.artifact_compiler_identity()
            @test occursin("rustc_wrapper=", ident)
            @test occursin("rustc_workspace_wrapper=", ident)
        end

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

    @testset "FIXED #247: the monomorphization key keeps parameter order" begin
        # The key used to be `(func_name, tuple(sort(values(type_params))...))`.
        # Sorting the *values* discarded which parameter got which type, so
        # pair<T=i32, U=i64> and pair<T=i64, U=i32> shared one cache entry and
        # the second call ran the first one's machine code (#247).
        a = Dict{Symbol, Type}(:T => Int32, :U => Int64)
        b = Dict{Symbol, Type}(:T => Int64, :U => Int32)

        key_a = RustCall.artifact_key(_id(kind = "monomorphization", source = "pair",
            type_params = RustCall.artifact_type_params([:T, :U], a)))
        key_b = RustCall.artifact_key(_id(kind = "monomorphization", source = "pair",
            type_params = RustCall.artifact_type_params([:T, :U], b)))
        @test key_a != key_b

        # `_monomorphization_id` — the helper both generics.jl call sites use —
        # has the same property, without needing a toolchain to build one.
        info = RustCall.GenericFunctionInfo(
            "pair", "pub fn pair<T, U>(a: T, b: U) -> T { a }", [:T, :U],
            Dict{Symbol, RustCall.TypeConstraints}(), "", ["T", "U"], "T", "pair",
            nothing, "")
        compiler = RustCall.RustCompiler(optimization_level = 2)
        id_a = RustCall._monomorphization_id(info, "pair", a, compiler)
        id_b = RustCall._monomorphization_id(info, "pair", b, compiler)
        @test id_a.type_params == ["T" => "Int32", "U" => "Int64"]
        @test id_b.type_params == ["T" => "Int64", "U" => "Int32"]
        @test RustCall.artifact_key(id_a) != RustCall.artifact_key(id_b)
        # Deterministic, and the compiler snapshot is part of it.
        @test RustCall.artifact_key(id_a) ==
              RustCall.artifact_key(RustCall._monomorphization_id(info, "pair", a, compiler))
        @test RustCall.artifact_key(id_a) != RustCall.artifact_key(
            RustCall._monomorphization_id(info, "pair", a,
                                          RustCall.RustCompiler(optimization_level = 0)))
        # An unbound declared parameter is an error, never a silent key.
        @test_throws ArgumentError RustCall._monomorphization_id(
            info, "pair", Dict{Symbol, Type}(:T => Int32), compiler)
    end

    @testset "FIXED #252: the rustc in the key is the rustc that compiles" begin
        # The PATH-based `_get_rustc_version()` that could degrade to the string
        # "unknown" is gone; every key now names the toolchain
        # `RustToolChain.rustc()` / `cargo()` resolve to, and an unidentifiable
        # compiler is an error rather than a sentinel.
        @test !isdefined(RustCall, :_get_rustc_version)
        @test !isdefined(RustCall, :_cached_rustc_version)
        @test !isdefined(RustCall, :_get_cargo_version)

        toolchain_ok = try
            RustCall.artifact_compiler_identity()
            true
        catch
            false
        end

        if !toolchain_ok
            @info "Skipping #252 identity test: RustToolChain rustc/cargo unavailable"
        else
            identity_str = RustCall.artifact_compiler_identity()
            @test occursin("rustc=", identity_str)
            @test occursin("cargo=", identity_str)
            # Never the "unknown" sentinel, anywhere in the identity.
            @test !occursin("unknown", identity_str)

            # The identity is memoized, so an empty PATH cannot change it back
            # to a degraded value mid-session ...
            empty_dir = mktempdir()
            try
                @test withenv("PATH" => empty_dir) do
                    RustCall.artifact_compiler_identity()
                end == identity_str
            finally
                rm(empty_dir; force = true, recursive = true)
            end

            # ... and it is what `toolchain_fingerprint` folds in, so the
            # fingerprint follows the real toolchain (#252).
            fp = RustCall.toolchain_fingerprint()
            @test fp == RustCall.toolchain_fingerprint()
            @test !occursin(RustCall._TOOLCHAIN_COMPILER_UNIDENTIFIED, fp)
        end

        # `toolchain_fingerprint()` stays total for callers that only need *a*
        # fingerprint; the compile paths are the ones that raise.
        @test RustCall._TOOLCHAIN_COMPILER_UNIDENTIFIED != "unknown"
    end

    @testset "FIXED: truncation happens in exactly one place" begin
        # No src/ site truncates below ARTIFACT_SHORT_ID_LEN and no truncated
        # value is a lookup key. The grep-style enforcement of that rule lives
        # in scripts/lint_artifact_identity.sh; here we assert the properties of
        # the one truncation function, and that the lookup keys are full length.
        code = "fn f() -> i32 { 1 }"
        key = RustCall.artifact_key(_id(kind = "rustc", source = code))

        @test length(key) == 64
        @test length(RustCall.artifact_short_id(key)) == RustCall.ARTIFACT_SHORT_ID_LEN
        @test RustCall.artifact_short_id(key) == first(key, RustCall.ARTIFACT_SHORT_ID_LEN)
        # Names may ask for fewer characters explicitly; lookups never do.
        @test length(RustCall.artifact_short_id(key, 12)) == 12
        @test_throws ArgumentError RustCall.artifact_short_id(key, 0)
        @test_throws ArgumentError RustCall.artifact_short_id(key, 65)

        # And the grep-style rule itself holds on this tree: no file outside
        # src/artifact_id.jl concatenates key material, truncates a digest, or
        # names an artifact with Julia's session-randomized `hash()`.
        lint = joinpath(pkgdir(RustCall), "scripts", "lint_artifact_identity.sh")
        @test isfile(lint)
        if !Sys.iswindows() && Sys.which("bash") !== nothing
            @test success(pipeline(`bash $lint $(joinpath(pkgdir(RustCall), "src"))`;
                                   stdout = devnull, stderr = devnull))
        end

        # The migrated adapters all return the full digest.
        compiler = RustCall.RustCompiler(optimization_level = 2)
        for k in (RustCall._cargo_block_identity("fn f() {}", "deps", ""),
                  RustCall.artifact_key(RustCall._cargo_block_id("fn f() {}",
                                                                 RustCall.DependencySpec[], "")))
            @test length(k) == 64
        end
        if RustCall.check_rustc_available()
            @test length(RustCall.generate_cache_key("fn f() {}", compiler)) == 64
            @test length(RustCall._rustc_block_identity("fn f() {}", compiler, "")) == 64
        end
    end

    @testset "Path-dependency digests are memoized (#278 §8)" begin
        # `artifact_path_dependency_digest` shells out to `cargo tree` and reads
        # every file of every local crate. Paying that on a warm re-evaluation
        # would add hundreds of milliseconds to a no-op, so the resolved graph is
        # memoized on the crate's Cargo.toml / Cargo.lock stats and file contents
        # on `(path, mtime, size)`.
        dir = mktempdir()
        try
            mkpath(joinpath(dir, "src"))
            write(joinpath(dir, "Cargo.toml"),
                  "[package]\nname = \"memo_probe\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")
            write(joinpath(dir, "src", "lib.rs"), "pub fn f() -> i32 { 1 }\n")

            RustCall._artifact_reset_digest_caches!()
            before = RustCall.CARGO_TREE_INVOCATIONS[]
            d1 = RustCall.artifact_path_dependency_digest(dir)
            after_cold = RustCall.CARGO_TREE_INVOCATIONS[]

            # The warm call resolves no graph again.
            d2 = RustCall.artifact_path_dependency_digest(dir)
            @test d1 == d2
            @test RustCall.CARGO_TREE_INVOCATIONS[] == after_cold
            # (When cargo is unavailable the cold call spawns nothing either;
            #  what matters is that the warm one adds no invocation.)
            @test after_cold >= before

            # An edited source still changes the digest: only *unchanged* files
            # skip the re-read, and the walk always happens.
            sleep(0.01)
            write(joinpath(dir, "src", "lib.rs"), "pub fn f() -> i32 { 2 }\n")
            RustCall._artifact_reset_digest_caches!()
            @test RustCall.artifact_path_dependency_digest(dir) != d1

            # A new file changes it too.
            d3 = RustCall.artifact_path_dependency_digest(dir)
            write(joinpath(dir, "src", "extra.rs"), "// new input\n")
            RustCall._artifact_reset_digest_caches!()
            @test RustCall.artifact_path_dependency_digest(dir) != d3
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "A same-length edit under an unchanged mtime still rebuilds (#287 review)" begin
        # A `(mtime, size)` stamp is a fine invalidation hint and a terrible
        # identity: a coarse-timestamp filesystem, a metadata-preserving tool,
        # or a same-length edit inside one timestamp tick all alias distinct
        # contents. Here the consequence would be running machine code compiled
        # from source that no longer exists, so file contents are never
        # memoized — every call reads every byte.
        dir = mktempdir()
        try
            mkpath(joinpath(dir, "src"))
            write(joinpath(dir, "Cargo.toml"),
                  "[package]\nname = \"alias_probe\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")
            src = joinpath(dir, "src", "lib.rs")
            original = "pub fn f() -> i32 { 1 }\n"
            replacement = "pub fn f() -> i32 { 2 }\n"
            @test length(original) == length(replacement)   # same size, by construction

            # Nothing memoizes file contents, so nothing *can* alias them.
            @test !isdefined(RustCall, :_FILE_CONTENT_DIGEST_CACHE)

            write(src, original)
            key_before = RustCall.artifact_path_dependency_digest(dir)
            @test RustCall.artifact_path_dependency_digest(dir) == key_before
            digest_before = RustCall._file_content_digest(src)

            # A reference file carrying the *exact* original timestamp of `src`,
            # so it can be copied back at full precision afterwards.
            reference = joinpath(dir, "mtime_reference")
            write(reference, "")
            can_restore = !Sys.iswindows() && Sys.which("touch") !== nothing &&
                success(pipeline(`touch -r $(src) $(reference)`; stderr = devnull))
            before_stat = (mtime(src), filesize(src))

            # Different bytes, same length; then the original mtime restored, so
            # the `(mtime, size)` pair a stamp would see is byte-for-byte what
            # it was — the exact aliasing Codex flagged.
            write(src, replacement)
            @test filesize(src) == before_stat[2]
            if can_restore
                run(pipeline(`touch -r $(reference) $(src)`; stderr = devnull))
                @test (mtime(src), filesize(src)) == before_stat   # indistinguishable by stat
            else
                @info "same-length alias probe: cannot restore mtime here; " *
                      "the contents assertion below still holds"
            end

            # The graph is still cached (no manifest changed) and no cache was
            # reset — the *contents* are re-read regardless, so the key moves.
            @test RustCall._file_content_digest(src) != digest_before
            @test RustCall.artifact_path_dependency_digest(dir) != key_before
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "A transitive manifest change re-resolves the graph (#287 review)" begin
        # The graph cache used to be validated against the root's Cargo.toml /
        # Cargo.lock only. A crate *inside* the graph that grows a new path
        # dependency changes its own manifest while the root's files stay
        # untouched, so the cached directory list would keep omitting the new
        # crate — and edits to it would never reach the key again.
        root = mktempdir()
        try
            function crate!(name, deps = "")
                d = joinpath(root, name)
                mkpath(joinpath(d, "src"))
                write(joinpath(d, "Cargo.toml"),
                      "[package]\nname = \"$(name)\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" *
                      "\n[dependencies]\n" * deps)
                write(joinpath(d, "src", "lib.rs"), "pub fn $(name)_f() -> i32 { 1 }\n")
                return d
            end
            grand = crate!("grand")
            child = crate!("child")
            parent = crate!("parent", "child = { path = \"../child\" }\n")

            RustCall._artifact_reset_digest_caches!()
            key_before = RustCall.artifact_path_dependency_digest(parent)
            _, dirs_before = RustCall.local_path_dependency_dirs(parent)
            @test any(d -> RustCall._canonical_dir(d) == RustCall._canonical_dir(child), dirs_before)
            @test !any(d -> RustCall._canonical_dir(d) == RustCall._canonical_dir(grand), dirs_before)

            # Warm: the graph is cached, no process spawn.
            warm = RustCall.CARGO_TREE_INVOCATIONS[]
            @test RustCall.artifact_path_dependency_digest(parent) == key_before
            @test RustCall.CARGO_TREE_INVOCATIONS[] == warm

            # A *transitive* crate grows a path dependency. The root's manifest
            # and lockfile are untouched.
            root_stamp = RustCall._graph_stamp(parent)
            write(joinpath(child, "Cargo.toml"),
                  "[package]\nname = \"child\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" *
                  "\n[dependencies]\ngrand = { path = \"../grand\" }\n")
            @test RustCall._graph_stamp(parent) == root_stamp

            # ... which invalidates the cached graph and costs a re-resolution.
            before_resolve = RustCall.CARGO_TREE_INVOCATIONS[]
            _, dirs_after = RustCall.local_path_dependency_dirs(parent)
            @test RustCall.CARGO_TREE_INVOCATIONS[] > before_resolve
            @test any(d -> RustCall._canonical_dir(d) == RustCall._canonical_dir(grand), dirs_after)

            key_after = RustCall.artifact_path_dependency_digest(parent)
            @test key_after != key_before

            # And the new crate is now a real input: editing it changes the key.
            write(joinpath(grand, "src", "lib.rs"), "pub fn grand_f() -> i32 { 99 }\n")
            @test RustCall.artifact_path_dependency_digest(parent) != key_after

            # Removing it again is noticed too (the child's manifest changes).
            write(joinpath(child, "Cargo.toml"),
                  "[package]\nname = \"child\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n")
            _, dirs_removed = RustCall.local_path_dependency_dirs(parent)
            @test !any(d -> RustCall._canonical_dir(d) == RustCall._canonical_dir(grand), dirs_removed)
        finally
            rm(root; recursive = true, force = true)
        end
    end

    @testset "A workspace manifest change re-resolves the graph (#287 review)" begin
        # A member inherits `dep = { workspace = true }` from
        # `[workspace.dependencies]` in the *workspace root* manifest — which,
        # for a virtual workspace, is not a package and can never appear in the
        # package list Cargo reports. Stamping only the crates in the graph
        # therefore misses every edit to it.
        root = mktempdir()
        try
            function member!(name, deps = "")
                d = joinpath(root, name)
                mkpath(joinpath(d, "src"))
                write(joinpath(d, "Cargo.toml"),
                      "[package]\nname = \"$(name)\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" *
                      "\n[dependencies]\n" * deps)
                write(joinpath(d, "src", "lib.rs"), "pub fn $(name)_f() -> i32 { 1 }\n")
                return d
            end
            shared = member!("shared")
            shared2 = member!("shared2")
            app = member!("app", "shared = { workspace = true }\n")

            workspace_manifest = joinpath(root, "Cargo.toml")
            write(workspace_manifest,
                  "[workspace]\nmembers = [\"app\", \"shared\", \"shared2\"]\nresolver = \"2\"\n" *
                  "\n[workspace.dependencies]\nshared = { path = \"shared\" }\n")

            # The workspace root is part of the validation set even though it is
            # not a package in the graph.
            @test RustCall._workspace_root_dir(app) == RustCall._canonical_dir(root) ||
                  RustCall._canonical_dir(RustCall._workspace_root_dir(app)) ==
                      RustCall._canonical_dir(root)

            RustCall._artifact_reset_digest_caches!()
            key_before = RustCall.artifact_path_dependency_digest(app)
            stamped = first.(RustCall._graph_stamps(RustCall.local_path_dependency_dirs(app)[2]))
            @test RustCall._canonical_dir(root) in stamped

            # Warm: no re-resolution.
            warm = RustCall.CARGO_TREE_INVOCATIONS[]
            @test RustCall.artifact_path_dependency_digest(app) == key_before
            @test RustCall.CARGO_TREE_INVOCATIONS[] == warm

            # Repoint the inherited dependency in the *workspace* manifest. The
            # member's own manifest is untouched.
            member_stamp = RustCall._graph_stamp(app)
            write(workspace_manifest,
                  "[workspace]\nmembers = [\"app\", \"shared\", \"shared2\"]\nresolver = \"2\"\n" *
                  "\n[workspace.dependencies]\nshared = { path = \"shared2\" }\n")
            @test RustCall._graph_stamp(app) == member_stamp

            # ... which must still invalidate the cached graph.
            @test RustCall.artifact_path_dependency_digest(app) != key_before
        finally
            rm(root; recursive = true, force = true)
        end
    end

    @testset "A same-length manifest edit under an unchanged mtime re-resolves (#287 review)" begin
        # Manifests were stat-stamped, which is the same aliasing this file
        # refuses to accept for sources: a same-length `Cargo.toml` edit under a
        # preserved timestamp would swap a path dependency with no
        # re-resolution. They are hashed now — a manifest is a few hundred
        # bytes, so there is nothing to trade.
        root = mktempdir()
        try
            for name in ("one", "two")
                d = joinpath(root, name)
                mkpath(joinpath(d, "src"))
                write(joinpath(d, "Cargo.toml"),
                      "[package]\nname = \"$(name)\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")
                write(joinpath(d, "src", "lib.rs"), "pub fn f() -> i32 { $(name == "one" ? 1 : 2) }\n")
            end
            parent = joinpath(root, "parent")
            mkpath(joinpath(parent, "src"))
            write(joinpath(parent, "src", "lib.rs"), "pub fn p() -> i32 { 0 }\n")
            manifest = joinpath(parent, "Cargo.toml")
            header = "[package]\nname = \"parent\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n"
            # The two bodies differ only in one character, so they are the same
            # length by construction.
            write(manifest, header * "dep = { path = \"../one\" }\n")

            RustCall._artifact_reset_digest_caches!()
            key_before = RustCall.artifact_path_dependency_digest(parent)
            _, dirs_before = RustCall.local_path_dependency_dirs(parent)
            @test any(d -> basename(rstrip(RustCall._canonical_dir(d), '/')) == "one", dirs_before)

            reference = joinpath(root, "mtime_reference")
            write(reference, "")
            can_restore = !Sys.iswindows() && Sys.which("touch") !== nothing &&
                success(pipeline(`touch -r $(manifest) $(reference)`; stderr = devnull))
            before_stat = (mtime(manifest), filesize(manifest))

            write(manifest, header * "dep = { path = \"../two\" }\n")
            @test filesize(manifest) == before_stat[2]      # same length
            if can_restore
                run(pipeline(`touch -r $(reference) $(manifest)`; stderr = devnull))
                @test (mtime(manifest), filesize(manifest)) == before_stat   # stat-identical
            end

            # Re-resolved anyway, and the swapped crate is what is hashed now.
            _, dirs_after = RustCall.local_path_dependency_dirs(parent)
            @test any(d -> basename(rstrip(RustCall._canonical_dir(d), '/')) == "two", dirs_after)
            @test RustCall.artifact_path_dependency_digest(parent) != key_before
        finally
            rm(root; recursive = true, force = true)
        end
    end

    @testset "Hashed relative paths are normalized" begin
        # A `\\`-spelled path and a `/`-spelled one are the same input; on
        # Windows so are two spellings that differ only in case.
        @test RustCall._hashed_relative_path("src\\lib.rs") == "src/lib.rs"
        @test RustCall._hashed_relative_path("src/lib.rs") == "src/lib.rs"
        if Sys.iswindows()
            @test RustCall._hashed_relative_path("SRC/Lib.rs") == "src/lib.rs"
        else
            @test RustCall._hashed_relative_path("SRC/Lib.rs") == "SRC/Lib.rs"
        end
    end

    @testset "artifact_derive replaces only what it is given" begin
        base = _id(kind = "cargo", source = "fn f() {}",
                   codegen = ["profile" => "release"], dependencies = ["serde"])
        same = RustCall.artifact_derive(base)
        @test RustCall.artifact_key(same) == RustCall.artifact_key(base)
        debug = RustCall.artifact_derive(base;
            codegen = vcat(base.codegen, ["profile" => "debug"]))
        @test RustCall.artifact_key(debug) != RustCall.artifact_key(base)
        @test debug.source == base.source && debug.dependencies == base.dependencies
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
