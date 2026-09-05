# Tests for the explicit load/compile policy object (issue #277, Phase A).
#
# Two halves:
#
#   1. the policy record and its named constructors, and
#   2. the *current divergences* between the front doors, asserted against the
#      shipped sources.  Phase A migrates no call site, so these tests pass on
#      today's `main`; when Phase B moves a door onto the shared loader, the
#      corresponding assertion here must be updated in the same PR.  That is
#      the point: the inconsistency is pinned down instead of implicit.

using Test
using RustCall
using Libdl

const _SRC_DIR = joinpath(dirname(dirname(pathof(RustCall))), "src")

_src(name) = read(joinpath(_SRC_DIR, name), String)

"""Number of non-overlapping occurrences of `needle` in the source of `name`."""
_count_in(name, needle) = count(_ -> true, eachmatch(needle, _src(name)))

@testset "LoadPolicy" begin

    @testset "record and defaults" begin
        p = RustCall.LoadPolicy("example")
        @test p.name == "example"
        @test p.dlopen_flags == UInt32(Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
        @test !RustCall.uses_global_symbols(p)
        @test p.panic_strategy === :abort
        @test p.cargo_profile === :release
        @test RustCall.registers_in_rust_libraries(p)
        @test p.registry_key_kind === :content_hash
        @test p.registration_mode === :replace
        @test !p.sets_current_lib
        @test RustCall.finalizer_frees(p)
        @test RustCall.dlopen_flags(p) == p.dlopen_flags
        @test occursin("LoadPolicy(example", sprint(show, p))

        g = RustCall.LoadPolicy("g"; dlopen_flags = Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW)
        @test RustCall.uses_global_symbols(g)

        @test_throws ArgumentError RustCall.LoadPolicy("bad"; panic_strategy = :terminate)
        @test_throws ArgumentError RustCall.LoadPolicy("bad"; registry = :somewhere)
        @test_throws ArgumentError RustCall.LoadPolicy("bad"; registry_key_kind = :nope)
        @test_throws ArgumentError RustCall.LoadPolicy("bad"; registration_mode = :upsert)
        # A non-RUST_LIBRARIES registry must not carry a RUST_LIBRARIES key kind.
        @test_throws ArgumentError RustCall.LoadPolicy("bad"; registry = :helper_slot,
                                                      registry_key_kind = :content_hash)
    end

    @testset "panic accessors" begin
        abort = RustCall.LoadPolicy("a"; panic_strategy = :abort)
        unwind = RustCall.LoadPolicy("u"; panic_strategy = :unwind)
        @test RustCall.rustc_panic_flags(abort) == ["-C", "panic=abort"]
        @test isempty(RustCall.rustc_panic_flags(unwind))
        @test RustCall.cargo_profile_panic_line(abort) == "panic = \"abort\""
        @test RustCall.cargo_profile_panic_line(unwind) === nothing
        @test !RustCall.requires_catch_unwind_boundary(abort)
        @test RustCall.requires_catch_unwind_boundary(unwind)
        @test !RustCall.requires_catch_unwind_boundary(
            RustCall.LoadPolicy("u2"; panic_strategy = :unwind,
                                boundary_catches_panics = true))
        @test RustCall.must_assume_unwind(unwind)
        @test !RustCall.must_assume_unwind(abort)
        @test RustCall.effective_panic_strategy(abort) === :abort
        @test RustCall.effective_panic_strategy(unwind) === :unwind

        # :cargo_default — RustCall drives Cargo but pins no `panic`, so the
        # result is Cargo's profile default AND the CARGO_PROFILE_<P>_PANIC
        # environment override, which the build inherits (#244).
        cd_policy = RustCall.LoadPolicy("cd"; panic_strategy = :cargo_default)
        @test RustCall.cargo_panic_env_var(cd_policy) == "CARGO_PROFILE_RELEASE_PANIC"
        @test RustCall.effective_panic_strategy(cd_policy; env = Dict()) === :unwind
        @test RustCall.effective_panic_strategy(
            cd_policy; env = Dict("CARGO_PROFILE_RELEASE_PANIC" => "abort")) === :abort
        @test RustCall.effective_panic_strategy(
            cd_policy; env = Dict("CARGO_PROFILE_RELEASE_PANIC" => "unwind")) === :unwind
        @test RustCall.effective_panic_strategy(
            cd_policy; env = Dict("CARGO_PROFILE_RELEASE_PANIC" => "")) === :unwind
        @test RustCall.requires_catch_unwind_boundary(cd_policy; env = Dict())
        @test !RustCall.requires_catch_unwind_boundary(
            cd_policy; env = Dict("CARGO_PROFILE_RELEASE_PANIC" => "abort"))
        @test RustCall.must_assume_unwind(cd_policy; env = Dict())
        @test !RustCall.must_assume_unwind(
            cd_policy; env = Dict("CARGO_PROFILE_RELEASE_PANIC" => "abort"))
        @test RustCall.rustc_panic_flags(cd_policy) === missing
        # The manifest pins nothing today — that is the bug Phase B fixes.
        @test RustCall.cargo_profile_panic_line(cd_policy) === nothing

        # A profile other than release picks the matching variable.
        dbg = RustCall.LoadPolicy("dbg"; panic_strategy = :cargo_default,
                                  cargo_profile = :dev)
        @test RustCall.cargo_panic_env_var(dbg) == "CARGO_PROFILE_DEV_PANIC"
        @test RustCall.effective_panic_strategy(
            dbg; env = Dict("CARGO_PROFILE_RELEASE_PANIC" => "abort")) === :unwind

        # :crate_profile — RustCall does not control the build, so the answer
        # is unknown rather than a guess. Phase B must read the effective
        # profile (`cargo metadata` / `cargo config get`) or force it (#244).
        crate = RustCall.LoadPolicy("c"; panic_strategy = :crate_profile)
        @test crate.panic_strategy === :crate_profile
        # Unchanged by the environment: the user's manifest can still pin it.
        @test RustCall.effective_panic_strategy(
            crate; env = Dict("CARGO_PROFILE_RELEASE_PANIC" => "abort")) === :crate_profile
        @test RustCall.rustc_panic_flags(crate) === missing
        @test RustCall.cargo_profile_panic_line(crate) === missing
        @test RustCall.requires_catch_unwind_boundary(crate) === missing
        # ...resolved conservatively: assume it can unwind.
        @test RustCall.must_assume_unwind(crate)
        @test !RustCall.must_assume_unwind(
            RustCall.LoadPolicy("c2"; panic_strategy = :crate_profile,
                                boundary_catches_panics = true))
        @test RustCall.requires_catch_unwind_boundary(
            RustCall.LoadPolicy("c3"; panic_strategy = :crate_profile,
                                boundary_catches_panics = true)) === false
    end

    @testset "named constructors cover every front door" begin
        @test length(RustCall.ALL_LOAD_POLICIES) == 9
        names = String[]
        for ctor in RustCall.ALL_LOAD_POLICIES
            p = ctor()
            @test p isa RustCall.LoadPolicy
            @test !isempty(p.name)
            @test !isempty(p.call_sites)      # every policy names what it subsumes
            @test !isempty(p.issues)
            push!(names, p.name)
        end
        @test length(unique(names)) == length(names)
        # The doors Phase B swaps over first. There is deliberately no
        # separate "cache hit" policy: the cache state does not change any of
        # the four decisions (see the #250 testset below).
        @test Set(["inline-rustc", "inline-cargo", "rust-crate-direct",
                   "rust-crate-wrapper", "helper-library"]) ⊆ Set(names)
        @test !("cache-hit" in names)
        @test !isdefined(RustCall, :cache_hit_policy)
    end

    # -----------------------------------------------------------------
    # Divergence 1: dlopen flags (#250)
    #
    # The axis is whether the block declares `// cargo-deps:`, NOT the cache
    # state: a dependency-free inline block is RTLD_LOCAL on both a disk-cache
    # hit (src/cache.jl:270) and a miss (src/ruststr.jl:284), while a
    # Cargo-backed block is RTLD_GLOBAL on both its cache hit
    # (src/ruststr.jl:386) and its fresh build (:419). So the same
    # user-visible construct publishes its symbols process-globally or not
    # depending only on whether it happens to name a dependency.
    # -----------------------------------------------------------------
    @testset "divergence: dlopen flags (#250)" begin
        local_sites = 0
        global_sites = 0
        for file in readdir(_SRC_DIR)
            endswith(file, ".jl") || continue
            file == "loadpolicy.jl" && continue
            src = _src(file)
            local_sites += count(_ -> true, eachmatch(r"dlopen\([^)]*RTLD_LOCAL", src))
            global_sites += count(_ -> true, eachmatch(r"dlopen\([^)]*RTLD_GLOBAL", src))
        end
        # B0 moved the two inline doors (direct rustc and Cargo) onto
        # `load_artifact!`, which reads the flags off the policy. What is left
        # open-coded: @irust, generics, hot reload, the two @rust_crate
        # templates, the helper library (2) and the deprecated LLVM path.
        @test local_sites == 2
        @test global_sites == 6
        @test local_sites + global_sites == 8

        # The inline doors no longer name a flag at all: cache.jl hands back a
        # path and ruststr.jl calls the loader.
        cache_src = _src("cache.jl")
        @test !occursin(r"dlopen\(", cache_src)
        ruststr_src = _src("ruststr.jl")
        @test count(_ -> true, eachmatch(r"dlopen\([^)]*RTLD_LOCAL", ruststr_src)) == 0
        @test count(_ -> true, eachmatch(r"dlopen\([^)]*RTLD_GLOBAL", ruststr_src)) == 1

        # One policy per axis value, each covering both cache states.
        rustc_policy = RustCall.inline_rustc_policy()
        cargo_policy = RustCall.inline_cargo_policy()
        @test !RustCall.uses_global_symbols(rustc_policy)
        @test RustCall.uses_global_symbols(cargo_policy)
        @test "src/cache.jl:270" in rustc_policy.call_sites      # cache hit
        @test "src/ruststr.jl:284" in rustc_policy.call_sites    # cache miss
        @test "src/ruststr.jl:386" in cargo_policy.call_sites    # cache hit
        @test "src/ruststr.jl:419" in cargo_policy.call_sites    # fresh build
        # ...and the rule is inverted: the helper library, the one library
        # other artifacts could resolve against, is the LOCAL one.
        @test !RustCall.uses_global_symbols(RustCall.helper_library_policy())
        @test RustCall.uses_global_symbols(RustCall.crate_direct_policy())
        @test RustCall.uses_global_symbols(RustCall.crate_wrapper_policy())
        @test occursin("RTLD_GLOBAL", RustCall.SYMBOL_VISIBILITY_RULE)
    end

    # -----------------------------------------------------------------
    # Divergence 2: panic strategy and the missing boundary (#244)
    #
    # `-C panic=abort` is passed on the direct-rustc path only; the generated
    # Cargo project sets no panic mode, and there is no catch_unwind anywhere,
    # so a panic crossing extern "C" on the Cargo path is undefined behaviour.
    # -----------------------------------------------------------------
    @testset "divergence: panic strategy (#244)" begin
        @test _count_in("compiler.jl", r"panic=abort") == 2
        @test !occursin("panic", _src("cargoproject.jl"))

        repo = dirname(_SRC_DIR)
        catch_unwind_hits = String[]
        for root in (joinpath(repo, "src"), joinpath(repo, "deps"))
            isdir(root) || continue
            for (dir, _, files) in walkdir(root)
                occursin(Base.Filesystem.path_separator * "target" *
                         Base.Filesystem.path_separator, dir * Base.Filesystem.path_separator) && continue
                for f in files
                    (endswith(f, ".jl") || endswith(f, ".rs")) || continue
                    f == "loadpolicy.jl" && continue   # this file only names the fix
                    path = joinpath(dir, f)
                    occursin("catch_unwind", read(path, String)) && push!(catch_unwind_hits, path)
                end
            end
        end
        # No FFI boundary contains a panic today (#244).
        @test isempty(catch_unwind_hits)

        @test RustCall.inline_rustc_policy().panic_strategy === :abort

        # The two Cargo-backed doors RustCall itself drives pin no `panic`, so
        # they take Cargo's release default — and the CARGO_PROFILE_RELEASE_PANIC
        # override. src/cargobuild.jl runs `cargo build` with the inherited
        # environment unless a captured snapshot is replayed (#272 added the
        # `env === nothing || setenv` branch); deps/build.jl always inherits.
        # Same source, different artifact depending on the caller's env (#244).
        @test occursin("env === nothing || (cmd = setenv(cmd, env))", _src("cargobuild.jl"))
        for policy in (RustCall.inline_cargo_policy(), RustCall.helper_library_policy())
            @test policy.panic_strategy === :cargo_default
            @test policy.cargo_profile === :release
            @test RustCall.cargo_panic_env_var(policy) == "CARGO_PROFILE_RELEASE_PANIC"
            @test RustCall.effective_panic_strategy(policy; env = Dict()) === :unwind
            @test RustCall.effective_panic_strategy(
                policy; env = Dict("CARGO_PROFILE_RELEASE_PANIC" => "abort")) === :abort
            @test RustCall.must_assume_unwind(policy; env = Dict())
        end
        # ...while the direct-rustc door pins -C panic=abort and is unaffected.
        @test RustCall.effective_panic_strategy(
            RustCall.inline_rustc_policy();
            env = Dict("CARGO_PROFILE_RELEASE_PANIC" => "unwind")) === :abort
        @test !RustCall.must_assume_unwind(
            RustCall.inline_rustc_policy();
            env = Dict("CARGO_PROFILE_RELEASE_PANIC" => "unwind"))
        # Both cargo-backed doors really do build --release.
        @test occursin("release=true", _src("ruststr.jl"))

        # @rust_crate has TWO build paths with different panic semantics,
        # chosen by crate_has_cdylib: the direct build runs Cargo with the
        # USER's manifest as the root (src/crate_bindings.jl:852, :914-925), so
        # their [profile.release] wins -> :crate_profile; the wrapper build
        # (:854-868) makes RustCall's generated manifest the root, and that one
        # sets only opt-level/lto (:266-269) -> :cargo_default. Hot reload
        # rebuilds the user's manifest (src/hot_reload.jl:264) -> :crate_profile.
        crate_src = _src("crate_bindings.jl")
        @test occursin("build_cargo_project(project, release=release)", crate_src)
        @test occursin("build_cargo_project(wrapper_project, release=build_release)", crate_src)
        @test occursin("\"[profile.release]\"", crate_src)
        @test !occursin("panic", crate_src)
        @test occursin("cargo build --release --manifest-path", _src("hot_reload.jl"))

        @test RustCall.crate_direct_policy().panic_strategy === :crate_profile
        @test RustCall.crate_wrapper_policy().panic_strategy === :cargo_default
        @test RustCall.hot_reload_policy().panic_strategy === :crate_profile
        @test RustCall.requires_catch_unwind_boundary(
            RustCall.crate_direct_policy()) === missing
        @test RustCall.requires_catch_unwind_boundary(
            RustCall.crate_wrapper_policy(); env = Dict()) === true
        @test RustCall.effective_panic_strategy(
            RustCall.crate_wrapper_policy();
            env = Dict("CARGO_PROFILE_RELEASE_PANIC" => "abort")) === :abort
        @test RustCall.must_assume_unwind(RustCall.crate_direct_policy())
        @test RustCall.must_assume_unwind(RustCall.hot_reload_policy())
        # The two @rust_crate doors disagree with each other (#244).
        @test RustCall.crate_direct_policy().panic_strategy !==
              RustCall.crate_wrapper_policy().panic_strategy
        # Everything except the panic strategy is shared between them.
        for f in (:dlopen_flags, :registry, :registry_key_kind, :registration_mode,
                  :sets_current_lib, :finalizer_frees)
            @test getfield(RustCall.crate_direct_policy(), f) ==
                  getfield(RustCall.crate_wrapper_policy(), f)
        end

        # Fourth unwinding path: the ownership helper library. deps/build.jl
        # builds it with a plain `cargo build --release` and
        # deps/rust_helpers/Cargo.toml declares no [profile.release] / panic
        # key, so Cargo's unwind default applies (#244).
        repo_root = dirname(_SRC_DIR)
        build_jl = read(joinpath(repo_root, "deps", "build.jl"), String)
        helpers_toml = read(joinpath(repo_root, "deps", "rust_helpers", "Cargo.toml"), String)
        @test occursin("build --release --manifest-path", build_jl)
        @test !occursin("panic", build_jl)
        @test !occursin("panic", helpers_toml)
        @test !occursin("[profile", helpers_toml)
        @test RustCall.helper_library_policy().panic_strategy === :cargo_default
        @test RustCall.requires_catch_unwind_boundary(
            RustCall.helper_library_policy(); env = Dict())
        # The two inline doors disagree, which is exactly what #244 asks to fix.
        @test RustCall.effective_panic_strategy(RustCall.inline_rustc_policy();
                                                env = Dict()) !==
              RustCall.effective_panic_strategy(RustCall.inline_cargo_policy();
                                                env = Dict())
        @test RustCall.requires_catch_unwind_boundary(
            RustCall.inline_cargo_policy(); env = Dict())
        @test !RustCall.requires_catch_unwind_boundary(RustCall.inline_rustc_policy())
    end

    # -----------------------------------------------------------------
    # Divergence 3: registration in RUST_LIBRARIES (#250, #251, #255)
    # -----------------------------------------------------------------
    @testset "divergence: registration sites (#250, #255)" begin
        writes = 0
        for file in readdir(_SRC_DIR)
            endswith(file, ".jl") || continue
            file == "loadpolicy.jl" && continue
            writes += count(_ -> true,
                            eachmatch(r"RUST_LIBRARIES\[[^\]]*\]\s*=", _src(file)))
        end
        # B0 moved `_register_manifest` onto `load_artifact!`, so the inline
        # doors write nothing themselves. Four open-coded sites remain: the
        # `@irust` loader in ruststr.jl, generics.jl, hot_reload.jl, and the
        # reload alias that #272 added in rustmacro.jl.
        @test writes == 4

        # Each site decides for itself whether CURRENT_LIB moves and what the
        # key looks like; the policies record that disagreement.
        @test RustCall.inline_rustc_policy().sets_current_lib
        @test RustCall.inline_cargo_policy().sets_current_lib
        @test !RustCall.generics_policy().sets_current_lib
        @test !RustCall.irust_policy().sets_current_lib
        @test !RustCall.hot_reload_policy().sets_current_lib

        @test RustCall.generics_policy().registry_key_kind === :content_hash
        @test RustCall.irust_policy().registry_key_kind === :irust_hash
        @test RustCall.hot_reload_policy().registry_key_kind === :crate_lib_name
        @test RustCall.inline_rustc_policy().registry_key_kind === :content_hash

        # Two doors bypass RUST_LIBRARIES entirely, so registry-level unload
        # cannot see them (#250).
        @test !RustCall.registers_in_rust_libraries(RustCall.crate_direct_policy())
        @test !RustCall.registers_in_rust_libraries(RustCall.crate_wrapper_policy())
        @test !RustCall.registers_in_rust_libraries(RustCall.helper_library_policy())
        @test !RustCall.registers_in_rust_libraries(RustCall.llvm_policy())

        # The hot-reload rebuild happens outside REGISTRY_LOCK (#255).
        @test occursin("outside REGISTRY_LOCK", _src("hot_reload.jl"))

        # Generics registers only when the key is absent, and that guard is
        # load-bearing: _unique_source_name returns the fixed base name
        # "rust_code" outside debug mode (src/compiler.jl:68-72), so every
        # instantiation collides on the same librust_code basename. An
        # unconditional assignment would swap the live handle and discard the
        # function-pointer cache filled at src/generics.jl:267 (#250).
        @test occursin("return \"rust_code\"", _src("compiler.jl"))
        @test occursin("if !haskey(RUST_LIBRARIES, lib_name)", _src("generics.jl"))
        @test RustCall.generics_policy().registration_mode === :insert_only
        for ctor in RustCall.ALL_LOAD_POLICIES
            p = ctor()
            p.name == "generics-monomorphization" && continue
            @test p.registration_mode === :replace
        end
    end

    @testset "register_library! is a locked transaction" begin
        policy = RustCall.LoadPolicy("test-registration"; sets_current_lib = true)
        name = "loadpolicy_test_lib_$(getpid())"
        handle = Ptr{Cvoid}(UInt(0xdead0000))   # never dlsym'd; registry bookkeeping only
        previous = RustCall.CURRENT_LIB[]
        try
            @test RustCall.register_library!(policy, name, handle) == name
            entry = lock(RustCall.REGISTRY_LOCK) do
                RustCall.RUST_LIBRARIES[name]
            end
            @test entry[1] == handle
            @test isempty(entry[2])                     # fresh function-pointer cache
            @test RustCall.CURRENT_LIB[] == name
            @test RustCall.unregister_library!(policy, name)
            @test !haskey(RustCall.RUST_LIBRARIES, name)
            @test RustCall.CURRENT_LIB[] == ""
            @test !RustCall.unregister_library!(policy, name)  # idempotent
            @test_throws ArgumentError RustCall.register_library!(policy, name, C_NULL)

            # Policies that do not use RUST_LIBRARIES are a no-op, so a Phase B
            # call site may call register_library! unconditionally.
            @test RustCall.register_library!(RustCall.crate_direct_policy(), name, handle) == name
            @test !haskey(RustCall.RUST_LIBRARIES, name)
            @test !RustCall.unregister_library!(RustCall.crate_direct_policy(), name)

            # :insert_only keeps the existing handle and its function-pointer
            # cache; :replace overwrites both (#250, src/generics.jl:250-253).
            insert_only = RustCall.LoadPolicy("test-insert-only";
                                              registration_mode = :insert_only)
            other = Ptr{Cvoid}(UInt(0xbeef0000))
            RustCall.register_library!(policy, name, handle)
            lock(RustCall.REGISTRY_LOCK) do
                RustCall.RUST_LIBRARIES[name][2]["cached_symbol"] = handle
            end
            RustCall.register_library!(insert_only, name, other)
            kept = lock(RustCall.REGISTRY_LOCK) do
                RustCall.RUST_LIBRARIES[name]
            end
            @test kept[1] == handle                       # existing handle kept
            @test haskey(kept[2], "cached_symbol")        # and its symbol cache

            RustCall.register_library!(policy, name, other)   # :replace
            replaced = lock(RustCall.REGISTRY_LOCK) do
                RustCall.RUST_LIBRARIES[name]
            end
            @test replaced[1] == other
            @test isempty(replaced[2])
            RustCall.unregister_library!(policy, name)

            # :insert_only on an absent key still inserts.
            @test RustCall.register_library!(insert_only, name, other) == name
            @test lock(() -> RustCall.RUST_LIBRARIES[name][1], RustCall.REGISTRY_LOCK) == other
            RustCall.unregister_library!(insert_only, name)
        finally
            lock(RustCall.REGISTRY_LOCK) do
                delete!(RustCall.RUST_LIBRARIES, name)
            end
            RustCall.CURRENT_LIB[] = previous
        end
    end

    # -----------------------------------------------------------------
    # Divergence 4: finalizer / ownership policy (#249, #252)
    #
    # Inline #[julia] struct objects never free ("Temporarily disabled free to
    # diagnose segfault"); @rust_crate struct objects call <Name>_free.
    # Same user-visible construct, opposite lifetime semantics.
    # -----------------------------------------------------------------
    @testset "divergence: finalizers (#249, #252)" begin
        structs_src = _src("structs.jl")
        @test _count_in("structs.jl", r"Finalizer: skipped free") == 2
        @test occursin("Temporarily disabled free", structs_src)

        crate_src = _src("crate_bindings.jl")
        @test occursin("_free", crate_src)
        @test occursin("finalizer(obj)", crate_src)

        @test !RustCall.finalizer_frees(RustCall.inline_rustc_policy())
        @test !RustCall.finalizer_frees(RustCall.inline_cargo_policy())
        @test RustCall.finalizer_frees(RustCall.crate_direct_policy())
        @test RustCall.finalizer_frees(RustCall.crate_wrapper_policy())
        @test RustCall.finalizer_frees(RustCall.inline_rustc_policy()) !==
              RustCall.finalizer_frees(RustCall.crate_direct_policy())
    end

    # -----------------------------------------------------------------
    # Phase B migration front: which doors already go through the loader.
    #
    # Phase A was additive; every commit of Phase B moves one more door onto
    # `load_artifact!` and shrinks this allow-list. When it is empty the
    # `Libdl.dlopen` lint (scripts/lint_load_path.sh) is what keeps it that
    # way.
    # -----------------------------------------------------------------
    @testset "Phase B: migrated doors go through loadpolicy.jl" begin
        migrated = ("ruststr.jl", "cache.jl")
        for file in readdir(_SRC_DIR)
            endswith(file, ".jl") || continue
            file in ("loadpolicy.jl", "RustCall.jl") && continue
            src = _src(file)
            if file in migrated
                continue
            end
            @test !occursin("load_artifact!(", src)
        end
        # ...and the migrated ones really do.
        @test occursin("load_artifact!(", _src("ruststr.jl"))
        @test occursin("inline_rustc_policy()", _src("ruststr.jl"))
        @test occursin("inline_cargo_policy()", _src("ruststr.jl"))
    end

    @testset "load_artifact! / unload_artifact! / alias_artifact!" begin
        policy = RustCall.LoadPolicy("test-loader"; sets_current_lib = true)
        name = "loadpolicy_loader_test_$(getpid())"
        alias = name * "_alias"
        handle = Ptr{Cvoid}(UInt(0xfeed0000))
        previous = RustCall.CURRENT_LIB[]
        try
            a = RustCall.adopt_artifact!(policy, handle; lib_name = name,
                                         symbols = ["f" => "rustcall_f"],
                                         return_types = ["f" => Int32])
            @test a isa RustCall.LoadedArtifact
            @test a.handle == handle
            @test a.alive[]
            @test RustCall.CURRENT_LIB[] == name
            @test RustCall.exported_symbol(name, "f") == "rustcall_f"
            @test RustCall.get_function_return_type(name, "f") === Int32
            @test occursin("LoadedArtifact(", sprint(show, a))

            # The alias shares the handle, gets its own metadata rows, and
            # shares the liveness flag.
            @test RustCall.alias_artifact!(policy, name, alias)
            @test RustCall.exported_symbol(alias, "f") == "rustcall_f"
            @test RustCall.artifact_alive_ref(alias) === a.alive

            # A :replace registration retires the previous artifact.
            other = Ptr{Cvoid}(UInt(0xf00d0000))
            b = RustCall.adopt_artifact!(policy, other; lib_name = name)
            @test !a.alive[]
            @test b.alive[]
            @test RustCall.exported_symbol(name, "f") == "f"   # metadata replaced

            # :insert_only keeps the incumbent and reports it.
            insert_only = RustCall.LoadPolicy("test-loader-insert";
                                              registration_mode = :insert_only)
            c = RustCall.adopt_artifact!(insert_only, handle; lib_name = name)
            @test c.handle == other
            @test c.alive === b.alive

            @test RustCall.unload_artifact!(policy, name; dlclose = false)
            @test !b.alive[]
            @test RustCall.CURRENT_LIB[] == ""
            @test !RustCall.unload_artifact!(policy, name; dlclose = false)
            @test_throws ArgumentError RustCall.adopt_artifact!(policy, C_NULL;
                                                               lib_name = name)
            @test_throws ArgumentError RustCall.adopt_artifact!(policy, handle;
                                                               lib_name = name,
                                                               on_replace = :burn)
        finally
            lock(RustCall.REGISTRY_LOCK) do
                delete!(RustCall.RUST_LIBRARIES, name)
                delete!(RustCall.RUST_LIBRARIES, alias)
                delete!(RustCall.ARTIFACT_ALIVE, name)
                delete!(RustCall.ARTIFACT_ALIVE, alias)
            end
            RustCall.CURRENT_LIB[] = previous
        end
    end
end
