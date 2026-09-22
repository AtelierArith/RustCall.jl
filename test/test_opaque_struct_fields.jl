using Test
using RustCall

# A `#[julia]` struct whose fields the FFI contract cannot describe is an
# opaque handle: such a field gets no generated getter or setter, whatever its
# visibility, so the struct binds and is reached through its methods (#453).
# Before, a private `Vec<i32>` field got a getter and binding failed with
# "cannot describe the return type of `Bag::items -> Vec<i32>`".

const OSF_FIXTURE = joinpath(@__DIR__, "fixtures", "sample_crate")

_osf_cargo_ok() = try
    success(`$(RustCall.cargo()) --version`)
catch
    false
end

@testset "a private Vec field does not stop an inline struct binding (#453)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        scope = Module()
        Core.eval(scope, :(using RustCall))
        Core.eval(scope, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), raw"""
            pub struct Inner453 { a: i32 }
            #[julia]
            pub struct Bag453 { items: Vec<i32>, inner: Inner453, n: i64 }
            impl Bag453 {
                pub fn new() -> Self { Bag453 { items: vec![1, 2, 3], inner: Inner453 { a: 4 }, n: 5 } }
                pub fn count(&self) -> usize { self.items.len() }
                pub fn inner_a(&self) -> i32 { self.inner.a }
            }
            """))
        bag = Core.eval(scope, :(Bag453()))
        @test Core.eval(scope, :(count($bag))) == 3
        @test Core.eval(scope, :(inner_a($bag))) == 4
        # A field whose value crosses on its own keeps its accessor.
        @test Core.eval(scope, :($bag.n)) == 5
        @test_throws Exception Core.eval(scope, :($bag.items))
    end
end

@testset "a private Vec field does not stop @rust_crate binding (#453)" begin
    if !RustCall.check_rustc_available() || !_osf_cargo_ok()
        @test_skip "rustc and cargo are required"
    else
        mktempdir() do root
            crate = joinpath(root, "bag453")
            mkpath(joinpath(crate, "src"))
            # The fixture's lockfile pins the same dependency graph offline.
            cp(joinpath(OSF_FIXTURE, "Cargo.lock"), joinpath(crate, "Cargo.lock"))
            write(joinpath(crate, "Cargo.toml"), """
                [package]
                name = "bag453"
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
                pub struct Bag { items: Vec<i32> }

                #[julia]
                impl Bag {
                    #[julia]
                    pub fn new() -> Self { Bag { items: vec![7, 8] } }
                    #[julia]
                    pub fn count(&self) -> usize { self.items.len() }
                }
                """)
            @test isempty(RustCall.boundary_report(crate; io = devnull).unsupported)
            scope = Module()
            Core.eval(scope, :(using RustCall))
            withenv("RUSTCALL_CACHE_DIR" => joinpath(root, "cache")) do
                bindings = Core.eval(scope, Expr(:macrocall, Symbol("@rust_crate"),
                                                 LineNumberNode(1), crate, :(name = "Bag453")))
                bag = Base.invokelatest(bindings.Bag)
                @test Base.invokelatest(bindings.count, bag) == 2
            end
        end
    end
end
