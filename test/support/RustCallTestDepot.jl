# Test-only implicit environment module, loaded before RustCall by each entry.
# It deliberately has no precompiled process-local installation state.
__precompile__(false)
module RustCallTestDepot

struct Installation
    directory::String
    depots::Vector{String}
    depot_env::Union{Nothing,String}
    override_env::Union{Nothing,String}
end

const installation = Ref{Union{Nothing,Installation}}(nothing)

function reset_cache_memo!()
    for (id, mod) in Base.loaded_modules
        if id.name == "RustCall" && isdefined(mod, :_reset_cache_dir_memo!)
            getfield(mod, :_reset_cache_dir_memo!)()
        end
    end
    return nothing
end

function restore_env!(name, value)
    if value === nothing
        pop!(ENV, name, nothing)
    else
        ENV[name] = value
    end
    return nothing
end

function cleanup!(; reset_memo::Bool = true)
    state = installation[]
    state === nothing && return nothing
    empty!(DEPOT_PATH)
    append!(DEPOT_PATH, state.depots)
    restore_env!("JULIA_DEPOT_PATH", state.depot_env)
    restore_env!("RUSTCALL_CACHE_DIR", state.override_env)
    reset_memo && reset_cache_memo!()
    installation[] = nothing
    # Windows can still map package precompile DLLs at process exit. Leave its
    # private temporary depot for later cleanup instead of deleting mapped files.
    if !Sys.iswindows()
        try
            rm(state.directory; recursive = true, force = true)
        catch
            # Cleanup must not replace the actual test result on exit.
        end
    end
    return nothing
end

function isolate!()
    state = installation[]
    state !== nothing && return state.directory
    state = Installation(
        mktempdir(; prefix = "rustcall-tests-", cleanup = false),
        copy(DEPOT_PATH),
        get(ENV, "JULIA_DEPOT_PATH", nothing),
        get(ENV, "RUSTCALL_CACHE_DIR", nothing),
    )
    pushfirst!(DEPOT_PATH, state.directory)
    ENV["JULIA_DEPOT_PATH"] = join(DEPOT_PATH, Sys.iswindows() ? ';' : ':')
    pop!(ENV, "RUSTCALL_CACHE_DIR", nothing)
    installation[] = state
    reset_cache_memo!()
    # No cache lock is needed during process shutdown. Explicit restoration
    # still resets a loaded RustCall memo for callers that continue running.
    atexit(() -> cleanup!(; reset_memo = false))
    return state.directory
end

end
