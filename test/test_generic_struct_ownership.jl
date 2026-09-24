# Generic struct groups belong to the block that defines them (#522).
#
# A generic `#[julia]` struct registers its wrappers (`Boxed_new`,
# `Boxed_tag`, `Boxed_free`, ...) for on-demand monomorphization. They were
# registered process-wide by that bare name and grouped by the struct's name
# alone, so two modules that each defined a generic `Boxed` shared one set:
# the later registration replaced the earlier one, and constructing the first
# module's `Boxed` ran the second module's source. The members are now owned
# by the library of the defining block (`GenericFunctionInfo.owner`,
# `GENERIC_FUNCTIONS_BY_LIB`), the generated code resolves them from its own
# module through `resolve_rust_call` (#520), and they go with the library.
#
# The struct is deliberately called `Boxed`: `test_generic_struct.jl` and
# `test_julia_keyword_names.jl` define generic structs of that name too, and
# may share this test worker.

using Test
using RustCall

function _own_module(name::Symbol)
    m = Module(name)
    Core.eval(m, :(using RustCall))
    return m
end
_own_eval(m::Module, code::AbstractString) = Base.invokelatest(Core.eval, m, Meta.parse(code))
_own_block(m::Module, rust::AbstractString) = _own_eval(m, "rust\"\"\"\n" * rust * "\n\"\"\"")
_own_call(f, args...) = Base.invokelatest(f, args...)
_own_get(m::Module, name::Symbol) = Base.invokelatest(getfield, m, name)

# A generic `Boxed` whose `tag` answers `tag`. `pad` changes the layout, so a
# field read through the other module's wrapper would read the wrong offset.
_boxed_source(tag; pad = false) = """
    #[julia]
    pub struct Boxed<T> { $(pad ? "pub pad: i64, " : "")pub v: T }
    impl<T: Copy> Boxed<T> {
        pub fn new(v: T) -> Self { Boxed { $(pad ? "pad: 99, " : "")v } }
        pub fn tag(&self) -> i32 { $tag }
        pub fn twice(&self) -> T where T: std::ops::Add<Output = T> { self.v + self.v }
    }
    """

_boxed(m::Module, ::Type{T}, v) where {T} = _own_call(_own_get(m, :Boxed){T}, T(v))
_tag(m::Module, obj) = _own_call(_own_get(m, :tag), obj)
_twice(m::Module, obj) = _own_call(_own_get(m, :twice), obj)
# The member a block's library registered: what that block's struct reaches.
_own_row(lib, member) = RustCall.GENERIC_FUNCTIONS_BY_LIB[(lib, member)]

