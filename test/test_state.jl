using Test
using RustCall

@testset "invalid registration inputs do not acquire a loader reference (#251)" begin
    name = RustCall._compile_and_load_rust(
        "#[julia] pub fn metadata_open_probe() -> i32 { 251 }", "metadata_open", 1)
    handle = RustCall.RUST_LIBRARIES[name][1]
    path = RustCall.Libdl.dlpath(handle)
    before = RustCall.artifact_handle_open_count(handle)
    alive = RustCall.artifact_alive_ref(name)
    policy = RustCall.inline_rustc_policy()
    try
        @test_throws ArgumentError RustCall.load_artifact!(policy, path;
            lib_name = "invalid_metadata_open", return_types = ("value" => 123,))
        @test RustCall.artifact_handle_open_count(handle) == before
        @test !haskey(RustCall.RUST_LIBRARIES, "invalid_metadata_open")
        eager = (error("eager iterator failed") for _ in 1:1)
        @test_throws ErrorException RustCall.load_artifact!(policy, path;
            lib_name = "invalid_metadata_open", eager)
        @test RustCall.artifact_handle_open_count(handle) == before
        @test alive[]
        target = RustCall.resolve_call_target(name, "metadata_open_probe")
        @test RustCall.call_rust_function(target.func_ptr, Int32) == 251
    finally
        # Also balance leaked references if this regression fails.
        while RustCall.artifact_handle_open_count(handle) > before
            RustCall.close_artifact_handle!(handle)
        end
        RustCall.unload_library(name; close = true)
    end
end

struct PausedStateString <: AbstractString
    entered::Channel{Nothing}
    release::Channel{Nothing}
end
function Base.String(value::PausedStateString)
    put!(value.entered, nothing)
    take!(value.release)
    "state_string_probe_251"
end

struct PausedLegacyStateRef <: Ref{String}
    entered::Channel{Nothing}
    release::Channel{Nothing}
end
function Base.getindex(value::PausedLegacyStateRef)
    put!(value.entered, nothing)
    take!(value.release)
    ""
end

@testset "legacy module adoption copies containers outside STATE (#251)" begin
    entered, release = Channel{Nothing}(1), Channel{Nothing}(1)
    scope = Module(:LegacyOwnedState251)
    libs, symbols = Dict{String, Any}(), Dict{String, String}()
    active = PausedLegacyStateRef(entered, release)
    for (binding, value) in ((:__RUSTCALL_LIBS, libs),
                              (:__RUSTCALL_SYMBOL_LIB, symbols),
                              (:__RUSTCALL_ACTIVE_LIB, active))
        Core.eval(scope, :(const $binding = $(QuoteNode(value))))
    end
    worker = Threads.@spawn RustCall._ensure_module_state!(scope)
    take!(entered)
    observer = Threads.@spawn RustCall.CURRENT_LIB[]
    try
        @test timedwait(() -> istaskdone(observer), 5) == :ok
    finally
        put!(release, nothing)
    end
    try
        data = fetch(worker)
        fetch(observer)
        @test data[:libs] !== libs
        @test data[:symbols] !== symbols
        @test data[:active] !== active
        @test data[:active][] == ""
        block = RustCall.RustBlockSnapshot("", "", "", 0)
        RustCall._record_module_block!(scope, "legacy_owned", block, ("value",))
        for binding in (:__RUSTCALL_LIBS, :__RUSTCALL_SYMBOL_LIB, :__RUSTCALL_ACTIVE_LIB)
            @test RustCall._module_binding(scope, binding) isa RustCall.StateView
        end
        @test RustCall._module_binding(scope, :__RUSTCALL_LIBS)["legacy_owned"] === block
        @test RustCall._module_binding(scope, :__RUSTCALL_SYMBOL_LIB)["value"] == "legacy_owned"
        @test RustCall._module_binding(scope, :__RUSTCALL_ACTIVE_LIB)[] == "legacy_owned"
        @test isempty(libs) && isempty(symbols)
        @test RustCall._ensure_module_state!(scope) === data
    finally
        delete!(RustCall.MODULE_STATES, scope)
        delete!(RustCall.MODULE_ACTIVE_LIB, scope)
    end
