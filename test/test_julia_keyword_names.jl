# A Rust item whose name is a Julia keyword gets a usable binding (#514).
#
# Rust and Julia reserve different words: `fn function`, `struct end`,
# `mod r#do`, a field `r#let` and a method `quote` are all legal Rust, and each
# used to produce a Julia definition that did not parse (`write_bindings_to_file`)
# or could not be called by name (`rust"""`, `@rust_crate`). One function,
# `RustCall.julia_binding_name`, now decides the Julia name of every Rust item:
# the `r#` of a raw identifier is dropped, and a name Julia reserves gets a
# trailing underscore (`for_`, `end_`). The layout checks compare those names,
# so `r#for` beside `for_` is refused rather than bound twice.

using Test
using RustCall
using RustToolChain: cargo

const KW_MACROS_PATH = joinpath(dirname(@__DIR__), "deps", "rustcall_julia_macros")

const _KW_HAVE_CARGO = try
    success(run(pipeline(`$(cargo()) --version`, devnull, devnull); wait = true))
catch
    false
end

function _kw_write_crate(dir::AbstractString, lib::AbstractString; name = "kw_names")
    mkpath(joinpath(dir, "src"))
    macros = replace(KW_MACROS_PATH, "\\" => "/")
    write(joinpath(dir, "Cargo.toml"), """
        [package]
        name = "$name"
        version = "0.1.0"
        edition = "2021"

        [lib]
        crate-type = ["cdylib"]

        [dependencies]
        rustcall_julia_macros = { path = "$macros" }

        [workspace]
        """)
    write(joinpath(dir, "src", "lib.rs"), lib)
end

# Every item kind named after a Julia keyword: a free function (raw and plain),
# a struct (plain `end`, raw `r#while`), its fields (raw `r#let`, plain
# `begin`), an inherent method (`quote`, raw `r#if`), a static method (`r#true`),
# a trait impl's method (`<end as Tr>::r#end`) and a submodule (`r#do`).
const KW_CRATE = """
    use rustcall_julia_macros::julia;

    pub trait Tr {
        fn r#end(&self) -> i32;
    }

    #[julia]
    pub fn r#for(x: i32) -> i32 {
        x + 1
    }

    #[julia]
    pub fn function(x: i32) -> i32 {
        x + 2
    }

    #[julia]
    pub struct end {
        pub r#let: i32,
        pub begin: i32,
    }

    #[julia]
    impl end {
        #[julia]
        pub fn new(a: i32, b: i32) -> Self {
            end { r#let: a, begin: b }
        }
        #[julia]
        pub fn quote(&self) -> i32 {
            self.r#let + self.begin
        }
        #[julia]
        pub fn r#true() -> i32 {
            42
        }
    }

    #[julia]
    impl Tr for end {
        #[julia]
        fn r#end(&self) -> i32 {
            self.r#let * 10
        }
    }

    #[julia]
    pub struct r#while {
        pub x: i32,
    }

    #[julia]
    impl r#while {
        #[julia]
        pub fn new(x: i32) -> Self {
            r#while { x }
        }
        #[julia]
        pub fn r#if(&self) -> i32 {
            self.x * 2
        }
    }

    #[julia]
    pub mod r#do {
        use rustcall_julia_macros::julia;

        #[julia]
        pub fn r#try(x: i32) -> i32 {
            x * 3
        }
    }
    """

