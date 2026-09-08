# A `#[julia] impl` block in another module than its struct (#315).
#
# The crate scan used to attach an impl block only to a struct found at the
# same file / module level, so for `struct Gauge` in `lib.rs` and
# `impl crate::Gauge` in `ops.rs` the proc-macro emitted `rustcall_Gauge_read`
# while the manifest listed `Gauge` with no methods and the Julia module had no
# `read`. The scan now collects structs and `#[julia] impl` blocks across the
# whole module tree and marries them by resolved path; a block whose header
# names no `#[julia]` struct fails the scan with the path it looked at.
#
# For an inline `rust"""` block the wrappers used to be emitted next to the
# struct, so a method whose signature named a type only its own module can see
# did not compile (#342). They are now emitted inside the impl's module, with
# string buffers of their own — and the manifest states the owner of those
# buffers per method (`Method.string_owner`) instead of leaving Julia to derive
# it from the flavour.

using Test
using RustCall
using Libdl
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

@testset "A literal include! is part of the including module (#315 review)" begin
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping the include! scan test"
    else
        mktempdir() do dir
            mkpath(joinpath(dir, "src"))
            macros = replace(CMI_MACROS_PATH, "\\" => "/")
            write(joinpath(dir, "Cargo.toml"), """
                [package]
                name = "included_items"
                version = "0.1.0"
                edition = "2021"

                [lib]
                crate-type = ["cdylib"]

                [dependencies]
                juliacall_macros = { path = "$macros" }
                """)
            # `api.rs` is reached by no `mod` declaration: rustc compiles its
            # items into the crate root, and so must the scan.
            write(joinpath(dir, "src", "api.rs"), """
                #[julia]
                pub fn included_add(a: i32, b: i32) -> i32 { a + b }
                """)
            write(joinpath(dir, "src", "table.rs"), "[1, 2, 3]\n")
            write(joinpath(dir, "src", "lib.rs"), """
                use juliacall_macros::julia;
                include!("api.rs");
                const TABLE: [i32; 3] = include!("table.rs");
                #[julia]
                pub fn root_sum() -> i32 { TABLE.iter().sum() }
                """)

            info = RustCall.scan_crate(dir)
            names = sort([f.name for f in info.julia_functions])
            @test names == ["included_add", "root_sum"]
            # The included items sit in the module that included them, so they
            # keep the crate-root symbols the proc-macro gives them (#300).
            symbols = Dict(f.name => f.symbol for f in info.julia_functions)
            @test symbols["included_add"] == "rustcall_included_add"
        end
    end
end

# ---------------------------------------------------------------------------
# #342: inline rust""" blocks — the wrapper is emitted at the impl block
# ---------------------------------------------------------------------------

@testset "#342: a cross-module wrapper is emitted inside the impl's module" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        # The issue's example verbatim: `Count` is private to `ops`, so a
        # wrapper naming it only compiles where the block is.
        source = """
        #[julia]
        pub struct Gauge { pub value: i32 }

        pub mod ops {
            type Count = i32;

            impl super::Gauge {
                pub fn read(&self) -> Count { self.value }
                pub fn label(&self) -> String { format!("Gauge({})", self.value) }
            }
        }
        """
        expanded = RustCall.expand_inline(source)
        info = only(RustCall.manifest_struct_infos(expanded.manifest))
        m = Dict(x.name => x for x in info.methods)

        # The exported symbol still follows the struct, wherever the block is.
        @test m["read"].symbol == "rustcall_Gauge_read"
        @test m["label"].symbol == "rustcall_Gauge_label"

        # The wrapper sits inside `mod ops`, spelling both the struct and the
        # module-local alias the way `ops` can see them.
        @test occursin("pub mod ops {", expanded.source)
        @test occursin("fn rustcall_Gauge_read(ptr: *const super::Gauge) -> Count",
                       expanded.source)

        # A cross-module string method declares buffers of its own, and the
        # manifest says so rather than leaving Julia to derive `Gauge_*`.
        @test m["label"].return_abi == "string"
        @test m["label"].string_owner == "Gauge_label"
        @test occursin("Gauge_label_free_rust_string", expanded.source)
        # The struct itself has no local string method, so it grows no shared
        # buffer that nothing would release.
        @test !info.has_owned_string_helper
        @test !occursin("Gauge_RustCallOwnedString", expanded.source)
    end
end

