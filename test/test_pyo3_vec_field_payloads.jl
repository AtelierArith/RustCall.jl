using RustCall, Test
include(joinpath(@__DIR__, "pyo3_wrapper_helpers.jl"))

@testset "PyO3 Vec fields use an owned-buffer ABI (#303)" begin
    mktempdir() do root
        mkpath(joinpath(root, "src"))
        write(joinpath(root, "Cargo.toml"), """
            [package]
            name = "vec_fields303"
            version = "0.1.0"
            edition = "2021"
            [dependencies]
            pyo3 = { version = "0.29", default-features = false, features = ["macros"] }
            """)
        write(joinpath(root, "src", "lib.rs"), raw"""
            use pyo3::prelude::*;
            #[pyclass]
            pub struct VecFields303 {
                #[pyo3(get, set)] pub values: Vec<i32>,
                #[pyo3(set)] pub write_only: Vec<f64>,
                #[pyo3(get)] pub packed: Vec<bool>,
            }
            #[pymethods]
            impl VecFields303 {
                #[new] pub fn new() -> Self {
                    Self { values: vec![1, 2, 3], write_only: vec![], packed: vec![true] }
                }
                pub fn write_only_sum(&self) -> f64 { self.write_only.iter().sum() }
            }
            """)
        wrapper = _link_libpython_wrapper(root)
        if wrapper === nothing
            @test_skip "no linkable Python here"
        else
            binding = @rust_crate root
            inline = binding.module_ref
            file = joinpath(root, "VecFields.jl")
            RustCall.write_bindings_to_file(root, file; output_module_name = "VecFields303File")
            holder = Module(gensym(:VecFieldHolder303))
            Base.include(holder, file)
            written = Base.invokelatest(getfield, holder, :VecFields303File)
            modules = [inline, written]
            try
                for module_ in modules
                    constructor = Base.invokelatest(getfield, module_, :VecFields303)
                    object = Base.invokelatest(constructor)
                    sum_hidden = Base.invokelatest(getfield, module_, :write_only_sum)
                    try
                        first = Base.invokelatest(getproperty, object, :values)
                        @test first isa RustCall.RustVec{Int32}
                        @test collect(first) == Int32[1, 2, 3]
                        finalize(first)

                        for value in (Int32[], Int64[4, -5, 6], 7:9)
                            Base.invokelatest(setproperty!, object, :values, value)
                            returned = Base.invokelatest(getproperty, object, :values)
                            @test collect(returned) == Int32[value...]
                            finalize(returned)
                        end

                        source = Base.invokelatest(getproperty, object, :values)
                        Base.invokelatest(setproperty!, object, :values, source)
                        @test collect(source) == Int32[7, 8, 9]
                        finalize(source)

                        Base.invokelatest(setproperty!, object, :write_only, [1, 2.5, -0.5])
                        @test Base.invokelatest(sum_hidden, object) == 3.0
                        @test_throws Exception Base.invokelatest(getproperty, object, :write_only)
                        @test_throws Exception Base.invokelatest(getproperty, object, :packed)
                        @test_throws InexactError Base.invokelatest(setproperty!, object, :values,
                                                                   [typemax(Int64)])

                        detached = Base.invokelatest(getproperty, object, :values)
                        finalize(object)
                        @test collect(detached) == Int32[7, 8, 9]
                        finalize(detached)
                    finally
                        finalize(object)
                    end
                    @test_throws RustCall.RustError Base.invokelatest(setproperty!, object, :values,
                                                                      Int32[])
                end
            finally
                for name in unique(Base.invokelatest(getfield, m, :_LIB_NAME) for m in modules)
                    RustCall.unload_library(name; close = true)
                    RustCall.close_retired_handles!(RustCall.retired_handles(name))
                end
            end
        end
    end
end
