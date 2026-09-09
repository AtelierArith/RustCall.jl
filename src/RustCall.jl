"""
    RustCall.jl

A Foreign Function Interface (FFI) package for calling Rust code from Julia
through a C-compatible ABI.

# Exported Macros
- `@rust`: Call a registered Rust function
- `@rust_str`: Compile and register Rust code (rust"" string literal)

# Example
```julia
using RustCall

# Define Rust code
rust\"\"\"
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}
\"\"\"

# Call the function
result = @rust add(10i32, 20i32)
```
"""
module RustCall

using Libdl

"""
    RustCallState

The mutable process state of RustCall.  The value is held by `STATE`, a
`Base.Lockable`, so registry objects are never declared as independent module
globals.  `StateView` is a compatibility handle used by the older internal
names; every operation on it takes the state lock, including reads made by
tests and extensions.

Static lookup tables are immutable dictionaries or tuples, not mutable
registries. `test/test_state.jl` inspects all module bindings, including values
returned by factories and containers nested in immutable wrappers, so a newly
named mutable registry cannot bypass the declaration guard. The compiler's
documentation metadata and synchronization primitives are not application
registries; captured per-object liveness flags belong to the state-owned images.

The state lock is the outer lock in RustCall's lock-ordering policy.  Code
under it may only manipulate state and resolve already-loaded pointers; it must
not call user Julia code, compile, `dlopen`/`dlclose`, or execute a `ccall`.
Those operations happen before or after the locked transaction.
"""
mutable struct RustCallState
    values::Dict{Symbol, Any}
end

const STATE = Base.Lockable(RustCallState(Dict{Symbol, Any}()))

struct StateView
    name::Symbol
    owner::Union{Nothing, Module}
end
StateView(name::Symbol) = StateView(name, nothing)

_state_value(view::StateView) = view.owner === nothing ? STATE.value.values[view.name] :
    STATE.value.values[:module_states][view.owner][view.name]

function _state_view(name::Symbol, value)
    STATE.value.values[name] = value
    return StateView(name)
end

function _state_read(view::StateView, f::Function)
    view.owner === nothing || _ensure_module_state!(view.owner)
    lock(STATE.lock) do
        f(_state_value(view))
    end
end
_state_read(f::Function, view::StateView) = _state_read(view, f)

Base.getindex(view::StateView) = _state_read(view) do value
    value isa Ref ? value[] : value
end
Base.isassigned(view::StateView) = _state_read(view) do value
    value isa Ref ? isassigned(value) : true
end
Base.getindex(view::StateView, key...) = _state_read(view) do value
    getindex(value, key...)
end
Base.setindex!(view::StateView, value) = _state_read(view) do state_value
    state_value[] = value
end
Base.setindex!(view::StateView, value, key...) = _state_read(view) do state_value
    setindex!(state_value, value, key...)
end
Base.get(view::StateView, key, default) = _state_read(view) do state_value
    get(state_value, key, default)
end
Base.get!(view::StateView, key, default) = _state_read(view) do state_value
    get!(state_value, key, default)
end
function Base.get!(default::Function, view::StateView, key)
    cached = _state_read(view) do state_value
        haskey(state_value, key) ? Some(state_value[key]) : nothing
    end
    cached === nothing || return something(cached)
    # A default may run rustc/Cargo or arbitrary caller code. Do not hold
    # STATE during its evaluation; another publisher may win in the meantime.
    candidate = default()
    return get!(view, key, candidate)
end
Base.haskey(view::StateView, key) = _state_read(view) do state_value
    haskey(state_value, key)
end
Base.delete!(view::StateView, key) = _state_read(view) do state_value
    delete!(state_value, key)
end
Base.empty!(view::StateView) = _state_read(view) do state_value
    empty!(state_value)
end
function Base.push!(view::StateView, items...)
    if view.name === :deferred_drops
        return lock(DEFERRED_DROPS_LOCK) do
            queue = _state_value(view)
            push!(getfield(queue, :entries), items...)
        end
    end
    return _state_read(view) do state_value
        push!(state_value, items...)
    end
end
Base.prepend!(view::StateView, items) = _state_read(view) do state_value
    prepend!(state_value, items)
end
function Base.filter!(predicate::Function, view::StateView)
    storage(value) = view.name === :deferred_drops && view.owner === nothing ?
                     getfield(value, :entries) : value
    snapshot = _state_read(view) do value
        copy(storage(value))
    end
    # Predicates are caller code and may wait for another registry user.
    # Evaluate once per snapshot entry without STATE, then remove only entries
    # which have not been replaced. Concurrent additions are not filtered.
    rejected = [entry for entry in snapshot if !predicate(entry)]
    _state_read(view) do value
        current = storage(value)
        if current isa AbstractDict
            for (key, previous) in rejected
                haskey(current, key) && current[key] === previous && delete!(current, key)
            end
        elseif current isa AbstractVector
            for previous in rejected
                index = findfirst(entry -> entry === previous, current)
                index === nothing || deleteat!(current, index)
            end
        elseif current isa AbstractSet
            for previous in rejected
                for entry in current
                    if entry === previous
                        delete!(current, entry)
                        break
                    end
                end
            end
        else
            throw(ArgumentError("filter! requires a dictionary, vector or set StateView"))
        end
    end
    return view
