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
        # Neither `Fields::xs` (`pub Vec<f64>`) nor `Handle::inner` (a private
        # `Vec<u8>`) is listed: a `Vec` field gets no generated getter (#453),
        # so there is nothing to describe and both structs bind as handles.
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
    @test occursin("6 unsupported", text)
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
        # The private `Vec` field `items` gets no getter (#453), so only the
        # `#[julia]` method returning a `Vec` is listed.
        @test _br_positions(report) == Set([("total", "argument `values`"),
                                            ("Bag::items", "return")])
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

# A field whose type the FFI contract cannot describe gets no getter (#453), so
# a struct holding one binds, and the report agrees with generation: it lists
# nothing for it.
@testset "a Vec field gets no getter and the struct binds (#453)" begin
    source = raw"""
        #[julia]
        pub struct OnlyFields { pub xs: Vec<f64>, pub n: i32 }
        impl OnlyFields {
            pub fn new() -> Self { OnlyFields { xs: vec![1.0, 2.0], n: 7 } }
            pub fn len(&self) -> usize { self.xs.len() }
        }
        """
    report = RustCall.inline_boundary_report(source; io = devnull)
    @test isempty(report.unsupported)
    scope = Module()
    Core.eval(scope, :(using RustCall))
    Core.eval(scope, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source))
    obj = Core.eval(scope, :(OnlyFields()))
    @test Core.eval(scope, :($obj.n)) == 7
    @test Core.eval(scope, :(len($obj))) == 2
end

# The report still checks every getter a manifest records against the contract
# generation uses: a manifest (from any extractor) claiming a getter for a type
# the contract cannot describe is reported, as generation would refuse it.
@testset "boundary report checks recorded field getters (#450 review)" begin
    manifest = RustCall.extract_manifest(raw"""
        #[julia]
        pub struct Recorded { pub n: i32 }
        impl Recorded { pub fn new() -> Self { Recorded { n: 0 } } }
        """; mode = "inline")
    field = only(only(manifest["structs"])["fields"])
    @test !isempty(field["getter"])
    field["rust_type"] = "Vec<f64>"
    report = RustCall._boundary_report(manifest, "inline block", devnull)
    @test _br_positions(report) == Set([("Recorded::n", "field getter")])
end

# Struct identity includes the module path: two `S` in different modules are
# two structs, each checked against its own fields, and reported under its
# qualified name (#450 review).
@testset "boundary report keys structs by module path (#450 review)" begin
    report = RustCall.inline_boundary_report(raw"""
        #[julia]
        pub mod a {
            #[julia]
            pub struct S { pub x: f64 }
            impl S {
                pub fn new() -> Self { S { x: 0.0 } }
                pub fn xs(&self) -> Vec<f64> { Vec::new() }
            }
        }
        #[julia]
        pub mod b {
            #[julia]
            pub struct S { pub n: i32 }
            impl S { pub fn new() -> Self { S { n: 0 } } }
            #[julia]
            pub fn f(v: Vec<u8>) -> i32 { 0 }
        }
        """; io = devnull)
    @test _br_positions(report) == Set([("a::S::xs", "return"), ("b::f", "argument `v`")])
end

# A call has `CALLBACK_SLOTS` trampoline slots; wrapper generation refuses a
# function with more callback arguments than that, so the report names the
# first one past the limit (#450 review).
@testset "boundary report enforces the callback-slot limit (#450 review)" begin
    n = RustCall.CALLBACK_SLOTS + 1
    args = join(("f$(i): extern \"C\" fn(i64) -> i64" for i in 1:n), ", ")
    report = RustCall.inline_boundary_report("#[julia]\npub fn many($(args)) -> i64 { 0 }"; io = devnull)
    @test _br_positions(report) == Set([("many", "argument `f$(n)`")])
    @test occursin(string(RustCall.CALLBACK_SLOTS), only(report.unsupported).reason)
    ok = join(("f$(i): extern \"C\" fn(i64) -> i64" for i in 1:RustCall.CALLBACK_SLOTS), ", ")
    @test isempty(RustCall.inline_boundary_report("#[julia]\npub fn most($(ok)) -> i64 { 0 }";
                                                  io = devnull).unsupported)
end

# The notes of #490: positions the contract describes but that leave something
# to the author. Recorded by the generators that decide them — the item-return
# and payload helpers for a raw pointer, the `@rust` registry for a
# hand-written export — never by the report.
@testset "boundary report notes raw-pointer returns and unguarded exports (#490)" begin
    source = raw"""
        #[no_mangle]
        pub extern "C" fn make_buf(n: usize) -> *mut u8 { std::ptr::null_mut() }

        #[no_mangle]
        pub extern "C" fn plain_add(a: i32, b: i32) -> i32 { a + b }

        #[no_mangle]
        pub extern "C" fn release_buf(p: *mut u8) {}

        #[julia]
        pub fn borrowed_bytes(n: i32) -> *const u8 { std::ptr::null() }

        #[julia]
        pub fn maybe_ptr(n: i32) -> Option<*mut i32> { None }

        #[julia]
        pub fn scalar(n: i32) -> i32 { n }

        #[julia]
        pub struct Holder { pub n: i32 }

        impl Holder {
            pub fn new() -> Self { Holder { n: 0 } }
            pub fn raw(&self) -> *const i32 { &self.n }
        }
        """
    report = RustCall.inline_boundary_report(source; io = devnull)
    # Notes are not findings: the surface is supported.
    @test isempty(report.unsupported)
    notes = Set((n.item, n.position) for n in report.notes)
    @test notes == Set([
        # A raw pointer handed back, by a `#[julia]` function, a method, a
        # payload and a hand-written export alike ...
        ("borrowed_bytes", "return"),
        ("Holder::raw", "return"),
        ("maybe_ptr", "Some payload"),
        ("make_buf", "return"),
        # ... and every hand-written export `@rust` can call, with no
        # generated panic boundary. `scalar` and the `n` getter are neither.
        ("make_buf", "entry point"),
        ("plain_add", "entry point"),
        ("release_buf", "entry point"),
    ])
    ptr = only(n for n in report.notes if n.item == "make_buf" && n.position == "return")
    @test ptr.rust_type == "*mut u8"
    @test occursin("release function", ptr.note)
    guard = only(n for n in report.notes if n.item == "plain_add")
    @test occursin("panic", guard.note)
    # Notes are not positions: `checked` counts the generated wrappers' only.
    clean = RustCall.inline_boundary_report(raw"""
        #[julia]
        pub fn scalar(n: i32) -> i32 { n }
        """; io = devnull)
    @test clean.checked == 2
    @test isempty(clean.notes)

    text = sprint(io -> RustCall.inline_boundary_report(source; io))
    @test occursin("no unsupported positions", text)
    @test occursin("7 note(s)", text)
    @test occursin("make_buf, return: *mut u8", text)

    # A crate's hand-written exports are not bound by `@rust_crate`, so
    # generation decides nothing about them and the report notes nothing for
    # them; the fixture's `#[julia]` surface returns no raw pointer.
    crate = RustCall.boundary_report(BR_SAMPLE_CRATE; io = devnull)
    @test !any(n -> n.position == "entry point", crate.notes)
end
