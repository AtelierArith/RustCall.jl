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
_src_structs() = read(joinpath(dirname(dirname(pathof(RustCall))), "src",
                               "structs.jl"), String)

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

    thread_local! {
        static BOOM_QUIET: std::cell::Cell<usize> = std::cell::Cell::new(0);
    }
    static BOOM_HOOK: std::sync::Once = std::sync::Once::new();

    /// The quiet hook `rustcall_core::codegen` now emits beside every panic
    /// channel: silent while this thread is inside the boundary, delegating to
    /// the previous hook otherwise. Without it this test alone prints ~2300
    /// `thread '<unnamed>' panicked at ...` lines, because it panics on
    /// purpose thousands of times.
    struct BoomQuiet;
    impl BoomQuiet {
        fn new() -> Self {
            BOOM_HOOK.call_once(|| {
                let previous = std::panic::take_hook();
                std::panic::set_hook(Box::new(move |info| {
                    if BOOM_QUIET.try_with(|d| d.get()).unwrap_or(0) == 0 {
                        previous(info);
                    }
                }));
            });
            BOOM_QUIET.with(|d| d.set(d.get() + 1));
            Self
        }
    }
    impl Drop for BoomQuiet {
        fn drop(&mut self) {
            let _ = BOOM_QUIET.try_with(|d| d.set(d.get().saturating_sub(1)));
        }
    }

    /// The shape `rustcall_core::codegen` emits: the body runs inside
    /// `catch_unwind`, a panic is recorded in this wrapper's thread-local
    /// channel, and a sentinel of the right shape is returned.
    #[no_mangle]
    pub extern "C" fn stress_boom() -> i32 {
        let _quiet = BoomQuiet::new();
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

            # ...and it did not *scan*. This is the criterion, counted rather
            # than inferred: `watch_folder` returning "the wait expired" used
            # to be treated as an event, so an idle project `stat`ed every
            # source file every interval, forever. A timeout now returns
            # without touching the mtime table (#255).
            RustCall._drain_source_changes(state, 0.05)
            before_scans = RustCall.source_scan_count()
            for _ in 1:4
                @test RustCall._await_source_change(state, 0.2) == false
            end
            @test RustCall.source_scan_count() == before_scans

            # A real change still wakes it — the watch is event-driven, not
            # disabled.
            _hrt_write_source(crate, 2)
            woke = false
            for _ in 1:10
                if RustCall._await_source_change(state, 1.0)
                    woke = true
                    break
                end
            end
            @test woke
            @test RustCall.source_scan_count() > before_scans

            # The debounce cannot be extended forever by a platform that keeps
            # handing back a queued event.
            t0 = time()
            RustCall._drain_source_changes(state, 0.05)
            @test time() - t0 < 0.05 * RustCall.MAX_DEBOUNCE_WINDOWS + 2.0

            # ...and with nothing happening it lasts ONE window, not the cap.
            # A `watch_folder` timeout used to count as an event and restart
            # the deadline, so a single save waited out `MAX_DEBOUNCE_WINDOWS`
            # before its rebuild — a tenth of a second became a second (#255).
            window = 0.2
            t0 = time()
            RustCall._drain_source_changes(state, window)
            elapsed = time() - t0
            @test elapsed >= window * 0.5           # it did wait the window
            @test elapsed < window * 3              # ...and not the cap
            # It also did not scan on each timeout.
            before_scans = RustCall.source_scan_count()
            RustCall._drain_source_changes(state, window)
            @test RustCall.source_scan_count() - before_scans <= 2
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
                    gen_ref = Ref(RustCall.CrateGeneration())
                    RustCall.register_handle_mirror!(lib_name, gen_ref)
                    current = lock(() -> RustCall.RUST_LIBRARIES[lib_name][1],
                                   RustCall.REGISTRY_LOCK)
                    @test gen_ref[].handle == current
                    @test gen_ref[].alive[]

                    _hrt_write_source(crate, 123)
                    @test RustCall.reload_library(state)
                    swapped = lock(() -> RustCall.RUST_LIBRARIES[lib_name][1],
                                   RustCall.REGISTRY_LOCK)
                    @test gen_ref[].handle == swapped
                    @test gen_ref[].handle != current      # a genuinely new image
                    @test gen_ref[].alive[]
                    # ...and the mirror resolves the new library's symbol.
                    @test RustCall.call_rust_function(
                        Libdl.dlsym(gen_ref[].handle, "hrt_probe"), Int32) == Int32(123)

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
                    @test gen_ref[].handle == C_NULL
                    @test !gen_ref[].alive[]
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
    # The watch covers nested modules, and a save during a build is not lost.
    #
    # `watch_folder` is not recursive — inotify watches one directory — so
    # watching only `src/` missed every edit to `src/foo/mod.rs`. That was
    # invisible while a timeout still triggered a scan; once a timeout stopped
    # scanning, a nested edit never reloaded on Linux at all.
    # ------------------------------------------------------------------
    @testset "a nested source file is watched (#255)" begin
        mktempdir() do dir
            crate = joinpath(dir, "nested")
            mkpath(joinpath(crate, "src", "inner"))
            write(joinpath(crate, "Cargo.toml"), """
                [package]
                name = "hrt_nested"
                version = "0.1.0"
                edition = "2021"

                [lib]
                crate-type = ["cdylib"]

                [dependencies]
                """)
            write(joinpath(crate, "src", "lib.rs"), """
                mod inner;
                """)
            nested = joinpath(crate, "src", "inner", "mod.rs")
            write(nested, """
                #[no_mangle]
                pub extern "C" fn hrt_nested() -> i32 { 1 }
                """)

            state = _hrt_state(crate, "hrt_nested_lib")
            # The tracker sees the nested file...
            @test any(f -> basename(dirname(f)) == "inner", state.source_files)
            # ...and so does the watch: both directories are subscribed.
            dirs = RustCall._watched_directories(state)
            @test joinpath(crate, "src") in dirs
            @test joinpath(crate, "src", "inner") in dirs

            # An edit to the nested file wakes the wait. With only `src/`
            # watched this blocks for the whole timeout and reports nothing.
            RustCall._drain_source_changes(state, 0.05)
            woke = false
            waiter = Threads.@spawn begin
                for _ in 1:10
                    RustCall._await_source_change(state, 1.0) && return true
                end
                return false
            end
            sleep(0.2)
            write(nested, """
                #[no_mangle]
                pub extern "C" fn hrt_nested() -> i32 { 2 }
                """)
            woke = fetch(waiter)
            @test woke
        end
    end

    # ------------------------------------------------------------------
    # A save that lands during the build is not lost (#255).
    #
    # Nothing is subscribed while `reload_library` runs, so the event that
    # would have woken the watcher never arrives. The fingerprint comparison
    # that already straddles the build now causes another pass.
    # ------------------------------------------------------------------
    if !_HRT_CARGO
        @test_skip "cargo is required for the mid-build save test"
    else
        @testset "a save during the rebuild is picked up (#255)" begin
            mktempdir() do dir
                crate = _hrt_make_crate(joinpath(dir, "chase"), "hrt_chase", 1)
                # A build script that takes its time, so "write while the
                # build is running" is a fact rather than a hope. Cargo reruns
                # it whenever a file in the package changes, which is every
                # pass here.
                write(joinpath(crate, "build.rs"), """
                    fn main() {
                        std::thread::sleep(std::time::Duration::from_millis(1500));
                    }
                    """)
                lib_name = "hrt_chase_lib"
                state = _hrt_state(crate, lib_name)
                try
                    @test RustCall.reload_library(state)
                    @test RustCall.call_rust_function(
                        RustCall.resolve_call_target(lib_name, "hrt_probe").func_ptr,
                        Int32) == Int32(1)

                    # Write value 2, and have another task write value 3 while
                    # the build for 2 is still running. The build that commits
                    # last must be the one for 3: without the chase, the
                    # library would serve 2 until some later event.
                    _hrt_write_source(crate, 2)
                    generations = RustCall.artifact_generation(lib_name)
                    racer = Threads.@spawn begin
                        sleep(0.6)       # inside the build script's sleep
                        _hrt_write_source(crate, 3)
                    end
                    @test RustCall.reload_library(state)
                    wait(racer)

                    # The call installed **two** generations: the build that
                    # was in flight when the save landed, and the one that
                    # chased it. Without the chase the second save would sit
                    # on disk unbuilt until some later event — and nothing was
                    # subscribed to notice it.
                    @test RustCall.artifact_generation(lib_name) - generations == 2
                    @test RustCall.call_rust_function(
                        RustCall.resolve_call_target(lib_name, "hrt_probe").func_ptr,
                        Int32) == Int32(3)
                    # The bound exists and is small.
                    @test RustCall.MAX_RELOAD_CHASES == 3
                finally
                    # `close = true`, not a bare unload: every reload retires
                    # the previous image and leaves it mapped, and Cargo built
                    # each one inside `dir`. A mapped file cannot be deleted on
                    # Windows, so `mktempdir`'s cleanup fails with ENOTEMPTY
                    # under `chase/target/release` and logs it at Error level.
                    # Closing first is what makes the cleanup succeed.
                    try
                        RustCall.unload_library(lib_name; close = true)
                    catch
                    end
                    RustCall.close_retired_handles!()
                end
            end
        end
    end

    # ------------------------------------------------------------------
    # The cfg probe is memoized on what decides its answer (#255, #277).
    #
    # A reload rescans the crate under the `#[cfg]` set its build actually
    # has. That set was memoized on the crate *path*, so turning a default
    # feature on or off between two reloads reused the previous answer: the
    # rescan then described `#[cfg(feature = ...)]` items the new build does
    # not contain, or missed ones it does, and registered the wrong ABI for
    # functions the program went on to call.
    # ------------------------------------------------------------------
    if !_HRT_CARGO
        @test_skip "cargo is required for the cfg-probe memo test"
    else
        @testset "the cfg probe follows a feature change (#255)" begin
            mktempdir() do dir
                crate = joinpath(dir, "cfgmemo")
                mkpath(joinpath(crate, "src"))
                manifest = joinpath(crate, "Cargo.toml")
                write_manifest = defaults -> write(manifest, """
                    [package]
                    name = "hrt_cfgmemo"
                    version = "0.1.0"
                    edition = "2021"

                    [lib]
                    crate-type = ["cdylib"]

                    [features]
                    default = [$(defaults)]
                    extra = []

                    [dependencies]
                    """)
                write(joinpath(crate, "src", "lib.rs"), """
                    #[no_mangle]
                    pub extern "C" fn hrt_cfgmemo() -> i32 { 1 }
                    """)

                write_manifest("")
                without = RustCall._crate_build_cfg_text(crate)
                @test !isempty(without)
                @test !occursin("feature=\"extra\"", without)

                # Only `Cargo.toml` changed — no source edit, and the path is
                # the same, which is all the old memo key looked at.
                write_manifest("\"extra\"")
                with = RustCall._crate_build_cfg_text(crate)
                @test occursin("feature=\"extra\"", with)
                @test with != without

                # ...and back again, so this is the memo following the input
                # rather than simply never memoizing.
                write_manifest("")
                @test RustCall._crate_build_cfg_text(crate) == without
            end
        end
    end

    # ------------------------------------------------------------------
    # A cached `FunctionInfo` is itself a snapshot (#277).
    #
    # This is the monomorphized-generic shape: the record is built once and
    # called long afterwards. It used to look its panic channel up by library
    # name at call time, so a task that unloaded the library in between got
    # `C_NULL` — while `func_ptr` still entered the mapped retired image. A
    # panic then came back as the wrapper's zero sentinel and was silently
    # accepted as a result. Deterministic, no threads required.
    # ------------------------------------------------------------------
    if !_HRT_CARGO
        @test_skip "cargo is required for the cached-snapshot test"
    else
        @testset "a cached FunctionInfo keeps its panic channel (#277)" begin
            mktempdir() do dir
                crate = joinpath(dir, "cached")
                mkpath(joinpath(crate, "src"))
                write(joinpath(crate, "Cargo.toml"), """
                    [package]
                    name = "hrt_cached"
                    version = "0.1.0"
                    edition = "2021"

                    [lib]
                    crate-type = ["cdylib"]

                    [dependencies]

                    [profile.release]
                    panic = "unwind"
                    """)
                _hrt_write_stress(crate, 7)
                lib_name = "hrt_cached_lib"
                state = _hrt_state(crate, lib_name)
                try
                    @test RustCall.reload_library(state)
                    target = RustCall.resolve_call_target(lib_name, "stress_boom")
                    @test target.channel != C_NULL
                    # Built exactly as `monomorphize_function` builds one: the
                    # channel and the handle resolved *now*, with the pointer.
                    info = RustCall.FunctionInfo(
                        "stress_boom", lib_name, Int32, Type[], target.func_ptr,
                        String[], :none, C_NULL,
                        target.channel, target.handle, target.generation)

                    # It works while the library is registered...
                    @test_throws RustCall.RustPanicError RustCall._call_monomorphized(info)

                    # ...and it still works once the library has been unloaded.
                    # The image is *retired*, not closed, so the pointer is
                    # still callable — and the panic must still be raised
                    # rather than returned as a zero.
                    # A constructor's snapshot carries the destructor and the
                    # liveness flag the object it allocates will capture, so
                    # the two cannot come from different generations (#277).
                    ctor = RustCall.resolve_call_target(lib_name, "Thing_new";
                                                        free_symbol = "Thing_free")
                    handle = lock(() -> RustCall.RUST_LIBRARIES[lib_name][1],
                                  RustCall.REGISTRY_LOCK)
                    @test ctor.handle == handle
                    @test ctor.free_ptr == Libdl.dlsym(handle, "Thing_free")
                    @test ctor.alive === RustCall.artifact_alive_ref(lib_name)
                    @test ctor.alive[]
                    @test ctor.generation == RustCall.artifact_generation(lib_name)
                    # ...and that is what `_call_rust_constructor` hands the
                    # generated inner constructor.
                    @test occursin("_call_rust_constructor(lib, ", _src_structs())
                    @test occursin("tgt.free_ptr, tgt.alive", _src_structs())

                    RustCall.unload_library(lib_name)
                    @test !haskey(RustCall.RUST_LIBRARIES, lib_name)
                    @test_throws RustCall.RustPanicError RustCall._call_monomorphized(info)
                    # The image is retired, not closed, so the destructor the
                    # object captured is still callable and its flag still
                    # true — which is what makes "retire, not close" safe.
                    @test ctor.alive[]
                finally
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
                    # What a generated `@rust_crate` module keeps: ONE
                    # immutable record, published by the loader in the same
                    # transaction that swaps the registry entry.
                    mirror = Ref(RustCall.CrateGeneration())
                    RustCall.register_handle_mirror!(lib_name, mirror)
                    # (generation number, value that generation returned).
                    # Every entry for one generation must agree: a call that
                    # read the handle of one generation and the code of another
                    # would show up as one number with two values.
                    seen = Set{Tuple{Int, Int32}}()
                    # (generation of the constructor snapshot, generation
                    # marker stored in the object it allocated).
                    ctor_seen = Set{Tuple{Int, Int32}}()
                    seen_lock = ReentrantLock()
                    crate_calls = Threads.Atomic{Int}(0)
                    dead_generation = Threads.Atomic{Int}(0)
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

                    # A crate module: one deref of the record per call, then
                    # `dlsym` and the call on *that* handle — exactly what
                    # `_call_target` and `_struct_generation` do in a generated
                    # module. Nothing here consults the registry by name.
                    crate_module = Threads.@spawn begin
                        while !stop[]
                            gen = mirror[]
                            if gen.handle != C_NULL
                                ptr = Libdl.dlsym(gen.handle, "stress_generation";
                                                  throw_error = false)
                                if ptr !== nothing
                                    value = RustCall.call_rust_function(ptr, Int32)
                                    # The image it just called must not have
                                    # been closed under it: the record it read
                                    # carried that image's own flag.
                                    gen.alive[] || Threads.atomic_add!(dead_generation, 1)
                                    lock(seen_lock) do
                                        push!(seen, (gen.generation, value))
                                    end
                                    Threads.atomic_add!(crate_calls, 1)
                                end
                            end
                            yield()
                        end
                    end

                    # An allocator: objects are created and dropped while the
                    # image under them is replaced. The object records the
                    # generation marker of the image that allocated it and the
                    # destructor it captured, and the two must agree — a
                    # constructor whose object took its destructor from a
                    # *later* snapshot would free through the wrong image.
                    allocator = Threads.@spawn begin
                        while !stop[]
                            # ONE snapshot for the whole construction — the
                            # allocating wrapper and the destructor the object
                            # will carry — exactly as `_call_rust_constructor`
                            # now does for a `#[julia]` constructor (#277).
                            target = RustCall.resolve_call_target(
                                lib_name, "Thing_new"; free_symbol = "Thing_free")
                            ptr = RustCall.call_rust_function(target.func_ptr, Ptr{Cvoid})
                            thing = StressThing(ptr, target.free_ptr, target.alive)
                            finalizer(RustCall.finalize_rust_object!, thing)
                            # The object carries the marker of the image that
                            # allocated it; the snapshot says which generation
                            # that was. A construction that straddled a swap
                            # would pair one generation with another's marker.
                            marker = unsafe_load(Ptr{Int32}(ptr))
                            lock(seen_lock) do
                                push!(ctor_seen, (target.generation, marker))
                            end
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
                    wait(caller); wait(panicker); wait(allocator); wait(crate_module)
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

                    # The crate-module path: it ran, it never called an image
                    # that had been closed under it, and each generation number
                    # is paired with exactly one returned value — a call that
                    # straddled a swap would pair one number with two.
                    # Every constructed object came from the generation its
                    # snapshot named: one snapshot generation, one marker.
                    @test length(ctor_seen) > 0
                    @test length(unique(first, collect(ctor_seen))) == length(ctor_seen)

                    @test crate_calls[] > 0
                    @test dead_generation[] == 0
                    @test length(unique(first, collect(seen))) == length(seen)
                    # ...and it really did see more than one generation.
                    @test length(unique(first, collect(seen))) > 1
                finally
                    lock(RustCall.REGISTRY_LOCK) do
                        delete!(RustCall.HANDLE_MIRRORS, lib_name)
                    end
                    try
                        RustCall.unload_library(lib_name)
                    catch
                    end
                end
            end
        end
    end
end
