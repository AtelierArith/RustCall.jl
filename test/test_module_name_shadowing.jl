# A Rust item bound into a generated module under a name the generated code
# itself uses — `struct Base`, `struct RustCall`, `fn getfield`, `fn Int32` —
# must not change what that code means (#528).
#
# The rule the emitters follow: every reference to something outside the
# generated module goes through a name no Rust identifier can spell — a
# `GlobalRef` in the expression emitters, a `rustcall′` alias in the written
# file. The derivation testset reads that off the emitted code of every
# emitter; the end-to-end testsets bind and call crates whose items take those
# names.
using RustCall
using RustToolChain
using Test

if Base.find_package("PythonCall") !== nothing
    @eval using PythonCall
end

const _MNS_FIXTURES = joinpath(@__DIR__, "fixtures")

# ---------------------------------------------------------------------------
# What emitted code references, read off the code by lowering it
# ---------------------------------------------------------------------------

# Every `GlobalRef` into `M` in a lowered statement: lowering resolves scope, so
# what is left is exactly the free global names the statement reads or defines.
function _mns_globals!(refs::Set{Symbol}, x, M::Module)
    if x isa GlobalRef
        x.mod === M && push!(refs, x.name)
    elseif x isa Expr
        foreach(a -> _mns_globals!(refs, a, M), x.args)
    elseif x isa Core.CodeInfo
        foreach(a -> _mns_globals!(refs, a, M), x.code)
    end
    return refs
end

# The names a module statement defines at module level, read off the statement:
# functions (`function f`, `f(x) = ...`, `function f end`), constants, types,
# submodules and imports.
function _mns_definitions!(defs::Set{Symbol}, st)
    st isa Expr || return defs
    head = st.head
    if head === :block
        foreach(a -> _mns_definitions!(defs, a), st.args)
    elseif head === :function || (head === :(=) && st.args[1] isa Expr &&
                                  st.args[1].head in (:call, :where, :(::)))
        sig = st.args[1]
        while sig isa Expr && sig.head in (:where, :(::))
            sig = sig.args[1]
        end
        sig isa Expr && sig.head === :call && (sig = sig.args[1])
        sig isa Symbol && push!(defs, sig)
    elseif head === :const
        lhs = st.args[1]
        lhs isa Expr && lhs.head === :(=) && (lhs = lhs.args[1])
        lhs isa Symbol && push!(defs, lhs)
    elseif head === :struct || head === :abstract
        name = head === :struct ? st.args[2] : st.args[1]
        name isa Expr && name.head === :<: && (name = name.args[1])
        name isa Symbol && push!(defs, name)
    elseif head === :module
        push!(defs, st.args[2])
    elseif head === :import || head === :using
        for path in st.args
            path isa Expr && path.head === :as && push!(defs, path.args[2])
            path isa Expr && path.head === :. && push!(defs, last(path.args))
            path isa Expr && path.head === :(:) && foreach(p -> push!(defs, last(p.args)), path.args[2:end])
        end
    end
    return defs
end

"""
    _mns_findings(modex) -> Vector{String}

For the module expression `modex` and every submodule in it: each free global
the emitted code references whose name a Rust identifier can spell and that is
not one of that module's own definitions. The names the module defines are
read off its statements, the references off their lowering — neither is a list.
"""
function _mns_findings(modex::Expr; where_ = String(modex.args[2]))
    body = modex.args[3]
    M = Module(:MnsProbe)
    defs = Set{Symbol}()
    refs = Set{Symbol}()
    findings = String[]
    statements = Any[]
    flatten!(x) = x isa Expr && x.head === :block ? foreach(flatten!, x.args) : push!(statements, x)
    flatten!(body)
    for st in statements
        st isa LineNumberNode && continue
        _mns_definitions!(defs, st)
        if st isa Expr && st.head === :module
            append!(findings, _mns_findings(st; where_ = where_ * "." * String(st.args[2])))
            continue
        end
        if st isa Expr && (st.head === :import || st.head === :using)
            # The aliases resolve here; a submodule's `import ..helper` names a
            # parent the probe does not have, and is a definition either way.
            relative = any(p -> p isa Expr && p.head === :. && first(p.args) === :., st.args)
            relative && continue
            try
                Core.eval(M, st)
            catch
                # `import PythonCall as rustcall′PythonCall` in a session without
                # PythonCall: the alias is what matters, not the package.
                for p in st.args
                    p isa Expr && p.head === :as && Core.eval(M, :(const $(p.args[2]) = $(Module())))
                end
            end
            continue
        end
        st isa Expr && st.head === :export && continue
        lowered = Meta.lower(M, st)
        if lowered isa Expr && lowered.head in (:error, :incomplete)
            push!(findings, "$where_: does not lower: $(lowered.args[1])")
            continue
        end
        _mns_globals!(refs, lowered, M)
    end
    for name in sort!(collect(refs))
        (RustCall._rust_spellable(name) && !(name in defs)) || continue
        push!(findings, "$where_: `$name`")
    end
    return findings
