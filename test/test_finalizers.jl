# Object lifetime: finalizers free, and are safe to run (#249, #277 Phase B4).
#
# The acceptance criteria of #249's finalizer half, one testset each:
#
#   (a) constructing an ownership type without the helper library throws
#       immediately, with actionable guidance;
#   (b) no finalizer performs a `dlsym`, takes `REGISTRY_LOCK`, or logs;
#   (c) no net leak across many create/drop cycles, single- and
#       multi-threaded, measured by a Rust-side allocation counter;
#   (d) the allocator contract is documented.

using Test
using Libdl
using RustCall

const _FIN_SRC = joinpath(dirname(dirname(pathof(RustCall))), "src")
_fin_src(name) = read(joinpath(_FIN_SRC, name), String)

"""The body of a top-level `function <name>(` in `src/<file>`."""
function _fin_function_body(file, name)
    src = _fin_src(file)
    i = findfirst("function $(name)(", src)
    i === nothing && return nothing
    tail = src[first(i):end]
    stop = findfirst("\nend", tail)
    return stop === nothing ? tail : tail[1:first(stop)]
end

@testset "Object lifetime and finalizers (#249)" begin

    # ------------------------------------------------------------------
    # (a) No helper library, no ownership value — and say what to do.
    # ------------------------------------------------------------------
    @testset "ownership types refuse to be created without the helpers" begin
        saved = RustCall.RUST_HELPERS_LIB[]
        try
            RustCall.RUST_HELPERS_LIB[] = nothing
            @test !RustCall.is_rust_helpers_available()

            err = try
                RustCall.create_rust_box(Int32(1))
                nothing
            catch e
                e
            end
            @test err isa RustCall.RustError
            # Actionable: it names the operation and the exact command.
            @test occursin("RustBox", err.message)
            @test occursin("Pkg.build(\"RustCall\")", err.message)

            # ...and it is the *same* refusal everywhere, so no ownership
            # value can be constructed without a way to release it.
            for op in (() -> RustCall.create_rust_box(Int32(1)),
                       () -> RustCall.create_rust_rc(Int32(1)),
                       () -> RustCall.create_rust_arc(Int32(1)))
                @test_throws RustCall.RustError op()
            end
            @test_throws RustCall.RustError RustCall.require_rust_helpers("Test op")
        finally
            RustCall.RUST_HELPERS_LIB[] = saved
        end
        # The refusal is not sticky: with the library back, it succeeds again.
        if RustCall.is_rust_helpers_available()
            @test RustCall.require_rust_helpers("Test op") != C_NULL
        end
    end

    # ------------------------------------------------------------------
    # (b) A finalizer may run on any thread, at any point, possibly while the
    #     running thread already holds REGISTRY_LOCK. So: no lock, no lookup,
    #     no symbol resolution, no logging.
    # ------------------------------------------------------------------
    @testset "no finalizer locks, looks up, or logs" begin
        body = _fin_function_body("structs.jl", "finalize_rust_object!")
        @test body !== nothing
        for forbidden in ("dlsym", "REGISTRY_LOCK", "lock(", "@warn", "@info",
                          "@error", "@debug", "get_function_pointer",
                          "RUST_LIBRARIES", "monomorphize_function")
            @test !occursin(forbidden, body)
        end
        # It reads only captured state.
        @test occursin("getfield(x, :free_ptr)", body)
        @test occursin("getfield(x, :alive)", body)

        # The generated finalizers all delegate to it rather than inlining a
        # body of their own — that is what makes the property checkable.
        for file in ("structs.jl", "crate_bindings.jl")
            src = _fin_src(file)
            @test occursin("finalizer(RustCall.finalize_rust_object!, obj)", src)
            # No `finalizer(obj) do x` blocks left anywhere.
            @test !occursin("finalizer(obj) do x", src)
        end

        # The ownership types' finalizers are held to the same rule.
        for name in ("_finalize_rust_box", "_finalize_rust_rc", "_finalize_rust_arc")
            b = _fin_function_body("memory.jl", name)
            b === nothing && continue
            @test !occursin("REGISTRY_LOCK", b)
        end
    end

    # ------------------------------------------------------------------
    # Behaviour: the free actually happens, exactly once, and never into an
    # unloaded library.
    # ------------------------------------------------------------------
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required for the lifetime tests"
    else
        # `LIVE` counts *Rust* allocations: `new` bumps it, `Drop` decrements
        # it. So the assertions below measure what the finalizer actually did
        # to the Rust object, not what Julia did to the wrapper.
        rust"""
        use std::sync::atomic::{AtomicI64, Ordering};

        static LIVE: AtomicI64 = AtomicI64::new(0);

        #[julia]
        pub struct Tracked {
            value: i32,
        }

        impl Tracked {
            pub fn new(value: i32) -> Self {
                LIVE.fetch_add(1, Ordering::SeqCst);
                Tracked { value }
            }

            pub fn get(&self) -> i32 {
                self.value
            }
        }

        impl Drop for Tracked {
            fn drop(&mut self) {
                LIVE.fetch_sub(1, Ordering::SeqCst);
            }
        }

        #[julia]
        fn tracked_live() -> i64 {
            LIVE.load(Ordering::SeqCst)
        }
        """

        # The wrappers must be created inside a *function*, not in the testset
        # body: a local of an enclosing frame stays rooted for as long as that
        # frame lives, so the last object of a loop would still be reachable
        # when the assertion runs, and the test would fail for a reason that
        # has nothing to do with finalizers.
        function _make_and_drop(n)
            for i in 1:n
                obj = Tracked(Int32(i % 128))
                get(obj)
            end
            return nothing
        end

        function _collect_all()
            for _ in 1:3
                GC.gc(true)
            end
            return nothing
        end

        @testset "the finalizer frees (#249)" begin
            baseline = tracked_live()
            @test (() -> begin
                obj = Tracked(Int32(7))
                r = get(obj) == Int32(7) && tracked_live() == baseline + 1
                r
            end)()
            _collect_all()
            @test tracked_live() == baseline
        end

        @testset "no net leak across many cycles (#249)" begin
            baseline = tracked_live()
            # 10^5 create/drop cycles. The counter is Rust-side, so it measures
            # the Rust allocation rather than the Julia wrapper: a wrapper that
            # is collected without freeing would leave the count high.
            _make_and_drop(100_000)
            _collect_all()
            @test tracked_live() == baseline

            # ...and the same from several threads at once. `Tracked::new`
            # bumps an atomic, so the count is exact under concurrency, and
            # the finalizers run on whichever thread the GC picks.
            n = max(2, Threads.nthreads())
            @sync for _ in 1:n
                Threads.@spawn _make_and_drop(10_000)
            end
            _collect_all()
            @test tracked_live() == baseline
            @test RustCall.finalizer_failure_count() == 0
        end

        @testset "double free is impossible, and a freed object raises" begin
            obj = Tracked(Int32(3))
            baseline = tracked_live()
            # Finalizing twice by hand must free once.
            finalize(obj)
            @test tracked_live() == baseline - 1
            finalize(obj)
            @test tracked_live() == baseline - 1
            @test getfield(obj, :ptr) == C_NULL
            # A method call on a freed object raises rather than segfaulting.
            @test_throws RustCall.RustError obj.value
        end

        @testset "an object outliving a *retired* image still frees" begin
            # A retired image is still mapped, so the destructor an object
            # captured is still there — and the object must run it, or every
            # reload would leak everything allocated before it. Only *closing*
            # the image makes objects from it inert (#249, #277).
            rust"""
            use std::sync::atomic::{AtomicI64, Ordering};

            static RETIRE_LIVE: AtomicI64 = AtomicI64::new(0);

            #[julia]
            pub struct RetireTracked {
                value: i32,
            }

            impl RetireTracked {
                pub fn new(value: i32) -> Self {
                    RETIRE_LIVE.fetch_add(1, Ordering::SeqCst);
                    RetireTracked { value }
                }
            }

            impl Drop for RetireTracked {
                fn drop(&mut self) {
                    RETIRE_LIVE.fetch_sub(1, Ordering::SeqCst);
                }
            }

            #[julia]
            fn retire_live() -> i64 {
                RETIRE_LIVE.load(Ordering::SeqCst)
            }
            """

            baseline = retire_live()
            obj = RetireTracked(Int32(5))
            survivor = RetireTracked(Int32(6))
            lib = getfield(obj, :lib_name)
            alive = getfield(obj, :alive)
            @test retire_live() == baseline + 2
            @test alive[]

            # Retire the library — what a hot reload does to the image it
            # replaces, and what `unload_library` now does too.
            @test RustCall.unload_artifact!(RustCall.inline_rustc_policy(), lib)
            retired = RustCall.retired_handles(lib)
            @test length(retired) == 1
            # The flag stays true: the image is still mapped.
            @test alive[]

            # The counter lives *in* the retired image, and reading it through
            # the retired handle is itself the proof that the image is still
            # there — the Julia wrapper cannot help, its library is gone from
            # the registry.
            probe = Libdl.dlsym(only(retired), "rustcall_retire_live")
            live() = RustCall.call_rust_function(probe, Int64)
            @test live() == baseline + 2

            # ...so the destructor runs, through the retired image.
            finalize(obj)
            @test live() == baseline + 1
            @test RustCall.finalizer_failure_count() == 0

            # Closing the image is what makes the *other* object inert: it
            # leaks rather than jumping into unmapped code.
            @test RustCall.close_retired_handles!(retired) == 1
            @test !alive[]
            @test !getfield(survivor, :alive)[]
            finalize(survivor)
            @test getfield(survivor, :ptr) == C_NULL
            @test RustCall.finalizer_failure_count() == 0
        end

        @testset "an object outliving a *closed* image is inert" begin
            # A *separate* library, whose counter lives in its own block: the
            # unload below retires that library, so its own `tracked_live`
            # equivalent must not be the thing we then call.
            rust"""
            use std::sync::atomic::{AtomicI64, Ordering};

            static UNLOAD_LIVE: AtomicI64 = AtomicI64::new(0);

            #[julia]
            pub struct UnloadTracked {
                value: i32,
            }

            impl UnloadTracked {
                pub fn new(value: i32) -> Self {
                    UNLOAD_LIVE.fetch_add(1, Ordering::SeqCst);
                    UnloadTracked { value }
                }
            }

            impl Drop for UnloadTracked {
                fn drop(&mut self) {
                    UNLOAD_LIVE.fetch_sub(1, Ordering::SeqCst);
                }
            }
            """

            obj = UnloadTracked(Int32(11))
            lib = getfield(obj, :lib_name)
            alive = getfield(obj, :alive)
            free_ptr = getfield(obj, :free_ptr)
            @test alive[]
            @test free_ptr != C_NULL

            # Unload *and close*: the image is gone, so the flag flips and the
            # finalizer declines to call the destructor instead of jumping into
            # unmapped code. Leaking one object is the right trade.
            RustCall.unload_artifact!(RustCall.inline_rustc_policy(), lib;
                                      close = true)
            @test !alive[]

            failures_before = RustCall.finalizer_failure_count()
            finalize(obj)
            @test getfield(obj, :ptr) == C_NULL
            @test RustCall.finalizer_failure_count() == failures_before
        end
    end

    # ------------------------------------------------------------------
    # (d) The allocator contract is written down.
    # ------------------------------------------------------------------
    @testset "the allocator contract is documented" begin
        docs = joinpath(dirname(_FIN_SRC), "docs", "src", "panics.md")
        @test isfile(docs)
        text = read(docs, String)
        @test occursin("allocator contract", lowercase(text))
        @test occursin("<Struct>_free", text)
        @test occursin("_free_rust_string", text)
    end
end
