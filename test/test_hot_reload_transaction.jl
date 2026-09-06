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
        @test RustCall._generation_path(joinpath("tmp", "libfoo.dylib"), 1) ==
              joinpath("tmp", "libfoo.1.dylib")
        @test RustCall._generation_path(joinpath("tmp", "libfoo.so"), 12) ==
              joinpath("tmp", "libfoo.12.so")
        # Next to the original, not in a temp directory: on Windows a DLL
        # resolves its dependencies relative to its own location.
        @test dirname(RustCall._generation_path(joinpath("a", "b", "libfoo.so"), 2)) ==
              joinpath("a", "b")
        @test basename(RustCall._generation_path(joinpath("a", "b", "foo.dll"), 7)) ==
              "foo.7.dll"

        @test occursin("_generation_path(built, state.generation)", _HRT_SRC)
        @test occursin("cp(built, new_lib_path; force = true)", _HRT_SRC)
        # The previous handle is closed *after* the swap, not before the build.
        @test occursin("on_replace = :dlclose", _HRT_SRC)
        @test findfirst("rebuild_crate(state.crate_path)", _HRT_SRC) <
              findfirst("_generation_path(built", _HRT_SRC) <
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
                    @test good_generation == 1
                    @test isfile(state.lib_path)
                    @test occursin(".1.", basename(state.lib_path))

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

                    # An unload empties it, so a module reading it reports
                    # "not loaded" rather than calling into a closed image.
                    RustCall.unload_library(lib_name)
                    @test handle_ref[] == C_NULL
                    @test !alive_ref[][]
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
end
