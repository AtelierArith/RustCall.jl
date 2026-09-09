using Test
using RustCall

@testset "the mutable runtime registry lives in one Lockable state (#251)" begin
    @test RustCall.STATE isa Base.Lockable
    @test RustCall.REGISTRY_LOCK === RustCall.STATE.lock

    registry_views = (
        :RUST_LIBRARIES, :CURRENT_LIB, :MODULE_ACTIVE_LIB,
        :FUNCTION_REGISTRY, :FUNCTION_REGISTRY_BY_LIB,
        :FUNCTION_RETURN_TYPES_BY_LIB, :FUNCTION_SYMBOLS_BY_LIB,
        :PANIC_CHANNELS, :GENERIC_FUNCTION_REGISTRY,
        :MONOMORPHIZED_FUNCTIONS, :IRUST_FUNCTIONS, :HOT_RELOAD_REGISTRY,
        :RELOAD_LOCKS, :ARTIFACT_ALIVE,
        :ARTIFACT_GENERATIONS, :HANDLE_MIRRORS, :RETIRED_HANDLES,
        :OWNED_HANDLES, :PRELOADED_LIBRARIES, :DEFERRED_DROPS,
    )
    source = read(joinpath(dirname(pathof(RustCall)), "RustCall.jl"), String)
    for name in registry_views
        @test isdefined(RustCall, name)
        @test isdefined(RustCall, Symbol("STATE"))
    end
    @test occursin("const STATE = Base.Lockable", source)

    # StateView operations take the state lock themselves.  This is a small
    # deterministic stress of the same access path used by compile/load state;
    # the 4-thread CI job runs the heavier hot-reload and FFI stress suites too.
    tasks = Task[]
    for worker in 1:8
        push!(tasks, Threads.@spawn begin
            for iteration in 1:100
                name = "state_$(worker)_$(iteration)"
                RustCall.RUST_LIBRARIES[name] =
                    (C_NULL, Dict{String, Ptr{Cvoid}}())
                @test haskey(RustCall.RUST_LIBRARIES, name)
                delete!(RustCall.RUST_LIBRARIES, name)
            end
        end)
    end
    foreach(wait, tasks)
    @test !any(startswith(String(name), "state_") for name in keys(RustCall.RUST_LIBRARIES))
end