end

_mns_text_module(code::AbstractString) =
    only(filter(x -> x isa Expr && x.head === :module, Meta.parseall(code).args))

# The two crate emitters over one crate's items.
function _mns_crate_emissions(info)
    ex = RustCall.emit_crate_module(info, "/tmp/libmns528.dylib"; lib_name = "mns528")
    code = RustCall.emit_crate_module_code(info, "/tmp/libmns528.dylib"; lib_name = "mns528")
    return ex, _mns_text_module(code)
end

# A crate of every shape the crate emitters have a branch for: scalars,
# strings in and out, `Option` / `Result` returns of both, callbacks, raw
# pointers, struct handles with every method kind, field accessors of every
# kind, and a Rust module.
const _MNS_CORPUS = raw"""
use rustcall_julia_macros::julia;

#[julia]
pub fn scalars(a: i32, b: f64, c: bool, d: u8, e: usize, f: char) -> i64 {
    a as i64 + b as i64 + c as i64 + d as i64 + e as i64 + f as i64
}
#[julia]
pub fn nothing_back(a: u32) { let _ = a; }
#[julia]
pub fn owned_text(s: &str, t: String) -> String { format!("{s}{t}") }
#[julia]
pub fn borrowed_text<'a>(s: &'a str) -> &'a str { s }
#[julia]
pub fn maybe(x: i32) -> Option<f64> { if x > 0 { Some(x as f64) } else { None } }
#[julia]
pub fn maybe_text(x: i32) -> Option<String> { if x > 0 { Some(x.to_string()) } else { None } }
#[julia]
pub fn fallible(x: i32) -> Result<i32, String> { if x > 0 { Ok(x) } else { Err("no".into()) } }
#[julia]
pub fn apply(f: extern "C" fn(i64) -> i64, x: i64) -> i64 { f(x) }
#[julia]
pub fn raw(p: *const i32) -> *mut u8 { p as *mut u8 }

#[julia]
pub struct Holder {
    pub n: i32,
    pub name: String,
    pub values: Vec<f64>,
    pub letter: char,
}

#[julia]
impl Holder {
    #[julia]
    pub fn new(n: i32) -> Self { Holder { n, name: String::new(), values: Vec::new(), letter: 'a' } }
    #[julia]
    pub fn make(n: i32) -> Holder { Holder::new(n) }
    #[julia]
    pub fn get(&self) -> i32 { self.n }
    #[julia]
    pub fn set(&mut self, n: i32) { self.n = n; }
    #[julia]
    pub fn label(&self, s: &str) -> String { format!("{s}{}", self.n) }
    #[julia]
    pub fn view(&self) -> &str { &self.name }
    #[julia]
    pub fn half(&self) -> Option<f64> { Some(self.n as f64 / 2.0) }
    #[julia]
    pub fn named(&self) -> Option<String> { Some(self.name.clone()) }
    #[julia]
    pub fn checked(&self, d: i32) -> Result<i32, String> { if d == 0 { Err("zero".into()) } else { Ok(self.n / d) } }
    #[julia]
    pub fn fold(&self, f: extern "C" fn(i64) -> i64) -> i64 { f(self.n as i64) }
    #[julia]
    pub fn shout(s: &str) -> String { s.to_uppercase() }
}

#[julia]
pub mod inner {
    use rustcall_julia_macros::julia;

    #[julia]
    pub fn deep(x: i32) -> i32 { x }

    #[julia]
    pub struct Leaf { pub v: i32 }

    #[julia]
    impl Leaf {
        #[julia]
        pub fn new(v: i32) -> Self { Leaf { v } }
        #[julia]
        pub fn text(&self, s: &str) -> Option<String> { Some(format!("{s}{}", self.v)) }
    }
}
"""

