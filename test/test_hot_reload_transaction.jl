# Hot reload is transactional, event-driven and debounced (#255).
#
# The acceptance criteria of the issue, one testset each:
#
#   1. saving a file with a compile error: the previous library keeps working,
#      the error is reported once, and fixing the file reloads;
#   2. the rebuild does not fight the loaded image (which is what breaks on
#      Windows, where a mapped DLL is locked): each reload opens its own file;
#   3. two saves within 200 ms produce one reload;
#   4. no polling loop when idle.
#
# The test crate is deliberately dependency-free: `#[julia]` is not what is
# under test here, and a crate that pulls in `juliacall_macros` would compile
# `syn` from scratch into its own target directory on every CI run.

using Test
using Libdl
using RustCall

const _HRT_SRC = read(joinpath(dirname(dirname(pathof(RustCall))), "src",
                               "hot_reload.jl"), String)
_src_loadpolicy() = read(joinpath(dirname(dirname(pathof(RustCall))), "src",
                                  "loadpolicy.jl"), String)

const _HRT_CARGO = try
    success(run(pipeline(`cargo --version`, devnull, devnull); wait = true))
catch
    false
end

"""A minimal dependency-free cdylib crate exporting `hrt_probe`."""
function _hrt_make_crate(dir, name, value)
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "Cargo.toml"), """
        [package]
        name = "$(name)"
        version = "0.1.0"
        edition = "2021"

        [lib]
        crate-type = ["cdylib"]

        [dependencies]

        [profile.release]
        panic = "unwind"
        """)
    _hrt_write_source(dir, value)
    return dir
end

_hrt_write_source(dir, value) = write(joinpath(dir, "src", "lib.rs"), """
    #[no_mangle]
    pub extern "C" fn hrt_probe() -> i32 { $(value) }
    """)

_hrt_write_broken(dir) = write(joinpath(dir, "src", "lib.rs"), """
    #[no_mangle]
    pub extern "C" fn hrt_probe() -> i32 { this is not rust }
    """)

"""
The Julia half of a `#[julia]` struct: exactly the fields
`RustCall.finalize_rust_object!` reads. Like a generated wrapper, it captures
its destructor and its image's liveness flag at construction — from one
snapshot, so the two cannot come from different generations (#249, #277).
"""
mutable struct StressThing
    ptr::Ptr{Cvoid}
    free_ptr::Ptr{Cvoid}
    alive::Base.RefValue{Bool}
end

"""The stress crate's source, tagged with the generation it belongs to."""
_hrt_write_stress(crate, generation) = write(joinpath(crate, "src", "lib.rs"), """
    use std::cell::RefCell;

    thread_local! {
        static BOOM_PANIC: RefCell<Option<String>> = RefCell::new(None);
    }

    /// This image's generation. A call that straddled a swap would return a
    /// number that was never published.
    #[no_mangle]
    pub extern "C" fn stress_generation() -> i32 { $(generation) }

    /// The shape `rustcall_core::codegen` emits: the body runs inside
    /// `catch_unwind`, a panic is recorded in this wrapper's thread-local
    /// channel, and a sentinel of the right shape is returned.
    #[no_mangle]
    pub extern "C" fn stress_boom() -> i32 {
        match std::panic::catch_unwind(|| -> i32 {
            panic!("boom from generation $(generation)")
        }) {
            Ok(value) => value,
            Err(payload) => {
                let message = match payload.downcast_ref::<&str>() {
                    Some(s) => s.to_string(),
                    None => match payload.downcast_ref::<String>() {
                        Some(s) => s.clone(),
                        None => "the Rust function panicked".to_string(),
                    },
                };
                BOOM_PANIC.with(|s| *s.borrow_mut() = Some(message));
                0
            }
        }
    }

    #[no_mangle]
    pub extern "C" fn stress_boom_take_panic(out: *mut u8, cap: usize) -> usize {
        BOOM_PANIC.with(|s| {
            let mut s = s.borrow_mut();
            let n = match s.as_ref() {
                Some(message) => {
                    let bytes = message.as_bytes();
                    if bytes.len() <= cap && !out.is_null() {
                        unsafe {
                            std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len());
                        }
                        Some(bytes.len())
                    } else {
                        return bytes.len();
                    }
                }
                None => None,
            };
            match n {
                Some(n) => { *s = None; n }
                None => 0,
            }
        })
    }

    /// A heap object and the destructor RustCall captures at construction.
    #[repr(C)]
    pub struct Thing { generation: i32 }

    #[no_mangle]
    pub extern "C" fn Thing_new() -> *mut Thing {
        Box::into_raw(Box::new(Thing { generation: $(generation) }))
    }

    #[no_mangle]
    pub extern "C" fn Thing_free(ptr: *mut Thing) {
        if !ptr.is_null() {
            unsafe { drop(Box::from_raw(ptr)) };
        }
    }
    """)

