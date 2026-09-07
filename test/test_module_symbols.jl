# Module-qualified exported symbols (#300).
#
# The exported-symbol scheme used to be `rustcall_<name>` / `<Struct>_free`
# with no module path, so two `#[julia] fn run` — or two `#[pyclass] struct C`
# — in different modules of one crate wanted the same symbol: a duplicate-symbol
# error from rustc, or a silently wrong binding. Every symbol now hangs off the
# item's FFI name (`rustcall_core::codegen::symbol_stem`): the bare name at the
# crate root, the module path folded in otherwise (`a::run` -> `a__run`,
# `_` inside a segment escaped as `_0`). A proc-macro cannot see its module, so
# `#[julia]` goes on the inline `mod` as well; the Julia side mirrors the Rust
# module tree with one submodule per module (`bindings.a.run()`).

using Test
using RustCall
using RustToolChain: cargo

const MS_MACROS_PATH = joinpath(dirname(@__DIR__), "deps", "juliacall_macros")

const _MS_HAVE_CARGO = try
    success(run(pipeline(`$(cargo()) --version`, devnull, devnull); wait = true))
catch
    false
end

# A crate with the same item names in two `#[julia]` modules, a nested module,
# underscores in module and item names, and a crate-root `run`.
function _ms_write_two_module_crate(dir::AbstractString)
    mkpath(joinpath(dir, "src"))
    macros = replace(MS_MACROS_PATH, "\\" => "/")
    write(joinpath(dir, "Cargo.toml"), """
        [package]
        name = "two_modules"
        version = "0.1.0"
        edition = "2021"

        [lib]
        crate-type = ["cdylib"]

        [dependencies]
        juliacall_macros = { path = "$macros" }

        [workspace]
        """)
    write(joinpath(dir, "src", "lib.rs"), """
        use juliacall_macros::julia;

        #[julia]
        pub fn run() -> i32 { 0 }

        #[julia]
        pub mod a {
            use juliacall_macros::julia;

            #[julia]
            pub fn run() -> i32 { 1 }

            #[julia]
            pub struct C { pub v: i32, pub label: String }

            #[julia]
            impl C {
                #[julia]
                pub fn new(v: i32) -> Self { Self { v, label: format!("a{v}") } }
                #[julia]
                pub fn get(&self) -> i32 { self.v }
                #[julia]
                pub fn describe(&self) -> String { format!("a::C({})", self.v) }
                #[julia]
                pub fn checked(&self, d: i32) -> Result<i32, String> {
                    if d == 0 { Err("zero".to_string()) } else { Ok(self.v / d) }
                }
            }

            #[julia]
            pub mod deep_er {
                use juliacall_macros::julia;

                #[julia]
                pub fn run() -> i32 { 3 }

                #[julia]
                pub fn snake_case_fn(x_1: i32) -> i32 { x_1 + 100 }
            }
        }

        #[julia]
        pub mod b {
            use juliacall_macros::julia;

            #[julia]
            pub fn run() -> i32 { 2 }

            #[julia]
            pub struct C { pub v: i32 }

            #[julia]
            impl C {
                #[julia]
                pub fn new(v: i32) -> Self { Self { v: v * 2 } }
                #[julia]
                pub fn get(&self) -> i32 { self.v }
            }
        }
        """)
    return dir
end