# Every call a bound crate module must answer, `get` resolving a binding by name.
function _kw_exercise(get)
    call = Base.invokelatest
    @test call(get(:for_), Int32(1)) == 2
    @test call(get(:function_), Int32(1)) == 3
    e = call(get(:end_), Int32(2), Int32(3))
    @test e isa get(:end_)
    @test call(get(:quote_), e) == 5
    # The trait method `r#end` keeps its own name (no other method shares it),
    # which Julia reserves: `end_`, a method of the struct's own constructor.
    @test call(get(:end_), e) == 20
    @test call(get(:true_), get(:end_)) == 42
    @test call(get(:true_)) == 42
    @test call(getproperty, e, :let_) == 2
    @test call(getproperty, e, :begin_) == 3
    call(setproperty!, e, :let_, Int32(9))
    @test call(getproperty, e, :let_) == 9
    @test call(propertynames, e) == (:let_, :begin_)
    w = call(get(:while_), Int32(5))
    @test call(get(:if_), w) == 10
    @test call(getproperty, w, :x) == 5
    @test call(call(getfield, get(:do_), :try_), Int32(4)) == 12
end

@testset "julia_binding_name decides every Julia name (#514)" begin
    name = RustCall.julia_binding_name
    @test name("x") == "x"
    @test name("r#type") == "type"
    @test name("r#match") == "match"
    @test name("for") == "for_"
    @test name("r#for") == "for_"
    @test name("end") == "end_"
    @test name("function") == "function_"
    @test name("true") == "true_"
    @test name("r#false") == "false_"
    # A contextual keyword Julia reads as an identifier on its own keeps its name.
    @test name("mutable") == "mutable"
    @test_throws ErrorException name("a-b")
    # Every keyword Julia documents, whatever the list: a name that does not
    # parse as a plain identifier by itself is bound with an underscore, and
    # every result is a plain identifier.
    for kw in keys(Base.Docs.keywords)
        s = String(kw)
        Base.isidentifier(s) || s in ("true", "false") || continue
        bound = name(s)
        @test Meta.parse(bound) === Symbol(bound)
        @test bound == (Meta.parse(s; raise = false) isa Symbol ? s : s * "_")
    end
    # The item-kind readers all go through it.
    sig = RustCall.RustFunctionSignature("r#for", String[], String[], "i32", false, String[])
    @test RustCall.julia_function_name(sig) == "for_"
    m = RustCall.RustMethod("quote", false, false, String[], String[], "i32")
    @test RustCall.julia_method_name(m) == "quote_"
    tm = RustCall.RustMethod("r#end", false, false, String[], String[], "i32";
                             trait_path = "Tr", julia_name = "end")
    @test RustCall.julia_method_name(tm) == "end_"
    @test RustCall.julia_field_name("r#let") == "let_"
    info = RustCall.RustStructInfo("end", String[], RustCall.RustMethod[], "",
                                   Tuple{String, String}[], true, Dict{String, Bool}())
    @test RustCall.julia_struct_name(info) == "end_"
    @test RustCall._julia_module_name("r#do") == "do_"
end

