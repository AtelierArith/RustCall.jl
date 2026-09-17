# Generation copies across pid namespaces (#321): the copy name carries a
# per-process instance token, and the owner holds `<copy>.lease` locked for
# its whole life, so a sweep in another process — even one whose process
# table cannot see the owner — never takes a live copy for abandoned.
using RustCall
using Test

const _GL_PROJECT = dirname(@__DIR__)

@testset "generation copy leases (#321)" begin
    host = RustCall._generation_copy_host()
    instance = RustCall._generation_copy_instance()

    @testset "the name" begin
        # Equal host, pid and generation, different instances: different paths.
        a = RustCall._generation_copy_name("libx", ".so", host, 4242, "0000aaaa", 7)
        b = RustCall._generation_copy_name("libx", ".so", host, 4242, "0000bbbb", 7)
        @test a != b
        @test a == "libx.rustcall.$(host).4242.0000aaaa.7.so"
        @test RustCall.generation_lease_path("/d/libx.rustcall.x.1.a.1.so") == "/d/libx.rustcall.x.1.a.1.so.lease"
        @test length(instance) == RustCall.GENERATION_COPY_INSTANCE_LEN
    end

    @testset "the lease is held for the life of the process" begin
        mktempdir() do dir
            built = joinpath(dir, "libheld.so")
            write(built, "not a library")
            copied = RustCall.loadable_library_copy(built)
            lease = RustCall.generation_lease_path(copied)
            @test isfile(lease)
            state = RustCall._lease_state(copied)
            if state === :none
                @test_skip "this file system offers no advisory locking"
            else
                # Held: a second description of the same lease cannot lock it,
                # in this process or in another one.
                @test state === :held
                probe = """
                using RustCall
                print(RustCall._lease_state($(repr(copied))))
                """
                out = read(`$(Base.julia_cmd()) --startup-file=no --project=$(_GL_PROJECT) -e $probe`, String)
                @test out == "held"
                # The lease stream is kept by RustCall, not by the caller.
                @test any(io -> io.name == "<file $(lease)>", RustCall._GENERATION_LEASES)
            end
        end
    end

    @testset "a sweep asks the lease, not the process table" begin
        mktempdir() do dir
            built = joinpath(dir, "libns.so")
            write(built, "not a library")
            # A pid that is gone from *this* process table: an exited child.
            gone = open(`$(Base.julia_cmd()) --startup-file=no -e 0`)
            dead_pid = getpid(gone)
            wait(gone)
            @test !RustCall._process_alive(dead_pid)
            # Another process plays "container A": it plants a copy tagged
            # with that dead pid — from its own namespace it would be live —
            # holds the copy's lease, and waits. From here the pid looks dead;
            # only the lease says otherwise.
            planted = joinpath(dir, "libns.rustcall.$(host).$(dead_pid).0badcafe.5.so")
            script = """
            using RustCall
            copy = $(repr(planted))
            RustCall._acquire_generation_lease(copy) === true || (print("nolock"); exit(0))
            write(copy, "planted")
            println("ready"); flush(stdout)
            readline(stdin)
            """
            holder = open(`$(Base.julia_cmd()) --startup-file=no --project=$(_GL_PROJECT) -e $script`, "r+")
            ready = readline(holder)
            if ready != "ready"
                close(holder); wait(holder)
                @test_skip "this file system offers no advisory locking"
            else
                try
                    @test isfile(planted)
                    @test RustCall._lease_state(planted) === :held
                    # The sweep keeps it although `_process_alive(dead_pid)` is false.
                    RustCall._sweep_stale_generation_copies(built)
                    @test isfile(planted)
                    @test isfile(RustCall.generation_lease_path(planted))
                    # Through the public entry point too.
                    copied = RustCall.loadable_library_copy(built)
                    @test isfile(copied) && isfile(planted)
                finally
                    # "Container A" exits: the kernel releases its lock.
                    close(holder)
                    wait(holder)
                end
                @test RustCall._lease_state(planted) === :free
                RustCall._sweep_stale_generation_copies(built)
                @test !isfile(planted)
                @test !isfile(RustCall.generation_lease_path(planted))
            end
            # A copy without a lease is still judged by the process table.
            unleased = joinpath(dir, "libns.rustcall.$(host).$(dead_pid).0badcafe.6.so")
            write(unleased, "no lease")
            RustCall._sweep_stale_generation_copies(built)
            @test !isfile(unleased)
            # ...and one with this process's pid but another instance and no
            # lease stays: from another namespace it could be live.
            twin = joinpath(dir, "libns.rustcall.$(host).$(getpid()).0badcafe.6.so")
            write(twin, "twin")
            RustCall._sweep_stale_generation_copies(built)
            @test isfile(twin)
        end
    end

    @testset "a held lease of the chosen name moves the counter on" begin
        mktempdir() do dir
            built = joinpath(dir, "libbusy.so")
            write(built, "not a library")
            # Occupy the very next name this process would pick, from another
            # process, then copy: the copy lands on the following generation.
            next = RustCall.process_generation_path(built, RustCall.RELOAD_GENERATION[] + 1)
            script = """
            using RustCall
            RustCall._acquire_generation_lease($(repr(next))) === true || (print("nolock"); exit(0))
            println("ready"); flush(stdout)
            readline(stdin)
            """
            holder = open(`$(Base.julia_cmd()) --startup-file=no --project=$(_GL_PROJECT) -e $script`, "r+")
            ready = readline(holder)
            if ready != "ready"
                close(holder); wait(holder)
                @test_skip "this file system offers no advisory locking"
            else
                try
                    copied = RustCall.loadable_library_copy(built)
                    @test copied != next
                    @test isfile(copied)
                    @test !isfile(next)
                finally
                    close(holder); wait(holder)
                end
            end
        end
    end

    @testset "the source keeps the order: lease before copy, sweep before both" begin
        src = read(joinpath(_GL_PROJECT, "src", "loadpolicy.jl"), String)
        body = src[findfirst("function loadable_library_copy", src)[1]:end]
        @test findfirst("_sweep_stale_generation_copies(built)", body)[1] <
              findfirst("_acquire_generation_lease(copy_path)", body)[1] <
              findfirst("cp(built, copy_path", body)[1]
    end
end
