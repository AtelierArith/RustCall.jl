using Test
using RustCall

# `boundary_report` / `inline_boundary_report` list every argument and return
# position of the generated FFI surface that the FFI contract cannot describe
# (#441). An unsupported *return* type already fails when the wrapper is
# generated, but an unsupported *argument* compiles and only fails when it is
# called, with a layout message about the Julia value rather than the Rust
# signature. The report surfaces both before anything is built or called.

const BR_SAMPLE_CRATE = joinpath(@__DIR__, "fixtures", "sample_crate")

_br_positions(report) = Set((u.item, u.position) for u in report.unsupported)

@testset "inline_boundary_report finds what the contract cannot describe (#441)" begin
    source = raw"""
        #[julia]
        pub fn good(a: i32, s: &str, t: String) -> f64 { 0.0 }

        #[julia]
        pub fn takes_vec(v: Vec<f64>, n: i32) -> i32 { n }

        #[julia]
        pub fn gives_map(n: i32) -> std::collections::HashMap<String, i32> { Default::default() }

        #[julia]
        pub fn fallible(n: i32) -> Result<Vec<u8>, String> { Err(String::new()) }

        #[julia]
        pub fn maybe(n: i32) -> Option<i64> { None }

        #[julia]
        pub fn apply(f: extern "C" fn(i64) -> i64, x: i64) -> i64 { f(x) }

        #[julia]
        pub fn bad_callback(f: extern "C" fn(&str) -> i32) -> i32 { 0 }

        #[julia]
        pub fn generic_one<T: Copy>(x: T) -> T { x }

        #[no_mangle]
        pub extern "C" fn hand_written(v: *const u8, n: usize) -> u64 { 0 }

        #[julia]
        pub struct Handle { inner: Vec<u8> }

        #[julia]
        pub struct Fields { pub xs: Vec<f64>, pub n: i32, pub label: String }

        impl Fields {
            pub fn new() -> Self { Fields { xs: Vec::new(), n: 0, label: String::new() } }
        }

        impl Handle {
            pub fn new() -> Self { Handle { inner: Vec::new() } }
            pub fn combine(&self, other: &Handle) -> i32 { 0 }
            pub fn bytes(&self) -> Vec<u8> { self.inner.clone() }
            pub fn len(&self) -> usize { self.inner.len() }
        }
        """
    report = RustCall.inline_boundary_report(source; io = devnull)

    @test _br_positions(report) == Set([
        ("takes_vec", "argument `v`"),
        ("gives_map", "return"),
        ("fallible", "Ok payload"),
        ("Handle::combine", "argument `other`"),
        ("Handle::bytes", "return"),
        ("bad_callback", "argument `f`"),
        ("Fields::xs", "field getter"),
        # A private field gets a generated getter too (the manifest records
        # one), so its `Vec<u8>` fails generation just the same.
        ("Handle::inner", "field getter"),
    ])
    # A callback argument is checked through the plan wrapper generation uses
    # (#296), so a signature it would refuse is reported, with its reason
    # (#450 review).
    cb = only(u for u in report.unsupported if u.item == "bad_callback")
    @test occursin("parameter 1", cb.reason)
    first_vec = only(u for u in report.unsupported if u.item == "takes_vec")
    @test first_vec.rust_type == "Vec<f64>"
    @test !isempty(first_vec.reason)

    # Everything else was examined and accepted: supported scalars and strings,
    # a `Result` whose error payload is a `String`, an `Option<i64>`, a
    # callback argument, and the struct's constructor and `usize` method.
    @test report.checked > length(report.unsupported)
    # Not RustCall's surface to police: a generic item is monomorphized later,
    # and a plain `#[no_mangle]` function generates no wrapper.
    @test !any(u -> u.item in ("generic_one", "hand_written"), report.unsupported)

    # The printed summary names each position and its Rust type.
    text = sprint(io -> RustCall.inline_boundary_report(source; io))
    @test occursin("takes_vec", text) && occursin("Vec<f64>", text)
    @test occursin("8 unsupported", text)
end

