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

        @testset "an entry from another process is never a hit" begin
            # A `CallTargetCache` is spliced into the body of the wrapper it
            # belongs to, so a package that calls a generated wrapper from a
            # precompile workload serialises it — pointers and all — into its
            # `.ji`. The epoch cannot tell: it starts at the same value in every
            # process, so a deserialised one can equal a live one. Only the
            # session token can, and it does so by identity rather than by luck
            # (#390 review).
            cache = RustCall.CallTargetCache()
            target = RustCall.CallTarget(Ptr{Cvoid}(1), Ptr{Cvoid}(2), C_NULL, Ref(true),
                                         Ptr{Cvoid}(3), "lib", nothing, nothing, 0, C_NULL)
            RustCall.publish_call_target!(cache, RustCall.artifact_epoch(), target)
            @test RustCall.cached_target_hit(cache) === target
            # Exactly what loading into a fresh process does: a new token, while
            # the epoch is left alone so that it *would* have matched.
            previous = RustCall.session_token()
            epoch_then = RustCall.artifact_epoch()
            try
                @eval RustCall SESSION_TOKEN = SessionToken()
                @test RustCall.session_token() !== previous
                @test RustCall.artifact_epoch() === epoch_then
                @test RustCall.cached_target_hit(cache) === nothing
            finally
                @eval RustCall SESSION_TOKEN = $previous
            end
            @test RustCall.cached_target_hit(cache) === target
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

        @testset "a generic is still found on its first call in a fresh process" begin
            # `_resolve_lib` replays a precompiled caller's recorded blocks, and
            # those blocks are what register the module's generic functions. It
            # used to run before the call by construction — the macro put it in
            # the argument list. Moving library resolution onto the call site's
            # slow path (#253) put it *after* the generic check, so in a fresh
            # process every generic looked like a plain symbol that no library
            # exports, and an unannotated `@rust` on one failed on first call
            # instead of monomorphizing (#390 review).
            root = mktempdir()
            pkg_name = "DispatchCacheGeneric"
            pkg_uuid = "b1d54f26-0a83-4c71-9e52-7d38a0c6b415"
            pkgdir_ = joinpath(root, pkg_name)
            mkpath(joinpath(pkgdir_, "src"))
            write(joinpath(pkgdir_, "Project.toml"), """
            name = "$pkg_name"
            uuid = "$pkg_uuid"
            version = "0.1.0"

            [deps]
            RustCall = "$(Base.PkgId(RustCall).uuid)"
            """)
            write(joinpath(pkgdir_, "src", "$pkg_name.jl"), """
            module $pkg_name
            using RustCall
            rust\"\"\"
            #[julia]
            pub fn dispatch_cache_generic<T: std::fmt::Display>(x: T) -> String {
                format!("<{x}>")
            }
            \"\"\"
            # `@rust` without an annotation, inside the package, so the call site
            # belongs to the precompiled module.
            call_it(x) = @rust dispatch_cache_generic(x)
            end
            """)
            project = pkgdir(RustCall)
            sep = Sys.iswindows() ? ";" : ":"
            cache_dir = joinpath(root, "rustcall-cache")
            function in_child(script::AbstractString)
                withenv("JULIA_LOAD_PATH" => join((project, root, "@stdlib"), sep),
                        "RUSTCALL_CACHE_DIR" => cache_dir,
                        "RUSTCALL_SUPPRESS_HELPERS_WARNING" => "1") do
                    readchomp(pipeline(`$(Base.julia_cmd()) --startup-file=no -e $script`;
                                       stderr = stderr))
                end
            end
            try
                # Precompile first, so the second session is the fresh process
                # that loads a `.ji` and has an empty generic registry.
                in_child("using $pkg_name")
                @test in_child("using $pkg_name; print($pkg_name.call_it(Int32(7)))") ==
                      "<7>"
            finally
                rm(root; force = true, recursive = true)
            end
        end

        @testset "restoring a module is not a symbol resolution" begin
            # The other half of the same ordering. `_resolve_lib` must sit
            # *outside* the fallback `try`: a block that fails to compile or load
            # is not "this name is a generic", and catching it there let an
            # earlier block's generic of the same name swallow the real error and
            # leave the module half restored (#390 review).
            #
            # Asserted on the source because the failure needs a package whose
            # *second* recorded block fails to load in a fresh process, which
            # cannot be staged without making the test depend on how a build is
            # made to fail.
            source = read(joinpath(dirname(@__DIR__), "src", "rustmacro.jl"), String)
            # Comments only: the prose below explains this ordering and names
            # both `try` and `_resolve_lib`, so searching the raw text would
            # measure the comment rather than the code.
            code_of(name) = begin
                body = source[findfirst("function $(name)", source)[1]:end]
                body = body[1:findfirst("\nend", body)[1]]
                join((line for line in split(body, '\n')
                      if !startswith(strip(line), "#")), '\n')
            end
            typed = code_of("_rust_call_typed_uncached")
            @test findfirst("_resolve_lib(", typed)[1] < findfirst("try", typed)[1]
            # And the dynamic path resolves the library before it asks whether
            # the name is generic.
            dynamic = code_of("_rust_call_dynamic_cached")
            @test findfirst("_resolve_lib(", dynamic)[1] <
                  findfirst("is_generic_function(", dynamic)[1]
        end

        @testset "a call site whose annotation varies is checked every time" begin
            # `::T` is an expression, not a literal, so this is *one* call site —
            # one spliced cache — asked for a different type on each call. An
            # entry validated for `Int32` handed to the `Float64` call would read
            # an `i32` return slot as a `Float64`: undefined behaviour, and
            # exactly what `_check_return_annotation` exists to refuse (#245).
            # The declared type is therefore part of what makes an entry a hit
            # (#390 review).
            @noinline varying(::Type{T}) where {T} = @rust dispatch_cache_value()::T
            @test varying(Int32) == 1
            @test_throws RustCall.RustError varying(Float64)
            # Both orders: the warm entry must not be a way past the check, and
            # the rejected one must not have displaced the good entry either.
            @test varying(Int32) == 1
            @test_throws RustCall.RustError varying(Float64)
        end

        @testset "a wrapper called during precompilation still calls correctly" begin
            # The end-to-end form of the test above, and the scenario that makes
            # it matter: a package whose module body *calls* a generated wrapper
            # is precompiled with that call's cache entry — native pointers and
            # all — written into its `.ji` file.
            #
            # What makes this a test rather than a coincidence is the third
            # line of the child script. A fresh process would normally be at a
            # different epoch, and the entry would be rejected for the wrong
            # reason; putting the counter back where it stood when the entry was
            # written removes that accident, so the only thing that can reject it
            # is the session token. Before the token, this printed garbage or
            # crashed the child.
            root = mktempdir()
            pkg_name = "DispatchCachePrecomp"
            # Hard-coded, like the other precompilation tests: `UUIDs` is not a
            # test dependency, and a fixed id is fine for a package that is
            # created, loaded and deleted inside one testset.
            pkg_uuid = "4e6b2c18-9d07-4a35-8f21-6c3d9b5e7a02"
            pkgdir_ = joinpath(root, pkg_name)
            mkpath(joinpath(pkgdir_, "src"))
            write(joinpath(pkgdir_, "Project.toml"), """
            name = "$pkg_name"
            uuid = "$pkg_uuid"
            version = "0.1.0"

            [deps]
            RustCall = "$(Base.PkgId(RustCall).uuid)"
            """)
            write(joinpath(pkgdir_, "src", "$pkg_name.jl"), """
            module $pkg_name
            using RustCall
            rust\"\"\"
            #[julia]
            pub fn dispatch_cache_precomp(a: i32) -> i32 { a + 1 }
            \"\"\"
            # Called here, while the package is being precompiled: this is what
            # populates the wrapper's cache and serialises it.
            const AT_PRECOMPILE = dispatch_cache_precomp(Int32(41))
            const EPOCH_AT_PRECOMPILE = RustCall.artifact_epoch()
            end
            """)
            project = pkgdir(RustCall)
            sep = Sys.iswindows() ? ";" : ":"
            cache_dir = joinpath(root, "rustcall-cache")
            function in_child(script::AbstractString)
                withenv("JULIA_LOAD_PATH" => join((project, root, "@stdlib"), sep),
                        "RUSTCALL_CACHE_DIR" => cache_dir,
                        "RUSTCALL_SUPPRESS_HELPERS_WARNING" => "1") do
                    readchomp(pipeline(`$(Base.julia_cmd()) --startup-file=no -e $script`;
                                       stderr = stderr))
                end
            end
            try
                @test in_child("using $pkg_name; print($pkg_name.AT_PRECOMPILE)") == "42"
                out = in_child("""
                    using RustCall, $pkg_name
                    RustCall.ARTIFACT_EPOCH[] = $pkg_name.EPOCH_AT_PRECOMPILE
                    print($pkg_name.dispatch_cache_precomp(Int32(41)))
                    """)
                @test out == "42"
            finally
                rm(root; force = true, recursive = true)
            end
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
