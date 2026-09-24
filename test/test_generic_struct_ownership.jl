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
            RustCall._rebind_module_block!(d, libs, lib_d, stale, record)
            z = _boxed(d, Int32, 8)
            @test _tag(d, z) == 7
            @test _twice(d, z) == 16
            @test haskey(libs, lib_d)
            @test !haskey(libs, stale)
            @test _own_eval(d, "@rust Boxed_new(Int32(1))::Int32") == 2
            finalize(z)
        end
    end

    # A known owner whose row is gone — what an unload racing the lookup
    # leaves — is an error, never the bare name: that is another module's
    # struct of the same name, here B's, with another layout (PR #523 review).
    @testset "a known owner's missing row is not answered by the bare name" begin
        e = _own_module(:GenericOwnerE)
        lib_e = _own_block(e, _boxed_source(5))
        f = _own_module(:GenericOwnerF)
        lib_f = _own_block(f, _boxed_source(6; pad = true))  # the bare name is now F's
        @test RustCall.GENERIC_FUNCTION_REGISTRY["Boxed_new"].owner == lib_f
        x = _boxed(e, Int32, 1)
        @test _tag(e, x) == 5
        finalize(x)
        row = _own_row(lib_e, "Boxed_new")
        # The library stays loaded, so restoring the block does not register
        # the row again: every attempt finds the owner and no row.
        delete!(RustCall.GENERIC_FUNCTIONS_BY_LIB, (lib_e, "Boxed_new"))
        try
            err = try
                _boxed(e, Int32, 2)
                nothing
            catch caught
                caught
            end
            @test err isa RustCall.RustError
            @test occursin("Boxed_new", sprint(showerror, err))
            @test occursin(lib_e, sprint(showerror, err))
        finally
            RustCall.GENERIC_FUNCTIONS_BY_LIB[(lib_e, "Boxed_new")] = row
        end
        y = _boxed(e, Int32, 3)
        @test _tag(e, y) == 5
        finalize(y)
    end

    # A struct's group rows are part of its library's metadata: installed in the
    # one transaction that publishes the library, with its symbol mappings and
    # generic functions (#520) — so there is no moment at which the library is
    # visible with some or none of its group (#522).
    @testset "the group is installed with the library's metadata" begin
        k = _own_module(:GenericOwnerK)
        at_registration = Ref{Any}(nothing)
        hook = function (stage, lib)
            stage === :registered || return
            at_registration[] = lock(RustCall.REGISTRY_LOCK) do
                Set(name for ((l, name), info) in RustCall.GENERIC_FUNCTIONS_BY_LIB
                    if l == lib && info.group === Symbol("generic_struct:Boxed"))
            end
        end
        lib_k = task_local_storage(RustCall._AFTER_MANIFEST_REGISTRATION, hook) do
            _own_block(k, _boxed_source(11))
        end
        @test at_registration[] isa Set
        @test at_registration[] ⊇ Set(["Boxed_new", "Boxed_tag", "Boxed_twice", "Boxed_free"])
        @test all(name -> _own_row(lib_k, name).owner == lib_k, at_registration[])
        x = _boxed(k, Int32, 1)
        @test _tag(k, x) == 11
        finalize(x)
        # The restore path — an unloaded or precompiled block brought back by
        # its module's next call — installs them the same way: the rows are
        # there in the transaction that publishes the restored library, not
        # after it (PR #523 review).
        RustCall.unload_library(lib_k)
        @test !haskey(RustCall.GENERIC_FUNCTIONS_BY_LIB, (lib_k, "Boxed_new"))
        at_registration[] = nothing
        y = task_local_storage(RustCall._AFTER_MANIFEST_REGISTRATION, hook) do
            _boxed(k, Int32, 2)
        end
        @test at_registration[] isa Set
        @test at_registration[] ⊇ Set(["Boxed_new", "Boxed_tag", "Boxed_twice", "Boxed_free"])
        @test _tag(k, y) == 11
        finalize(y)
    end

    # A generic registered by hand, one wrapper at a time, is ungrouped: its
    # constructor's snapshot holds only itself, and the destructor is a
    # registration of its own — found as before, never looked for inside the
    # constructor's one-member "group" (PR #523 review).
    @testset "a hand-registered, ungrouped constructor keeps its destructor" begin
        src = """
            #[julia]
            pub struct LegacyBox522<T> { pub v: T }
            impl<T: Copy> LegacyBox522<T> {
                pub fn new(v: T) -> Self { LegacyBox522 { v } }
            }
            """
        expanded = RustCall.expand_inline(src)
        info = only(RustCall.manifest_struct_infos(expanded.manifest))
        wrappers = [first(w) for w in info.generic_wrappers]
        @test "LegacyBox522_new" in wrappers
        @test "LegacyBox522_free" in wrappers
        for (wrapper, _, params) in info.generic_wrappers
            RustCall.register_generic_function(wrapper, expanded.source,
                Symbol.(isempty(params) ? info.type_params : params))
        end
        @test RustCall.GENERIC_FUNCTION_REGISTRY["LegacyBox522_new"].group === nothing
        legacy = _own_module(:GenericOwnerLegacy)
        # The emitted code names these helpers unqualified, as `rust"""`'s own
        # expansion (a RustCall macro) resolves them.
        Core.eval(legacy, :(using RustCall: _call_generic_constructor, _call_generic_method,
                                            _call_generic_field, _resolve_generic_struct_field_type))
        Core.eval(legacy, :(macro emit_legacy()
            $(RustCall.emit_julia_definitions)($info)
        end))
        Base.invokelatest(Core.eval, legacy, :(@emit_legacy))
        x = _own_call(_own_get(legacy, :LegacyBox522){Int32}, Int32(4))
        @test getfield(x, :free_ptr) != C_NULL
        @test getfield(x, :alive)[]
        @test _own_call(getproperty, x, :v) == 4
        before = RustCall.finalizer_failure_count()
        finalize(x)
        @test getfield(x, :ptr) == C_NULL
        @test RustCall.finalizer_failure_count() == before
    end

    # The member and its whole group are one snapshot, read in one transaction;
    # the instantiation uses only that. So rows dropped *after* the read — an
    # unload racing the constructor — cannot leave a constructor-only group
    # without methods or destructor (PR #523 review).
    @testset "the group is read with the member, once" begin
        g = _own_module(:GenericOwnerG)
        lib_g = _own_block(g, _boxed_source(9))
        # Another module's `Boxed` registered last: the bare names are its, so
        # a second read of G's group after its rows went would find only the
        # member itself — the constructor-only group of the review.
        h = _own_module(:GenericOwnerH)
        lib_h = _own_block(h, _boxed_source(10; pad = true))
        @test RustCall.GENERIC_FUNCTION_REGISTRY["Boxed_tag"].owner == lib_h
        dropped = Pair{Tuple{String, String}, RustCall.GenericFunctionInfo}[]
        seen = Ref{Any}(nothing)
        hook = function (snapshot)
            seen[] = snapshot
            # Every sibling row of the owner goes, as an unload would take them.
            for (key, info) in collect(RustCall.GENERIC_FUNCTIONS_BY_LIB)
                if first(key) == lib_g && info.name != snapshot.member.name
                    push!(dropped, key => info)
                    delete!(RustCall.GENERIC_FUNCTIONS_BY_LIB, key)
                end
            end
        end
        x = try
            task_local_storage(RustCall._AFTER_GENERIC_STRUCT_SNAPSHOT, hook) do
                _boxed(g, Int64, 21)  # a cold instantiation: new source, new type
            end
        finally
            for (key, info) in dropped
                RustCall.GENERIC_FUNCTIONS_BY_LIB[key] = info
            end
        end
        @test seen[] isa RustCall.GenericStructSnapshot
        @test seen[].member.name == "Boxed_new"
        @test Set(info.name for info in seen[].members) ⊇
              Set(["Boxed_new", "Boxed_tag", "Boxed_twice", "Boxed_free"])
        @test all(info -> info.owner == lib_g, seen[].members)
        @test !isempty(dropped)
        # The whole group was instantiated from the snapshot: methods and the
        # destructor are in the object's own image.
        artifact = RustCall.GENERIC_STRUCT_ARTIFACTS[(x.lib_name, getfield(x, :alive))]
        @test all(name -> haskey(artifact, name), ("Boxed_new", "Boxed_tag", "Boxed_twice", "Boxed_free"))
        @test getfield(x, :free_ptr) == artifact["Boxed_free"].func_ptr
        @test _tag(g, x) == 9
        @test _twice(g, x) == 42
        before = RustCall.finalizer_failure_count()
        finalize(x)
        @test RustCall.finalizer_failure_count() == before
    end
