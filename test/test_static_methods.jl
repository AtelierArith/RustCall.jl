# Static `#[julia]` methods dispatch on the type (#323).
#
# A static method (no `self`) used to be bound as a bare Julia function named
# after the method, so `Labeler::shout` and the crate's free `fn shout` defined
# the same `shout(::Any)` twice: the second silently overwrote the first under
# `@rust_crate`, and a module written by `write_bindings_to_file` could not be
# precompiled at all ("Method overwriting is not permitted during Module
# precompilation"). A static method is now `shout(Labeler, s)`, and it keeps the
# bare `shout(s)` form only when no free function or other static method of the
# crate has that name.

using Test
using RustCall
using RustToolChain: cargo

const SM_SAMPLE_CRATE = joinpath(@__DIR__, "fixtures", "sample_crate")

const _SM_HAVE_CARGO = try
    success(run(pipeline(`$(cargo()) --version`, devnull, devnull); wait = true))
catch
    false
end

@testset "Static methods dispatch on the type (#323)" begin
    info = RustCall.scan_crate(SM_SAMPLE_CRATE)
    colliding = RustCall._static_method_collisions(info)
    # `fn shout(String)` and `Labeler::shout(&str)` share a name; `Divider::parse_scale`
    # is the only `parse_scale`; constructors (`new`) never count.
    @test "shout" in colliding
    @test !("parse_scale" in colliding)
    @test !("new" in colliding)

    @testset "written module: one bare `shout`, a typed `Labeler` one" begin
        code = RustCall.emit_crate_module_code(info, "/tmp/libsample.so")
        # The free function keeps its bare name; the static method is typed and
        # gets no bare form, so `shout(::Any)` is defined exactly once.
        @test occursin("function shout(input)", code)
        @test occursin("function shout(::Type{Labeler}, s)", code)
        @test !occursin("shout(s) = shout(Labeler, s)", code)
        @test count("\nfunction shout(", code) == 2   # `shout(input)` and `shout(::Type{Labeler}, s)`
        # A static method that collides with nothing keeps both forms; the
        # delegator names its own arguments so that an argument called like
        # the method or the struct cannot shadow them (#325 review).
        @test occursin("function parse_scale(::Type{Divider}, text)", code)
        @test occursin("parse_scale(__rustcall_arg1) = parse_scale(Divider, __rustcall_arg1)", code)
        # Constructors are untouched: `Labeler(count)`, not `new(...)`.
        @test occursin("function Labeler(count)", code)
        @test !occursin("function new(", code)
    end

    @testset "in-memory Expr template agrees" begin
        labeler = only(filter(s -> s.name == "Labeler", info.julia_structs))
        shout_m = only(filter(m -> m.name == "shout", labeler.methods))
        # `string(::Expr)` prints the delegator as
        # `shout(__rustcall_arg1) = begin … shout(Labeler, __rustcall_arg1) end`.
        typed = string(RustCall._generate_crate_method_wrapper(labeler, shout_m; bare = false))
        @test occursin("function shout(::Type{Labeler}, s)", typed)
        @test !occursin("shout(__rustcall_arg1) = begin", typed)
        with_bare = string(RustCall._generate_crate_method_wrapper(labeler, shout_m))
        @test occursin("function shout(::Type{Labeler}, s)", with_bare)
        @test occursin("shout(__rustcall_arg1) = begin", with_bare)
        @test occursin("shout(Labeler, __rustcall_arg1)", with_bare)
        # Constructors never dispatch on the type.
        ctor = only(filter(m -> m.is_constructor, labeler.methods))
        @test occursin("function Labeler(count)", string(RustCall._generate_crate_method_wrapper(labeler, ctor)))
    end

    @testset "inline rust\"\"\" path agrees" begin
        if !RustCall.check_rustc_available()
            @warn "rustc not available, skipping the inline #323 test"
        else
            # A free `twice` and a static `Yeller::twice` in one block, plus a
            # static `thrice` that collides with nothing — whose argument is
            # named like the method, and a `Yeller`-named argument on `level`:
            # neither may shadow the function or the type in the bare
            # delegator (#325 review).
            rust"""
            #[julia]
            fn twice(x: i32) -> i32 { x * 2 }

            #[julia]
            pub struct Yeller { pub level: i32 }

            #[julia]
            impl Yeller {
                #[julia]
                pub fn new(level: i32) -> Self { Yeller { level } }
                #[julia]
                pub fn twice(x: i32) -> i32 { x * 2 + 1 }
                #[julia]
                pub fn thrice(thrice: i32) -> i32 { thrice * 3 }
                #[julia]
                pub fn level_of(Yeller: i32) -> i32 { Yeller }
            }
            """
            @test twice(Int32(5)) == 10                  # the free function, not overwritten
            @test twice(Yeller, Int32(5)) == 11          # Yeller::twice
            @test thrice(Yeller, Int32(5)) == 15         # typed form always
            @test thrice(Int32(5)) == 15                 # bare form: no collision, no shadowing
            @test level_of(Yeller, Int32(7)) == 7
            @test level_of(Int32(7)) == 7
            # `twice`: the free function's bare method plus the typed static
            # one, nothing overwritten; `thrice`: typed plus its bare delegator.
            @test length(methods(twice)) == 2
            @test length(methods(thrice)) == 2
            y = Yeller(Int32(1))
            @test y.level == 1
        end
    end

    if !_SM_HAVE_CARGO || !RustCall.check_rustc_available()
        @warn "cargo/rustc not available, skipping the behavioural #323 tests"
    else
        @testset "both `shout`s are callable, in memory" begin
            bindings = @rust_crate SM_SAMPLE_CRATE name="StaticMethodBindings"
            @test bindings.shout("hello") == "HELLO"                       # free fn (String)
            @test bindings.shout(bindings.Labeler, "hi") == "HI"           # Labeler::shout (&str)
            @test RustCall.unwrap(bindings.parse_scale(" 7 ")) == Int32(7)                 # bare form kept
            @test RustCall.unwrap(bindings.parse_scale(bindings.Divider, " 7 ")) == Int32(7)
            @test RustCall.is_err(bindings.parse_scale(bindings.Divider, "seven"))
        end

        @testset "a written module with both `shout`s loads without overwriting" begin
            output_dir = mktempdir()
            output_path = joinpath(output_dir, "StaticBindings.jl")
            try
                RustCall.write_bindings_to_file(SM_SAMPLE_CRATE, output_path;
                                                output_module_name = "StaticBindings")
                content = read(output_path, String)
                @test occursin("function shout(::Type{Labeler}, s)", content)
                @test count("\nfunction shout(", content) == 2
                # Loading the file defines every method once: with `--warn-overwrite`
                # semantics this is what precompilation checks, and here it is
                # asserted directly on the method tables.
                sandbox = Module(:StaticSandbox)
                Base.include(sandbox, output_path)
                mod = Base.invokelatest(getfield, sandbox, :StaticBindings)
                shout_f = Base.invokelatest(getfield, mod, :shout)
                sigs = [m.sig for m in methods(shout_f)]
                @test length(sigs) == 2
                @test any(s -> s.parameters[2] === Type{Base.invokelatest(getfield, mod, :Labeler)}, sigs)
                @test Base.invokelatest(shout_f, "hey") == "HEY"
                @test Base.invokelatest(shout_f, Base.invokelatest(getfield, mod, :Labeler), "hey") == "HEY"
                try
                    RustCall.unload_library(Base.invokelatest(getfield, mod, :_LIB_NAME); close = true)
                catch
                end
            finally
                rm(output_dir; recursive = true, force = true)
            end
        end
    end
end
