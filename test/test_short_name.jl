using Test
using RustCall

# #504: a short id that names a path or a Cargo package is spelled and owned in
# one place, `src/short_name.jl`. For each such name, two full keys that share
# the prefix are forced together here, and their outputs must never mix: a
# persistent name refuses the second key, a reused one makes the two builds take
# turns from build start through copy-out.

const SN_K1 = "0123456789abcdef" * "1"^48
const SN_K2 = "0123456789abcdef" * "2"^48

_sn_src(file) = read(joinpath(pkgdir(RustCall), "src", file), String)

@testset "short names are a prefix of the full key, and keys do not move (#504)" begin
    @test RustCall.short_name(SN_K1) == first(SN_K1, RustCall.ARTIFACT_SHORT_ID_LEN)
    @test RustCall.short_name(SN_K1) == RustCall.short_name(SN_K2)
    @test RustCall.short_name(SN_K1; prefix = "p_", n = 12) == "p_0123456789ab"
    @test RustCall.short_name_path("/r", SN_K1; prefix = "x_") ==
          joinpath("/r", "x_0123456789abcdef")

    # The helper only spells keys; it computes none. Sample keys pinned from
    # before #504 — a helper that fed back into identity would move them.
    @test RustCall.artifact_key(RustCall.ArtifactId(kind = "rustc", source = "fn f() {}",
                                                    toolchain = "t", compiler = "c")) ==
          "e2a601ff6027c557899810935106cbb961f60b8559508c664c0a3ac54f2072e9"
    @test RustCall.artifact_key(RustCall.cargo_lockfile_id(RustCall.DependencySpec[])) ==
          "2404ffb20187763ca4bd1e7e81b6b34cc2d49e1238e55599a92d1f5860591e81"
    @test RustCall.cargo_block_package(RustCall.DependencySpec[]) == "rustcall_block_2404ffb20187"

    # ...and the on-disk layout is the one #495 shipped: the target directory's
    # name is the first 16 hex characters of the unchanged key.
    mktempdir() do root
        withenv("RUSTCALL_CACHE_DIR" => joinpath(root, "cache")) do
            crate = mkpath(joinpath(root, "crate"))
            key = RustCall.artifact_key(RustCall.crate_target_id(crate))
            @test length(key) == 64
            @test RustCall.crate_target_directory(crate) ==
                  joinpath(RustCall.get_cargo_cache_dir(), "targets", first(key, 16))
        end
    end
end

@testset "a persistent short name belongs to one full key (#504)" begin
    mktempdir() do root
        # A directory name: the record is inside it.
        dir = RustCall.short_name_path(root, SN_K1)
        @test dir == RustCall.short_name_path(root, SN_K2)
        @test RustCall.claim_short_name!(dir, SN_K1) === nothing
        @test read(joinpath(dir, RustCall.SHORT_NAME_KEY_FILE), String) == SN_K1
        @test RustCall.claim_short_name!(dir, SN_K1) === nothing
        @test_throws RustCall.RustError RustCall.claim_short_name!(dir, SN_K2; wait = 0)

        # A file stem: the record is beside it.
        stem = RustCall.short_name_path(root, SN_K1; prefix = "rust_", n = 12)
        @test RustCall.claim_short_name!(stem, SN_K1; stem = true) === nothing
        @test read(stem * ".rustcall-key", String) == SN_K1
        @test_throws RustCall.RustError RustCall.claim_short_name!(stem, SN_K2; stem = true, wait = 0)
    end

    # Claims that race: one owner, every other key refused, however many.
    mktempdir() do root
        dir = joinpath(root, "0123456789abcdef")
        keys = ["0123456789abcdef" * string(i; base = 16, pad = 48) for i in 1:24]
        outcome = Vector{Any}(undef, length(keys))
        tasks = [Threads.@spawn begin
                     try
                         RustCall.with_owned_short_name(dir, keys[i]; wait = 5) do
                             write(joinpath(dir, "out"), keys[i])
                         end
                         outcome[i] = :won
                     catch e
                         outcome[i] = e
                     end
                 end for i in eachindex(keys)]
        foreach(wait, tasks)
        winners = findall(==(:won), outcome)
        @test length(winners) == 1
        @test all(o -> o === :won || o isa RustCall.RustError, outcome)
        # The output under the name is the owner's and nobody else's.
        @test read(joinpath(dir, "out"), String) == keys[only(winners)]
    end

    # Two uses by the owning key take turns: no overlap from start to copy-out.
    mktempdir() do root
        dir = joinpath(root, "0123456789abcdef")
        inside = Threads.Atomic{Int}(0)
        overlap = Threads.Atomic{Bool}(false)
        copies = String[]
        tasks = [Threads.@spawn begin
                     RustCall.with_owned_short_name(dir, SN_K1; poll = 0.01) do
                         Threads.atomic_add!(inside, 1) == 0 || (overlap[] = true)
                         write(joinpath(dir, "out"), "build $(i)")
                         sleep(0.05)
                         push!(copies, read(joinpath(dir, "out"), String) == "build $(i)" ?
                                       "own" : "mixed")
                         Threads.atomic_sub!(inside, 1)
                     end
                 end for i in 1:6]
        foreach(wait, tasks)
        @test !overlap[]
        @test copies == fill("own", 6)
    end
