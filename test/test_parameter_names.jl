# A Rust parameter named like something a generated wrapper uses (#526).
#
# A wrapper names its parameters after the Rust ones (`julia_parameter_names`,
# #516), and its body names things of its own without qualification: the
# generated module's helpers (`_call_target`), Base functions (`pointer`,
# `getfield`), the types it converts through (`Int64(x)`), its type variables,
# the PyO3 host's receiver `obj`. A parameter spelled like one of them
# shadowed it. No list of such names can be complete (PR #527 review), so every
# emitter names its parameters against its own output (`_rename_parameters`):
# it emits once with placeholders, reads every other name of each definition,
# and names each parameter against those. This file checks the result the same
# way for every emitter: emitting a corpus whose parameter is spelled `n` must
# give, up to that parameter's final name, exactly what spelling it `zqx` gives.

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
function _pn_defs(x, out = Tuple{Expr, Any, Vector{Symbol}, Expr}[])
    x isa Expr || return out
    if x.head in (:function, :(=)) && length(x.args) == 2
        sig = x.args[1]
        # The type variables the definition introduces (`where {T}`).
        typevars = Symbol[]
        while sig isa Expr && sig.head in (:where, :(::))
            if sig.head === :where
                for v in sig.args[2:end]
                    v = _pn_unesc(v)
                    v isa Expr && v.head === :(<:) && (v = _pn_unesc(v.args[1]))
                    v isa Symbol && push!(typevars, v)
                end
            end
            sig = sig.args[1]
        end
        sig isa Expr && sig.head === :call && push!(out, (sig, x.args[2], typevars, x))
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
    for (sig, body, typevars) in _pn_defs(expr)
        params = _pn_params(sig)
        name in params || continue
        bound, read = Set{Symbol}(), Set{Symbol}()
        _pn_hygienic(sig) ? _pn_escaped_body!(body, bound, read) : _pn_body!(body, bound, read)
        push!(out, (sig, params, bound, read, typevars))
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
    return Expr(:block, PN._pyo3_host_item_exprs(info, PN._pyo3_host_classes(info))...)
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

# The output of an emitter with its corpus parameter at `from` read with the
# parameter at `to`: every symbol `from` exactly (and the string-argument local
# derived from it), every string `from` exactly, replaced. Parsed text and
# expressions both; line numbers dropped.
function _pn_alpha(x, from::Symbol, to::Symbol)
    local_from = Symbol("rustcall′str′", from)
    local_to = Symbol("rustcall′str′", to)
    swap(y) = y === from ? to : y === local_from ? local_to :
              y isa String && y == String(from) ? String(to) :
              y isa QuoteNode ? QuoteNode(swap(y.value)) :
              y isa Expr ? Expr(y.head, map(swap, y.args)...) : y
    return swap(x)
end

# Printed without line numbers or gensym counters (`##payload#145`), which
# differ between two emissions of the same definition.
_pn_text_of(x) = replace(string(Base.remove_linenums!(deepcopy(x))), r"##(\w+)#\d+" => s"##\1#")

# A name a Rust function can take as a parameter: a plain identifier and not
# a keyword. Every name an emitter binds itself is `rustcall′...`, which no
# such name spells (PR #527 review), so none is excluded.
_pn_rust_parameter(n::Symbol) =
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", String(n)) &&
    !(String(n) in ("self", "Self", "super", "crate", "_"))

# Every symbol of an expression.
_pn_symbols(x, out = Set{Symbol}()) =
    x isa Symbol ? push!(out, x) :
    x isa QuoteNode ? _pn_symbols(x.value, out) :
    x isa Expr ? (foreach(a -> _pn_symbols(a, out), x.args); out) : out

# A name a parameter could meet in a wrapper: a plain identifier, not one the
# allocator hands out itself for a parameter it renamed (`zqx`).
_pn_identifier(s::Symbol) = Base.isidentifier(s) && Meta.parse(String(s); raise = false) isa Symbol

@testset "julia_parameter_names takes the names in scope (#526)" begin
    names = PN.julia_parameter_names
    @test names(["pointer", "x"]; reserved = ["pointer"]) == ["pointer_", "x"]
    @test names(["Int64", "Foo"]; reserved = ["Int64", "foo"]) == ["Int64_", "Foo"]
    @test names(["obj", "obj_"]; reserved = ["obj"]) == ["obj__", "obj_"]
    out = names(["obj", "pointer", "end"]; reserved = ["obj", "pointer"])
    @test names(out; reserved = ["obj", "pointer"]) == out
    @test allunique(out)
end

