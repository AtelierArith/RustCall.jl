# Component tests loaded by test_pyo3_link_plan.jl.

@testset "PyO3 link plan: resolved behavior" begin
    # ------------------------------------------------------------------
    # The resolved path. Needs cargo and a resolvable crate.
    # ------------------------------------------------------------------
    mandatory_crate = joinpath(@__DIR__, "fixtures", "sample_crate_pyo3_only")
    optional_crate = joinpath(@__DIR__, "fixtures", "sample_crate_pyo3")
    probe = try
        RustCall.pyo3_link_plan(mandatory_crate)
    catch
        nothing
    end

    if probe === nothing || !probe.resolved
        @test_skip "Cargo could not resolve the example crates; skipping the resolved link-plan tests"
    else
        @testset "resolved: mandatory pyo3 links libpython" begin
            plan = RustCall.pyo3_link_plan(mandatory_crate)
            @test plan.resolved
            @test plan.mode === :link_libpython
            # Cargo's own answer, not a re-implementation of feature resolution.
            @test "macros" in plan.pyo3_features
            @test !("extension-module" in plan.pyo3_features)
            # The configuration the crate scan then runs under.
            @test !isempty(plan.cfg_text)
            @test occursin("target_pointer_width", plan.cfg_text)
        end

        @testset "resolved: the cfg probe follows the requested profile (#307 review)" begin
            # `debug_assertions` is set in a debug build and not in a release
            # one, so a scan under the wrong profile decides a
            # `#[cfg(debug_assertions)]` item the other way round: the plan for
            # `build_release = false` must probe the debug configuration.
            release = RustCall.pyo3_link_plan(mandatory_crate)
            debug = RustCall.pyo3_link_plan(mandatory_crate; release = false)
            @test release.resolved && debug.resolved
            @test !occursin(r"^debug_assertions$"m, release.cfg_text)
            @test occursin(r"^debug_assertions$"m, debug.cfg_text)
            # Everything but the configuration is the same build.
            @test debug.mode === release.mode
            @test debug.pyo3_features == release.pyo3_features
        end

        @testset "resolved: the feature set is the caller's choice" begin
            # `test/fixtures/sample_crate_pyo3` has
            # `pyo3 = { optional = true, features = ["extension-module"] }` behind
            # `python = [...]` with `default = []`. Different feature sets are
            # genuinely different builds, and the plan answers for the one asked
            # about rather than hunting for a nicer one.
            default_plan = RustCall.pyo3_link_plan(optional_crate)
            @test default_plan.resolved
            @test default_plan.mode === :python_free
            @test isempty(default_plan.pyo3_features)
            @test occursin("does not resolve pyo3", default_plan.reason)

            with_python = RustCall.pyo3_link_plan(optional_crate; features = ["python"])
            @test with_python.resolved
            @test "extension-module" in with_python.pyo3_features
            @test with_python.feature_flags == ["--features", "python"]
            if Sys.iswindows()
                # See the conservative-fallback testset: `extension-module` is
                # not a blocker on Windows.
                @test with_python.mode === :link_libpython
                @test occursin("On Windows pyo3 still links", with_python.reason)
            else
                @test with_python.mode === :unlinkable
                @test occursin("extension-module", with_python.reason)
                @test occursin("pyo3_feature_candidates", with_python.reason)
            end
        end

        @testset "resolved: which features activate pyo3" begin
            candidates = RustCall.pyo3_feature_candidates(optional_crate)
            @test !isempty(candidates)
            python = only(c for c in candidates if c.feature == "python")
            @test python.activates_pyo3
            # This crate's feature also pulls `extension-module`, which is what
            # makes that build unloadable.
            @test python.extension_module

            # A crate with no `[features]` table has nothing to choose from.
            @test isempty(RustCall.pyo3_feature_candidates(mandatory_crate))
        end

        @testset "resolved: dev-dependencies do not poison the plan" begin
            # A wrapper depends on the target crate's *library*, so the target's
            # dev-dependencies are not in the graph it builds. Reading feature
            # edges without restricting them to normal dependencies would report
            # this crate as unlinkable.
            mktempdir() do dir
                _write_crate(dir, """
                [package]
                name = "dev_ext"
                version = "0.1.0"
                edition = "2021"

                [dependencies]
                pyo3 = { version = "0.29", default-features = false, features = ["macros"] }

                [dev-dependencies]
                pyo3 = { version = "0.29", features = ["extension-module"] }
                """)
                plan = RustCall.pyo3_link_plan(dir)
                if !plan.resolved
                    @test_skip "Cargo could not resolve the dev-dependency crate; skipping"
                else
                    @test plan.mode === :link_libpython
                    @test !("extension-module" in plan.pyo3_features)
                end
            end
        end
    end


end
