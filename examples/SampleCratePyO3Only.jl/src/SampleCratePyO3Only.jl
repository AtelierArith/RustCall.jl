"""
    SampleCratePyO3Only

A Julia package with the Rust crate `deps/sample_crate_pyo3_only` embedded in
it: a crate **written for PyO3 only**. It carries no RustCall attribute — no
`#[julia]` anywhere — and does not depend on `rustcall_julia_macros`; it is a PyO3
extension crate as its author wrote it for Python. RustCall binds it anyway
(#275 Phase 2): `deps/build.jl` runs `RustCall.write_bindings_to_file`, which
scans the `pub` items PyO3 exposes, generates a **wrapper crate** that depends
on the crate, builds it, and writes the bindings of that wrapper.

The two halves live in separate files:

- **Rust**: `deps/sample_crate_pyo3_only/src/lib.rs` — `#[pyfunction]`,
  `#[pyclass]`, `#[pymethods]` and nothing else. No Julia file contains Rust
  source, and no Rust file mentions Julia.
- **Julia**: this file and `src/generated/Bindings.jl`, the generated wrapper's
  binding, written by `deps/build.jl` (run `Pkg.build("SampleCratePyO3Only")`).

The wrapper links libpython (pyo3 is a mandatory dependency of the crate, link
plan `:link_libpython`), so building this package needs a Python interpreter;
see `README.md`.

Every exported name here is the Julia binding of the same-named PyO3 item,
except `parse_int` and `distance`, which are Julia-side conveniences.
"""
module SampleCratePyO3Only

using RustCall
using RustCall: RustResult, is_ok, unwrap

const _BINDINGS_FILE = joinpath(@__DIR__, "generated", "Bindings.jl")
if !isfile(_BINDINGS_FILE)
    # First use from a fresh checkout, before any
    # `Pkg.build("SampleCratePyO3Only")`: run the build step now so that
    # `using SampleCratePyO3Only` and `Pkg.test()` work without a manual step.
    # `Pkg.build("SampleCratePyO3Only")` is still the way to regenerate after
    # editing the Rust crate.
    @info "SampleCratePyO3Only: no generated bindings yet; running deps/build.jl"
    include(joinpath(@__DIR__, "..", "deps", "build.jl"))
end
include(_BINDINGS_FILE)
# Explicit list: exactly the names this module re-exports unchanged. The
# crate's `parse` is *not* among them — re-exporting it would shadow
# `Base.parse` for every user of this package — so it is reached as
# `Bindings.parse` by the `parse_int` wrapper below.
using .Bindings: add, shout,
                 Point, origin, norm, translate, label, scaled

# Names the PyO3 crate exposes, re-exported unchanged: `#[pyfunction]`s ...
export add, shout
# ... and the `#[pyclass]` with its `#[new]`, `#[staticmethod]` and methods.
export Point, origin, norm, translate, label, scaled

# Julia-side conveniences defined below.
export parse_int, distance

"""
    parse_int(s::AbstractString) -> Int32

Parse an integer in Rust through the crate's `parse`, a `#[pyfunction]`
returning `PyResult<i32>`. The wrapper cannot render a `PyErr` without a Python
interpreter, so the generated binding returns `RustResult{Int32, String}` whose
`Err` payload is always the fixed sentence `RustCall.PYO3_OPAQUE_ERROR`; this
wrapper turns that into an `ArgumentError` naming the input instead.
"""
function parse_int(s::AbstractString)::Int32
    r = Bindings.parse(String(s))
    is_ok(r) || throw(ArgumentError("parse_int: not an integer: $(repr(s))"))
    return unwrap(r)
end

"""
    distance(p::Point, q::Point) -> Float64

Euclidean distance between two points, computed from the fields
`#[pyclass(get_all, set_all)]` exposes (`p.x`, `p.y` go through the generated
getters) and the crate's `Point::norm`.
"""
function distance(p::Point, q::Point)::Float64
    d = Point(p.x - q.x, p.y - q.y)
    return norm(d)
end

end # module SampleCratePyO3Only