end

@testset "registry argument conversion and retirement iteration release STATE (#251)" begin
    operations = (
        name -> RustCall.register_function_symbol(name, "value", "exported_value"),
        name -> RustCall.exported_symbol(name, "value"),
        RustCall.artifact_generation,
        RustCall.retired_handles,
        name -> RustCall._generic_struct_free_target(name, ()),
    )
    for operation in operations
        entered, release = Channel{Nothing}(1), Channel{Nothing}(1)
        worker = Threads.@spawn operation(PausedStateString(entered, release))
        take!(entered)
        observer = Threads.@spawn RustCall.CURRENT_LIB[]
        try
            @test timedwait(() -> istaskdone(observer), 5) == :ok
        finally
            put!(release, nothing)
        end
        fetch(worker)
        fetch(observer)
    end
    RustCall.clear_library_metadata!("state_string_probe_251")
    entered, release = Channel{Nothing}(1), Channel{Nothing}(1)
    handles = (begin
        put!(entered, nothing)
        take!(release)
        Ptr{Cvoid}(C_NULL)
    end for _ in 1:1)
    worker = Threads.@spawn RustCall.close_retired_handles!(handles)
    take!(entered)
    observer = Threads.@spawn RustCall.CURRENT_LIB[]
    try
        @test timedwait(() -> istaskdone(observer), 5) == :ok
    finally
        put!(release, nothing)
    end
    @test fetch(worker) == 0
    fetch(observer)
end

@testset "metadata iterators run outside STATE and fail before publication (#251)" begin
    policy = RustCall.inline_rustc_policy()
    for adopt in (false, true), field in (:symbols, :return_types)
        name = "state_metadata_$(adopt)_$(field)"
        entered, release = Channel{Nothing}(1), Channel{Nothing}(1)
        row = field === :symbols ? "value" => "exported_value" : "value" => Int32
        rows = (begin
            put!(entered, nothing)
            take!(release)
            row
        end for _ in 1:1)
        worker = Threads.@spawn begin
            kwargs = NamedTuple{(field,)}((rows,))
            if adopt
                RustCall.adopt_artifact!(policy, Ptr{Cvoid}(UInt(0x251));
                    lib_name = name, set_current = false, kwargs...)
            else
                RustCall.register_artifact_metadata!(policy, name;
                    set_current = false, kwargs...)
            end
        end
        ready = timedwait(() -> isready(entered) || istaskdone(worker), 10)
        ready == :ok || error("metadata worker did not reach its iterator")
        istaskdone(worker) && fetch(worker)
        take!(entered)
        observer = Threads.@spawn RustCall.CURRENT_LIB[]
        try
            @test timedwait(() -> istaskdone(observer), 5) == :ok
        finally
            put!(release, nothing)
        end
        try
            fetch(worker)
            fetch(observer)
            @test field === :symbols ? RustCall.exported_symbol(name, "value") == "exported_value" :
                  RustCall.get_function_return_type(name, "value") === Int32
            @test_throws ArgumentError RustCall.register_artifact_metadata!(policy, name;
                symbols = ("value" => "wrong",), return_types = ("value" => 123,),
                set_current = false)
            @test field === :symbols ? RustCall.exported_symbol(name, "value") == "exported_value" :
                  RustCall.get_function_return_type(name, "value") === Int32
        finally
            if adopt
                RustCall.unload_artifact!(policy, name)
                RustCall.close_retired_handles!(RustCall.retired_handles(name))
            else
                RustCall.clear_library_metadata!(name)
            end
        end
    end
end

