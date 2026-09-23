# A method's `where` predicates on its `rust"""` wrapper (#482).
#
# The wrapper declares the method's whole environment — the impl block's
# lifetimes and `where` clause, then the method's — with `Self` spelled as the
# impl's type. Before, a `Self` in an argument type or the block's own lifetime
# (`impl<'x> Buf`) made the block fail inside generated code (E0411 / E0261),
# and a `&'static str` argument failed with a borrow-checker error there; the
# first now works and the second is refused at the method.
using RustCall
using Test

function _predicate_eval_block(source::String)
    m = Module(:PredicateTransferBlock)
    Core.eval(m, :(using RustCall))
    try
        Core.eval(m, Meta.parse("rust\"\"\"\n" * source * "\n\"\"\""))
    catch err
        return (m, err isa LoadError ? err.error : err)
    end
    return (m, nothing)
end

@testset "where predicates are carried onto the wrapper (#482)" begin
    m, err = _predicate_eval_block("""
    pub trait PtTagged { fn tag() -> i32; }
    impl PtTagged for PtBuf { fn tag() -> i32 { 3 } }

    #[julia]
    pub struct PtBuf { pub n: i32 }
    impl PtBuf {
        pub fn new(n: i32) -> Self { PtBuf { n } }
        pub fn tagged(&self) -> i32 where Self: PtTagged { <Self as PtTagged>::tag() + self.n }
        pub fn times<'a>(&self, other: &'a Self) -> i32 where Self: PtTagged { self.n * other.n }
        pub fn labelled<'a, 'c>(&self, other: &'a PtBuf, s: &'c str) -> i32 where 'c: 'a { other.n + s.len() as i32 }
    }
    impl<'x> PtBuf {
        pub fn plus(&self, other: &'x PtBuf) -> i32 { self.n + other.n }
    }
    """)
    @test err === nothing
    a = Base.invokelatest(m.PtBuf, Int32(2))
    b = Base.invokelatest(m.PtBuf, Int32(5))
    @test Base.invokelatest(m.tagged, a) == 5
    # A struct reference crosses as the object's pointer.
    @test Base.invokelatest(m.times, a, b.ptr) == 10
    @test Base.invokelatest(m.labelled, a, b.ptr, "four") == 9
    @test Base.invokelatest(m.plus, a, b.ptr) == 7
end

@testset "a lowered string that must outlive the call is refused (#482)" begin
    _, err = _predicate_eval_block("""
    #[julia]
    pub struct PtRefused { pub n: i32 }
    impl PtRefused {
        pub fn new(n: i32) -> Self { PtRefused { n } }
        pub fn keep(&self, s: &'static str) -> i32 { s.len() as i32 }
    }
    """)
    @test err isa RustCall.CompilationError
    msg = sprint(showerror, err)
    @test occursin("`PtRefused::keep`: argument `s` arrives from Julia as a pointer and a length", msg)
    @test occursin("cannot be borrowed for `'static`", msg)
    @test !occursin("does not live long enough", msg)
end
