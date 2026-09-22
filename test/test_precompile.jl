# `using RustCall` used to JIT-compile the `__init__` helper-load path in every
# process: `_state_mutate` was a `do`-block closure specialised on the concrete
# state-container type, so each registry written during the load paid a fresh
# 40–80 ms compile. `src/precompile.jl` now caches that path in the package
# image, and `_StateMutation` (`src/state_filter.jl`) replaces the per-type
# closures with one non-specialising callable.
#
# Two things are pinned here:
#
#   * the workload mutates throwaway `StateView`s and must remove them again —
#     anything it leaves behind is serialised into the `.ji`;
#   * the replacement still performs real writes through the `StateView` API.

using RustCall
using Test

@testset "precompile workload leaves no state behind" begin
    before = Set(keys(RustCall.STATE.value.values))
    RustCall._precompile_init_load_path()
    after = Set(keys(RustCall.STATE.value.values))
    @test after == before
    @test !any(k -> startswith(String(k), "__precompile"), after)
end

@testset "state mutation write path is one callable (#perf)" begin
    # `_state_read(view, f::Function)` requires the callable to be a `Function`;
    # it stops matching (and every `StateView` write breaks) without this.
    @test RustCall._StateMutation <: Function

    views = Dict{Symbol, Any}()
    lock(RustCall.REGISTRY_LOCK) do
        values = RustCall.STATE.value.values
        for (name, value) in (:__test_mutation_dict => Dict{Ptr{Cvoid}, Ref{Bool}}(),
                              :__test_mutation_ref => Ref{Bool}(false),
                              :__test_mutation_vec => RustCall.DeferredDrop[])
            values[name] = value
            views[name] = value
        end
    end
    try
        dict = RustCall.StateView(:__test_mutation_dict)
        handle = Ptr{Cvoid}(1)
        alive = Ref(false)
        dict[handle] = alive
        @test views[:__test_mutation_dict][handle] === alive
        delete!(dict, handle)
        @test !haskey(views[:__test_mutation_dict], handle)

        flag = RustCall.StateView(:__test_mutation_ref)
        flag[] = true
        @test views[:__test_mutation_ref][] === true

        queue = RustCall.StateView(:__test_mutation_vec)
        push!(queue, RustCall.DeferredDrop(handle, "RustBox{Int32}", :rust_box_drop_i32))
        @test length(views[:__test_mutation_vec]) == 1
        empty!(queue)
        @test isempty(views[:__test_mutation_vec])
    finally
        lock(RustCall.REGISTRY_LOCK) do
            for name in keys(views)
                delete!(RustCall.STATE.value.values, name)
            end
        end
    end
end

# ----------------------------------------------------------------------------
# The crate scan / hash / host-artifact workload (#449)
# ----------------------------------------------------------------------------

# Every registry value, copied, so a workload that writes *into* an existing
# container (a memo entry, a `Ref` value) is caught as well as one that adds a
# key. The key-set comparison above is blind to that.
function _state_values_snapshot()
    lock(RustCall.REGISTRY_LOCK) do
        Dict{Symbol, Any}(name => (value isa Ref ? (isassigned(value) ? value[] : nothing) :
                                   value isa Union{AbstractDict, AbstractVector, AbstractSet} ?
                                       copy(value) : value)
                          for (name, value) in RustCall.STATE.value.values)
    end
end

_extractor_available() = try
    RustCall.extractor_path()
    true
catch
    false
end

@testset "crate scan workload leaves no state behind (#449)" begin
    before = _state_values_snapshot()
    epoch = RustCall.ARTIFACT_EPOCH[]
    result = RustCall._precompile_crate_scan_path()
    after = _state_values_snapshot()
    @test keys(after) == keys(before)
    for name in keys(before)
        # `Ref`s compare by value, containers by content: the placeholder
        # toolchain identity, the temporary cfg file, the graph memo and the
        # extractor path must all be back to what they were.
        @test isequal(after[name], before[name])
    end
    # The hash and lookup halves need no tool; the scan half needs the extractor.
    @test result.hashed
    @test result.located
    @test result.scanned == _extractor_available()
    # It writes registries, so the call-site caches were invalidated at least
    # once — and the epoch is monotone, so nothing is asserted about how often.
    @test RustCall.ARTIFACT_EPOCH[] >= epoch
    # Repeatable: a second run finds the same clean slate.
    @test RustCall._precompile_crate_scan_path() == result
