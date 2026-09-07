# A `#[julia] impl` block in another module than its struct (#315).
#
# The crate scan used to attach an impl block only to a struct found at the
# same file / module level, so for `struct Gauge` in `lib.rs` and
# `impl crate::Gauge` in `ops.rs` the proc-macro emitted `rustcall_Gauge_read`
# while the manifest listed `Gauge` with no methods and the Julia module had no
# `read`. The scan now collects structs and `#[julia] impl` blocks across the
# whole module tree and marries them by resolved path; a block whose header
# names no `#[julia]` struct fails the scan with the path it looked at.

using Test
using RustCall
using RustToolChain: cargo

const CMI_MACROS_PATH = joinpath(dirname(@__DIR__), "deps", "juliacall_macros")

const _CMI_HAVE_CARGO = try
    success(run(pipeline(`$(cargo()) --version`, devnull, devnull); wait = true))
catch
    false
end

# The split layout of the issue: the struct in `lib.rs`, its methods from a
# sibling file through `crate::`, from another through a `use`, and from a
# marked child module through `super::`.
function _cmi_write_split_crate(dir::AbstractString; ops_header::AbstractString = "impl crate::Gauge")
    mkpath(joinpath(dir, "src"))
    macros = replace(CMI_MACROS_PATH, "\\" => "/")
    write(joinpath(dir, "Cargo.toml"), """
        [package]
        name = "split_gauge"
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

        mod more;
        mod ops;

        #[julia]
        pub struct Gauge { pub value: i32 }

        #[julia]
        impl Gauge {
            #[julia]
            pub fn new(value: i32) -> Self { Self { value } }
        }

        #[julia]
        pub mod nested {
            use juliacall_macros::julia;

            #[julia]
            impl super::Gauge {
                #[julia]
                pub fn halved(&self) -> Result<i32, String> {
                    if self.value % 2 == 0 { Ok(self.value / 2) } else { Err(format!("{} is odd", self.value)) }
                }
            }
        }
        """)
    write(joinpath(dir, "src", "ops.rs"), """
        use juliacall_macros::julia;

        #[julia]
        $ops_header {
            #[julia]
            pub fn read(&self) -> i32 { self.value }

            #[julia]
            pub fn bump(&mut self) { self.value += 1; }
        }
        """)
    write(joinpath(dir, "src", "more.rs"), """
        use juliacall_macros::julia;
        use crate::Gauge;

        #[julia]
        impl Gauge {
            #[julia]
            pub fn label(&self) -> String { format!("Gauge({})", self.value) }
        }
        """)
    return dir
end

@testset "Cross-module #[julia] impl blocks (#315)" begin
    @testset "the scan attaches every block to the struct it names" begin
        mktempdir() do dir
            _cmi_write_split_crate(dir)
            info = RustCall.scan_crate(dir)
            @test length(info.julia_structs) == 1
            gauge = only(info.julia_structs)
            @test gauge.ffi_name == "Gauge"
            @test isempty(gauge.module_path)
            # Every method symbol follows the struct, not the module of its block.
            @test Dict(m.name => m.symbol for m in gauge.methods) ==
                  Dict("new" => "rustcall_Gauge_new", "read" => "rustcall_Gauge_read",
                       "bump" => "rustcall_Gauge_bump", "label" => "rustcall_Gauge_label",
                       "halved" => "rustcall_Gauge_halved")
            by_name = Dict(m.name => m for m in gauge.methods)
            @test by_name["bump"].is_mutable
            @test by_name["label"].return_abi == "string"
            @test by_name["halved"].return_kind == :result
        end
    end

    @testset "a block naming no #[julia] struct fails the scan, with the path" begin
        mktempdir() do dir
            _cmi_write_split_crate(dir; ops_header = "impl crate::Meter")
            err = try
                RustCall.scan_crate(dir)
                nothing
            catch e
                e
            end
            @test err isa RustCall.ExtractorError
            if err isa RustCall.ExtractorError
                @test occursin("`impl crate::Meter`", err.msg)
                @test occursin("names no #[julia] struct", err.msg)
                @test occursin("ops.rs", err.msg)
            end
        end
    end

    if !_CMI_HAVE_CARGO || !RustCall.check_rustc_available()
        @warn "cargo/rustc not available, skipping the behavioural #315 tests"
    else
        @testset "the methods are callable through @rust_crate" begin
            mktempdir() do dir
                _cmi_write_split_crate(dir)
                bindings = @rust_crate dir name="SplitGaugeBindings"
                call = Base.invokelatest
                g = call(bindings.Gauge, Int32(4))
                @test bindings.read(g) == 4
                bindings.bump(g)
                @test bindings.read(g) == 5
                @test call(getproperty, g, :value) == 5
                # The `String` buffer hangs off `Gauge_label`, the Result
                # aggregate is `CResult_Gauge_halved` (#268).
                @test bindings.label(g) == "Gauge(5)"
                odd = bindings.halved(g)
                @test odd isa RustCall.RustResult && !odd.is_ok && odd.value == "5 is odd"
                bindings.bump(g)
                even = bindings.halved(g)
                @test even.is_ok && even.value == 3
                try
                    RustCall.unload_library(getfield(bindings, :module_ref)._LIB_NAME; close = true)
                catch
                end
            end
        end

        @testset "a module written by write_bindings_to_file binds them too" begin
            mktempdir() do dir
                _cmi_write_split_crate(dir)
                output_path = joinpath(dir, "SplitGauge.jl")
                RustCall.write_bindings_to_file(dir, output_path;
                                                output_module_name = "SplitGaugeWritten")
                content = read(output_path, String)
                @test occursin("\"rustcall_Gauge_read\"", content)
                @test occursin("\"rustcall_Gauge_label\"", content)
                @test occursin("_ctor_target(\"rustcall_Gauge_new\", \"Gauge_free\")", content)

                sandbox = Module(:CmiSandbox)
                Base.include(sandbox, output_path)
                mod = Base.invokelatest(getfield, sandbox, :SplitGaugeWritten)
                get_in(m, names...) = foldl((acc, n) -> Base.invokelatest(getfield, acc, n), names; init = m)
                call = Base.invokelatest
                g = call(get_in(mod, :Gauge), Int32(6))
                @test call(get_in(mod, :read), g) == 6
                call(get_in(mod, :bump), g)
                @test call(get_in(mod, :read), g) == 7
                @test call(get_in(mod, :label), g) == "Gauge(7)"
                try
                    RustCall.unload_library(Base.invokelatest(getfield, mod, :_LIB_NAME); close = true)
                catch
                end
            end
        end
    end
end