end
Base.isempty(view::StateView) = _state_read(view, isempty)
Base.length(view::StateView) = _state_read(view, length)
Base.copy(view::StateView) = _state_read(view, copy)
Base.keys(view::StateView) = _state_read(view) do value
    collect(keys(value))
end
Base.values(view::StateView) = _state_read(view) do value
    collect(values(value))
end

# Iteration uses a snapshot so the state lock is not held across user code.
function Base.iterate(view::StateView)
    snapshot = _state_read(view, copy)
    item = iterate(snapshot)
    item === nothing && return nothing
    value, cursor = item
    return value, (snapshot, cursor)
end
function Base.iterate(view::StateView, state::Tuple{Any, Any})
    snapshot, cursor = state
    item = iterate(snapshot, cursor)
    item === nothing && return nothing
    value, next_cursor = item
    return value, (snapshot, next_cursor)
end

# Thread-safety lock for the state container.  It remains named for internal
# compatibility, but the lock now belongs to STATE rather than to a free
# standing registry.
const REGISTRY_LOCK = STATE.lock

# Include submodules in order of dependency
include("types.jl")
include("typetranslation.jl")
include("ffi_contract.jl")
# rustc's `--error-format=json` diagnostics, read as data rather than as text
# (#348). Depends on nothing; must precede compiler.jl, which probes with it.
include("rustc_json.jl")
include("compiler.jl")
include("codegen.jl")
include("exceptions.jl")
include("cache.jl")

# Explicit load/compile policy object (#277, Phase A). Additive: not yet used
# by any call site. Functions here reference RUST_LIBRARIES / CURRENT_LIB from
# ruststr.jl, which is resolved at call time, so it can sit right after cache.jl.
include("loadpolicy.jl")

# Artifact identity (#278, Phase A). Also right after cache.jl: it is the
# identity layer the cache sits on and it needs nothing beyond
# exceptions.jl/compiler.jl (both already included) at load time;
# toolchain_fingerprint() from manifest.jl is only called at run time.
include("artifact_id.jl")

include("memory.jl")

# Phase 3: External library integration
include("dependencies.jl")
include("dependency_resolution.jl")
include("cargoproject.jl")
include("cargobuild.jl")

include("ruststr.jl")
include("module_state.jl")
include("rustmacro.jl")

# Phase 2: Generics support
include("generics.jl")

# Phase 4: Object mapping support
include("structs.jl")

# Phase 5: #[julia] attribute support
include("julia_functions.jl")

# FFI manifest consumption (rustcall-extract CLI); depends on the types above
include("manifest.jl")

# Phase 6: External crate bindings (Maturin-like feature)
include("crate_bindings.jl")

# PyO3 crates without a RustCall attribute: scan reporting and the link plan
# a wrapper crate needs (#275). Depends on scan_crate from crate_bindings.jl.
include("pyo3.jl")

# Hot reload support
include("hot_reload.jl")

# Export public API — only macros/string literals are exported.
# All other identifiers are accessible via RustCall.XXX or import RustCall: XXX.
export @rust, @rust_str, @irust, @irust_str
export @rust_crate
# The by-value opt-in of #245. A macro, because it must define its method in
# the *calling* module for that method to survive the caller's precompilation.
export @register_ffi_struct

# Module initialization
function __init__()
    # The deprecated RTLD_GLOBAL escape hatch (#250, #277 Phase B2), read once:
    # a load policy must not change halfway through a session.
    _init_dlopen_global_override!()

    # Check for rustc availability
    if !check_rustc_available()
        @warn """
        No working rustc found. RustCall.jl resolves the compiler through RustToolChain.jl,
        which uses a `rustc` on PATH when there is one and otherwise the toolchain it
        provides through Julia's Artifacts system; neither could be run.

        To see the underlying error, run the same resolution yourself:
            using RustToolChain; run(`\$(RustToolChain.rustc()) --version`)

        Remedies: install Rust with rustup (https://rustup.rs) so a `rustc` is on PATH,
        or make the artifact download possible (network access, a writable depot) and
        retry. On Windows the artifact toolchain also needs the MSVC build tools; see the
        RustToolChain.jl README.
        """
    end

    # Try to load Rust helpers library
    if !try_load_rust_helpers()
        # Only show warning once, not on every test
        if !haskey(ENV, "RUSTCALL_SUPPRESS_HELPERS_WARNING")
            @warn """
            Rust helpers library not found. Ownership types (Box, Rc, Arc) will not work until the library is built.

            To build the library, run:
                using Pkg; Pkg.build("RustCall")
            Or from command line:
                julia --project -e 'using Pkg; Pkg.build("RustCall")'

            To suppress this warning, set:
                ENV["RUSTCALL_SUPPRESS_HELPERS_WARNING"] = "1"
            """
        end
    else
        @debug "Rust helpers library loaded successfully."
    end
end

end # module RustCall