@testset "a Julia keyword renamed onto a taken name is refused (#514)" begin
    sig(name; path = String[]) = RustCall.RustFunctionSignature(
        name, String[], String[], "i32", false, String[]; module_path = path)
    meth(name; kw...) = RustCall.RustMethod(name, false, false, String[], String[], "i32"; kw...)
    strct(name, methods, fields = Tuple{String, String}[]) =
        RustCall.RustStructInfo(name, String[], methods, "", fields, true, Dict{String, Bool}();
                                field_getters = Dict(f => "$(name)_get_$f" for (f, _) in fields),
                                field_setters = Dict(f => "$(name)_set_$f" for (f, _) in fields))
    check(fs, ss) = RustCall._check_module_names(RustCall._module_tree(fs, ss))
    msg(f) = try
        f(); ""
    catch err
        sprint(showerror, err)
    end
    none = RustCall.RustStructInfo[]
    # Free functions: `r#for` and `for_` are two Rust names, one Julia name.
    @test check([sig("r#for")], none) === nothing
    m = msg(() -> check([sig("r#for"), sig("for_")], none))
    @test occursin("`for_`", m) && occursin("r#for", m) && occursin("#514", m)
    # One Rust item described twice (`#[cfg]` variants) is not a clash.
    @test check([sig("r#for"), sig("r#for")], none) === nothing
    # Inside a submodule, too.
    @test_throws ErrorException check([sig("function"; path = ["a"]),
                                       sig("function_"; path = ["a"])], none)
    # Methods of one struct: an inherent `r#end` beside `end_`, and a trait's
    # `end` (bound `end_`) beside an inherent `end_`.
    @test_throws ErrorException check(RustCall.RustFunctionSignature[],
                                      [strct("S", [meth("r#end"), meth("end_")])])
    @test_throws ErrorException check(RustCall.RustFunctionSignature[],
                                      [strct("S", [meth("r#end"; trait_path = "Tr", julia_name = "end"),
                                                   meth("end_")])])
    # Two structs may each have one: that is dispatch.
    @test check(RustCall.RustFunctionSignature[],
                [strct("S", [meth("r#end")]), strct("T", [meth("end_")])]) === nothing
    # Fields of one struct.
    m = msg(() -> check(RustCall.RustFunctionSignature[],
                        [strct("S", RustCall.RustMethod[], [("r#let", "i32"), ("let_", "i32")])]))
    @test occursin("`let_`", m) && occursin("S.r#let", m)
    # A struct renamed onto a function's name, and a module onto a sibling's.
    @test_throws ErrorException check([sig("while_")], [strct("r#while", RustCall.RustMethod[])])
    @test_throws ErrorException check([sig("f"; path = ["r#do"]), sig("g"; path = ["do_"])], none)
    # The inline flavour runs the same check over a block's items.
    @test_throws ErrorException RustCall._check_julia_name_clashes(
        [sig("r#for"), sig("for_")], none, "the block")
    # The check compares what the emitters *define* at the top level
    # (`julia_definitions`), not a hand-listed set of item kinds (PR #515
    # review). Struct types share one namespace: `struct r#for` beside
    # `struct for_` would define the type `for_` twice.
    nofns = RustCall.RustFunctionSignature[]
    ctor() = RustCall.RustMethod("new", true, false, ["x"], ["i32"], "Self")
    static(name) = RustCall.RustMethod(name, true, false, ["x"], ["i32"], "i32")
    inline(fs, ss) = RustCall._check_julia_name_clashes(fs, ss, "the block")
    m = msg(() -> inline(nofns, [strct("r#for", RustCall.RustMethod[]),
                                 strct("for_", RustCall.RustMethod[])]))
    @test occursin("`for_`", m) && occursin("struct `r#for`", m) && occursin("struct `for_`", m)
    # A constructor is `T(args...)`: a free function of the type's Julia name
    # would replace it, either way round.
    @test_throws ErrorException inline([sig("while_")], [strct("r#while", [ctor()])])
    @test_throws ErrorException inline([sig("r#while")], [strct("while_", [ctor()])])
    # A module has one namespace: a type's name is taken whole, by the type
    # and its own constructors and methods. A free function of that name is
    # refused whatever the emission order.
    @test_throws ErrorException inline([sig("C")], [strct("C", RustCall.RustMethod[])])
    # So is another struct's method bound under a type's name — methods are
    # module-level generic functions (PR #515 review, raised on #517).
    m = msg(() -> inline(nofns, [strct("A", [meth("r#for")]),
                                 strct("for_", RustCall.RustMethod[])]))
    @test occursin("method `A::r#for`", m) && occursin("struct `for_`", m)
    @test_throws ErrorException check(nofns, [strct("A", [meth("r#for")]),
                                              strct("for_", RustCall.RustMethod[])])
    # A type's own method of its name adds a method to the type: allowed, as
    # for `<end as Tr>::r#end` bound `end_(self::end_)` in the crate below.
    @test inline(nofns, [strct("r#end", [meth("r#end")])]) === nothing
    # Instance methods of two structs share one generic function: overloading.
    @test inline(nofns, [strct("A", [meth("area")]), strct("B", [meth("area")])]) === nothing
    # A static method is `for_(::Type{S}, x)`; its bare `for_(x)` is withheld
    # when a free function or another static method is bound as `for_`
    # (`_static_method_collisions`), so neither of these defines `for_` twice.
    @test inline([sig("r#for")], [strct("S", [static("for_")])]) === nothing
    @test inline(nofns, [strct("S", [static("r#for")]), strct("T", [static("for_")])]) === nothing
    defs = RustCall.julia_definitions([sig("r#for")], [strct("S", [static("for_")])])
    @test count(d -> d.name == "for_" && d.scope === :free, defs) == 1
    @test any(d -> d.name == "for_" && d.scope == (:static, "S"), defs)
    # ... but a bare static form does meet another type's constructor.
    @test_throws ErrorException inline(nofns, [strct("r#for", [ctor()]),
                                              strct("S", [static("for_")])])
    # The crate expression emitter's `get_<f>` accessor meets a method of that
    # name on the same struct: both are `get_x(self::S)`.
    getter = strct("S", [meth("get_x")], [("x", "i32")])
    m = msg(() -> check(nofns, [getter]))
    @test occursin("`get_x`", m) && occursin("S::get_x", m) && occursin("S.x", m)
    @test inline(nofns, [getter]) === nothing  # a `rust"""` block defines no accessor
    # Two submodules one Julia name would bind.
    @test_throws ErrorException check([sig("f"; path = ["r#end"]), sig("g"; path = ["end_"])], none)
