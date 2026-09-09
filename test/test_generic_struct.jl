# Originally derived from the deleted `examples/generic_struct_test.jl` (removed in #9); the tests below are the reference.
using RustCall
using Test

struct NonCopyStatePayload{T} end

@testset "same-name generic rebuild retains each object's image (#291)" begin
    rust"""
    use std::sync::atomic::{AtomicI32, Ordering};
    static SAME_NAME_COUNTER: AtomicI32 = AtomicI32::new(0);
    #[julia]
    pub struct SameNameGenerationProbe<T> { value: T }
    impl<T> SameNameGenerationProbe<T> {
        pub fn new(value: T) -> Self { Self { value } }
        pub fn same_name_tick(&self) -> i32 { SAME_NAME_COUNTER.fetch_add(1, Ordering::SeqCst) + 1 }
        pub fn same_name_count(&self) -> i32 { SAME_NAME_COUNTER.load(Ordering::SeqCst) }
    }
    """
    old = SameNameGenerationProbe{Int32}(Int32(7))
    current = nothing
    try
        @test Base.invokelatest(same_name_tick, old) == 1
        RustCall.unload_library(old.lib_name)
        current = SameNameGenerationProbe{Int32}(Int32(8))
        @test current.lib_name == old.lib_name
        @test getfield(current, :alive) !== getfield(old, :alive)
        @test Base.invokelatest(same_name_count, current) == 0
        @test Base.invokelatest(same_name_count, old) == 1
        @test Base.invokelatest(same_name_tick, current) == 1
        @test Base.invokelatest(same_name_tick, old) == 2
        for (object, value) in ((old, 7), (current, 8))
            @test object.value == value
            object.value = Int32(value + 10)
            @test object.value == value + 10
            for member in ("SameNameGenerationProbe_free", "SameNameGenerationProbe_get_value",
                           "SameNameGenerationProbe_set_value", "SameNameGenerationProbe_same_name_count")
                snapshot = RustCall._generic_artifact_member(object.lib_name, member, getfield(object, :alive))
                @test RustCall.alive_ref_for_handle(snapshot.handle, object.lib_name) === getfield(object, :alive)
            end
        end
    finally
        finalize(old)
        current === nothing || finalize(current)
        RustCall.close_retired_handles!(RustCall.retired_handles(old.lib_name))
        RustCall.unload_library(old.lib_name; close = true)
    end
end

@testset "closed generic images reject methods and field wrappers before FFI (#291)" begin
    rust"""
    #[julia]
    pub struct ClosedGenericImage<T> { value: T }
    impl<T> ClosedGenericImage<T> {
        pub fn new(value: T) -> Self { Self { value } }
        pub fn closed_value(&self) -> T where T: Copy { self.value }
    }
    """
    object = ClosedGenericImage{Int32}(Int32(7))
    @test Base.invokelatest(closed_value, object) == 7
    @test object.value == 7
    object.value = Int32(8)
    @test Base.invokelatest(closed_value, object) == 8
    # Explicit close intentionally makes the allocation inert. The pointer
    # remains non-null: checking only finalization is not sufficient.
    RustCall.unload_library(object.lib_name; close = true)
    @test getfield(object, :ptr) != C_NULL
    @test !getfield(object, :alive)[]
    @test_throws RustCall.RustError Base.invokelatest(closed_value, object)
    @test_throws RustCall.RustError object.value
    @test_throws RustCall.RustError (object.value = Int32(9))
    before = RustCall.finalizer_failure_count()
    finalize(object)
    @test getfield(object, :ptr) == C_NULL
    @test RustCall.finalizer_failure_count() == before
end

@testset "generic group registration replaces the whole member set atomically (#251, #291)" begin
    source(member) = """
        #[julia] pub struct AtomicGenericGroup<T> { value: T }
        impl<T> AtomicGenericGroup<T> {
            pub fn new(value: T) -> Self { Self { value } }
            pub fn $(member)(&self) -> i32 { 1 }
        }
        """
    versions = [RustCall.expand_inline(source(member)) for member in ("old_member", "new_member")]
    infos = [only(RustCall.manifest_struct_infos(version.manifest)) for version in versions]
    group = Symbol("generic_struct:AtomicGenericGroup")
    expected = [Set(first(wrapper) for wrapper in info.generic_wrappers) for info in infos]
    snapshot() = lock(RustCall.REGISTRY_LOCK) do
        [info for info in values(RustCall.GENERIC_FUNCTION_REGISTRY) if info.group === group]
    end
    publish(index) = RustCall.register_generic_struct_wrappers(infos[index], versions[index].source)
    publish(1)
    @test Set(info.name for info in snapshot()) == expected[1]
    publish(2)
    @test Set(info.name for info in snapshot()) == expected[2]
    @test all(info -> info.code == versions[2].source, snapshot())
    if Threads.nthreads() > 1
        stop = Threads.Atomic{Bool}(false)
        ready = Channel{Nothing}(3)
        readers = [Threads.@spawn(begin
            valid = true
            count = 0
            put!(ready, nothing)
            while !stop[]
                observed = snapshot()
                valid &= any(eachindex(versions)) do index
                    Set(info.name for info in observed) == expected[index] &&
                    all(info -> info.code == versions[index].source, observed)
                end
                count += 1
                yield()
            end
            (valid, count)
        end) for _ in 1:3]
        try
            foreach(_ -> take!(ready), 1:3)
            for iteration in 1:20
                publish(mod1(iteration, 2))
            end
        finally
            stop[] = true
            for reader in readers
                valid, count = fetch(reader)
                @test valid
                @test count > 0
            end
        end
    end