@testset "a parameter is named against its own definitions (#526)" begin
    # A toy emitter: `f` converts through its argument's spelling, `g` does
    # not. Only `f`'s parameter meets a name of its definition.
    f = PN.RustFunctionSignature("f", ["Int64"], ["i64"], "i64", false, String[])
    g = PN.RustFunctionSignature("g", ["Int64"], ["i64"], "i64", false, String[])
    emit(fs, ss) = Expr(:block, [begin
        p = Symbol(only(sig.arg_names))
        sig.name == "f" ? :(function f($p) Int64($p) end) : :(function g($p) $p end)
    end for sig in fs]...)
    renamed, _ = PN._rename_parameters([f, g], PN.RustStructInfo[], emit)
    @test only(renamed[1].arg_names) == "Int64_"
    @test only(renamed[2].arg_names) == "Int64"
    # A placeholder is a Julia identifier the source text reads back as
    # itself, and no Rust identifier: a crate's own name spelled like an old
    # placeholder is an ordinary name the definition uses (PR #527 review).
    placeholder = PN._parameter_placeholder(1)
    @test Base.isidentifier(placeholder) && Meta.parse(placeholder) === Symbol(placeholder)
    @test !all(c -> isascii(c) && (isletter(c) || isdigit(c) || c == '_'), placeholder)
    h = PN.RustFunctionSignature("h", ["__rustcall_arg_1__"], ["i64"], "i64", false, String[])
    emit_h(fs, ss) = Expr(:block, [begin
        q = Symbol(only(sig.arg_names))
        :(function h($q) __rustcall_arg_1__($q) end)
    end for sig in fs]...)
    renamed_h, _ = PN._rename_parameters([h], PN.RustStructInfo[], emit_h)
    @test only(renamed_h[1].arg_names) == "__rustcall_arg_1___"
    # An emitter that raises leaves the names alone: it raises again.
    failing(fs, ss) = error("refused")
    same, _ = PN._rename_parameters([f], PN.RustStructInfo[], failing)
    @test only(same[1].arg_names) == "Int64"
end

if !PN_HAVE_CARGO || !PN.check_rustc_available()
    @testset "wrapper parameters never meet the wrapper's own names (#526)" begin
        @test_skip "cargo/rustc not available"
    end
