# One receiver model for every `#[julia]` method (#509).
#
# `MethodModel.is_mutable` used to read only the `&mut self` shorthand, so a
# method written `self: &mut Self` got a wrapper that bound the object as
# `&Buf` and failed to compile inside generated code. The receiver is now read
# in one place (`rustcall_julia_core::receiver`) as reference layers over
# `Self` or the header's own spelling of the type, and the wrapper's pointer,
# its binding, its path call and the manifest's `is_mutable` all follow from
# it. These tests call such methods from Julia, in the inline flavour and
# through `@rust_crate`, and observe the mutation.

using Test
using RustCall
using RustToolChain: cargo

const RCV_MACROS_PATH = joinpath(dirname(@__DIR__), "deps", "rustcall_julia_macros")

const _RCV_HAVE_CARGO = try
    success(run(pipeline(`$(cargo()) --version`, devnull, devnull); wait = true))
catch
    false
end

const RCV_INLINE_SOURCE = raw"""
    #[julia]
    #[derive(Clone, Copy)]
    pub struct RcvGauge {
        pub value: i32,
    }

    impl RcvGauge {
        pub fn new(value: i32) -> Self { RcvGauge { value } }
        pub fn rcv_typed_mut(self: &mut Self, by: i32) -> i32 { self.value += by; self.value }
        pub fn rcv_own_mut(self: &mut RcvGauge, by: i32) -> i32 { self.value += by; self.value }
        pub fn rcv_mut_mut(self: &mut &mut Self, by: i32) -> i32 { self.value += by; self.value }
        pub fn rcv_typed_ref(self: &Self) -> i32 { self.value }
        pub fn rcv_ref_ref(self: &&Self) -> i32 { self.value }
        pub fn rcv_copy(mut self, by: i32) -> i32 { self.value += by; self.value }
    }
    """

@testset "the manifest reads mutability from the receiver model (#509)" begin
    manifest = RustCall.extract_manifest(RCV_INLINE_SOURCE; mode = "inline")
    methods = Dict(m["name"] => m for s in manifest["structs"] for m in s["methods"])
    for (name, mutable) in ("rcv_typed_mut" => true, "rcv_own_mut" => true,
                            "rcv_mut_mut" => true, "rcv_typed_ref" => false,
                            "rcv_ref_ref" => false, "rcv_copy" => false)
        @test methods[name]["is_mutable"] == mutable
        @test !methods[name]["is_static"]
        @test isempty(get(methods[name], "skip_reason", ""))
    end
    @test methods["new"]["is_static"]
end

if RustCall.check_rustc_available()
    rust"""
    #[julia]
    #[derive(Clone, Copy)]
    pub struct RcvGauge {
        pub value: i32,
    }

    impl RcvGauge {
        pub fn new(value: i32) -> Self { RcvGauge { value } }
        pub fn rcv_typed_mut(self: &mut Self, by: i32) -> i32 { self.value += by; self.value }
        pub fn rcv_own_mut(self: &mut RcvGauge, by: i32) -> i32 { self.value += by; self.value }
        pub fn rcv_mut_mut(self: &mut &mut Self, by: i32) -> i32 { self.value += by; self.value }
        pub fn rcv_typed_ref(self: &Self) -> i32 { self.value }
        pub fn rcv_ref_ref(self: &&Self) -> i32 { self.value }
        pub fn rcv_copy(mut self, by: i32) -> i32 { self.value += by; self.value }
    }
    """
end

@testset "typed receivers are callable from an inline block (#509)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        g = RcvGauge(Int32(1))
        @test rcv_typed_mut(g, Int32(2)) == 3
        @test rcv_typed_ref(g) == 3
        @test rcv_own_mut(g, Int32(4)) == 7
        @test rcv_mut_mut(g, Int32(1)) == 8
        @test rcv_ref_ref(g) == 8
        # A by-value receiver works on a copy: the object is not changed.
        @test rcv_copy(g, Int32(100)) == 108
        @test rcv_typed_ref(g) == 8
    end
end

function _rcv_write_crate(dir::AbstractString)
    mkpath(joinpath(dir, "src"))
    macros = replace(RCV_MACROS_PATH, "\\" => "/")
    write(joinpath(dir, "Cargo.toml"), """
        [package]
        name = "receiver_forms"
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

        #[julia]
        pub struct Counter { pub n: i32 }

        #[julia]
        impl Counter {
            #[julia]
            pub fn new(n: i32) -> Self { Self { n } }

            #[julia]
            pub fn typed_add(self: &mut Self, by: i32) -> i32 { self.n += by; self.n }

            #[julia]
            pub fn own_add(self: &mut Counter, by: i32) -> i32 { self.n += by; self.n }

            #[julia]
            pub fn peek(self: &Self) -> i32 { self.n }
        }
        """)
end

@testset "typed receivers are callable through @rust_crate (#509)" begin
    if !_RCV_HAVE_CARGO || !RustCall.check_rustc_available()
        @test_skip "cargo/rustc not available"
    else
        mktempdir() do dir
            _rcv_write_crate(dir)
            bindings = @rust_crate dir name = "ReceiverFormsBindings"
            call = Base.invokelatest
            c = call(bindings.Counter, Int32(5))
            @test bindings.typed_add(c, Int32(2)) == 7
            @test bindings.own_add(c, Int32(3)) == 10
            @test bindings.peek(c) == 10
            @test call(getproperty, c, :n) == 10
            try
                RustCall.unload_library(call(getfield, getfield(bindings, :module_ref), :_LIB_NAME);
                                        close = true)
            catch
            end
        end
    end
end