if RustCall.check_rustc_available()
    rust"""
    #[julia]
    pub struct CmiInlineGauge {
        pub value: i32,
    }

    impl CmiInlineGauge {
        pub fn new(value: i32) -> Self { CmiInlineGauge { value } }

        // Wrapped next to the struct: shares the struct's owned-string buffer.
        pub fn cmi_here(&self) -> String { format!("here({})", self.value) }
    }

    pub mod cmi_ops {
        impl super::CmiInlineGauge {
            pub fn cmi_cross_read(&self) -> i32 { self.value }

            // Wrapped inside `cmi_ops`, with a buffer of its own released
            // through `CmiInlineGauge_cmi_cross_label_free_rust_string`.
            pub fn cmi_cross_label(&self) -> String { format!("cross({})", self.value) }

            pub fn cmi_cross_split(&self, d: i32) -> Result<i32, String> {
                if d == 0 {
                    Err(format!("cannot divide {} by zero", self.value))
                } else {
                    Ok(self.value / d)
                }
            }

            pub fn cmi_cross_bump(&mut self) { self.value += 1; }
        }
    }

    // A struct with no string method of its own: nothing emits
    // `CmiFarOnly_RustCallOwnedString` / `CmiFarOnly_free_rust_string`, so a
    // consumer that derived the owner from the flavour — the struct, for the
    // inline one — would not resolve the release symbol at all (#342).
    #[julia]
    pub struct CmiFarOnly {
        pub n: i32,
    }

    impl CmiFarOnly {
        pub fn new(n: i32) -> Self { CmiFarOnly { n } }
    }

    pub mod cmi_far {
        impl super::CmiFarOnly {
            pub fn cmi_far_name(&self) -> String { format!("far({})", self.n) }

            pub fn cmi_far_split(&self, d: i32) -> Result<String, String> {
                if d == 0 { Err("zero".to_string()) } else { Ok(format!("{}", self.n / d)) }
            }
        }
    }

    #[julia]
    pub struct CmiAliased {
        pub k: i32,
    }

    impl CmiAliased {
        pub fn new(k: i32) -> Self { CmiAliased { k } }
    }

    // A renamed import: the wrapper is emitted here and can only spell the
    // struct as `Dial`, but every exported symbol keeps following the
    // resolved struct — which is what the manifest advertises (#342 review).
    pub mod cmi_alias {
        use super::CmiAliased as Dial;

        impl Dial {
            pub fn cmi_alias_name(&self) -> String { format!("dial({})", self.k) }
        }
    }
    """
end

@testset "#342: inline cross-module methods are callable, strings included" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        g = CmiInlineGauge(Int32(6))
        # A method from the block beside the struct, and one from `cmi_ops`.
        @test cmi_here(g) == "here(6)"
        @test cmi_cross_read(g) == 6
        # The owned buffer of a cross-module method is released through its own
        # `<Struct>_<method>_free_rust_string`; deriving `<Struct>_*` from the
        # inline flavour, as Julia did before #342, would not resolve.
        @test cmi_cross_label(g) == "cross(6)"
        cmi_cross_bump(g)
        @test cmi_cross_read(g) == 7
        # A `Result` payload takes the same per-method buffer.
        bad = cmi_cross_split(g, Int32(0))
        @test bad isa RustCall.RustResult && !bad.is_ok
        @test bad.value == "cannot divide 7 by zero"
        good = cmi_cross_split(g, Int32(7))
        @test good.is_ok && good.value == 1

        # `CmiFarOnly` has no local string method, so the struct-level buffer
        # does not exist: only the per-method `<Struct>_<method>` owner the
        # manifest states resolves.
        f = CmiFarOnly(Int32(9))
        @test cmi_far_name(f) == "far(9)"
        halved = cmi_far_split(f, Int32(3))
        @test halved.is_ok && halved.value == "3"

        # An owned buffer whose release symbol does not resolve is leaked in
        # silence (`_take_owned_string` skips a null `free_ptr`), so the value
        # alone cannot show that the right symbol was used. Ask for the owner
        # the emitters ask for and resolve it against the block's own library:
        # the fallback is the pre-#342 inline derivation, and it is not exported
        # here at all.
        far_info = only(RustCall.manifest_struct_infos(RustCall.expand_inline("""
            #[julia]
            pub struct CmiFarOnly { pub n: i32 }

            pub mod cmi_far {
                impl super::CmiFarOnly {
                    pub fn cmi_far_name(&self) -> String { format!("far({})", self.n) }
                }
            }
            """).manifest))
        @test !far_info.has_owned_string_helper
        far_method = only(far_info.methods)
        @test far_method.string_owner == "CmiFarOnly_cmi_far_name"
        far_target = RustCall.resolve_call_target(
            getfield(f, :lib_name), far_method.symbol;
            free_symbol = RustCall.ffi_free_symbol(
                RustCall._method_string_owner(far_method, far_info.ffi_name)))
        @test far_target.free_ptr != C_NULL

        handle = first(RustCall.RUST_LIBRARIES[getfield(f, :lib_name)])
        exports(sym) = Libdl.dlsym(handle, sym; throw_error = false) !== nothing
        @test exports("CmiFarOnly_cmi_far_name_free_rust_string")
        @test exports("CmiFarOnly_cmi_far_split_free_rust_string")
        # The owner Julia would have derived from the flavour before #342.
        @test !exports("CmiFarOnly_free_rust_string")

        # The mixed struct exports both: the shared buffer its local method
        # uses, and the per-method one of the block in `cmi_ops`.
        gauge_handle = first(RustCall.RUST_LIBRARIES[getfield(g, :lib_name)])
        gauge_exports(sym) = Libdl.dlsym(gauge_handle, sym; throw_error = false) !== nothing
        # A renamed import in the header: the call resolves only because the
        # symbols follow the resolved struct, not the alias (#342 review).
        a = CmiAliased(Int32(5))
        @test cmi_alias_name(a) == "dial(5)"
        alias_handle = first(RustCall.RUST_LIBRARIES[getfield(a, :lib_name)])
        alias_exports(sym) = Libdl.dlsym(alias_handle, sym; throw_error = false) !== nothing
        @test alias_exports("rustcall_CmiAliased_cmi_alias_name")
        @test alias_exports("CmiAliased_cmi_alias_name_free_rust_string")
        @test !alias_exports("rustcall_Dial_cmi_alias_name")

        @test gauge_exports("CmiInlineGauge_free_rust_string")
        @test gauge_exports("CmiInlineGauge_cmi_cross_label_free_rust_string")
        @test gauge_exports("CmiInlineGauge_cmi_cross_split_free_rust_string")
    end
end
