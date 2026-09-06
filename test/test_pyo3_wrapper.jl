# Phase 2 of #275: a crate written for PyO3, carrying no RustCall attribute at
# all, is bound by generating a wrapper crate that depends on it, building that,
# and loading the result.
#
# Two fixtures, because there are two link plans and only one of them can run
# everywhere:
#
#   * `examples/sample_crate_pyo3_optional` — pyo3 is optional and only the
#     `#[pyfunction]` *markers* are behind a feature, so the wrapper builds with
#     pyo3 out of the graph entirely (`:python_free`). No Python is needed, so
#     this is the fixture CI exercises on every platform.
#   * `examples/sample_crate_pyo3_only` — pyo3 is a mandatory dependency, which
#     is the common shape; the wrapper cdylib hard-links libpython
#     (`:link_libpython`) and only builds and loads where an interpreter's
#     library directory can be found. That testset skips itself otherwise.
#
# The class, the accessors, the `PyResult` method and the drop counter live in
# the second fixture: pyo3's inner attributes (`new`, `getter`, `setter`,
# `pyo3(get, set)`) cannot be put behind `cfg_attr`, so a `#[pyclass]` cannot
# exist in a crate whose pyo3 dependency is optional.
using RustCall
using Test

const PYO3_OPTIONAL_CRATE = joinpath(@__DIR__, "..", "examples", "sample_crate_pyo3_optional")
const PYO3_ONLY_CRATE = joinpath(@__DIR__, "..", "examples", "sample_crate_pyo3_only")

# A `:link_libpython` wrapper can only be built where the interpreter's library
# directory is known; `pyo3_link_rustflags` raises otherwise, and that is the
# whole point of the plan.
function _link_libpython_available(crate)
    RustCall.check_rustc_available() || return false
    try
        plan = RustCall.pyo3_link_plan(crate)
        plan.mode === :link_libpython || return false
        RustCall.pyo3_link_rustflags(plan)
        return true
    catch
        return false
    end
end

