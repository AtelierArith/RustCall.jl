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
const PYO3_DECLARATIVE_CRATE = joinpath(@__DIR__, "fixtures", "sample_crate_pyo3_declarative")
const PYO3_ASYNC_CRATE = joinpath(@__DIR__, "fixtures", "sample_crate_pyo3_async")
const PYO3_ONLY_CRATE = joinpath(@__DIR__, "fixtures", "sample_crate_pyo3_only")
const JULIA_ONLY_CRATE = joinpath(@__DIR__, "fixtures", "sample_crate")

# The host path can bind a crate that takes a pyo3-numpy array, but that call
# needs numpy in the interpreter; PythonCall does not install it on its own, so
# the numpy assertions below are the one place a skip is honest (#424).
function _numpy_available()
    RustCall.pyo3_host_available() || return false
    try
        PythonCall.pyimport("numpy")
        return true
    catch
        return false
    end
end

@testset "PyO3 Python-host build plan (#424 Phase 1)" begin

    @testset "a #[pymodule] names the importable module" begin
        @test RustCall._pyo3_extension_module_name(PYO3_HOST_CRATE) ==
              "sample_crate_pyo3_host"
        @test RustCall._pyo3_extension_module_name(PYO3_ONLY_CRATE) ==
              "sample_crate_pyo3_only"
        # A declarative `#[pymodule] mod name` names the module too (#424).
        @test RustCall._pyo3_extension_module_name(PYO3_DECLARATIVE_CRATE) ==
              "sample_crate_pyo3_declarative"
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

    @testset "the artifact is located without an interpreter (#449)" begin
        # `build_pyo3_extension` is the interpreter probe plus this; the
        # precompile workload runs this half on its own, so it must need
        # nothing but the scan and the cache directory it is given.
        info = RustCall.scan_crate(PYO3_HOST_CRATE)
        name = RustCall._pyo3_extension_module_name(info)
        mktempdir() do cache
            a = RustCall._pyo3_extension_artifact(cache, info, name, "/py/one", ".one.so", "fp-1")
            @test a.module_name == "sample_crate_pyo3_host"
            @test a.dir == joinpath(cache, "pyo3-host", RustCall.artifact_short_id(a.key))
            @test a.lib_path == joinpath(a.dir, "sample_crate_pyo3_host.one.so")
            @test a.interpreter == "/py/one" && a.fingerprint == "fp-1" && a.ext_suffix == ".one.so"
            @test !isfile(a.lib_path)
            # The interpreter's path, its fingerprint and the feature set are
            # each in the key; the same inputs give the same key.
            same = RustCall._pyo3_extension_artifact(cache, info, name, "/py/one", ".one.so", "fp-1")
            @test same.key == a.key
            @test RustCall._pyo3_extension_artifact(cache, info, name, "/py/two", ".one.so", "fp-1").key != a.key
            @test RustCall._pyo3_extension_artifact(cache, info, name, "/py/one", ".one.so", "fp-2").key != a.key
            @test RustCall._pyo3_extension_artifact(cache, info, name, "/py/one", ".one.so", "fp-1";
                                                    release = false).key != a.key
        end
    end

    @testset "the interpreter probe is one process, and refuses cleanly" begin
        @test RustCall._pyo3_extension_interpreter_probe("") == ("", "")
        missing_python = joinpath(mktempdir(), "no-such-python")
        @test RustCall._pyo3_extension_interpreter_probe(missing_python) == ("", "")
        @test RustCall._pyo3_extension_ext_suffix(missing_python) == ""
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