end

@testset "method-local type parameters do not block a generic constructor" begin
    rust"""
    #[julia]
    pub struct MethodLocalParam<T> { value: T }
    impl<T> MethodLocalParam<T> {
        pub fn new(value: T) -> Self { Self { value } }
        pub fn map<U>(&self, value: U) -> U { value }
        pub fn local_value(&self) -> T where T: Copy { self.value }
    }
    """
    object = MethodLocalParam{Int32}(Int32(17))
    try
        @test Base.invokelatest(local_value, object) == 17
        params = Dict{Symbol, Type}(:T => Int32)
        ctor = RustCall.get_monomorphized_function("MethodLocalParam_new", params)
        free = RustCall.get_monomorphized_function("MethodLocalParam_free", params)
        @test ctor.handle == free.handle
        @test getfield(object, :free_ptr) == free.func_ptr
        @test !haskey(RustCall.GENERIC_STRUCT_ARTIFACTS[(object.lib_name, getfield(object, :alive))], "MethodLocalParam_map")
    finally
        finalize(object)
    end
end

@testset "generic objects retain their method generation across registration reload (#291)" begin
    rust"""
    #[julia]
    pub struct GenerationStableBox<T> { value: T }
    impl<T> GenerationStableBox<T> {
        pub fn new(value: T) -> Self { Self { value } }
        pub fn stable_stamp(&self) -> i32 { 111 }
        pub fn stable_label(&self) -> String { "generation 111".to_string() }
        pub fn stable_boom(&self) -> i32 { panic!("generation 111") }
    }
    """
    old = GenerationStableBox{Int32}(Int32(7))
    @test Base.invokelatest(stable_stamp, old) == 111
    members = filter(info -> info.group === Symbol("generic_struct:GenerationStableBox"),
                     collect(values(RustCall.GENERIC_FUNCTION_REGISTRY)))
    @test !isempty(members)
    stop = Threads.Atomic{Bool}(false)
    readers = Task[]
    objects = Any[old]
    before = RustCall.finalizer_failure_count()
    try
        if Threads.nthreads() > 1
            for _ in 1:3
                push!(readers, Threads.@spawn begin
                    valid = true
                    calls = 0
                    while !stop[]
                        valid &= Base.invokelatest(stable_stamp, old) == 111
                        calls += 1
                        yield()
                    end
                    (valid, calls)
                end)
            end
        end
        for version in (222, 333)
            replacements = [RustCall.GenericFunctionInfo(
                info.name, replace(info.code, "111" => string(version)), info.type_params,
                info.constraints, info.context, info.arg_types, info.return_type,
                info.path, info.compiler, info.blocked, info.group) for info in members]
            lock(RustCall.REGISTRY_LOCK) do
                for info in replacements
                    RustCall.GENERIC_FUNCTION_REGISTRY[info.name] = info
                end
            end
            current = GenerationStableBox{Int32}(Int32(version))
            push!(objects, current)
            @test Base.invokelatest(stable_stamp, current) == version
            @test current.lib_name != old.lib_name
            @test Base.invokelatest(stable_stamp, old) == 111
            @test Base.invokelatest(stable_label, old) == "generation 111"
            error = try
                Base.invokelatest(stable_boom, old)
                nothing
            catch caught
                caught
            end
            @test error isa RustCall.RustPanicError
            @test occursin("generation 111", sprint(showerror, error))
            original_free = RustCall._generic_artifact_member(old.lib_name, "GenerationStableBox_free", getfield(old, :alive))
            @test original_free.func_ptr == getfield(old, :free_ptr)
            if version == 222
                # Retire the original image while readers still enter it.
                # Its object must not need the live-name registry or migrate
                # to the newly published group's methods.
                RustCall.unload_library(old.lib_name)
                @test !haskey(RustCall.RUST_LIBRARIES, old.lib_name)
                @test getfield(old, :alive)[]
                @test original_free.handle in RustCall.retired_handles(old.lib_name)
                @test Base.invokelatest(stable_stamp, old) == 111
            end
        end
    finally
        stop[] = true
        for reader in readers
            valid, calls = fetch(reader)
            @test valid
            @test calls > 0
        end
        for object in objects
            finalize(object)
        end
        lock(RustCall.REGISTRY_LOCK) do
            for info in members
                RustCall.GENERIC_FUNCTION_REGISTRY[info.name] = info
            end
        end
    end
    @test RustCall.finalizer_failure_count() == before
    @test_throws RustCall.RustError Base.invokelatest(stable_stamp, old)
    # All readers joined and every object finalized: this is the explicit
    # quiescence point at which reclaiming this test's old image is safe.
    @test RustCall.close_retired_handles!(RustCall.retired_handles(old.lib_name)) > 0
    @test !getfield(old, :alive)[]
