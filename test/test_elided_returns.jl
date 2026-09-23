# An elided lifetime in a `rust"""` wrapper's plain return (#484).
#
# `pub fn get(&self) -> &i32` and `#[julia] pub fn f(b: &Buf) -> &i32` made the
# whole block fail inside generated code (E0106): the wrapper's receiver is a
# raw pointer, which has no lifetime for elision to pick. The wrapper now names
# the lifetime elision picks on the item, so the block compiles, and a `&T`
# return is what the C ABI says it is, a pointer. The FFI contract still has no
# row for `&T`, so under the default `FFI_STRICT = :error` the item is refused at
# the method, as a named `&'a T` return always was; `@rust f(x)::Ptr{T}` calls
# it. A return that elision ties to a lowered `&str` argument would borrow a
# string that is gone when the wrapper returns, and is refused with RustCall's
# own message.
using RustCall
using Test

function _elided_eval_block(source::String)
    m = Module(:ElidedReturnBlock)
    Core.eval(m, :(using RustCall))
    try
        Core.eval(m, Meta.parse("rust\"\"\"\n" * source * "\n\"\"\""))
    catch err
        return (m, err isa LoadError ? err.error : err)
    end
    return (m, nothing)
end

# The block's bindings are defined after this code was compiled.
_elided_latest(m, name) = Base.invokelatest(getglobal, m, name)

const _ELIDED_BLOCK = """
#[julia]
pub struct ErBuf { pub n: i32 }
impl ErBuf {
    pub fn new(n: i32) -> Self { ErBuf { n } }
    pub fn get(&self) -> &i32 { &self.n }
    pub fn get_mut(&mut self) -> &mut i32 { &mut self.n }
    pub fn with_str(&self, s: &str) -> &i32 { let _ = s; &self.n }
    pub fn val(&self) -> i32 { self.n }
}
#[julia]
pub fn er_pick(b: &ErBuf) -> &i32 { &b.n }
"""

@testset "an elided return lifetime is named on the wrapper (#484)" begin
    # Default contract: `&i32` has no row, so the method is refused by name —
    # not a rustc error inside generated code.
    _, err = _elided_eval_block(_ELIDED_BLOCK)
    @test err isa RustCall.RustError
    msg = sprint(showerror, err)
    @test occursin("`ErBuf::get() -> &i32`", msg)
    @test !occursin("E0106", msg)

    # With the contract relaxed the block compiles, and each wrapper hands back
    # a pointer into the object.
    old = RustCall.FFI_STRICT[]
    RustCall.FFI_STRICT[] = :warn
    try
        m, err = _elided_eval_block(replace(_ELIDED_BLOCK, "ErBuf" => "ErBufW",
                                            "er_pick" => "er_pick_w"))
        @test err === nothing
        b = Base.invokelatest(_elided_latest(m, :ErBufW), Int32(5))
        @test Base.invokelatest(_elided_latest(m, :val), b) == 5
        p = Core.eval(m, :(@rust rustcall_ErBufW_get($(b.ptr))::Ptr{Int32}))
        @test unsafe_load(p) == 5
        q = Core.eval(m, :(@rust rustcall_ErBufW_get_mut($(b.ptr))::Ptr{Int32}))
        @test q == p
        unsafe_store!(q, Int32(6))
        @test Base.invokelatest(_elided_latest(m, :val), b) == 6
        s = "four"
        r = GC.@preserve s Core.eval(m, :(@rust rustcall_ErBufW_with_str(
            $(b.ptr), $(pointer(s)), $(UInt(ncodeunits(s))))::Ptr{Int32}))
        @test r == p
        f = Core.eval(m, :(@rust er_pick_w($(b.ptr))::Ptr{Int32}))
        @test f == p
    finally
        RustCall.FFI_STRICT[] = old
    end
end

@testset "a return borrowed from a lowered string is refused (#484)" begin
    old = RustCall.FFI_STRICT[]
    RustCall.FFI_STRICT[] = :warn
    try
        _, err = _elided_eval_block("""
        pub static ER_N: i32 = 3;
        #[julia]
        pub fn er_from_str(s: &str) -> &i32 { let _ = s; &ER_N }
        """)
        @test err isa RustCall.CompilationError
        msg = sprint(showerror, err)
        @test occursin("`er_from_str`: the returned reference borrows from argument `s` by lifetime elision", msg)
        @test !occursin("E0106", msg)
    finally
        RustCall.FFI_STRICT[] = old
    end
end