# Items named after what the generated code uses: the modules it names
# (`Base`, `Core`, `RustCall`, `Libdl`, `GC`), types it spells (`Symbol`, `IO`)
# and functions it calls (`getfield`, `convert`, `pointer`, `nothing`, `error`,
# `Int32`), at the crate root and in a Rust module.
const _MNS_SHADOWING = raw"""
use rustcall_julia_macros::julia;

#[julia]
pub struct Base { pub x: i32 }

#[julia]
impl Base {
    #[julia]
    pub fn new(x: i32) -> Self { Base { x } }
    #[julia]
    pub fn get(&self) -> i32 { self.x }
    #[julia]
    pub fn label(&self, s: &str) -> std::string::String { format!("{s}{}", self.x) }
    #[julia]
    pub fn half(&self) -> Option<f64> { Some(self.x as f64 / 2.0) }
}

#[julia]
pub struct Core { pub y: f64 }

#[julia]
impl Core {
    #[julia]
    pub fn new(y: f64) -> Self { Core { y } }
    #[julia]
    pub fn checked(&self, d: i32) -> Result<i32, std::string::String> {
        if d == 0 { Err("zero".into()) } else { Ok(self.y as i32 / d) }
    }
}

#[julia]
pub struct RustCall { pub z: i32 }

#[julia]
impl RustCall {
    #[julia]
    pub fn new(z: i32) -> Self { RustCall { z } }
    #[julia]
    pub fn doubled(&self) -> i32 { 2 * self.z }
}

#[julia]
pub struct Symbol { pub v: i32 }

#[julia]
impl Symbol {
    #[julia]
    pub fn new(v: i32) -> Self { Symbol { v } }
}

#[julia]
pub struct IO { pub w: i32 }

#[julia]
impl IO {
    #[julia]
    pub fn new(w: i32) -> Self { IO { w } }
}

#[julia]
pub fn getfield(x: i32) -> i32 { x + 1 }
#[julia]
pub fn convert(x: f64) -> f64 { x * 2.0 }
#[julia]
pub fn pointer(s: &str) -> usize { s.len() }
#[julia]
pub fn nothing() -> i32 { 3 }
#[julia]
pub fn error(x: i32) -> Result<i32, std::string::String> { if x > 0 { Ok(x) } else { Err("neg".into()) } }
#[julia]
#[allow(non_snake_case)]
pub fn Int32(x: i32) -> i32 { x + 2 }
#[julia]
#[allow(non_snake_case)]
pub fn GC(s: &str) -> std::string::String { s.to_uppercase() }
#[julia]
#[allow(non_snake_case)]
pub fn Libdl() -> i32 { 4 }
#[julia]
pub fn apply(f: extern "C" fn(i64) -> i64, x: i64) -> i64 { f(x) * 10 }

#[julia]
pub mod nested {
    use rustcall_julia_macros::julia;

    #[julia]
    pub struct Base { pub w: i32 }

    #[julia]
    impl Base {
        #[julia]
        pub fn new(w: i32) -> Self { Base { w } }
        #[julia]
        pub fn tripled(&self) -> i32 { 3 * self.w }
    }

    #[julia]
    pub fn getfield(x: i32) -> i32 { x + 10 }
}
"""

function _mns_crate(dir::AbstractString, package::AbstractString, source::AbstractString)
    mkpath(joinpath(dir, "src"))
    runtime = RustCall.rustcall_runtime_crate_path()
    write(joinpath(dir, "Cargo.toml"), """
        [package]
        name = "$(package)"
        version = "0.1.0"
        edition = "2021"

        [lib]
        crate-type = ["cdylib"]

        [dependencies]
        rustcall_julia_macros = { path = "$(RustCall.escape_toml_string(runtime))" }
        """)
    write(joinpath(dir, "src", "lib.rs"), source)
    return String(dir)
end

_mns_cargo_available() = try
    run(pipeline(`$(RustToolChain.cargo()) --version`, devnull))
    true
catch
    false
end

