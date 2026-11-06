using Test, TOML

# This supervisor never imports RustCall or operates on a caller cache. Only
# children with simulated, temporary caller depots invoke the destructive file.
const HARNESS580_PACKAGE_UUID = "7ac5b1a4-9e37-4f0e-9aa3-3305a66bfb1c"

function _harness580_sentinels(caller_depot, override)
    scratch = joinpath(caller_depot, "scratchspaces", HARNESS580_PACKAGE_UUID, "cache-v2")
    legacy =
        joinpath(caller_depot, "compiled", "v$(VERSION.major).$(VERSION.minor)", "RustCall")
    paths = String[]
    for root in (scratch, override)
        append!(
            paths,
            [
                joinpath(root, "deadbeef"^8 * extension) for
                extension in (".so", ".dll", ".dylib")
            ],
        )
        push!(paths, joinpath(root, "cargo", "caller-owned", "keep.bin"))
        push!(paths, joinpath(root, "metadata", "caller-owned.json"))
        push!(
            paths,
            joinpath(root, "cargo", "targets", "probe", "target", "debug", "keep.bin"),
        )
        push!(paths, joinpath(root, "lockfiles", "keep.lock"))
    end
    push!(paths, joinpath(legacy, "v2", "keep.bin"))
    push!(paths, joinpath(legacy, "cargo", "keep.bin"))
    push!(paths, joinpath(legacy, "metadata", "keep.bin"))
    push!(paths, joinpath(legacy, "deadbeef"^8 * ".ll"))
    payloads = Dict{String,Vector{UInt8}}()
    for (index, path) in enumerate(paths)
        mkpath(dirname(path))
        payload =
            vcat(collect(codeunits("caller-sentinel-$index")), UInt8[0x00, 0xff, 0x7f])
        write(path, payload)
        payloads[path] = payload
    end
    return payloads
end

function _harness580_run_entry(entry, checkout, project, original_depots, directory)
    caller_depot = joinpath(directory, "caller-depot")
    override = joinpath(directory, "caller-override")
    mkpath(caller_depot)
    mkpath(override)
    sentinels = _harness580_sentinels(caller_depot, override)
    report_path = joinpath(directory, "depot-report.toml")
    log_path = joinpath(directory, "entry.log")
    separator = Sys.iswindows() ? ';' : ':'
    simulated_depots = [caller_depot; original_depots]
    environment = (
        "JULIA_DEPOT_PATH" => join(simulated_depots, separator),
        "RUSTCALL_CACHE_DIR" => override,
        "RUSTCALL_TEST_DEPOT_REPORT" => report_path,
        # A shard-2 parent must still execute this exact cache-file regression.
        "RUSTCALL_CI_SHARD" => nothing,
    )
    preflight_code = "using RustCall; realpath(pkgdir(RustCall)) == realpath(ARGS[1]) || error(\"wrong RustCall checkout selected before cache entry\")"
    preflight = `$(Base.julia_cmd()) --startup-file=no --project=$project -e $preflight_code $checkout`
    command =
        entry === :runner ?
        `$(Base.julia_cmd()) --startup-file=no --project=$project $(joinpath(checkout, "test", "runtests.jl")) --jobs=1 test_cache` :
        `$(Base.julia_cmd()) --startup-file=no --project=$project $(joinpath(checkout, "test", "test_cache.jl"))`
    passed = open(log_path, "w") do log
        # This read-only package check precedes either destructive entry point.
        preflight_ok = success(
            pipeline(addenv(preflight, environment...); stdout = log, stderr = log),
        )
        @test preflight_ok
        preflight_ok || return false
        success(pipeline(addenv(command, environment...); stdout = log, stderr = log))
    end
    if !passed
        println(stderr, "cache isolation entry $entry failed:\n", read(log_path, String))
    end
    @test passed
    @test isfile(report_path)
    # Keep failure diagnostics readable, and never substitute a caller path
    # for a missing report's private depot.
    passed && isfile(report_path) || return nothing
    report = TOML.parsefile(report_path)
    first_depot = normpath(report["first_depot"])
    depots = normpath.(String.(report["depots"]))
    @test first_depot != normpath(caller_depot)
    @test first(depots) == first_depot
    caller_position = findfirst(==(normpath(caller_depot)), depots)
    @test caller_position !== nothing
    if caller_position !== nothing
        @test caller_position > 1
        @test depots[caller_position:end] == normpath.(simulated_depots)
    end
    @test report["depot_env"] == join(report["depots"], separator)
    @test normpath(report["child_first_depot"]) == first_depot
    @test !report["override_present"]
    @test realpath(report["package_dir"]) == realpath(checkout)
    @test realpath(report["child_package_dir"]) == realpath(checkout)
    relative_cache = relpath(normpath(report["cache_dir"]), first_depot)
    @test !isabspath(relative_cache)
    @test first(splitpath(relative_cache)) == "scratchspaces"
    @test normpath(report["cache_dir"]) != normpath(override)
    for (path, payload) in sentinels
        @test isfile(path)
        @test isfile(path) && read(path) == payload
    end
    # The support module defers deletion of mapped Windows DLLs until its
    # process exits. Now that the child has exited, remove only its named
    # private prefixes; the simulated caller and all original fallbacks are
    # explicitly excluded even if a malformed report repeats one up front.
    if Sys.iswindows() && caller_position !== nothing
        for private in depots[1:(caller_position-1)]
            private in normpath.(simulated_depots) && continue
            startswith(basename(private), "rustcall-tests-") || continue
            relative = relpath(private, tempdir())
            (isabspath(relative) || first(splitpath(relative)) == "..") && continue
            try
                rm(private; recursive = true, force = true)
            catch
                # A late OS mapping can still defer cleanup; never redirect
                # cleanup to a caller or fallback depot to compensate.
            end
        end
    elseif !Sys.iswindows()
        @test !isdir(first_depot)
    end
    return first_depot
end

@testset "actual cache test entries preserve simulated caller caches (#580)" begin
    checkout = dirname(@__DIR__)
    active = Base.active_project()
    @test active !== nothing
    active === nothing &&
        error("cache harness regression requires an active package test project")
    project = dirname(active)
    before_depots = copy(DEPOT_PATH)
    before_depot_env = get(ENV, "JULIA_DEPOT_PATH", nothing)
    before_override = get(ENV, "RUSTCALL_CACHE_DIR", nothing)
    private_roots = String[]
    mktempdir() do directory
        for entry in (:runner, :direct)
            @testset "$entry: actual test_cache entry is isolated" begin
                case_dir = joinpath(directory, String(entry))
                mkpath(case_dir)
                root =
                    _harness580_run_entry(entry, checkout, project, before_depots, case_dir)
                root === nothing || push!(private_roots, root)
            end
        end
    end
    @test length(private_roots) == 2
    @test length(unique(private_roots)) == 2
    @test DEPOT_PATH == before_depots
    @test get(ENV, "JULIA_DEPOT_PATH", nothing) == before_depot_env
    @test get(ENV, "RUSTCALL_CACHE_DIR", nothing) == before_override
end