@testset "pyo3-numpy array spellings (#424)" begin
    # `PyReadonlyArray*` / `PyArray*`, bare, behind `Py<...>` or behind
    # `Bound<'_, ...>`, with or without the `numpy::` path; `Dyn` is any rank.
    @test RustCall._pyo3_host_numpy_parts("PyReadonlyArray1<f64>") == (1, "f64")
    @test RustCall._pyo3_host_numpy_parts("PyArrayDyn<i32>") == (-1, "i32")
    @test RustCall._pyo3_host_numpy_parts("Py<PyArray2<u8>>") == (2, "u8")
    @test RustCall._pyo3_host_numpy_parts("Bound<'_, PyArray1<f64>>") == (1, "f64")
    @test RustCall._pyo3_host_numpy_parts("numpy::PyReadonlyArray3<f32>") == (3, "f32")
    @test RustCall._pyo3_host_numpy_parts("Vec<f64>") === nothing
    @test RustCall._pyo3_host_numpy_parts("PyArrayMethods") === nothing
    # The Julia side: an array argument is an `AbstractArray` the emitter wraps
    # with `numpy.asarray`; a numpy return is typed from its element.
    @test RustCall._pyo3_host_arg_type("PyReadonlyArray1<f64>") === :AbstractArray
    @test RustCall._pyo3_host_arg_type("Py<PyArray2<u8>>") === :AbstractArray
    @test RustCall._pyo3_host_value_type("Py<PyArray1<f64>>") == :(Vector{Float64})
    @test RustCall._pyo3_host_value_type("PyArray2<f32>") == :(Matrix{Float32})
    @test RustCall._pyo3_host_value_type("PyReadonlyArrayDyn<i32>") == :(Array{Int32})
end

@testset "PyO3 declarative module attribute paths (#424)" begin
    info = RustCall.scan_crate(PYO3_DECLARATIVE_CRATE)
    direct = Dict(f.name => f for f in info.pyo3_functions)
    # The top-level `#[pymodule] mod` is the imported module, so a direct item
    # is `module.direct`; a nested `#[pymodule] mod inner` contributes `inner`.
    @test direct["direct"].python_path == String[]
    @test direct["nested"].python_path == ["inner"]
    # The same for a class: `module.Gauge`, and the Python attribute path is
    # recorded on the struct, not on each method.
    gauge = only(filter(s -> s.name == "Gauge", info.pyo3_structs))
    @test gauge.python_path == String[]
    # Which fields PyO3 exposes, and in which direction, independent of `pub`.
    @test gauge.field_pyo3_get == Dict("value" => true, "label" => true)
    @test gauge.field_pyo3_set == Dict("value" => true, "label" => false)
end

@testset "an async fn is refused on the host path (#424)" begin
    info = RustCall.scan_crate(PYO3_ASYNC_CRATE)
    later = only(filter(f -> f.name == "later", info.pyo3_functions))
    # The extractor's `async_fn` reason, and the host generator's own filter.
    @test later.skip_reason == "async_fn"
    @test RustCall._pyo3_host_async(later)
    now = only(filter(f -> f.name == "now", info.pyo3_functions))
    @test !RustCall._pyo3_host_async(now)

    # The generated module carries a binding for `now` and none for `later`: a
    # binding for the coroutine would look like a value and never run (#424).
    # From a copy: the bindings come from the scan of the build's own
    # configuration, and Cargo writes a lockfile beside the manifest it probes.
    text = mktempdir() do dir
        cp(PYO3_ASYNC_CRATE, joinpath(dir, "crate"))
        string(RustCall.generate_pyo3_host_bindings(joinpath(dir, "crate")))
    end
    @test occursin("now", text)
    @test !occursin("later", text)
end