function _hrt_state(crate, lib_name)
    state = RustCall.HotReloadState(
        crate, "", lib_name, RustCall.find_rust_source_files(crate),
        Dict{String, Float64}(), nothing, true, nothing)
    for f in state.source_files
        state.last_modified[f] = RustCall.get_file_mtime(f)
    end
    return state
end

@testset "Hot reload is transactional (#255)" begin

    # ------------------------------------------------------------------
    # (2) Each reload opens its own file, so the rebuild never has to
    #     overwrite the image that is currently mapped.
    # ------------------------------------------------------------------
    @testset "each reload opens a fresh path" begin
        # `joinpath` on both sides: the separator is the platform's, and this
        # test also runs on Windows.
        @test RustCall.generation_path(joinpath("tmp", "libfoo.dylib"), 1) ==
              joinpath("tmp", "libfoo.1.dylib")
        @test RustCall.generation_path(joinpath("tmp", "libfoo.so"), 12) ==
              joinpath("tmp", "libfoo.12.so")
        # Next to the original, not in a temp directory: on Windows a DLL
        # resolves its dependencies relative to its own location.
        @test dirname(RustCall.generation_path(joinpath("a", "b", "libfoo.so"), 2)) ==
              joinpath("a", "b")
        @test basename(RustCall.generation_path(joinpath("a", "b", "foo.dll"), 7)) ==
              "foo.7.dll"

        @test occursin("loadable_library_copy(built)", _HRT_SRC)
        # The generation comes from a process-wide counter, so disabling and
        # re-enabling hot reload cannot restart at 1 and collide with a `.1.`
        # file that is still mapped (#255).
        @test occursin("state.generation = RELOAD_GENERATION[]", _HRT_SRC)
        a = RustCall.next_reload_generation()
        b = RustCall.next_reload_generation()
        @test b == a + 1
        # A *fresh* state does not reset it.
        fresh = RustCall.HotReloadState("/nonexistent", "", "x", String[],
                                        Dict{String, Float64}(), nothing, true, nothing)
        @test fresh.generation == 0
        @test RustCall.next_reload_generation() > b
        @test occursin("loadable_library_copy", _src_loadpolicy())
        # The previous image is RETIRED after the swap, never closed under a
        # call that may still be inside it (#277).
        @test !occursin("on_replace = :dlclose", _HRT_SRC)
        @test findfirst("rebuild_crate(state.crate_path)", _HRT_SRC) <
              findfirst("loadable_library_copy(built)", _HRT_SRC) <
              findfirst("load_artifact!(hot_reload_policy()", _HRT_SRC)
    end

    # ------------------------------------------------------------------
    # (4) An idle watcher blocks in the kernel rather than polling.
    # ------------------------------------------------------------------
    @testset "no polling loop when idle" begin
        @test occursin("FileWatching.watch_folder", _HRT_SRC)
        @test occursin("_await_source_change", _HRT_SRC)
        @test occursin("poll::Bool", _HRT_SRC)     # the explicit fallback
        # The watch loop itself no longer sleeps; only the `poll` branch and
        # the debounce window do.
        loop = _HRT_SRC[first(findfirst("state.watch_task = @async begin", _HRT_SRC)):end]
        loop = loop[1:first(findfirst("Stopped watching", loop))]
        @test !occursin("sleep(interval)\n", loop) || occursin("if poll", loop)

        # Behavioural: waiting on an unchanged directory returns `false` after
        # roughly the timeout, having consumed no CPU in between. A polling
        # loop would have `stat`ed every source file instead.
        mktempdir() do dir
            crate = _hrt_make_crate(joinpath(dir, "idle"), "hrt_idle", 1)
            state = _hrt_state(crate, "hrt_idle_lib")
            # Creating the crate queued a few filesystem events; drain them so
            # the measurement below is of an *idle* watch.
            RustCall._drain_source_changes(state, 0.05)

            # Waiting on an unchanged directory reports "nothing changed"
            # and returns — it neither spins forever nor blocks forever. The
            # wait may return early on an event the platform had already
            # queued (macOS does), which is why the timing assertion is an
            # upper bound: what matters for #255 is that the loop is driven by
            # the kernel rather than by `stat`, and that is asserted against
            # the source above.
            t0 = time()
            for _ in 1:3
                @test RustCall._await_source_change(state, 0.3) == false
            end
            @test time() - t0 < 5.0

            # The debounce cannot be extended forever by a platform that keeps
            # handing back a queued event.
            t0 = time()
            RustCall._drain_source_changes(state, 0.05)
            @test time() - t0 < 0.05 * RustCall.MAX_DEBOUNCE_WINDOWS + 2.0
        end
    end

    # ------------------------------------------------------------------
    # The scan-vs-build consistency check hashes CONTENT.
    #
    # A `(mtime, size)` stamp misses the edit a developer is most likely to
    # make between the scan and the build: one character for another, with the
    # mtime restored by an editor, a formatter or a `git checkout`. The
    # manifest would then describe sources the build did not compile.
    # ------------------------------------------------------------------
    @testset "a same-size edit with a restored mtime is detected" begin
        @test occursin("crate_content_digest", _HRT_SRC)
        @test !occursin("_source_stamps", _HRT_SRC)

        mktempdir() do dir
            crate = _hrt_make_crate(joinpath(dir, "digest"), "hrt_digest", 1)
            src = joinpath(crate, "src", "lib.rs")
            before = RustCall._source_fingerprint(crate)
            @test !isempty(before)
            @test RustCall._source_fingerprint(crate) == before   # stable

            stamp = stat(src)
            original = read(src, String)
            # Same length, different content — `1` becomes `2` — and the mtime
            # is put back where it was.
            edited = replace(original, "hrt_probe() -> i32 { 1 }" =>
                                       "hrt_probe() -> i32 { 2 }")
            @test length(edited) == length(original)
            write(src, edited)
            touch(src)
            try
                # Restore mtime and atime to the pre-edit values.
                Base.Filesystem.futime(src, stamp.mtime, stamp.mtime)
            catch
                # Not every platform exposes it; the digest does not care.
            end
            @test filesize(src) == stamp.size

            after = RustCall._source_fingerprint(crate)
            @test after != before          # a stamp would have said "unchanged"
        end
    end

    # ------------------------------------------------------------------
    # (3) Two saves inside the debounce window are one reload.
    # ------------------------------------------------------------------
    @testset "two saves within 200 ms produce one reload" begin
        @test RustCall.HOT_RELOAD_DEBOUNCE_SECONDS[] > 0
        @test RustCall.HOT_RELOAD_DEBOUNCE_SECONDS[] <= 0.2

        mktempdir() do dir
            crate = _hrt_make_crate(joinpath(dir, "debounce"), "hrt_debounce", 1)
            state = _hrt_state(crate, "hrt_debounce_lib")

            # Two writes 50 ms apart, both inside the window.
            _hrt_write_source(crate, 2)
            sleep(0.05)
            _hrt_write_source(crate, 3)

            # The drain absorbs the whole burst, so the single rebuild that
            # follows it sees no further pending change — which is what makes
            # two saves one reload rather than two.
            RustCall._drain_source_changes(state, RustCall.HOT_RELOAD_DEBOUNCE_SECONDS[])
            @test !RustCall.check_for_changes(state)
        end
    end

    # ------------------------------------------------------------------
    # A reload while a call is in flight must not pull the ground out.
    #
    # This is why a replaced image is retired rather than closed: the call
    # below reads its function pointer, enters the old image, and is still
    # inside it when the reload swaps the library. Closing the image there is a
    # use-after-`dlclose`.
    # ------------------------------------------------------------------
    if !_HRT_CARGO
        @test_skip "cargo is required for the in-flight reload test"
    else
        @testset "a reload does not close an image a call is inside" begin
            mktempdir() do dir
                crate = joinpath(dir, "inflight")
                mkpath(joinpath(crate, "src"))
                write(joinpath(crate, "Cargo.toml"), """
                    [package]
                    name = "hrt_inflight"
                    version = "0.1.0"
                    edition = "2021"

                    [lib]
                    crate-type = ["cdylib"]

                    [dependencies]

                    [profile.release]
                    panic = "unwind"
                    """)
                # A function that stays inside the image for 200 ms.
                write(joinpath(crate, "src", "lib.rs"), """
                    #[no_mangle]
                    pub extern "C" fn hrt_slow() -> i32 {
                        std::thread::sleep(std::time::Duration::from_millis(200));
                        1
                    }
                    """)
                lib_name = "hrt_inflight_lib"
                state = _hrt_state(crate, lib_name)
                try
                    @test RustCall.reload_library(state)
                    old_handle = lock(() -> RustCall.RUST_LIBRARIES[lib_name][1],
                                      RustCall.REGISTRY_LOCK)
                    # The pointer is read *now*, out of the image that is about
                    # to be replaced — exactly what an in-flight call holds.
                    slow = RustCall.get_function_pointer(lib_name, "hrt_slow")

                    result = Ref(0)
                    task = Threads.@spawn begin
                        result[] = RustCall.call_rust_function(slow, Int32)
                    end

                    # Reload while it is inside.
                    sleep(0.05)
                    write(joinpath(crate, "src", "lib.rs"), """
                        #[no_mangle]
                        pub extern "C" fn hrt_slow() -> i32 {
                            std::thread::sleep(std::time::Duration::from_millis(200));
                            2
                        }
                        """)
                    @test RustCall.reload_library(state)

                    # The call completes rather than crashing the process.
                    wait(task)
                    @test result[] == Int32(1)     # it ran the OLD code, as it must

                    # The old image is retired, still mapped, and not closed.
                    retired = RustCall.retired_handles(lib_name)
                    @test old_handle in retired
                    @test length(retired) == 1

                    # Closing it is explicit, and closes it exactly once.
                    before = RustCall.DLCLOSE_COUNT[]
                    RustCall.unload_library(lib_name; close = true)
                    @test RustCall.DLCLOSE_COUNT[] == before + 2   # live + retired
                    @test isempty(RustCall.retired_handles(lib_name))
                finally
                    try
                        RustCall.unload_library(lib_name; close = true)
                    catch
                    end
                end
            end
        end
    end

    # ------------------------------------------------------------------
    # (1) A failed rebuild keeps the previous library, and says so once.
    # ------------------------------------------------------------------
    if !_HRT_CARGO
        @test_skip "cargo is required for the failed-rebuild test"
    else
        @testset "a failed rebuild keeps the previous library (#255)" begin
            mktempdir() do dir
                crate = _hrt_make_crate(joinpath(dir, "reload"), "hrt_reload", 41)
                lib_name = "hrt_reload_lib"
                state = _hrt_state(crate, lib_name)

                try
                    # First build: the library loads and answers 41.
                    @test RustCall.reload_library(state)
                    @test haskey(RustCall.RUST_LIBRARIES, lib_name)
                    @test RustCall.call_rust_function(
                        RustCall.get_function_pointer(lib_name, "hrt_probe"),
                        Int32) == Int32(41)
                    good_generation = state.generation
                    # A process-wide counter, so the value is whatever this
                    # process is up to — the point is that it is used and that
                    # the file is named after it (#255).
                    @test good_generation >= 1
                    @test isfile(state.lib_path)
                    @test occursin(".$(good_generation).", basename(state.lib_path))

                    # Now save a file that does not compile.
                    _hrt_write_broken(crate)
                    @test !RustCall.reload_library(state)

                    # The previous library is still loaded and still works —
                    # the whole point of building before swapping.
                    @test haskey(RustCall.RUST_LIBRARIES, lib_name)
                    @test RustCall.call_rust_function(
                        RustCall.get_function_pointer(lib_name, "hrt_probe"),
                        Int32) == Int32(41)
                    @test state.generation == good_generation   # no swap happened
                    @test !isempty(state.last_failure)

                    # The same failure is reported once: a second attempt with
                    # the same broken source logs nothing new at :error level.
                    failure = state.last_failure
                    @test !RustCall.reload_library(state)
                    @test state.last_failure == failure

                    # Fixing the file reloads successfully, into a *new* file.
                    _hrt_write_source(crate, 99)
                    @test RustCall.reload_library(state)
                    @test isempty(state.last_failure)
                    @test state.generation > good_generation
                    @test RustCall.call_rust_function(
                        RustCall.get_function_pointer(lib_name, "hrt_probe"),
                        Int32) == Int32(99)

                    # A module-local copy of the handle — what a generated
                    # `@rust_crate` module keeps — follows the swap. Without
                    # that it would still point at the image the reload closed,
                    # and the next `dlsym` would read unmapped memory (#277).
                    handle_ref = Ref(Ptr{Cvoid}(C_NULL))
                    alive_ref = Ref(Ref(true))
                    RustCall.register_handle_mirror!(lib_name, handle_ref, alive_ref)
                    current = lock(() -> RustCall.RUST_LIBRARIES[lib_name][1],
                                   RustCall.REGISTRY_LOCK)
                    @test handle_ref[] == current
                    @test alive_ref[][]

                    _hrt_write_source(crate, 123)
                    @test RustCall.reload_library(state)
                    swapped = lock(() -> RustCall.RUST_LIBRARIES[lib_name][1],
                                   RustCall.REGISTRY_LOCK)
                    @test handle_ref[] == swapped
                    @test handle_ref[] != current      # a genuinely new image
                    @test alive_ref[][]
                    # ...and the mirror resolves the new library's symbol.
                    @test RustCall.call_rust_function(
                        Libdl.dlsym(handle_ref[], "hrt_probe"), Int32) == Int32(123)

                    # The replaced image is RETIRED, not closed: a call that
                    # started before the reload may still be running inside it,
                    # and there is no per-call reader pin that would make
                    # closing safe. It is kept mapped until someone says it is
                    # safe to reclaim (#277).
                    retired = RustCall.retired_handles(lib_name)
                    @test length(retired) >= 1
                    @test current in retired            # the pre-reload image
                    @test !(swapped in retired)         # ...but not the live one
                    # ...and it is still mapped, so a pointer taken from it
                    # before the reload still resolves.
                    @test Libdl.dlsym(current, "hrt_probe"; throw_error = false) !== nothing

                    # An unload empties the mirror, so a module reading it
                    # reports "not loaded" rather than calling into a closed
                    # image — and does NOT close the retired ones by default.
                    closes_before = RustCall.DLCLOSE_COUNT[]
                    RustCall.unload_library(lib_name)
                    @test handle_ref[] == C_NULL
                    @test !alive_ref[][]
                    # Nothing was closed: unloading retires, exactly as a
                    # reload does — one code path (#277).
                    @test RustCall.DLCLOSE_COUNT[] == closes_before

                    # The records survive the name going away, so they stay
                    # reclaimable. `close = true` is the caller stating that
                    # nothing is in flight, and reclaims exactly them.
                    remaining = RustCall.retired_handles(lib_name)
                    @test length(remaining) >= 3     # two reloads + the unload
                    # Close exactly this library's images, and let the *return
                    # value* say how many went: `DLCLOSE_COUNT` is process-wide,
                    # so an exact delta on it would be an assertion about
                    # whatever else the suite loaded.
                    @test RustCall.close_retired_handles!(remaining) == length(remaining)
                    @test isempty(RustCall.retired_handles(lib_name))
                    @test RustCall.DLCLOSE_COUNT[] >= closes_before + length(remaining)
                    # Closing again is a no-op: the records are gone.
                    @test RustCall.close_retired_handles!(remaining) == 0
                finally
                    # Windows locks a loaded DLL, so the temp tree can only be
                    # removed after the library is gone. Best effort either way.
                    try
                        RustCall.unload_library(lib_name)
                    catch
                    end
                end
            end
        end
    end

    # ------------------------------------------------------------------
    # The generation-snapshot rule, under concurrency (#277).
    #
    # Every FFI entry point takes ONE snapshot under ONE lock — pointer,
    # panic channel, destructor, liveness flag — and nothing after the
    # snapshot looks anything up by library name. This is the adversarial
    # case for that rule: a reload loop runs against live traffic, and each
    # of the three kinds of traffic has an observable invariant.
    #
    #   * no wrong-generation call — the crate returns its own generation,
    #     so a call that straddled a swap shows up as a value that was
    #     never published;
    #   * no lost panic — a panicking wrapper always raises
    #     `RustPanicError`; its sentinel never reaches the caller;
    #   * no finalizer failure — an object frees through the destructor of
    #     the image that allocated it, or not at all.
    #
    # The wrappers are hand-written rather than macro-generated for the
    # reason given at the top of this file: the ABI is what is under test,
    # not `#[julia]`, and pulling in `juliacall_macros` would compile `syn`
    # from scratch on every CI run.
    # ------------------------------------------------------------------
    if !_HRT_CARGO
        @test_skip "cargo is required for the reload stress test"
    else
        @testset "calls, panics and objects survive a reload loop (#277)" begin
            mktempdir() do dir
                crate = joinpath(dir, "stress")
                mkpath(joinpath(crate, "src"))
                write(joinpath(crate, "Cargo.toml"), """
                    [package]
                    name = "hrt_stress"
                    version = "0.1.0"
                    edition = "2021"

                    [lib]
                    crate-type = ["cdylib"]

                    [dependencies]

                    [profile.release]
                    panic = "unwind"
                    """)

                lib_name = "hrt_stress_lib"
                _hrt_write_stress(crate, 1)
                state = _hrt_state(crate, lib_name)

                try
                    @test RustCall.reload_library(state)

                    published = Set{Int32}([Int32(1)])
                    published_lock = ReentrantLock()
                    stop = Threads.Atomic{Bool}(false)
                    wrong_generation = Threads.Atomic{Int}(0)
                    lost_panic = Threads.Atomic{Int}(0)
                    wrong_panic = Threads.Atomic{Int}(0)
                    calls = Threads.Atomic{Int}(0)
                    panics = Threads.Atomic{Int}(0)
                    objects = Threads.Atomic{Int}(0)
                    failures_before = RustCall.finalizer_failure_count()

                    # A caller. The value must be a generation that was
                    # published at some point — never a mixture.
                    caller = Threads.@spawn begin
                        while !stop[]
                            target = RustCall.resolve_call_target(lib_name, "stress_generation")
                            value = RustCall.call_rust_function(target.func_ptr, Int32)
                            lock(published_lock) do
                                value in published || Threads.atomic_add!(wrong_generation, 1)
                            end
                            Threads.atomic_add!(calls, 1)
                            yield()
                        end
                    end

                    # A panicker. Pointer and channel come from one snapshot,
                    # and nothing yields between the call and the read.
                    panicker = Threads.@spawn begin
                        while !stop[]
                            target = RustCall.resolve_call_target(lib_name, "stress_boom")
                            raised = false
                            try
                                RustCall.guard_rust_panic_ptr(
                                    RustCall.call_rust_function(target.func_ptr, Int32),
                                    target.channel, "stress_boom")
                            catch e
                                raised = true
                                e isa RustCall.RustPanicError || Threads.atomic_add!(wrong_panic, 1)
                                occursin("boom from generation", sprint(showerror, e)) ||
                                    Threads.atomic_add!(wrong_panic, 1)
                            end
                            raised || Threads.atomic_add!(lost_panic, 1)
                            Threads.atomic_add!(panics, 1)
                            yield()
                        end
                    end

                    # An allocator: objects are created and dropped while the
                    # image under them is replaced.
                    allocator = Threads.@spawn begin
                        while !stop[]
                            target = RustCall.resolve_call_target(lib_name, "Thing_new")
                            gen = RustCall.artifact_generation_snapshot(lib_name, "Thing")
                            ptr = RustCall.call_rust_function(target.func_ptr, Ptr{Cvoid})
                            thing = StressThing(ptr, gen.free_ptr, gen.alive)
                            finalizer(RustCall.finalize_rust_object!, thing)
                            Threads.atomic_add!(objects, 1)
                            thing = nothing
                            GC.gc(false)
                            yield()
                        end
                    end

                    # ...and the reload loop they all run against.
                    for generation in 2:5
                        # Published *before* the source is written: the swap
                        # commits inside `reload_library`, so a caller can
                        # legitimately observe the new generation before that
                        # call returns. The invariant is that no call ever
                        # returns a value that was never written — a mixture of
                        # two generations, or a read of freed memory.
                        lock(published_lock) do
                            push!(published, Int32(generation))
                        end
                        _hrt_write_stress(crate, generation)
                        RustCall.reload_library(state)
                    end

                    stop[] = true
                    wait(caller); wait(panicker); wait(allocator)
                    GC.gc(true)

                    # The loop really did run against live traffic...
                    @test calls[] > 0
                    @test panics[] > 0
                    @test objects[] > 0
                    @test length(published) > 1

                    # ...and every invariant held.
                    @test wrong_generation[] == 0
                    @test lost_panic[] == 0
                    @test wrong_panic[] == 0
                    @test RustCall.finalizer_failure_count() == failures_before
                finally
                    try
                        RustCall.unload_library(lib_name)
                    catch
                    end
                end
            end
        end
    end
end