end

# #507 review: a location with contents but no owner record — a PyO3 host cache
# entry written before #504 kept none — was claimed by whichever key asked
# first, which then found the old module in it: possibly built for another key
# that shares the short id. Such a location is foreign now: `:clear` empties it
# before recording the owner, `:refuse` raises, and only an empty or absent one
# is claimed as it stands.
@testset "an unrecorded location is never adopted (#507 review)" begin
    legacy!(dir) = (mkpath(dir); write(joinpath(dir, "ext.so"), "legacy"); dir)
    for key in (SN_K2, SN_K1)       # a colliding key, and the very key it had
        mktempdir() do cache
            dir = legacy!(RustCall.short_name_path(joinpath(cache, "pyo3-host"), SN_K1))
            seen = RustCall.with_owned_short_name(dir, key; foreign = :clear) do
                isfile(joinpath(dir, "ext.so"))
            end
            @test !seen
            @test read(joinpath(dir, RustCall.SHORT_NAME_KEY_FILE), String) == key

            dir2 = legacy!(joinpath(cache, "other", "0123456789abcdef"))
            @test_throws RustCall.RustError RustCall.claim_short_name!(dir2, key)
            @test isfile(joinpath(dir2, "ext.so"))
            @test !isfile(joinpath(dir2, RustCall.SHORT_NAME_KEY_FILE))
        end
    end
    # An empty or absent location is claimed as before.
    mktempdir() do root
        empty = mkpath(joinpath(root, "0123456789abcdef"))
        @test RustCall.claim_short_name!(empty, SN_K1) === nothing
        @test RustCall.claim_short_name!(joinpath(root, "fedcba9876543210"), SN_K1) === nothing
    end
    # Claimants racing on one unrecorded directory: one owner, its record
    # survives every other claimant's clearing, and the old contents are gone.
    mktempdir() do root
        dir = legacy!(joinpath(root, "0123456789abcdef"))
        keys = ["0123456789abcdef" * string(i; base = 16, pad = 48) for i in 1:16]
        outcome = Vector{Any}(undef, length(keys))
        tasks = [Threads.@spawn begin
                     try
                         RustCall.claim_short_name!(dir, keys[i]; foreign = :clear, wait = 5)
                         outcome[i] = :won
                     catch e
                         outcome[i] = e
                     end
                 end for i in eachindex(keys)]
        foreach(wait, tasks)
        winners = findall(==(:won), outcome)
        @test length(winners) == 1
        @test all(o -> o === :won || o isa RustCall.RustError, outcome)
        @test read(joinpath(dir, RustCall.SHORT_NAME_KEY_FILE), String) == keys[only(winners)]
        @test !isfile(joinpath(dir, "ext.so"))
    end
    # The PyO3 host path clears (its cache is RustCall's own).
    @test occursin("with_owned_short_name(artifact.dir, artifact.key; foreign = :clear",
                   _sn_src("pyo3_host.jl"))
    # A crate target directory without a record: emptied, then owned.
    mktempdir() do root
        withenv("RUSTCALL_CACHE_DIR" => joinpath(root, "cache")) do
            crate = mkpath(joinpath(root, "crate"))
            base = legacy!(RustCall.crate_target_directory(crate))
            @test RustCall._crate_target!(crate) == base
            @test !isfile(joinpath(base, "ext.so"))
            @test read(joinpath(base, RustCall.CRATE_TARGET_KEY_FILE), String) ==
                  RustCall.artifact_key(RustCall.crate_target_id(crate))
        end
    end
    # A debug stem: only the files of that name go; the rest of `debug_dir` stays.
    mktempdir() do debug_dir
        stem = joinpath(debug_dir, "rust_0123456789ab")
        write(stem * ".rs", "legacy")
        write(joinpath(debug_dir, "librust_0123456789ab.dylib"), "legacy")
        write(joinpath(debug_dir, "notes.txt"), "mine")
        write(joinpath(debug_dir, "rust_0123456789abcd.rs"), "another stem")
        @test RustCall.claim_short_name!(stem, SN_K1; stem = true, foreign = :clear) === nothing
        @test !isfile(stem * ".rs")
        @test !isfile(joinpath(debug_dir, "librust_0123456789ab.dylib"))
        @test read(joinpath(debug_dir, "notes.txt"), String) == "mine"
        @test isfile(joinpath(debug_dir, "rust_0123456789abcd.rs"))
        @test read(stem * ".rustcall-key", String) == SN_K1
    end
