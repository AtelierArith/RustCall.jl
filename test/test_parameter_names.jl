# A Rust parameter named like something a generated wrapper uses (#526).
#
# A wrapper names its parameters after the Rust ones (`julia_parameter_names`,
# #516), and its body reads names of its own: the helpers of the generated
# module (`_call_target`, `_guard_panic`, `_pyo3_module`), Base functions
# (`pointer`, `sizeof`, `getfield`), the PyO3 host's receiver `obj`. A
# parameter spelled like one of them shadowed it — `fn echo(pointer: &str)`
# made the `@rust_crate` wrapper call its own argument, and a PyO3 method
# `fn m(&self, obj: i32)` gave a wrapper two parameters named `obj`, which does
# not even define. The one allocator reserves those names —
# `RustCall._JULIA_EMITTER_NAMES`, the `CResult_` / `COption_` aggregates, and
# the types the item's own crate or block defines (a struct `foo` is a name a
# wrapper reads, a parameter `Foo` is not; PR #527 review) — and this file
# derives the set from what the emitters actually emit, so an emitter that
# starts reading a new name fails here until the name is reserved.

using Test
using RustCall
using RustToolChain: cargo

const PN = RustCall
const PN_MACROS_PATH = joinpath(dirname(@__DIR__), "deps", "rustcall_julia_macros")
const PN_HAVE_CARGO = try
    success(run(pipeline(`$(cargo()) --version`, devnull, devnull); wait = true))
catch
    false
end

# ----------------------------------------------------------------------------
# A small reader of generated definitions: each `function` with its parameters,
# and the names its body binds and reads.
# ----------------------------------------------------------------------------

_pn_unesc(x) = x isa Expr && x.head === :escape ? x.args[1] : x

function _pn_param(a)
    a = _pn_unesc(a)
    a isa Symbol && return a
    a isa Expr || return nothing
    if a.head in (:(::), :kw, :(...), :(=))
        a.head === :(::) && length(a.args) == 1 && return nothing
        return _pn_param(a.args[1])
    end
    return nothing
end

function _pn_params(call::Expr)
    out = Symbol[]
    for a in call.args[2:end]
        if a isa Expr && a.head === :parameters
            append!(out, filter(!isnothing, map(_pn_param, a.args)))
        else
            p = _pn_param(a)
            p === nothing || push!(out, p)
        end
    end
    return out
end

# Every `function` definition in `x` whose signature is a call, with its body.
function _pn_defs(x, out = Tuple{Expr, Any}[])
    x isa Expr || return out
    if x.head in (:function, :(=)) && length(x.args) == 2
        sig = x.args[1]
        while sig isa Expr && sig.head in (:where, :(::))
            sig = sig.args[1]
        end
        sig isa Expr && sig.head === :call && push!(out, (sig, x.args[2]))
    end
    foreach(a -> _pn_defs(a, out), x.args)
    return out
end

# The names a body binds (assignments, loop / comprehension / `let` variables,
# a `catch` variable, lambda parameters) and the names it reads or calls.
# Escaped expressions are the caller's; a hygienic `rust"""` expansion binds
# and reads its own names in a scope a parameter cannot reach, so only the
# escaped part of such a body is read.
function _pn_body!(x, bound, read)
    x isa Symbol && (push!(read, x); return)
    x isa Expr || return
    h = x.head
    if h === :escape
        _pn_body!(x.args[1], bound, read)
    elseif h === :(=) && _pn_unesc(x.args[1]) isa Symbol
        push!(bound, _pn_unesc(x.args[1]))
        _pn_body!(x.args[2], bound, read)
    elseif h === :(=) && x.args[1] isa Expr && x.args[1].head === :tuple
        foreach(s -> _pn_unesc(s) isa Symbol && push!(bound, _pn_unesc(s)), x.args[1].args)
        _pn_body!(x.args[2], bound, read)
    elseif h === :try
        _pn_body!(x.args[1], bound, read)
        length(x.args) >= 2 && x.args[2] isa Symbol && push!(bound, x.args[2])
        foreach(a -> _pn_body!(a, bound, read), x.args[3:end])
    elseif h in (:generator, :for, :let)
        foreach(a -> _pn_body!(a, bound, read), x.args)
    elseif h === :(->)
        a = x.args[1]
        a isa Symbol && push!(bound, a)
        a isa Expr && foreach(s -> s isa Symbol && push!(bound, s), a.args)
        _pn_body!(x.args[2], bound, read)
    elseif h === :.
        _pn_body!(x.args[1], bound, read)
    elseif h in (:quote, :inert, :function, :line, :meta)
        return
    elseif h === :macrocall
        foreach(a -> _pn_body!(a, bound, read), x.args[3:end])
    else
        foreach(a -> _pn_body!(a, bound, read), x.args)
    end
