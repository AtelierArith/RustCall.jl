"""
    SampleCratePyO3

A Julia package with the Rust crate `deps/sample_crate_pyo3` embedded in it: a
crate with **dual bindings**: `#[julia]` for Julia and PyO3's own attributes for Python,
on one definition of each item.

The two halves live in separate files:

- **Rust**: `deps/sample_crate_pyo3/src/lib.rs` — the implementation, with
  `#[julia]` next to `#[cfg_attr(feature = "python", pyo3::...)]`. No Julia
  file contains Rust source, and the Julia build never enables the `python`
  feature (the wrapper links no Python).
- **Julia**: this file and `src/generated/Bindings.jl`, which `deps/build.jl`
  writes with `RustCall.write_bindings_to_file` (run
  `Pkg.build("SampleCratePyO3")`).

Every exported name here is the Julia binding of the same-named Rust item; the
Python module exposes the same names (see `deps/sample_crate_pyo3/README.md`).
"""
module SampleCratePyO3

using RustCall

const _BINDINGS_FILE = joinpath(@__DIR__, "generated", "Bindings.jl")
if !isfile(_BINDINGS_FILE)
    # First use from a fresh checkout, before any `Pkg.build("SampleCratePyO3")`:
    # run the build step now so that `using SampleCratePyO3` and `Pkg.test()`
    # work without a manual step. `Pkg.build("SampleCratePyO3")` is still the
    # way to regenerate after editing the Rust crate.
    @info "SampleCratePyO3: no generated bindings yet; running deps/build.jl"
    include(joinpath(@__DIR__, "..", "deps", "build.jl"))
end
include(_BINDINGS_FILE)
# Explicit list: exactly the names this module re-exports.
using .Bindings: add, fibonacci, shout, shout_twice,
                 Point, distance_from_origin, translate, scaled

export add, fibonacci, shout, shout_twice
export Point, distance_from_origin, translate, scaled
export norm

"""
    norm(p::Point) -> Float64

The Euclidean norm of `p`, a Julia-side alias of the crate's
`Point::distance_from_origin`.
"""
norm(p::Point)::Float64 = distance_from_origin(p)

end # module SampleCratePyO3