@testset "a raw PyO3 name is looked up as Python exposes it (#514)" begin
    # `#[pyfunction] fn r#for` is the Python attribute `for`, bound in Julia as
    # `for_`; the manifest's `python_name` says so (PR #515 review).
    info = RustCall.scan_crate(PYO3_HOST_CRATE)
    raw = only(filter(f -> f.name == "r#for", info.pyo3_functions))
    @test raw.python_name == "for"
    @test RustCall.julia_function_name(raw) == "for_"
    point = only(filter(s -> s.name == "Point", info.pyo3_structs))
    matched = only(filter(m -> m.name == "r#match", point.methods))
    @test matched.python_name == "match"
    classes = Dict{String, Symbol}("Point" => :Point)
    text = string(Base.remove_linenums!(Expr(:block,
        RustCall._pyo3_host_function_expr(raw, classes)...)))
    @test occursin("function for_(", text)
    # The Python attribute is `for` (spelled `var"for"` in a Julia expression).
    @test occursin(".var\"for\"(", text)
    @test !occursin("r#", text)
    text = string(RustCall.generate_pyo3_host_bindings(PYO3_HOST_CRATE))
    @test !occursin("r#", text)
    # A hand-built signature without a `python_name` is unrawed too.
    sig = RustCall.RustFunctionSignature("r#in", String[], String[], "i32", false, String[])
    @test RustCall._pyo3_host_python_name(sig.name, sig.python_name) == "in"

    # `fn r#for` beside `fn for_` is refused before anything is emitted, by the
    # clash check every emitter runs (PR #515 review).
    mktempdir() do dir
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "Cargo.toml"), """
            [package]
            name = "pyo3_host_clash"
            version = "0.1.0"
            edition = "2021"

            [lib]
            crate-type = ["cdylib"]

            [dependencies]
            pyo3 = { version = "0.29", default-features = false, features = ["macros"] }
            """)
        write(joinpath(dir, "src", "lib.rs"), """
            use pyo3::prelude::*;
            #[pyfunction]
            fn r#for(x: i32) -> i32 { x }
            #[pyfunction]
            fn for_(x: i32) -> i32 { x }
            #[pymodule]
            fn pyo3_host_clash(m: &Bound<'_, PyModule>) -> PyResult<()> {
                m.add_function(wrap_pyfunction!(r#for, m)?)?;
                m.add_function(wrap_pyfunction!(for_, m)?)?;
                Ok(())
            }
            """)
        err = try
            RustCall.generate_pyo3_host_bindings(dir)
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        msg = err === nothing ? "" : sprint(showerror, err)
        @test occursin("`for_`", msg) && occursin("r#for", msg) && occursin("#514", msg)

        # Two `#[pyclass]`es one Julia type name would bind (PR #515 review).
        write(joinpath(dir, "src", "lib.rs"), """
            use pyo3::prelude::*;
            #[pyclass]
            pub struct r#for { pub x: i32 }
            #[pyclass]
            pub struct for_ { pub y: i32 }
            #[pymodule]
            fn pyo3_host_clash(m: &Bound<'_, PyModule>) -> PyResult<()> {
                m.add_class::<r#for>()?;
                m.add_class::<for_>()?;
                Ok(())
            }
            """)
        err = try
            RustCall.generate_pyo3_host_bindings(dir)
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        msg = err === nothing ? "" : sprint(showerror, err)
        @test occursin("struct `r#for`", msg) && occursin("struct `for_`", msg)

        # The host binds a static method without its type, so it is a free
        # function: it meets a `#[pyfunction]` of its Julia name, and another
        # class's static method (PR #515 review, raised on #517).
        refusal(lib) = begin
            write(joinpath(dir, "src", "lib.rs"), lib)
            try
                RustCall.generate_pyo3_host_bindings(dir)
                ""
            catch e
                sprint(showerror, e)
            end
        end
        msg = refusal("""
            use pyo3::prelude::*;
            #[pyfunction] fn r#for(x: i32) -> i32 { x }
            #[pyclass] pub struct S { pub v: i32 }
            #[pymethods] impl S { #[staticmethod] fn for_(x: i32) -> i32 { x } }
            """)
        @test occursin("function `r#for`", msg) && occursin("method `S::for_`", msg)
        msg = refusal("""
            use pyo3::prelude::*;
            #[pyclass] pub struct S { pub v: i32 }
            #[pymethods] impl S { #[staticmethod] fn r#for(x: i32) -> i32 { x } }
            #[pyclass] pub struct T { pub v: i32 }
            #[pymethods] impl T { #[staticmethod] fn for_(x: i32) -> i32 { x } }
            """)
        @test occursin("method `S::r#for`", msg) && occursin("method `T::for_`", msg)
        # The host defines its functions before its types: a function of a
        # class's Julia name is refused too.
        msg = refusal("""
            use pyo3::prelude::*;
            #[pyfunction] fn while_(x: i32) -> i32 { x }
            #[pyclass] pub struct r#while { pub v: i32 }
            """)
        @test occursin("function `while_`", msg) && occursin("struct `r#while`", msg)
        # Instance methods of two classes are dispatch, not a clash.
        @test refusal("""
            use pyo3::prelude::*;
            #[pyclass] pub struct S { pub v: i32 }
            #[pymethods] impl S { fn r#for(&self) -> i32 { 1 } }
            #[pyclass] pub struct T { pub v: i32 }
            #[pymethods] impl T { fn for_(&self) -> i32 { 2 } }
            """) == ""
        # ... but a class's method bound under another class's name is not:
        # the method is the module-level function `for_`, the class the type
        # `for_` (PR #515 review, raised on #517).
        msg = refusal("""
            use pyo3::prelude::*;
            #[pyclass] pub struct A { pub v: i32 }
            #[pymethods] impl A { fn r#for(&self) -> i32 { 1 } }
            #[pyclass] pub struct for_ { pub v: i32 }
            """)
        @test occursin("method `A::r#for`", msg) && occursin("struct `for_`", msg)
        # Mutually exclusive `#[cfg]` variants are one item in any build: the
        # bindings come from the scan of the build's own configuration, so the
        # check sees one of them (PR #515 review).
        write(joinpath(dir, "Cargo.toml"),
              replace(read(joinpath(dir, "Cargo.toml"), String),
                      "[dependencies]" => "[features]\nx = []\n\n[dependencies]"))
        @test refusal("""
            use pyo3::prelude::*;
            #[cfg(feature = "x")]
            #[pyfunction] fn r#for(x: i32) -> i32 { x }
            #[cfg(not(feature = "x"))]
            #[pyfunction] fn for_(x: i32) -> i32 { x }
            """) == ""
        # A property is remapped to its Python attribute only for a field the
        # host binds: an unexposed raw `r#for` beside an exposed `for_` leaves
        # `obj.for_` reading `for_` (PR #515 review).
        write(joinpath(dir, "src", "lib.rs"), """
            use pyo3::prelude::*;
            #[pyclass] pub struct H { pub r#for: i32, #[pyo3(get)] pub for_: i32 }
            """)
        hidden = string(Base.remove_linenums!(RustCall.generate_pyo3_host_bindings(dir)))
        @test !occursin("s = :for", hidden)
        @test occursin("(:for_,)", hidden)

        # A raw class name in argument and return position is the class: the
        # class map is keyed by `rust_name`, the key every type spelling is
        # looked up by (PR #515 review, raised on #517).
        write(joinpath(dir, "src", "lib.rs"), """
            use pyo3::prelude::*;
            #[pyclass] pub struct r#type { pub v: i32 }
            #[pyfunction] fn make() -> r#type { r#type { v: 1 } }
            #[pyfunction] fn wrapped(py: Python<'_>) -> PyResult<Py<r#type>> { Py::new(py, r#type { v: 2 }) }
            #[pyfunction] fn read(t: PyRef<'_, r#type>) -> i32 { t.v }
            #[pyfunction] fn read_ref(t: &r#type) -> i32 { t.v }
            #[pyfunction] fn read_all(ts: Vec<PyRef<'_, r#type>>) -> usize { ts.len() }
            """)
        info = RustCall.scan_crate(dir)
        classes = RustCall._pyo3_host_classes(info)
        @test classes == Dict("type" => :type)
        for spelling in ("r#type", "&r#type", "PyRef<'_, r#type>", "Py<r#type>",
                         "Bound<'_, r#type>")
            @test RustCall._pyo3_host_struct_target(spelling, classes) === :type
            @test RustCall._pyo3_host_struct_arg(spelling, classes) == (:type, false)
        end
        @test RustCall._pyo3_host_struct_arg("Vec<PyRef<'_, r#type>>", classes) == (:type, true)
        text = string(Base.remove_linenums!(RustCall.generate_pyo3_host_bindings(dir)))
        @test occursin("type((_pyo3_module()).make())", text)
        # Every class argument is passed as the Python object the handle holds.
        @test count("isa PythonCall.Py", text) >= 3
    end