end

# Whether an expression is a hygienic macro expansion (`rust"""`): its
# parameters are escaped, and only escaped names can meet them.
_pn_hygienic(sig::Expr) = any(a -> a isa Expr && a.head === :escape, sig.args[2:end])

function _pn_escaped_body!(x, bound, read)
    x isa Expr || return
    if x.head === :escape
        _pn_body!(x.args[1], bound, read)
    else
        foreach(a -> _pn_escaped_body!(a, bound, read), x.args)
    end
end

# `(parameters, names bound, names read)` of every definition that takes `name`.
function _pn_wrappers(expr, name::Symbol)
    out = []
    for (sig, body) in _pn_defs(expr)
        params = _pn_params(sig)
        name in params || continue
        bound, read = Set{Symbol}(), Set{Symbol}()
        _pn_hygienic(sig) ? _pn_escaped_body!(body, bound, read) : _pn_body!(body, bound, read)
        push!(out, (sig, params, bound, read))
    end
    return out
end

# ----------------------------------------------------------------------------
# The emitters, over a corpus of signatures with one parameter named `n`.
# ----------------------------------------------------------------------------

_pn_julia_source(n) = """
    #[julia] pub fn f_plain($n: i32) -> i32 { $n }
    #[julia] pub fn f_float($n: f64) -> f64 { $n }
    #[julia] pub fn f_bool($n: bool) -> bool { $n }
    #[julia] pub fn f_string($n: &str) -> String { $n.to_string() }
    #[julia] pub fn f_owned($n: String) -> usize { $n.len() }
    #[julia] pub fn f_str($n: i32) -> &'static str { "x" }
    #[julia] pub fn f_result($n: i32) -> Result<i32, String> { Ok($n) }
    #[julia] pub fn f_result_string($n: &str) -> Result<String, String> { Ok($n.to_string()) }
    #[julia] pub fn f_option($n: i32) -> Option<i32> { Some($n) }
    #[julia] pub fn f_option_string($n: i32) -> Option<String> { None }
    #[julia] pub fn f_unit($n: i32) { let _ = $n; }
    #[julia] pub fn f_cb($n: extern "C" fn(i32) -> i32) -> i32 { $n(1) }
    #[julia] pub fn f_ptr($n: *const u8) -> usize { $n as usize }
    #[julia] pub fn f_struct($n: &S) -> i32 { $n.v }
    #[julia] pub struct S { pub v: i32 }
    #[julia] impl S {
    #[julia] pub fn new($n: i32) -> Self { S { v: $n } }
    #[julia] pub fn m(&self, $n: i32) -> i32 { self.v + $n }
    #[julia] pub fn m_mut(&mut self, $n: i32) { self.v = $n; }
    #[julia] pub fn m_string(&self, $n: &str) -> String { $n.to_string() }
    #[julia] pub fn m_str(&self, $n: i32) -> &str { "x" }
    #[julia] pub fn m_result(&self, $n: i32) -> Result<i32, String> { Ok($n) }
    #[julia] pub fn m_option(&self, $n: i32) -> Option<i32> { Some($n) }
    #[julia] pub fn m_self(&self, $n: i32) -> S { S { v: $n } }
    #[julia] pub fn m_cb(&self, $n: extern "C" fn(i32) -> i32) -> i32 { $n(self.v) }
    #[julia] pub fn st($n: i32) -> i32 { $n }
    #[julia] pub fn st_self($n: i32) -> Self { S { v: $n } }
    }
    """

