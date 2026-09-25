# A Rust argument whose name is a Julia keyword gets a usable parameter (#516).
#
# `#[julia] fn f(end: i32)` or `fn g(r#for: &str)` is legal Rust, and the
# generated wrapper used to take a parameter spelled `end` / `r#for`, so the
# file `write_bindings_to_file` writes did not parse. `julia_parameter_names`
# now decides every generated parameter name, once, in the
# `RustFunctionSignature` / `RustMethod` constructors: a name goes through
# `julia_binding_name` (`end` → `end_`), a pattern or `_` is named after its
# position, and a name another parameter already has gets further underscores.

using Test
using RustCall
using RustToolChain: cargo

const KWARG_MACROS_PATH = joinpath(dirname(@__DIR__), "deps", "rustcall_julia_macros")

const _KWARG_HAVE_CARGO = try
    success(run(pipeline(`$(cargo()) --version`, devnull, devnull); wait = true))
catch
    false
end

# Every argument shape a wrapper plans differently, each named like a Julia
# keyword: by value, `&str`, a callback, `Result` and `Option` returns, a
# renamed name beside the name it is renamed to (`end`, `end_`), a raw name
# beside a generated local's (`r#func_ptr`), an inherent method, a static
# method and a trait method.
const KWARG_ITEMS = """
    pub trait Tr {
        fn scaled(&self, r#in: i32) -> i32;
    }

    #[julia]
    pub fn add(end: i32, r#for: i32) -> i32 {
        end + r#for
    }

    #[julia]
    pub fn both(end: i32, end_: i32) -> i32 {
        end * 10 + end_
    }

    #[julia]
    pub fn local_names(r#func_ptr: i32, panic_channel: i32) -> i32 {
        r#func_ptr - panic_channel
    }

    #[julia]
    pub fn count(function: &str) -> usize {
        function.len()
    }

    #[julia]
    pub fn apply(quote: extern "C" fn(i64) -> i64, begin: i64) -> i64 {
        quote(begin)
    }

    #[julia]
    pub fn checked(r#do: i32) -> Result<i32, String> {
        if r#do >= 0 { Ok(r#do * 2) } else { Err("negative".to_string()) }
    }

    #[julia]
    pub fn maybe(r#let: i32) -> Option<i32> {
        if r#let > 0 { Some(r#let + 1) } else { None }
    }

    #[julia]
    pub struct Acc {
        pub total: i32,
    }

    #[julia]
    impl Acc {
        #[julia]
        pub fn new(r#type: i32) -> Self {
            Acc { total: r#type }
        }
        #[julia]
        pub fn bump(&mut self, end: i32, end_: i32) -> i32 {
            self.total += end * 10 + end_;
            self.total
        }
        #[julia]
        pub fn label(&self, r#where: &str) -> usize {
            r#where.len() + self.total as usize
        }
        #[julia]
        pub fn make(module: i32) -> i32 {
            module * 3
        }
    }

    #[julia]
    impl Tr for Acc {
        #[julia]
        fn scaled(&self, r#in: i32) -> i32 {
            self.total * r#in
        }
    }
    """

function _kwarg_write_crate(dir::AbstractString)
    mkpath(joinpath(dir, "src"))
    macros = replace(KWARG_MACROS_PATH, "\\" => "/")
    write(joinpath(dir, "Cargo.toml"), """
        [package]
        name = "kw_arguments"
        version = "0.1.0"
        edition = "2021"

        [lib]
        crate-type = ["cdylib"]

        [dependencies]
        rustcall_julia_macros = { path = "$macros" }

        [workspace]
        """)
    write(joinpath(dir, "src", "lib.rs"), "use rustcall_julia_macros::julia;\n\n" * KWARG_ITEMS)
end