@testset "PyO3 wrapper crate (#275 Phase 2)" begin

    @testset "the opaque PyErr message is one contract, written down twice" begin
        # `rustcall_core::wrap::PYERR_MESSAGE` and `RustCall.PYO3_OPAQUE_ERROR`
        # describe the same value; the Rust side documents it and the Julia side
        # raises it, so they must not drift.
        rust = read(joinpath(@__DIR__, "..", "deps", "rustcall_core", "src", "wrap.rs"), String)
        @test occursin(RustCall.PYO3_OPAQUE_ERROR, rust)
        @test RustCall.PYO3_ERROR_CODE == Int32(1)
        @test occursin("pub const PYERR_CODE: i32 = 1;", rust)
    end

    @testset "generation: what the wrapper exports, and what it refuses" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is not available"
        else
            info = RustCall.scan_crate(PYO3_OPTIONAL_CRATE)
            @test RustCall.crate_needs_pyo3_wrapper(info)

            cargo_toml = RustCall.parse_cargo_toml(joinpath(PYO3_OPTIONAL_CRATE, "Cargo.toml"))
            sources = sort(RustCall.find_rust_sources(PYO3_OPTIONAL_CRATE))
            lib_root, tree_files = RustCall._crate_scan_inputs(PYO3_OPTIONAL_CRATE, cargo_toml, sources)
            source = RustCall.wrap_crate(tree_files; crate_name = info.name, cfg = :lenient,
                                         crate_root = lib_root, skip_unparsable = true)

            # The generated file calls the *item* through the dependency's path
            # and exports the #279 symbol scheme.
            @test occursin("sample_crate_pyo3_optional::add", source.lib_rs)
            @test occursin("pub extern \"C\" fn rustcall_add", source.lib_rs)
            @test occursin("rustcall_add_take_panic", source.lib_rs)

            functions, structs, skipped = RustCall._pyo3_wrapper_items(source.manifest)
            names = Set(f.name for f in functions)
            @test names == Set(["add", "shout", "greeting", "boom"])
            @test all(f -> f.exported && isempty(f.skip_reason), functions)
            @test isempty(structs)

            reasons = Dict(item.name => item.skip_reason for item in skipped)
            @test reasons["private_add"] == "not_public"
            # The *item* is behind the feature here, not only its marker, and
            # the lenient scan cannot decide the predicate.
            @test reasons["only_with_python"] == "cfg_undecided:feature = \"python\""
            @test startswith(reasons["sample_crate_pyo3_optional"], "pymodule")
        end
    end

    @testset ":python_free — a wrapper that links no libpython" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is not available"
        else
            plan = RustCall.pyo3_link_plan(PYO3_OPTIONAL_CRATE)
            @test plan.mode === :python_free
            @test RustCall.pyo3_link_rustflags(plan) == String[]

            M = @rust_crate PYO3_OPTIONAL_CRATE
            @test M.add(Int32(2), Int32(3)) == 5
            @test M.shout("hello") == "HELLO!"
            @test M.greeting() == "hello from a pyo3-optional crate"
            @test M.boom(Int32(4)) == 8

            # The panic boundary is the one `#[julia]` uses, because the wrapper
            # came out of the same generator.
            err = try
                M.boom(Int32(-1))
                nothing
            catch e
                e
            end
            @test err isa RustCall.RustPanicError
            @test occursin("boom: n must not be negative", err.message)
        end
    end

    @testset ":python_free — write_bindings_to_file emits the same bindings" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is not available"
        else
            mktempdir() do dir
                out = joinpath(dir, "OptionalBindings.jl")
                RustCall.write_bindings_to_file(PYO3_OPTIONAL_CRATE, out;
                                                output_module_name = "PyO3OptionalBindings")
                code = read(out, String)
                @test occursin("function add(a, b)", code)
                @test occursin("rustcall_add", code)
                @test occursin("greeting_RustCallBorrowedString", code) ||
                      occursin("_call_rust_borrowed_string_ptr", code)
                # The generated file is a module definition; evaluating it
                # creates methods in a newer world than this one, so every call
                # into it goes through `invokelatest` (as the other emitted
                # bindings tests do).
                mod = Module(:PyO3OptionalBindingsHost)
                Base.include(mod, out)
                bound = Base.invokelatest(getfield, mod, :PyO3OptionalBindings)
                add = Base.invokelatest(getfield, bound, :add)
                shout = Base.invokelatest(getfield, bound, :shout)
                @test Base.invokelatest(add, Int32(4), Int32(5)) == 9
                @test Base.invokelatest(shout, "x") == "X!"
            end
        end
    end

    @testset ":link_libpython — a class, its accessors and PyResult" begin
        if !_link_libpython_available(PYO3_ONLY_CRATE)
            @test_skip "no Python library directory: a :link_libpython wrapper cannot be built"
        else
            M = @rust_crate PYO3_ONLY_CRATE

            # Free functions, including the string ABI.
            @test M.add(Int32(2), Int32(3)) == 5
            @test M.shout("hello") == "HELLO!"

            # `PyResult<T>` -> `RustResult{T, String}`; the error is opaque and
            # never rendered from the `PyErr`.
            ok = M.parse("42")
            @test ok isa RustCall.RustResult{Int32, String}
            @test ok.is_ok && ok.value == 42
            bad = M.parse("not a number")
            @test !bad.is_ok
            @test bad.value == RustCall.PYO3_OPAQUE_ERROR

            # The generated struct type is defined in a newer world than this
            # testset, so its constructor and property access go through
            # `invokelatest`; the function proxies of `CrateBindings` already do.
            call = Base.invokelatest

            # `#[new]` is the constructor, `#[staticmethod]` a plain function.
            p = call(M.Point, 3.0, 4.0)
            @test M.norm(p) == 5.0
            @test M.norm(M.origin()) == 0.0

            # `#[getter]` and `#[setter]` are ordinary methods from the C side.
            @test M.sum(p) == 7.0
            M.set_both(p, 2.0)
            @test M.norm(p) == sqrt(8.0)

            # `#[pyo3(get, set)]` becomes property access; `#[pyo3(get)]` is
            # read-only in Python but the wrapper still only emits the getter.
            call(setproperty!, p, :x, 6.0)
            @test call(getproperty, p, :x) == 6.0
            @test call(getproperty, p, :y) == 2.0

            # A `String`-returning method comes back through the per-method
            # owned buffer.
            @test M.label(p) == "(6, 2)"

            # A `PyResult` *method*, both ways.
            good = M.scaled(p, 2.0)
            @test good.is_ok && good.value ≈ 2 * M.norm(p)
            @test !M.scaled(p, Inf).is_ok
            @test M.scaled(p, Inf).value == RustCall.PYO3_OPAQUE_ERROR

            # A panic in a wrapped item is catchable, not fatal.
            @test_throws RustCall.RustPanicError M.boom(Int32(-1))

            # The generated `Point_free` really runs the Rust destructor: the
            # crate counts its drops.
            before = M.dropped_points()
            let doomed = call(M.Point, 1.0, 1.0)
                @test M.norm(doomed) ≈ sqrt(2.0)
                finalize(doomed)
            end
            @test M.dropped_points() == before + 1
        end
    end

    @testset ":link_libpython — the plan is refused rather than mis-built" begin
        # An `extension-module` crate cannot be wrapped at all on Unix; the
        # refusal happens before anything is generated.
        plan = RustCall.PyO3LinkPlan(:unlinkable, String[], "", "test")
        @test_throws RustCall.RustError RustCall.pyo3_link_rustflags(plan)

        # `:link_libpython` with no interpreter directory is refused too, with a
        # message that says what to set.
        blind = RustCall.PyO3LinkPlan(:link_libpython, String[], "", "test")
        err = try
            RustCall.pyo3_link_rustflags(blind)
            nothing
        catch e
            e
        end
        @test err isa RustCall.RustError
        @test occursin("RUSTCALL_PYTHON_LIBDIR", sprint(showerror, err))
    end

    @testset "artifact identity separates wrapper builds from plain ones" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is not available"
        else
            info = RustCall.scan_crate(PYO3_OPTIONAL_CRATE)
            plain = RustCall.compute_crate_hash(info)
            wrapper = RustCall.compute_crate_hash(info; kind = "pyo3-wrapper")
            featured = RustCall.compute_crate_hash(info; kind = "pyo3-wrapper",
                                                   features = ["python"],
                                                   default_features = false)
            flagged = RustCall.compute_crate_hash(info; kind = "pyo3-wrapper",
                                                  rustflags = ["-L", "native=/x"])
            @test length(Set([plain, wrapper, featured, flagged])) == 4
            # And the registry name follows the key, so two feature sets of one
            # crate do not clobber each other's entry.
            @test RustCall.crate_library_name(info; kind = "pyo3-wrapper") !=
                  RustCall.crate_library_name(info; kind = "pyo3-wrapper",
                                              features = ["python"])
        end
    end

    @testset "scan_report names the wrapper's exports" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is not available"
        else
            io = IOBuffer()
            report = RustCall.scan_report(PYO3_OPTIONAL_CRATE; io = io)
            text = String(take!(io))
            @test occursin("Wrapper crate exports:", text)
            @test occursin("rustcall_add", text)
            @test report.wrapped !== nothing
            @test Set(item.name for item in report.wrapped) ==
                  Set(["add", "shout", "greeting", "boom"])

            # Phase-1-only reporting still works and says nothing was generated.
            io = IOBuffer()
            report = RustCall.scan_report(PYO3_OPTIONAL_CRATE; io = io, generate = false)
            @test report.wrapped === nothing
            @test occursin("Wrapper crate: not generated", String(take!(io)))
        end
    end

    @testset "a crate with no wrappable PyO3 item takes the pre-#275 path" begin
        # `sample_crate` carries `#[julia]` attributes and no PyO3 ones, so
        # nothing here changes how it is bound.
        info = RustCall.scan_crate(joinpath(@__DIR__, "..", "examples", "sample_crate"))
        @test !RustCall.crate_needs_pyo3_wrapper(info)
    end
end
