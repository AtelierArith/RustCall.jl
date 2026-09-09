using RustCall, Test
include(joinpath(@__DIR__, "pyo3_wrapper_helpers.jl"))

@testset "PyO3 String fields use the byte-pair setter ABI (#303)" begin
    mktempdir() do root
        mkpath(joinpath(root, "src"))
        write(joinpath(root, "Cargo.toml"), """
            [package]
            name = "string_fields303"
            version = "0.1.0"
            edition = "2021"
            [dependencies]
            pyo3 = { version = "0.29", default-features = false, features = ["macros"] }
            """)
        write(joinpath(root, "src", "lib.rs"), raw"""
            use pyo3::prelude::*;
            #[pyclass]
            pub struct TextFields303 {
                #[pyo3(get, set)] pub label: String,
                #[pyo3(set)] pub write_only: String,
            }
            #[pymethods]
            impl TextFields303 {
                #[new] pub fn new() -> Self {
                    Self { label: "initial".into(), write_only: "hidden".into() }
                }
                pub fn read_write_only(&self) -> String { self.write_only.clone() }
            }
            """)
        wrapper = _link_libpython_wrapper(root)
        if wrapper === nothing
            @test_skip "no linkable Python here"
        else
            binding = @rust_crate root
            inline = binding.module_ref
            file = joinpath(root, "StringFields.jl")
            RustCall.write_bindings_to_file(root, file; output_module_name = "StringFields303")
            holder = Module(gensym(:StringFieldHolder303))
            Base.include(holder, file)
            written = Base.invokelatest(getfield, holder, :StringFields303)
            modules = [inline, written]
            try
                for module_ in modules
                    constructor = Base.invokelatest(getfield, module_, :TextFields303)
                    object = Base.invokelatest(constructor)
                    read_hidden = Base.invokelatest(getfield, module_, :read_write_only)
                    try
                        @test Base.invokelatest(getproperty, object, :label) == "initial"
                        for value in ("", "日本語\0tail", SubString("[substring]", 2, 10))
                            Base.invokelatest(setproperty!, object, :label, value)
                            @test Base.invokelatest(getproperty, object, :label) == value
                            Base.invokelatest(setproperty!, object, :write_only, value)
                            @test Base.invokelatest(read_hidden, object) == value
                            if module_ === inline
                                set_label = Base.invokelatest(getfield, module_, :set_label!)
                                set_hidden = Base.invokelatest(getfield, module_, :set_write_only!)
                                Base.invokelatest(set_label, object, value)
                                @test Base.invokelatest(getproperty, object, :label) == value
                                Base.invokelatest(set_hidden, object, value)
                                @test Base.invokelatest(read_hidden, object) == value
                            end
                        end
                        @test !isdefined(module_, :get_write_only)
                        @test_throws Exception Base.invokelatest(getproperty, object, :write_only)
                        @test_throws MethodError Base.invokelatest(setproperty!, object, :label, 17)
                        @test_throws RustCall.RustError Base.invokelatest(setproperty!, object, :label, String(UInt8[0xff]))
                    finally
                        finalize(object)
                    end
                    @test_throws RustCall.RustError Base.invokelatest(setproperty!, object, :label, "after free")
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
