# Phase 1.5 of #275: test the selected PyO3 link mode and its probe inputs.
using RustCall
using Test
using TOML

function _write_crate(dir::AbstractString, cargo_toml::AbstractString)
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "Cargo.toml"), cargo_toml)
    write(joinpath(dir, "src", "lib.rs"), "")
    return dir
end

_manifest(text::AbstractString) = TOML.parse(text)

# A file system without advisory locks cannot exercise the lease behavior.
function _advisory_lock_state(io)
    return try
        RustCall._try_lock_lease(io)
    catch
        nothing
    end
end

include("pyo3_link_plan_fallback.jl")
include("pyo3_link_plan_resolved.jl")
include("pyo3_link_plan_linking.jl")
include("pyo3_link_plan_wrapper_probe.jl")
include("pyo3_link_plan_probe_leases.jl")
include("pyo3_link_plan_scan_report.jl")
include("pyo3_link_plan_concurrency.jl")
