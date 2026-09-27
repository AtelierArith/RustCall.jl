# Tests for the crate bindings feature (Maturin-like functionality)

using Test
using RustCall
using RustToolChain: cargo
using Libdl

const SAMPLE_CRATE_PATH = joinpath(@__DIR__, "fixtures", "sample_crate")
const SAMPLE_CRATE_PYO3_PATH = joinpath(@__DIR__, "fixtures", "sample_crate_pyo3")
const _SRC_DIR_CB = joinpath(dirname(dirname(pathof(RustCall))), "src", "ffi")

include("crate_bindings_core.jl")
include("crate_bindings_integration.jl")
include("crate_bindings_runtime.jl")
include("crate_bindings_precompile.jl")
include("crate_bindings_strings.jl")
include("crate_bindings_proxy_format.jl")
