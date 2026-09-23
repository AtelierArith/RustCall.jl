# Two gaps of `rust"""` left by #471 (#477).
#
# 1. A method of a *generic* `#[julia]` struct that is generic in its own right
#    (`impl<T> W<T> { pub fn pair<U>(..) }`) used to get a generic wrapper
#    carrying `U`, which instantiating `W{Int32}` never binds: the block
#    defined, and the call failed with "Generic member 'W_pair' is unavailable".
#    The block is now refused at the method, like #471's concrete-struct case.
# 2. A method taking a struct reference with a named lifetime
#    (`pub fn sum<'a>(&self, other: &'a Buf)`) got a wrapper naming `'a`
#    without declaring it, so the block failed to compile (E0261). The wrapper
#    now declares the lifetime and the block works.
using RustCall
using Test

function _gap_eval_block(source::String)
    m = Module(:InlineGenericGapBlock)
    Core.eval(m, :(using RustCall))
    try
        Core.eval(m, Meta.parse("rust\"\"\"\n" * source * "\n\"\"\""))
    catch err
        return (m, err isa LoadError ? err.error : err)
    end
    return (m, nothing)
end

@testset "a generic method of a generic inline struct is refused (#477)" begin
    _, err = _gap_eval_block("""
    #[julia]
    pub struct GapWrap<T> { pub v: T }
    impl<T: Copy> GapWrap<T> {
        pub fn new(v: T) -> Self { GapWrap { v } }
        pub fn get(&self) -> T { self.v }
        pub fn pair<U: Copy>(&self, u: U) -> U { u }
    }
    """)
    @test err isa RustCall.CompilationError
    msg = sprint(showerror, err)
    @test occursin("`GapWrap::pair` is generic over `U`", msg)
    @test occursin("instantiated per struct type", msg)
    @test !occursin("cannot find type `U`", msg)

    # Without the method-level parameter the struct instantiates and binds.
    m, err = _gap_eval_block("""
    #[julia]
    pub struct GapWrapOk<T> { pub v: T }
    impl<T: Copy> GapWrapOk<T> {
        pub fn new(v: T) -> Self { GapWrapOk { v } }
        pub fn get(&self) -> T { self.v }
        // Not `pub`: not wrapped, so it may stay generic.
        fn pair_with<U: Copy>(&self, u: U) -> U { let _ = self.v; u }
        pub fn pair_i32(&self, u: i32) -> i32 { self.pair_with(u) }
    }
    """)
    @test err === nothing
    w = Base.invokelatest(m.GapWrapOk{Int32}, Int32(3))
    @test Base.invokelatest(m.get, w) == 3
    @test Base.invokelatest(m.pair_i32, w, Int32(9)) == 9
end

@testset "a named lifetime on a struct-reference argument compiles (#477)" begin
    m, err = _gap_eval_block("""
    #[julia]
    pub struct GapBuf { pub n: i32 }
    impl GapBuf {
        pub fn new(n: i32) -> Self { GapBuf { n } }
        pub fn get(&self) -> i32 { self.n }
        pub fn sum<'a>(&self, other: &'a GapBuf) -> i32 { self.n + other.n }
        pub fn nested<'a, 'b: 'a>(&'a self, x: &'a GapBuf, y: &'b GapBuf) -> i32 { self.n + x.n - y.n }
    }
    """)
    @test err === nothing
    a = Base.invokelatest(m.GapBuf, Int32(2))
    b = Base.invokelatest(m.GapBuf, Int32(5))
    c = Base.invokelatest(m.GapBuf, Int32(1))
    @test Base.invokelatest(m.get, a) == 2
    # A struct reference crosses as the object's pointer.
    @test Base.invokelatest(m.sum, a, b.ptr) == 7
    @test Base.invokelatest(m.nested, a, b.ptr, c.ptr) == 6
end
