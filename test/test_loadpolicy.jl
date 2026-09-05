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

@testset verbose=true "LoadPolicy" begin

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
        # Both pinned strategies state themselves, at the compile site and in
        # the manifest: `unwind` is Cargo's and rustc's default, but a default
        # is not a pin, and an inherited CARGO_PROFILE_RELEASE_PANIC would
        # otherwise decide it (#244).
        @test RustCall.rustc_panic_flags(abort) == ["-C", "panic=abort"]
        @test RustCall.rustc_panic_flags(unwind) == ["-C", "panic=unwind"]
        @test RustCall.cargo_profile_panic_line(abort) == "panic = \"abort\""
        @test RustCall.cargo_profile_panic_line(unwind) == "panic = \"unwind\""
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
        # B1 finished the migration: every door reads its flags off its
        # policy. What is left open-coded outside loadpolicy.jl is the
        # deprecated LLVM path (#265 Phase 2 deletes it) and the two
        # @rust_crate module templates, whose dlopen runs in the *generated*
        # module (B5 routes them through the loader too).
        @test local_sites == 0
        @test global_sites == 3
        for file in ("cache.jl", "ruststr.jl", "generics.jl", "hot_reload.jl",
                     "memory.jl", "rustmacro.jl")
            @test !occursin(r"dlopen\(", _src(file))
        end
        # ...and scripts/lint_load_path.sh is what keeps it that way.
        lint = read(joinpath(dirname(_SRC_DIR), "scripts", "lint_load_path.sh"), String)
        @test occursin("Libdl", lint)
        @test occursin("loadpolicy", lint)

        # B2: the axis is gone. Every policy is RTLD_LOCAL | RTLD_NOW, so the
        # same rust""" construct behaves the same whether or not it names a
        # dependency (#250).
        for ctor in RustCall.ALL_LOAD_POLICIES
            p = ctor()
            @test !RustCall.uses_global_symbols(p)
            @test p.dlopen_flags == UInt32(Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
        end
        @test occursin("RTLD_LOCAL", RustCall.SYMBOL_VISIBILITY_RULE)
        # The rule now says the GLOBAL category is empty, and says why.
        @test occursin("dlsym", RustCall.SYMBOL_VISIBILITY_RULE)
    end

    # -----------------------------------------------------------------
    # The deprecated RTLD_GLOBAL escape hatch (#250, one release).
    # -----------------------------------------------------------------
    @testset "RUSTCALL_DLOPEN_GLOBAL escape hatch" begin
        policy = RustCall.inline_rustc_policy()
        previous = RustCall.DLOPEN_GLOBAL_OVERRIDE[]
        try
            @test !RustCall._init_dlopen_global_override!(Dict{String, String}())
            @test RustCall.dlopen_flags(policy) == policy.dlopen_flags

            @test RustCall._init_dlopen_global_override!(
                Dict("RUSTCALL_DLOPEN_GLOBAL" => "1"))
            # One warning, naming the issue, then silence.
            flags = @test_logs (:warn, r"RUSTCALL_DLOPEN_GLOBAL") match_mode = :any begin
                RustCall.dlopen_flags(policy)
            end
            @test flags == policy.dlopen_flags | UInt32(Libdl.RTLD_GLOBAL)
            @test RustCall.dlopen_flags(policy) == flags   # no second warning
            # The *policy* still says LOCAL: the override is not a policy.
            @test !RustCall.uses_global_symbols(policy)

            # Only an affirmative value turns it on.
            @test !RustCall._init_dlopen_global_override!(
                Dict("RUSTCALL_DLOPEN_GLOBAL" => "0"))
            @test !RustCall._init_dlopen_global_override!(
                Dict("RUSTCALL_DLOPEN_GLOBAL" => ""))
        finally
            RustCall._init_dlopen_global_override!(Dict{String, String}())
            RustCall.DLOPEN_GLOBAL_OVERRIDE[] = previous
        end
    end

    # Symbols of a LOCAL artifact are reachable through its handle and NOT
    # through the process-global namespace. Windows `LoadLibrary` has no such
    # distinction, so the negative half is unix-only.
    @testset "RTLD_LOCAL keeps symbols out of the global namespace" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required to build a library to load"
        else
            lib = RustCall.compile_rust_to_shared_lib("""
                #[no_mangle]
                pub extern "C" fn rustcall_visibility_probe() -> i32 { 7 }
                """)
            name = "loadpolicy_visibility_$(getpid())"
            policy = RustCall.inline_rustc_policy()
            try
                a = RustCall.load_artifact!(policy, lib; lib_name = name)
                # Through its own handle: always.
                ptr = Libdl.dlsym(a.handle, "rustcall_visibility_probe")
                @test RustCall.call_rust_function(ptr, Int32) == Int32(7)
                # Through the process-global namespace: not on unix.
                # RTLD_DEFAULT is NULL on glibc/musl and (void *)-2 on Darwin.
                # Windows `LoadLibrary` has no LOCAL/GLOBAL distinction at all,
                # so there is nothing to assert there.
                if Sys.isunix()
                    rtld_default = Sys.isapple() ? Ptr{Cvoid}(-2) : C_NULL
                    found = ccall(:dlsym, Ptr{Cvoid}, (Ptr{Cvoid}, Cstring),
                                  rtld_default, "rustcall_visibility_probe")
                    @test found == C_NULL
                end
            finally
                RustCall.unload_artifact!(policy, name)
            end
        end
    end

    # -----------------------------------------------------------------
    # #244: one panic strategy, and a boundary that catches.
    #
    # Before B3 the direct-rustc path passed `-C panic=abort` (a panic killed
    # the session outright), the Cargo path took Cargo's default and could be
    # flipped by an environment variable, and there was no `catch_unwind`
    # anywhere. Now every door RustCall owns is pinned to `unwind` — twice: in
    # the manifest and in the environment Cargo runs under — and the single
    # wrapper generator catches, records the message in a per-wrapper channel
    # and returns a sentinel, so Julia raises `RustPanicError`.
    # -----------------------------------------------------------------
    @testset "panic: pinned unwind and a catching boundary (#244)" begin
        # The rustc path no longer hard-codes a strategy: it asks the policy.
        @test _count_in("compiler.jl", r"panic=abort") == 0
        @test _count_in("compiler.jl", r"rustc_panic_flags\(inline_rustc_policy\(\)\)") == 2

        # Every RustCall-owned door: pinned unwind, boundary catches.
        owned = (RustCall.inline_rustc_policy(), RustCall.inline_cargo_policy(),
                 RustCall.crate_wrapper_policy(), RustCall.helper_library_policy(),
                 RustCall.generics_policy())
        for policy in owned
            @test policy.panic_strategy === :unwind
            @test RustCall.effective_panic_strategy(policy) === :unwind
            # ...and an inherited CARGO_PROFILE_RELEASE_PANIC cannot change it.
            @test RustCall.effective_panic_strategy(
                policy; env = Dict("CARGO_PROFILE_RELEASE_PANIC" => "abort")) === :unwind
        end
        for policy in owned
            policy.name == "irust" && continue
            @test policy.boundary_catches_panics
            @test !RustCall.requires_catch_unwind_boundary(policy)
            @test !RustCall.must_assume_unwind(policy)
        end

        # PARITY: the two inline doors agree, which is the acceptance criterion
        # "panic behavior is identical regardless of which compile path
        # produced the library".
        rustc_policy = RustCall.inline_rustc_policy()
        cargo_policy = RustCall.inline_cargo_policy()
        @test rustc_policy.panic_strategy === cargo_policy.panic_strategy
        @test RustCall.rustc_panic_flags(rustc_policy) ==
              RustCall.rustc_panic_flags(cargo_policy)
        @test RustCall.cargo_profile_panic_line(rustc_policy) ==
              RustCall.cargo_profile_panic_line(cargo_policy)
        @test RustCall.effective_panic_strategy(rustc_policy; env = Dict()) ===
              RustCall.effective_panic_strategy(cargo_policy; env = Dict())
        @test rustc_policy.boundary_catches_panics ==
              cargo_policy.boundary_catches_panics

        # The manifests RustCall writes pin it; the environment it passes to
        # Cargo pins it again.
        @test occursin("cargo_profile_panic_line(inline_cargo_policy())",
                       _src("cargoproject.jl"))
        @test occursin("cargo_profile_panic_line(crate_wrapper_policy())",
                       _src("crate_bindings.jl"))
        @test occursin("_cargo_panic_env", _src("cargobuild.jl"))
        @test occursin("build_env === nothing || (cmd = setenv(cmd, build_env))",
                       _src("cargobuild.jl"))
        env = RustCall._cargo_panic_env(cargo_policy, Dict("A" => "b"), true)
        @test env["CARGO_PROFILE_RELEASE_PANIC"] == "unwind"
        @test env["A"] == "b"
        @test RustCall._cargo_panic_env(cargo_policy, Dict{String, String}(), false)[
            "CARGO_PROFILE_DEV_PANIC"] == "unwind"
        # A user crate's own profile is not overridden from the outside.
        @test RustCall._cargo_panic_env(RustCall.crate_direct_policy(), nothing, true) === nothing

        repo_root = dirname(_SRC_DIR)
        build_jl = read(joinpath(repo_root, "deps", "build.jl"), String)
        helpers_toml = read(joinpath(repo_root, "deps", "rust_helpers", "Cargo.toml"), String)
        @test occursin("CARGO_PROFILE_RELEASE_PANIC", build_jl)
        @test occursin("panic = \"unwind\"", helpers_toml)

        # The two @rust_crate build paths now agree on everything the panic
        # boundary depends on; only the *strategy* of a user crate stays
        # unknown, because their manifest decides it.
        @test RustCall.crate_direct_policy().panic_strategy === :crate_profile
        @test RustCall.hot_reload_policy().panic_strategy === :crate_profile
        for p in (RustCall.crate_direct_policy(), RustCall.hot_reload_policy())
            @test p.boundary_catches_panics
            @test RustCall.requires_catch_unwind_boundary(p) === false
            @test !RustCall.must_assume_unwind(p)
        end

        # The boundary exists: exactly one generator emits it, and it emits the
        # channel next to it.
        codegen_rs = read(joinpath(repo_root, "deps", "rustcall_core", "src", "codegen.rs"), String)
        @test occursin("catch_unwind", codegen_rs)
        @test occursin("AssertUnwindSafe", codegen_rs)
        @test occursin("PANIC_SYMBOL_SUFFIX", codegen_rs)
        # ...in `generate_wrapper`, and nowhere else in src/.
        @test _count_in("codegen.jl", r"catch_unwind") == 0

        # The Julia half of the channel.
        @test RustCall.ffi_panic_symbol("rustcall_f") == "rustcall_f_take_panic"
        @test RustCall.take_rust_panic(C_NULL) === nothing
        @test RustCall.check_rust_panic("no_such_lib", "no_such_symbol") === nothing
        e = RustCall.RustPanicError("f", "boom")
        @test e isa Exception
        @test occursin("boom", sprint(showerror, e))
        @test occursin("f", sprint(showerror, e))
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
        # Every door goes through the loader now: nothing outside
        # loadpolicy.jl writes RUST_LIBRARIES.
        @test writes == 0

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

        # The hot-reload registry transaction is `load_artifact!`'s, and the
        # rebuild that precedes it holds no registry lock — see the #255
        # testset below.

        # Generics registers only when the key is absent, and that guard is
        # load-bearing: _unique_source_name returns the fixed base name
        # "rust_code" outside debug mode (src/compiler.jl:68-72), so every
        # instantiation compiles into its own temp directory under the same
        # librust_code basename. An unconditional assignment would swap a live
        # handle and discard the function-pointer cache (#250). Since B1 the
        # guard is `generics_policy()`'s registration mode rather than an
        # open-coded `if !haskey(...)`, and `load_artifact!` closes the loser's
        # duplicate handle instead of leaking it.
        @test occursin("return \"rust_code\"", _src("compiler.jl"))
        @test occursin("generics_policy()", _src("generics.jl"))
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
    @testset "Phase B: every door goes through loadpolicy.jl" begin
        # Each door still names its own policy — that is what makes a later
        # change of policy one edit rather than a search.
        @test occursin("inline_rustc_policy()", _src("ruststr.jl"))
        @test occursin("inline_cargo_policy()", _src("ruststr.jl"))
        @test occursin("irust_policy()", _src("ruststr.jl"))
        @test occursin("generics_policy()", _src("generics.jl"))
        @test occursin("hot_reload_policy()", _src("hot_reload.jl"))
        @test occursin("helper_library_policy()", _src("memory.jl"))
        @test occursin("alias_artifact!(", _src("rustmacro.jl"))
        # unload_library / unload_all_libraries are wrappers now.
        @test occursin("unload_artifact!(", _src("ruststr.jl"))
    end

    # -----------------------------------------------------------------
    # `load_artifact!` under concurrency (#277 risk 1).
    #
    # `dlopen` is deliberately outside REGISTRY_LOCK, so two tasks loading the
    # same path both open it. The registry transaction decides the winner and
    # the loser's duplicate handle is closed rather than left mapped or
    # swapped in over a live entry.
    # -----------------------------------------------------------------
    @testset "load_artifact! is safe under concurrency" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required to build a library to load concurrently"
        else
            mktempdir() do dir
                src = joinpath(dir, "conc.rs")
                write(src, """
                    #[no_mangle]
                    pub extern "C" fn rustcall_conc_probe(a: i32) -> i32 { a + 1 }
                    """)
                lib = RustCall.compile_rust_to_shared_lib(read(src, String))

                for (mode, expect_one_handle) in ((:insert_only, true), (:replace, false))
                    name = "loadpolicy_conc_$(mode)_$(getpid())"
                    policy = RustCall.LoadPolicy("test-conc-$(mode)";
                                                 registration_mode = mode)
                    try
                        n = 8
                        results = Vector{RustCall.LoadedArtifact}(undef, n)
                        @sync for i in 1:n
                            Threads.@spawn results[i] = RustCall.load_artifact!(
                                policy, lib; lib_name = name,
                                eager = ("rustcall_conc_probe",))
                        end

                        # Exactly one entry, and it is the handle every
                        # :insert_only caller was handed.
                        entry = lock(() -> RustCall.RUST_LIBRARIES[name],
                                     RustCall.REGISTRY_LOCK)
                        @test haskey(entry[2], "rustcall_conc_probe")
                        if expect_one_handle
                            @test all(r -> r.handle == entry[1], results)
                            @test length(unique(r -> r.handle, results)) == 1
                        else
                            # :replace — the last writer wins, and every
                            # artifact but the live one has been retired.
                            @test count(r -> r.alive[], results) == 1
                            @test any(r -> r.handle == entry[1], results)
                        end

                        # The function is callable through the registered entry.
                        ptr = RustCall.get_function_pointer(name, "rustcall_conc_probe")
                        @test RustCall.call_rust_function(ptr, Int32, Int32(41)) == Int32(42)

                        RustCall.unload_artifact!(policy, name)
                        @test all(r -> !r.alive[], results)
                        @test !haskey(RustCall.RUST_LIBRARIES, name)
                    finally
                        lock(RustCall.REGISTRY_LOCK) do
                            delete!(RustCall.RUST_LIBRARIES, name)
                            delete!(RustCall.ARTIFACT_ALIVE, name)
                        end
                    end
                end
            end
        end
    end

    # -----------------------------------------------------------------
    # #255: a failed hot reload keeps the previous library.
    #
    # _reload_library_locked rebuilds, rescans and dlopens *before* anything is
    # removed, and the swap is one load_artifact! with on_replace = :dlclose.
    # There is no unload-first block left, and the rebuild no longer runs with
    # the registry emptied.
    # -----------------------------------------------------------------
    @testset "hot reload rebuilds before it swaps (#255)" begin
        src = _src("hot_reload.jl")
        @test occursin("on_replace = :dlclose", src)
        @test occursin("_source_stamps", src)          # rescan/build TOCTOU guard
        @test occursin("_scan_crate_signatures", src)
        @test !occursin("outside REGISTRY_LOCK", src)  # the old unload-first comment
        # The rescan happens before the build, so the manifest describes the
        # sources that were compiled.
        scan_at = findfirst("_scan_crate_signatures(state.crate_path)", src)
        build_at = findfirst("rebuild_crate(state.crate_path)", src)
        @test scan_at !== nothing && build_at !== nothing
        @test first(scan_at) < first(build_at)
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