_pn_generic_source(n) = """
    #[julia] pub struct G<T> { pub v: T }
    impl<T: Copy> G<T> {
        pub fn new($n: T) -> Self { G { v: $n } }
        pub fn m(&self, $n: T) -> T { $n }
    }
    #[julia] pub fn g<T: Copy>($n: T) -> T { $n }
    """

_pn_pyo3_source(n) = """
    use pyo3::prelude::*;
    #[pyfunction] fn pf($n: i32) -> i32 { $n }
    #[pyfunction] #[pyo3(signature = ($n = 1))] fn pf_default($n: i32) -> i32 { $n }
    #[pyfunction] fn pf_result($n: &str) -> PyResult<i32> { Ok($n.len() as i32) }
    #[pyfunction] fn pf_class($n: PyRef<'_, P>) -> i32 { $n.v }
    #[pyfunction] fn pf_classes($n: Vec<PyRef<'_, P>>) -> usize { $n.len() }
    #[pyclass] pub struct P { v: i32 }
    #[pymethods] impl P {
        #[new] fn new($n: i32) -> Self { P { v: $n } }
        fn m(&self, $n: i32) -> i32 { self.v + $n }
        fn m_res(&self, $n: i32) -> PyResult<i32> { Ok($n) }
        fn m_self(&self, $n: i32) -> P { P { v: $n } }
        fn m_class(&self, $n: PyRef<'_, P>) -> i32 { $n.v }
        #[pyo3(signature = ($n = 2))] fn m_default(&self, $n: i32) -> i32 { $n }
        fn m_array(&self, $n: numpy::PyReadonlyArray1<'_, f64>) -> f64 { $n.as_array().sum() }
        #[staticmethod] fn st($n: i32) -> i32 { $n }
    }
    """

function _pn_inline(src)
    m = PN.extract_manifest(src; mode = "inline")
    structs, functions = PN._inline_wrapper_exprs(PN.manifest_function_signatures(m),
                                                 PN.manifest_struct_infos(m))
    return Expr(:block, structs..., functions)
end

function _pn_crate(src)
    m = PN.extract_manifest(src; mode = "crate")
    a, b, c = PN._crate_wrapper_exprs(PN._module_tree(PN.manifest_function_signatures(m),
                                                      PN.manifest_struct_infos(m)))
    return Expr(:block, a, b, c...)
end

function _pn_write_crate(dir, lib; name, pyo3 = false)
    mkpath(joinpath(dir, "src"))
    macros = replace(PN_MACROS_PATH, "\\" => "/")
    dep = pyo3 ? "pyo3 = { version = \"0.29\", default-features = false, features = [\"macros\"] }\n" *
                 "numpy = \"0.29\"" :
                 "rustcall_julia_macros = { path = \"$macros\" }"
    write(joinpath(dir, "Cargo.toml"), """
        [package]
        name = "$name"
        version = "0.1.0"
        edition = "2021"

        [lib]
        crate-type = ["cdylib"]

        [dependencies]
        $dep
        """)
    write(joinpath(dir, "src", "lib.rs"), lib)
end

function _pn_text(dir, src)
    _pn_write_crate(dir, "use rustcall_julia_macros::julia;\n" * src; name = "pn_text")
    info = PN.scan_crate(dir)
    return Meta.parseall(PN.emit_crate_module_code(info, joinpath(dir, "libpn_text.so")))
end

function _pn_pyo3(dir, src)
    _pn_write_crate(dir, src; name = "pn_pyo3", pyo3 = true)
    info = PN.scan_crate(dir)
    classes = PN._pyo3_host_classes(info)
    out = Any[]
    for f in PN._pyo3_host_bound_functions(info)
        append!(out, PN._pyo3_host_function_expr(f, classes))
    end
    for s in PN._pyo3_host_bound_classes(info)
        append!(out, PN._pyo3_host_struct_exprs(s, classes))
    end
    return Expr(:block, out...)