end

# #507 review, second round: a record, once created, is never among what `:clear`
# removes — on a file system without locking two claimants can both pass the
# re-check, and the second must not erase the first's record — and without
# locking `:clear` is refused outright.
@testset "a claim never deletes a record, and needs a lock to clear (#507 review)" begin
    mktempdir() do root
        # (1) Another claimant's record appears after the re-check: the listing
        # `:clear` works from leaves it (and every lock file) alone.
        dir = mkpath(joinpath(root, "0123456789abcdef"))
        write(joinpath(dir, "ext.so"), "legacy")
        write(joinpath(dir, RustCall.SHORT_NAME_KEY_FILE), SN_K1)
        touch(joinpath(dir, RustCall.SHORT_NAME_LOCK_FILE))
        @test RustCall._short_name_contents(dir, false) == [joinpath(dir, "ext.so")]
        stem = joinpath(root, "rust_0123456789ab")
        write(stem * ".rs", "legacy")
        write(stem * ".rustcall-key", SN_K1)
        touch(stem * ".rustcall-lock")
        @test RustCall._short_name_contents(stem, true) == [stem * ".rs"]
    end
    mktempdir() do root
        # A claimant whose lock returns while another records its key (the
        # re-check sees it): the other's record stands and this key is refused.
        dir = mkpath(joinpath(root, "0123456789abcdef"))
        write(joinpath(dir, "ext.so"), "legacy")
        racing(io) = (write(joinpath(dir, RustCall.SHORT_NAME_KEY_FILE), SN_K1); nothing)
        @test_throws RustCall.RustError RustCall.claim_short_name!(dir, SN_K2; foreign = :clear,
                                                                    wait = 0, try_lock = racing)
        @test read(joinpath(dir, RustCall.SHORT_NAME_KEY_FILE), String) == SN_K1
    end
    mktempdir() do root
        # (2) No locking at all: `:clear` degrades to `:refuse` for a location
        # with contents, naming the path; nothing is removed or recorded.
        nolock(io) = nothing
        dir = mkpath(joinpath(root, "0123456789abcdef"))
        write(joinpath(dir, "ext.so"), "legacy")
        err = try
            RustCall.claim_short_name!(dir, SN_K1; foreign = :clear, try_lock = nolock)
            nothing
        catch e
            e
        end
        @test err isa RustCall.RustError
        msg = sprint(showerror, err)
        @test occursin("no locking", msg) && occursin(dir, msg)
        @test isfile(joinpath(dir, "ext.so"))
        @test !isfile(joinpath(dir, RustCall.SHORT_NAME_KEY_FILE))
        # An empty or absent location is still claimed by the exclusive create.
        @test RustCall.claim_short_name!(joinpath(root, "fedcba9876543210"), SN_K1;
                                         foreign = :clear, try_lock = nolock) === nothing
        # With locking, the same location is cleared and claimed.
        @test RustCall.claim_short_name!(dir, SN_K1; foreign = :clear) === nothing
        @test !isfile(joinpath(dir, "ext.so"))
    end
end

@testset "crate target directory: a colliding crate is refused (#504)" begin
    mktempdir() do root
        withenv("RUSTCALL_CACHE_DIR" => joinpath(root, "cache")) do
            crate = mkpath(joinpath(root, "crate"))
            write(joinpath(crate, "Cargo.toml"), "[package]\nname = \"c504\"\nversion = \"0.1.0\"\n")
            key = RustCall.artifact_key(RustCall.crate_target_id(crate))
            other = first(key, 16) * (key[17] == '0' ? "1" : "0") * key[18:end]
            @test other != key && RustCall.short_name(other) == RustCall.short_name(key)
            # Another crate whose key shares the prefix owns the directory.
            base = RustCall.crate_target_directory(crate)
            RustCall.claim_short_name!(base, other)
            # Every flavour, and the probe's environment, refuses to build there.
            for flavour in (:direct, :pyo3_host, :pyo3_wrapper)
                @test_throws RustCall.RustError RustCall._crate_target!(crate, flavour)
            end
            @test_throws RustCall.RustError RustCall._wrapper_probe_env(Dict{String, String}(),
                                                                        crate, true, "")
            @test_throws RustCall.RustError RustCall._wrapper_shaped_project(crate, "p504")
            @test !isdir(RustCall.crate_target_directory(crate, :pyo3_host))
            @test !isdir(RustCall.crate_target_directory(crate, :pyo3_wrapper))
        end
    end