end

@testset "rust\"\"\" binds keyword-named items (#514)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc not available"
    else
        m = Module(:KwInlineBlock)
        Core.eval(m, :(using RustCall))
        Core.eval(m, Meta.parse("""rust\"\"\"
            #[julia]
            pub fn r#for(x: i32) -> i32 { x + 1 }

            #[julia]
            pub fn function(x: i32) -> i32 { x + 2 }

            #[julia]
            pub struct end { pub r#let: i32, pub begin: i32 }

            #[julia]
            impl end {
                pub fn new(a: i32, b: i32) -> Self { end { r#let: a, begin: b } }
                pub fn quote(&self) -> i32 { self.r#let + self.begin }
                pub fn r#true() -> i32 { 42 }
            }

            #[julia]
            pub struct r#while { pub x: i32 }

            #[julia]
            impl r#while {
                pub fn new(x: i32) -> Self { r#while { x } }
                pub fn r#if(&self) -> i32 { self.x * 2 }
            }
            \"\"\""""))
        call = Base.invokelatest
        get(n) = call(getfield, m, n)
        @test call(get(:for_), Int32(1)) == 2
        @test call(get(:function_), Int32(1)) == 3
        e = call(get(:end_), Int32(2), Int32(3))
        @test call(get(:quote_), e) == 5
        @test call(call(getproperty, e, :quote_)) == 5
        @test call(get(:true_), get(:end_)) == 42
        @test call(get(:true_)) == 42
        @test call(getproperty, e, :let_) == 2
        @test call(getproperty, e, :begin_) == 3
        call(setproperty!, e, :let_, Int32(8))
        @test call(getproperty, e, :let_) == 8
        w = call(get(:while_), Int32(5))
        @test call(get(:if_), w) == 10

        # A generic struct's raw method: its generic wrapper is registered
        # under the unraw name (`KwBoxed514_match`) the extractor gives it, and the
        # Julia method is `match` (PR #515 review).
        g = Module(:KwInlineGeneric)
        Core.eval(g, :(using RustCall))
        Core.eval(g, Meta.parse("""rust\"\"\"
            #[julia]
            pub struct KwBoxed514<T> { pub v: T }
            impl<T: Copy> KwBoxed514<T> {
                pub fn new(v: T) -> Self { KwBoxed514 { v } }
                pub fn r#match(&self) -> T { self.v }
                pub fn r#end(&self) -> T { self.v }
            }
            \"\"\""""))
        bx = call(call(getfield, g, :KwBoxed514){Int32}, Int32(6))
        @test call(call(getfield, g, :match), bx) == 6
        @test call(call(getfield, g, :end_), bx) == 6

        # `r#for` beside `for_` is refused before anything is defined.
        clash = Module(:KwInlineClash)
        Core.eval(clash, :(using RustCall))
        err = try
            Core.eval(clash, Meta.parse("""rust\"\"\"
                #[julia]
                pub fn r#for(x: i32) -> i32 { x }
                #[julia]
                pub fn for_(x: i32) -> i32 { x }
                \"\"\""""))
            nothing
        catch e
            e isa LoadError ? e.error : e
        end
        @test err isa ErrorException
        @test occursin("`for_`", sprint(showerror, err))

        # A free `fn r#for` beside static methods bound as `for_` on two
        # structs: each static method keeps its typed form and none takes the
        # bare name, so all three stay callable (#323, #514).
        st = Module(:KwInlineStatics)
        Core.eval(st, :(using RustCall))
        Core.eval(st, Meta.parse("""rust\"\"\"
            #[julia]
            pub fn r#for(x: i32) -> i32 { x + 1 }
            #[julia]
            pub struct Sa { pub v: i32 }
            #[julia]
            impl Sa { pub fn for_(x: i32) -> i32 { x + 10 } }
            #[julia]
            pub struct Sb { pub v: i32 }
            #[julia]
            impl Sb { pub fn r#for(x: i32) -> i32 { x + 100 } }
            \"\"\""""))
        sget(n) = call(getfield, st, n)
        @test call(sget(:for_), Int32(1)) == 2
        @test call(sget(:for_), sget(:Sa), Int32(1)) == 11
        @test call(sget(:for_), sget(:Sb), Int32(1)) == 101

        # ... and so are two struct types one Julia name would bind.
        types = Module(:KwInlineTypeClash)
        Core.eval(types, :(using RustCall))
        err = try
            Core.eval(types, Meta.parse("""rust\"\"\"
                #[julia]
                pub struct r#for { pub x: i32 }
                #[julia]
                pub struct for_ { pub y: i32 }
                \"\"\""""))
            nothing
        catch e
            e isa LoadError ? e.error : e
        end
        @test err isa ErrorException
        @test occursin("struct `r#for`", sprint(showerror, err))
    end