else
    textdir = mktempdir()
    pyodir = mktempdir()
    emitters = _pn_emitters(textdir, pyodir)

    @testset "no parameter meets a name of its own definition, in any emitter (#526)" begin
        # For each emitter: the names its output for the `zqx` corpus uses in
        # a definition taking `zqx` — what a parameter could shadow — and a few
        # more; the corpus with its parameter spelled like each of them must be
        # the `zqx` corpus up to the parameter's final name. A parameter that
        # kept a name its definition reads, or was renamed onto one, breaks
        # the equivalence (that name would be swapped too).
        for (label, gen) in emitters
            base = gen("zqx")
            used = Set{Symbol}()
            for (sig, body) in _pn_defs(base)
                :zqx in _pn_params(sig) || continue
                union!(used, _pn_symbols(sig), _pn_symbols(body))
            end
            probes = sort!(collect(setdiff(union(used, Symbol.(["Int64", "Float32", "Char",
                                                                 "Cint", "obj", "T", "pointer",
                                                                 "__rustcall_arg_1__", "__rustcall_str_zqx",
                                                                 "__rustcall_cb_frame"])),
                                           Set([:zqx]))))
            base_defs = _pn_defs(base)
            failures = String[]
            for n in probes
                (_pn_identifier(n) && _pn_rust_parameter(n)) || continue
                out = try
                    gen(String(n))
                catch
                    continue    # not a name Rust accepts for a parameter
                end
                out_defs = _pn_defs(out)
                length(out_defs) == length(base_defs) ||
                    (push!(failures, "$n: $(length(out_defs)) definitions"); continue)
                # Definition by definition: the parameter's final name is what
                # stands where `zqx` stood, and swapping it back must give the
                # `zqx` definition exactly.
                for ((zsig, _, _, zdef), (nsig, _, _, ndef)) in zip(base_defs, out_defs)
                    at = findfirst(==(:zqx), _pn_params(zsig))
                    at === nothing && continue
                    final = _pn_params(nsig)[at]
                    _pn_text_of(_pn_alpha(ndef, final, :zqx)) == _pn_text_of(zdef) ||
                        push!(failures, "$n -> $final in $(zsig.args[1])")
                end
            end
            @test isempty(failures) || (@info "$label: a parameter meets its definition" failures; false)
        end
    end

    @testset "a wrapper binds no name a Rust identifier spells (PR #527 review)" begin
        # Every name a generated definition binds itself — a receiver, a
        # pointer, a panic channel, a string temporary, a constructor's
        # arguments — is `rustcall′...`, a namespace no Rust identifier (so no
        # crate item and no parameter) can spell: a local never shadows a
        # crate item its definition reads. Checked for every definition that
        # takes the corpus parameter or is defined on a corpus type; a
        # hygienic `rust\"\"\"` expansion is checked on its escaped part, the
        # only part a crate name reaches.
        corpus_types = Set([:S, :P, :G])
        emitter_local(b::Symbol) = occursin('′', String(b))
        for (label, gen) in emitters
            failures = String[]
            for (sig, body, typevars) in _pn_defs(gen("zqx"))
                symbols = _pn_symbols(sig)
                (:zqx in _pn_params(sig) || !isempty(intersect(symbols, corpus_types))) || continue
                bound, read = Set{Symbol}(), Set{Symbol}()
                if _pn_hygienic(sig) || startswith(label, "rust")
                    _pn_escaped_body!(body, bound, read)
                    for a in sig.args[2:end]
                        a isa Expr && a.head === :escape && push!(bound, _pn_unesc(a))
                    end
                else
                    _pn_body!(body, bound, read)
                    union!(bound, _pn_params(sig))
                end
                for b in bound
                    (b === :zqx || emitter_local(b) || b in typevars) && continue
                    push!(failures, "$b in $(sig.args[1])")
                end
            end
            @test isempty(failures) || (@info "$label: a local a Rust name can spell" unique(failures); false)
        end
    end

    @testset "a parameter named like a wrapper's own name calls through (#526)" begin
        # End to end, where a build is available: `@rust_crate`, a written
        # bindings file, `rust\"\"\"`.
        lib = """
            use rustcall_julia_macros::julia;
            #[julia] pub fn echo(pointer: &str) -> String { pointer.to_string() }
            #[julia] pub fn size(sizeof: i32, nothing: i32) -> i32 { sizeof + nothing }
            // Parameters named like the types the wrapper body converts
            // through (PR #527 review).
            #[allow(non_snake_case)]
            #[julia] pub fn widen(Int64: i64, Float32: f32, Char: u32, Cint: i32) -> i64 {
                Int64 + Float32 as i64 + Char as i64 + Cint as i64
            }
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
            // An item and a parameter spelled like the renaming probe's own
            // placeholders: the probe must not take them for its own (PR #527
            // review).
            #[allow(non_camel_case_types)]
            #[julia] pub struct __rustcall_arg_1__ { pub v: i32 }
            #[julia] impl __rustcall_arg_1__ {
                #[julia] pub fn new(__rustcall_arg_1__: i32, __rustcall_arg_2__: i32) -> Self {
                    __rustcall_arg_1__ { v: __rustcall_arg_1__ * 10 + __rustcall_arg_2__ }
                }
            }
            // A struct spelled like the string temporary its own constructor
            // made for its parameter (`__rustcall_str_` + `s`), which then
            // shadowed the type it constructs (PR #527 review).
            #[allow(non_camel_case_types)]
            #[julia] pub struct __rustcall_str_s { pub n: i32 }
            #[julia] impl __rustcall_str_s {
                #[julia] pub fn new(s: &str) -> Self { __rustcall_str_s { n: s.len() as i32 } }
            }
            """
        exercise(get) = begin
            call = Base.invokelatest
            @test call(get(:echo), "hi") == "hi"
            @test call(get(:size), Int32(2), Int32(3)) == 5
            @test call(get(:widen), Int64(1), Float32(2), UInt32(3), Int32(4)) == 10
            acc = call(get(:Acc), Int32(4))
            @test call(get(:add), acc, Int32(5)) == 9
            f = call(get(:foo), Int32(1), Int32(2))
            @test call(getproperty, f, :v) == 12
            a = call(get(:__rustcall_arg_1__), Int32(3), Int32(4))
            @test call(getproperty, a, :v) == 34
            t = call(get(:__rustcall_str_s), "four")
            @test call(getproperty, t, :n) == 4
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

    @testset "a generic struct's type variable is no parameter (#527 review)" begin
        # `rust\"\"\"` defines the generic struct's method wrappers with
        # `where {obj_}`; a parameter `obj_` beside it does not define.
        sandbox = Module(:PnGenericSandbox)
        Core.eval(sandbox, :(using RustCall))
        @test (Core.eval(sandbox, Meta.parse("""rust\"\"\"
            #[julia] pub struct G<obj_> { pub v: obj_ }
            impl<obj_: Copy> G<obj_> {
                pub fn pick(&self, obj: obj_) -> obj_ { obj }
            }
            \"\"\"""")); true)
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