@testset "Module-qualified symbols (#300)" begin
    @testset "one derivation: manifest symbols carry the module path" begin
        mktempdir() do dir
            _ms_write_two_module_crate(dir)
            info = RustCall.scan_crate(dir)
            by_path = Dict((f.module_path, f.name) => f for f in info.julia_functions)
            @test by_path[(String[], "run")].symbol == "rustcall_run"
            @test by_path[(String[], "run")].ffi_name == "run"
            @test by_path[(["a"], "run")].symbol == "rustcall_a__run"
            @test by_path[(["a"], "run")].ffi_name == "a__run"
            @test by_path[(["b"], "run")].symbol == "rustcall_b__run"
            # Nested modules accumulate; underscores are escaped so `a_b::c` and
            # `a::b_c` can never meet.
            @test by_path[(["a", "deep_er"], "run")].symbol == "rustcall_a__deep_0er__run"
            @test by_path[(["a", "deep_er"], "snake_case_fn")].symbol ==
                  "rustcall_a__deep_0er__snake_0case_0fn"

            structs = Dict(s.module_path => s for s in info.julia_structs)
            @test structs[["a"]].ffi_name == "a__C"
            @test structs[["b"]].ffi_name == "b__C"
            @test structs[["a"]].field_getters["v"] == "a__C_get_v"
            @test structs[["b"]].field_setters["v"] == "b__C_set_v"
            @test Dict(m.name => m.symbol for m in structs[["a"]].methods) ==
                  Dict("new" => "rustcall_a__C_new", "get" => "rustcall_a__C_get",
                       "describe" => "rustcall_a__C_describe",
                       "checked" => "rustcall_a__C_checked")
            @test Dict(m.name => m.symbol for m in structs[["b"]].methods) ==
                  Dict("new" => "rustcall_b__C_new", "get" => "rustcall_b__C_get")
            # Every exported symbol of the crate is distinct.
            symbols = vcat([f.symbol for f in info.julia_functions],
                           [m.symbol for s in info.julia_structs for m in s.methods],
                           [RustCall.ffi_struct_free_symbol(s.ffi_name) for s in info.julia_structs],
                           [g for s in info.julia_structs for g in values(s.field_getters)])
            @test allunique(symbols)
        end
    end

    @testset "the Julia layout mirrors the Rust module tree" begin
        mktempdir() do dir
            _ms_write_two_module_crate(dir)
            info = RustCall.scan_crate(dir)
            tree = RustCall._module_tree(info)
            @test [f.name for f in tree.functions] == ["run"]
            @test isempty(tree.structs)
            @test [last(c.path) for c in tree.children] == ["a", "b"]
            a = tree.children[1]
            @test [f.name for f in a.functions] == ["run"]
            @test [s.name for s in a.structs] == ["C"]
            @test [c.path for c in a.children] == [["a", "deep_er"]]
            @test sort([f.name for f in a.children[1].functions]) == ["run", "snake_case_fn"]

            # The in-memory template: a nested `module a ... end` per module,
            # with the parent's helpers imported.
            ex = RustCall.emit_crate_module(info, "/tmp/libtwo_modules.so")
            text = string(ex)
            @test occursin("module a", text)
            @test occursin("module b", text)
            @test occursin("module deep_er", text)
            @test occursin("_call_target(\"rustcall_a__run\")", text)
            @test occursin("_call_target(\"rustcall_b__run\")", text)
            @test occursin("_call_target(\"rustcall_run\")", text)
            @test occursin("_ctor_target(\"rustcall_a__C_new\", \"a__C_free\")", text)
            @test occursin("_ctor_target(\"rustcall_b__C_new\", \"b__C_free\")", text)
            @test occursin("import .._LIB_NAME", text)
            @test occursin(".._call_target", text)
            @test occursin(".._struct_generation", text)

            # The source-text template agrees, symbol for symbol.
            code = RustCall.emit_crate_module_code(info, "/tmp/libtwo_modules.so")
            @test occursin("# Bindings format: $(RustCall.BINDINGS_FORMAT_VERSION)", code)
            @test RustCall.BINDINGS_FORMAT_VERSION >= 7
            @test occursin("\nmodule a\n", code)
            @test occursin("\nmodule b\n", code)
            @test occursin("\nmodule deep_er\n", code)
            @test occursin("end # module deep_er", code)
            @test occursin("_call_target(\"rustcall_a__deep_0er__snake_0case_0fn\")", code)
            @test occursin("_ctor_target(\"rustcall_a__C_new\", \"a__C_free\")", code)
            @test occursin("_struct_generation(\"b__C_free\")", code)
            # The per-method string buffer of `a::C::describe` is released
            # through the module-qualified owner.
            @test occursin("\"a__C_describe_free_rust_string\"", code)
            @test occursin("\"a__C_checked_free_rust_string\"", code)
            @test occursin("import .._LIB_NAME, .._LIB_GEN", code)
            @test occursin(".._ctor_target", code)
            @test Meta.parse(code) isa Expr   # well-formed Julia
        end
    end

    @testset "a module named like a parent binding is refused" begin
        # Rust keeps `fn a` and `mod a` in separate namespaces; Julia does not,
        # so the generated parent would define `a` twice. Checked on the layout,
        # with hand-built signatures — no crate needed.
        sig(name, path) = RustCall.RustFunctionSignature(name, String[], String[], "i32", false,
                                                          String[]; module_path = path)
        ok = RustCall._module_tree([sig("run", String[]), sig("run", ["a"])], RustCall.RustStructInfo[])
        @test RustCall._check_module_names(ok) === nothing
        clash = RustCall._module_tree([sig("a", String[]), sig("run", ["a"])], RustCall.RustStructInfo[])
        err = try
            RustCall._check_module_names(clash)
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("module `a`", err.msg)
        @test occursin("the function `a`", err.msg)
        @test occursin("Rename the module or the item", err.msg)
        # A struct named like a nested module, one level down.
        st = RustCall.RustStructInfo("deep", String[], RustCall.RustMethod[], "",
                                     Tuple{String, String}[], true, Dict{String, Bool}();
                                     module_path = ["a"])
        nested = RustCall._module_tree([sig("f", ["a", "deep"])], [st])
        @test_throws ErrorException RustCall._check_module_names(nested)
        # A module named like a generated helper.
        helper = RustCall._module_tree([sig("f", ["_call_target"])], RustCall.RustStructInfo[])
        @test_throws ErrorException RustCall._check_module_names(helper)
    end

    @testset "a #[julia] item in an unmarked inline module is refused" begin
        mktempdir() do dir
            _ms_write_two_module_crate(dir)
            src = read(joinpath(dir, "src", "lib.rs"), String)
            write(joinpath(dir, "src", "lib.rs"),
                  replace(src, "#[julia]\npub mod b {" => "pub mod b {"; count = 1))
            err = try
                RustCall.scan_crate(dir)
                nothing
            catch e
                e
            end
            @test err isa RustCall.ExtractorError
            msg = sprint(showerror, err)
            @test occursin("inline module `b`", msg)
            @test occursin("#[julia] pub mod b", msg)
            @test occursin("#300", msg)
        end
    end

    @testset "two file modules exporting one symbol fail closed" begin
        # File modules (`mod x;`) cannot carry the attribute and are transparent
        # to the scheme, so `x::run` and `y::run` both want `rustcall_run`. The
        # extractor reports the duplicate with both locations instead of
        # describing a library that cannot be built.
        mktempdir() do dir
            _ms_write_two_module_crate(dir)
            write(joinpath(dir, "src", "lib.rs"), "pub mod x;\npub mod y;\n")
            for m in ("x", "y")
                write(joinpath(dir, "src", "$m.rs"), """
                    use juliacall_macros::julia;
                    #[julia]
                    pub fn run() -> i32 { 1 }
                    """)
            end
            err = try
                RustCall.scan_crate(dir)
                nothing
            catch e
                e
            end
            @test err isa RustCall.ExtractorError
            msg = sprint(showerror, err)
            @test occursin("duplicate exported symbol `rustcall_run`", msg)
            @test occursin("x.rs", msg)
            @test occursin("y.rs", msg)
            @test occursin("#[julia] pub mod", msg)
        end
    end

    @testset "inline rust\"\"\" blocks qualify by the module they walk" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required"
        else
            expanded = RustCall.expand_inline("""
                mod a { #[julia] pub fn ms_inline_run() -> i32 { 1 } }
                mod b { #[julia] pub fn ms_inline_run() -> i32 { 2 } }
                """)
            sigs = RustCall.manifest_function_signatures(expanded.manifest)
            @test sort([s.symbol for s in sigs]) ==
                  ["rustcall_a__ms_0inline_0run", "rustcall_b__ms_0inline_0run"]
            @test occursin("pub extern \"C\" fn rustcall_a__ms_0inline_0run()", expanded.source)
            @test occursin("pub extern \"C\" fn rustcall_b__ms_0inline_0run()", expanded.source)
            # A `#[julia]` marker on an inline-block module is accepted and
            # stripped: it is the crate-mode spelling of the same path.
            marked = RustCall.expand_inline("#[julia] mod c { #[julia] pub fn ms_marked() -> i32 { 3 } }")
            @test only(RustCall.manifest_function_signatures(marked.manifest)).symbol ==
                  "rustcall_c__ms_0marked"
            @test !occursin("#[julia]", marked.source)

            # And a block whose modules each define a struct compiles and runs:
            # the destructors are `a__MsCell_free` / `b__MsCell_free`, not one
            # `MsCell_free` twice. (Julia names stay flat in an inline block,
            # so the second `run` wins the Julia name; the symbols do not clash.)
            rust"""
            mod ms_a {
                #[julia]
                pub struct MsCell { pub v: i32 }
                impl MsCell {
                    pub fn new(v: i32) -> Self { Self { v } }
                    pub fn twice(&self) -> i32 { self.v * 2 }
                }
                #[julia]
                pub fn ms_a_only() -> i32 { 11 }
            }
            mod ms_b {
                #[julia]
                pub fn ms_b_only() -> i32 { 22 }
            }
            """
            @test ms_a_only() == 11
            @test ms_b_only() == 22
            c = MsCell(Int32(4))
            @test twice(c) == 8
            @test c.v == 4
        end
    end

    if !_MS_HAVE_CARGO || !RustCall.check_rustc_available()
        @warn "cargo/rustc not available, skipping the behavioural #300 tests"
    else
        @testset "both `run`s and both `C`s are callable through @rust_crate" begin
            mktempdir() do dir
                _ms_write_two_module_crate(dir)
                bindings = @rust_crate dir name="TwoModulesBindings"
                call = Base.invokelatest
                @test bindings.run() == 0
                @test bindings.a.run() == 1
                @test bindings.b.run() == 2
                @test bindings.a.deep_er.run() == 3
                @test bindings.a.deep_er.snake_case_fn(Int32(5)) == 105

                ca = call(bindings.a.C, Int32(4))
                cb = call(bindings.b.C, Int32(4))
                @test bindings.a.get(ca) == 4
                @test bindings.b.get(cb) == 8          # `b::C::new` doubles
                @test call(getproperty, ca, :v) == 4
                @test call(getproperty, cb, :v) == 8
                call(setproperty!, ca, :v, Int32(7))
                @test bindings.a.get(ca) == 7
                @test call(getproperty, ca, :label) == "a4"
                # String and Result methods of `a::C`, whose buffers hang off
                # `a__C_describe` / `a__C_checked`.
                @test bindings.a.describe(ca) == "a::C(7)"
                ok = bindings.a.checked(ca, Int32(7))
                @test ok isa RustCall.RustResult && ok.is_ok && ok.value == 1
                bad = bindings.a.checked(ca, Int32(0))
                @test !bad.is_ok && bad.value == "zero"
                # Two distinct Julia types, each in its own module.
                @test call(typeof, ca) !== call(typeof, cb)
                @test nameof(parentmodule(call(typeof, ca))) == :a
                @test nameof(parentmodule(call(typeof, cb))) == :b
                try
                    RustCall.unload_library(getfield(bindings, :module_ref)._LIB_NAME; close = true)
                catch
                end
            end
        end

        @testset "a module written by write_bindings_to_file binds both `run`s" begin
            mktempdir() do dir
                _ms_write_two_module_crate(dir)
                output_path = joinpath(dir, "TwoModules.jl")
                RustCall.write_bindings_to_file(dir, output_path;
                                                output_module_name = "TwoModulesWritten")
                content = read(output_path, String)
                @test occursin("\nmodule a\n", content)
                @test occursin("\nmodule b\n", content)
                @test occursin("_call_target(\"rustcall_a__run\")", content)
                @test occursin("_ctor_target(\"rustcall_b__C_new\", \"b__C_free\")", content)

                sandbox = Module(:MsSandbox)
                Base.include(sandbox, output_path)
                mod = Base.invokelatest(getfield, sandbox, :TwoModulesWritten)
                get_in(m, names...) = foldl((acc, n) -> Base.invokelatest(getfield, acc, n), names; init = m)
                call = Base.invokelatest
                @test call(get_in(mod, :run)) == 0
                @test call(get_in(mod, :a, :run)) == 1
                @test call(get_in(mod, :b, :run)) == 2
                @test call(get_in(mod, :a, :deep_er, :run)) == 3
                ca = call(get_in(mod, :a, :C), Int32(5))
                cb = call(get_in(mod, :b, :C), Int32(5))
                @test call(get_in(mod, :a, :get), ca) == 5
                @test call(get_in(mod, :b, :get), cb) == 10
                @test call(get_in(mod, :a, :describe), ca) == "a::C(5)"
                try
                    RustCall.unload_library(Base.invokelatest(getfield, mod, :_LIB_NAME); close = true)
                catch
                end
            end
        end
    end

    @testset "PyO3: two #[pyclass] C in different modules are both wrappable" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required"
        else
            mktempdir() do dir
                mkpath(joinpath(dir, "src"))
                write(joinpath(dir, "Cargo.toml"), """
                    [package]
                    name = "two_classes"
                    version = "0.1.0"
                    edition = "2021"

                    [lib]
                    crate-type = ["rlib"]

                    [dependencies]
                    pyo3 = { version = "0.29", default-features = false, features = ["macros"] }

                    [workspace]
                    """)
                write(joinpath(dir, "src", "lib.rs"), """
                    pub mod a {
                        use pyo3::prelude::*;
                        #[pyclass]
                        pub struct C { #[pyo3(get, set)] pub v: i32 }
                        #[pymethods]
                        impl C {
                            #[new]
                            pub fn new(v: i32) -> Self { Self { v } }
                            pub fn get(&self) -> i32 { self.v }
                            pub fn name(&self) -> String { format!("a::C({})", self.v) }
                        }
                        #[pyfunction]
                        pub fn run() -> i32 { 1 }
                    }
                    pub mod b {
                        use pyo3::prelude::*;
                        #[pyclass]
                        pub struct C { #[pyo3(get, set)] pub v: i32 }
                        #[pymethods]
                        impl C {
                            #[new]
                            pub fn new(v: i32) -> Self { Self { v: v * 2 } }
                            pub fn get(&self) -> i32 { self.v }
                        }
                        #[pyfunction]
                        pub fn run() -> i32 { 2 }
                    }
                    """)
                info = RustCall.scan_crate(dir)
                @test RustCall.crate_needs_pyo3_wrapper(info)
                classes = Dict(s.module_path => s for s in info.pyo3_structs)
                @test Set(keys(classes)) == Set([["a"], ["b"]])
                @test classes[["a"]].ffi_name == "a__C"
                @test classes[["b"]].ffi_name == "b__C"
                @test all(s -> isempty(s.skip_reason), values(classes))
                @test all(m -> isempty(m.skip_reason), (m for s in values(classes) for m in s.methods))
                @test classes[["a"]].field_getters["v"] == "rustcall_a__C_get_v"
                @test classes[["b"]].field_getters["v"] == "rustcall_b__C_get_v"
                runs = Dict(f.module_path => f for f in info.pyo3_functions)
                @test runs[["a"]].symbol == "rustcall_a__run"
                @test runs[["b"]].symbol == "rustcall_b__run"
                @test all(f -> isempty(f.skip_reason), values(runs))
                # `symbol_collision` is unreachable for such a crate.
                reasons = vcat([f.skip_reason for f in info.pyo3_functions],
                               [s.skip_reason for s in info.pyo3_structs],
                               [m.skip_reason for s in info.pyo3_structs for m in s.methods])
                @test !any(r -> startswith(r, "symbol_collision"), reasons)

                # The generated wrapper source names both destructors.
                cargo_toml = RustCall.parse_cargo_toml(joinpath(dir, "Cargo.toml"))
                sources = sort(RustCall.find_rust_sources(dir))
                lib_root, tree_files = RustCall._crate_scan_inputs(dir, cargo_toml, sources)
                source = RustCall.wrap_crate(tree_files; crate_name = info.name, cfg = :lenient,
                                             crate_root = lib_root)
                @test occursin("fn a__C_free(", source.lib_rs)
                @test occursin("fn b__C_free(", source.lib_rs)
                @test occursin("fn rustcall_a__C_name(", source.lib_rs)
                @test occursin("a__C_name_free_rust_string", source.lib_rs)

                # Building and calling needs a linkable Python (see
                # test_pyo3_wrapper.jl); everything after the build is a hard
                # assertion.
                wrapper = try
                    plan = RustCall.pyo3_link_plan(dir)
                    plan.mode === :link_libpython ? RustCall.build_pyo3_wrapper(info) : nothing
                catch e
                    @info "skipping the PyO3 two-classes build" exception = e
                    nothing
                end
                if wrapper === nothing || !_MS_HAVE_CARGO
                    @test_skip "no linkable Python here: the wrapper cannot be built"
                else
                    M = @rust_crate dir name="TwoClassesBindings"
                    call = Base.invokelatest
                    @test M.a.run() == 1
                    @test M.b.run() == 2
                    ca = call(M.a.C, Int32(4))
                    cb = call(M.b.C, Int32(4))
                    @test M.a.get(ca) == 4
                    @test M.b.get(cb) == 8
                    @test M.a.name(ca) == "a::C(4)"
                    call(setproperty!, ca, :v, Int32(9))
                    @test call(getproperty, ca, :v) == 9
                    @test call(getproperty, cb, :v) == 8
                    try
                        RustCall.unload_library(getfield(M, :module_ref)._LIB_NAME; close = true)
                    catch
                    end
                end
            end
        end
    end
end
