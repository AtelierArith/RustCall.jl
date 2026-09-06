# Phase 1.5 of #275: before a wrapper crate is built against a PyO3 crate,
# decide whether it can be linked and loaded at all, and under which flags.
#
# The decision is read from the target crate's Cargo.toml — no build, no
# Python — so these tests only need temporary crates with a manifest.
using RustCall
using Test

function _write_crate(dir::AbstractString, cargo_toml::AbstractString)
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "Cargo.toml"), cargo_toml)
    write(joinpath(dir, "src", "lib.rs"), "")
    return dir
end

@testset "PyO3 link plan (#275 Phase 1.5)" begin
    @testset "no pyo3 dependency at all" begin
        mktempdir() do dir
            _write_crate(dir, """
            [package]
            name = "plain"
            version = "0.1.0"
            edition = "2021"
            """)
            plan = RustCall.pyo3_link_plan(dir)
            @test plan.mode === :python_free
            @test isempty(plan.feature_flags)
            @test RustCall.pyo3_link_rustflags(plan) == String[]
        end
    end

    @testset "(a) optional pyo3: build with the feature off" begin
        mktempdir() do dir
            _write_crate(dir, """
            [package]
            name = "optional_pyo3"
            version = "0.1.0"
            edition = "2021"

            [dependencies]
            pyo3 = { version = "0.29", optional = true }

            [features]
            default = []
            python = ["dep:pyo3"]
            """)
            plan = RustCall.pyo3_link_plan(dir)
            @test plan.mode === :python_free
            # The feature is not in `default`, so nothing has to be turned off.
            @test isempty(plan.feature_flags)
            @test occursin("optional", plan.reason)
            @test RustCall.pyo3_link_rustflags(plan) == String[]
        end
    end

    @testset "(a) optional pyo3 that is on by default: --no-default-features" begin
        mktempdir() do dir
            _write_crate(dir, """
            [package]
            name = "optional_default_pyo3"
            version = "0.1.0"
            edition = "2021"

            [dependencies]
            pyo3 = { version = "0.29", optional = true }

            [features]
            default = ["python"]
            python = ["dep:pyo3"]
            """)
            plan = RustCall.pyo3_link_plan(dir)
            @test plan.mode === :python_free
            @test plan.feature_flags == ["--no-default-features"]
        end
    end

    @testset "(b) mandatory pyo3: the wrapper links libpython" begin
        mktempdir() do dir
            _write_crate(dir, """
            [package]
            name = "mandatory_pyo3"
            version = "0.1.0"
            edition = "2021"

            [dependencies]
            pyo3 = { version = "0.29", default-features = false, features = ["macros"] }
            """)
            plan = RustCall.pyo3_link_plan(dir)
            @test plan.mode === :link_libpython
            @test occursin("libpython", plan.reason)

            # With an explicit library directory the flags name it as both a
            # search path and an rpath; without one the build must refuse.
            mktempdir() do libdir
                withenv("RUSTCALL_PYTHON_LIBDIR" => libdir) do
                    located = RustCall.pyo3_link_plan(dir)
                    @test located.rpath == libdir
                    flags = RustCall.pyo3_link_rustflags(located)
                    @test "native=$(libdir)" in flags
                    @test any(f -> occursin("rpath,$(libdir)", f), flags)
                end
                withenv("RUSTCALL_PYTHON_LIBDIR" => joinpath(libdir, "does_not_exist")) do
                    missing_plan = RustCall.pyo3_link_plan(dir)
                    @test missing_plan.rpath == ""
                    @test_throws RustCall.RustError RustCall.pyo3_link_rustflags(missing_plan)
                end
            end
        end
    end

    @testset "(c) extension-module: cannot be linked or loaded" begin
        mktempdir() do dir
            _write_crate(dir, """
            [package]
            name = "ext_module"
            version = "0.1.0"
            edition = "2021"

            [dependencies]
            pyo3 = { version = "0.29", features = ["extension-module"] }
            """)
            plan = RustCall.pyo3_link_plan(dir)
            @test plan.mode === :unlinkable
            # The message must say what to change, not just that it failed.
            @test occursin("extension-module", plan.reason)
            @test occursin("optional", plan.reason)
            err = try
                RustCall.pyo3_link_rustflags(plan)
                nothing
            catch e
                e
            end
            @test err isa RustCall.RustError
        end
    end

    @testset "extension-module behind an optional pyo3 is still python-free" begin
        # The MWE's `examples/sample_crate_pyo3` shape: pyo3 optional, with
        # `extension-module` in its feature list. Turning the feature off
        # removes both.
        mktempdir() do dir
            _write_crate(dir, """
            [package]
            name = "maturin_style"
            version = "0.1.0"
            edition = "2021"

            [dependencies]
            pyo3 = { version = "0.29", features = ["extension-module"], optional = true }

            [features]
            default = []
            python = ["pyo3"]
            """)
            plan = RustCall.pyo3_link_plan(dir)
            @test plan.mode === :python_free
        end
    end

    @testset "extension-module reachable from default features is disabled" begin
        mktempdir() do dir
            _write_crate(dir, """
            [package]
            name = "default_ext"
            version = "0.1.0"
            edition = "2021"

            [dependencies]
            pyo3 = "0.29"

            [features]
            default = ["python"]
            python = ["pyo3/extension-module"]
            """)
            plan = RustCall.pyo3_link_plan(dir)
            # pyo3 itself is mandatory, so libpython is linked either way, but
            # `extension-module` can be switched off and must be.
            @test plan.mode === :link_libpython
            @test plan.feature_flags == ["--no-default-features"]
        end
    end

    @testset "the example crate is the mandatory-pyo3 case" begin
        crate = joinpath(dirname(@__DIR__), "examples", "sample_crate_pyo3_only")
        @test isdir(crate)
        @test RustCall.pyo3_link_plan(crate).mode === :link_libpython
    end

    @testset "a missing Cargo.toml is an error, not a mode" begin
        mktempdir() do dir
            @test_throws RustCall.RustError RustCall.pyo3_link_plan(dir)
        end
    end

    @testset "skip reasons have explanations" begin
        @test RustCall.pyo3_skip_explanation("") == ""
        @test occursin("E0603", RustCall.pyo3_skip_explanation("not_public"))
        text = RustCall.pyo3_skip_explanation("pyo3_type:Python<'_>")
        @test occursin("interpreter", text)
        @test occursin("Python<'_>", text)
        # An unknown reason from a newer extractor is passed through, never
        # rendered as an empty explanation.
        @test RustCall.pyo3_skip_explanation("brand_new_reason") == "brand_new_reason"
    end
end
