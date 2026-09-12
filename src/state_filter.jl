# Active filter operations observe mutations under STATE. Observation lasts
# only for the operation; completed/throwing predicates leave no retained log.
mutable struct StateFilterWatch
    kind::Symbol
    changed::Set{Any}
    positions::Vector{Int}
end

const STATE_FILTERS = _state_view(:state_filters, IdDict{Any, Vector{StateFilterWatch}}())

_filter_storage(view::StateView, value) =
    view.name === :deferred_drops && view.owner === nothing ? getfield(value, :entries) : value

# Caller holds STATE. Tokens identify original vector occurrences, not values:
# removing an occurrence and adding an identical value gives it token zero.
function _observe_state_mutation!(watch::StateFilterWatch, value, op::Symbol, args)
    if watch.kind === :vector
        if op === :empty!
            empty!(watch.positions)
        elseif op === :push!
            append!(watch.positions, zeros(Int, length(args)))
        elseif op === :prepend!
            prepend!(watch.positions, zeros(Int, length(args[1])))
        elseif op === :deleteat!
            deleteat!(watch.positions, args[1])
        elseif op === :setindex!
            indices = LinearIndices(value)[args[2:end]...]
            for index in (indices isa Integer ? (indices,) : indices)
                watch.positions[index] = 0
            end
        end
    elseif op === :empty!
        union!(watch.changed, watch.kind === :dict ? keys(value) : value)
    elseif op === :delete!
        push!(watch.changed, args[1])
    elseif op === :setindex! && watch.kind === :dict
        push!(watch.changed, length(args) == 2 ? args[2] : args[2:end])
    elseif op === :get! && watch.kind === :dict
        haskey(value, args[1]) || push!(watch.changed, args[1])
    elseif op === :push!
        for item in args
            if watch.kind === :dict
                push!(watch.changed, first(item))
            elseif !(item in value)
                push!(watch.changed, item)
            end
        end
    end
    return nothing
end

# All state-container writes, including the deferred queue and module metadata,
# pass through this helper. Mutation bookkeeping shares their transaction.
function _state_mutate_storage!(value, op::Symbol, args...)
    watches = get(_state_value(STATE_FILTERS), value, ())
    for watch in watches
        _observe_state_mutation!(watch, value, op, args)
    end
    try
        return getfield(Base, op)(value, args...)
    catch
        # A container operation can fail after a partial write (e.g. element
        # conversion during push!). Protect the remaining occurrences rather
        # than applying a stale positional plan to the partially changed value.
        for watch in watches
            if watch.kind === :vector
                watch.positions = zeros(Int, length(value))
            else
                union!(watch.changed, watch.kind === :dict ? keys(value) : value)
            end
        end
        rethrow()
    finally
        # Every state write invalidates every cached `CallTarget` (#253). Here,
        # rather than at the mutation sites, because this is the one helper they
        # all already pass through — a new registry or a new call to an existing
        # one cannot forget to do it. In `finally`, so the partially-applied
        # write of the `catch` branch above invalidates too, and **after** the
        # write: a reader that sampled the epoch before it and resolved before
        # the write now holds a stale epoch and will re-resolve, where bumping
        # first would let that reader stamp a stale snapshot as current.
        Threads.atomic_add!(ARTIFACT_EPOCH, 1)
    end
end

_state_mutate(view::StateView, op::Symbol, args...) = _state_read(view) do value
    _state_mutate_storage!(_filter_storage(view, value), op, args...)
end

function _filter_state!(predicate::Function, view::StateView)
    value, entries, watch = _state_read(view) do raw
        value = _filter_storage(view, raw)
        kind = value isa AbstractDict ? :dict : value isa AbstractVector ? :vector :
               value isa AbstractSet ? :set : nothing
        kind === nothing && throw(ArgumentError("filter! requires a dictionary, vector or set StateView"))
        entries = collect(value)
        watch = StateFilterWatch(kind, Set{Any}(), kind === :vector ? collect(eachindex(value)) : Int[])
        push!(get!(() -> StateFilterWatch[], _state_value(STATE_FILTERS), value), watch)
        (value, entries, watch)
    end
    try
        rejected = findall(entry -> !predicate(entry), entries)
        _state_read(view) do raw
            for token in rejected
                entry = entries[token]
                if watch.kind === :vector
                    index = findfirst(==(token), watch.positions)
                    index === nothing || _state_mutate_storage!(value, :deleteat!, index)
                elseif watch.kind === :dict
                    key, previous = entry
                    if !(key in watch.changed) && haskey(value, key) && value[key] === previous
                        _state_mutate_storage!(value, :delete!, key)
                    end
                elseif !(entry in watch.changed) && entry in value
                    _state_mutate_storage!(value, :delete!, entry)
                end
            end
        end
    finally
        _state_read(view) do raw
            watches = _state_value(STATE_FILTERS)[value]
            deleteat!(watches, findfirst(w -> w === watch, watches))
            isempty(watches) && delete!(_state_value(STATE_FILTERS), value)
        end
    end
    return view
end
