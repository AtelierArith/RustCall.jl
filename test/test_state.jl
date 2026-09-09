using Test
using RustCall

@testset "state cache factories run outside STATE and preserve a concurrent winner (#251)" begin
    view = lock(RustCall.REGISTRY_LOCK) do
        RustCall._state_view(gensym(:factory_test), Dict{String, Any}())
    end
    started = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    creator = Threads.@spawn get!(view, "key") do
        put!(started, nothing)
        take!(release)
        1
    end
    take!(started)
    updater = Threads.@spawn (view["key"] = 99)
    try
        @test timedwait(() -> istaskdone(updater), 5) == :ok
    finally
        put!(release, nothing)
    end
    @test fetch(creator) == 99
    wait(updater)
    @test view["key"] == 99
    @test get!(() -> error("must not evaluate an existing key"), view, "key") == 99
    view["nothing"] = nothing
    @test get!(() -> error("nothing is a cached value"), view, "nothing") === nothing
    @test_throws ErrorException get!(() -> error("factory failed"), view, "missing")
    @test !haskey(view, "missing")
    lock(RustCall.REGISTRY_LOCK) do
        delete!(RustCall.STATE.value.values, view.name)
    end
end

# Inspect values rather than constructor spellings: a registry returned by a
# factory must be caught too. Compiler-generated documentation metadata is not
# application state; immutable lookup tables and StateViews are safe to share.
function _contains_mutable_registry(value, seen = IdSet{Any}())
    value === RustCall.STATE && return false
    value isa Union{Type, Module, ReentrantLock, RustCall.StateView} && return false
    isbitstype(typeof(value)) && return false
    if value isa Union{AbstractDict, AbstractSet, Ref, AbstractArray} &&
       !(value isa Base.ImmutableDict)
        return true
    end
    value in seen && return false
    push!(seen, value)
    return any(1:fieldcount(typeof(value))) do index
        isdefined(value, index) && _contains_mutable_registry(getfield(value, index), seen)
    end
end

function _mutable_module_registries(mod::Module)
    found = Symbol[]
    for name in names(mod; all = true, imported = false)
        startswith(String(name), "##meta#") && continue
        isdefined(mod, name) || continue
        value = getfield(mod, name)
        if _contains_mutable_registry(value)
            push!(found, name)
        end
    end
    return sort!(found)
end

function _state_transaction_callouts(source::String, file = "fixture")
    tailname(x) = x isa Symbol ? x : x isa QuoteNode ? tailname(x.value) :
                  x isa Expr && x.head == :. ? tailname(x.args[end]) : nothing
    state_argument(x) = tailname(x) in (:STATE, :REGISTRY_LOCK, :RELOAD_LOCKS_LOCK,
                                       :DEFERRED_DROPS_LOCK) ||
                        (x isa Expr && x.head == :. && tailname(x) == :lock &&
                         tailname(x.args[1]) == :STATE)
    state_call(x) = x isa Expr && x.head == :call &&
        (tailname(x.args[1]) == :_state_read ||
         (tailname(x.args[1]) == :lock && any(state_argument, x.args[2:end])))
    forbidden = (:ccall, :run, :read, :write, :wait, :sleep, :yield, :dlopen, :dlclose,
                 :compile_rust_to_shared_lib, :expand_inline, :extract_manifest,
                 :monomorphize_function, :toolchain_fingerprint, :artifact_compiler_identity,
                 :rebuild_callback, :invokelatest, Symbol("@warn"), Symbol("@debug"),
                 Symbol("@info"), Symbol("@error"))
    found = Tuple{String, Int, Symbol}[]
    function walk(x, line = 1, held = false)
        x isa Expr || return
        if x.head in (:call, :macrocall) && held && tailname(x.args[1]) in forbidden
            push!(found, (file, line, tailname(x.args[1])))
        end
        guarded = held || state_call(x) || (x.head == :do && state_call(x.args[1])) ||
                  (x.head == :macrocall && tailname(x.args[1]) == Symbol("@lock") &&
                   any(state_argument, x.args[2:end]))
        for arg in x.args
            if arg isa LineNumberNode
                line = arg.line
            else
                walk(arg, line, guarded)
            end
        end
    end
    walk(Meta.parseall(source))
    return found
end

@testset "state transactions contain no blocking, FFI, or logging callouts (#251)" begin
    bad = """
        lock(REGISTRY_LOCK) do
            ccall(pointer, Cvoid, ())
            @warn "locked logger"
        end
        lock(() -> run(command), RustCall.REGISTRY_LOCK)
        Base.@lock STATE begin
            @info "locked logger"
        end
        """
    @test last.(_state_transaction_callouts(bad)) ==
          [:ccall, Symbol("@warn"), :run, Symbol("@info")]
    @test isempty(_state_transaction_callouts("lock(() -> read(io), other_lock)"))
    for file in readdir(dirname(pathof(RustCall)); join = true)
        endswith(file, ".jl") || continue
        callouts = _state_transaction_callouts(read(file, String), basename(file))
        @test isempty(callouts)
    end
end