end

function _pn_emitters(textdir, pyodir)
    return [
        ("rust\"\"\"", n -> _pn_inline(_pn_julia_source(n))),
        ("rust\"\"\" generic struct", n -> _pn_inline(_pn_generic_source(n))),
        ("@rust_crate", n -> _pn_crate(_pn_julia_source(n))),
        ("write_bindings_to_file", n -> _pn_text(textdir, _pn_julia_source(n))),
        ("pyo3_host", n -> _pn_pyo3(pyodir, _pn_pyo3_source(n))),
    ]
end

# The names the allocator reserves for an emitter's corpus: the manifest's own
# definitions (`_manifest_reserved_names`), as the constructors are given them.
function _pn_reserved(label, n)
    src = label == "rust\"\"\" generic struct" ? _pn_generic_source(n) :
          label == "pyo3_host" ? _pn_pyo3_source(n) : _pn_julia_source(n)
    mode = startswith(label, "rust") ? "inline" : "crate"
    return PN._manifest_reserved_names(PN.extract_manifest(src; mode))
end

# The plain names an emitter's output defines: its functions and types.
function _pn_defined(expr, out = Set{String}())
    expr isa Expr || return out
    if expr.head === :struct
        name = expr.args[2]
        name isa Expr && name.head === :curly && (name = name.args[1])
        name isa Expr && name.head === :escape && (name = name.args[1])
        name isa Symbol && push!(out, String(name))
    end
    foreach(a -> _pn_defined(a, out), expr.args)
    return out
end

# A name a parameter could meet in a wrapper: a plain identifier, not one the
# allocator hands out itself for a parameter it renamed (`zqx`).
_pn_identifier(s::Symbol) = Base.isidentifier(s) && Meta.parse(String(s); raise = false) isa Symbol

@testset "julia_parameter_names reserves the emitters' own names (#526)" begin
    names = PN.julia_parameter_names
    @test names(["obj", "pointer", "x"]) == ["obj_", "pointer_", "x"]
    @test names(["getfield", "sizeof", "nothing"]) == ["getfield_", "sizeof_", "nothing_"]
    # A type name the wrappers read is reserved; any other capitalised name is
    # kept as written (PR #527 review: lowering `Foo` onto a struct `foo`
    # shadowed it).
    @test names(["Int32", "Foo"]) == ["Int32_", "Foo"]
    @test names(["CResult_f", "COption_g"]) == ["arg_CResult_f", "arg_COption_g"]
    # The item's own types are reserved by the caller, which knows them.
    @test names(["foo", "Foo"]; reserved = ["foo"]) == ["foo_", "Foo"]
    @test names(["S", "s"]; reserved = ["S"]) == ["S_", "s"]
    # A name kept as written still wins over a renamed one.
    @test names(["obj", "obj_"]) == ["obj__", "obj_"]
    # Idempotent, and never a reserved name.
    for input in (["obj", "pointer", "S", "s", "end"], ["_call_target", "_guard_panic"],
                  collect(PN._JULIA_EMITTER_NAMES))
        out = names(input; reserved = ["S"])
        @test names(out; reserved = ["S"]) == out
        @test !any(n -> n in PN._JULIA_EMITTER_NAMES || n == "S", out)
        @test allunique(out)
    end
    # The manifest's own types are what the constructors are given.
    m = PN.extract_manifest("""
        #[julia] pub struct foo { pub v: i32 }
        #[julia] impl foo {
            #[julia] pub fn new(Foo: i32, foo: i32) -> Self { foo { v: Foo + foo } }
        }
        #[julia] pub fn make(foo: i32, Foo: i32) -> i32 { foo + Foo }
        """; mode = "crate")
    @test only(PN.manifest_function_signatures(m)).arg_names == ["foo_", "Foo"]
    @test only(only(PN.manifest_struct_infos(m)).methods).arg_names == ["Foo", "foo_"]