end

@testset "a one-argument #[new] cannot overwrite the default constructor (#433)" begin
    info = RustCall.scan_crate(PYO3_HOST_CRATE)
    wrapper = only(filter(s -> s.name == "Wrapper", info.pyo3_structs))
    classes = Dict{String, Symbol}("Wrapper" => :Wrapper)
    exprs = RustCall._pyo3_host_struct_exprs(wrapper, classes)
    struct_expr = only(filter(e -> e isa Expr && e.head === :struct, exprs))
    body = struct_expr.args[3]
    # The field, then an explicit inner constructor. Defining *any* inner
    # constructor stops Julia from synthesizing the untyped `Wrapper(x)` that
    # the emitted `Wrapper(obj::Any)` would otherwise overwrite — a hard error
    # during module precompilation (#433).
    @test length(body.args) >= 2
    inner = body.args[2]
    @test inner isa Expr && inner.head === :(=)
    @test inner.args[1] isa Expr && inner.args[1].head === :call &&
          inner.args[1].args[1] === :Wrapper
    @test inner.args[2] isa Expr && inner.args[2].head === :call &&
          inner.args[2].args[1] === :new
    # The public one-argument constructor is still emitted, as an outer method
    # rather than a redefinition.
    @test any(e -> e isa Expr && e.head === :function &&
                    e.args[1] isa Expr && e.args[1].head === :call &&
                    e.args[1].args[1] === :Wrapper, exprs)
