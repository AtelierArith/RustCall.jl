# Component tests loaded by test_pyo3_link_plan.jl.

@testset "PyO3 link plan: probe leases" begin
    @testset "a project is claimed before it is visible (#437)" begin
        # The whole point of #437: the lease is locked under a staging name and
        # renamed into place before the directory exists, so a sweep never has
        # to guess whether a visible project is still being created. No grace
        # window is consulted and no owner can be building against a tree a
        # sweep took for abandoned.
        mktempdir() do parent
            dir = RustCall._new_shaped_project_dir(parent)
            lease = RustCall._publish_shaped_project_lease(parent, dir)
            if lease === nothing
                @test_skip "no advisory locking here (Windows, or a lockless volume)"
            else
                @test !isdir(dir)                       # claimed, not yet visible
                @test isfile(RustCall.generation_lease_path(dir))
                @test RustCall._lease_state(dir) === :held
                @test RustCall._sweep_abandoned_projects(parent) == 0
                mkpath(dir)
                @test isdir(dir)
                @test RustCall._sweep_abandoned_projects(parent) == 0
                RustCall._remove_shaped_project(dir, lease)
                @test !isdir(dir)
                @test !isfile(RustCall.generation_lease_path(dir))
            end
        end
    end

    @testset "an orphan lease is swept once its owner is gone (#437)" begin
        # A claim whose owner died between the lock and `mkdir` leaves a lease
        # with no project. A held one must stay; a free one must not accumulate.
        mktempdir() do parent
            dir = RustCall._new_shaped_project_dir(parent)
            lease = RustCall._publish_shaped_project_lease(parent, dir)
            if lease === nothing
                @test_skip "no advisory locking here"
            else
                @test RustCall._sweep_abandoned_projects(parent) == 0
                @test isfile(RustCall.generation_lease_path(dir))
                close(lease)                            # the owner dies here
                @test RustCall._lease_state(dir) === :free
                @test RustCall._sweep_abandoned_projects(parent) == 1
                @test !isfile(RustCall.generation_lease_path(dir))
            end
        end
    end

    @testset "a failed claim initialization leaves nothing behind (#437 review)" begin
        # `_wrapper_shaped_project` publishes the claim before it initializes the
        # tree. If initialization throws, `_with_shaped_project` never receives
        # the tuple and so never cleans up; the failure path itself must. An
        # unreadable lockfile is the deterministic way to throw there.
        if Sys.iswindows()
            @test_skip "chmod-based failure is POSIX-only"
        else
            mktempdir() do root
                mkpath(joinpath(root, "src"))
                write(joinpath(root, "Cargo.toml"), """
                [package]
                name = "init_fail"
                version = "0.1.0"
                edition = "2021"
                """)
                write(joinpath(root, "src", "lib.rs"), "")
                lock = joinpath(root, "Cargo.lock")
                write(lock, "# unreadable\n")
                chmod(lock, 0o000)
                try
                    readable = try
                        open(io -> read(io), lock)
                        true
                    catch
                        false
                    end
                    if readable
                        @test_skip "this user ignores file permissions"
                    else
                        parent = joinpath(RustCall.crate_target_directory(root, :pyo3_wrapper),
                                          "rustcall-pyo3-test")
                        @test_throws Exception RustCall._wrapper_shaped_project(
                            root, "rustcall-pyo3-test")
                        entries = isdir(parent) ? readdir(parent) : String[]
                        @test isempty(filter(startswith("project_"), entries))
                        @test isempty(filter(endswith(".lease"), entries))
                    end
                finally
                    chmod(lock, 0o644)
                end
            end
        end
    end

    @testset "a paused owner keeps its project across pid namespaces (#437)" begin
        # Synchronize the pause at the exact window #437 removed: the claim is
        # held, the directory does not exist yet, and the owner is stopped. A
        # sweep in another process must leave the claim alone; when the owner
        # dies without a `finally`, the same sweep removes it with no wait.
        mktempdir() do parent
            script = """
            using RustCall
            parent = $(repr(parent))
            dir = RustCall._new_shaped_project_dir(parent)
            lease = RustCall._publish_shaped_project_lease(parent, dir)
            if lease === nothing
                print("nolock"); flush(stdout); exit(0)
            end
            println(dir); flush(stdout)
            readline(stdin)          # paused before the directory is made
            mkpath(dir)
            println("made"); flush(stdout)
            readline(stdin)          # paused while the claim is held
            """
            holder = open(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) -e $script`, "r+")
            line = readline(holder)
            if line == "nolock" || isempty(line)
                close(holder); wait(holder)
                @test_skip "no advisory locking here"
            else
                dir = line
                try
                    @test !isdir(dir)
                    @test RustCall._sweep_abandoned_projects(parent) == 0
                    @test isfile(RustCall.generation_lease_path(dir))
                    println(holder, "go"); flush(holder)
                    @test readline(holder) == "made"
                    @test isdir(dir)
                    @test RustCall._sweep_abandoned_projects(parent) == 0
                finally
                    close(holder)        # the owner dies, running no `finally`
                    wait(holder)
                end
                @test RustCall._lease_state(dir) === :free
                @test RustCall._sweep_abandoned_projects(parent) == 1
                @test !isdir(dir)
                @test !isfile(RustCall.generation_lease_path(dir))
            end
        end
    end

    @testset "an abandoned probe project is swept, a live one is kept (#425)" begin
        # The `finally` that removes a probe project does not run when the
        # process is interrupted, and a probe of a large crate is hundreds of
        # MB. The next probe names its project after its owner and sweeps the
        # ones whose owner is gone — never a live process's.
        mktempdir() do parent
            probe = open(joinpath(parent, "probe.lease"), "w")
            locking = _advisory_lock_state(probe) === true
            close(probe)
            rm(joinpath(parent, "probe.lease"); force = true)
            # No lease, another pid: swept by the pid fallback at once.
            dead = joinpath(parent, "project_2000000000_abandoned")
            mkpath(dead)
            # No lease, this process's pid: kept, with no waiting.
            live = joinpath(parent, "project_$(getpid())_live")
            mkpath(live)
            # A lease nobody holds (the owner died before its `finally`): free,
            # so swept whatever the name's pid says, with no grace window.
            freed = joinpath(parent, "project_$(getpid())_freed")
            mkpath(freed)
            write(RustCall.generation_lease_path(freed), "")
            # A name with no owner encoded and no lease is never guessed at.
            legacy = joinpath(parent, "project_legacy")
            mkpath(legacy)
            @test RustCall._sweep_abandoned_projects(parent) == (locking ? 2 : 1)
            @test !isdir(dead)
            @test isdir(live)
            @test isdir(legacy)
            @test !isfile(RustCall.generation_lease_path(dead))
            if locking
                @test !isdir(freed)
                @test !isfile(RustCall.generation_lease_path(freed))
            else
                @test isdir(freed)      # a free lease is unreadable: pid, alive
            end
        end
    end

    @testset "a held lease protects a live probe across pid namespaces (#425 review)" begin
        # Another "container" holds the lease on a project tagged with a pid
        # that is dead here. The pid fallback alone would delete it; the held
        # lease says hold. Needs advisory locking, like the generation leases.
        mktempdir() do parent
            gone = open(`$(Base.julia_cmd()) --startup-file=no -e 0`)
            dead_pid = getpid(gone)
            wait(gone)
            @test !RustCall._process_alive(dead_pid)
            guarded = joinpath(parent, "project_$(dead_pid)_guarded")
            mkpath(guarded)
            script = """
            using RustCall
            io = open($(repr(RustCall.generation_lease_path(guarded))), "w")
            ok = try RustCall._try_lock_lease(io) === true catch; false end
            ok || (print("nolock"); exit(0))
            println("ready"); flush(stdout)
            readline(stdin)
            """
            holder = open(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) -e $script`, "r+")
            ready = readline(holder)
            if ready != "ready"
                close(holder); wait(holder)
                @test_skip "this file system offers no advisory locking"
            else
                try
                    @test RustCall._lease_state(guarded) === :held
                    # The name's pid reads as dead here; the lease keeps it.
                    @test RustCall._sweep_abandoned_projects(parent) == 0
                    @test isdir(guarded)
                finally
                    close(holder); wait(holder)
                end
                # The owner is gone: the free lease lets the sweep take it at
                # once — there is no create-to-lock window to wait out.
                @test RustCall._lease_state(guarded) === :free
                @test RustCall._sweep_abandoned_projects(parent) == 1
                @test !isdir(guarded)
            end
        end
    end


end
