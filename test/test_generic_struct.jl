# Test cases converted from examples/generic_struct_test.jl
using RustCall
using Test

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
        @test alive !== RustCall.DEAD_ARTIFACT

        # The flag is a *registry* flag — the very `Ref` the loader holds for
        # the image that exports this destructor — and not a fresh `Ref(true)`
        # invented for a name nothing is registered under. That invention was
        # the bug: an object holding it would believe itself live forever,
        # and its finalizer would call into an image that had been closed.
        registered = lock(RustCall.REGISTRY_LOCK) do
            collect(values(RustCall.ARTIFACT_ALIVE))
        end
        @test any(f -> f === alive, registered)

        # Each generic instantiation is compiled into its own artifact today,
        # so the destructor may live in a different image from the
        # constructor. What the snapshot guarantees is that the flag belongs to
        # the image the finalizer will actually call into; giving a generic
        # struct's constructor and destructor one artifact, which is what
        # would put the allocation and the free on one allocator, is #291.
        lib = getfield(b, :lib_name)
        @test !isempty(lib)

        # ...and the object still frees exactly once, without raising.
        before = RustCall.finalizer_failure_count()
        b = nothing
        GC.gc(true)
        @test RustCall.finalizer_failure_count() == before
    end
end