@testset "a clean surface reports nothing (#441)" begin
    report = RustCall.inline_boundary_report(raw"""
        #[julia]
        pub fn add(a: i32, b: i32) -> i32 { a + b }
        """; io = devnull)
    @test isempty(report.unsupported)
    @test report.checked == 3
    @test occursin("no unsupported", sprint(io -> RustCall.inline_boundary_report(
        "#[julia]\npub fn add(a: i32, b: i32) -> i32 { a + b }"; io)))
end

@testset "boundary_report reads a crate's #[julia] surface (#441)" begin
    # The fixture crate is what `@rust_crate` binds in the rest of the suite,
    # so every position it exposes must be describable.
    report = RustCall.boundary_report(BR_SAMPLE_CRATE; io = devnull)
    @test report.checked > 0
    @test isempty(report.unsupported)

    # The integration guide's example facade keeps its whole surface describable.
    ledger = RustCall.boundary_report(joinpath(dirname(@__DIR__), "examples", "SafeLedger.jl",
                                               "deps", "safe_ledger"); io = devnull)
    @test ledger.checked == 11
    @test isempty(ledger.unsupported)

    mktempdir() do root
        crate = joinpath(root, "br_crate")
        mkpath(joinpath(crate, "src"))
        write(joinpath(crate, "Cargo.toml"), """
            [package]
            name = "br_crate"
            version = "0.1.0"
            edition = "2021"

            [lib]
            crate-type = ["cdylib"]

            [dependencies]
            rustcall_julia_macros = { path = $(repr(RustCall.rustcall_runtime_crate_path())) }
            """)
        write(joinpath(crate, "src", "lib.rs"), """
            use rustcall_julia_macros::julia;

            #[julia]
            fn total(values: Vec<f64>) -> f64 { values.iter().sum() }

            #[julia]
            pub struct Bag { items: Vec<i32> }

            #[julia]
            impl Bag {
                #[julia]
                pub fn new() -> Self { Bag { items: Vec::new() } }
                #[julia]
                pub fn items(&self) -> Vec<i32> { self.items.clone() }
                // Not attributed: `@rust_crate` does not wrap it.
                pub fn raw(&self) -> Vec<i32> { self.items.clone() }
            }
            """)
        report = RustCall.boundary_report(crate; io = devnull)
        # `items` is private, but the manifest records a getter for a `Vec`
        # field anyway, and `@rust_crate` refuses to bind `Bag` because of it
        # (checked by hand: "cannot describe the return type of
        # `Bag::items -> Vec<i32>`"), so the report names it.
        @test _br_positions(report) == Set([("total", "argument `values`"),
                                            ("Bag::items", "return"),
                                            ("Bag::items", "field getter")])
    end
end

# "Builds nothing": the crate report takes the target configuration from
# `rustc --print cfg` and never runs the Cargo probe a lenient scan would
# otherwise start (#450 review). Checked in a fresh process, where no earlier
# scan has populated the probe's memo.
@testset "boundary_report runs no Cargo (#450 review)" begin
    script = """
        using RustCall
        before = length(RustCall._CARGO_CFG_TEXT)
        RustCall.boundary_report($(repr(BR_SAMPLE_CRATE)); io = devnull)
        print(before, " ", length(RustCall._CARGO_CFG_TEXT))
        """
    out = withenv("RUSTCALL_SUPPRESS_HELPERS_WARNING" => "1") do
        readchomp(`$(Base.julia_cmd()) --startup-file=no --project=$(pkgdir(RustCall)) -e $script`)
    end
    @test out == "0 0"
end

# A readable field gets a generated getter, and an unsupported field type
# fails when the struct's Julia wrapper is generated, exactly like an
# unsupported return type (#450 review).
@testset "boundary report checks field getters (#450 review)" begin
    source = raw"""
        #[julia]
        pub struct OnlyFields { pub xs: Vec<f64>, pub n: i32 }
        impl OnlyFields { pub fn new() -> Self { OnlyFields { xs: Vec::new(), n: 0 } } }
        """
    report = RustCall.inline_boundary_report(source; io = devnull)
    @test _br_positions(report) == Set([("OnlyFields::xs", "field getter")])
    # And the report agrees with what generation does with that struct.
    scope = Module()
    Core.eval(scope, :(using RustCall))
    err = try
        Core.eval(scope, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source))
        nothing
    catch e
        e
    end
    @test err !== nothing
    @test occursin("OnlyFields::xs -> Vec<f64>", sprint(showerror, err))
end
