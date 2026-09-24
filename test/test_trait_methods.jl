# `@rust_crate` binds the `#[julia]` methods of a trait impl (#506).
#
# The crate scan skipped trait impls, so the proc macro exported wrappers for
# `#[julia] impl tr::A for Buf { #[julia] fn m }` that no manifest described
# and no Julia module bound; and a trait method exported the symbol an
# inherent method of the same name exports, so an inherent `m` beside a
# trait's `m` — or `m` of two traits — defined one `#[no_mangle]` symbol
# twice. Every per-method name now hangs off one method stem
# (`rustcall_julia_core::codegen::method_stem`: `m`, `1A_m`, `1B_m`), every
# trait method is in the manifest with its trait, and one whose name another
# method of the struct shares is bound as `<Trait>_<name>` while the inherent
# method keeps `name`.

using Test
using RustCall
using RustToolChain: cargo

const TM_MACROS_PATH = joinpath(dirname(@__DIR__), "deps", "rustcall_julia_macros")

const _TM_HAVE_CARGO = try
    success(run(pipeline(`$(cargo()) --version`, devnull, devnull); wait = true))
catch
    false
end

function _tm_write_crate(dir::AbstractString)
    mkpath(joinpath(dir, "src"))
    macros = replace(TM_MACROS_PATH, "\\" => "/")
    write(joinpath(dir, "Cargo.toml"), """
        [package]
        name = "trait_methods"
        version = "0.1.0"
        edition = "2021"

        [lib]
        crate-type = ["cdylib"]

        [dependencies]
        rustcall_julia_macros = { path = "$macros" }

        [workspace]
        """)
    write(joinpath(dir, "src", "lib.rs"), """
        use rustcall_julia_macros::julia;

        pub mod tr {
            pub trait A {
                fn m(&self) -> i32;
                fn make() -> i32;
                fn build(n: i32) -> Self;
                fn label(&self) -> String;
            }
        }

        pub trait B {
            fn m(&mut self, by: i32) -> i32;
            fn only_b(&self) -> i32;
        }

        #[julia]
        pub struct Buf { pub n: i32 }

        #[julia]
        impl Buf {
            #[julia]
            pub fn new(n: i32) -> Self { Buf { n } }

            #[julia]
            pub fn m(&self) -> i32 { self.n }

            #[julia]
            pub fn make() -> i32 { 1 }
        }

        #[julia]
        impl tr::A for Buf {
            #[julia]
            fn m(&self) -> i32 { self.n * 10 }

            #[julia]
            fn make() -> i32 { 2 }

            #[julia]
            fn build(n: i32) -> Self { Buf { n: n + 100 } }

            #[julia]
            fn label(&self) -> String { format!("A({})", self.n) }
        }

        #[julia]
        impl B for Buf {
            #[julia]
            fn m(&mut self, by: i32) -> i32 { self.n += by; self.n * 100 }

            #[julia]
            fn only_b(&self) -> i32 { self.n + 7 }
        }
        """)
end

# Every call a bound module must answer, `get` resolving a binding by name.
function _tm_exercise(get)
    call = Base.invokelatest
    Buf = get(:Buf)
    b = call(Buf, Int32(3))
    # The inherent `m` keeps its name; each trait's is qualified.
    @test call(get(:m), b) == 3
    @test call(get(:A_m), b) == 30
    @test call(get(:B_m), b, Int32(2)) == 500
    @test call(getproperty, b, :n) == 5
    # A trait method no other method shares a name with keeps its own.
    @test call(get(:only_b), b) == 12
    @test call(get(:label), b) == "A(5)"
    # Static methods, dispatched on the type.
    @test call(get(:make), Buf) == 1
    @test call(get(:A_make), Buf) == 2
    # A trait's `Self`-returning function is bound under its name, not as a
    # second `Buf(n)` constructor.
    built = call(get(:build), Buf, Int32(1))
    @test built isa Buf
    @test call(getproperty, built, :n) == 101
    @test call(get(:m), call(Buf, Int32(7))) == 7
end

