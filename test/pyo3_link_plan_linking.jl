# Component tests loaded by test_pyo3_link_plan.jl.

@testset "PyO3 link plan: linking options" begin
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

    @testset "the link options travel in the wrapper's build script (#307 review)" begin
        # An environment `RUSTFLAGS` is ignored whenever
        # `CARGO_ENCODED_RUSTFLAGS` is set, and replaces a crate's `[build]
        # rustflags` when it is not; a `build.rs` reaches exactly this cdylib's
        # link step.
        linked = RustCall.PyO3LinkPlan(:link_libpython, String[], @__DIR__, "test")
        script = RustCall._pyo3_wrapper_build_script(linked)
        @test occursin("fn main()", script)
        @test occursin("cargo:rustc-link-search=native=$(escape_string(@__DIR__))", script)
        if Sys.iswindows()
            @test !occursin("rpath", script)
        else
            @test occursin("cargo:rustc-link-arg=-Wl,-rpath,$(escape_string(@__DIR__))", script)
        end
        # The same options, as `pyo3_link_rustflags` spells them for the key.
        flags = RustCall.pyo3_link_rustflags(linked)
        @test "native=$(@__DIR__)" in flags
        # Nothing for a build that links no libpython.
        @test RustCall._pyo3_wrapper_build_script(
                  RustCall.PyO3LinkPlan(:python_free, String[], "", "test")) == ""
    end

    @testset "the runtime DLL travels with the plan on Windows (#307 review)" begin
        # Windows has no rpath and the wrapper imports `python3xy.dll` by name,
        # a file beside the interpreter rather than in the `libs` directory it
        # linked against; the plan records the DLL the interpreter itself runs
        # and the module opens it before the wrapper. Elsewhere the rpath does
        # this and nothing is recorded.
        @test RustCall.PyO3LinkPlan(:link_libpython, String[], @__DIR__, "test").runtime_libraries ==
              String[]
        carried = RustCall.PyO3LinkPlan(:link_libpython, String[], @__DIR__, "test";
                                        runtime_libraries = ["C:\\py\\python312.dll"])
        @test carried.runtime_libraries == ["C:\\py\\python312.dll"]
        # No interpreter (a `PYO3_CONFIG_FILE` / `PYO3_CROSS_LIB_DIR`
        # configuration consults none): nothing to record.
        @test RustCall._python_runtime_libraries("") == String[]
        # One that cannot be run: nothing, not an error.
        @test RustCall._python_runtime_libraries(joinpath(@__DIR__, "no_such_python")) == String[]
        interpreter = RustCall._python_executable_on_path()
        if !Sys.iswindows()
            @test RustCall._python_runtime_libraries(interpreter) == String[]
        elseif isempty(interpreter)
            @test_skip "a Python interpreter is required"
        else
            libs = RustCall._python_runtime_libraries(interpreter)
            @test length(libs) == 1
            @test isfile(libs[1])
            @test endswith(lowercase(libs[1]), ".dll")
            @test occursin("python", lowercase(basename(libs[1])))
            # ... and the plan that names this interpreter carries it.
            plan = RustCall._pyo3_unresolved_cfg_plan(".", String[], ["a"], ["macros"], true)
            if plan.interpreter == interpreter
                @test plan.runtime_libraries == libs
            end
        end
    end


end