@testset "cold symbol resolution releases STATE and retains the captured generation (#251)" begin
    source(type, value) = """
        #[julia]
        pub fn state_lookup_value() -> $type { $value }
        #[no_mangle]
        pub extern "C" fn state_lookup_release() {}
        #[no_mangle]
        pub extern "C" fn state_lookup_release_take_panic(_out: *mut u8, _cap: usize) -> usize { 0 }
        """
    old = RustCall._compile_and_load_rust(source("i32", "111"), "state_lookup", 1)
    replacement = RustCall._compile_and_load_rust(source("f64", "222.0"), "state_lookup", 1)
    old_handle = RustCall.RUST_LIBRARIES[old][1]
    replacement_handle = RustCall.RUST_LIBRARIES[replacement][1]
    # An explicit cached signature must not override the replacement's ABI
    # after this name is redirected to a different image.
    registered = RustCall.register_function("state_lookup_value", old, Int32, Type[])
    lock(RustCall.REGISTRY_LOCK) do
        empty!(RustCall.RUST_LIBRARIES[old][2])
        delete!(RustCall.PANIC_CHANNELS, (old, "rustcall_state_lookup_value"))
    end
    entered, release = Channel{Nothing}(1), Channel{Nothing}(1)
    first_lookup = Ref(true)
    function paused_lookup(handle, symbol; throw_error = false)
        if first_lookup[]
            first_lookup[] = false
            put!(entered, nothing)
            take!(release)
        end
        RustCall.Libdl.dlsym(handle, symbol; throw_error)
    end
    worker = Threads.@spawn RustCall.resolve_call_target(old, "state_lookup_value";
        free_symbol = "state_lookup_release", _lookup = paused_lookup)
    take!(entered)
    publisher = Threads.@spawn RustCall.alias_artifact!(
        RustCall.inline_rustc_policy(), replacement, old)
    try
        @test timedwait(() -> istaskdone(publisher), 5) == :ok
    finally
        put!(release, nothing)
    end
    try
        target = fetch(worker)
        wait(publisher)
        @test target.handle == old_handle
        @test target.alive[]
        @test target.return_type === Int32
        @test target.func_info === registered
        @test RustCall.call_rust_function(target.func_ptr, Int32) == 111
        @test target.channel == RustCall.Libdl.dlsym(old_handle, "rustcall_state_lookup_value_take_panic")
        @test target.free_ptr == RustCall.Libdl.dlsym(old_handle, "state_lookup_release")
        @test target.free_channel == RustCall.Libdl.dlsym(old_handle, "state_lookup_release_take_panic")
        current = RustCall.resolve_call_target(old, "state_lookup_value";
            free_symbol = "state_lookup_release")
        @test current.handle == replacement_handle
        @test current.return_type === Float64
        @test current.func_info === nothing
        @test RustCall._snapshot_return_type(current) === Float64
        @test RustCall.call_rust_function(current.func_ptr, Float64) == 222.0
        @test current.free_ptr == RustCall.Libdl.dlsym(replacement_handle, "state_lookup_release")
        @test current.free_channel == RustCall.Libdl.dlsym(replacement_handle, "state_lookup_release_take_panic")
        @test current.free_channel != target.free_channel
        @test current.generation == target.generation + 1
        RustCall.alias_artifact!(RustCall.inline_rustc_policy(), replacement, old)
        @test RustCall.resolve_call_target(old, "state_lookup_value").generation == current.generation
    finally
        for name in (old, replacement)
            haskey(RustCall.RUST_LIBRARIES, name) && RustCall.unload_library(name; close = true)
            RustCall.close_retired_handles!(RustCall.retired_handles(name))
        end
    end
end