@testset "@rust_crate binds a trait impl's #[julia] methods (#506)" begin
    if !_TM_HAVE_CARGO || !RustCall.check_rustc_available()
        @test_skip "cargo/rustc not available"
    else
        @testset "the manifest describes them, each under its own symbol" begin
            mktempdir() do dir
                _tm_write_crate(dir)
                _, _, manifest = RustCall._crate_manifest(dir; cfg_text = RustCall._rustc_cfg_text(),
                                                          allow_cargo = false)
                buf = only(RustCall.manifest_struct_infos(manifest))
                rows = Set((m.trait_path, m.name, m.symbol, RustCall.julia_method_name(m))
                           for m in buf.methods)
                @test rows == Set([
                    ("", "new", "rustcall_Buf_new", "new"),
                    ("", "m", "rustcall_Buf_m", "m"),
                    ("", "make", "rustcall_Buf_make", "make"),
                    ("tr::A", "m", "rustcall_Buf_1A_m", "A_m"),
                    ("tr::A", "make", "rustcall_Buf_1A_make", "A_make"),
                    ("tr::A", "build", "rustcall_Buf_1A_build", "build"),
                    ("tr::A", "label", "rustcall_Buf_1A_label", "label"),
                    ("B", "m", "rustcall_Buf_1B_m", "B_m"),
                    ("B", "only_b", "rustcall_Buf_1B_only_b", "only_b"),
                ])
            end
        end

        @testset "boundary_report examines every one of them" begin
            mktempdir() do dir
                _tm_write_crate(dir)
                report = RustCall.boundary_report(dir; io = devnull)
                @test isempty(report.unsupported)
                _, _, manifest = RustCall._crate_manifest(dir; cfg_text = RustCall._rustc_cfg_text(),
                                                          allow_cargo = false)
                structs = RustCall.manifest_struct_infos(manifest)
                collected = RustCall._collect_boundary() do
                    RustCall._crate_wrapper_exprs(RustCall._module_tree(
                        RustCall.manifest_function_signatures(manifest), structs))
                end
                items = Set(p.item for p in collected.positions)
                for item in ("Buf::m", "<Buf as tr::A>::m", "<Buf as tr::A>::make",
                             "<Buf as tr::A>::build", "<Buf as tr::A>::label",
                             "<Buf as B>::m", "<Buf as B>::only_b")
                    @test item in items
                end
                @test report.checked == length(collected.positions)
            end
        end

        @testset "the methods are callable through @rust_crate" begin
            mktempdir() do dir
                _tm_write_crate(dir)
                bindings = @rust_crate dir name = "TraitMethodsBindings"
                mod = getfield(bindings, :module_ref)
                _tm_exercise(name -> Base.invokelatest(getfield, mod, name))
                try
                    RustCall.unload_library(Base.invokelatest(getfield, mod, :_LIB_NAME); close = true)
                catch
                end
            end
        end

        @testset "a raw method name is written without its r# (PR #513 review)" begin
            mktempdir() do dir
                _tm_write_crate(dir)
                # A trait method spelled as a raw identifier, unique and shared.
                lib = joinpath(dir, "src", "lib.rs")
                write(lib, read(lib, String) * """

                    pub trait Raw { fn r#match(&self) -> i32; fn r#loop(&self) -> i32; }

                    #[julia]
                    impl Buf {
                        #[julia]
                        pub fn r#loop(&self) -> i32 { -1 }
                    }

                    #[julia]
                    impl Raw for Buf {
                        #[julia]
                        fn r#match(&self) -> i32 { self.n + 1000 }
                        #[julia]
                        fn r#loop(&self) -> i32 { self.n + 2000 }
                    }
                    """)
                output_path = joinpath(dir, "RawTraitMethods.jl")
                RustCall.write_bindings_to_file(dir, output_path;
                                                output_module_name = "RawTraitMethodsWritten")
                content = read(output_path, String)
                @test !occursin("function r#", content)
                sandbox = Module(:TmRawSandbox)
                Base.include(sandbox, output_path)
                mod = Base.invokelatest(getfield, sandbox, :RawTraitMethodsWritten)
                get(name) = Base.invokelatest(getfield, mod, name)
                b = Base.invokelatest(get(:Buf), Int32(4))
                @test Base.invokelatest(get(:match), b) == 1004
                @test Base.invokelatest(get(:loop), b) == -1
                @test Base.invokelatest(get(:Raw_loop), b) == 2004
                try
                    RustCall.unload_library(get(:_LIB_NAME); close = true)
                catch
                end
            end
        end

        @testset "a module written by write_bindings_to_file binds them too" begin
            mktempdir() do dir
                _tm_write_crate(dir)
                output_path = joinpath(dir, "TraitMethods.jl")
                RustCall.write_bindings_to_file(dir, output_path;
                                                output_module_name = "TraitMethodsWritten")
                content = read(output_path, String)
                for symbol in ("rustcall_Buf_m", "rustcall_Buf_1A_m", "rustcall_Buf_1B_m",
                               "rustcall_Buf_1A_build")
                    @test occursin("\"$symbol\"", content)
                end
                sandbox = Module(:TmSandbox)
                Base.include(sandbox, output_path)
                mod = Base.invokelatest(getfield, sandbox, :TraitMethodsWritten)
                _tm_exercise(name -> Base.invokelatest(getfield, mod, name))
                try
                    RustCall.unload_library(Base.invokelatest(getfield, mod, :_LIB_NAME); close = true)
                catch
                end
            end
        end
    end
end
