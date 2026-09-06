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

"""
    _reclaim_libraries!(names...)

Give every named library back: unload it through the loader with
`close = true`, drain whatever is still retired, and only then remove any
registry row that survived.

The `finally` blocks in this file used to `delete!(RUST_LIBRARIES, name)`
directly, which is not a cleanup. A row removed by hand is never *retired*, so
`close_retired_handles!` cannot see the image and the owned `dlopen` reference
is never given back: the test leaks a mapped library into the rest of the
process — on Windows, an undeletable DLL. AGENTS.md says to unload before
deleting; this is what that means for a testset that opened a real image.

Only for testsets that loaded a real library. A testset that `adopt_artifact!`s
a fabricated handle must never be closed through here — `dlclose` on a made-up
pointer is not a cleanup either.
"""
function _reclaim_libraries!(names...)
    policy = RustCall.inline_rustc_policy()
    # The handles these names retired, collected *before* the unloads so the
    # drain below is exactly this testset's. Never the no-argument
    # `close_retired_handles!()`: it sweeps every retired image in the process,
    # and under the parallel runner that can unmap another testset's retired
    # library while it still has live objects or a call inside it (#301 review).
    mine = Ptr{Cvoid}[]
    for n in names
        append!(mine, RustCall.retired_handles(n))
    end
    for n in names
        try
            RustCall.unload_artifact!(policy, n; close = true)
        catch
        end
        append!(mine, RustCall.retired_handles(n))
    end
    unique!(mine)
    isempty(mine) || RustCall.close_retired_handles!(mine)
    lock(RustCall.REGISTRY_LOCK) do
        for n in names
            delete!(RustCall.RUST_LIBRARIES, n)
            delete!(RustCall.ARTIFACT_ALIVE, n)
        end
    end
    return nothing
