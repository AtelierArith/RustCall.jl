# A generic method of a non-generic inline `#[julia]` struct (#471).
#
# `rust"""` gives every `pub fn` of such a struct an `extern "C"` wrapper with a
# fixed symbol. A method generic over `T` used to get a wrapper naming the
# unbound `T`: the manifest still reported it, so the block failed at macro
# expansion with an FFI-contract error about `T`, and the expanded source did
# not compile either. The expander now refuses the method at the method, and
# the block's build fails with that one diagnostic. The two ways the message
# names — a generic free function, and a non-generic method delegating to a
# private generic one — work.
using RustCall
using Test

# Evaluate a `rust"""` block in a module of its own and return what it threw.
function _eval_block(source::String)
    m = Module(:GenericInlineMethodBlock)
    Core.eval(m, :(using RustCall))
    try
        Core.eval(m, Meta.parse("rust\"\"\"\n" * source * "\n\"\"\""))
    catch err
        return err isa LoadError ? err.error : err
    end
    return nothing
end

@testset "a generic method of a concrete inline struct is refused (#471)" begin
    err = _eval_block("""
    #[julia]
    pub struct GenericMethodAcc { pub total: i64 }
    #[julia]
    impl GenericMethodAcc {
        pub fn new() -> Self { GenericMethodAcc { total: 0 } }
        pub fn echo<T: Copy>(&self, x: T) -> T { x }
    }
    """)
    @test err isa RustCall.CompilationError
    msg = sprint(showerror, err)
    @test occursin("`GenericMethodAcc::echo` is generic over `T`", msg)
    @test occursin("generic free function", msg)
    # The one diagnostic, not rustc's complaint about generated code or the
    # FFI contract's about an unbound `T`.
    @test !occursin("cannot find type `T`", msg)
    @test !occursin("FFI contract", msg)

    err = _eval_block("""
    #[julia]
    pub struct ImplTraitMethodAcc { pub total: i64 }
    impl ImplTraitMethodAcc {
        pub fn shown(&self, x: impl Copy) -> i64 { let _ = x; self.total }
    }
    """)
    @test err isa RustCall.CompilationError
    @test occursin("`ImplTraitMethodAcc::shown` uses `impl Trait`", sprint(showerror, err))
end

@testset "the ways the refusal names work (#471)" begin
    rust"""
    #[julia]
    pub struct DelegatingAcc { pub total: i64 }
    impl DelegatingAcc {
        pub fn new(total: i64) -> Self { DelegatingAcc { total } }
        // Not `pub`: not wrapped, so it may stay generic.
        fn scaled_by<T: Copy + Into<i64>>(&self, k: T) -> i64 { self.total * k.into() }
        pub fn scaled_i32(&self, k: i32) -> i64 { self.scaled_by(k) }
    }

    #[julia]
    pub fn generic_inline_echo<T: Copy>(x: T) -> T { x }
    """
    acc = DelegatingAcc(7)
    @test Base.invokelatest(scaled_i32, acc, Int32(3)) == 21
    @test @rust(generic_inline_echo(Int32(42))::Int32) == 42
    @test @rust(generic_inline_echo(2.5)::Float64) == 2.5
end