@testset "state filters preserve delete/reinsert updates and release mutation watches (#251)" begin
    for original in (Dict("key" => 1), [1], Set([1]))
        view = lock(RustCall.REGISTRY_LOCK) do
            RustCall._state_view(gensym(:aba_probe), copy(original))
        end
        entered, release = Channel{Nothing}(1), Channel{Nothing}(1)
        worker = Threads.@spawn filter!(view) do entry
            put!(entered, nothing)
            take!(release)
            false
        end
        take!(entered)
        if original isa AbstractDict
            delete!(view, "key")
            view["key"] = 1
        else
            empty!(view)
            push!(view, 1)
        end
        put!(release, nothing)
        fetch(worker)
        try
            @test copy(view) == original
            snapshot = view[]
            empty!(snapshot)
            @test copy(view) == original
            @test isempty(RustCall.STATE_FILTERS)
            @test_throws ErrorException filter!(_ -> error("failed predicate"), view)
            @test isempty(RustCall.STATE_FILTERS)
        finally
            lock(RustCall.REGISTRY_LOCK) do
                delete!(RustCall.STATE.value.values, view.name)
            end
        end
    end

    # A flush can drain and requeue an identical deferred drop while a filter
    # is paused. These internal queue writes also participate in tracking.
    queue = RustCall.DEFERRED_DROPS
    entry = RustCall.DeferredDrop(Ptr{Cvoid}(123), "aba_queue", :unused)
    saved = lock(RustCall.REGISTRY_LOCK) do
        value = RustCall._state_value(queue).entries
        saved = copy(value)
        RustCall._state_mutate_storage!(value, :empty!)
        saved
    end
    push!(queue, entry)
    entered, release = Channel{Nothing}(1), Channel{Nothing}(1)
    worker = Threads.@spawn filter!(queue) do item
        put!(entered, nothing)
        take!(release)
        false
    end
    take!(entered)
    lock(RustCall.REGISTRY_LOCK) do
        value = RustCall._state_value(queue).entries
        RustCall._state_mutate_storage!(value, :empty!)
        RustCall._state_mutate_storage!(value, :prepend!, [entry])
    end
    put!(release, nothing)
    fetch(worker)
    try
        @test lock(RustCall.REGISTRY_LOCK) do
            RustCall._state_value(queue).entries == [entry]
        end
        @test isempty(RustCall.STATE_FILTERS)
    finally
        lock(RustCall.REGISTRY_LOCK) do
            value = RustCall._state_value(queue).entries
            RustCall._state_mutate_storage!(value, :empty!)
            RustCall._state_mutate_storage!(value, :prepend!, saved)
        end
    end
end

@testset "FFI layout callbacks and method definitions run outside STATE (#251)" begin
    scope = Module(gensym(:FFIStateAudit))
    Core.eval(scope, :(using RustCall))
    Core.eval(scope, :(struct AuditValue; x::Int32; end))
    T = Base.invokelatest(getfield, scope, :AuditValue)
    entered, release = Channel{Nothing}(1), Channel{Nothing}(1)
    Core.eval(scope, quote
        function RustCall.ffi_by_value_layout(::Type{$T})
            put!($entered, nothing)
            take!($release)
            :repr_c
        end
    end)
    registrar = Threads.@spawn RustCall.register_ffi_struct(T)
    take!(entered)
    observer = Threads.@spawn lock(() -> true, RustCall.REGISTRY_LOCK)
    # Releasing only STATE is insufficient: the callback must also let a
    # different task acquire the definition gate.
    gate_observer = Threads.@spawn lock(() -> true, RustCall.FFI_METHOD_LOCK[])
    try
        @test timedwait(() -> istaskdone(observer), 5) == :ok
        @test timedwait(() -> istaskdone(gate_observer), 5) == :ok
    finally
        put!(release, nothing)
    end
    try
        @test fetch(registrar) === T
        @test fetch(observer)
        @test fetch(gate_observer)
    finally
        @test RustCall.unregister_ffi_struct(T)
    end
    @test RustCall.register_ffi_struct(T) === T
    @test RustCall.unregister_ffi_struct(T)
end