# Every call a bound module must answer, `get` resolving a binding by name.
function _kwarg_exercise(get; trait::Bool = true)
    call = Base.invokelatest
    @test call(get(:add), Int32(1), Int32(2)) == 3
    @test call(get(:both), Int32(1), Int32(2)) == 12
    @test call(get(:local_names), Int32(7), Int32(2)) == 5
    @test call(get(:count), "abcd") == 4
    @test call(get(:apply), x -> x + 1, Int64(41)) == 42
    # `rust"""` returns the `RustResult` / `RustOption`; a crate module unwraps.
    value(x) = x isa Union{RustCall.RustResult, RustCall.RustOption} ? RustCall.unwrap(x) : x
    failed(f) = try
        r = f()
        r isa RustCall.RustResult && !r.is_ok
    catch
        true
    end
    none(x) = x === nothing || (x isa RustCall.RustOption && !x.is_some)
    @test value(call(get(:checked), Int32(3))) == 6
    @test failed(() -> call(get(:checked), Int32(-1)))
    @test value(call(get(:maybe), Int32(1))) == 2
    @test none(call(get(:maybe), Int32(0)))
    a = call(get(:Acc), Int32(5))
    @test call(get(:bump), a, Int32(1), Int32(2)) == 17
    @test call(get(:label), a, "xy") == 19
    @test call(get(:make), get(:Acc), Int32(2)) == 6
    trait && @test call(get(:scaled), a, Int32(2)) == 34
end

# The parameter list of every generated `function <name>(...)` in `content`.
function _kwarg_params(content::AbstractString, name::AbstractString)
    lines = filter(l -> startswith(lstrip(l), "function $(name)("), split(content, '\n'))
    return [strip(l) for l in lines]
end

@testset "julia_parameter_names decides every parameter name (#516)" begin
    names = RustCall.julia_parameter_names
    @test names(String[]) == String[]
    @test names(["x", "y"]) == ["x", "y"]
    @test names(["end", "r#for", "function", "r#type"]) == ["end_", "for_", "function_", "type"]
    # A renamed argument yields to one that needs no change, in either order.
    @test names(["end", "end_"]) == ["end__", "end_"]
    @test names(["end_", "end"]) == ["end_", "end__"]
    @test names(["end", "end_", "end__"]) == ["end___", "end_", "end__"]
    # A pattern, `_`, or a spelling with no Julia identifier is named by position.
    @test names(["_", "(a, b)", "x"]) == ["arg1", "arg2", "x"]
    @test names(["_", "arg1"]) == ["arg1_", "arg1"]
    # Every result parses as a distinct plain identifier, and the function is
    # idempotent — a record rebuilt from its own names is unchanged.
    for input in (["end", "end_", "r#end", "for", "_", "__"],
                  ["begin", "r#begin", "begin_", "begin__"])
        out = names(input)
        @test allunique(out)
        @test all(n -> Meta.parse(n) === Symbol(n), out)
        @test names(out) == out
    end
    # The constructors apply it, so every emitter reads the same names.
    sig = RustCall.RustFunctionSignature("f", ["end", "end_"], ["i32", "i32"], "i32", false, String[])
    @test sig.arg_names == ["end__", "end_"]
    m = RustCall.RustMethod("m", false, false, ["r#for"], ["i32"], "i32")
    @test m.arg_names == ["for_"]
    # A generated local is chosen against the Julia names: `r#func_ptr` is the
    # parameter `func_ptr`, so the local is prefixed.
    raw = RustCall.RustFunctionSignature("g", ["r#func_ptr"], ["i32"], "i32", false, String[])
    @test RustCall._generated_local("func_ptr", raw.arg_names) != :func_ptr
    # The PyO3 host reads the same names.
    scalar = RustCall.PyO3Shape(:scalar, "i32")
    py = RustCall.RustFunctionSignature("h", ["end", "r#for"], ["i32", "i32"], "i32", false, String[];
                                        attribute = :py_function,
                                        py_arg_shapes = Union{Nothing, RustCall.PyO3Shape}[scalar, scalar],
                                        py_return_shape = scalar)
    @test first(RustCall._pyo3_host_args(py.arg_names, py.py_arg_shapes, py.python_defaults,
                                         py.python_kinds)) == [:end_, :for_]
end