@testset "generic struct groups are owned by their block (#522)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc not found"
        return
    end

    a = _own_module(:GenericOwnerA)
    b = _own_module(:GenericOwnerB)
    lib_a = _own_block(a, _boxed_source(1))
    lib_b = _own_block(b, _boxed_source(2; pad = true))
    @test lib_a != lib_b

    @testset "each module reaches its own struct" begin
        # B registered last; A still builds and calls its own.
        for T in (Int32, Float64)
            xa = _boxed(a, T, 5)
            xb = _boxed(b, T, 7)
            @test _tag(a, xa) == 1
            @test _tag(b, xb) == 2
            @test _twice(a, xa) == T(10)
            @test _twice(b, xb) == T(14)
            @test _own_call(getproperty, xa, :v) == T(5)
            @test _own_call(getproperty, xb, :v) == T(7)
            @test _own_call(getproperty, xb, :pad) == 99
            _own_call(setproperty!, xa, :v, T(6))
            @test _twice(a, xa) == T(12)
            # Two sources, two instantiations: never one shared image.
            @test xa.lib_name != xb.lib_name
            before = RustCall.finalizer_failure_count()
            finalize(xa)
            finalize(xb)
            @test RustCall.finalizer_failure_count() == before
        end
    end

    @testset "the rows are owner-qualified" begin
        for (lib, other) in ((lib_a, lib_b), (lib_b, lib_a))
            for member in ("Boxed_new", "Boxed_tag", "Boxed_free")
                row = RustCall.GENERIC_FUNCTIONS_BY_LIB[(lib, member)]
                @test row.owner == lib
                @test row.group === Symbol("generic_struct:Boxed")
                @test row.code != RustCall.GENERIC_FUNCTIONS_BY_LIB[(other, member)].code
            end
        end
        # A group is one owner's members, whatever the bare name maps to.
        own_a = _own_row(lib_a, "Boxed_new")
        @test own_a.owner == lib_a
        members = lock(RustCall.REGISTRY_LOCK) do
            RustCall._generic_group_members(own_a)
        end
        @test all(info -> info.owner == lib_a, members)
        @test Set(info.name for info in members) ⊇
              Set(["Boxed_new", "Boxed_tag", "Boxed_twice", "Boxed_free"])
        @test _own_row(lib_b, "Boxed_new").owner == lib_b
    end

    @testset "the cache key of an unchanged struct does not move" begin
        # The instantiation's identity is the source, the bindings, the
        # compiler and the group symbol — never the owner — so it is the key
        # it was before the owner existed, and the same whenever it is asked.
        info = _own_row(lib_a, "Boxed_new")
        compiler = something(info.compiler, RustCall.get_default_compiler())
        params = Dict{Symbol, Type}(:T => Int32)
        member_key = RustCall.artifact_key(
            RustCall._monomorphization_id(info, info.name, params, compiler))
        group_id = RustCall.ArtifactId(;
            kind = "generic_struct",
            source = info.code,
            type_params = RustCall.artifact_type_params(info.type_params, params),
            target_triple = compiler.target_triple,
            codegen = RustCall.artifact_codegen_options(compiler),
            RustCall._generic_cargo_identity(info.cargo)...,
            extra = Pair{String, String}["group" => "generic_struct:Boxed"],
        )
        image = "rust_generic_struct_" * RustCall.artifact_short_id(RustCall.artifact_key(group_id))
        x = _boxed(a, Int32, 1)
        @test x.lib_name == image
        @test haskey(RustCall.MONOMORPHIZED_FUNCTIONS, member_key)
        # Running the unchanged block again re-registers the same members
        # under the same library, and reaches the same instantiation.
        @test _own_block(a, _boxed_source(1)) == lib_a
        again = _own_row(lib_a, "Boxed_new")
        @test RustCall.artifact_key(
            RustCall._monomorphization_id(again, again.name, params, compiler)) == member_key
        y = _boxed(a, Int32, 2)
        @test y.lib_name == image
        # Same source in another module: the same library, so the same
        # instantiation, as it should be.
        c = _own_module(:GenericOwnerC)
        @test _own_block(c, _boxed_source(1)) == lib_a
        z = _boxed(c, Int32, 3)
        @test z.lib_name == image
        @test _tag(c, z) == 1
        foreach(finalize, (x, y, z))
    end

    @testset "a re-run block with another body is its module's own" begin
        old = _boxed(a, Int32, 4)
        lib_a2 = _own_block(a, _boxed_source(10))
        @test lib_a2 != lib_a
        new = _boxed(a, Int32, 4)
        @test _tag(a, new) == 10
        # The object built before keeps its image; B is untouched.
        @test _tag(a, old) == 1
        xb = _boxed(b, Int32, 4)
        @test _tag(b, xb) == 2
        @test _own_call(getproperty, xb, :pad) == 99
        foreach(finalize, (old, new, xb))
    end

    @testset "rows go with their library" begin
        RustCall.unload_library(lib_b)
        @test !haskey(RustCall.GENERIC_FUNCTIONS_BY_LIB, (lib_b, "Boxed_new"))
        # A is unaffected by B's unload.
        xa = _boxed(a, Int32, 8)
        @test _tag(a, xa) == 10
        # B's next construction restores B's block, and with it B's own rows.
        xb = _boxed(b, Int32, 8)
        @test _tag(b, xb) == 2
        @test _own_call(getproperty, xb, :pad) == 99
        @test RustCall.GENERIC_FUNCTIONS_BY_LIB[(lib_b, "Boxed_new")].owner == lib_b
        foreach(finalize, (xa, xb))
    end

    # The struct's code reads its members from the library of the block that
    # emitted it — not through `@rust` name resolution, where a later block
    # of the module exporting an ordinary function of a member's name answers
    # first (PR #523 review).
    @testset "a later block's ordinary export of a member's name" begin
        d = _own_module(:GenericOwnerD)
        lib_d = _own_block(d, _boxed_source(7))
        lib_d2 = _own_block(d, """
            #[no_mangle]
            pub extern "C" fn Boxed_new(x: i32) -> i32 { x + 1 }

            #[julia]
            pub fn Boxed_tag(x: i32) -> i32 { x + 2 }
            """)
        @test lib_d2 != lib_d
        x = _boxed(d, Int32, 5)
        @test _tag(d, x) == 7
        @test _twice(d, x) == 10
        @test _own_call(getproperty, x, :v) == 5
        # `@rust` still reaches the later block's exports.
        @test _own_eval(d, "@rust Boxed_new(Int32(1))::Int32") == 2
        @test _own_eval(d, "Boxed_tag(Int32(1))") == 3
        finalize(x)

        @testset "after the defining block is reloaded" begin
            # Unloaded and restored under its own name.
            RustCall.unload_library(lib_d)
            y = _boxed(d, Int32, 6)
            @test _tag(d, y) == 7
            @test _own_row(lib_d, "Boxed_new").owner == lib_d
            finalize(y)
            # Recorded under a name that is no longer its identity — what a
            # precompiled caller holds when the toolchain changed: the restore
            # reloads the block, renames the record, and the struct still
            # finds its members by the block, not by the stored name.
            libs = RustCall._module_binding(d, :__RUSTCALL_LIBS)
            record = libs[lib_d]
            RustCall.unload_library(lib_d)
            stale = "rust_stale_" * lib_d
            libs[stale] = record
            delete!(libs, lib_d)
            RustCall._rename_module_block!(d, lib_d, stale)
            z = _boxed(d, Int32, 8)
            @test _tag(d, z) == 7
            @test _twice(d, z) == 16
            @test haskey(libs, lib_d)
            @test !haskey(libs, stale)
            @test _own_eval(d, "@rust Boxed_new(Int32(1))::Int32") == 2
            finalize(z)
        end
    end
end