end

if !PN_HAVE_CARGO || !PN.check_rustc_available()
    @testset "wrapper parameters never meet the wrapper's own names (#526)" begin
        @test_skip "cargo/rustc not available"
    end
else
    textdir = mktempdir()
    pyodir = mktempdir()
    emitters = _pn_emitters(textdir, pyodir)

    @testset "every name a wrapper reads is reserved from its parameters (#526)" begin
        # Derived from the emitters' own output: with a parameter named `zqx`,
        # every name any wrapper taking it binds or reads — other than its
        # parameters — is reserved, a type of the corpus itself (`S`, `G`, `P`),
        # or a local the emitter renames itself when a parameter takes it
        # (`_generated_local`).
        for (label, gen) in emitters
            unreserved = Set{Symbol}()
            reserved = _pn_reserved(label, "zqx")
            ex = gen("zqx")
            # Every function and type the emitter defines is a reserved name.
            defined = union(_pn_defined(ex),
                            Set(String(_pn_unesc(sig.args[1])) for (sig, _) in _pn_defs(ex)
                                if _pn_unesc(sig.args[1]) isa Symbol))
            undefended = [d for d in defined
                          if !(d in reserved || d in PN._JULIA_EMITTER_NAMES ||
                               PN._reserved_aggregate_name(d)) && _pn_identifier(Symbol(d))]
            @test isempty(undefended) || (@info "$label defines unreserved names" undefended; false)
            for (sig, params, bound, read) in _pn_wrappers(ex, :zqx)
                for s in setdiff(union(read, bound), params)
                    _pn_identifier(s) || continue
                    str = String(s)
                    (str in PN._JULIA_EMITTER_NAMES || str in reserved) && continue
                    PN._reserved_aggregate_name(str) && continue
                    startswith(str, "__rustcall_") && continue
                    push!(unreserved, s)
                end
            end
            # A local the emitter binds is renamed on collision: check that
            # instead of reserving it.
            for s in collect(unreserved)
                renamed = all(_pn_wrappers(gen(String(s)), s)) do (sig, params, bound, read)
                    !(s in params) || !(s in bound)
                end
                renamed && delete!(unreserved, s)
            end
            @test isempty(unreserved) || (@info "$label reads unreserved names" unreserved; false)
        end
        # ... and nothing is reserved that no emitter uses.
        used = Set{String}()
        for (label, gen) in emitters
            ex = gen("zqx")
            for (sig, params, bound, read) in _pn_wrappers(ex, :zqx)
                union!(used, String.(union(read, bound, params)))
            end
            # A name the emitter defines is reserved as well.
            union!(used, _pn_defined(ex))
            union!(used, (String(_pn_unesc(sig.args[1])) for (sig, _) in _pn_defs(ex)
                          if _pn_unesc(sig.args[1]) isa Symbol))
        end
        unused = [n for n in PN._JULIA_EMITTER_NAMES if !(n in used)]
        @test isempty(unused) || (@info "reserved but unused" unused; false)
    end

    @testset "no wrapper parameter shadows a name its wrapper uses (#526)" begin
        # The emitters, with a parameter named after each reserved name and
        # after the corpus's own definitions (types, methods, functions): a
        # reserved name is renamed, and no wrapper then has two parameters of
        # one name or a parameter spelled like a name it reads.
        probes = vcat(collect(PN._JULIA_EMITTER_NAMES),
                      ["S", "P", "m", "st", "f_plain", "CResult_f_result"])
        for (label, gen) in emitters
            # The parameters a wrapper has of its own (the PyO3 host's `obj`).
            own = Dict(sig.args[1] => setdiff(params, [:zqx])
                       for (sig, params, _, _) in _pn_wrappers(gen("zqx"), :zqx))
            for n in probes
                _pn_identifier(Symbol(n)) || continue
                reserved = _pn_reserved(label, n)
                renamed = Symbol(PN.julia_parameter_names([n]; reserved)[1])
                taken = n in PN._JULIA_EMITTER_NAMES || n in reserved ||
                        PN._reserved_aggregate_name(n)
                taken && @test renamed !== Symbol(n)
                for (sig, params, bound, read) in _pn_wrappers(gen(n), renamed)
                    ok = allunique(params) && renamed in params &&
                         (!taken || !(Symbol(n) in params) ||
                          Symbol(n) in get(own, sig.args[1], Symbol[]))
                    ok || @info "$label: `$n` meets the wrapper" sig
                    @test ok
                end
            end
        end
    end

    @testset "a parameter named like a wrapper's own name calls through (#526)" begin
        # End to end, where a build is available: `@rust_crate`, a written
        # bindings file, `rust\"\"\"`.
        lib = """
            use rustcall_julia_macros::julia;
            #[julia] pub fn echo(pointer: &str) -> String { pointer.to_string() }
            #[julia] pub fn size(sizeof: i32, nothing: i32) -> i32 { sizeof + nothing }
            // A lowercase type and parameters spelled like it (PR #527 review).
            #[allow(non_camel_case_types)]
            #[julia] pub struct foo { pub v: i32 }
            #[julia] impl foo {
                #[allow(non_snake_case)]
                #[julia] pub fn new(Foo: i32, foo: i32) -> Self { foo { v: Foo * 10 + foo } }
            }
            #[julia] pub struct Acc { pub v: i32 }
            #[julia] impl Acc {
                #[julia] pub fn new(getfield: i32) -> Self { Acc { v: getfield } }
                #[julia] pub fn add(&self, getfield: i32) -> i32 { self.v + getfield }
            }
            """
        exercise(get) = begin
            call = Base.invokelatest
            @test call(get(:echo), "hi") == "hi"
            @test call(get(:size), Int32(2), Int32(3)) == 5
            acc = call(get(:Acc), Int32(4))
            @test call(get(:add), acc, Int32(5)) == 9
            f = call(get(:foo), Int32(1), Int32(2))
            @test call(getproperty, f, :v) == 12
        end
        mktempdir() do dir
            _pn_write_crate(dir, lib; name = "pn_crate")
            bindings = @rust_crate dir name = "PnBindings"
            mod = getfield(bindings, :module_ref)
            exercise(name -> Base.invokelatest(getfield, mod, name))
            try
                PN.unload_library(Base.invokelatest(getfield, mod, :_LIB_NAME); close = true)
            catch
            end
        end
        mktempdir() do dir
            _pn_write_crate(dir, lib; name = "pn_written")
            path = joinpath(dir, "PnWritten.jl")
            PN.write_bindings_to_file(dir, path; output_module_name = "PnWritten")
            sandbox = Module(:PnSandbox)
            Base.include(sandbox, path)
            mod = Base.invokelatest(getfield, sandbox, :PnWritten)
            exercise(name -> Base.invokelatest(getfield, mod, name))
            try
                PN.unload_library(Base.invokelatest(getfield, mod, :_LIB_NAME); close = true)
            catch
            end
        end
    end

    @testset "a PyO3 host method whose parameter is `obj` defines (#526)" begin
        # The host binds an instance method as `m(obj::P, args...)`: a Rust
        # parameter `obj` gave it two parameters named `obj`, which Julia
        # refuses to define. Evaluating the definitions needs no Python.
        mktempdir() do dir
            ex = _pn_pyo3(dir, _pn_pyo3_source("obj"))
            sandbox = Module(:PnPyo3Sandbox)
            Core.eval(sandbox, :(struct P end))
            methods_only = [d for d in ex.args if d isa Expr && d.head === :function &&
                            _pn_defs(d)[1][1].args[1] in (:m, :m_res, :m_self, :m_class, :m_default)]
            @test !isempty(methods_only)
            for d in methods_only
                @test (Core.eval(sandbox, d); true)
            end
        end
    end
end
