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
        @test RustCall.registers_in_rust_libraries(p)
        @test p.registry_key_kind === :content_hash
        @test !p.sets_current_lib
        @test RustCall.finalizer_frees(p)
        @test RustCall.dlopen_flags(p) == p.dlopen_flags
        @test occursin("LoadPolicy(example", sprint(show, p))

        g = RustCall.LoadPolicy("g"; dlopen_flags = Libdl.RTLD_GLOBAL | Libdl.RTLD_NOW)
        @test RustCall.uses_global_symbols(g)

        @test_throws ArgumentError RustCall.LoadPolicy("bad"; panic_strategy = :terminate)
        @test_throws ArgumentError RustCall.LoadPolicy("bad"; registry = :somewhere)
        @test_throws ArgumentError RustCall.LoadPolicy("bad"; registry_key_kind = :nope)
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
        # The five doors Phase B swaps over first.
        @test Set(["inline-rustc", "inline-cargo", "rust-crate",
                   "helper-library", "cache-hit"]) ⊆ Set(names)
    end

    # -----------------------------------------------------------------
    # Divergence 1: dlopen flags (#250)
    #
    # The same inline block gets RTLD_LOCAL on a cache miss and RTLD_GLOBAL on
    # the Cargo path / Cargo cache hit, so whether its symbols enter the
    # process-global namespace depends on which door and on cache state.
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
        # Current main: 4 local, 8 global, 12 total. Phase B collapses these
        # into a single loader; update these numbers as doors move over.
        @test local_sites == 4
        @test global_sites == 8
        @test local_sites + global_sites == 12

        # The pair that makes the bug user-visible: cache-miss vs Cargo path.
        @test !RustCall.uses_global_symbols(RustCall.inline_rustc_policy())
        @test RustCall.uses_global_symbols(RustCall.inline_cargo_policy())
        @test !RustCall.uses_global_symbols(RustCall.cache_hit_policy())
        # ...and the rule is inverted: the helper library, the one library
        # other artifacts could resolve against, is the LOCAL one.
        @test !RustCall.uses_global_symbols(RustCall.helper_library_policy())
        @test RustCall.uses_global_symbols(RustCall.crate_policy())
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
        @test RustCall.inline_cargo_policy().panic_strategy === :unwind
        @test RustCall.crate_policy().panic_strategy === :unwind
        # The two inline doors disagree, which is exactly what #244 asks to fix.
        @test RustCall.inline_rustc_policy().panic_strategy !==
              RustCall.inline_cargo_policy().panic_strategy
        @test RustCall.requires_catch_unwind_boundary(RustCall.inline_cargo_policy())
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
        # Seven open-coded registration sites on current main.
        @test writes == 7

        # Each site decides for itself whether CURRENT_LIB moves and what the
        # key looks like; the policies record that disagreement.
        @test RustCall.inline_rustc_policy().sets_current_lib
        @test RustCall.cache_hit_policy().sets_current_lib
        @test RustCall.inline_cargo_policy().sets_current_lib
        @test !RustCall.generics_policy().sets_current_lib
        @test !RustCall.irust_policy().sets_current_lib
        @test !RustCall.hot_reload_policy().sets_current_lib

        @test RustCall.generics_policy().registry_key_kind === :lib_basename
        @test RustCall.irust_policy().registry_key_kind === :irust_hash
        @test RustCall.hot_reload_policy().registry_key_kind === :crate_lib_name
        @test RustCall.inline_rustc_policy().registry_key_kind === :content_hash

        # Two doors bypass RUST_LIBRARIES entirely, so registry-level unload
        # cannot see them (#250).
        @test !RustCall.registers_in_rust_libraries(RustCall.crate_policy())
        @test !RustCall.registers_in_rust_libraries(RustCall.helper_library_policy())
        @test !RustCall.registers_in_rust_libraries(RustCall.llvm_policy())

        # The hot-reload rebuild happens outside REGISTRY_LOCK (#255).
        @test occursin("outside REGISTRY_LOCK", _src("hot_reload.jl"))
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
            @test RustCall.register_library!(RustCall.crate_policy(), name, handle) == name
            @test !haskey(RustCall.RUST_LIBRARIES, name)
            @test !RustCall.unregister_library!(RustCall.crate_policy(), name)
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
        @test !RustCall.finalizer_frees(RustCall.cache_hit_policy())
        @test !RustCall.finalizer_frees(RustCall.inline_cargo_policy())
        @test RustCall.finalizer_frees(RustCall.crate_policy())
        @test RustCall.finalizer_frees(RustCall.inline_rustc_policy()) !==
              RustCall.finalizer_frees(RustCall.crate_policy())
    end

    @testset "Phase A is additive: no call site migrated yet" begin
        # loadpolicy.jl is included but nothing in src/ uses it yet.
        for file in readdir(_SRC_DIR)
            endswith(file, ".jl") || continue
            file in ("loadpolicy.jl", "RustCall.jl") && continue
            src = _src(file)
            @test !occursin("LoadPolicy", src)
            @test !occursin("register_library!", src)
        end
    end
end