end

@testset "PyO3 Python-host import (#424 Phase 1)" begin
    if !RustCall.pyo3_host_available()
        # Visible as a Broken/skipped result, not a silent pass (#464).
        @test_skip "the PyO3 Python-host import testset needs PythonCall; `using PythonCall` enables RustCallPyO3HostExt"
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
    if _numpy_available()
        # The raw module wants a real ndarray — `numpy.asarray` is the
        # conversion the typed binding below inserts (#424).
        np = PythonCall.pyimport("numpy")
        @test pyconvert(Float64, module_.array_sum(np.asarray([1.0, 2.0, 3.0]))) == 6.0
        @test pyconvert(Vector{Float64}, module_.doubled(np.asarray([1.0, 2.0]))) == [2.0, 4.0]
    else
        @test_skip "pyo3-numpy assertions need numpy in the interpreter"
    end
    # A second call must reuse the cached artifact rather than rebuild.
    again = RustCall.build_pyo3_extension(PYO3_HOST_CRATE;
                                          python = PythonCall.python_executable_path())
    @test again.lib_path == RustCall.build_pyo3_extension(
        PYO3_HOST_CRATE; python = PythonCall.python_executable_path()).lib_path
    @test isfile(again.lib_path)

    # The split hook (#449): the build is the interpreter-free half a package
    # can run ahead of time, and `pyo3_host_import(artifact)` is the import.
    imported = RustCall.pyo3_host_import(again)
    @test pyconvert(Int, imported.add(20, 22)) == 42
    # The import checks the artifact against the interpreter this process runs
    # by fingerprint, never by path alone (#449 review): another path for the
    # same interpreter is accepted; another fingerprint is refused, naming
    # both, even under the running interpreter's own path (an upgrade in
    # place).
    relabel(a; interpreter = a.interpreter, fingerprint = a.fingerprint,
            ext_suffix = a.ext_suffix) =
        RustCall.PyO3Extension(a.module_name, a.lib_path, a.dir, ext_suffix,
                               interpreter, fingerprint, a.key)
    same_by_fingerprint = relabel(again; interpreter = joinpath(mktempdir(), "python"))
    @test pyconvert(Int, RustCall.pyo3_host_import(same_by_fingerprint).add(1, 1)) == 2
    stale = "CPython|0.0.0|other|libpython0.0.so|/nowhere|True"
    # ... and a suffix the running interpreter does not tag its extensions
    # with is refused too, fingerprint or not: the import resolves by it.
    other_suffix = relabel(again; ext_suffix = ".cpython-000-nowhere.so")
    err = try
        RustCall.pyo3_host_import(other_suffix)
        nothing
    catch e
        e
    end
    @test err isa RustCall.RustError
    @test occursin(".cpython-000-nowhere.so", sprint(showerror, err))
    @test occursin(again.ext_suffix, sprint(showerror, err))
    for foreign in (relabel(again; interpreter = joinpath(mktempdir(), "python"), fingerprint = stale),
                    relabel(again; fingerprint = stale))
        err = try
            RustCall.pyo3_host_import(foreign)
            nothing
        catch e
            e
        end
        @test err isa RustCall.RustError
        @test occursin(foreign.interpreter, sprint(showerror, err))
        @test occursin(stale, sprint(showerror, err))
        @test occursin(PythonCall.python_executable_path(), sprint(showerror, err))
    end
    # The one-process probe reports what the two single probes report, so the
    # key it fills is the key the wrapper path would compute.
    python = PythonCall.python_executable_path()
    @test RustCall._pyo3_extension_interpreter_probe(python) ==
          (RustCall._pyo3_extension_ext_suffix(python),
           RustCall._python_interpreter_fingerprint(python))
    @test again.fingerprint == RustCall._python_interpreter_fingerprint(python)
