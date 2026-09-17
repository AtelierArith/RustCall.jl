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
