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

    @testset "one block defining a generic and a function of one @rust name is refused" begin
        # A generic binds no Julia wrapper, so the one-namespace check of #514
        # did not see it: `fn r#for<T>` beside `fn for_` loaded, both were
        # published under `for_`, and `@rust for_(...)` silently reached the
        # generic. Every name the `@rust` registries publish is checked now
        # (`r#try` / `try_` here: a name no other testset defines),
        # in either order, and against a hand-written export too (PR #521
        # review).
        blocks = (
            "generic first" => """
                #[julia]
                pub fn r#try<T: Copy>(x: T) -> T { x }
                #[julia]
                pub fn try_(x: i32) -> i32 { x + 100 }
                """,
            "function first" => """
                #[julia]
                pub fn try_(x: i32) -> i32 { x + 100 }
                #[julia]
                pub fn r#try<T: Copy>(x: T) -> T { x }
                """,
            "hand-written export" => """
                #[julia]
                pub fn r#try<T: Copy>(x: T) -> T { x }
                #[no_mangle]
                pub extern "C" fn try_(x: i32) -> i32 { x + 100 }
                """,
        )
        for (i, (label, rust)) in enumerate(blocks)
            @testset "$label" begin
                m = _ro_module(Symbol("ResolutionOrderClash", i))
                err = try
                    _ro_block(m, rust)
                    nothing
                catch e
                    e isa LoadError ? e.error : e
                end
                @test err isa ErrorException
                msg = err === nothing ? "" : sprint(showerror, err)
                @test occursin("`try_`", msg)
                @test occursin("r#try", msg)
                # Refused before anything is published: the module has no
                # block, and no other block defines `try_`, so neither form of
                # `@rust try_` reaches anything.
                @test !isdefined(m, :__RUSTCALL_LIBS) ||
                      isempty(RustCall._module_block_libraries(m))
                @test_throws Exception _ro_eval(m, :(@rust try_(Int32(1))::Int32))
                @test_throws Exception _ro_eval(m, :(@rust try_(Int32(1))))
            end
        end
        # The check reads the same predicate as the publishers: a refused
        # generic publishes nothing and claims no name.
        sig(name; generic = false, skip = "") = RustCall.RustFunctionSignature(
            name, String["x"], String[generic ? "T" : "i32"], generic ? "T" : "i32",
            generic, generic ? String["T"] : String[]; skip_reason = skip,
            symbol = generic ? "" : "rustcall_" * name, exported = !generic)
        check(fs) = RustCall._check_julia_name_clashes(fs, RustCall.RustStructInfo[],
                                                       "the block"; registry = fs)
        @test_throws ErrorException check([sig("r#for"; generic = true), sig("for_")])
        @test check([sig("r#for"; generic = true, skip = "unsafe_fn"), sig("for_")]) === nothing
        @test check([sig("r#for"; generic = true)]) === nothing
    end

    @testset "a generated method calls its wrapper symbol, not a name" begin
        # A method's generated Julia wrapper calls the exported symbol
        # `rustcall_<Struct>_<method>`. It went through the user-facing name
        # resolution, which asks the block's generics first, so a generic free
        # function whose Julia name happened to be that symbol captured the
        # method (PR #521 review). The generics sit in a `#[julia] mod`, where
        # they are legal Rust beside the wrappers at the crate root.
        m = _ro_module(:ResolutionOrderWrapperSymbol)
        _ro_block(m, """
            #[julia]
            pub struct Ro520S { pub v: i32 }
            #[julia]
            impl Ro520S {
                pub fn new(v: i32) -> Self { Ro520S { v } }
                pub fn scale(x: i32) -> i32 { x * 2 }
                pub fn twice(&self) -> i32 { self.v * 2 }
            }
            #[julia]
            pub mod g {
                #[julia]
                pub fn rustcall_Ro520S_scale<T: Copy>(x: T) -> T { x }
                #[julia]
                pub fn rustcall_Ro520S_twice<T: Copy>(x: T) -> T { x }
            }
            """)
        # The methods reach their own wrappers.
        @test _ro_eval(m, :(scale(Ro520S, Int32(21)))) === Int32(42)
        obj = _ro_eval(m, :(Ro520S(Int32(5))))
        @test _ro_eval(m, :(twice($obj))) === Int32(10)
        # The generic keeps its user-facing name: `@rust` still reaches it.
        @test _ro_eval(m, :(@rust rustcall_Ro520S_scale(Int32(3))::Int32)) === Int32(3)
        @test _ro_eval(m, :(@rust rustcall_Ro520S_scale(2.5))) === 2.5
    end

    @testset "a re-registered block publishes its generics with its metadata" begin
        # A block run again while its library is loaded re-registers the
        # library's metadata. The generics used to be published in a second
        # step, after `clear_library_metadata!` had dropped the library's own
        # generic row: a call from the module in between fell through to
        # another module's generic of that name and specialized its body (PR
        # #521 review). The seam runs right after the metadata transaction;
        # there the library's own generic must already be what `@rust` reaches.
        a = _ro_module(:ResolutionOrderRereg)
        b = _ro_module(:ResolutionOrderReregOther)
        block_a = """
            #[julia]
            pub fn ro520_rereg<T: Copy + std::ops::Add<Output = T>>(x: T) -> T { x + x }
            """
        lib_a = _ro_block(a, block_a)
        _ro_block(b, """
            #[julia]
            pub fn ro520_rereg<T: Copy + std::ops::Add<Output = T>>(x: T) -> T { x + x + x }
            """)
        @test _ro_eval(a, :(@rust ro520_rereg(Int32(10)))) === Int32(20)
        seen = Any[]
        hook = (stage, lib) -> begin
            stage === :registered && lib == lib_a || return
            own = get(RustCall.GENERIC_FUNCTIONS_BY_LIB, (lib_a, "ro520_rereg"), nothing)
            reached = RustCall.resolve_rust_call(nothing, lib_a, "ro520_rereg")
            push!(seen, (own !== nothing, reached isa RustCall.GenericFunctionInfo &&
                                          reached === own))
        end
        task_local_storage(RustCall._AFTER_MANIFEST_REGISTRATION, hook) do
            @test _ro_block(a, block_a) == lib_a  # the same block: a re-registration
        end
        @test !isempty(seen)
        @test all(first, seen)
        @test all(last, seen)
        @test _ro_eval(a, :(@rust ro520_rereg(Int32(10)))) === Int32(20)
        @test _ro_eval(b, :(@rust ro520_rereg(Int32(10)))) === Int32(30)

        # The transaction itself: metadata with generics installs them, and
        # a malformed generics row is refused before anything is erased.
        policy = RustCall.inline_rustc_policy()
        own = RustCall.GENERIC_FUNCTIONS_BY_LIB[(lib_a, "ro520_rereg")]
        @test_throws ArgumentError RustCall.register_artifact_metadata!(
            policy, lib_a; generics = Any["not a generic"], require_loaded = true,
            set_current = false)
        @test RustCall.GENERIC_FUNCTIONS_BY_LIB[(lib_a, "ro520_rereg")] === own
        @test RustCall.register_artifact_metadata!(
            policy, lib_a; generics = [own], require_loaded = true, set_current = false)
        @test RustCall.GENERIC_FUNCTIONS_BY_LIB[(lib_a, "ro520_rereg")] === own
    end

    @testset "a block's library key and its order are rebound together" begin
        # `_resolve_lib` rebinds a precompiled block from the library name it
        # stored to the one a reload derived. The key and the block's order
        # moved in two steps, so a concurrent first call could see the new key
        # with no order, rank the module's newest block last and call an older
        # block (PR #521 review). Pure state: the blocks are recorded, not built.
        m = _ro_module(:ResolutionOrderRebind)
        snapshot = RustCall.RustBlockSnapshot("", "", "", 0)
        RustCall._record_module_block!(m, "ro520_older", snapshot, String[])
        RustCall._record_module_block!(m, "ro520_newest", snapshot, String[])
        libs = RustCall.StateView(:libs, m)
        @test RustCall._module_block_libraries(m) == ["ro520_newest", "ro520_older"]
        RustCall._rebind_module_block!(m, libs, "ro520_newest", "ro520_renamed", snapshot)
        @test RustCall._module_block_libraries(m) == ["ro520_renamed", "ro520_older"]
        @test !haskey(libs, "ro520_newest")

        # Readers never see the rebound block ranked below an older one.
        if Threads.nthreads() >= 2
            names = ("ro520_renamed", "ro520_newest")
            done = Threads.Atomic{Bool}(false)
            writer = Threads.@spawn begin
                for i in 1:50_000
                    from, to = isodd(i) ? names : reverse(names)
                    RustCall._rebind_module_block!(m, libs, from, to, snapshot)
                end
                done[] = true
            end
            violations = 0
            reads = 0
            while !done[]
                order = RustCall._module_block_libraries(m)
                reads += 1
                (length(order) == 2 && first(order) in names) || (violations += 1)
            end
            wait(writer)
            @test violations == 0
            @test reads > 0
        else
            @test_skip "needs at least 2 threads (the 4-thread CI job runs it)"
        end

        # `_resolve_lib` rebinds through that one function, never key by key.
        source = read(joinpath(dirname(@__DIR__), "src", "rustmacro.jl"), String)
        body = source[findfirst("function _resolve_lib(", source)[1]:end]
        body = body[1:findfirst("\nend", body)[1]]
        code = join((l for l in split(body, '\n') if !startswith(strip(l), "#")), '\n')
        @test occursin("_rebind_module_block!(", code)
        @test !occursin("delete!(libs", code)
        @test !occursin("libs[actual]", code)
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

    # A caller whose own library is unloaded between the restore and the read
    # does not know whether that block defines the name, so the process-wide
    # registration — here another module's generic of the same name — must
    # not answer: the resolution restores again, or fails (PR #523 review).
    @testset "a caller's library unloaded mid-resolution is never answered by another module" begin
        a = _ro_module(:ResolutionOrderVanishA)
        b = _ro_module(:ResolutionOrderVanishB)
        lib_a = _ro_block(a, """
            #[julia]
            pub fn ro522_vanish<T: Copy + std::ops::Add<Output = T>>(x: T) -> T { x }
            """)
        _ro_block(b, """
            #[julia]
            pub fn ro522_vanish<T: Copy + std::ops::Add<Output = T>>(x: T) -> T { x + x + x }
            """)
        # B registered last: the bare name is B's.
        @test RustCall.GENERIC_FUNCTION_REGISTRY["ro522_vanish"] !==
              RustCall.GENERIC_FUNCTIONS_BY_LIB[(lib_a, "ro522_vanish")]
        # Unloaded once, right after the restore: the next attempt restores it.
        unloads = Ref(0)
        once = function (stage)
            stage === :restored && unloads[] == 0 || return
            unloads[] += 1
            RustCall.unload_library(lib_a)
        end
        result = task_local_storage(RustCall._AFTER_RUST_RESOLUTION_RESTORE, once) do
            _ro_eval(a, :(@rust ro522_vanish(Int32(5))))
        end
        @test unloads[] == 1
        @test result === Int32(5)
        # Unloaded after every restore: an error, never B's `15`.
        always = stage -> stage === :restored && RustCall.unload_library(lib_a)
        err = try
            task_local_storage(RustCall._AFTER_RUST_RESOLUTION_RESTORE, always) do
                _ro_eval(a, :(@rust ro522_vanish(Int32(6))))
            end
        catch caught
            caught
        end
        @test err isa RustCall.RustError
        @test occursin("ro522_vanish", sprint(showerror, err))
        @test _ro_eval(a, :(@rust ro522_vanish(Int32(7)))) === Int32(7)
        @test _ro_eval(b, :(@rust ro522_vanish(Int32(7)))) === Int32(21)
    end

    # The same, with the library restored again between the read of the
    # caller's rows and the check of its liveness (an unload, then a restore:
    # ABA). Deciding from two reads saw a missing row *and* a loaded library,
    # and fell through to the other module's generic (PR #523 review).
    @testset "an unload and a restore between the read and the liveness check" begin
        a = _ro_module(:ResolutionOrderAbaA)
        b = _ro_module(:ResolutionOrderAbaB)
        lib_a = _ro_block(a, """
            #[julia]
            pub fn ro522_aba<T: Copy + std::ops::Add<Output = T>>(x: T) -> T { x }
            """)
        _ro_block(b, """
            #[julia]
            pub fn ro522_aba<T: Copy + std::ops::Add<Output = T>>(x: T) -> T { x + x + x }
            """)
        b_row = RustCall.GENERIC_FUNCTION_REGISTRY["ro522_aba"]
        stages = Symbol[]
        hook = function (stage)
            push!(stages, stage)
            if stage === :restored && count(==(:restored), stages) == 1
                RustCall.unload_library(lib_a)           # A
            elseif stage === :owned_read && count(==(:owned_read), stages) == 1
                RustCall._resolve_lib(a, "")             # B: restored again
                # ...while the bare name is B's again (B re-registered).
                RustCall.GENERIC_FUNCTION_REGISTRY["ro522_aba"] = b_row
            end
        end
        result = task_local_storage(RustCall._AFTER_RUST_RESOLUTION_RESTORE, hook) do
            _ro_eval(a, :(@rust ro522_aba(Int32(5))))
        end
        @test :owned_read in stages
        @test result === Int32(5)
        @test _ro_eval(b, :(@rust ro522_aba(Int32(5)))) === Int32(15)
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
