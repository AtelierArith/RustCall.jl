# Runtime state for modules containing inline rust blocks. Only immutable
# block records are serialized into a caller's precompile image; the mutable
# library/symbol/active tables are owned by the process STATE.
struct ModuleBlockRecord
    lib_name::String
    block::RustBlockSnapshot
    symbols::Tuple{Vararg{String}}
    order::Int
end

const MODULE_STATES = _state_view(:module_states, Dict{Module, Dict{Symbol, Any}}())
const MODULE_BLOCK_SEQUENCE = _state_view(:module_block_sequence, Ref(0))

function _module_block_records(mod::Module)
    records = ModuleBlockRecord[]
    for name in names(mod; all = true, imported = false)
        startswith(String(name), "##__RUSTCALL_BLOCK_SNAPSHOT#") || continue
        value = Base.invokelatest(getfield, mod, name)
        value isa ModuleBlockRecord && push!(records, value)
    end
    sort!(records; by = record -> record.order)
end

function _ensure_module_state!(mod::Module)
    existing = get(MODULE_STATES, mod, nothing)
    existing === nothing || return existing

    # Read precompile records and old-style user-provided containers outside
    # STATE. Legacy bindings remain usable, but newly generated bindings are
    # immutable StateViews and do not own separate Dicts or Refs.
    libs = _module_binding(mod, :__RUSTCALL_LIBS)
    symbols = _module_binding(mod, :__RUSTCALL_SYMBOL_LIB)
    active = _module_binding(mod, :__RUSTCALL_ACTIVE_LIB)
    libs = libs isa AbstractDict ? libs : Dict{String, Any}()
    symbols = symbols isa AbstractDict ? symbols : Dict{String, String}()
    active = active isa Ref ? active : Ref("")
    for record in _module_block_records(mod)
        libs[record.lib_name] = record.block
        for symbol in record.symbols
            symbols[symbol] = record.lib_name
        end
        active[] = record.lib_name
    end
    candidate = Dict{Symbol, Any}(
        :libs => libs, :symbols => symbols, :active => active,
        :crate_generation => Ref(CrateGeneration()),
        :crate_symbols => Dict{Tuple{Ptr{Cvoid}, String}, Ptr{Cvoid}}())
    return lock(REGISTRY_LOCK) do
        chosen = get!(MODULE_STATES, mod, candidate)
        isempty(chosen[:active][]) || get!(MODULE_ACTIVE_LIB, mod, chosen[:active][])
        chosen
    end
end

function _define_module_state_views!(mod::Module)
    for (binding, kind) in ((:__RUSTCALL_LIBS, :libs),
                            (:__RUSTCALL_SYMBOL_LIB, :symbols),
                            (:__RUSTCALL_ACTIVE_LIB, :active))
        if !isdefined(mod, binding)
            view = StateView(kind, mod)
            Core.eval(mod, Expr(:const, Expr(:(=), binding, QuoteNode(view))))
        end
    end
    return nothing
end

# Caller holds STATE. Check every name before changing any of the table.
function _module_symbol_conflict(table, lib_name::String, symbols)
    for symbol in symbols
        owner = get(table, symbol, "")
        if !isempty(owner) && owner != lib_name && haskey(RUST_LIBRARIES, owner)
            return (symbol, owner)
        end
    end
    return nothing
end

function _throw_module_symbol_conflict(conflict, module_name)
    symbol, owner = conflict
    throw(RustError("""
        `$(symbol)` is already exported by another `rust\"\"\"` block in module $(module_name).

        Two blocks of one module exporting the same name is an ambiguity, not an
        override: the Julia wrapper of the second would replace the first while both
        libraries stayed loaded, and which one a call reached would depend on the
        order they were compiled in.

        Either rename the Rust function, or drop the earlier block first:

            RustCall.unload_library("$(owner)")
        """))
end

function _record_module_block!(mod::Module, lib_name::String,
                               block::RustBlockSnapshot, symbols)
    names = Tuple(String.(symbols))
    _define_module_state_views!(mod)
    _ensure_module_state!(mod)
    result = lock(REGISTRY_LOCK) do
        data = MODULE_STATES[mod]
        conflict = _module_symbol_conflict(data[:symbols], lib_name, names)
        conflict === nothing || return conflict
        for symbol in names
            _state_mutate_storage!(data[:symbols], :setindex!, lib_name, symbol)
        end
        _state_mutate_storage!(data[:libs], :setindex!, block, lib_name)
        data[:active][] = lib_name
        MODULE_ACTIVE_LIB[mod] = lib_name
        MODULE_BLOCK_SEQUENCE[] += 1
        ModuleBlockRecord(lib_name, block, names, MODULE_BLOCK_SEQUENCE[])
    end
    result isa ModuleBlockRecord || _throw_module_symbol_conflict(result, nameof(mod))

    # Record actual execution order during precompilation, including repeated
    # executions of a literal. Ordinary runtime cache hits create no bindings.
    if Base.generating_output()
        binding = gensym(:__RUSTCALL_BLOCK_SNAPSHOT)
        Core.eval(mod, Expr(:const, Expr(:(=), binding, QuoteNode(result))))
    end
    return nothing
end

function _record_module_symbols_transaction!(table, lib_name, symbols, module_name)
    name = String(lib_name)
    names = Tuple(String.(symbols))
    update = function (values)
        conflict = _module_symbol_conflict(values, name, names)
        conflict === nothing || return conflict
        for symbol in names
            _state_mutate_storage!(values, :setindex!, name, symbol)
        end
        return nothing
    end
    conflict = if table isa StateView
        _state_read(table, update)
    else
        lock(REGISTRY_LOCK) do
            update(table)
        end
    end
    conflict === nothing || _throw_module_symbol_conflict(conflict, module_name)
    return nothing
end
