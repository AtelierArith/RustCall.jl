# ---
# jupyter:
#   jupytext:
#     text_representation:
#       extension: .jl
#       format_name: percent
#       format_version: '1.3'
#       jupytext_version: 1.18.1
#   kernelspec:
#     display_name: Julia 1.12
#     language: julia
#     name: julia-1.12
# ---

# %%
using Test

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."))

using RustCall

sample_crate_path = joinpath(pkgdir(RustCall), "examples", "sample_crate")
@rust_crate sample_crate_path

@testset "distance_from_origin" begin
    p = SampleCrate.Point(3.0, 4.0)
    @test SampleCrate.distance_from_origin(p) == 5.0
    # Access fields using property access syntax
    @test p.x == 3.0
    @test p.y == 4.0
end