@testset "state filter predicates run outside STATE and retain concurrent writes (#251)" begin
    for initial in (Dict("old" => 1), [1], Set([1]))
        view = lock(RustCall.REGISTRY_LOCK) do
            RustCall._state_view(gensym(:filter_test), initial)
        end
        entered = Channel{Nothing}(1)
        release = Channel{Nothing}(1)
        worker = Threads.@spawn filter!(view) do entry
            put!(entered, nothing)
            take!(release)
            false
        end
        take!(entered)
        writer = Threads.@spawn begin
            if initial isa AbstractDict
                view["old"] = 2
                view["added"] = 3
            else
                push!(view, 2)
            end
        end
        try
            @test timedwait(() -> istaskdone(writer), 5) == :ok
        finally
            put!(release, nothing)
        end
        @test fetch(worker) === view
        wait(writer)
        @test copy(view) == (initial isa AbstractDict ? Dict("old" => 2, "added" => 3) :
                            initial isa AbstractSet ? Set([2]) : [2])
        previous = copy(view)
        @test_throws ErrorException filter!(_ -> error("predicate failed"), view)
        @test copy(view) == previous
        lock(RustCall.REGISTRY_LOCK) do
            delete!(RustCall.STATE.value.values, view.name)
        end
    end

    # The deferred queue uses the same snapshot protocol even though its
    # entries are wrapped in a queue rather than stored directly in STATE.
    queue = RustCall.DEFERRED_DROPS
    original = lock(RustCall.REGISTRY_LOCK) do
        entries = RustCall._state_value(queue).entries
        saved = copy(entries)
        empty!(entries)
        saved
    end
    old = RustCall.DeferredDrop(Ptr{Cvoid}(1), "filter-old", :unused)
    added = RustCall.DeferredDrop(Ptr{Cvoid}(2), "filter-new", :unused)
    entered = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    push!(queue, old)
    worker = Threads.@spawn filter!(queue) do entry
        put!(entered, nothing)
        take!(release)
        false
    end
    take!(entered)
    writer = Threads.@spawn push!(queue, added)
    try
        @test timedwait(() -> istaskdone(writer), 5) == :ok
    finally
        put!(release, nothing)
    end
    try
        @test fetch(worker) === queue
        wait(writer)
        @test lock(RustCall.REGISTRY_LOCK) do
            RustCall._state_value(queue).entries == [added]
        end
    finally
        lock(RustCall.REGISTRY_LOCK) do
            entries = RustCall._state_value(queue).entries
            empty!(entries)
            append!(entries, original)
        end
    end
end

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
                 :eval, :delete_method, :_ffi_by_value_agrees, :dlsym, :_lookup,
                 :prepare_library_metadata, :String,
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
        :RUST_LIBRARIES, :CURRENT_LIB, :MODULE_ACTIVE_LIB, :MODULE_STATES, :MODULE_BLOCK_SEQUENCE,
        :FUNCTION_REGISTRY, :FUNCTION_REGISTRY_BY_LIB,
        :FUNCTION_RETURN_TYPES_BY_LIB, :FUNCTION_SYMBOLS_BY_LIB,
        :PANIC_CHANNELS, :GENERIC_FUNCTION_REGISTRY,
        :MONOMORPHIZED_FUNCTIONS, :GENERIC_STRUCT_ARTIFACTS, :IRUST_FUNCTIONS, :HOT_RELOAD_REGISTRY,
        :STATE_FILTERS, :FFI_METHOD_LOCK,
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