end

@testset "PyO3 Python-host typed bindings (#424 Phase 2)" begin
    if !RustCall.pyo3_host_available()
        # Visible as a Broken/skipped result, not a silent pass (#464).
        @test_skip "the PyO3 Python-host typed testset needs PythonCall; `using PythonCall` enables RustCallPyO3HostExt"
        return
    end
    bindings = RustCall.load_crate_bindings(PYO3_HOST_CRATE; pyo3_host = true)

    @test bindings.add(Int32(2), Int32(3)) == 5
    # A raw Rust name, exposed by PyO3 without its `r#` (#514).
    @test bindings.for_(Int32(2)) == 3
    # `not_public` to the C-ABI scan; registered by the crate's own `#[pymodule]`.
    @test bindings.private_add(4, 5) == 9
    # `pyo3_type:Python<'_>` to the C-ABI scan; the injected token is dropped
    # from the Julia signature.
    @test bindings.interpreter_token() == 7

    point = bindings.Point(3.0, 4.0)
    @test bindings.norm(point) == 5.0
    @test bindings.match(point) == 7.0
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

    # PyO3's default is supplied by its own dispatcher: one Julia method per
    # arity, so the omitted argument is never invented here.
    @test bindings.add_default(5) == 15
    @test bindings.add_default(5, 1) == 6

    # The type-level behaviour, through the generated module directly (what a
    # package reaches with `using .Bindings: Point, ...`; the `CrateBindings`
    # proxy re-wraps objects and is not type-transparent).
    M = bindings.module_ref
    p34 = M.Point(3.0, 4.0)                           # norm 5
    @test M.scaled_by(p34, 2.0).value == 10.0
    @test M.scaled_by(p34, 2.0, 1.0).value == 11.0

    # A class-typed return is wrapped into the Julia struct, and a class-typed
    # argument is passed as the Python object the handle holds.
    p64 = M.Point(6.0, 4.0)
    mirrored = M.mirrored(p64)
    @test mirrored isa M.Point
    @test (mirrored.x, mirrored.y) == (-6.0, -4.0)
    @test M.distance_to(p64, M.origin()) == sqrt(52)
    @test M.distance_to(p64, mirrored) == sqrt(208)

    # A `Vec` of class references.
    @test M.total_norm([p34, M.origin()]) == 5.0

    if _numpy_available()
        # The typed binding converts the Julia array and the numpy return.
        @test bindings.array_sum([1.0, 2.0, 3.0]) == 6.0
        @test bindings.doubled([1.0, 2.0]) == [2.0, 4.0]
    end

    # A Python callable argument: a Julia function reaches Python as a
    # callable (PythonCall wraps it), and the binding passes it through (#424).
    applied = bindings.apply_twice(x -> x + 1, Int32(5))
    @test applied isa RustCall.RustResult{Int32, String}
    @test applied.is_ok && applied.value == 7

    # A `Py<PyAny>` return has no Julia type, so the binding keeps the
    # interpreter object rather than inventing one (#424).
    obj = PythonCall.pyimport("builtins").list([1, 2, 3])
    echoed = bindings.echo_object(obj)
    @test echoed isa PythonCall.Py
    @test pyconvert(Vector{Int}, echoed) == [1, 2, 3]

    # A `#[classmethod]`: Python's bound descriptor passes the class, so the
    # binding takes no `cls` argument and calls through the class object (#424).
    named = bindings.named_origin()
    @test (named.x, named.y) == (0.0, 0.0)

    # `#[pyo3(pass_module)]`: PyO3 injects the module, so the binding takes no
    # argument for it (#424).
    @test bindings.module_name() == "sample_crate_pyo3_host"

    # A one-argument `#[new]` mapping to `Any` (#433): the public constructor
    # reaches the class, and no synthesized constructor is overwritten. Through
    # the generated module, which is type-transparent (the proxy re-wraps).
    made = bindings.module_ref.Wrapper(41)
    @test made.is_ok
    wrapper = made.value
    @test wrapper.value == 41
    @test bindings.module_ref.tag(wrapper) == "wrapper:41"
