# Build step of SampleCratePyO3.jl: compile the Rust crate for Julia and write
# the bindings that `src/SampleCratePyO3.jl` includes.
#
# `Pkg.build("SampleCratePyO3")` runs this file (RustCall's "Precompilation
# Support" workflow, docs/src/precompilation.md):
#
#   1. `cargo build --release` of deps/sample_crate_pyo3, the crate embedded
#      in this package, *without* the `python` feature — the Julia build
#      never links Python;
#   2. the built library is copied to deps/lib/;
#   3. src/generated/Bindings.jl is written with a path relative to itself.
#
# The Python half of the same crate is built separately with maturin (see
# deps/sample_crate_pyo3/README.md); this package never touches it.

using RustCall

const CRATE_DIR = joinpath(@__DIR__, "sample_crate_pyo3")
const BINDINGS_PATH = joinpath(@__DIR__, "..", "src", "generated", "Bindings.jl")

isdir(CRATE_DIR) || error("Rust crate not found at $(CRATE_DIR)")

mkpath(dirname(BINDINGS_PATH))
RustCall.write_bindings_to_file(
    CRATE_DIR,
    BINDINGS_PATH;
    output_module_name = "Bindings",
    build_release = true,
    relative_lib_path = joinpath("..", "..", "deps", "lib"),
)

@info "SampleCratePyO3: bindings written" BINDINGS_PATH