end

@testset "@rust_crate and write_bindings_to_file bind keyword-named items (#514)" begin
    if !_KW_HAVE_CARGO || !RustCall.check_rustc_available()
        @test_skip "cargo/rustc not available"
    else
        @testset "exported symbols keep the Rust side's spelling" begin
            mktempdir() do dir
                _kw_write_crate(dir, KW_CRATE)
                _, _, manifest = RustCall._crate_manifest(dir; cfg_text = RustCall._rustc_cfg_text(),
                                                          allow_cargo = false)
                syms = Set(f.symbol for f in RustCall.manifest_function_signatures(manifest))
                @test syms == Set(["rustcall_for", "rustcall_function", "rustcall_do__try"])
                structs = Dict(s.name => s for s in RustCall.manifest_struct_infos(manifest))
                e = structs["end"]
                @test Set(m.symbol for m in e.methods) ==
                      Set(["rustcall_end_new", "rustcall_end_quote", "rustcall_end_true",
                           "rustcall_end_2Tr_end"])
                # A raw field's accessor is described as the proc macro exports it.
                @test e.field_getters["r#let"] == "end_get_let"
                @test e.field_setters["r#let"] == "end_set_let"
                @test Set(m.symbol for m in structs["r#while"].methods) ==
                      Set(["rustcall_while_new", "rustcall_while_if"])
                report = RustCall.boundary_report(dir; io = devnull)
                @test isempty(report.unsupported)
            end
        end

        @testset "through @rust_crate" begin
            mktempdir() do dir
                _kw_write_crate(dir, KW_CRATE)
                bindings = @rust_crate dir name = "KwNamesBindings"
                mod = getfield(bindings, :module_ref)
                _kw_exercise(name -> Base.invokelatest(getfield, mod, name))
                # The expression emitter's field accessors follow the property.
                get(name) = Base.invokelatest(getfield, mod, name)
                e = Base.invokelatest(get(:end_), Int32(1), Int32(2))
                @test Base.invokelatest(get(:get_let_), e) == 1
                try
                    RustCall.unload_library(Base.invokelatest(getfield, mod, :_LIB_NAME); close = true)
                catch
                end
            end
        end

        @testset "through a file written by write_bindings_to_file" begin
            mktempdir() do dir
                _kw_write_crate(dir, KW_CRATE)
                output_path = joinpath(dir, "KwNames.jl")
                RustCall.write_bindings_to_file(dir, output_path;
                                                output_module_name = "KwNamesWritten")
                content = read(output_path, String)
                # The file parses as a whole...
                parsed = Meta.parseall(content)
                @test !any(ex -> ex isa Expr && ex.head in (:error, :incomplete), parsed.args)
                # A raw name survives only in the comment naming the Rust module.
                @test all(l -> startswith(lstrip(l), "#") || !occursin("r#", l),
                          split(content, '\n'))
                @test occursin("function for_(", content)
                @test occursin("mutable struct end_", content)
                @test occursin("module do_", content)
                # ... and loads, binding what @rust_crate binds.
                sandbox = Module(:KwNamesSandbox)
                Base.include(sandbox, output_path)
                mod = Base.invokelatest(getfield, sandbox, :KwNamesWritten)
                _kw_exercise(name -> Base.invokelatest(getfield, mod, name))
                try
                    RustCall.unload_library(Base.invokelatest(getfield, mod, :_LIB_NAME); close = true)
                catch
                end
            end
        end

        @testset "a keyword renamed onto a taken name is refused" begin
            mktempdir() do dir
                _kw_write_crate(dir, """
                    use rustcall_julia_macros::julia;

                    #[julia]
                    pub fn r#for(x: i32) -> i32 { x }

                    #[julia]
                    pub fn for_(x: i32) -> i32 { x }
                    """; name = "kw_clash")
                err = try
                    RustCall.write_bindings_to_file(dir, joinpath(dir, "Clash.jl"))
                    nothing
                catch e
                    e
                end
                @test err isa ErrorException
                msg = sprint(showerror, err)
                @test occursin("`for_`", msg) && occursin("r#for", msg) && occursin("#514", msg)
            end
        end

        @testset "mutually exclusive cfg variants are one item" begin
            # Bound from the scan of the build's own configuration, so only the
            # variant this build compiles is checked and bound (PR #515 review).
            mktempdir() do dir
                _kw_write_crate(dir, """
                    use rustcall_julia_macros::julia;

                    #[cfg(feature = "x")]
                    #[julia]
                    pub fn r#for(x: i32) -> i32 { x + 1 }

                    #[cfg(not(feature = "x"))]
                    #[julia]
                    pub fn for_(x: i32) -> i32 { x + 2 }
                    """; name = "kw_cfg")
                toml = joinpath(dir, "Cargo.toml")
                write(toml, replace(read(toml, String), "[dependencies]" => "[features]\nx = []\n\n[dependencies]"))
                output_path = joinpath(dir, "KwCfg.jl")
                RustCall.write_bindings_to_file(dir, output_path; output_module_name = "KwCfgWritten")
                sandbox = Module(:KwCfgSandbox)
                Base.include(sandbox, output_path)
                mod = Base.invokelatest(getfield, sandbox, :KwCfgWritten)
                @test Base.invokelatest(Base.invokelatest(getfield, mod, :for_), Int32(1)) == 3
                try
                    RustCall.unload_library(Base.invokelatest(getfield, mod, :_LIB_NAME); close = true)
                catch
                end
            end
        end
    end