end

@testset "PyO3 Python-host declarative modules (#424)" begin
    if !RustCall.pyo3_host_available()
        # Visible as a Broken/skipped result, not a silent pass (#464).
        @test_skip "the PyO3 declarative-module testset needs PythonCall; `using PythonCall` enables RustCallPyO3HostExt"
        return
    end
    bindings = RustCall.load_crate_bindings(PYO3_DECLARATIVE_CRATE; pyo3_host = true)

    # A direct item of the declarative module is `module.direct`.
    @test bindings.direct(3) == 6
    # A nested `#[pymodule] mod inner` is `module.inner.nested`.
    @test bindings.nested(3) == 103
    # The raw import proves the attribute path the binding used.
    module_ = RustCall.pyo3_host_import(PYO3_DECLARATIVE_CRATE)
    @test pyconvert(Int, module_.inner.nested(3)) == 103

    gauge = bindings.Gauge(5, "g")
    @test gauge.value == 5
    @test gauge.label == "g"
    # A `#[getter]` method is a Python property; `getproperty` reaches it.
    @test pyconvert(Int, gauge.doubled) == 10
    # Which fields answer, and in which direction, comes from the manifest; a
    # get-only field is readable and not writable (#424).
    @test :value in propertynames(gauge)
    @test :label in propertynames(gauge)
    gauge.value = 7
    @test gauge.value == 7
    @test_throws ArgumentError (gauge.label = "h")
end

@testset "PyO3 Python-host @rust_crate dispatch (#424 Phase 3)" begin
    if !RustCall.pyo3_host_available()
        # Visible as a Broken/skipped result, not a silent pass (#464).
        @test_skip "the PyO3 Python-host macro testset needs PythonCall; `using PythonCall` enables RustCallPyO3HostExt"
        return
    end
    Host = @rust_crate PYO3_HOST_CRATE pyo3_host = true
    @test Host.add(Int32(2), Int32(3)) == 5
    @test Host.Point(3.0, 4.0).x == 3.0
end

