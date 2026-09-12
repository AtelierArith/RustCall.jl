using Test
using RustCall

# A call site keeps the `CallTarget` it resolved and reuses it while the artifact
# epoch says no state write has happened since (#253). That is the whole reason
# `@rust` went from ~9.9 µs to ~12 ns and stopped serialising on `REGISTRY_LOCK`
# — and it is only sound while the invalidation is airtight, because a snapshot
# reused across a reload is a call into a retired image with the replacement's
# channel, which is the #277 bug class.
#
# So these tests are about exactly two things: that the epoch moves whenever the
# state does, and that a moved epoch is what the fast path checks.

@testset "cached dispatch (#253)" begin
    @testset "every state write moves the epoch" begin
        # Not "the writes we remembered to annotate": the bump lives in
        # `_state_mutate_storage!`, the one helper every state-container write
        # already passes through, so a registry added later cannot forget it.
        before = RustCall.artifact_epoch()
        view = RustCall._state_view(:dispatch_cache_probe, Dict{String, Int}())
        try
            view["a"] = 1
            after_write = RustCall.artifact_epoch()
            @test after_write > before
            delete!(view, "a")
            @test RustCall.artifact_epoch() > after_write
        finally
            lock(RustCall.REGISTRY_LOCK) do
                delete!(RustCall.STATE.value.values, :dispatch_cache_probe)
            end
        end
    end

    @testset "a hit is dropped as soon as the epoch moves" begin
        cache = RustCall.CallTargetCache()
        @test RustCall.cached_target_hit(cache) === nothing
        # Publish a fabricated entry: this testset is about the epoch check, and
        # it must hold whatever the snapshot happens to be.
        target = RustCall.CallTarget(Ptr{Cvoid}(1), Ptr{Cvoid}(2), C_NULL, Ref(true),
                                     Ptr{Cvoid}(3), "lib", nothing, nothing, 0, C_NULL)
        RustCall.publish_call_target!(cache, RustCall.artifact_epoch(), target)
        @test RustCall.cached_target_hit(cache) === target
        Threads.atomic_add!(RustCall.ARTIFACT_EPOCH, 1)
        @test RustCall.cached_target_hit(cache) === nothing
    end

    @testset "an epoch sampled after resolving would be wrong" begin
        # The ordering rule, asserted rather than only commented: a snapshot
        # stamped with an epoch taken *after* a concurrent write would look
        # current forever. `_refresh_call_target!` samples before resolving, so
        # the stale stamp loses the race instead of winning it.
        source = read(joinpath(dirname(@__DIR__), "src", "ruststr.jl"), String)
        body = source[findfirst("function _refresh_call_target!", source)[1]:end]
        body = body[1:findfirst("\nend", body)[1]]
        @test findfirst("artifact_epoch()", body)[1] <
              findfirst("resolve_call_target(", body)[1]
    end

    if !RustCall.check_rustc_available()
        @info "Skipping the cached-dispatch call tests: no Rust toolchain"
        @test_skip "needs rustc"
    else
        rust"""
        #[julia]
        pub fn dispatch_cache_value() -> i32 { 1 }
        """

        # One call site, fixed for the rest of this file: its cache object is
        # created when the macro expands and never again, which is what makes
        # the reload below a test of invalidation rather than of redefinition.
        @noinline call_site() = @rust dispatch_cache_value()::Int32

        @testset "a warm call site re-resolves once the epoch moves" begin
            @test call_site() == 1
            # Warm, then invalidated by an unrelated state write — the same
            # thing a reload does to it, without needing a second block
            # exporting the same name, which one module may not have (#300).
            view = RustCall._state_view(:dispatch_cache_reresolve, Dict{String, Int}())
            try
                view["x"] = 1
            finally
                lock(RustCall.REGISTRY_LOCK) do
                    delete!(RustCall.STATE.value.values, :dispatch_cache_reresolve)
                end
            end
            # The call site has to go all the way back through
            # `module_symbol_library` + `resolve_call_target` here, and still
            # answer correctly.
            @test call_site() == 1
            @test call_site() == 1
        end

        # The adversarial end-to-end version of the above — a reload loop racing
        # tasks that call, panic, allocate and drop — is
        # `test_hot_reload_transaction.jl`, which runs against this same path and
        # is where a stale snapshot would actually show up as a wrong answer.

        @testset "unloading a library moves the epoch" begin
            # The property the whole scheme rests on, pinned against the one
            # event that would actually hurt: a snapshot kept across an unload
            # is a pointer into an image the registry no longer names. The bump
            # is not written at the unload site — it comes from the state writes
            # the unload performs — so this asserts the consequence rather than
            # the mechanism, and keeps holding if the mechanism is rewritten.
            rust"""
            #[julia]
            pub fn dispatch_cache_unload() -> i32 { 7 }
            """
            name = RustCall.get_current_library()
            before = RustCall.artifact_epoch()
            RustCall.unload_library(name)
            @test RustCall.artifact_epoch() > before
        end

        @testset "the fast path takes no lock" begin
            # #253's second acceptance criterion, as a property rather than a
            # timing: a warmed call site must complete while another task holds
            # `REGISTRY_LOCK`. Before the cache it could not — every call took
            # that lock on the way to the snapshot, which is why four threads
            # ran slower than one.
            #
            # Warmed *twice*, deliberately. The first resolution of a symbol
            # publishes its pointer into the image's own cache, and that
            # publication is itself a state write, so it bumps the epoch and
            # leaves the entry it just produced stale. The second call finds the
            # pointer already there, writes nothing, and its entry sticks. One
            # extra resolution per call site, once.
            call_site()
            call_site()
            held = Channel{Nothing}(1)
            release = Channel{Nothing}(1)
            holder = Threads.@spawn lock(RustCall.REGISTRY_LOCK) do
                put!(held, nothing)
                take!(release)
            end
            take!(held)
            result = Threads.@spawn call_site()
            finished = timedwait(() -> istaskdone(result), 20.0)
            # Released before anything waits on `result`: if the call did take
            # the lock, `fetch` would block until the holder let go, and the
            # holder is waiting for this.
            put!(release, nothing)
            wait(holder)
            @test finished === :ok
            @test fetch(result) == 1
        end

        @testset "a return annotation is still checked after a cache hit" begin
            # The check moved to publication time (both its inputs are fixed for
            # the life of an entry), so the thing to prove is that a rejected
            # snapshot leaves no reusable entry behind: the second call must
            # raise exactly as the first did, not sail through on a hit.
            @noinline bad_site() = @rust dispatch_cache_value()::Float64
            @test_throws RustCall.RustError bad_site()
            @test_throws RustCall.RustError bad_site()
            # And the honest call site is unaffected.
            @test call_site() == 1
        end
    end
end
