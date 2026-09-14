# Without the ownership helper library, an ownership type refuses to exist
# rather than half-working (#249, pinned for #404).
#
# `deps/rustcall_helpers` is what allocates and frees behind `RustBox` /
# `RustRc` / `RustArc` / `RustVec`. A value constructed without it could never be
# freed, so `require_rust_helpers` refuses **before** anything is allocated, and
# the refusal names the one command that fixes it. The deferred-drop queue is
# for the other order — an object that existed before the library went away —
# and must stay empty here: nothing was constructed.
#
# In-process rather than in a child with the library hidden, because what is
# under test is the refusal, and the slot is the one thing every path consults.

using RustCall
using Test

@testset "ownership types refuse to exist without the helpers (#404)" begin
    had = RustCall.RUST_HELPERS_LIB[]
    drops_before = RustCall.get_deferred_drop_count()
    try
        RustCall.RUST_HELPERS_LIB[] = nothing
        @test !RustCall.is_rust_helpers_available()
        for (label, construct) in ("RustBox" => () -> RustCall.RustBox(Int32(1)),
                                   "RustRc" => () -> RustCall.RustRc(Int32(1)),
                                   "RustArc" => () -> RustCall.RustArc(Int32(1)),
                                   "RustVec" => () -> RustCall.RustVec(Int32[1, 2]))
            err = try
                construct()
                nothing
            catch e
                e
            end
            @test err isa RustCall.RustError
            message = sprint(showerror, err)
            # The operation, the library and the remedy — not "not loaded".
            @test occursin(label, message)
            @test occursin("ownership helper library", message)
            @test occursin("Pkg.build(\"RustCall\")", message)
        end
        # Refused before allocation: nothing is waiting to be freed.
        @test RustCall.get_deferred_drop_count() == drops_before
    finally
        RustCall.RUST_HELPERS_LIB[] = had
    end
    @test RustCall.is_rust_helpers_available() == (had !== nothing)
end