@testset "emitted code names nothing a Rust item can take (#528)" begin

    @testset "U+2032 is a Julia identifier character and no Rust one" begin
        # Julia parses `rustcall′Base` as one identifier, `Base.:′` is not an
        # operator, and the character is punctuation (`Po`), outside Rust's
        # XID_Continue: no Rust identifier, raw or not, can spell an alias.
        @test Meta.parse("rustcall′Base.getfield") == Expr(:., Symbol("rustcall′Base"), QuoteNode(:getfield))
        @test Base.Unicode.category_abbrev('′') == "Po"
        for name in ("foo", "_x", "Base", "RustCall", "getfield", "Int32", "café", "x1", "__init__")
            @test RustCall._rust_spellable(name)
        end
        for name in ("rustcall′Base", "rustcall′RustCall", "rustcall′PythonCall", "set_x!",
                     "@preserve", "#TC#fn#f", "==", "1x", "")
            @test !RustCall._rust_spellable(name)
        end
        # Every alias the emitters bind is outside that grammar, so a crate
        # item can never collide with one.
        for alias in (RustCall._EMITTED_BASE_ALIAS, RustCall._EMITTED_RUSTCALL_ALIAS,
                      RustCall._EMITTED_PYTHONCALL_ALIAS)
            @test !RustCall._rust_spellable(alias)
        end
        # The names Julia's `module` itself defines, read off a fresh module.
        fresh = Core.eval(Module(:MnsFresh), :(module MnsFreshInner end))
        @test Set(setdiff(names(fresh; all = true), [:MnsFreshInner])) ==
              Set(RustCall._JULIA_MODULE_OWN_NAMES)
    end

    @testset "every emitter's free globals are its own definitions" begin
        mktempdir() do dir
            corpus = _mns_crate(joinpath(dir, "corpus"), "mns_corpus_528", _MNS_CORPUS)
            shadowing = _mns_crate(joinpath(dir, "shadowing"), "mns_shadowing_528", _MNS_SHADOWING)
            crates = [corpus, shadowing, joinpath(_MNS_FIXTURES, "sample_crate")]
            for crate in crates
                info = RustCall.scan_crate(crate)
                ex, text = _mns_crate_emissions(info)
                @test isempty(_mns_findings(ex))
                @test isempty(_mns_findings(text))
                for f in (_mns_findings(ex)..., _mns_findings(text)...)
                    @info "a free global a Rust item can take" crate f
                end
            end
            # The crate emitters over PyO3 items (`PyResult` wrappers,
            # `#[pyclass]` handles), as the PyO3 wrapper crate binds them:
            # the items `rustcall-extract wrap` describes, no build needed.
            for fixture in ("sample_crate_pyo3", "sample_crate_pyo3_only")
                path = joinpath(_MNS_FIXTURES, fixture)
                info = RustCall.scan_crate(path)
                cargo_toml = RustCall.parse_cargo_toml(joinpath(path, "Cargo.toml"))
                sources = sort(RustCall.find_rust_sources(path))
                lib_root, tree_files = RustCall._crate_scan_inputs(path, cargo_toml, sources)
                source = RustCall.wrap_crate(tree_files; crate_name = info.name, cfg = :lenient,
                                             crate_root = lib_root, skip_unparsable = true)
                functions, structs, _, _ = RustCall._pyo3_wrapper_items(source.manifest)
                @test !isempty(functions) || !isempty(structs)
                pyo3 = RustCall.CrateInfo(info.name, info.path, info.version, info.dependencies,
                                          functions, structs, info.source_files)
                ex, text = _mns_crate_emissions(pyo3)
                @test isempty(_mns_findings(ex))
                @test isempty(_mns_findings(text))
                for f in (_mns_findings(ex)..., _mns_findings(text)...)
                    @info "a free global a Rust item can take" fixture f
                end
            end
            # The PyO3 host, over its fixture (numpy arrays, properties,
            # classes, `PyResult`s) and the declarative one.
            for fixture in ("sample_crate_pyo3_host", "sample_crate_pyo3_declarative")
                ex = RustCall.generate_pyo3_host_bindings(joinpath(_MNS_FIXTURES, fixture))
                findings = _mns_findings(ex)
                @test isempty(findings)
                foreach(f -> @info("a free global a Rust item can take", fixture, f), findings)
            end
        end
    end

    @testset "rust\"\"\" is hygienic: its expansion reads no global of the caller" begin
        # The wrappers `rust"""` defines live in the caller's module, but the
        # macro escapes only the crate's names; everything the wrappers use is
        # resolved in RustCall. Every free global of the expansion is
        # therefore a name the block itself defines.
        block = raw"""
        #[julia]
        pub struct Base { pub x: i32 }
        #[julia]
        impl Base {
            #[julia]
            pub fn new(x: i32) -> Self { Base { x } }
            #[julia]
            pub fn label(&self, s: &str) -> String { format!("{s}{}", self.x) }
        }
        #[julia]
        pub fn getfield(s: &str, f: extern "C" fn(i64) -> i64) -> Option<i64> { Some(f(s.len() as i64)) }
        """
        M = Module(:MnsRustStr)
        Core.eval(M, :(using RustCall))
        expanded = macroexpand(M, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), block))
        refs = _mns_globals!(Set{Symbol}(), Meta.lower(M, expanded), M)
        # The crate's own names, which the macro escapes on purpose: what the
        # block defines (`julia_definitions`) and every method it names.
        manifest = RustCall.expand_inline(block).manifest
        structs = RustCall.manifest_struct_infos(manifest)
        defs = RustCall.julia_definitions(RustCall.manifest_function_signatures(manifest), structs)
        own = Set(Symbol(d.name) for d in defs)
        foreach(s -> foreach(m -> push!(own, Symbol(RustCall.julia_method_name(m))), s.methods), structs)
        leaked = filter(n -> RustCall._rust_spellable(n) && !(n in own), refs)
        @test isempty(leaked)
        isempty(leaked) || @info "rust\"\"\" reads a caller global" leaked
    end

    if !_mns_cargo_available()
        @test_skip "the end-to-end crate testsets need cargo"
        return
    end

    @testset "@rust_crate and a written file bind items named like what they use" begin
        mktempdir() do dir
            crate = _mns_crate(joinpath(dir, "crate"), "mns_shadow_e2e_528", _MNS_SHADOWING)
            check(m) = begin
                b = Base.invokelatest(getproperty(m, :Base), Int32(3))
                @test Base.invokelatest(m.get, b) == 3
                @test Base.invokelatest(m.label, b, "x") == "x3"
                h = Base.invokelatest(m.half, b)
                @test h.is_some && h.value == 1.5
                @test b.x == 3
                b.x = Int32(5)
                @test b.x == 5
                @test occursin(".Base(", sprint(show, b))
                c = Base.invokelatest(getproperty(m, :Core), 8.0)
                r = Base.invokelatest(m.checked, c, Int32(2))
                @test r.is_ok && r.value == 4
                @test !Base.invokelatest(m.checked, c, Int32(0)).is_ok
                rc = Base.invokelatest(getproperty(m, :RustCall), Int32(21))
                @test Base.invokelatest(m.doubled, rc) == 42
                @test Base.invokelatest(getproperty(m, :Symbol), Int32(1)).v == 1
                @test Base.invokelatest(getproperty(m, :IO), Int32(2)).w == 2
                @test Base.invokelatest(m.getfield, Int32(1)) == 2
                @test Base.invokelatest(m.convert, 1.5) == 3.0
                @test Base.invokelatest(m.pointer, "four") == 4
                @test Base.invokelatest(m.nothing) == 3
                @test Base.invokelatest(m.error, Int32(7)).value == 7
                # A function named like a Base type is the module's own, not a
                # constructor method of Base's `Int32`.
                @test Base.invokelatest(getproperty(m, :Int32), Int32(1)) == 3
                @test Int32(Int8(1)) === Int32(1)
                @test Base.invokelatest(getproperty(m, :GC), "abc") == "ABC"
                @test Base.invokelatest(getproperty(m, :Libdl)) == 4
                @test Base.invokelatest(m.apply, x -> x + 1, 4) == 50
                n = Base.invokelatest(getproperty(m.nested, :Base), Int32(2))
                @test Base.invokelatest(m.nested.tripled, n) == 6
                @test Base.invokelatest(m.nested.getfield, Int32(1)) == 11
            end
            bindings = @eval RustCall.@rust_crate $crate name = "MnsShadow528" cache = false
            # A module defined after this testset started: its bindings,
            # `Base` among them, are read in the latest world.
            Base.invokelatest(check, bindings.module_ref)
            out = joinpath(dir, "bindings.jl")
            RustCall.write_bindings_to_file(crate, out; output_module_name = "MnsShadowFile528")
            written = read(out, String)
            # The file names Base and RustCall only in its alias imports.
            @test occursin("import Base as rustcall′Base", written)
            @test !occursin(r"^import RustCall$"m, written)
            m = Core.eval(Main, :(include($out)))
            Base.invokelatest(check, m)
            RustCall.unload_library(Base.invokelatest(getproperty, m, :_LIB_NAME))
            RustCall.unload_library(Base.invokelatest(getproperty, bindings.module_ref, :_LIB_NAME))
        end
    end

    @testset "a crate item may not take Julia's own eval / include" begin
        mktempdir() do dir
            for name in RustCall._JULIA_MODULE_OWN_NAMES
                crate = _mns_crate(joinpath(dir, String(name)), "mns_own_$(name)_528",
                                   "use rustcall_julia_macros::julia;\n#[julia]\npub fn $(name)(x: i32) -> i32 { x }\n")
                info = RustCall.scan_crate(crate)
                err = try
                    RustCall.emit_crate_module(info, "/tmp/x.dylib"; lib_name = "x")
                    nothing
                catch e
                    e
                end
                @test err isa ErrorException
                @test err !== nothing && occursin("`$name`", sprint(showerror, err))
            end
        end
    end
