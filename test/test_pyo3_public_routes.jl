using RustCall, Test
include(joinpath(@__DIR__, "pyo3_wrapper_helpers.jl"))

function _public_route_wrapper303(file_module)
    mktempdir() do root
        mkpath(joinpath(root, "src"))
        write(joinpath(root, "Cargo.toml"), """
            [package]
            name = "public_routes303"
            version = "0.1.0"
            edition = "2021"
            [lib]
            crate-type = ["rlib"]
            [dependencies]
            pyo3 = { version = "0.29", default-features = false, features = ["macros"] }
            """)
        hidden_source = raw"""
                use pyo3::prelude::*;
                #[pyfunction] pub fn calculate() -> i32 { 42 }
                #[pyclass] pub struct Counter { #[pyo3(get, set)] pub value: i32 }
                #[pymethods] impl Counter {
                    #[new] pub fn new(value: i32) -> Self { Self { value } }
                    pub fn value(&self) -> i32 { self.value }
                }
                pub mod api {
                    use pyo3::prelude::*;
                    #[pyfunction] pub fn answer() -> i32 { 17 }
                }
            """
        module_source = if file_module
            write(joinpath(root, "src", "implementation.rs"), hidden_source)
            "#[path = \"implementation.rs\"] mod hidden;"
        else
            "mod hidden {\n" * hidden_source * "\n}"
        end
        write(joinpath(root, "src", "lib.rs"), module_source * raw"""
            mod bridge { pub use crate::hidden::Counter as PublicCounter; }
            pub use bridge::*;
            // Rust permits this value beside the re-exported type. It must
            // not make the class's type-namespace route ambiguous.
            #[allow(non_snake_case)] pub fn PublicCounter() -> i32 { 99 }
            pub use hidden::calculate as public_calculate;
            pub use hidden::calculate as _;
            pub use hidden::api as public_api;
            """)
        wrapper = _link_libpython_wrapper(root)
        if wrapper === nothing
            @test_skip "no linkable Python here"
        else
            bindings = @rust_crate root
            module_ = getfield(bindings, :module_ref)
            object = nothing
            try
                # Julia's canonical layout is unchanged; only the external
                # Rust call path uses the public aliases. One owning type.
                hidden = Base.invokelatest(getfield, module_, :hidden)
                calculate = Base.invokelatest(getfield, hidden, :calculate)
                counter = Base.invokelatest(getfield, hidden, :Counter)
                value = Base.invokelatest(getfield, hidden, :value)
                api = Base.invokelatest(getfield, hidden, :api)
                answer = Base.invokelatest(getfield, api, :answer)
                @test Base.invokelatest(calculate) == 42
                object = Base.invokelatest(counter, Int32(23))
                @test Base.invokelatest(value, object) == 23
                @test Base.invokelatest(getproperty, object, :value) == 23
                Base.invokelatest(setproperty!, object, :value, Int32(31))
                @test Base.invokelatest(getproperty, object, :value) == 31
                @test Base.invokelatest(value, object) == 31
                @test Base.invokelatest(answer) == 17
            finally
                object === nothing || finalize(object)
                name = Base.invokelatest(getfield, module_, :_LIB_NAME)
                RustCall.unload_library(name; close = true)
                RustCall.close_retired_handles!(RustCall.retired_handles(name))
            end
        end
    end
end

@testset "public re-exports build and call real PyO3 wrappers (#303)" begin
    @testset "$layout module" for layout in (:inline, :file)
        _public_route_wrapper303(layout === :file)
    end
end
