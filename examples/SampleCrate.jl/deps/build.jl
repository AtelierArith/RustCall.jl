# Build step of SampleCrate.jl: compile the Rust crate and write the Julia
# bindings that `src/SampleCrate.jl` includes.
#
# `Pkg.build("SampleCrate")` runs this file. It is the "Precompilation Support"
# workflow from RustCall's documentation (docs/src/precompilation.md):
#
#   1. `cargo build --release` of deps/sample_crate, the crate embedded in
#      this package (RustCall runs it);
#   2. the built library is copied to deps/lib/, next to this file;
#   3. src/generated/Bindings.jl is written with a path *relative* to itself,
#      so the package is self-contained once built and precompiles normally.
#
# Both outputs are generated and ignored by git (see ../.gitignore).

using RustCall

const CRATE_DIR = joinpath(@__DIR__, "sample_crate")
const BINDINGS_PATH = joinpath(@__DIR__, "..", "src", "generated", "Bindings.jl")

isdir(CRATE_DIR) || error("Rust crate not found at $(CRATE_DIR)")

mkpath(dirname(BINDINGS_PATH))
RustCall.write_bindings_to_file(
    CRATE_DIR,
    BINDINGS_PATH;
    output_module_name = "Bindings",
    build_release = true,
    # relative to src/generated/Bindings.jl
    relative_lib_path = joinpath("..", "..", "deps", "lib"),
)

@info "SampleCrate: bindings written" BINDINGS_PATH