@testset "generated module registries are state-owned and publish atomically (#251)" begin
    scopes = [Module(gensym(:ModuleState)) for _ in 1:2]
    libraries = String[]
    try
        for (value, scope) in enumerate(scopes)
            Core.eval(scope, :(using RustCall))
            source = "#[julia] pub fn scoped_state_value() -> i32 { $value }"
            library = Core.eval(scope, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(0), source))
            push!(libraries, library)
            for binding in (:__RUSTCALL_LIBS, :__RUSTCALL_SYMBOL_LIB, :__RUSTCALL_ACTIVE_LIB)
                view = RustCall._module_binding(scope, binding)
                @test view isa RustCall.StateView
                @test view.owner === scope
            end
            @test isempty(_mutable_module_registries(scope))
            @test isempty(RustCall._module_block_records(scope)) # no runtime metadata accumulation
            @test Base.invokelatest(RustCall._module_binding(scope, :scoped_state_value)) == value
        end
        scope = scopes[1]
        symbols = RustCall._module_binding(scope, :__RUSTCALL_SYMBOL_LIB)
        libs = RustCall._module_binding(scope, :__RUSTCALL_LIBS)
        active = RustCall._module_binding(scope, :__RUSTCALL_ACTIVE_LIB)
        old_symbols, old_libs, old_active = copy(symbols), copy(libs), active[]
        @test_throws RustCall.RustError RustCall._record_module_symbols!(
            symbols, "other_owner", ["fresh_symbol", "rustcall_scoped_state_value"], nameof(scope))
        @test copy(symbols) == old_symbols
        @test_throws RustCall.RustError RustCall._record_module_block!(
            scope, "other_owner", libs[libraries[1]], ["fresh_symbol", "rustcall_scoped_state_value"])
        @test copy(symbols) == old_symbols
        @test copy(libs) == old_libs
        @test active[] == old_active
        @test Base.invokelatest(RustCall._module_binding(scopes[2], :scoped_state_value)) == 2
    finally
        for library in libraries
            RustCall.unload_library(library; close = true)
        end
    end
end

@testset "both crate module templates keep runtime registries in STATE (#251)" begin
    fixture = joinpath(@__DIR__, "fixtures", "sample_crate")
    scope = Module(gensym(:CrateStateScope))
    Core.eval(scope, :(using RustCall))
    modules = Module[]
    libraries = String[]
    try
        bindings = RustCall.load_crate_bindings(fixture;
            submodule_name = "OwnedCrateState", target_module = scope)
        direct = getfield(bindings, :module_ref)
        push!(modules, direct)
        push!(libraries, RustCall._module_binding(direct, :_LIB_NAME))
        info = RustCall.scan_crate(fixture)
        code = RustCall.emit_crate_module_code(info,
            RustCall._module_binding(direct, :_LIB_PATH);
            module_name = "OwnedEmittedState", lib_name = "owned_emitted_state_251")
        emitted = RustCall._instantiate_runtime_bindings(Meta.parse(code);
            target_module = scope, visible = true)
        push!(modules, emitted)
        push!(libraries, RustCall._module_binding(emitted, :_LIB_NAME))

        for mod in modules
            @test isempty(_mutable_module_registries(mod))
            generation = RustCall._module_binding(mod, :_LIB_GEN)
            symbols = RustCall._module_binding(mod, :_SYMBOLS)
            @test generation isa RustCall.StateView
            @test symbols isa RustCall.StateView
            @test generation.owner === symbols.owner === mod
            name = RustCall._module_binding(mod, :_LIB_NAME)
            @test lock(RustCall.REGISTRY_LOCK) do
                cell = RustCall._state_value(generation)
                any(ref -> ref === cell, RustCall.HANDLE_MIRRORS[name])
            end
            multiply = RustCall._module_binding(mod, :multiply)
            @test Base.invokelatest(multiply, 2.0, 3.0) == 6.0
            @test !isempty(symbols)
            readers = [Threads.@spawn Base.invokelatest(multiply, 3.0, 4.0) for _ in 1:16]
            @test all(==(12.0), fetch.(readers))
            RustCall.unload_library(name)
            @test generation[].handle == C_NULL
            @test_throws Exception Base.invokelatest(multiply, 2.0, 3.0)
        end
    finally
        for name in libraries
            RustCall.unload_library(name; close = true)
            RustCall.close_retired_handles!(RustCall.retired_handles(name))
        end
    end
end