end

@testset "generic methods with stronger bounds do not block construction" begin
    rust"""
    #[derive(Default)]
    pub struct NonCopyStatePayload<T> { value: Vec<T> }
    #[julia]
    pub struct StrongBound<T> { value: T }
    impl<T> StrongBound<T> {
        pub fn new() -> Self where T: Default { Self { value: T::default() } }
        pub fn copied(&self) -> T where T: Copy { self.value }
        pub fn len(&self) -> usize { 5 }
    }
    """
    object = StrongBound{NonCopyStatePayload{Int32}}()
    @test Base.invokelatest(len, object) == 5
    @test getfield(object, :free_ptr) != C_NULL
    params = Dict(:T => NonCopyStatePayload{Int32})
    constructor = RustCall.get_monomorphized_function("StrongBound_new", params)
    destructor = RustCall.get_monomorphized_function("StrongBound_free", params)
    @test constructor.handle == destructor.handle
    @test getfield(object, :lib_name) == constructor.lib_name
    @test_throws RustCall.CompilationError RustCall.monomorphize_function("StrongBound_copied", params)
    finalize(object)
end

@testset "Generic Struct Test" begin
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping generic struct tests"
        return
    end

    @testset "Generic Wrapper" begin
        rust"""
        #[julia]
        pub struct Wrapper<T> {
            value: T,
        }

        impl<T> Wrapper<T> {
            pub fn new(value: T) -> Self {
                Self { value }
            }

            pub fn get_value(&self) -> T where T: Copy {
                self.value
            }

            pub fn set_value(&mut self, val: T) {
                self.value = val;
            }
        }
        """

        w = Wrapper{Int32}(Int32(42))
        @test w !== nothing

        val = get_value(w)
        @test val == 42
        @test w.value == 42

        set_value(w, Int32(100))
        val2 = get_value(w)
        @test val2 == 100
        @test w.value == 100
    end

    # A generic constructor allocates, so the object it returns must capture
    # the destructor and the liveness flag of the image that allocated it,
    # from the constructor's own snapshot. It used to take them in a second
    # step afterwards, so an unload or a reload in between paired a pointer
    # from one image with another image's `free` — and, when nothing was
    # registered under the name any more, with a freshly invented "alive"
    # flag that nothing would ever flip (#249, #277).
    @testset "a generic struct is bound to the image that allocated it" begin
        rust"""
        #[julia]
        pub struct Boxed<T> {
            value: T,
        }

        impl<T> Boxed<T> {
            pub fn new(value: T) -> Self {
                Self { value }
            }

            pub fn get(&self) -> T where T: Copy {
                self.value
            }
        }
        """

        b = Boxed{Int32}(Int32(7))
        @test Base.invokelatest(get, b) == 7

        # What the finalizer will use: a real destructor, and the flag of the
        # image that exports it — not a fresh `Ref(true)`.
        free_ptr = getfield(b, :free_ptr)
        alive = getfield(b, :alive)
        @test free_ptr != C_NULL
        @test alive[]
        @test alive !== RustCall._state_read(RustCall.DEAD_ARTIFACT, identity)

        # The flag is a *registry* flag — the very `Ref` the loader holds for
        # the image that exports this destructor — and not a fresh `Ref(true)`
        # invented for a name nothing is registered under. That invention was
        # the bug: an object holding it would believe itself live forever,
        # and its finalizer would call into an image that had been closed.
        registered = lock(RustCall.REGISTRY_LOCK) do
            collect(values(RustCall.ARTIFACT_ALIVE))
        end
        @test any(f -> f === alive, registered)

        # Constructor, methods, accessors, and destructor for one type
        # instantiation share one artifact, so allocation and free use one
        # allocator (#291).
        lib = getfield(b, :lib_name)
        @test !isempty(lib)
        free_info = only(filter(info -> occursin("Boxed_free", info.name),
                                values(RustCall.MONOMORPHIZED_FUNCTIONS)))
        @test free_info.lib_name == lib

        # ...and the object still frees exactly once, without raising.
        before = RustCall.finalizer_failure_count()
        b = nothing
        GC.gc(true)
        @test RustCall.finalizer_failure_count() == before
    end
end
