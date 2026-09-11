# Resolve the benchmark environment against the repository checkout.
#
# `BenchmarkTools` is a benchmark-only dependency (issue #260), so the scripts
# run under `--project=benchmark` rather than under the package project. That
# environment declares `RustCall` as a dependency but cannot know where the
# checkout is, so this file develops it from the parent directory the first
# time and instantiates.
#
# Every benchmark script includes this file before `using RustCall`.

import Pkg

const _REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const _BENCH_PROJECT = normpath(joinpath(@__DIR__, "Project.toml"))

let active = Base.active_project()
    if active !== nothing && normpath(active) == _BENCH_PROJECT
        if !isfile(joinpath(@__DIR__, "Manifest.toml"))
            Pkg.develop(Pkg.PackageSpec(path = _REPO_ROOT))
        end
        Pkg.instantiate()
    elseif Base.identify_package("BenchmarkTools") === nothing
        # Some other environment is active — most likely the package project,
        # which is where these scripts used to run. `BenchmarkTools` is not a
        # dependency of RustCall any more (#260), so name the command that
        # works before the script's own `using BenchmarkTools` fails with
        # "package not found". A script that needs no BenchmarkTools
        # (`benchmarks_cfg_probe.jl`) keeps running, which is why this warns
        # rather than throws.
        @warn """
              BenchmarkTools is not available in the active environment. The benchmark
              scripts have their own since #260; run them with

                  julia --project=benchmark benchmark/<script>.jl
              """ active_project = active
    end
end
