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
    end
end