end

@testset "PyO3 host extension directory: a colliding key is refused (#504)" begin
    # `build_pyo3_extension` owns the short-named directory by the full key
    # before it looks inside, and holds its lock through the publish.
    src = _sn_src("pyo3_host.jl")
    @test occursin("dir = short_name_path(joinpath(String(cache_dir), \"pyo3-host\"), key)", src)
    held = findfirst("return with_owned_short_name(artifact.dir, artifact.key;", src)
    @test held !== nothing
    lookup = findnext("isfile(artifact.lib_path)", src, last(held))
    publish = findnext("_publish_cache_file(built, artifact.lib_path)", src, last(held))
    @test lookup !== nothing && publish !== nothing
    @test first(findfirst("function build_pyo3_extension(", src)) < first(held)

    # The same mechanism, with two keys forced onto one directory: the second
    # never sees the first one's module.
    mktempdir() do cache
        dir1 = RustCall.short_name_path(joinpath(cache, "pyo3-host"), SN_K1)
        dir2 = RustCall.short_name_path(joinpath(cache, "pyo3-host"), SN_K2)
        @test dir1 == dir2
        module_file = joinpath(dir1, "ext.so")
        RustCall.with_owned_short_name(dir1, SN_K1) do
            write(module_file, SN_K1)
        end
        seen = Ref(false)
        refused = try
            RustCall.with_owned_short_name(dir2, SN_K2; wait = 0) do
                seen[] = isfile(module_file)
            end
            nothing
        catch e
            e
        end
        @test refused isa RustCall.RustError
        @test !seen[]
        @test read(module_file, String) == SN_K1
    end
end

@testset "debug build files: colliding code is refused (#504)" begin
    mktempdir() do debug_dir
        compiler = RustCall.RustCompiler(debug_mode = true, debug_dir = debug_dir)
        code = "#[no_mangle]\npub extern \"C\" fn f504() -> i32 { 5 }\n"
        key = RustCall.stable_content_hash(code)
        name = RustCall._unique_source_name(code, compiler)
        @test name == RustCall.short_name(key; prefix = "rust_", n = RustCall.RECOVERY_FINGERPRINT_LEN)
        other = first(key, RustCall.RECOVERY_FINGERPRINT_LEN) * "0"^(length(key) - RustCall.RECOVERY_FINGERPRINT_LEN)
        other == key && (other = first(key, RustCall.RECOVERY_FINGERPRINT_LEN) * "1"^(length(key) - RustCall.RECOVERY_FINGERPRINT_LEN))
        # Code whose digest shares the prefix owns the name: refused before a
        # file of that name is written.
        write(joinpath(debug_dir, name) * ".rustcall-key", other)
        @test_throws RustCall.RustError RustCall.compile_rust_to_shared_lib(code; compiler = compiler)
        @test !isfile(joinpath(debug_dir, name * ".rs"))
        rm(joinpath(debug_dir, name) * ".rustcall-key")
        if RustCall.check_rustc_available()
            lib = RustCall.compile_rust_to_shared_lib(code; compiler = compiler)
            @test isfile(lib)
            @test startswith(basename(lib), "lib" * name)
            @test read(joinpath(debug_dir, name) * ".rustcall-key", String) == key
        else
            @test_skip "rustc is required to compile in debug mode"
        end
    end
end

@testset "the lint keeps short-id locations in src/short_name.jl (#504)" begin
    lint = joinpath(pkgdir(RustCall), "scripts", "lint_artifact_identity.sh")
    if Sys.iswindows() || Sys.which("bash") === nothing
        @test_skip "bash is required to run the lint"
    else
        @test success(pipeline(`bash $lint $(joinpath(pkgdir(RustCall), "src"))`;
                               stdout = devnull, stderr = devnull))
        mktempdir() do dir
            bad(text) = (write(joinpath(dir, "bad.jl"), text);
                         success(pipeline(`bash $lint $dir`; stdout = devnull, stderr = devnull)))
            # A short id in a path, unmarked or falsely marked, fails...
            @test !bad("p = joinpath(root, artifact_short_id(key))\n")
            @test !bad("p = joinpath(root, artifact_short_id(key)) # short-id: label\n")
            @test !bad("n = \"pkg_\$(artifact_short_id(key))\"\n")
            # ...a marked label passes, as does the helper itself.
            @test bad("n = \"rust_\$(artifact_short_id(key))\" # short-id: label\n")
            @test bad("p = short_name_path(root, key)\n")
        end
    end
end