end

# Source level: on the generic struct path, the generic registrations are read
# in one place, in one transaction, and the instantiation reads none (#522).
# Parsed rather than grepped, so docstrings that name the tables do not count.
function _own_functions(path)
    defs = Dict{Symbol, Any}()
    walk(ex) = if ex isa Expr
        if ex.head === :function || (ex.head === :(=) && ex.args[1] isa Expr && ex.args[1].head === :call)
            sig = ex.args[1]
            while sig isa Expr && sig.head in (:where, :(::))
                sig = sig.args[1]
            end
            if sig isa Expr && sig.head === :call && sig.args[1] isa Symbol
                defs[sig.args[1]] = push!(get(defs, sig.args[1], Any[]), ex)
            end
        end
        foreach(walk, ex.args)
    end
    walk(Meta.parseall(read(path, String)))
    return defs
end
_own_symbols(ex) = ex isa Symbol ? Set([ex]) :
                   ex isa Expr ? union(Set{Symbol}(), (_own_symbols(a) for a in ex.args)...) :
                   ex isa QuoteNode ? _own_symbols(ex.value) : Set{Symbol}()
function _own_count_locks(ex)
    ex isa Expr || return 0
    here = ex.head === :call && ex.args[1] === :lock && length(ex.args) >= 2 &&
           ex.args[2] === :REGISTRY_LOCK ? 1 : 0
    # `lock(REGISTRY_LOCK) do ... end` is a `:do` around this very `:call`,
    # so the call alone is counted.
    return here + sum(_own_count_locks, ex.args; init = 0)
end

@testset "the generic struct path reads the generic registrations once (#522)" begin
    src = joinpath(pkgdir(RustCall), "src")
    tables = Set([:GENERIC_FUNCTIONS_BY_LIB, :GENERIC_FUNCTION_REGISTRY, :_generic_group_members])
    structs = _own_functions(joinpath(src, "structs.jl"))
    readers = Set(name for (name, exs) in structs
                  if any(ex -> !isempty(intersect(_own_symbols(ex), tables)), exs))
    # One function of structs.jl touches the generic registrations...
    @test readers == Set([:_read_generic_struct_snapshot])
    # ...in exactly one locked transaction.
    reader = only(structs[:_read_generic_struct_snapshot])
    @test _own_count_locks(reader) == 1
    # The group instantiation reads no generic registration at all: which
    # members it builds is decided by its caller's one read.
    generics = _own_functions(joinpath(src, "generics.jl"))
    body = only(generics[:_instantiate_generic_struct_group])
    @test isempty(intersect(_own_symbols(body), tables))
    @test !(:_generic_group_member in _own_symbols(body))
end
