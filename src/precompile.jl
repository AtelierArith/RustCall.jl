# `__init__` eagerly loads the ownership helper library, and that load path is
# the only thing that exercises a broad family of `_state_read`/`_state_mutate`
# specializations: the do-block closures in `src/RustCall.jl` and
# `_state_mutate_storage!` (`src/state_filter.jl`) are keyed by the concrete
# state-container type, and `load_artifact!` touches `Dict{Ptr{Cvoid}, Int}`,
# `Dict{Ptr{Cvoid}, RetiredImage}`, `Dict{String, Ref{Bool}}`, several `Ref`s and
# the deferred-drop `Vector{DeferredDrop}` in one go.
#
# Precompilation never runs `__init__`, so those specializations are absent from
# the package image and every `using RustCall` JIT-compiles them in-process.
# Measured on Julia 1.13 the path costs ~0.65 s of a ~0.86 s load (`@time_imports`
# reports 97% compilation time for `__init__`; `--compile=min` drops the load to
# ~0.21 s), dominated by one 40–80 ms compile per container type.
#
# The workload below replays those state operations against throwaway
# containers so the native code lands in the image. The dummy views are removed
# before returning, so no serializable state — let alone a pointer — survives
# into the `.ji`. It runs only while generating output; at `using` time this file
# does nothing.
function _precompile_init_load_path()
    added = Symbol[]
    add(name, value) = begin
        STATE.value.values[name] = value
        push!(added, name)
        StateView(name)
    end
    try
        ptr = Ptr{Cvoid}(0)

        # OWNED_HANDLES[handle] = count (setindex! with (value, key))
        _state_mutate(add(:__precompile_owned_handles, Dict{Ptr{Cvoid}, Int}()),
                      :setindex!, 1, ptr)

        # RETIRED_HANDLES: delete!(view, handle)
        _state_mutate(add(:__precompile_retired_handles,
                          Dict{Ptr{Cvoid}, RetiredImage}()),
                      :delete!, ptr)

        # HANDLE_ONLY_ALIVE[handle] = alive
        _state_mutate(add(:__precompile_handle_only_alive,
                          Dict{Ptr{Cvoid}, Ref{Bool}}()),
                      :setindex!, Ref(false), ptr)

        # ARTIFACT_ALIVE[name] = alive
        _state_mutate(add(:__precompile_artifact_alive,
                          Dict{String, Ref{Bool}}()),
                      :setindex!, Ref(false), "lib")

        # RUST_HELPERS_LIB[] = handle
        _state_mutate(add(:__precompile_rust_helpers_lib,
                          Ref{Union{Nothing, Ptr{Cvoid}}}(nothing)),
                      :setindex!, ptr)

        # DROP_WARNING_SHOWN[] = flag, and the per-image liveness flags
        _state_mutate(add(:__precompile_drop_warning_shown, Ref{Bool}(false)),
                      :setindex!, true)

        # The deferred-drop queue, as `flush_deferred_drops` drains it.
        queue = add(:__precompile_deferred_drops, DeferredDrop[])
        _state_mutate(queue, :push!,
                      DeferredDrop(ptr, "RustBox{Int32}", :rust_box_drop_i32))
        _state_read(queue, copy)
        _state_mutate(queue, :empty!)

        # `preloaded_libraries` and roster queries copy a populated registry.
        _state_read(add(:__precompile_rust_libraries,
                        Dict{String, Tuple{Ptr{Cvoid}, Dict{String, Ptr{Cvoid}}}}()),
                    copy)
    finally
        for name in added
            delete!(STATE.value.values, name)
        end
    end
    return nothing
end

if ccall(:jl_generating_output, Cint, ()) == 1
    _precompile_init_load_path()
    # The workload caches the do-block closures, but Julia does not serialise
    # every concrete `Base` method those closures dispatch to. Name the
    # remaining ones so the JIT cost is paid here, once, rather than at every
    # `using`.
    precompile(Base.setindex!, (Dict{Ptr{Cvoid}, Int}, Int, Ptr{Cvoid}))
    precompile(Base.setindex!, (Dict{Ptr{Cvoid}, Ref{Bool}}, Base.RefValue{Bool}, Ptr{Cvoid}))
    precompile(Base.setindex!, (Dict{String, Ref{Bool}}, Base.RefValue{Bool}, String))
    precompile(Base.setindex!, (Ref{Union{Nothing, Ptr{Cvoid}}}, Ptr{Cvoid}))
    precompile(Base.delete!, (Dict{Ptr{Cvoid}, RetiredImage}, Ptr{Cvoid}))
    precompile(Base.empty!, (Vector{DeferredDrop},))
    precompile(Base.copy, (Vector{DeferredDrop},))
    precompile(Base.iterate, (Vector{DeferredDrop},))
    precompile(Base.copy, (Dict{String, Tuple{Ptr{Cvoid}, Dict{String, Ptr{Cvoid}}}},))
    precompile(Base.iterate, (Dict{String, Tuple{Ptr{Cvoid}, Dict{String, Ptr{Cvoid}}}},))
end
