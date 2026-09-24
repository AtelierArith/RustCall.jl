# One resolution order for every `@rust` form (#520).
#
# The typed `@rust f(x)::T` tried the symbol tables — across every loaded
# library — before the generic registry, and the untyped `@rust f(x)` asked the
# generic registry first; both registries were process-wide. So a plain `for_`
# of an unrelated block shadowed a module's own generic `for_` under `::T`, and
# that generic captured the other module's untyped call. `resolve_rust_call`
# now decides for every form: the caller's own blocks — functions and generics
# together — first, then the documented fallback; and a block's generics are
# owned by its library (`GENERIC_FUNCTIONS_BY_LIB`) as its exports are.

using Test
using RustCall

# A fresh module with `using RustCall`, and a way to run code in it in the
# latest world (the `rust"""` block defines bindings the next statement reads).
function _ro_module(name::Symbol)
    m = Module(name)
    Core.eval(m, :(using RustCall))
    return m
end
_ro_eval(m::Module, code::AbstractString) = Base.invokelatest(Core.eval, m, Meta.parse(code))
_ro_eval(m::Module, ex::Expr) = Base.invokelatest(Core.eval, m, ex)
_ro_block(m::Module, rust::AbstractString) =
    _ro_eval(m, "rust\"\"\"\n" * rust * "\n\"\"\"")

