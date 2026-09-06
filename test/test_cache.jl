# Tests for compilation caching

using RustCall
using Test

"""
    with_isolated_depot(f)

Run `f(depot)` with a fresh temporary directory in front of `DEPOT_PATH`.

The cache-location testsets look at, create in and sweep two trees that are
derived from `DEPOT_PATH[1]`: the scratch space `get_cache_dir()` resolves to,
and the pre-#252 root `_legacy_cache_root()`. In a depot a RustCall has really
been used in, both hold the user's own files — a leftover `v2/` tree, real
`cargo/` and `metadata/` directories — which would both break the assertions
and make the opt-in legacy sweep delete something that is not a fixture. A
temporary first depot gives those tests a tree nobody else wrote.

Both inputs to the memoized cache directory change here, so the memo is reset on
the way in and on the way out.
"""
function with_isolated_depot(f)
    depot = mktempdir()
    saved = copy(DEPOT_PATH)
    try
        pushfirst!(DEPOT_PATH, depot)
        RustCall._reset_cache_dir_memo!()
        return f(depot)
    finally
        empty!(DEPOT_PATH)
        append!(DEPOT_PATH, saved)
        RustCall._reset_cache_dir_memo!()
        rm(depot; recursive = true, force = true)
    end
end

@testset "Compilation Caching" begin
    # Clear cache before testing
    RustCall.clear_cache()

    @testset "Cache Directory Management" begin
        cache_dir = RustCall.get_cache_dir()
        @test isdir(cache_dir)
        # The scratch space is namespaced by RustCall's package UUID.
        @test occursin("scratchspaces", cache_dir)
        @test occursin("7ac5b1a4-9e37-4f0e-9aa3-3305a66bfb1c", cache_dir)

        metadata_dir = RustCall.get_metadata_dir()
        @test isdir(metadata_dir)
    end

    @testset "Cache format namespace (#252, #278)" begin
        with_isolated_depot() do _depot
            # Every cached artifact lives in a scratch space named for the on-disk
            # cache format, so a key-formula change (#278 Phase B) cannot serve a
            # hit written by the previous format, and two RustCalls that disagree
            # about the layout keep separate trees.
            cache_dir = RustCall.get_cache_dir()
            @test basename(cache_dir) == "cache-v$(RustCall.CACHE_FORMAT_VERSION)"
            @test RustCall.CACHE_SCRATCH_NAME == "cache-v$(RustCall.CACHE_FORMAT_VERSION)"

            # The Cargo and metadata trees nest under it.
            @test startswith(RustCall.get_metadata_dir(), cache_dir)
            @test startswith(RustCall.get_cargo_cache_dir(), cache_dir)

            # Older scratch siblings are swept best-effort; newer ones are left alone.
            root = dirname(cache_dir)
            old_dir = joinpath(root, "cache-v1")
            new_dir = joinpath(root, "cache-v$(RustCall.CACHE_FORMAT_VERSION + 1)")
            unrelated = joinpath(root, "not-a-cache")
            mkpath(old_dir)
            mkpath(new_dir)
            mkpath(unrelated)
            write(joinpath(old_dir, "x.txt"), "old")
            try
                stale = RustCall._stale_cache_format_dirs()
                @test old_dir in stale
                @test !(new_dir in stale)
                @test !(unrelated in stale)
                @test !(cache_dir in stale)

                RustCall.sweep_stale_cache_formats()
                @test !isdir(old_dir)
                @test isdir(new_dir)      # a future format's cache is not ours to delete
                @test isdir(unrelated)    # nor is anything that is not `cache-v<n>`
                @test isdir(cache_dir)
            finally
                rm(new_dir; recursive = true, force = true)
                rm(old_dir; recursive = true, force = true)
                rm(unrelated; recursive = true, force = true)
            end
        end
    end

    @testset "RustCall writes nothing under ~/.julia/compiled (#252)" begin
        with_isolated_depot() do _depot
            # Acceptance criterion 1 of #252: the cache is a Scratch.jl space, and
            # `.../compiled/vX.Y/RustCall` — Julia's own precompile directory — is
            # read-only for RustCall and is never created by it.
            cache_dir = RustCall.get_cache_dir()
            @test !occursin(joinpath("compiled", "v$(VERSION.major).$(VERSION.minor)"), cache_dir)

            # The depot is brand new, so if anything appears under
            # `.../compiled/vX.Y/RustCall` in this testset, RustCall put it
            # there. The pre-#252 code created that directory in `get_cache_dir`
            # itself, on the first cache lookup.
            legacy_root = RustCall._legacy_cache_root()
            @test startswith(legacy_root, _depot)
            @test !isdir(legacy_root)

            # Every writer on the cache path goes through `get_cache_dir`; exercise
            # them and assert the legacy root stays absent.
            key = RustCall.stable_content_hash("#252 storage location probe")
            payload = joinpath(mktempdir(), "probe" * RustCall.get_library_extension())
            write(payload, "not really a library")
            RustCall.save_cached_library(key, payload, RustCall.CacheMetadata(
                key, key, "probe", "probe-triple", RustCall.Dates.now(), String["probe"]))
            try
                @test RustCall.get_cached_library(key) !== nothing
                @test startswith(RustCall.get_cached_library(key), cache_dir)
                @test startswith(RustCall.get_cargo_cache_dir(), cache_dir)
                # Nothing appeared in Julia's precompile directory — not one
                # file, and not the directory itself.
                @test !isdir(legacy_root)
                @test isempty(RustCall._legacy_cache_files())
                @test isempty(RustCall._legacy_cache_dirs())
                # A sweep, an age-based cleanup and a plain `clear_cache()` do
                # not create it either.
                RustCall.sweep_stale_cache_formats()
                RustCall.cleanup_old_cache(365)
                @test !isdir(legacy_root)
            finally
                rm(RustCall.get_cached_library(key); force = true)
                rm(joinpath(cache_dir, key * RustCall.get_library_extension() * ".sha256"); force = true)
                rm(joinpath(RustCall.get_metadata_dir(), key * ".json"); force = true)
            end
        end
    end

    @testset "Read-only DEPOT_PATH[1] with a writable depot behind it (#252)" begin
        # Acceptance criterion 3 of #252. `Scratch.get_scratch!` defaults to
        # `first(DEPOT_PATH)`; RustCall scans for the first *writable* depot, so
        # a read-only depot in front (shared/HPC depots, baked container images)
        # is not fatal.
        ro = mktempdir()
        rw = mktempdir()
        chmod(ro, 0o500)
        ro_still_writable = try
            probe = joinpath(ro, "probe")
            touch(probe)
            rm(probe; force = true)
            true
        catch
            false
        end
        if Sys.iswindows() || ro_still_writable
            # Running as root, or on a filesystem where mode bits do not deny
            # the owner: there is no read-only directory to test against.
            @info "Skipping read-only depot test: a 0o500 directory is still writable here"
            chmod(ro, 0o700)
            rm(ro; recursive = true, force = true)
            rm(rw; recursive = true, force = true)
        else
            saved_depots = copy(DEPOT_PATH)
            try
                empty!(DEPOT_PATH)
                append!(DEPOT_PATH, [ro, rw])
                RustCall._reset_cache_dir_memo!()

                @test RustCall._depot_is_writable(ro) == false
                @test RustCall._depot_is_writable(rw) == true
                @test RustCall._writable_depot() == rw

                dir = RustCall.get_cache_dir()
                @test isdir(dir)
                @test startswith(dir, rw)
                @test basename(dir) == RustCall.CACHE_SCRATCH_NAME
                @test isempty(readdir(ro))          # the read-only depot stays empty

                # The cache is actually usable from there.
                write(joinpath(dir, "probe.txt"), "ok")
                @test read(joinpath(dir, "probe.txt"), String) == "ok"
                @test startswith(RustCall.get_metadata_dir(), dir)
                @test startswith(RustCall.get_cargo_cache_dir(), dir)

                # With no writable depot at all, the failure is a named error,
                # not an IOError from deep inside a copy.
                empty!(DEPOT_PATH)
                push!(DEPOT_PATH, ro)
                RustCall._reset_cache_dir_memo!()
                @test RustCall._writable_depot() === nothing
                err = try
                    RustCall.get_cache_dir()
                    nothing
                catch e
                    e
                end
                @test err isa RustCall.RustError
                @test occursin("DEPOT_PATH", sprint(showerror, err))
                @test occursin("RUSTCALL_CACHE_DIR", sprint(showerror, err))
            finally
                empty!(DEPOT_PATH)
                append!(DEPOT_PATH, saved_depots)
                RustCall._reset_cache_dir_memo!()
                chmod(ro, 0o700)
                rm(ro; recursive = true, force = true)
                rm(rw; recursive = true, force = true)
            end
        end
    end

    @testset "RUSTCALL_CACHE_DIR override (#252)" begin
        override = mktempdir()
        saved = get(ENV, "RUSTCALL_CACHE_DIR", nothing)
        try
            ENV["RUSTCALL_CACHE_DIR"] = override
            RustCall._reset_cache_dir_memo!()
            @test RustCall.get_cache_dir() == abspath(override)
            @test startswith(RustCall.get_metadata_dir(), abspath(override))
            # An explicitly chosen directory has no sibling namespace to sweep.
            @test isempty(RustCall._stale_cache_format_dirs())
        finally
            if saved === nothing
                delete!(ENV, "RUSTCALL_CACHE_DIR")
            else
                ENV["RUSTCALL_CACHE_DIR"] = saved
            end
            RustCall._reset_cache_dir_memo!()
            rm(override; recursive = true, force = true)
        end
    end

    @testset "The legacy sweep never deletes what RustCall did not write (#252, #287)" begin
        with_isolated_depot() do _depot
            # `_legacy_cache_root()` is `.../compiled/vX.Y/RustCall` — *Julia's own*
            # package precompile directory for RustCall, where it keeps `<slug>.ji`
            # and `<slug>.dylib` native images. Deleting every regular file there
            # would throw away fresh precompilation output and could race another
            # Julia process writing it. Since #252 RustCall never writes here at
            # all; the tree is read for the opt-in legacy sweep and nothing else.
            root = RustCall._legacy_cache_root()
            root_existed = isdir(root)
            mkpath(root)

            # Named exactly as Julia names them (a package slug: mixed case and an
            # underscore, so `_LEGACY_CACHE_FILE` cannot match).
            julia_ji = joinpath(root, "qLtCw_2ChqG.ji")
            julia_img = joinpath(root, "qLtCw_2ChqG." * (Sys.iswindows() ? "dll" :
                                                         Sys.isapple() ? "dylib" : "so"))
            unrelated = joinpath(root, "notes.txt")
            # ... and a genuine v1 artifact: a `stable_content_hash` key plus the
            # library extension, which is all v1 ever wrote loose in this directory.
            v1_key = RustCall.stable_content_hash("a v1 cache entry")
            legacy_lib = joinpath(root, v1_key * RustCall.get_library_extension())
            legacy_sum = legacy_lib * ".sha256"
            legacy_ir = joinpath(root, v1_key * ".ll")
            # Directory shapes both layouts left behind, including the *current*
            # format version: since #252 nothing under this root is written any
            # more, so every `v<n>` there is abandoned, not just the older ones.
            legacy_v1 = joinpath(root, "v1")
            legacy_vcur = joinpath(root, "v$(RustCall.CACHE_FORMAT_VERSION)")
            legacy_meta = joinpath(root, "metadata")
            julia_dir = joinpath(root, "qLtCw_2ChqG.dSYM")

            for f in (julia_ji, julia_img, unrelated, legacy_lib, legacy_sum, legacy_ir)
                write(f, "x")
            end
            for d in (legacy_v1, legacy_vcur, legacy_meta, julia_dir)
                mkpath(d)
                write(joinpath(d, "content"), "x")
            end
            try
                # The classifiers are the safety property: only ours match.
                listed = RustCall._legacy_cache_files()
                @test legacy_lib in listed
                @test legacy_sum in listed
                @test legacy_ir in listed
                @test !(julia_ji in listed)
                @test !(julia_img in listed)
                @test !(unrelated in listed)

                dirs = RustCall._legacy_cache_dirs()
                @test legacy_v1 in dirs
                @test legacy_vcur in dirs
                @test legacy_meta in dirs
                @test !(julia_dir in dirs)

                # Off by default: a plain sweep touches nothing under this root at
                # all, and neither does an age-based cleanup.
                RustCall.sweep_stale_cache_formats()
                @test all(isfile, (julia_ji, julia_img, unrelated, legacy_lib, legacy_sum, legacy_ir))
                @test all(isdir, (legacy_v1, legacy_vcur, legacy_meta, julia_dir))
                RustCall.cleanup_old_cache(0)
                @test all(isfile, (julia_ji, julia_img, unrelated, legacy_lib, legacy_sum, legacy_ir))
                @test all(isdir, (legacy_v1, legacy_vcur, legacy_meta, julia_dir))

                # Explicitly requested: only the RustCall artifacts go.
                RustCall.sweep_stale_cache_formats(; legacy = true)
                @test !isfile(legacy_lib)
                @test !isfile(legacy_sum)
                @test !isfile(legacy_ir)
                @test !isdir(legacy_v1)
                @test !isdir(legacy_vcur)
                @test !isdir(legacy_meta)
                @test isfile(julia_ji)      # Julia's precompile output survives
                @test isfile(julia_img)
                @test isfile(unrelated)
                @test isdir(julia_dir)
                @test isdir(root)           # the root itself is never removed
            finally
                for f in (julia_ji, julia_img, unrelated, legacy_lib, legacy_sum, legacy_ir)
                    rm(f; force = true)
                end
                for d in (legacy_v1, legacy_vcur, legacy_meta, julia_dir)
                    rm(d; recursive = true, force = true)
                end
                # Do not leave Julia's precompile directory behind if this test
                # created it: #252 is precisely about not writing here.
                if !root_existed && isdir(root) && isempty(readdir(root))
                    rm(root; force = true)
                end
            end

            # The pattern itself, stated directly.
            @test occursin(RustCall._LEGACY_CACHE_FILE, "$(RustCall.stable_content_hash("k")).ll")
            for name in ("qLtCw_2ChqG.ji", "qLtCw_2ChqG.dylib", "qLtCw_2ChqG.so",
                         "notes.txt", "Manifest.toml", "ABCDEF0123456789.dylib",
                         "deadbeef.stale", "libfoo.dylib")
                @test !occursin(RustCall._LEGACY_CACHE_FILE, name)
            end
        end
    end

    @testset "Cache Key Generation" begin
        code1 = """
        #[no_mangle]
        pub extern "C" fn test1() -> i32 { 42 }
        """

        code2 = """
        #[no_mangle]
        pub extern "C" fn test2() -> i32 { 42 }
        """

        compiler = RustCall.get_default_compiler()

        key1 = RustCall.generate_cache_key(code1, compiler)
        key2 = RustCall.generate_cache_key(code2, compiler)

        @test key1 != key2  # Different code should produce different keys
        @test length(key1) == 64  # SHA256 produces 64 hex characters
        @test length(key2) == 64

        # Same code should produce same key (deterministic)
        key1_again = RustCall.generate_cache_key(code1, compiler)
        @test key1 == key1_again

        # The key is `artifact_key` of an ArtifactId and nothing else (#278):
        # there is no second formula to keep in sync here.
        expected_id = RustCall.ArtifactId(
            kind = "rustc",
            source = code1,
            target_triple = compiler.target_triple,
            codegen = RustCall.artifact_codegen_options(compiler),
            cfg = String[RustCall.stable_content_hash(RustCall._cfg_snapshot(:strict))],
            build_env = RustCall.artifact_build_env(RustCall.RUSTC_BUILD_ENV_NAMES),
        )
        @test key1 == RustCall.artifact_key(expected_id)

        # Compiler settings are part of the key.
        @test key1 != RustCall.generate_cache_key(
            code1, RustCall.RustCompiler(optimization_level = 0))

        # The cfg snapshot is part of the key, and an explicit snapshot wins.
        @test RustCall.generate_cache_key(code1, compiler; cfg_text = "target_os=\"nowhere\"") != key1
    end

    @testset "The compiler in the key is the compiler that runs (#252)" begin
        # `artifact_compiler_identity` reads RustToolChain.rustc()/cargo() —
        # the very commands src/compiler.jl and src/cargobuild.jl invoke — and
        # raises rather than degrading to the string "unknown".
        @test !isdefined(RustCall, :_get_rustc_version)
        @test !isdefined(RustCall, :_cached_rustc_version)
        @test !isdefined(RustCall, :_get_cargo_version)

        identity_ok = try
            RustCall.artifact_compiler_identity()
            true
        catch
            false
        end
        if !identity_ok
            @info "Skipping #252 key test: RustToolChain rustc/cargo unavailable"
        else
            identity_str = RustCall.artifact_compiler_identity()
            @test !occursin("unknown", identity_str)

            # Acceptance test from the issue: a changed toolchain fingerprint
            # must produce a cache miss, not a stale hit.
            code = "#[no_mangle]\npub extern \"C\" fn fingerprint_probe() -> i32 { 1 }\n"
            compiler = RustCall.get_default_compiler()
            key_before = RustCall.generate_cache_key(code, compiler)
            saved = RustCall._TOOLCHAIN_FINGERPRINT[]
            try
                RustCall._TOOLCHAIN_FINGERPRINT[] = RustCall.stable_content_hash("a different toolchain")
                key_after = RustCall.generate_cache_key(code, compiler)
                @test key_after != key_before
                @test !RustCall.is_cache_valid(key_before, code, compiler)
            finally
                RustCall._TOOLCHAIN_FINGERPRINT[] = saved
                RustCall._reset_extractor_state!()
            end
            @test RustCall.generate_cache_key(code, compiler) == key_before
        end
    end

    @testset "stable_content_hash utility" begin
        # stable_content_hash must be deterministic and session-stable
        h1 = RustCall.stable_content_hash("hello")
        h2 = RustCall.stable_content_hash("hello")
        @test h1 == h2
        @test length(h1) == 64  # SHA-256 → 64 hex chars

        # Different inputs produce different hashes
        h3 = RustCall.stable_content_hash("world")
        @test h1 != h3
    end

    @testset "Cross-process cache key stability" begin
        # Verify that generate_cache_key and stable_content_hash produce
        # identical results in a separate Julia process (guards against
        # accidental use of session-randomized hash()).
        code = "fn test() -> i32 { 42 }"
        compiler = RustCall.get_default_compiler()
        key_here = RustCall.generate_cache_key(code, compiler)

        project_dir = pkgdir(RustCall)
        key_subprocess = readchomp(`$(Base.julia_cmd()) --project=$project_dir -e "
            using RustCall
            code = \"fn test() -> i32 { 42 }\"
            compiler = RustCall.get_default_compiler()
            print(RustCall.generate_cache_key(code, compiler))
        "`)

        @test key_here == key_subprocess

        # Also verify stable_content_hash directly
        hash_here = RustCall.stable_content_hash("cross-process test data")
        hash_subprocess = readchomp(`$(Base.julia_cmd()) --project=$project_dir -e "
            using RustCall
            print(RustCall.stable_content_hash(\"cross-process test data\"))
        "`)

        @test hash_here == hash_subprocess
    end

    @testset "Cache Operations" begin
        # Test cache size
        initial_size = RustCall.get_cache_size()
        @test initial_size >= 0

        # Test listing cached libraries (should be empty initially)
        cached_libs = RustCall.list_cached_libraries()
        @test isa(cached_libs, Vector{String})
    end

    @testset "Cache Metadata Round-trip (issue #90)" begin
        using Dates

        test_key = "test_metadata_roundtrip_key_0123456789abcdef"
        test_metadata = RustCall.CacheMetadata(
            test_key,
            "abcdef1234567890abcdef1234567890",
            "2_false_x86_64-unknown-linux-gnu",
            "x86_64-unknown-linux-gnu",
            DateTime(2025, 6, 15, 12, 30, 0),
            ["add", "multiply", "divide"]
        )

        # Save metadata
        RustCall.save_cache_metadata(test_key, test_metadata)

        # Load it back
        loaded = RustCall.load_cache_metadata(test_key)
        @test loaded !== nothing
        @test loaded.cache_key == test_key
        @test loaded.code_hash == "abcdef1234567890abcdef1234567890"
        @test loaded.compiler_config == "2_false_x86_64-unknown-linux-gnu"
        @test loaded.target_triple == "x86_64-unknown-linux-gnu"
        @test loaded.created_at == DateTime(2025, 6, 15, 12, 30, 0)
        @test loaded.functions == ["add", "multiply", "divide"]

        # Non-existent key returns nothing
        @test RustCall.load_cache_metadata("nonexistent_key_xyz") === nothing

        # Empty functions list round-trips
        test_key2 = "test_metadata_empty_funcs"
        test_metadata2 = RustCall.CacheMetadata(
            test_key2, "hash2", "config2", "triple2",
            DateTime(2025, 1, 1), String[]
        )
        RustCall.save_cache_metadata(test_key2, test_metadata2)
        loaded2 = RustCall.load_cache_metadata(test_key2)
        @test loaded2 !== nothing
        @test loaded2.functions == String[]

        # Clean up test metadata files
        metadata_dir = RustCall.get_metadata_dir()
        for k in [test_key, test_key2]
            p = joinpath(metadata_dir, "$(k).json")
            isfile(p) && rm(p)
        end
    end

    @testset "Concurrent cache access (issue #91)" begin
        using Dates

        # Verify CACHE_LOCK exists
        @test isdefined(RustCall, :CACHE_LOCK)
        @test RustCall.CACHE_LOCK isa ReentrantLock

        # Run concurrent save/load operations to verify no corruption
        n_tasks = 4
        n_ops = 5
        results = Vector{Bool}(undef, n_tasks)
        test_keys = ["concurrent_test_$(t)_$(i)" for t in 1:n_tasks for i in 1:n_ops]

        tasks = []
        for t in 1:n_tasks
            task = Threads.@spawn begin
                for i in 1:n_ops
                    key = "concurrent_test_$(t)_$(i)"
                    meta = RustCall.CacheMetadata(
                        key, "hash_$(t)_$(i)", "config", "triple",
                        Dates.now(), ["func_$(t)_$(i)"]
                    )
                    RustCall.save_cache_metadata(key, meta)
                    loaded = RustCall.load_cache_metadata(key)
                    if loaded === nothing || loaded.cache_key != key
                        return false
                    end
                end
                return true
            end
            push!(tasks, task)
        end

        for (i, task) in enumerate(tasks)
            results[i] = fetch(task)
        end
        @test all(results)

        # Clean up test metadata files
        metadata_dir = RustCall.get_metadata_dir()
        for key in test_keys
            p = joinpath(metadata_dir, "$(key).json")
            isfile(p) && rm(p)
        end
    end

    # Only run rustc tests if rustc is available
    if RustCall.check_rustc_available()
        @testset "Cache Hit/Miss" begin
            # Clear cache
            RustCall.clear_cache()

            # First compilation (cache miss)
            rust"""
            #[no_mangle]
            pub extern "C" fn cached_add(a: i32, b: i32) -> i32 {
                a + b
            }
            """

            # Call the function to ensure it works
            result1 = @rust cached_add(Int32(10), Int32(20))::Int32
            @test result1 == 30

            # Check that cache was created
            cached_libs = RustCall.list_cached_libraries()
            @test length(cached_libs) > 0

            # Clear in-memory cache
            RustCall.unload_all_libraries()
            empty!(RustCall.RUST_LIBRARIES)
            RustCall.CURRENT_LIB[] = ""

            # Second compilation (should use cache)
            rust"""
            #[no_mangle]
            pub extern "C" fn cached_add(a: i32, b: i32) -> i32 {
                a + b
            }
            """

            # Should still work
            result2 = @rust cached_add(Int32(15), Int32(25))::Int32
            @test result2 == 40
        end

        @testset "Cache Validation" begin
            code = """
            #[no_mangle]
            pub extern "C" fn validation_test() -> i32 { 100 }
            """

            compiler = RustCall.get_default_compiler()
            cache_key = RustCall.generate_cache_key(code, compiler)

            # Test validation with non-existent cache
            @test !RustCall.is_cache_valid(cache_key, code, compiler)

            # After compilation, cache should be valid
            rust"""
            #[no_mangle]
            pub extern "C" fn validation_test() -> i32 { 100 }
            """

            # The library is compiled from the extractor-expanded source
            wrapped_code = RustCall.wrap_rust_code(RustCall.expand_inline(code).source)
            cache_key = RustCall.generate_cache_key(wrapped_code, compiler)
            @test RustCall.is_cache_valid(cache_key, wrapped_code, compiler)
        end

        @testset "Cache Cleanup" begin
            # Test cleanup function exists and runs without error
            removed_count = RustCall.cleanup_old_cache(0)  # Remove all files older than 0 days
            @test removed_count >= 0

            # Test cache size
            cache_size = RustCall.get_cache_size()
            @test cache_size >= 0
        end

        @testset "Cache Clear" begin
            # Ensure we have some cache
            rust"""
            #[no_mangle]
            pub extern "C" fn clear_test() -> i32 { 999 }
            """

            cached_before = RustCall.list_cached_libraries()
            @test length(cached_before) > 0
            cache_size_before = RustCall.get_cache_size()

            # Clear cache
            RustCall.clear_cache()

            cached_after = RustCall.list_cached_libraries()
            cache_size_after = RustCall.get_cache_size()

            # On Windows, DLL files may be locked and cannot be deleted immediately
            # if they are currently loaded by Julia. Allow some files to remain.
            if Sys.iswindows()
                # On Windows, some files may remain locked
                # Check that at least some files were deleted
                @test length(cached_after) < length(cached_before) || length(cached_after) == 0
                @test cache_size_after < cache_size_before || cache_size_after == 0
            else
                # On Unix-like systems, all files should be deleted
                @test length(cached_after) == 0
                @test cache_size_after == 0
            end
        end
    else
        @warn "rustc not found, skipping cache integration tests"
    end
end