@testset "rust\"\"\" binds keyword-named arguments (#516)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc not available"
    else
        m = Module(:KwArgInlineBlock)
        Core.eval(m, :(using RustCall))
        Core.eval(m, Meta.parse("rust\"\"\"\n" * KWARG_ITEMS * "\n\"\"\""))
        # An inline block binds no trait impl's methods.
        _kwarg_exercise(n -> Base.invokelatest(getfield, m, n); trait = false)
        # Generics: a monomorphized function, and a generic struct's methods,
        # whose wrappers are emitted per instantiation.
        g = Module(:KwArgInlineGeneric)
        Core.eval(g, :(using RustCall))
        Core.eval(g, Meta.parse("""rust\"\"\"
            #[julia]
            pub fn kw_twice<T: Copy + std::ops::Add<Output = T>>(end: T) -> T { end + end }

            #[julia]
            pub struct KwBox<T> { v: T }

            impl<T: Copy + std::ops::Add<Output = T>> KwBox<T> {
                pub fn new(r#type: T) -> Self { Self { v: r#type } }
                pub fn plus(&self, end: T, end_: T) -> T { self.v + end + end_ }
                pub fn tagged(&self, r#for: &str) -> usize { r#for.len() }
            }
            \"\"\""""))
        @test RustCall.call_generic_function("kw_twice", Int32(4)) == 8
        box = Base.invokelatest(Base.invokelatest(getfield, g, :KwBox){Int32}, Int32(1))
        @test Base.invokelatest(Base.invokelatest(getfield, g, :plus), box, Int32(2), Int32(3)) == 6
        @test Base.invokelatest(Base.invokelatest(getfield, g, :tagged), box, "abc") == 3
    end
end

@testset "@rust_crate and write_bindings_to_file bind keyword-named arguments (#516)" begin
    if !_KWARG_HAVE_CARGO || !RustCall.check_rustc_available()
        @test_skip "cargo/rustc not available"
    else
        @testset "through @rust_crate" begin
            mktempdir() do dir
                _kwarg_write_crate(dir)
                bindings = @rust_crate dir name = "KwArgBindings"
                mod = getfield(bindings, :module_ref)
                _kwarg_exercise(n -> Base.invokelatest(getfield, mod, n))
                try
                    RustCall.unload_library(Base.invokelatest(getfield, mod, :_LIB_NAME); close = true)
                catch
                end
            end
        end

        @testset "through a file written by write_bindings_to_file" begin
            mktempdir() do dir
                _kwarg_write_crate(dir)
                output_path = joinpath(dir, "KwArgs.jl")
                RustCall.write_bindings_to_file(dir, output_path;
                                                output_module_name = "KwArgsWritten")
                content = read(output_path, String)
                parsed = Meta.parseall(content)
                @test !any(ex -> ex isa Expr && ex.head in (:error, :incomplete), parsed.args)
                # No parameter is spelled as the keyword or the raw name.
                @test _kwarg_params(content, "add") == ["function add(end_, for_)"]
                @test _kwarg_params(content, "both") == ["function both(end__, end_)"]
                @test _kwarg_params(content, "apply") == ["function apply(quote_, begin_)"]
                @test _kwarg_params(content, "bump") == ["function bump(rustcall′self::Acc, end__, end_)"]
                @test all(l -> startswith(lstrip(l), "#") || !occursin("r#", l),
                          split(content, '\n'))
                # `apply` takes a callback *followed by* another argument: the
                # written call parenthesizes its `@cfunction`, so it loads.
                sandbox = Module(:KwArgsSandbox)
                Base.include(sandbox, output_path)
                mod = Base.invokelatest(getfield, sandbox, :KwArgsWritten)
                _kwarg_exercise(n -> Base.invokelatest(getfield, mod, n))
                try
                    RustCall.unload_library(Base.invokelatest(getfield, mod, :_LIB_NAME); close = true)
                catch
                end
            end
        end
    end
end

@testset "the PyO3 host binds keyword-named arguments (#516)" begin
    # Scanned and emitted without Python: the host reads the same names.
    mktempdir() do dir
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "Cargo.toml"), """
            [package]
            name = "pyo3_host_kwargs"
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
            fn both(end: i32, end_: i32, r#for: i32) -> i32 { end + end_ + r#for }
            #[pymodule]
            fn pyo3_host_kwargs(m: &Bound<'_, PyModule>) -> PyResult<()> {
                m.add_function(wrap_pyfunction!(both, m)?)?;
                Ok(())
            }
            """)
        info = RustCall.scan_crate(dir)
        f = only(filter(f -> f.name == "both", info.pyo3_functions))
        @test f.arg_names == ["end__", "end_", "for_"]
        text = string(Base.remove_linenums!(Expr(:block,
            RustCall._pyo3_host_function_expr(f)...)))
        @test occursin("function both(end__, end_, for_)", text)
        @test !occursin("var\"end\"", text) && !occursin("r#", text)
    end
end
