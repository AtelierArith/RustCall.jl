# Component tests loaded by test_pyo3_link_plan.jl.

# Two PyO3 wrapper builds whose full keys share the short id name one Cargo
# package and write one `<profile>/librustcall_wrapper_<short>.*`. Cargo's lock
# ends when Cargo exits, before RustCall copies the file out, so without a lock
# of its own one build's output could be cached under the other's key (#495
# review). The name comes from `with_short_name`, which holds the name's lock
# over the build, the check and the copy (#504); here a stub build writes its
# key into the shared output, yields, and the copy reads it back — each copy
# must be its own key's.
@testset "concurrent wrapper builds of one short id copy their own output (#495 review)" begin
    k1 = "0123456789abcdef" * "1"^48
    k2 = "0123456789abcdef" * "2"^48
    @test RustCall.artifact_short_id(k1) == RustCall.artifact_short_id(k2)
    # The real build takes its package name, and the lock of that name, from
    # `with_short_name`, and builds and copies out inside it.
    src = read(joinpath(pkgdir(RustCall), "src", "pyo3", "pyo3.jl"), String)
    held = findfirst("with_short_name(target, key; prefix = \"rustcall_wrapper_\") do wrapper_name", src)
    @test held !== nothing
    build = findnext("built = build_cargo_project(project;", src, last(held))
    copy = findnext("save_cargo_cached_library(key, built)", src, last(held))
    release = findnext("cleanup_cargo_project(project)", src, last(held))
    @test build !== nothing && copy !== nothing && release !== nothing
    @test first(build) < first(copy) < first(release)
    @test RustCall.short_name(k1; prefix = "rustcall_wrapper_") ==
          RustCall.short_name(k2; prefix = "rustcall_wrapper_") ==
          "rustcall_wrapper_0123456789abcdef"

    mktempdir() do dir
        out = joinpath(dir, "librustcall_wrapper_0123456789abcdef.so")
        lock_path = joinpath(dir, "rustcall_wrapper_0123456789abcdef.lock")
        copies = Dict{String, String}()
        names = Dict{String, String}()
        build_and_copy(key) = RustCall.with_short_name(dir, key; prefix = "rustcall_wrapper_",
                                                       poll = 0.01) do name
            names[key] = name
            write(out, key)                   # Cargo writes the shared output
            sleep(0.2)                        # ...and exits; the other build may start
            copies[key] = read(out, String)   # the copy-out
        end
        tasks = [Threads.@spawn(build_and_copy(k)) for k in (k1, k2, k1, k2)]
        foreach(wait, tasks)
        @test copies[k1] == k1
        @test copies[k2] == k2
        # One name, one lock file, for both keys.
        @test joinpath(dir, names[k1] * ".lock") == joinpath(dir, names[k2] * ".lock") == lock_path

        # Across processes: a child holds the lock over its build and copy;
        # the parent's build waits for it rather than interleaving.
        ready = joinpath(dir, "ready")
        child_copy = joinpath(dir, "child_copy")
        script = """
            using RustCall
            RustCall.with_short_name_lock($(repr(lock_path))) do
                write($(repr(out)), $(repr(k1)))
                touch($(repr(ready)))
                sleep(3)
                write($(repr(child_copy)), read($(repr(out)), String))
            end
            """
        child = run(`$(Base.julia_cmd()) --startup-file=no --project=$(pkgdir(RustCall)) -e $script`;
                    wait = false)
        deadline = time() + 120
        while !isfile(ready) && time() < deadline && process_running(child)
            sleep(0.05)
        end
        @test isfile(ready)
        parent_copy = RustCall.with_short_name_lock(lock_path; poll = 0.01) do
            write(out, k2)
            read(out, String)
        end
        wait(child)
        @test success(child)
        @test read(child_copy, String) == k1
        @test parent_copy == k2
    end
end
