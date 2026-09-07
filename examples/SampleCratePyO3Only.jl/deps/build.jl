# Build step of SampleCratePyO3Only.jl: bind a PyO3-only crate for Julia and
# write the bindings that `src/SampleCratePyO3Only.jl` includes.
#
# `Pkg.build("SampleCratePyO3Only")` runs this file (RustCall's "Precompilation
# Support" workflow, docs/src/precompilation.md). The crate in
# deps/sample_crate_pyo3_only carries no RustCall attribute, so
# `write_bindings_to_file` takes the PyO3 wrapper path (#275 Phase 2,
# docs/src/pyo3.md):
#
#   1. the crate is scanned for the `pub` items PyO3 exposes, and a wrapper
#      crate that depends on it is generated under the crate's own `target/`;
#   2. `cargo build --release` of that wrapper. pyo3 is a mandatory dependency
#      of the crate, so the wrapper links libpython (link plan
#      `:link_libpython`): the build needs a Python interpreter whose library
#      directory RustCall can find — `PYO3_PYTHON` pins one;
#   3. the built library is copied to deps/lib/;
#   4. src/generated/Bindings.jl is written with a path relative to itself.
#
# Nothing in deps/sample_crate_pyo3_only is touched.

using RustCall

const CRATE_DIR = joinpath(@__DIR__, "sample_crate_pyo3_only")
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

@info "SampleCratePyO3Only: bindings written" BINDINGS_PATH
