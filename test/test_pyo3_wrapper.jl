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
const PYO3_MIXED_CRATE = joinpath(@__DIR__, "..", "examples", "sample_crate_pyo3_mixed")

# Whether a `:link_libpython` wrapper can actually be built here.
#
# Knowing the plan is not enough, and deliberately so: a machine can have a
# Python interpreter whose library directory `python_library_dir` finds while
# still lacking what the *link* needs — the `libpython3.x.so` symlink and the
# headers live in a `-dev` package that a bare CI image does not install, and
# pyo3's build script refuses without them. So the guard performs the build and
# skips on a build failure, rather than asserting on a machine that cannot
# produce the artifact at all.
#
# Only the build is forgiven. Everything after it — loading, calling,
# destructing — is a hard assertion, so a real regression cannot hide behind
# this skip. The build result is returned so the testset does not pay for it
# twice; `@rust_crate` then hits the cache it just filled.
function _link_libpython_wrapper(crate; features::Vector{String} = String[],
                                 default_features::Bool = true)
    RustCall.check_rustc_available() || return nothing
    try
        plan = RustCall.pyo3_link_plan(crate; features = features,
                                       default_features = default_features)
        plan.mode === :link_libpython || return nothing
        return RustCall.build_pyo3_wrapper(RustCall.scan_crate(crate);
                                           features = features,
                                           default_features = default_features)
    catch e
        @info "skipping the :link_libpython wrapper testset" exception = e
        return nothing
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

            functions, structs, skipped, exports = RustCall._pyo3_wrapper_items(source.manifest)
            names = Set(f.name for f in functions)
            @test exports == 4
            @test names == Set(["add", "shout", "greeting", "boom"])
            @test all(f -> f.exported && isempty(f.skip_reason), functions)
            @test isempty(structs)

            reasons = Dict(item.name => item.skip_reason for item in skipped)
            @test reasons["private_add"] == "not_public"
            # Generated from a **lenient** scan here, which is what an
            # unresolved plan falls back to: the item is behind a `#[cfg]` whose
            # predicate the scan could not decide, so calling it cannot be
            # justified. With a resolved plan it is decided instead — see
            # "a resolved plan decides `#[cfg]`, it does not refuse it".
            @test reasons["only_with_python"] == "cfg_undecided:feature = \"python\""
            @test startswith(reasons["sample_crate_pyo3_optional"], "pymodule")
        end
    end

    @testset "the optional crate, with its feature on" begin
        # Everything the `#[cfg_attr]`-marked crate exposes, called through the
        # wrapper. Its plan is `:link_libpython` once the feature is on, so this
        # skips where a wrapper cannot be linked.
        wrapper = _link_libpython_wrapper(PYO3_OPTIONAL_CRATE;
                                          features = ["python"], default_features = false)
        if wrapper === nothing
            @test_skip "no linkable Python here: the feature-on wrapper cannot be built"
        else
            M = @rust_crate PYO3_OPTIONAL_CRATE features=["python"] default_features=false
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

    @testset "write_bindings_to_file emits the same bindings" begin
        wrapper = _link_libpython_wrapper(PYO3_OPTIONAL_CRATE;
                                          features = ["python"], default_features = false)
        if wrapper === nothing
            @test_skip "no linkable Python here: the feature-on wrapper cannot be built"
        else
            mktempdir() do dir
                out = joinpath(dir, "OptionalBindings.jl")
                RustCall.write_bindings_to_file(PYO3_OPTIONAL_CRATE, out;
                                                output_module_name = "PyO3OptionalBindings",
                                                features = ["python"],
                                                default_features = false)
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
        wrapper = _link_libpython_wrapper(PYO3_ONLY_CRATE)
        if wrapper === nothing
            @test_skip "no linkable Python here: a :link_libpython wrapper cannot be built"
        else
            @test wrapper.plan.mode === :link_libpython
            @test isfile(wrapper.lib_path)
            # The wrapper exports the whole class, not only the free functions.
            @test any(st -> st.name == "Point", wrapper.info.julia_structs)

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

            # `#[pyo3(set)]` alone is a setter with no getter (#307 review):
            # the write reaches Rust — `scaled_norm` reads the field — and the
            # read is refused as a missing field rather than served through a
            # symbol the manifest never listed.
            call(setproperty!, p, :scale, 3.0)
            @test M.scaled_norm(p) ≈ 3 * M.norm(p)
            @test_throws ErrorException call(getproperty, p, :scale)
            @test :scale in call(propertynames, p)

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

    @testset "generated `PyResult` mirrors carry the by-value assertion (#245)" begin
        # Since #295 an aggregate return has to carry a layout assertion or
        # `call_rust_function` refuses it. The `CResult_<owner>` mirror this path
        # generates is RustCall's own `#[repr(C)]` type — the wrapper crate
        # builds it with the same `generate_c_result_type` the `#[julia]` path
        # uses — so it subtypes `FFIByValue` exactly as that path's mirrors do.
        # Without it every wrapped `PyResult` call raised at its first
        # invocation, which is what CI caught on #307.
        if !RustCall.check_rustc_available()
            @test_skip "rustc is not available"
        else
            info = RustCall.scan_crate(PYO3_ONLY_CRATE)
            cargo_toml = RustCall.parse_cargo_toml(joinpath(PYO3_ONLY_CRATE, "Cargo.toml"))
            sources = sort(RustCall.find_rust_sources(PYO3_ONLY_CRATE))
            lib_root, tree_files = RustCall._crate_scan_inputs(PYO3_ONLY_CRATE, cargo_toml, sources)
            source = RustCall.wrap_crate(tree_files; crate_name = info.name, cfg = :lenient,
                                         crate_root = lib_root, skip_unparsable = true)
            # The Rust side really does declare it `#[repr(C)]`, which is what
            # the Julia-side assertion claims.
            @test occursin("#[repr(C)]", source.lib_rs)
            @test occursin("pub struct CResult_parse", source.lib_rs)

            functions, structs, _, _ = RustCall._pyo3_wrapper_items(source.manifest)
            wrapped = RustCall.CrateInfo(info.name, info.path, info.version, info.dependencies,
                                         functions, structs, info.source_files,
                                         info.pyo3_functions, info.pyo3_structs)
            # Both emitters, since they are separate code paths.
            code = RustCall.emit_crate_module_code(wrapped, "/nonexistent/lib.so";
                                                   lib_name = "rust_crate_byvalue_probe")
            @test occursin("struct CResult_parse <: FFIByValue", code)
            @test occursin("struct CResult_Point_scaled <: FFIByValue", code)

            expr = RustCall.emit_crate_module(wrapped, "/nonexistent/lib.so";
                                              lib_name = "rust_crate_byvalue_probe")
            text = string(expr)
            @test occursin("CResult_parse <: FFIByValue", text)
            @test occursin("CResult_Point_scaled <: FFIByValue", text)
        end
    end

    @testset "a setter-only field is a property with no read, in both emitters (#307 review)" begin
        # The manifest's two accessor columns are independent; the emitters
        # must not key the setter on the getter, nor invent a getter symbol.
        info = RustCall.RustStructInfo("Knob", String[], RustCall.RustMethod[], "",
                                       [("level", "f64"), ("gain", "f64")], true,
                                       Dict{String, Bool}("JuliaStruct" => true);
                                       field_abis = Dict("level" => "", "gain" => ""),
                                       field_getters = Dict("level" => "rustcall_Knob_get_level"),
                                       field_setters = Dict("level" => "rustcall_Knob_set_level",
                                                            "gain" => "rustcall_Knob_set_gain"))
        @test RustCall.field_is_writable(info, "gain")
        @test !RustCall.field_is_accessible(info, "gain")

        # Source text (`write_bindings_to_file`).
        code = RustCall._emit_struct_code(info)
        @test occursin("rustcall_Knob_set_gain", code)
        @test occursin("rustcall_Knob_get_level", code)
        @test !occursin("Knob_get_gain", code)
        @test occursin("(:level, :gain,)", code)

        # In memory (`@rust_crate`).
        text = string(RustCall._generate_property_accessors(info))
        @test occursin("rustcall_Knob_set_gain", text)
        @test !occursin("Knob_get_gain", text)
        accessor = string(RustCall._generate_crate_field_accessor(info, "gain", "f64"))
        @test occursin("set_gain!", accessor)
        @test !occursin("get_gain", accessor)
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
            # The build inherits the ambient environment, so it is part of the
            # artifact: a wrapper built under different `RUSTFLAGS` is a
            # different binary and must not answer the first one's lookup
            # (#282's allowlist, via `artifact_build_env`).
            env = RustCall.compute_crate_hash(info; kind = "pyo3-wrapper",
                                              build_env = RustCall.artifact_build_env())
            flagged = withenv("RUSTFLAGS" => "-C target-cpu=native") do
                RustCall.compute_crate_hash(info; kind = "pyo3-wrapper",
                                            build_env = RustCall.artifact_build_env())
            end
            @test env != flagged
            @test flagged != wrapper
            # `env` may equal `wrapper` when nothing in the #282 allowlist is
            # set, which is the point: an empty environment is not a different
            # build. What must never collide is a *different* environment.
            @test length(Set([plain, wrapper, featured, flagged])) == 4
            # The interpreter a `:link_libpython` build pins `PYO3_PYTHON` to
            # is decided by the plan and folded into the key *before* the
            # lookup, so two interpreters sharing one library directory are two
            # wrappers, not one cache hit (#307 review, #278).
            one = RustCall.PyO3LinkPlan(:link_libpython, String[], @__DIR__, "test";
                                        interpreter = "/opt/one/bin/python3")
            two = RustCall.PyO3LinkPlan(:link_libpython, String[], @__DIR__, "test";
                                        interpreter = "/opt/two/bin/python3")
            flags = RustCall.pyo3_link_rustflags(one)
            @test flags == RustCall.pyo3_link_rustflags(two)
            key_one = RustCall.compute_crate_hash(info; kind = "pyo3-wrapper",
                                                  build_env = RustCall._pyo3_wrapper_build_env(one, flags))
            key_two = RustCall.compute_crate_hash(info; kind = "pyo3-wrapper",
                                                  build_env = RustCall._pyo3_wrapper_build_env(two, flags))
            @test key_one != key_two
            # A `:python_free` build consults no interpreter, so its key
            # carries none: the same plan with or without one is one artifact.
            free = RustCall.PyO3LinkPlan(:python_free, String[], "", "test";
                                         interpreter = "/opt/one/bin/python3")
            @test !any(p -> p.first == "rustcall-pyo3-python",
                       RustCall._pyo3_wrapper_build_env(free, String[]))
            # And the registry name follows the key, so two feature sets of one
            # crate do not clobber each other's entry.
            @test RustCall.crate_library_name(info; kind = "pyo3-wrapper") !=
                  RustCall.crate_library_name(info; kind = "pyo3-wrapper",
                                              features = ["python"])
        end
    end

    @testset "a mixed crate keeps its `#[julia]` items (#307 review)" begin
        # `#[julia]` is additive since #279 and exports `rustcall_<name>` from
        # the *target* crate; the wrapper crate generates entry points for the
        # PyO3 items and links the rest. Binding only the PyO3 origins dropped
        # every `#[julia]` function and struct of such a crate from the module.
        if !RustCall.check_rustc_available()
            @test_skip "rustc is not available"
        else
            info = RustCall.scan_crate(PYO3_MIXED_CRATE)
            @test !isempty(info.julia_functions)
            @test RustCall.crate_needs_pyo3_wrapper(info)

            wrapper = try
                RustCall.build_pyo3_wrapper(info)
            catch e
                @info "skipping the mixed-crate build" exception = e
                nothing
            end
            if wrapper === nothing
                @test_skip "the mixed crate's wrapper (:link_libpython) cannot be built here"
            else
                names = Set(f.name for f in wrapper.info.julia_functions)
                # Both origins, in one module.
                @test "julia_double" in names        # #[julia]
                @test "julia_shout" in names         # #[julia], string ABI
                @test "shared_add" in names          # both marks; #[julia] owns it
                @test "py_triple" in names           # #[pyfunction]
                @test any(st -> st.name == "Tally", wrapper.info.julia_structs)

                M = @rust_crate PYO3_MIXED_CRATE
                @test M.julia_double(Int32(21)) == 42
                @test M.julia_shout("hey") == "HEY!"
                @test M.shared_add(Int32(2), Int32(3)) == 5
                @test M.py_triple(Int32(4)) == 12
                tally = Base.invokelatest(M.Tally, Int64(7))
                @test M.doubled(tally) == 14
                @test Base.invokelatest(getproperty, tally, :count) == 7
            end
        end
    end

    @testset "the Rust path uses `[lib] name`, not the package name (#307 review)" begin
        # Rust code refers to a dependency by its **library target** name, which
        # `[lib] name` renames. Emitting `sample_crate_pyo3_mixed::add` for a
        # crate whose library is `mixed_pyo3_sample` is an unresolved-crate
        # error in code the user never wrote.
        cargo_toml = RustCall.parse_cargo_toml(joinpath(PYO3_MIXED_CRATE, "Cargo.toml"))
        @test RustCall.crate_rust_identifier("sample_crate_pyo3_mixed", cargo_toml) ==
              "mixed_pyo3_sample"
        # No `[lib] name`: the package name, with Cargo's `-` -> `_`.
        @test RustCall.crate_rust_identifier("a-b", Dict{String, Any}()) == "a_b"
        @test RustCall.crate_rust_identifier("a-b", Dict{String, Any}(
            "lib" => Dict{String, Any}("crate-type" => ["rlib"]))) == "a_b"

        if RustCall.check_rustc_available()
            info = RustCall.scan_crate(PYO3_MIXED_CRATE)
            sources = sort(RustCall.find_rust_sources(PYO3_MIXED_CRATE))
            lib_root, tree_files = RustCall._crate_scan_inputs(PYO3_MIXED_CRATE, cargo_toml,
                                                               sources)
            source = RustCall.wrap_crate(tree_files;
                crate_name = RustCall.crate_rust_identifier(info.name, cargo_toml),
                cfg = :lenient, crate_root = lib_root, skip_unparsable = true)
            @test occursin("mixed_pyo3_sample::py_triple", source.lib_rs)
            @test !occursin("sample_crate_pyo3_mixed::", source.lib_rs)
        end
    end

    @testset "a resolved plan decides `#[cfg]`, it does not refuse it (#307 review)" begin
        # Forcing lenient evaluation refused every feature-gated item as
        # `cfg_undecided` — including one the caller had *explicitly* asked for
        # by naming its feature. When Cargo resolved the configuration the scan
        # runs under it, so the item is decided.
        if !RustCall.check_rustc_available()
            @test_skip "rustc is not available"
        else
            info = RustCall.scan_crate(PYO3_OPTIONAL_CRATE)
            plan = RustCall.pyo3_link_plan(PYO3_OPTIONAL_CRATE;
                                           features = ["python"], default_features = false)
            if !plan.resolved
                @test_skip "Cargo could not resolve the crate"
            else
                @test !isempty(plan.cfg_text)
                wrapper = try
                    RustCall.build_pyo3_wrapper(info; features = ["python"],
                                                default_features = false)
                catch e
                    @info "skipping the feature-gated build" exception = e
                    nothing
                end
                if wrapper === nothing
                    @test_skip "the feature-gated wrapper (:link_libpython) cannot be built here"
                else
                    names = Set(f.name for f in wrapper.info.julia_functions)
                    # `#[cfg(feature = "python")] pub fn only_with_python` exists
                    # in this build, so it is wrapped rather than refused.
                    @test "only_with_python" in names
                    @test !any(x -> startswith(x.skip_reason, "cfg_undecided"), wrapper.skipped)
                end
            end
        end
    end

    @testset "a build that exposes nothing to PyO3 falls back to the plain path" begin
        # With the feature off, every `#[cfg_attr(feature = "python", ...)]`
        # marker is gone, so this build has no Python API and nothing for a
        # wrapper crate to export. Building an empty cdylib for it would be
        # worse than not building one.
        if !RustCall.check_rustc_available()
            @test_skip "rustc is not available"
        else
            info = RustCall.scan_crate(PYO3_OPTIONAL_CRATE)
            plan = RustCall.pyo3_link_plan(PYO3_OPTIONAL_CRATE)
            if !plan.resolved
                @test_skip "Cargo could not resolve the crate"
            else
                @test plan.mode === :python_free
                @test RustCall.build_pyo3_wrapper(info) === nothing
            end
        end
    end

    @testset "scan_report names the wrapper's exports" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is not available"
        else
            io = IOBuffer()
            report = RustCall.scan_report(PYO3_ONLY_CRATE; io = io)
            text = String(take!(io))
            @test occursin("Wrapper crate exports:", text)
            @test occursin("rustcall_add", text)
            @test report.wrapped !== nothing
            @test Set(item.name for item in report.wrapped) ⊇
                  Set(["add", "shout", "parse", "Point", "new", "norm"])

            # With the feature on, the optional crate's gated item is reported
            # as an export rather than as undecidable.
            io = IOBuffer()
            report = RustCall.scan_report(PYO3_OPTIONAL_CRATE; io = io,
                                          features = ["python"], default_features = false)
            if report.plan.resolved
                @test "only_with_python" in Set(item.name for item in report.wrapped)
            end

            # Phase-1-only reporting still works and says nothing was generated.
            io = IOBuffer()
            report = RustCall.scan_report(PYO3_ONLY_CRATE; io = io, generate = false)
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