end

@testset "the PyO3 host binds classes named like what it uses (#528)" begin
    if !RustCall.pyo3_host_available()
        @test_skip "the PyO3 host end-to-end testset needs PythonCall; `using PythonCall` enables RustCallPyO3HostExt"
        return
    end
    mktempdir() do dir
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "Cargo.toml"), """
            [package]
            name = "mns_host_528"
            version = "0.1.0"
            edition = "2021"

            [lib]
            crate-type = ["cdylib"]

            [dependencies]
            pyo3 = { version = "0.29", default-features = false, features = ["macros", "extension-module"] }
            """)
        write(joinpath(dir, "src", "lib.rs"), raw"""
            use pyo3::prelude::*;

            #[pyclass]
            pub struct Base { #[pyo3(get, set)] pub x: i32 }

            #[pymethods]
            impl Base {
                #[new]
                fn new(x: i32) -> Self { Base { x } }
                fn doubled(&self) -> i32 { 2 * self.x }
            }

            #[pyclass]
            pub struct PythonCall { #[pyo3(get)] pub y: f64 }

            #[pymethods]
            impl PythonCall {
                #[new]
                fn new(y: f64) -> Self { PythonCall { y } }
            }

            #[pyclass]
            pub struct RustCall { #[pyo3(get)] pub z: i32 }

            #[pymethods]
            impl RustCall {
                #[new]
                fn new(z: i32) -> Self { RustCall { z } }
            }

            #[pyfunction]
            fn getfield(x: i32) -> i32 { x + 1 }

            #[pyfunction]
            #[allow(non_snake_case)]
            fn Int32(x: i32) -> i32 { x + 2 }

            #[pyfunction]
            fn nothing() -> i32 { 3 }

            #[pymodule]
            fn mns_host_528(m: &Bound<'_, PyModule>) -> PyResult<()> {
                m.add_class::<Base>()?;
                m.add_class::<PythonCall>()?;
                m.add_class::<RustCall>()?;
                m.add_function(wrap_pyfunction!(getfield, m)?)?;
                m.add_function(wrap_pyfunction!(Int32, m)?)?;
                m.add_function(wrap_pyfunction!(nothing, m)?)?;
                Ok(())
            }
            """)
        bindings = RustCall.load_crate_bindings(dir; pyo3_host = true)
        # Read in the latest world: the module, and its `Base`, are newer than
        # this testset.
        check(M) = begin
            b = getproperty(M, :Base)(Int32(4))
            @test M.doubled(b) == 8
            @test b.x == 4
            b.x = Int32(6)
            @test b.x == 6
            @test occursin("Base", sprint(show, b))
            @test getproperty(M, :PythonCall)(1.5).y == 1.5
            @test getproperty(M, :RustCall)(Int32(9)).z == 9
            @test M.getfield(Int32(1)) == 2
            @test getproperty(M, :Int32)(Int32(1)) == 3
            @test Int32(Int8(1)) === Int32(1)
            @test M.nothing() == 3
        end
        Base.invokelatest(check, bindings.module_ref)
    end
end
