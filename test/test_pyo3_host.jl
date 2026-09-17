# Phase 1 of #424: a PyO3 crate is built **as the Python extension it already
# is** — the `extension-module` cdylib the link plan calls `:unlinkable` — and
# imported. That reaches what the wrapper crate cannot name: a private
# `#[pyfunction]` (E0603 for an outside caller) and a `Python<'_>` signature.
#
# RustCall itself stays interpreter-free. The build is core and needs no Python
# at all; only the import needs one, and it lives in `RustCallPyO3HostExt`,
# which is loaded with PythonCall. So the suite is layered:
#
#   * the build-plan layer always runs;
#   * the build-and-import layer runs only where `pyo3_host_available()` is
#     true, i.e. where the session has PythonCall — a deliberate one-off run,
#     not the default suite, because PythonCall installs a Python.
using RustCall
using Test

# `RustCallPyO3HostExt` is loaded together with PythonCall. The default suite
# does not depend on it, so it is loaded only when the session already has it —
# otherwise the import layer below skips itself and the build-plan layer, which
# needs no Python, still runs.
if Base.find_package("PythonCall") !== nothing
    @eval using PythonCall
end

const PYO3_HOST_CRATE = joinpath(@__DIR__, "fixtures", "sample_crate_pyo3_host")
const PYO3_ONLY_CRATE = joinpath(@__DIR__, "fixtures", "sample_crate_pyo3_only")
const JULIA_ONLY_CRATE = joinpath(@__DIR__, "fixtures", "sample_crate")

@testset "PyO3 Python-host build plan (#424 Phase 1)" begin

    @testset "a #[pymodule] names the importable module" begin
        @test RustCall._pyo3_extension_module_name(PYO3_HOST_CRATE) ==
              "sample_crate_pyo3_host"
        @test RustCall._pyo3_extension_module_name(PYO3_ONLY_CRATE) ==
              "sample_crate_pyo3_only"
        # `#[pymodule]` lives in the optional fixture too, under a feature; the
        # lenient scan reads the marker rather than deciding the feature.
        optional = joinpath(@__DIR__, "fixtures", "sample_crate_pyo3_optional")
        @test RustCall._pyo3_extension_module_name(optional) == "sample_crate_pyo3_optional"
        # Nothing to import without one.
        @test RustCall._pyo3_extension_module_name(JULIA_ONLY_CRATE) == ""
    end

    @testset "the output file fills the [lib] name and the platform" begin
        cargo_toml = RustCall.parse_cargo_toml(joinpath(PYO3_HOST_CRATE, "Cargo.toml"))
        @test RustCall._crate_lib_name(cargo_toml) == "sample_crate_pyo3_host"
        name = RustCall._pyo3_extension_filename("mwemod")
        expected = Sys.iswindows() ? "mwemod.dll" :
                   Sys.isapple() ? "libmwemod.dylib" : "libmwemod.so"
        @test name == expected
    end

    @testset "[lib] name wins, otherwise the package name with `-` folded" begin
        @test RustCall._crate_lib_name(
            Dict("package" => Dict("name" => "a-b"), "lib" => Dict("name" => "c_d"))) == "c_d"
        @test RustCall._crate_lib_name(Dict("package" => Dict("name" => "a-b"))) == "a_b"
    end

    @testset "an rlib-only crate is not refused for that reason" begin
        # The wrapper path requires an `rlib` target; this path requires a
        # `cdylib` and selects one explicitly, so `crate-type = ["rlib"]` is a
        # non-issue. It fails here only for the missing interpreter, not for the
        # crate type.
        err = try
            RustCall.build_pyo3_extension(PYO3_ONLY_CRATE; python = "")
            nothing
        catch e
            e
        end
        @test err isa RustCall.RustError
        @test occursin("Python interpreter", sprint(showerror, err))
    end

    @testset "the host path refuses what it cannot honour" begin
        @test_throws RustCall.RustError RustCall.build_pyo3_extension(
            PYO3_ONLY_CRATE; python = "")
        # No `#[pymodule]`, nothing to import.
        @test_throws RustCall.RustError RustCall.build_pyo3_extension(
            JULIA_ONLY_CRATE; python = "/usr/bin/python3")
    end

    @testset "requesting the host without PythonCall names the fix" begin
        # Only meaningful where the extension is absent: with PythonCall
        # loaded the same call is the one the Phase 3 testset exercises.
        if !RustCall.pyo3_host_available()
            err = try
                RustCall.generate_bindings(PYO3_HOST_CRATE; pyo3_host = true)
                nothing
            catch e
                e
            end
            @test err isa RustCall.RustError
            @test occursin("PythonCall", sprint(showerror, err))
        end
    end
