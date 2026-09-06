# Phase 1.5 of #275: before a wrapper crate is built against a PyO3 crate,
# decide whether it can be linked and loaded at all, and under which features.
#
# The plan asks **Cargo** to resolve the features (`cargo tree -e features`) and
# rustc for the resulting configuration, rather than re-implementing feature
# resolution in Julia. Two layers are tested separately:
#
#   * the conservative fallback, a pure `Cargo.toml` read used when Cargo cannot
#     answer — fast, offline, no toolchain needed;
#   * the resolved path, against the committed example crates, skipped when
#     Cargo cannot resolve them (no cargo, no network for a cold registry).
using RustCall
using Test
using TOML

function _write_crate(dir::AbstractString, cargo_toml::AbstractString)
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "Cargo.toml"), cargo_toml)
    write(joinpath(dir, "src", "lib.rs"), "")
    return dir
end

_manifest(text::AbstractString) = TOML.parse(text)

@testset "PyO3 link plan (#275 Phase 1.5)" begin
    @testset "conservative fallback: no pyo3 declared" begin
        plan = RustCall._pyo3_conservative_plan(_manifest("""
        [package]
        name = "plain"
        version = "0.1.0"
        """))
        @test plan.mode === :python_free
        @test plan.resolved == false
        @test occursin("no pyo3 dependency", plan.reason)
        @test RustCall.pyo3_link_rustflags(plan) == String[]
    end

    @testset "conservative fallback: extension-module cannot be loaded" begin
        for text in ("""
                     [package]
                     name = "ext"
                     version = "0.1.0"
                     [dependencies]
                     pyo3 = { version = "0.29", features = ["extension-module"] }
                     """,
                     # Renamed dependency: matched on `package`, and the advice
                     # names the key the crate actually uses.
                     """
                     [package]
                     name = "ext_renamed"
                     version = "0.1.0"
                     [dependencies]
                     python = { package = "pyo3", version = "0.29", features = ["extension-module"] }
                     """,
                     # Behind a target table, which the fallback does not try to
                     # evaluate: any declaration counts.
                     """
                     [package]
                     name = "ext_target"
                     version = "0.1.0"
                     [target.'cfg(windows)'.dependencies]
                     pyo3 = { version = "0.29", features = ["extension-module"] }
                     """)
            plan = RustCall._pyo3_conservative_plan(_manifest(text))
            @test occursin("conservative", plan.reason)
            if Sys.iswindows()
                # A DLL resolves every import at link time, so pyo3 links the
                # interpreter's import library there whether or not the feature
                # is on, and the wrapper is an ordinary `:link_libpython` build
                # (#294 review). Only Unix leaves the symbols undefined.
                @test plan.mode === :link_libpython
                @test occursin("On Windows pyo3 still links", plan.reason)
            else
                @test plan.mode === :unlinkable
                @test occursin("extension-module", plan.reason)
                @test_throws RustCall.RustError RustCall.pyo3_link_rustflags(plan)
            end
        end
        # The advice names the key the crate actually uses -- only on the Unix
        # path, which is the one that has to explain why it refused.
        if !Sys.iswindows()
            @test occursin("[dependencies.python]",
                           RustCall._pyo3_conservative_plan(_manifest("""
                           [package]
                           name = "ext_renamed"
                           version = "0.1.0"
                           [dependencies]
                           python = { package = "pyo3", version = "0.29", features = ["extension-module"] }
                           """)).reason)
        end
    end

    @testset "conservative fallback: any other pyo3 links libpython" begin
        # Without Cargo nothing here can show that an *optional* pyo3 is off in
        # the build the wrapper would make, so the fallback does not claim it.
        for text in ("""
                     [package]
                     name = "mandatory"
                     version = "0.1.0"
                     [dependencies]
                     pyo3 = { version = "0.29", default-features = false, features = ["macros"] }
                     """,
                     """
                     [package]
                     name = "optional"
                     version = "0.1.0"
                     [dependencies]
                     pyo3 = { version = "0.29", optional = true }
                     [features]
                     default = []
                     python = ["dep:pyo3"]
                     """)
            plan = RustCall._pyo3_conservative_plan(_manifest(text))
            @test plan.mode === :link_libpython
            @test occursin("conservative", plan.reason)
        end
    end

    @testset "link flags and the dependency entry" begin
        plan = RustCall._pyo3_conservative_plan(_manifest("""
        [package]
        name = "mandatory"
        version = "0.1.0"
        [dependencies]
        pyo3 = "0.29"
        """))
        @test plan.mode === :link_libpython

        mktempdir() do libdir
            withenv("RUSTCALL_PYTHON_LIBDIR" => libdir) do
                located = RustCall._pyo3_conservative_plan(_manifest("""
                [package]
                name = "mandatory"
                version = "0.1.0"
                [dependencies]
                pyo3 = "0.29"
                """))
                @test located.rpath == libdir
                flags = RustCall.pyo3_link_rustflags(located)
                @test "native=$(libdir)" in flags
                if Sys.iswindows()
                    # Windows has no rpath: the loader finds a DLL through the
                    # executable's directory and PATH, and `link.exe` rejects
                    # `-Wl,-rpath` outright (#294 review).
                    @test flags == ["-L", "native=$(libdir)"]
                else
                    @test any(f -> occursin("rpath,$(libdir)", f), flags)
                end
            end
            withenv("RUSTCALL_PYTHON_LIBDIR" => joinpath(libdir, "nope")) do
                missing_plan = RustCall._pyo3_conservative_plan(_manifest("""
                [package]
                name = "mandatory"
                version = "0.1.0"
                [dependencies]
                pyo3 = "0.29"
                """))
                @test missing_plan.rpath == ""
                @test_throws RustCall.RustError RustCall.pyo3_link_rustflags(missing_plan)
            end
        end

        # `default-features = false` belongs in the wrapper's dependency entry:
        # the `cargo build --no-default-features` flag applies to the package
        # being built, not to a dependency's defaults.
        off = RustCall.PyO3LinkPlan(:python_free, ["--no-default-features"], "", "test", false;
                                    crate_features = ["a", "b"])
        entry = RustCall.pyo3_dependency_toml(off, "target_crate", "/tmp/x")
        @test occursin("[dependencies.target_crate]", entry)
        @test occursin("default-features = false", entry)
        @test occursin("features = [\"a\", \"b\"]", entry)

        on = RustCall.PyO3LinkPlan(:python_free, String[], "", "test", true)
        @test !occursin("default-features", RustCall.pyo3_dependency_toml(on, "t", "/tmp/x"))
    end

    @testset "a missing Cargo.toml is an error, not a mode" begin
        mktempdir() do dir
            @test_throws RustCall.RustError RustCall.pyo3_link_plan(dir)
            @test_throws RustCall.RustError RustCall.pyo3_feature_candidates(dir)
        end
    end

    @testset "feature flags are spelled the way Cargo takes them" begin
        @test RustCall._pyo3_feature_flags(String[], true) == String[]
        @test RustCall._pyo3_feature_flags(String[], false) == ["--no-default-features"]
        @test RustCall._pyo3_feature_flags(["a"], true) == ["--features", "a"]
        @test RustCall._pyo3_feature_flags(["a", "b"], false) ==
              ["--no-default-features", "--features", "a,b"]
    end

    @testset "skip reasons have explanations" begin
        @test RustCall.pyo3_skip_explanation("") == ""
        @test occursin("E0603", RustCall.pyo3_skip_explanation("not_public"))
        text = RustCall.pyo3_skip_explanation("pyo3_type:Python<'_>")
        @test occursin("interpreter", text)
        @test occursin("Python<'_>", text)
        @test occursin("#300", RustCall.pyo3_skip_explanation("symbol_collision:a::run"))
        # An unknown reason from a newer extractor is passed through, never
        # rendered as an empty explanation.
        @test RustCall.pyo3_skip_explanation("brand_new_reason") == "brand_new_reason"
    end

    # ------------------------------------------------------------------
    # The resolved path. Needs cargo and a resolvable crate.
    # ------------------------------------------------------------------
    mandatory_crate = joinpath(dirname(@__DIR__), "examples", "sample_crate_pyo3_only")
    optional_crate = joinpath(dirname(@__DIR__), "examples", "sample_crate_pyo3")
    probe = try
        RustCall.pyo3_link_plan(mandatory_crate)
    catch
        nothing
    end

    if probe === nothing || !probe.resolved
        @warn "Cargo could not resolve the example crates; skipping the resolved link-plan tests"
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

        @testset "resolved: the feature set is the caller's choice" begin
            # `examples/sample_crate_pyo3` has
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
                    @warn "Cargo could not resolve the dev-dependency crate; skipping"
                else
                    @test plan.mode === :link_libpython
                    @test !("extension-module" in plan.pyo3_features)
                end
            end
        end
    end

    # ------------------------------------------------------------------
    # From the post-merge review of #294 (PR that landed Phase 1 / 1.5).
    # ------------------------------------------------------------------

    @testset "extension-module is a Unix-only blocker" begin
        # A DLL must resolve every import at link time, so pyo3 links the
        # interpreter's import library on Windows regardless of
        # `extension-module`; the resulting cdylib loads like any other
        # `:link_libpython` build. On Unix the feature leaves libpython's
        # symbols undefined and the cdylib cannot be loaded at all.
        @test RustCall.extension_module_is_linkable() == Sys.iswindows()

        plan = RustCall._pyo3_unresolved_cfg_plan(".", String[], String[],
                                                  ["extension-module"], true)
        if Sys.iswindows()
            @test plan.mode === :link_libpython
        else
            @test plan.mode === :unlinkable
            @test_throws RustCall.RustError RustCall.pyo3_link_rustflags(plan)
        end
    end

    @testset "link flags: no rpath where there is no rpath" begin
        # `-Wl,-rpath` is a GNU/Apple ld option; link.exe rejects it, and
        # Windows resolves a DLL through PATH rather than a recorded path.
        plan = RustCall.PyO3LinkPlan(:link_libpython, String[], @__DIR__, "test")
        flags = RustCall.pyo3_link_rustflags(plan)
        @test flags[1] == "-L"
        @test flags[2] == "native=$(@__DIR__)"
        if Sys.iswindows()
            @test length(flags) == 2
            @test !any(f -> occursin("rpath", f), flags)
        else
            @test any(f -> occursin("-Wl,-rpath,$(@__DIR__)", f), flags)
        end
    end

    @testset "a plan whose cfg probe failed is not `resolved`" begin
        # `cargo tree` can succeed while `cargo rustc -- --print cfg` fails.
        # Saying `resolved = true` with an empty `cfg_text` made `scan_report`
        # fall back to a lenient scan without ever saying so.
        for (pyo3_features, pyo3_active, expected) in
                ((String[], false, :python_free),
                 (["macros"], true, :link_libpython))
            plan = RustCall._pyo3_unresolved_cfg_plan(".", String[], ["a"],
                                                      pyo3_features, pyo3_active)
            @test plan.resolved == false
            @test plan.cfg_text == ""
            @test plan.mode === expected
            @test plan.crate_features == ["a"]
            @test occursin("--print cfg", plan.reason)
        end
    end
end
