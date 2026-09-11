# Resolve the benchmark environment against the repository checkout.
#
# `BenchmarkTools` is a benchmark-only dependency (issue #260), so the scripts
# run under `--project=benchmark` rather than the package project. That
# environment declares `RustCall` as a dependency but cannot know where the
# checkout is, so this file develops it from the parent directory the first
# time and instantiates.
#
# Every benchmark script includes this file before `using RustCall`.

import Pkg

const _REPO_ROOT = normpath(joinpath(@__DIR__, ".."))

if Base.active_project() == joinpath(@__DIR__, "Project.toml")
    _manifest = joinpath(@__DIR__, "Manifest.toml")
    if !isfile(_manifest)
        Pkg.develop(Pkg.PackageSpec(path = _REPO_ROOT))
    end
    Pkg.instantiate()
end