@testset "registry guard detects newly named mutable bindings (#251)" begin
    fixture = Module(:NewRegistryFixture)
    Core.eval(fixture, quote
        make_registry() = Dict{String, Int}()
        const NEW_DICTIONARY = make_registry()
        const NEW_REFERENCE = Ref(0)
        const NEW_SET = Set{String}()
        const NEW_VECTOR = String[]
        const WRAPPED_STATE = (cache = Dict{String, Int}(),)
        const STATIC_TUPLE = ("a", "b")
        const STATIC_MAP = Base.ImmutableDict("a" => 1)
    end)
    @test _mutable_module_registries(fixture) ==
          [:NEW_DICTIONARY, :NEW_REFERENCE, :NEW_SET, :NEW_VECTOR, :WRAPPED_STATE]
    @test isempty(_mutable_module_registries(RustCall))
end

@testset "compiler initialization cannot overwrite a concurrent setter (#251)" begin
    started = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    original = RustCall._state_read(RustCall.DEFAULT_COMPILER, identity)
    initializer = nothing
    try
        lock(RustCall.STATE.lock) do
            RustCall.STATE.value.values[:default_compiler] = Ref{RustCall.RustCompiler}()
        end
        initializer = Threads.@spawn RustCall._default_compiler() do
            put!(started, nothing)
            take!(release)
            RustCall.RustCompiler(optimization_level = 2)
        end
        take!(started)
        chosen = RustCall.RustCompiler(optimization_level = 0)
        observer = Threads.@spawn begin
            RustCall.set_default_compiler(chosen)
            true
        end
        @test timedwait(() -> istaskdone(observer), 5) == :ok
        put!(release, nothing)
        @test fetch(initializer) === chosen
        @test RustCall.get_default_compiler() === chosen
        @test fetch(observer)
    finally
        if initializer !== nothing && !istaskdone(initializer)
            isready(release) || put!(release, nothing)
            wait(initializer)
        end
        lock(RustCall.STATE.lock) do
            RustCall.STATE.value.values[:default_compiler] = original
        end
    end
end

@testset "specialization releases STATE before waiting for the extractor" begin
    for grouped in (false, true)
        name = grouped ? "state_lock_grouped" : "state_lock_plain"
        source = "pub fn $name<T: Copy>(x: T) -> T { x }"
        RustCall.register_generic_function(name, source, [:T];
            group = grouped ? :state_lock_test_group : nothing)
        started = Channel{Nothing}(1)
        compilation = nothing
        observer = nothing
        lock(RustCall._EXTRACTOR_LOCK)
        try
            compilation = Threads.@spawn begin
                put!(started, nothing)
                RustCall.monomorphize_function(name, Dict(:T => Int32))
            end
            take!(started)
            # Allow specialization to reach extractor identity resolution.
            sleep(0.2)
            observer = Threads.@spawn lock(() -> true, RustCall.REGISTRY_LOCK)
            @test timedwait(() -> istaskdone(observer), 5.0) === :ok
        finally
            unlock(RustCall._EXTRACTOR_LOCK)
        end
        @test fetch(observer)
        info = fetch(compilation)
        @test RustCall._call_monomorphized(info, Int32(17)) == 17
        @test RustCall.get_monomorphized_function(name, Dict(:T => Int32)) === info
    end
end

@testset "unknown image yields an inert liveness Ref" begin
    alive = RustCall.alive_ref_for_handle(C_NULL, "unregistered_state_test")
    @test alive isa Base.RefValue{Bool}
    @test !alive[]
    @test RustCall.alive_ref_for_handle(C_NULL, "another_unregistered_state_test") === alive
    generation = RustCall.generic_struct_generation_snapshot(
        "missing_state_test_destructor", (Int32,), "missing_state_test_library")
    @test generation.free_ptr == C_NULL
    @test generation.alive === alive
    @test !generation.alive[]
end

@testset "the mutable runtime registry lives in one Lockable state (#251)" begin
    @test RustCall.STATE isa Base.Lockable
    @test RustCall.REGISTRY_LOCK === RustCall.STATE.lock

    registry_views = (
        :RUST_LIBRARIES, :CURRENT_LIB, :MODULE_ACTIVE_LIB,
        :FUNCTION_REGISTRY, :FUNCTION_REGISTRY_BY_LIB,
        :FUNCTION_RETURN_TYPES_BY_LIB, :FUNCTION_SYMBOLS_BY_LIB,
        :PANIC_CHANNELS, :GENERIC_FUNCTION_REGISTRY,
        :MONOMORPHIZED_FUNCTIONS, :GENERIC_STRUCT_ARTIFACTS, :IRUST_FUNCTIONS, :HOT_RELOAD_REGISTRY,
        :RELOAD_LOCKS, :ARTIFACT_ALIVE,
        :ARTIFACT_GENERATIONS, :HANDLE_MIRRORS, :RETIRED_HANDLES,
        :OWNED_HANDLES, :PRELOADED_LIBRARIES, :HANDLE_ONLY_ALIVE, :DEFERRED_DROPS,
        :_ARTIFACT_COMPILER_IDENTITY,
    )
    source = read(joinpath(dirname(pathof(RustCall)), "RustCall.jl"), String)
    for name in registry_views
        @test isdefined(RustCall, name)
        @test getfield(RustCall, name) isa RustCall.StateView
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