end

include(joinpath(@__DIR__, "pyo3_wrapper_helpers.jl"))

@testset "@rust_crate binds a PyO3 crate's raw-named items (#514)" begin
    # A `#[pymethods] fn r#match` got the symbol `rustcall_Kw_r#match`, which
    # the wrapper crate cannot spell, so the method was silently dropped (PR
    # #517 review). Every PyO3 symbol now hangs off the unraw stem.
    mktempdir() do root
        mkpath(joinpath(root, "src"))
        write(joinpath(root, "Cargo.toml"), """
            [package]
            name = "kw_pyo3_514"
            version = "0.1.0"
            edition = "2021"
            [dependencies]
            pyo3 = { version = "0.29", default-features = false, features = ["macros"] }
            """)
        write(joinpath(root, "src", "lib.rs"), raw"""
            use pyo3::prelude::*;
            #[pyfunction]
            pub fn r#for(x: i32) -> i32 { x + 1 }
            #[pyclass]
            pub struct Kw514 { #[pyo3(get, set)] pub r#let: i32 }
            #[pymethods]
            impl Kw514 {
                #[new] pub fn new(v: i32) -> Self { Kw514 { r#let: v } }
                pub fn r#match(&self) -> i32 { self.r#let * 2 }
                pub fn r#end(&self) -> i32 { self.r#let * 3 }
            }
            """)
        info = RustCall.scan_crate(root)
        kw = only(filter(s -> s.name == "Kw514", info.pyo3_structs))
        @test Set(m.symbol for m in kw.methods) ==
              Set(["rustcall_Kw514_new", "rustcall_Kw514_match", "rustcall_Kw514_end"])
        wrapper = _link_libpython_wrapper(root)
        if wrapper === nothing
            @test_skip "no linkable Python here"
        else
            mod = (@rust_crate root).module_ref
            get(name) = Base.invokelatest(getfield, mod, name)
            call = Base.invokelatest
            @test call(get(:for_), Int32(2)) == 3
            k = call(get(:Kw514), Int32(5))
            @test call(get(:match), k) == 10
            @test call(get(:end_), k) == 15
            @test call(getproperty, k, :let_) == 5
            try
                RustCall.unload_library(call(getfield, mod, :_LIB_NAME); close = true)
            catch
            end
        end
    end