end

@testset "registry directives are derived from the containers" begin
    # `_precompile_concrete_members` decides which value-typed directives a
    # registry gets: the stored `RefValue{T}` for an abstract `Ref{T}`, one per
    # concrete member of a `Union`, nothing for `Any`.
    @test RustCall._precompile_concrete_members(Ref{Bool}) == Any[Base.RefValue{Bool}]
    @test RustCall._precompile_concrete_members(Base.RefValue{Bool}) == Any[Base.RefValue{Bool}]
    @test Set(RustCall._precompile_concrete_members(Union{Nothing, Ptr{Cvoid}})) ==
          Set(Any[Nothing, Ptr{Cvoid}])
    @test RustCall._precompile_concrete_members(Any) == Any[]
    @test RustCall._precompile_concrete_members(AbstractString) == Any[]
    @test RustCall._precompile_concrete_members(Int) == Any[Int]
    # The helper itself runs against the live registries without error.
    @test RustCall._precompile_state_container_ops() === nothing
end

# The user-visible property of #449: in a fresh session the first crate scan,
# the first crate hash and the host path's cache lookup run **out of the
# package image**, compiling none of their own methods. `--trace-compile`
# prints every method compiled at run time; none of the path's entry points
# may appear. Only RustCall's own names are asserted — what `Base` compiles for
# a process spawn is Julia's business and changes with the release.
@testset "the crate scan path is in the package image (#449)" begin
    pkg = Base.identify_package("RustCall")
    if !_extractor_available()
        @info "skipping the crate-scan image testset" reason = "no extractor binary"
        return
    end
    if pkg === nothing || !Base.isprecompiled(pkg)
        @info "skipping the crate-scan image testset" reason = "RustCall is not precompiled"
        return
    end
    crate = joinpath(@__DIR__, "fixtures", "sample_crate_pyo3_only")
    trace = tempname()
    script = """
        using RustCall
        info = RustCall.scan_crate($(repr(crate)))
        name = RustCall._pyo3_extension_module_name(info)
        RustCall.compute_crate_hash(info)
        mktempdir() do cache
            artifact = RustCall._pyo3_extension_artifact(
                cache, info, name, "python3", ".cpython-313-darwin.so", "CPython|3.13.0|x|y|z|True";
                features = String[], default_features = true, release = true)
            isfile(artifact.lib_path)
        end
        """
    project = Base.active_project()
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project --trace-compile=$trace -e $script`
    env = copy(ENV)
    haskey(ENV, "RUSTCALL_EXTRACT") && (env["RUSTCALL_EXTRACT"] = ENV["RUSTCALL_EXTRACT"])
    ok = success(pipeline(setenv(cmd, env); stdout = devnull, stderr = stderr))
    @test ok
    compiled = ok && isfile(trace) ? readlines(trace) : String[]
    entry_points = ("RustCall.scan_crate", "RustCall.extract_manifest",
                    "RustCall.manifest_function_signatures", "RustCall.manifest_struct_infos",
                    "RustCall.compute_crate_hash", "RustCall.artifact_path_dependency_digest",
                    "RustCall.crate_content_digest", "RustCall._pyo3_extension_artifact",
                    "RustCall._pyo3_extension_module_name", "RustCall._run_extractor")
    leaked = filter(line -> any(occursin(name, line) for name in entry_points), compiled)
    # A hit here means the image was built without the workload's inputs — a
    # `using RustCall` that precompiled before `Pkg.build` produced the
    # extractor, most likely. Touch `src/precompile.jl` to rebuild the image.
    @test isempty(leaked)
    isempty(leaked) || foreach(println, leaked)
    rm(trace; force = true)
end
