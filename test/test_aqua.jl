# Dependency and package hygiene, enforced mechanically (issue #260).
#
# The motivating defect: `BenchmarkTools` sat in `[deps]` while only
# `benchmark/*.jl` used it, so every user of RustCall pulled it (and its
# transitive dependencies) into their runtime graph. A prose note would not
# have stopped it coming back; `Aqua.test_all` does, and covers the rest of
# the same class (missing `[compat]` bounds, stale `[extras]`, type piracy,
# unbound type parameters, undefined exports).
#
# `persistent_tasks` is disabled deliberately. It loads RustCall in a child
# process and fails the package if the process is still busy after a fixed
# wall-clock timeout. RustCall's `__init__` probes the Rust toolchain
# (`check_rustc_available`), which on a machine without `rustc` on PATH asks
# RustToolChain.jl for its artifact and may download one — a first-run cost
# that has nothing to do with a leaked task and everything to do with how long
# the check is willing to wait. Nothing in `__init__` starts a task; the
# hot-reload watchers are started on demand and stopped by
# `test/test_hot_reload.jl`.

using Aqua
using Pkg
using RustCall
using Test

@testset "Aqua quality assurance" begin
    Aqua.test_all(RustCall; persistent_tasks = false)
end

# Pkg warns, once per load, when a `[compat]` entry for a non-upgradable
# stdlib does not admit the version shipped with the running Julia
# (`check_stdlib_compat` in Pkg's Operations.jl). The motivating defect:
# `SHA = "0.7"` while Julia 1.13 ships SHA 1.0.0, so every `Pkg.build` /
# `Pkg.resolve` of a user environment printed
# "Ignoring incompatible compat entry `SHA = "0.7"`". The bound must track the
# running stdlib, which is not a fixed number across supported Julia versions;
# this test derives it from the loaded module instead.
@testset "stdlib [compat] admits the running version" begin
    project = RustCall.TOML.parsefile(joinpath(pkgdir(RustCall), "Project.toml"))
    for name in keys(project["deps"])
        compat = get(project["compat"], name, nothing)
        compat === nothing && continue
        isdefined(RustCall, Symbol(name)) || continue
        mod = getfield(RustCall, Symbol(name))
        mod isa Module || continue
        version = pkgversion(mod)
        version === nothing && continue
        @test version in Pkg.Types.semver_spec(compat)
    end
end

@testset "BenchmarkTools is not a runtime dependency (#260)" begin
    project = RustCall.TOML.parsefile(joinpath(pkgdir(RustCall), "Project.toml"))
    # It stays available to `benchmark/benchmarks.jl` through `[extras]` and
    # the `benchmark` target, but must never reach a user of the package.
    @test !haskey(project["deps"], "BenchmarkTools")
    @test haskey(project["extras"], "BenchmarkTools")
    @test "BenchmarkTools" in project["targets"]["benchmark"]
end