# The first call of a generated host binding compiles nothing of RustCall's or
# of the extension's (#449): the hook's keyword entry point, the build and the
# import all come from the package images. A child process, because the
# property is about a fresh session; `--trace-compile` prints what is compiled
# at run time, and none of it may be the hook. The generated module itself is
# expected there — it is evaluated in the child.
@testset "a generated host call is served from the images (#449)" begin
    if !RustCall.pyo3_host_available()
        # Visible as a Broken/skipped result, not a silent pass (#464).
        @test_skip "the generated-host image testset needs PythonCall; `using PythonCall` enables RustCallPyO3HostExt"
        return
    end
    # Build first, in this process, so the child measures a warm cache.
    RustCall.build_pyo3_extension(PYO3_HOST_CRATE;
                                  python = PythonCall.python_executable_path())
    trace = tempname()
    script = """
        using RustCall, PythonCall
        @rust_crate $(repr(abspath(PYO3_HOST_CRATE))) submodule="Bindings" pyo3_host=true
        Bindings.add(Int32(2), Int32(3))
        """
    # Coverage off in the child, for the reason `test_precompile.jl` gives.
    cmd = `$(Base.julia_cmd()) --startup-file=no --code-coverage=none --project=$(Base.active_project()) --trace-compile=$trace -e $script`
    @test success(pipeline(cmd; stdout = devnull, stderr = stderr))
    compiled = isfile(trace) ? readlines(trace) : String[]
    leaked = filter(line -> occursin("pyo3_host_import", line) ||
                            occursin("RustCallPyO3HostExt", line) ||
                            occursin("RustCall.build_pyo3_extension", line) ||
                            occursin("RustCall.scan_crate", line), compiled)
    @test isempty(leaked)
    isempty(leaked) || foreach(println, leaked)
    rm(trace; force = true)
end

@testset "a one-argument #[new] precompiles (#433)" begin
    if !RustCall.pyo3_host_available()
        # Visible as a Broken/skipped result, not a silent pass (#464).
        @test_skip "the one-argument #[new] precompile testset needs PythonCall; `using PythonCall` enables RustCallPyO3HostExt"
        return
    end
    # Overwriting a method is only a warning outside precompilation; Julia
    # *refuses* it while precompiling a package. So the regression this fixes
    # has to be a package that is actually precompiled — asserting on the
    # emitted expression alone would not have caught it.
    root = mktempdir()
    pkg_name = "PyO3HostOneArg433_$(basename(root))"
    pkg_uuid = "8f0c5e2a-6b41-4d7e-9a3c-2e5b7c1d4f60"
    pkgdir_ = joinpath(root, pkg_name)
    mkpath(joinpath(pkgdir_, "src"))
    write(joinpath(pkgdir_, "Project.toml"), """
    name = "$pkg_name"
    uuid = "$pkg_uuid"
    version = "0.1.0"

    [deps]
    PythonCall = "$(Base.PkgId(PythonCall).uuid)"
    RustCall = "$(Base.PkgId(RustCall).uuid)"
    """)
    write(joinpath(pkgdir_, "src", "$pkg_name.jl"), """
    module $pkg_name
    using RustCall
    using PythonCall
    @rust_crate $(repr(abspath(PYO3_HOST_CRATE))) submodule="Bindings" pyo3_host=true
    using .Bindings: Wrapper
    export Wrapper
    end
    """)
    # The temp package is a package-directory environment on the load path; the
    # active project supplies RustCall and PythonCall (this testset only runs
    # when PythonCall is loaded).
    project = dirname(Base.active_project())
    sep = Sys.iswindows() ? ";" : ":"
    out = withenv("JULIA_LOAD_PATH" => join((project, root, "@stdlib"), sep)) do
        readchomp(pipeline(`$(Base.julia_cmd()) --startup-file=no -e $("""
            using $pkg_name
            w = Wrapper(41)
            print(w.value.value, " ", Base.isprecompiled(Base.identify_package($(repr(pkg_name)))))
            """)`; stderr = stderr))
    end
    @test out == "41 true"
end