end

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
        # Only the deprecated LLVM IR path still opens anything itself
        # (#265 Phase 2 deletes it).
        @test local_sites == 0
        @test global_sites == 1
        for file in ("cache.jl", "ruststr.jl", "generics.jl", "hot_reload.jl",
                     "memory.jl", "rustmacro.jl", "crate_bindings.jl")
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

    # A library an artifact imports by name, that the loader would not find on
    # its own, is opened first through the same door — a PyO3 wrapper's Python
    # DLL on Windows, where there is no rpath (#307 review). Any library stands
    # in for the DLL here: the mechanism is the same on every platform.
    @testset "preload: a dependency is opened before the image, once, for good" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required to build a library to load"
        else
            dependency = RustCall.compile_rust_to_shared_lib("""
                #[no_mangle]
                pub extern "C" fn rustcall_preload_dependency() -> i32 { 1 }
                """)
            lib = RustCall.compile_rust_to_shared_lib("""
                #[no_mangle]
                pub extern "C" fn rustcall_preload_image() -> i32 { 2 }
                """)
            name = "loadpolicy_preload_$(getpid())"
            policy = RustCall.inline_rustc_policy()
            @test !(dependency in RustCall.preloaded_libraries())
            try
                a = RustCall.load_artifact!(policy, lib; lib_name = name, preload = [dependency])
                @test dependency in RustCall.preloaded_libraries()
                @test Libdl.dlsym(a.handle, "rustcall_preload_image") != C_NULL
                # Opened once: a second artifact naming the same dependency gets
                # the handle already held, and the table does not grow.
                handle = RustCall.preload_dependency!(policy, dependency)
                @test handle != C_NULL
                @test RustCall.preload_dependency!(policy, dependency) == handle
                @test count(==(dependency), RustCall.preloaded_libraries()) == 1
            finally
                RustCall.unload_artifact!(policy, name; close = true)
            end
            # Retiring the artifact does not close what it depended on: the
            # dependency stays open for the life of the process.
            @test dependency in RustCall.preloaded_libraries()

            # A dependency that cannot be opened is the error — named — and
            # the image is not loaded or registered behind it.
            missing = joinpath(@__DIR__, "no_such_dependency_$(getpid()).so")
            err = try
                RustCall.load_artifact!(policy, lib; lib_name = name * "_missing",
                                        preload = [missing])
                nothing
            catch e
                e
            end
            @test err isa RustCall.RustError
            @test occursin(missing, sprint(showerror, err))
            @test !(missing in RustCall.preloaded_libraries())
            @test !lock(() -> haskey(RustCall.RUST_LIBRARIES, name * "_missing"),
                        RustCall.REGISTRY_LOCK)
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
        # A library with no channel is a no-op, and the guard passes the value
        # through untouched.
        @test RustCall.check_rust_panic_ptr(C_NULL, "no_such_symbol") === nothing
        @test RustCall.guard_rust_panic_ptr(42, C_NULL, "no_such_symbol") == 42
        @test RustCall.panic_channel_pointer("no_such_lib", "no_such_symbol") == C_NULL
        # The channel is resolved BEFORE the wrapper call at every call site:
        # it is a thread-local in the image, so a lock (which can yield) between
        # the call and the read would let the task move to another OS thread and
        # miss the panic entirely. `test_panics.jl` asserts the behaviour under
        # concurrency; this pins the shape.
        # ...and pointer + channel come from ONE snapshot, so a call cannot
        # straddle two generations of a library (#277).
        for (file, kind) in (("rustmacro.jl", "resolve_call_target("),
                             ("structs.jl", "resolve_call_target("),
                             ("julia_functions.jl", "resolve_call_target("),
                             ("crate_bindings.jl", "_call_target("),
                             ("generics.jl", "channel, artifact.handle, artifact.generation"))
            @test occursin(kind, _src(file))
        end
        # The owned-`String` release function comes from the same snapshot as
        # the call that produced the buffer, never a later lookup by name.
        @test occursin("free_symbol = free_func_name", _src("structs.jl"))
        @test occursin("target.free_ptr", _src("structs.jl"))
        # The return ABI is part of the snapshot too: it decides how the return
        # slot is read, and reading a retired generation's result with the
        # replacement's ABI is memory corruption, not a wrong answer (#277).
        @test occursin("return_type = get(FUNCTION_RETURN_TYPES_BY_LIB", _src("ruststr.jl"))
        @test occursin("ret_type = target.return_type", _src("rustmacro.jl"))
        @test occursin("func_info = target.func_info", _src("rustmacro.jl"))
        # ...and a cached `FunctionInfo` is itself a snapshot: it carries the
        # channel of the image its pointer came from, never a name to look one
        # up by later.
        @test occursin("channel = info.channel", _src("generics.jl"))
        # The generic struct destructor and its liveness flag come from one
        # locked read, like the non-generic path.
        @test occursin("generic_struct_generation_snapshot(", _src("structs.jl"))
        # A constructor allocates, so the object it returns is built from the
        # constructor's own snapshot — never from a second lookup afterwards.
        @test occursin("ptr, tgt = GC.@preserve", _src("structs.jl"))
        @test occursin("\$esc_struct(ptr, tgt.lib_name, tgt.free_ptr, tgt.alive)",
                       _src("structs.jl"))
        @test occursin("_ctor_target(", _src("crate_bindings.jl"))
        @test occursin("alive_ref_for_handle(", _src("structs.jl"))
        # ...and the old, resolve-after-the-call entry points are gone.
        for file in readdir(_SRC_DIR)
            endswith(file, ".jl") || continue
            src = _src(file)
            @test !occursin("guard_rust_panic(", src)
            @test !occursin("check_rust_panic(", src)
        end
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

        # The two @rust_crate doors used to bypass RUST_LIBRARIES entirely, so
        # registry-level unload could not see them (#250). Since B5 the
        # generated module publishes its handle through `load_artifact!` and
        # keeps its own `Ref` as a fast path, so both are visible.
        @test RustCall.registers_in_rust_libraries(RustCall.crate_direct_policy())
        @test RustCall.registers_in_rust_libraries(RustCall.crate_wrapper_policy())
        @test RustCall.crate_direct_policy().registry_key_kind === :crate_lib_name
        # The helper library's home is RUST_HELPERS_LIB, and the deprecated
        # LLVM path registers nowhere at all.
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
            # call site may call register_library! unconditionally. (The
            # helper library is such a policy; the @rust_crate doors stopped
            # being one in B5.)
            @test RustCall.register_library!(RustCall.helper_library_policy(), name, handle) == name
            @test !haskey(RustCall.RUST_LIBRARIES, name)
            @test !RustCall.unregister_library!(RustCall.helper_library_policy(), name)

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
    # #249: one lifetime rule, and finalizers that are safe to run.
    #
    # Inline `#[julia]` struct objects used to leak — the free was disabled
    # with a "Temporarily disabled free to diagnose segfault" comment — while
    # `@rust_crate` objects freed. Same construct, opposite semantics. Now
    # both free, and both do it from a finalizer that takes no lock, resolves
    # no symbol and logs nothing.
    # -----------------------------------------------------------------
    @testset "finalizers free, and are safe to run (#249)" begin
        structs_src = _src("structs.jl")
        @test _count_in("structs.jl", r"Finalizer: skipped free") == 0
        @test !occursin("Temporarily disabled free", structs_src)

        # Every policy frees.
        for ctor in RustCall.ALL_LOAD_POLICIES
            p = ctor()
            p.name in ("irust", "llvm-ir", "generics-monomorphization") && continue
            @test RustCall.finalizer_frees(p)
        end
        @test RustCall.finalizer_frees(RustCall.inline_rustc_policy()) ===
              RustCall.finalizer_frees(RustCall.crate_direct_policy())

        # One destructor symbol, from the contract.
        @test RustCall.ffi_struct_free_symbol("Point") == "Point_free"
        for file in ("structs.jl", "crate_bindings.jl")
            src = _src(file)
            @test occursin("ffi_struct_free_symbol", src)
            # ...and no hand-built `<Name>_free` string anywhere.
            @test !occursin("_free\")", src)
        end

        # The finalizer body: captured pointer and flag, no lookup, no lock,
        # no logging (a finalizer may run while the thread holds
        # REGISTRY_LOCK, and @warn allocates and can yield).
        body_start = findfirst("function finalize_rust_object!", structs_src)
        @test body_start !== nothing
        body = structs_src[first(body_start):end]
        body = body[1:first(findfirst("\nend", body))]
        for forbidden in ("dlsym", "REGISTRY_LOCK", "lock(", "@warn", "@info", "@error",
                          "get_function_pointer")
            @test !occursin(forbidden, body)
        end
        # The order that makes a double free impossible: null the field, then
        # check liveness, then call.
        @test findfirst("setfield!(x, :ptr, C_NULL)", body) <
              findfirst("ccall(free_ptr", body)
        @test findfirst("getfield(x, :alive)[] || return", body) <
              findfirst("ccall(free_ptr", body)

        # A failure is counted, not logged.
        @test RustCall.finalizer_failure_count() isa Int
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
    # RustCall closes only what RustCall opened.
    #
    # `load_artifact!` opens an image and takes ownership of it; a handle that
    # merely arrives through `adopt_artifact!` belongs to whoever opened it. On
    # glibc a `dlclose` of a stale or foreign handle segfaults inside
    # `_dl_close` rather than returning an error, so this is a crash boundary,
    # not bookkeeping. Ownership is also what makes closing idempotent: it is
    # checked and given up in one locked step, so a handle is closed at most
    # once however many callers race to close it.
    # -----------------------------------------------------------------
    @testset "only handles RustCall opened are closed" begin
        # A fabricated handle is never owned, and releasing it closes nothing.
        fake = Ptr{Cvoid}(UInt(0xdeadbe00))
        @test !RustCall.artifact_handle_is_owned(fake)
        before = RustCall.DLCLOSE_COUNT[]
        @test RustCall.close_artifact_handle!(fake) == false
        @test RustCall.close_artifact_handle!(C_NULL) == false
        @test RustCall.DLCLOSE_COUNT[] == before

        if !RustCall.check_rustc_available()
            @test_skip "rustc is required to open a real image"
        else
            lib = RustCall.compile_rust_to_shared_lib("""
                #[no_mangle]
                pub extern "C" fn rustcall_owned_probe() -> i32 { 1 }
                """)
            policy = RustCall.inline_rustc_policy()
            name = "loadpolicy_owned_$(getpid())"
            adopted = "loadpolicy_adopted_$(getpid())"
            try
                a = RustCall.load_artifact!(policy, lib; lib_name = name)
                @test RustCall.artifact_handle_is_owned(a.handle)

                # Opening the same path again is the same image (`dlopen`
                # refcounts), and ownership is a set: it is taken once, so the
                # image is closed once.
                b = RustCall.load_artifact!(policy, lib; lib_name = adopted)
                @test b.handle == a.handle
                @test RustCall.artifact_handle_is_owned(a.handle)

                # Unloading retires; the image is still owned and still mapped.
                # `dlopen` refcounts, so two opens owe two closes. Ownership
                # is a *count* for exactly this reason: a set would have
                # collapsed them, and closing the losing duplicate of an
                # `:insert_only` race would then have left the winner
                # unclosable forever (#277).
                @test RustCall.artifact_handle_open_count(a.handle) == 2

                RustCall.unload_artifact!(policy, name)
                @test RustCall.artifact_handle_is_owned(a.handle)
                before = RustCall.DLCLOSE_COUNT[]
                @test RustCall.close_artifact_handle!(a.handle) == true
                @test RustCall.DLCLOSE_COUNT[] == before + 1
                @test RustCall.artifact_handle_open_count(a.handle) == 1
                @test RustCall.close_artifact_handle!(a.handle) == true
                @test RustCall.DLCLOSE_COUNT[] == before + 2
                # The debt is paid: a further close is refused, not performed.
                @test RustCall.close_artifact_handle!(a.handle) == false
                @test RustCall.DLCLOSE_COUNT[] == before + 2
                @test !RustCall.artifact_handle_is_owned(a.handle)
                @test RustCall.artifact_handle_open_count(a.handle) == 0
            finally
                _reclaim_libraries!(name, adopted)
            end
        end
    end

    # -----------------------------------------------------------------
    # An alias is a second name for ONE image, so it needs one close.
    #
    # `alias_artifact!` used to insert the same handle under two names with no
    # bookkeeping, so `unload_all_libraries()` closed it twice — the second
    # close decrements a refcount that belongs to someone else — and unloading
    # one name left the other pointing at code that was about to be unmapped.
    # -----------------------------------------------------------------
    @testset "an alias is one image, closed once" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required to build a library to alias"
        else
            lib = RustCall.compile_rust_to_shared_lib("""
                #[no_mangle]
                pub extern "C" fn rustcall_alias_probe() -> i32 { 5 }
                """)
            policy = RustCall.inline_rustc_policy()
            name = "loadpolicy_alias_$(getpid())"
            alias = name * "_second"
            try
                a = RustCall.load_artifact!(policy, lib; lib_name = name)
                @test RustCall.alias_artifact!(policy, name, alias)
                @test lock(() -> RustCall.RUST_LIBRARIES[alias][1],
                           RustCall.REGISTRY_LOCK) == a.handle
                @test RustCall.library_names_for_handle(a.handle) |> Set ==
                      Set([name, alias])

                # Unloading *either* name removes both. The image is retired,
                # not closed, and its flag stays true.
                before = RustCall.DLCLOSE_COUNT[]
                @test RustCall.unload_artifact!(policy, alias)
                @test RustCall.DLCLOSE_COUNT[] == before
                @test !haskey(RustCall.RUST_LIBRARIES, alias)
                @test !haskey(RustCall.RUST_LIBRARIES, name)   # not left dangling
                @test a.alive[]
                @test a.handle in RustCall.retired_handles(name)

                # ...and unloading again is a no-op.
                @test !RustCall.unload_artifact!(policy, name)

                # One image, one close, however many names it had.
                @test RustCall.close_retired_handles!([a.handle]) == 1
                @test RustCall.DLCLOSE_COUNT[] == before + 1
                @test !a.alive[]
                @test RustCall.close_retired_handles!([a.handle]) == 0
            finally
                _reclaim_libraries!(name, alias)
            end

            # `unload_all_libraries` walks names, so it must survive an alias
            # disappearing under it.
            lib2 = RustCall.compile_rust_to_shared_lib("""
                #[no_mangle]
                pub extern "C" fn rustcall_alias_probe2() -> i32 { 6 }
                """)
            name2 = "loadpolicy_alias_all_$(getpid())"
            alias2 = name2 * "_second"
            b2 = RustCall.load_artifact!(policy, lib2; lib_name = name2)
            RustCall.alias_artifact!(policy, name2, alias2)
            before = RustCall.DLCLOSE_COUNT[]
            @test_nowarn RustCall.unload_all_libraries(; close = true)
            @test isempty(RustCall.RUST_LIBRARIES)
            @test isempty(RustCall.retired_handles())
            # One close for the aliased image, whatever else was loaded.
            @test RustCall.DLCLOSE_COUNT[] >= before + 1
            @test !b2.alive[]
        end
    end

    # -----------------------------------------------------------------
    # #291 item 4: two contained lifecycle edges.
    # -----------------------------------------------------------------
    @testset "re-aliasing the same image does not retire it (#291)" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required to build a library to alias"
        else
            lib = RustCall.compile_rust_to_shared_lib("""
                #[no_mangle]
                pub extern "C" fn rustcall_realias_probe() -> i32 { 11 }
                """)
            policy = RustCall.inline_rustc_policy()
            name = "loadpolicy_realias_$(getpid())"
            alias = name * "_stored"
            other = name * "_other"
            try
                a = RustCall.load_artifact!(policy, lib; lib_name = name)
                @test RustCall.alias_artifact!(policy, name, alias)
                @test a.alive[]
                shared = lock(() -> RustCall.ARTIFACT_ALIVE[alias],
                              RustCall.REGISTRY_LOCK)
                @test shared === a.alive

                # The bug: `alias_artifact!` retired whatever was registered
                # under the target name — and when the target *already* names
                # this image, that flag is this image's own. A second
                # `_alias_reloaded_library` (one runs on every `_resolve_lib`,
                # so the second call through one module reaches this) declared
                # a live library dead: objects holding the flag go inert, their
                # destructors never run, and every `alive[]` check turns a
                # working call into an error.
                for _ in 1:3
                    @test RustCall.alias_artifact!(policy, name, alias)
                    @test a.alive[]
                    @test shared[]
                    @test lock(() -> RustCall.ARTIFACT_ALIVE[alias],
                               RustCall.REGISTRY_LOCK) === a.alive
                    @test lock(() -> RustCall.RUST_LIBRARIES[alias][1],
                               RustCall.REGISTRY_LOCK) == a.handle
                end
                @test RustCall.library_names_for_handle(a.handle) |> Set ==
                      Set([name, alias])

                # Displacing a name that pointed somewhere else is a
                # **retirement**, not a death sentence. The displaced image is
                # still mapped, so it keeps its flag `true` and its objects
                # still free through it; only `close_retired_handles!` — the
                # caller stating no call is in flight — makes them inert, and
                # it flips the flag itself. Flipping it here left a mapped
                # image whose every object silently skipped its destructor
                # (#291 review).
                lib2 = RustCall.compile_rust_to_shared_lib("""
                    #[no_mangle]
                    pub extern "C" fn rustcall_realias_probe2() -> i32 { 12 }
                    """)
                b = RustCall.load_artifact!(policy, lib2; lib_name = other)
                @test b.alive[]
                @test b.handle != a.handle
                @test RustCall.alias_artifact!(policy, name, other)
                @test b.alive[]         # retired, not closed: still frees
                @test a.alive[]         # and the one it now names is untouched
                @test lock(() -> RustCall.ARTIFACT_ALIVE[other],
                           RustCall.REGISTRY_LOCK) === a.alive

                # Displacing `b` took its **only** name away, and an image with
                # no name is unreachable: nothing can unload it and
                # `close_retired_handles!` cannot see it, so its owned `dlopen`
                # reference could never be given back. `alias_artifact!` now
                # retires it, exactly as `load_artifact!` does on a replace.
                @test RustCall.library_names_for_handle(b.handle) |> isempty
                @test b.handle in RustCall.retired_handles()
                @test b.handle in RustCall.retired_handles(other)
                @test RustCall.artifact_handle_is_owned(b.handle)
                # The flag stays true until the image is actually closed, which
                # is what `alive_ref_for_handle` promises a cached pointer.
                @test lock(() -> RustCall.alive_ref_for_handle(b.handle, other),
                           RustCall.REGISTRY_LOCK) === b.alive
                @test b.alive[]

                # Both images can therefore be reclaimed — which is what stops
                # this test leaking two mapped libraries into the rest of the
                # process, and on Windows two undeletable DLLs.
                before = RustCall.DLCLOSE_COUNT[]
                # One unload closes both: `other` is a name of *this* image now
                # and of `b`'s retired record, so the reclaim reaches both.
                @test RustCall.unload_artifact!(policy, name; close = true)
                @test RustCall.DLCLOSE_COUNT[] == before + 2
                @test !(a.handle in RustCall.retired_handles())
                @test !(b.handle in RustCall.retired_handles())
                @test RustCall.close_retired_handles!([a.handle, b.handle]) == 0
                @test !RustCall.artifact_handle_is_owned(a.handle)
                @test !RustCall.artifact_handle_is_owned(b.handle)
                # ...and *now* both flags are false: closing is what makes an
                # image's objects inert.
                @test !a.alive[]
                @test !b.alive[]
                for n in (name, alias, other)
                    @test !haskey(RustCall.RUST_LIBRARIES, n)
                end
            finally
                _reclaim_libraries!(name, alias, other)
            end
        end
    end

    @testset "displacing one of several names leaves the image alone (#291)" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required to open a real image"
        else
            lib = RustCall.compile_rust_to_shared_lib("""
                #[no_mangle]
                pub extern "C" fn rustcall_multi_name_probe() -> i32 { 21 }
                """)
            other_lib = RustCall.compile_rust_to_shared_lib("""
                #[no_mangle]
                pub extern "C" fn rustcall_multi_name_probe2() -> i32 { 22 }
                """)
            policy = RustCall.inline_rustc_policy()
            keep = "loadpolicy_multiname_keep_$(getpid())"
            spare = "loadpolicy_multiname_spare_$(getpid())"
            src = "loadpolicy_multiname_src_$(getpid())"
            try
                # One image under two names, and a second image to alias over
                # one of them.
                victim = RustCall.load_artifact!(policy, lib; lib_name = keep)
                @test RustCall.alias_artifact!(policy, keep, spare)
                mover = RustCall.load_artifact!(policy, other_lib; lib_name = src)
                @test mover.handle != victim.handle

                # `spare` now names `mover`'s image. `victim`'s image loses one
                # of its two names and is otherwise untouched: still registered
                # under `keep`, still live, not retired. `_record_retired!`
                # declines for it — which is only correct if nothing flipped
                # its flag on the way (#291 review).
                @test RustCall.alias_artifact!(policy, src, spare)
                @test victim.alive[]
                @test RustCall.library_names_for_handle(victim.handle) == [keep]
                @test !(victim.handle in RustCall.retired_handles())
                @test lock(() -> RustCall.alive_ref_for_handle(victim.handle, keep),
                           RustCall.REGISTRY_LOCK) === victim.alive
                # A call through the surviving name still works, which is the
                # user-visible form of "the flag is true".
                @test RustCall.call_rust_function(
                    RustCall.resolve_call_target(keep, "rustcall_multi_name_probe").func_ptr,
                    Int32) == Int32(21)

                before = RustCall.DLCLOSE_COUNT[]
                @test RustCall.unload_artifact!(policy, keep; close = true)
                @test !victim.alive[]
                @test RustCall.DLCLOSE_COUNT[] == before + 1

                # `mover` is still loaded, under both `src` and `spare`. It has
                # to go back through the loader too — a registry row removed by
                # hand is never retired, so nothing could ever close it.
                @test RustCall.artifact_handle_is_owned(mover.handle)
                @test RustCall.unload_artifact!(policy, src; close = true)
                @test RustCall.DLCLOSE_COUNT[] == before + 2
                @test !RustCall.artifact_handle_is_owned(mover.handle)
                @test !RustCall.artifact_handle_is_owned(victim.handle)
                @test !mover.alive[]
                for n in (keep, spare, src)
                    @test !haskey(RustCall.RUST_LIBRARIES, n)
                end
            finally
                _reclaim_libraries!(keep, spare, src)
            end
        end
    end

    @testset "one image, one liveness flag under two live names (#291)" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required to open a real image"
        else
            path = RustCall.compile_rust_to_shared_lib("""
                #[no_mangle]
                pub extern "C" fn rustcall_two_names_probe() -> i32 { 13 }
                """)
            policy = RustCall.inline_rustc_policy()
            first_name = "loadpolicy_twonames_a_$(getpid())"
            second_name = "loadpolicy_twonames_b_$(getpid())"
            try
                a = RustCall.load_artifact!(policy, path; lib_name = first_name)
                # The same *path* under a second name: `dlopen` refcounts and
                # answers with the same image, so this is one lifetime with two
                # registry rows.
                b = RustCall.load_artifact!(policy, path; lib_name = second_name)
                @test b.handle == a.handle
                @test RustCall.library_names_for_handle(a.handle) |> Set ==
                      Set([first_name, second_name])

                # One image, one flag. A second flag here is not cosmetic:
                # `unload_artifact!` retires the image with *one* of them and
                # drops the other from `ARTIFACT_ALIVE` without ever flipping
                # it, so every object that captured the dropped flag believes
                # itself live after `close = true` unmapped the code its
                # destructor calls into.
                @test b.alive === a.alive
                @test lock(RustCall.REGISTRY_LOCK) do
                    RustCall.ARTIFACT_ALIVE[first_name] ===
                        RustCall.ARTIFACT_ALIVE[second_name]
                end
                @test lock(() -> RustCall.registered_alive_for_handle(a.handle),
                           RustCall.REGISTRY_LOCK) === a.alive
                # A cached pointer finds the same flag by handle, under either
                # name — which is the property the finalizers rely on.
                @test lock(() -> RustCall.alive_ref_for_handle(a.handle, first_name),
                           RustCall.REGISTRY_LOCK) === a.alive
                @test lock(() -> RustCall.alive_ref_for_handle(a.handle, second_name),
                           RustCall.REGISTRY_LOCK) === a.alive

                # Closing flips the one flag, so *both* artifacts observe it —
                # and reclaims both owned opens, so the test leaves nothing
                # mapped (on Windows, nothing undeletable).
                @test RustCall.artifact_handle_is_owned(a.handle)
                @test RustCall.unload_artifact!(policy, first_name)
                @test a.alive[] && b.alive[]        # retired, not closed
                RustCall.close_retired_handles!([a.handle])
                @test !a.alive[]
                @test !b.alive[]
                @test !RustCall.artifact_handle_is_owned(a.handle)
                @test !(a.handle in RustCall.retired_handles())
            finally
                _reclaim_libraries!(first_name, second_name)
            end
        end
    end

    # -----------------------------------------------------------------
    # A module-local copy of a handle must not go stale (#277).
    #
    # -----------------------------------------------------------------
    # One image, two names: `dlopen` refcounts, so two opens owe two closes.
    # Retiring the record and closing once left the last loader reference
    # unreclaimable and the image mapped for the life of the process (#277).
    # -----------------------------------------------------------------
    @testset "retiring an image drains its owned opens" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required to open a real image"
        else
            path = RustCall.compile_rust_to_shared_lib("""
                #[no_mangle]
                pub extern "C" fn rustcall_drain_probe() -> i32 { 3 }
                """)
            policy = RustCall.inline_rustc_policy()
            first_name = "loadpolicy_drain_a_$(getpid())"
            second_name = "loadpolicy_drain_b_$(getpid())"
            try
                a = RustCall.load_artifact!(policy, path; lib_name = first_name)
                b = RustCall.load_artifact!(policy, path; lib_name = second_name)
                # The same file, so `dlopen` hands back the same image twice.
                @test a.handle == b.handle
                @test RustCall.artifact_handle_open_count(a.handle) == 2

                RustCall.unload_artifact!(policy, first_name)
                RustCall.unload_artifact!(policy, second_name)
                @test a.handle in RustCall.retired_handles()

                before = RustCall.DLCLOSE_COUNT[]
                @test RustCall.close_retired_handles!([a.handle]) == 1
                # Two opens, two closes: the loader holds no reference now.
                # One close would have left the image mapped for the life of
                # the process, with its record already discarded.
                @test RustCall.DLCLOSE_COUNT[] == before + 2
                @test !RustCall.artifact_handle_is_owned(a.handle)
                @test RustCall.artifact_handle_open_count(a.handle) == 0
                @test !(a.handle in RustCall.retired_handles())
            finally
                _reclaim_libraries!(first_name, second_name)
            end
        end
    end

    # -----------------------------------------------------------------
    # One mapped image, one liveness flag — across an unload and a reopen.
    # `unload_library(name)` retires without closing, so the image stays
    # mapped and its objects hold its flag; the next `dlopen` of that path
    # answers with the same handle (#277).
    # -----------------------------------------------------------------
    @testset "reopening a retired image keeps its liveness flag" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required to open a real image"
        else
            path = RustCall.compile_rust_to_shared_lib("""
                #[no_mangle]
                pub extern "C" fn rustcall_reopen_probe() -> i32 { 4 }
                """)
            policy = RustCall.inline_rustc_policy()
            name = "loadpolicy_reopen_$(getpid())"
            try
                a = RustCall.load_artifact!(policy, path; lib_name = name)
                # An object allocated now would hold this flag.
                held = a.alive
                @test held[]

                RustCall.unload_artifact!(policy, name)
                @test a.handle in RustCall.retired_handles()
                @test held[]           # retired, not closed: still callable

                # Reopening the same path: the loader hands back the very same
                # image, so it must keep the very same flag. A fresh one would
                # leave `held` watching nothing — and a later close of the new
                # generation would flip a flag no live object holds.
                b = RustCall.load_artifact!(policy, path; lib_name = name)
                @test b.handle == a.handle
                @test b.alive === held
                @test !(b.handle in RustCall.retired_handles())
                @test held[]

                # ...and closing it now does reach the objects that held it.
                RustCall.unload_artifact!(policy, name)
                RustCall.close_retired_handles!([b.handle])
                @test !held[]
            finally
                _reclaim_libraries!(name)
            end
        end
    end

    # -----------------------------------------------------------------
    # The drain closes what the *retirement* owned, never what a reopen
    # acquired afterwards (#277).
    # -----------------------------------------------------------------
    @testset "the retired drain does not steal a reopen's reference" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required to open a real image"
        else
            path = RustCall.compile_rust_to_shared_lib("""
                #[no_mangle]
                pub extern "C" fn rustcall_steal_probe() -> i32 { 5 }
                """)
            policy = RustCall.inline_rustc_policy()
            name = "loadpolicy_steal_$(getpid())"
            other = "loadpolicy_steal_other_$(getpid())"
            try
                a = RustCall.load_artifact!(policy, path; lib_name = name)
                RustCall.unload_artifact!(policy, name)
                record = lock(() -> RustCall.RETIRED_HANDLES[a.handle],
                              RustCall.REGISTRY_LOCK)
                # The record remembers what it was retired with...
                @test record.owned == 1

                # ...and a reopen under another name takes a reference of its
                # own, which the drain must not touch.
                b = RustCall.load_artifact!(policy, path; lib_name = other)
                @test b.handle == a.handle
                @test RustCall.artifact_handle_open_count(a.handle) == 2

                # The reopen removed the retirement, so there is nothing to
                # drain — and the live reference survives.
                @test isempty(intersect(RustCall.retired_handles(), [a.handle]))
                before = RustCall.DLCLOSE_COUNT[]
                @test RustCall.close_retired_handles!([a.handle]) == 0
                @test RustCall.DLCLOSE_COUNT[] == before
                @test RustCall.artifact_handle_open_count(a.handle) == 2
                @test RustCall.call_rust_function(
                    RustCall.resolve_call_target(other, "rustcall_steal_probe").func_ptr,
                    Int32) == Int32(5)
            finally
                _reclaim_libraries!(name, other)
            end
        end
    end

    # A generated `@rust_crate` module reads its handle from its own `Ref` on
    # every call. A hot reload closes the previous image and `unload_library`
    # closes it outright, so a raw copy would be a `dlsym` into unmapped
    # memory. The loader keeps registered mirrors in step.
    # -----------------------------------------------------------------
    @testset "handle mirrors follow replace and unload" begin
        policy = RustCall.LoadPolicy("test-mirror"; sets_current_lib = false)
        name = "loadpolicy_mirror_$(getpid())"
        # ONE record, not two `Ref`s. Handle, liveness flag and generation are
        # published together, so a reader's single deref can never pair one
        # generation's handle with another's flag (#277).
        gen_ref = Ref(RustCall.CrateGeneration())
        first_handle = Ptr{Cvoid}(UInt(0xaaaa0000))
        second_handle = Ptr{Cvoid}(UInt(0xbbbb0000))
        try
            RustCall.register_handle_mirror!(name, gen_ref)
            # Nothing registered yet, so the mirror is untouched.
            @test gen_ref[].handle == C_NULL

            a = RustCall.adopt_artifact!(policy, first_handle; lib_name = name)
            @test gen_ref[].handle == first_handle
            @test gen_ref[].alive === a.alive
            @test gen_ref[].alive[]
            @test gen_ref[].generation == a.generation
            first_generation = gen_ref[].generation
            @test first_generation > 0

            # A replace — what a hot reload does — moves the mirror to the new
            # handle, the new liveness flag and the next generation, in one
            # transaction and as one value.
            b = RustCall.adopt_artifact!(policy, second_handle; lib_name = name)
            @test gen_ref[].handle == second_handle
            @test gen_ref[].alive === b.alive
            @test gen_ref[].alive[]
            @test gen_ref[].generation == first_generation + 1
            # The previous image is retired but still mapped, so its flag stays
            # true and objects it allocated still free through it.
            @test a.alive[]
            @test first_handle in RustCall.retired_handles(name)

            # An unload empties the mirror, so the module's own check reports
            # "not loaded" instead of dlsym'ing a closed handle.
            RustCall.unload_artifact!(policy, name)
            @test gen_ref[].handle == C_NULL
            # The *mirror's* slot is emptied — the module's library is gone —
            # while the artifact's own flag stays true until its image closes.
            @test !gen_ref[].alive[]
            @test b.alive[]

            # The mirror stays registered: a reload under the same name — which
            # is what hot reload is — fills it in again.
            c = RustCall.adopt_artifact!(policy, first_handle; lib_name = name)
            @test gen_ref[].handle == first_handle
            @test gen_ref[].alive === c.alive
            @test gen_ref[].generation == c.generation
        finally
            lock(RustCall.REGISTRY_LOCK) do
                delete!(RustCall.RUST_LIBRARIES, name)
                delete!(RustCall.ARTIFACT_ALIVE, name)
                delete!(RustCall.HANDLE_MIRRORS, name)
            end
        end
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
                            # :replace — the last writer wins. Every earlier
                            # generation keeps its flag `true`: its image is
                            # still mapped (retired, not closed), so objects it
                            # allocated must still free through it (#249, #277).
                            @test all(r -> r.alive[], results)
                            @test any(r -> r.handle == entry[1], results)
                            # One image, opened `n` times: `dlopen` refcounts
                            # and hands back the same handle, so there is
                            # nothing to retire.
                            @test length(unique(r -> r.handle, results)) == 1
                        end

                        # The function is callable through the registered entry.
                        ptr = RustCall.get_function_pointer(name, "rustcall_conc_probe")
                        @test RustCall.call_rust_function(ptr, Int32, Int32(41)) == Int32(42)

                        RustCall.unload_artifact!(policy, name; close = true)
                        @test all(r -> !r.alive[], results)
                        @test !haskey(RustCall.RUST_LIBRARIES, name)
                        @test isempty(RustCall.retired_handles(name))
                    finally
                        _reclaim_libraries!(name)
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
        # A replaced image is retired, not closed: a call that started before
        # the reload may still be inside it (#277).
        # A replaced image is retired, not closed, and so is an unloaded one:
        # one code path, `RETIRED_HANDLES` (#277).
        @test !occursin("on_replace", src)
        @test occursin("RETIRED_HANDLES", _src("loadpolicy.jl"))
        @test occursin("close_retired_handles!", _src("loadpolicy.jl"))
        # The rescan/build guard hashes content, not (mtime, size).
        @test occursin("_source_fingerprint", src)
        @test occursin("crate_content_digest", src)
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

            # A :replace registration retires the previous artifact — and a
            # retired image keeps its flag `true`, because it is still mapped
            # and its objects must still free through it. Only *closing* an
            # image makes its objects inert (#249).
            other = Ptr{Cvoid}(UInt(0xf00d0000))
            b = RustCall.adopt_artifact!(policy, other; lib_name = name)
            @test a.alive[]
            @test b.alive[]
            @test a.alive !== b.alive                  # a flag per generation
            @test RustCall.exported_symbol(name, "f") == "f"   # metadata replaced
            # `handle` has NOT left the registry: the alias still names it. An
            # image is retired when no name reaches it any more, which is what
            # keeps an alias from being turned into a dangling entry.
            @test !(handle in RustCall.retired_handles(name))
            @test RustCall.library_names_for_handle(handle) == [alias]

            # :insert_only keeps the incumbent and reports it — and does not
            # close the handle it was handed, which is only `load_artifact!`'s
            # to close because only `load_artifact!` opened it. `handle` here
            # is a bookkeeping value, never a real image, so closing it would
            # segfault inside the dynamic loader.
            insert_only = RustCall.LoadPolicy("test-loader-insert";
                                              registration_mode = :insert_only)
            c = RustCall.adopt_artifact!(insert_only, handle; lib_name = name)
            @test c.handle == other
            @test c.alive === b.alive

            # Unloading retires by default: the registry rows go, the image
            # stays mapped, the flag stays true.
            @test RustCall.unload_artifact!(policy, name)
            @test b.alive[]
            @test other in RustCall.retired_handles(name)
            @test RustCall.CURRENT_LIB[] == ""
            @test !RustCall.unload_artifact!(policy, name)

            # The alias still holds the first image, so unloading it retires
            # that one too — and only now, with no name reaching it.
            @test RustCall.unload_artifact!(policy, alias)
            @test a.alive[]
            @test handle in RustCall.retired_handles(alias)

            # `close = true` is what makes objects from an image inert. These
            # handles were *adopted*, never opened by RustCall, so releasing
            # them retires the bookkeeping and flips the flags but performs no
            # `dlclose` — closing a value that was never a real image
            # segfaults inside glibc's `_dl_close` rather than returning an
            # error, so "do not close what you did not open" is load-bearing.
            @test !RustCall.artifact_handle_is_owned(handle)
            @test !RustCall.artifact_handle_is_owned(other)
            closes_before = RustCall.DLCLOSE_COUNT[]
            @test RustCall.close_retired_handles!([handle, other]) == 2
            @test RustCall.DLCLOSE_COUNT[] == closes_before   # nothing closed
            @test !a.alive[]
            @test !b.alive[]
            # Idempotent: the records are gone, so a second release is a no-op
            # rather than a second `dlclose` of the same value.
            @test RustCall.close_retired_handles!([handle, other]) == 0
            @test RustCall.DLCLOSE_COUNT[] == closes_before
            @test isempty(RustCall.retired_handles(name))
            @test isempty(RustCall.retired_handles(alias))
            @test_throws ArgumentError RustCall.adopt_artifact!(policy, C_NULL;
                                                               lib_name = name)
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
