using RustCall, Test
include(joinpath(@__DIR__, "pyo3_wrapper_helpers.jl"))

@testset "wrapper resolver separates build features in standalone/workspace targets (#303)" begin
    for workspace in (false, true)
        @testset "workspace=$workspace" begin
            mktempdir() do root
                target = workspace ? joinpath(root, "member") : root
                mkpath(joinpath(target, "src"))
                if workspace
                    write(joinpath(root, "Cargo.toml"), """
                        [workspace]
                        resolver = "1"
                        members = ["member", "sibling"]
                        [workspace.dependencies]
                        python = { package = "pyo3", version = "0.29", features = ["macros"] }
                        """)
                    mkpath(joinpath(root, "sibling", "src"))
                    write(joinpath(root, "sibling", "Cargo.toml"), """
                        [package]
                        name = "resolver_sibling303"
                        version = "0.1.0"
                        edition = "2018"
                        [dependencies]
                        python = { workspace = true, features = ["extension-module"] }
                        """)
                    write(joinpath(root, "sibling", "src", "lib.rs"), "")
                end
                dependency = workspace ? "workspace = true" :
                    "package = \"pyo3\", version = \"0.29\", features = [\"macros\"]"
                build_dependency = workspace ?
                    "workspace = true, features = [\"extension-module\"]" :
                    "package = \"pyo3\", version = \"0.29\", features = [\"extension-module\"]"
                write(joinpath(target, "Cargo.toml"), """
                    [package]
                    name = "resolver_target303"
                    version = "0.1.0"
                    edition = "2018"
                    [dependencies]
                    python = { $dependency }
                    [build-dependencies]
                    python = { $build_dependency }
                    [features]
                    default = ["normally_on"]
                    normally_on = []
                    extra = []
                    """ * (workspace ? "" : "\n[workspace]\n"))
                write(joinpath(target, "build.rs"), "fn main() {}")
                write(joinpath(target, "src", "lib.rs"), """
                    extern crate python as pyo3;
                    use pyo3::prelude::*;
                    #[pyfunction] pub fn answer() -> i32 { 42 }
                    """)
                resolved = RustCall._cargo_resolved_features(target;
                    features = ["extra"], default_features = false)
                @test resolved !== nothing
                if resolved !== nothing
                    crate_features, python_features, active = resolved
                    @test active
                    @test "extra" in crate_features
                    @test !("normally_on" in crate_features)
                    @test !("extension-module" in python_features)
                end
                plan = RustCall.pyo3_link_plan(target)
                @test plan.resolved
                @test plan.mode === :link_libpython
                @test "normally_on" in plan.crate_features
                wrapper = _link_libpython_wrapper(target)
                if wrapper === nothing
                    @test_skip "no linkable Python here"
                else
                    binding = @rust_crate target
                    module_ = binding.module_ref
                    name = getfield(module_, :_LIB_NAME)
                    try
                        @test Base.invokelatest(getfield(module_, :answer)) == 42
                    finally
                        RustCall.unload_library(name; close = true)
                        RustCall.close_retired_handles!(RustCall.retired_handles(name))
                    end
                end
            end
        end
    end
end