@testset "@rust resolution order (#520)" begin
    @testset "a module's own generic is not shadowed by another block's function" begin
        # The issue's case: a generic `r#for` (Julia name `for_`) in A, a
        # plain one in B.
        a = _ro_module(:ResolutionOrderA)
        b = _ro_module(:ResolutionOrderB)
        lib_a = _ro_block(a, """
            #[julia]
            pub fn r#for<T: Copy>(x: T) -> T { x }
            """)
        lib_b = _ro_block(b, """
            #[julia]
            pub fn r#for(x: i32) -> i32 { x + 100 }
            """)

        # From A: A's generic, typed and untyped — and it really specializes,
        # so a `Float64` works too.
        @test _ro_eval(a, :(@rust for_(Int32(1))::Int32)) === Int32(1)
        @test _ro_eval(a, :(@rust for_(Int32(1)))) === Int32(1)
        @test _ro_eval(a, :(@rust for_(2.5)::Float64)) === 2.5
        # From B: B's function, typed and untyped.
        @test _ro_eval(b, :(@rust for_(Int32(1))::Int32)) === Int32(101)
        @test _ro_eval(b, :(@rust for_(Int32(1)))) === Int32(101)

        # Warm call sites keep answering the same (the cached path).
        _ro_eval(a, :(ro_typed(x) = @rust for_(x)::Int32))
        _ro_eval(b, :(ro_typed(x) = @rust for_(x)::Int32))
        _ro_eval(a, :(ro_untyped(x) = @rust for_(x)))
        _ro_eval(b, :(ro_untyped(x) = @rust for_(x)))
        for _ in 1:3
            @test _ro_eval(a, :(ro_typed(Int32(5)))) === Int32(5)
            @test _ro_eval(b, :(ro_typed(Int32(5)))) === Int32(105)
            @test _ro_eval(a, :(ro_untyped(Int32(5)))) === Int32(5)
            @test _ro_eval(b, :(ro_untyped(Int32(5)))) === Int32(105)
        end

        # The entry points that take a library name follow the same order,
        # with that library as the caller's own.
        @test RustCall._rust_call_dynamic(lib_a, "for_", Int32(7)) === Int32(7)
        @test RustCall._rust_call_dynamic(lib_b, "for_", Int32(7)) === Int32(107)
        @test RustCall._rust_call_typed(lib_a, "for_", Int32, Int32(7)) === Int32(7)
        @test RustCall._rust_call_typed(lib_b, "for_", Int32, Int32(7)) === Int32(107)

        # A hand-written export of that name elsewhere keeps its manifest
        # return type, so an unannotated call works: another module's generic
        # of the name used to suppress the hint process-wide.
        p = _ro_module(:ResolutionOrderPlainExport)
        _ro_block(p, """
            #[no_mangle]
            pub extern "C" fn for_(x: i32) -> i32 { x + 200 }
            """)
        @test _ro_eval(p, :(@rust for_(Int32(1)))) === Int32(201)
        @test _ro_eval(a, :(@rust for_(Int32(1)))) === Int32(1)

        # Each library owns its own row; the plain function registers none.
        @test haskey(RustCall.GENERIC_FUNCTIONS_BY_LIB, (lib_a, "for_"))
        @test !haskey(RustCall.GENERIC_FUNCTIONS_BY_LIB, (lib_b, "for_"))
    end

    @testset "two modules' generics of one name are each their own" begin
        a = _ro_module(:ResolutionOrderGenA)
        b = _ro_module(:ResolutionOrderGenB)
        _ro_block(a, """
            #[julia]
            pub fn ro520_scale<T: Copy + std::ops::Add<Output = T>>(x: T) -> T { x + x }
            """)
        _ro_block(b, """
            #[julia]
            pub fn ro520_scale<T: Copy + std::ops::Add<Output = T>>(x: T) -> T { x + x + x }
            """)
        # B registered last; A still reaches its own.
        @test _ro_eval(a, :(@rust ro520_scale(Int32(10)))) === Int32(20)
        @test _ro_eval(a, :(@rust ro520_scale(Int32(10))::Int32)) === Int32(20)
        @test _ro_eval(b, :(@rust ro520_scale(Int32(10)))) === Int32(30)
        @test _ro_eval(b, :(@rust ro520_scale(Int32(10))::Int32)) === Int32(30)
        # Different sources, so different instantiations, not one shared entry.
        @test _ro_eval(a, :(@rust ro520_scale(1.5))) === 3.0
        @test _ro_eval(b, :(@rust ro520_scale(1.5))) === 4.5
        # The bare name is the process-wide registration: the one made last.
        @test RustCall.call_generic_function("ro520_scale", Int32(10)) === Int32(30)
    end

    @testset "the fallback: a name none of the caller's blocks defines" begin
        # A module with a block of its own that does not define the name: the
        # process-wide generic registration answers first, then another
        # library's export (the cross-block call).
        g = _ro_module(:ResolutionOrderFallbackGeneric)
        f = _ro_module(:ResolutionOrderFallbackFn)
        c = _ro_module(:ResolutionOrderFallbackCaller)
        _ro_block(g, """
            #[julia]
            pub fn ro520_fallback_generic<T: Copy>(x: T) -> T { x }
            """)
        _ro_block(f, """
            #[julia]
            pub fn ro520_fallback_fn(x: i32) -> i32 { x * 3 }
            """)
        _ro_block(c, """
            #[julia]
            pub fn ro520_unrelated(x: i32) -> i32 { x }
            """)
        @test _ro_eval(c, :(@rust ro520_fallback_generic(Int32(4))::Int32)) === Int32(4)
        @test _ro_eval(c, :(@rust ro520_fallback_generic(Int32(4)))) === Int32(4)
        @test _ro_eval(c, :(@rust ro520_fallback_fn(Int32(4))::Int32)) === Int32(12)
        @test _ro_eval(c, :(@rust ro520_fallback_fn(Int32(4)))) === Int32(12)
    end

    @testset "a later block of one module redefines a name, whatever its kind" begin
        m = _ro_module(:ResolutionOrderLater)
        _ro_block(m, """
            #[julia]
            pub fn ro520_later(x: i32) -> i32 { x + 1 }
            """)
        # Warm call sites on the function...
        _ro_eval(m, :(ro_typed(x) = @rust ro520_later(x)::Int32))
        _ro_eval(m, :(ro_untyped(x) = @rust ro520_later(x)))
        @test _ro_eval(m, :(ro_typed(Int32(1)))) === Int32(2)
        @test _ro_eval(m, :(ro_untyped(Int32(1)))) === Int32(2)
        # ... then a later block of the same module defines a generic of that
        # name. Registering it is a state write, so the kept snapshots are
        # dropped and both call sites resolve again — to the later block, as a
        # later block's plain function always did (the module's active block).
        _ro_block(m, """
            #[julia]
            pub fn ro520_later<T: Copy>(x: T) -> T { x }
            """)
        @test _ro_eval(m, :(ro_typed(Int32(1)))) === Int32(1)
        @test _ro_eval(m, :(ro_untyped(Int32(1)))) === Int32(1)
        # And back: a function in a still later block wins over the generic.
        _ro_block(m, """
            #[no_mangle]
            pub extern "C" fn ro520_later(x: i32) -> i32 { x + 1000 }
            """)
        @test _ro_eval(m, :(ro_typed(Int32(1)))) === Int32(1001)
        @test _ro_eval(m, :(ro_untyped(Int32(1)))) === Int32(1001)
    end

    @testset "a re-registered generic of one module: the last one answers" begin
        # An edited block run again leaves the earlier library loaded; the
        # later block is the one a call means, as it always was.
        m = _ro_module(:ResolutionOrderEdited)
        _ro_block(m, """
            #[julia]
            pub fn ro520_edited<T: Copy>(x: T) -> T { x }
            """)
        @test _ro_eval(m, :(@rust ro520_edited(Int32(3)))) === Int32(3)
        _ro_block(m, """
            #[julia]
            pub fn ro520_edited<T: Copy + std::ops::Add<Output = T>>(x: T) -> T { x + x }
            """)
        @test _ro_eval(m, :(@rust ro520_edited(Int32(3)))) === Int32(6)
        @test _ro_eval(m, :(@rust ro520_edited(Int32(3))::Int32)) === Int32(6)
    end

    @testset "a library's generic rows go with it" begin
        m = _ro_module(:ResolutionOrderUnload)
        lib = _ro_block(m, """
            #[julia]
            pub fn ro520_gone<T: Copy>(x: T) -> T { x }
            """)
        @test haskey(RustCall.GENERIC_FUNCTIONS_BY_LIB, (lib, "ro520_gone"))
        RustCall.unload_library(lib)
        @test !haskey(RustCall.GENERIC_FUNCTIONS_BY_LIB, (lib, "ro520_gone"))
    end

    @testset "one function decides, for every form" begin
        # Source-level: the four `@rust` entry points ask `resolve_rust_call`
        # and nothing else decides generic-or-function; it restores the
        # caller's blocks before it resolves anything.
        source = read(joinpath(dirname(@__DIR__), "src", "rustmacro.jl"), String)
        code_of(name) = begin
            body = source[findfirst("function $(name)(", source)[1]:end]
            body = body[1:findfirst("\nend", body)[1]]
            join((line for line in split(body, '\n')
                  if !startswith(strip(line), "#")), '\n')
        end
        for entry in ("_rust_call_dynamic", "_rust_call_typed",
                      "_rust_call_dynamic_cached", "_rust_call_typed_uncached")
            code = code_of(entry)
            @test occursin("resolve_rust_call(", code)
            @test !occursin("is_generic_function(", code)
            @test !occursin("resolve_call_target(", code)
            @test !occursin("GENERIC_FUNCTION_REGISTRY", code)
        end
        resolver = code_of("resolve_rust_call")
        @test findfirst("_resolve_lib(", resolver)[1] < findfirst("artifact_epoch()", resolver)[1]
        @test findfirst("artifact_epoch()", resolver)[1] <
              findfirst("resolve_call_target(", resolver)[1]
        @test !occursin("try", resolver)
    end
end