end

@testset "PyO3 Python-host import (#424 Phase 1)" begin
    if !RustCall.pyo3_host_available()
        @info "skipping the PyO3 Python-host import testset" reason =
            "PythonCall is not loaded; `using PythonCall` enables RustCallPyO3HostExt"
        return
    end
    # Once the host is available these are hard assertions: a build, import or
    # call regression must not become a skip.
    module_ = RustCall.pyo3_host_import(PYO3_HOST_CRATE)
    @test pyconvert(Int, module_.add(2, 3)) == 5
    # Not `pub`: a wrapper crate compiled outside the fixture cannot name it
    # (rustc E0603), so the C-ABI scan reports `not_public`. The crate's own
    # `#[pymodule]` registered it, so importing reaches it.
    @test pyconvert(Int, module_.private_add(4, 5)) == 9
    # `interpreter_token(py: Python<'_>)` is `pyo3_type` to the C-ABI scan, and
    # an ordinary argument here.
    @test pyconvert(Int, module_.interpreter_token()) == 7
    # A `#[pyclass]`: construction, field access and a method.
    point = module_.Point(3.0, 4.0)
    @test pyconvert(Float64, point.norm()) == 5.0
    @test pyconvert(Float64, point.x) == 3.0
    point.x = 6.0
    @test pyconvert(Float64, point.x) == 6.0
    # A second call must reuse the cached artifact rather than rebuild.
    again = RustCall.build_pyo3_extension(PYO3_HOST_CRATE;
                                          python = PythonCall.python_executable_path())
    @test again.lib_path == RustCall.build_pyo3_extension(
        PYO3_HOST_CRATE; python = PythonCall.python_executable_path()).lib_path
    @test isfile(again.lib_path)
end

@testset "PyO3 Python-host typed bindings (#424 Phase 2)" begin
    if !RustCall.pyo3_host_available()
        @info "skipping the PyO3 Python-host typed testset" reason =
            "PythonCall is not loaded; `using PythonCall` enables RustCallPyO3HostExt"
        return
    end
    bindings = RustCall.load_crate_bindings(PYO3_HOST_CRATE; pyo3_host = true)

    @test bindings.add(Int32(2), Int32(3)) == 5
    # `not_public` to the C-ABI scan; registered by the crate's own `#[pymodule]`.
    @test bindings.private_add(4, 5) == 9
    # `pyo3_type:Python<'_>` to the C-ABI scan; the injected token is dropped
    # from the Julia signature.
    @test bindings.interpreter_token() == 7

    point = bindings.Point(3.0, 4.0)
    @test bindings.norm(point) == 5.0
    # `#[pyo3(get, set)]` on a private field of a private struct: the descriptor
    # lives inside the crate, so the Python object answers.
    @test point.x == 3.0
    point.x = 6.0
    @test point.x == 6.0

    # `#[staticmethod]` returning `Self`.
    origin = bindings.origin()
    @test origin.x == 0.0 && origin.y == 0.0

    # `PyResult<T>` carries the interpreter's own message, not the opaque one.
    good = bindings.parse("42")
    @test good.is_ok && good.value == 42
    bad = bindings.parse("not a number")
    @test !bad.is_ok
    @test occursin("not an integer", bad.value)
    @test !occursin(RustCall.PYO3_OPAQUE_ERROR, bad.value)

    scaled = bindings.scaled(point, 0.5)
    @test scaled.is_ok
end

@testset "PyO3 Python-host @rust_crate dispatch (#424 Phase 3)" begin
    if !RustCall.pyo3_host_available()
        @info "skipping the PyO3 Python-host macro testset" reason =
            "PythonCall is not loaded; `using PythonCall` enables RustCallPyO3HostExt"
        return
    end
    Host = @rust_crate PYO3_HOST_CRATE pyo3_host = true
    @test Host.add(Int32(2), Int32(3)) == 5
    @test Host.Point(3.0, 4.0).x == 3.0
end