end

@testset "no emitter keys or binds a raw manifest name (#514)" begin
    # Every Julia-side use of a manifest name goes through `rust_name` (a
    # lookup, a key, a composed Rust-side name) or `julia_binding_name` (a
    # binding). A `Symbol(x.name)`, an `x.name => ...` key or an `_$(x.name)`
    # composed name in an emitter would carry a raw identifier's `r#` through;
    # this is where the #514 review findings kept coming from.
    item = "(?:f|m|s|sig|func|method|info|struct_info)"
    patterns = [Regex("Symbol\\($item\\.name\\)"), Regex("\\b$item\\.name =>"),
                Regex("_\\\$\\($item\\.name\\)")]
    src = joinpath(dirname(@__DIR__), "src")
    offenders = String[]
    for file in ("pyo3_host.jl", "crate_bindings.jl", "structs.jl", "julia_functions.jl",
                 "ruststr.jl", "julia_names.jl")
        for (n, line) in enumerate(eachline(joinpath(src, file)))
            startswith(lstrip(line), "#") && continue
            # The crate's own package name, not an item's.
            occursin("rust_crate_\$(info.name)_", line) && continue
            any(p -> occursin(p, line), patterns) && push!(offenders, "$file:$n: $(strip(line))")
        end
    end
    @test isempty(offenders)
    @test RustCall.rust_name("r#type") == "type"
    @test RustCall.rust_name("type") == "type"
end
