using Test, RustCall

const OWNED572_SOURCE = raw"""
use std::sync::atomic::{AtomicU32, Ordering};
static OWNER_DROPS: AtomicU32 = AtomicU32::new(0);
static FACTOR_DROPS: AtomicU32 = AtomicU32::new(0);
#[julia] pub fn owner_drops572() -> u32 { OWNER_DROPS.load(Ordering::SeqCst) }
#[julia] pub fn factor_drops572() -> u32 { FACTOR_DROPS.load(Ordering::SeqCst) }
#[julia] pub struct Owner572 { n: i32 }
impl Drop for Owner572 { fn drop(&mut self) { OWNER_DROPS.fetch_add(1, Ordering::SeqCst); } }
#[julia] impl Owner572 {
    #[julia] pub fn new(n: i32) -> Self { Self { n } }
    #[julia] pub fn get(&self) -> i32 { self.n }
    #[julia] #[rustcall_owned_return(Factor572)]
    pub fn make(&self) -> Factor572 { Factor572 { n: self.n * 10 } }
    #[julia] #[rustcall_owned_return(Factor572)]
    pub fn checked(&self, mode: i32) -> Result<Factor572, String> { owned_result572(self.n * 10, mode) }
    #[julia] #[rustcall_owned_return(Owner572)]
    pub fn copy_self(&self) -> Self { Self { n: self.n } }
    #[julia] #[rustcall_owned_return(Owner572)]
    pub fn result_self(&self) -> Result<Self, String> { Ok(Self { n: self.n }) }
    #[julia] #[rustcall_owned_return(Factor572)]
    pub fn static_factor(n: i32) -> Factor572 { Factor572 { n } }
}
#[julia] pub struct Factor572 { n: i32 }
impl Drop for Factor572 { fn drop(&mut self) { FACTOR_DROPS.fetch_add(1, Ordering::SeqCst); } }
#[julia] impl Factor572 { #[julia] pub fn get(&self) -> i32 { self.n } }
#[julia] pub struct OwnedCtor572 { n: i32 }
#[julia] impl OwnedCtor572 {
    #[julia] #[rustcall_owned_return(OwnedCtor572)]
    pub fn from_owner(owner: &Owner572) -> Self { Self { n: owner.n } }
    #[julia] pub fn get(&self) -> i32 { self.n }
}
#[julia] pub struct OwnedFallibleCtor572 { n: i32 }
#[julia] impl OwnedFallibleCtor572 {
    #[julia] #[rustcall_owned_return(OwnedFallibleCtor572)]
    pub fn from_owner(owner: &Owner572) -> Result<Self, String> { Ok(Self { n: owner.n }) }
    #[julia] pub fn get(&self) -> i32 { self.n }
}
#[julia] #[rustcall_owned_return(Factor572)]
pub fn owned_free572(n: i32) -> Factor572 { Factor572 { n } }
#[julia] #[rustcall_owned_return(Factor572)]
pub fn owned_result572(n: i32, mode: i32) -> Result<Factor572, String> {
    let factor = Factor572 { n };
    if mode == 1 { return Err("factor rejected".into()); }
    if mode == 2 { panic!("factor panic"); }
    Ok(factor)
}
#[julia] #[rustcall_owned_return(Factor572)]
pub fn owned_callback572(owner: &Owner572, callback: extern "C" fn() -> i32) -> Factor572 {
    callback(); Factor572 { n: owner.n }
}
#[julia] #[rustcall_owned_return(Factor572)]
pub fn owned_result_callback572(owner: &Owner572, callback: extern "C" fn() -> i32) -> Result<Factor572, String> {
    callback(); Ok(Factor572 { n: owner.n })
}
#[julia] #[rustcall_owned_return(Factor572)]
pub fn mixed_owned572(required: &Owner572, optional: Option<&Owner572>, xs: &[f64]) -> Factor572 {
    Factor572 { n: required.n + optional.map_or(0, |v| v.n) + xs.iter().sum::<f64>() as i32 }
}
#[julia] #[rustcall_owned_return(Factor572)]
pub fn mixed_result572(required: &Owner572, optional: Option<&Owner572>, xs: &mut [f64], mode: i32) -> Result<Factor572, String> {
    if !xs.is_empty() { xs[0] += 1.0; }
    let factor = Factor572 { n: required.n + optional.map_or(0, |v| v.n) + xs.iter().sum::<f64>() as i32 };
    if mode == 1 { return Err("mixed rejected".into()); }
    if mode == 2 { panic!("mixed panic"); }
    Ok(factor)
}
#[julia] #[rustcall_owned_return(Factor572)]
pub fn mixed_callback572(required: &Owner572, optional: Option<&Owner572>, xs: &mut [f64], callback: extern "C" fn() -> i32) -> Factor572 {
    if !xs.is_empty() { xs[0] += 2.0; }
    callback();
    Factor572 { n: required.n + optional.map_or(0, |v| v.n) + xs.iter().sum::<f64>() as i32 }
}
#[julia] impl Owner572 {
    #[julia] #[rustcall_owned_return(Factor572)]
    pub fn mixed_factor(&self, optional: Option<&Self>, xs: &[f64]) -> Factor572 { mixed_owned572(self, optional, xs) }
    #[julia] #[rustcall_owned_return(Factor572)]
    pub fn mixed_static(optional: Option<&Self>, xs: &[f64]) -> Factor572 { Factor572 { n: optional.map_or(0, |v| v.n) + xs.iter().sum::<f64>() as i32 } }
    #[julia] #[rustcall_owned_return(Owner572)]
    pub fn mixed_self(&self, optional: Option<&Self>, xs: &[f64]) -> Self { Self { n: self.n + optional.map_or(0, |v| v.n) + xs.iter().sum::<f64>() as i32 } }
}
#[julia] pub struct OwnedMixedCtor572 { n: i32 }
#[julia] impl OwnedMixedCtor572 {
    #[julia] #[rustcall_owned_return(OwnedMixedCtor572)]
    pub fn from_inputs(required: &Owner572, optional: Option<&Owner572>, xs: &[f64]) -> Self { Self { n: required.n + optional.map_or(0, |v| v.n) + xs.iter().sum::<f64>() as i32 } }
    #[julia] pub fn get(&self) -> i32 { self.n }
}
#[julia] pub struct OwnedMixedFallible572 { n: i32 }
#[julia] impl OwnedMixedFallible572 {
    #[julia] #[rustcall_owned_return(OwnedMixedFallible572)]
    pub fn from_inputs(required: &Owner572, optional: Option<&Owner572>, xs: &[f64]) -> Result<Self, String> { Ok(Self { n: required.n + optional.map_or(0, |v| v.n) + xs.iter().sum::<f64>() as i32 }) }
    #[julia] pub fn get(&self) -> i32 { self.n }
}
"""

const OWNED572_LIB = Core.eval(
    @__MODULE__,
    Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), OWNED572_SOURCE),
)

@testset "explicit owned return metadata resolves the selected concrete owner (#572)" begin
    manifest = RustCall.extract_manifest(OWNED572_SOURCE; mode = "inline")
    functions = Dict(f.name => f for f in RustCall.manifest_function_signatures(manifest))
    @test functions["owned_free572"].return_abi == "boxed"
    @test functions["owned_free572"].return_handle.name == "Factor572"
    @test functions["owned_result572"].ok_abi == "boxed"
    @test functions["owned_result572"].return_handle.ffi_name == "Factor572"
    owner =
        only(s for s in RustCall.manifest_struct_infos(manifest) if s.name == "Owner572")
    make = only(m for m in owner.methods if m.name == "make")
    @test make.return_handle.name == "Factor572"
    @test !make.is_constructor
    bad = deepcopy(manifest)
    only(f for f in bad["functions"] if f["name"] == "owned_free572")["return_handle"] = "Missing572"
    @test_throws RustCall.ExtractorError RustCall.manifest_function_signatures(bad)
end

function _owned572_mixed_checks(call, owner)
    for (factory, expected) in (
        (() -> call(:mixed_owned572, owner, nothing, [1.0, 2.0]), 6),
        (() -> call(:mixed_owned572, owner, owner, [1.0, 2.0]), 9),
        (() -> call(:mixed_factor, owner, owner, [1.0, 2.0]), 9),
        (() -> call(:mixed_static, typeof(owner), nothing, [1.0, 2.0]), 3),
        (() -> call(:mixed_static, typeof(owner), owner, [1.0, 2.0]), 6),
        (
            () ->
                RustCall.unwrap(call(:mixed_result572, owner, owner, [1.0, 2.0], Int32(0))),
            10,
        ),
    )
        factor = factory()
        try
            @test nameof(typeof(factor)) == :Factor572
            @test call(:get, factor) == expected
            @test factor.alive === owner.alive
            @test factor.free_ptr != owner.free_ptr
            @test_throws ArgumentError call(:mixed_owned572, factor, nothing, [1.0])
        finally
            finalize(factor)
        end
    end
    self_copy = call(:mixed_self, owner, nothing, [1.0, 2.0])
    @test typeof(self_copy) === typeof(owner)
    @test call(:get, self_copy) == 6
    finalize(self_copy)
    for (constructor, fallible) in
        ((:OwnedMixedCtor572, false), (:OwnedMixedFallible572, true))
        value = call(constructor, owner, nothing, [1.0, 2.0])
        object = fallible ? RustCall.unwrap(value) : value
        @test call(:get, object) == 6
        finalize(object)
    end
    @test_throws ArgumentError call(:mixed_owned572, owner, owner.ptr, [1.0])
    @test_throws ArgumentError call(:mixed_owned572, owner, C_NULL, [1.0])
    @test_throws ArgumentError call(:mixed_owned572, owner, nothing, Float32[1])
    gone = call(:Owner572, Int32(1))
    finalize(gone)
    @test_throws RustCall.RustError call(:mixed_owned572, gone, nothing, [1.0])
    @test_throws RustCall.RustError call(:mixed_owned572, owner, gone, [1.0])
    for mode in (Int32(1), Int32(2))
        xs = [1.0]
        drops = call(:factor_drops572)
        if mode == 1
            @test call(:mixed_result572, owner, nothing, xs, mode).value == "mixed rejected"
        else
            @test_throws RustCall.RustPanicError call(
                :mixed_result572,
                owner,
                nothing,
                xs,
                mode,
            )
        end
        @test xs == [2.0]
        @test call(:factor_drops572) == drops + 1
    end
    xs = [1.0]
    gc_factor = call(
        :mixed_callback572,
        owner,
        call(:Owner572, Int32(4)),
        xs,
        () -> (GC.gc(); Int32(0)),
    )
    @test call(:get, gc_factor) == 10
    @test xs == [3.0]
    finalize(gc_factor)
    drops = call(:factor_drops572)
    @test_throws ErrorException call(
        :mixed_callback572,
        owner,
        owner,
        [1.0],
        () -> error("mixed callback"),
    )
    @test call(:factor_drops572) == drops + 1
    @test isempty(RustCall._callback_frames())
    tls = task_local_storage()
    key = :RustCall_before_owned_adoption
    previous = Base.get(tls, key, nothing)
    tls[key] = (_, _) -> error("mixed adoption failure")
    try
        for factory in (
            () -> call(:mixed_owned572, owner, nothing, [1.0]),
            () -> call(:mixed_result572, owner, owner, [1.0], Int32(0)),
        )
            drops = call(:factor_drops572)
            @test_throws ErrorException factory()
            @test call(:factor_drops572) == drops + 1
        end
    finally
        previous === nothing ? delete!(tls, key) : (tls[key] = previous)
    end
end

function _owned572_checks(call)
    owner = call(:Owner572, Int32(3))
    before_owner = call(:owner_drops572)
    before_factor = call(:factor_drops572)
    factor = call(:make, owner)
    @test nameof(typeof(factor)) == :Factor572
    @test call(:get, factor) == 30
    @test factor.alive === owner.alive
    @test factor.free_ptr != owner.free_ptr
    finalize(factor)
    @test call(:factor_drops572) == before_factor + 1
    @test call(:owner_drops572) == before_owner
    for factor in (
        call(:owned_free572, Int32(7)),
        RustCall.unwrap(call(:owned_result572, Int32(8), Int32(0))),
        RustCall.unwrap(call(:checked, owner, Int32(0))),
        call(:static_factor, typeof(owner), Int32(9)),
    )
        @test nameof(typeof(factor)) == :Factor572
        @test call(:get, factor) in (7, 8, 30, 9)
        finalize(factor)
    end
    for copy in (call(:copy_self, owner), RustCall.unwrap(call(:result_self, owner)))
        @test typeof(copy) === typeof(owner)
        @test call(:get, copy) == 3
        @test copy.ptr != owner.ptr
        finalize(copy)
    end
    for (ctor_name, fallible) in ((:OwnedCtor572, false), (:OwnedFallibleCtor572, true))
        @test_throws ArgumentError call(ctor_name, C_NULL)
        @test_throws ArgumentError call(ctor_name, owner.ptr)
        value = call(ctor_name, owner)
        object = fallible ? RustCall.unwrap(value) : value
        @test call(:get, object) == 3
        finalize(object)
    end
    n = call(:factor_drops572)
    @test call(:owned_result572, Int32(1), Int32(1)).value == "factor rejected"
    @test call(:factor_drops572) == n + 1
    @test_throws RustCall.RustPanicError call(:owned_result572, Int32(1), Int32(2))
    @test call(:factor_drops572) == n + 2
    @test call(:checked, owner, Int32(1)).value == "factor rejected"
    @test_throws RustCall.RustPanicError call(:checked, owner, Int32(2))
    # A Julia callback may throw after Rust continues and produces an owner;
    # both the plain and Result guards must free the undeliverable owner.
    for fn in (:owned_callback572, :owned_result_callback572)
        before = call(:factor_drops572)
        @test_throws ErrorException call(fn, owner, () -> error("Julia callback error"))
        @test call(:factor_drops572) == before + 1
        @test isempty(RustCall._callback_frames())
    end
    # Actual generated constructors normally cannot fail after they adopt.
    # This seam throws before adoption to exercise the cleanup transaction.
    tls = task_local_storage()
    key = :RustCall_before_owned_adoption
    previous = Base.get(tls, key, nothing)
    tls[key] = (T, ptr) -> error("Julia adoption failure")
    try
        for invocation in (
            () -> call(:owned_free572, Int32(11)),
            () -> call(:owned_result572, Int32(11), Int32(0)),
            () -> call(:make, owner),
            () -> call(:checked, owner, Int32(0)),
        )
            before = call(:factor_drops572)
            @test_throws ErrorException invocation()
            @test call(:factor_drops572) == before + 1
        end
        @test RustCall.is_err(call(:owned_result572, Int32(11), Int32(1)))
    finally
        previous === nothing ? delete!(tls, key) : (tls[key] = previous)
    end
    for _ = 1:5
        factor =
            call(:owned_callback572, call(:Owner572, Int32(42)), () -> (GC.gc(); Int32(0)))
        @test call(:get, factor) == 42
        finalize(factor)
    end
    @testset "mixed slices and optional inputs select explicit owned returns" begin
        _owned572_mixed_checks(call, owner)
    end
    finalize(owner)
end

@testset "owned direct and Result returns choose the right class and destructor inline (#572)" begin
    _owned572_checks(
        (name, args...) -> Base.invokelatest(getfield(@__MODULE__, name), args...),
    )
end

@testset "owned direct and Result returns share their plan across crate emitters (#572)" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "src"))
        runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
        write(
            joinpath(dir, "Cargo.toml"),
            """
[package]
name = "owned_returns572"
version = "0.1.0"
edition = "2021"
[lib]
crate-type = ["cdylib"]
[dependencies]
rustcall_julia_macros = { path = "$runtime" }
""",
        )
        write(
            joinpath(dir, "src", "lib.rs"),
            "use rustcall_julia_macros::julia;\n" * OWNED572_SOURCE,
        )
        bindings = @rust_crate dir
        output = joinpath(dir, "WrittenOwned572.jl")
        RustCall.write_bindings_to_file(dir, output; output_module_name = "WrittenOwned572")
        sandbox = Module(:OwnedSandbox572)
        Base.include(sandbox, output)
        written = Base.invokelatest(getfield, sandbox, :WrittenOwned572)
        modules = (getfield(bindings, :module_ref), written)
        try
            for mod in modules
                call =
                    (name, args...) ->
                        Base.invokelatest(Base.invokelatest(getfield, mod, name), args...)
                _owned572_checks(call)
            end
            mktempdir() do replacement_dir
                mkpath(joinpath(replacement_dir, "src"))
                write(
                    joinpath(replacement_dir, "Cargo.toml"),
                    read(joinpath(dir, "Cargo.toml"), String),
                )
                replacement_source = replace(
                    OWNED572_SOURCE,
                    "FACTOR_DROPS.fetch_add(1," => "FACTOR_DROPS.fetch_add(10,",
                )
                write(
                    joinpath(replacement_dir, "src", "lib.rs"),
                    "use rustcall_julia_macros::julia;\n" * replacement_source,
                )
                replacement_binding = @rust_crate replacement_dir
                replacement = getfield(replacement_binding, :module_ref)
                libname(mod) = Base.invokelatest(getfield, mod, :_LIB_NAME)
                invoke(mod, name, args...) =
                    Base.invokelatest(Base.invokelatest(getfield, mod, name), args...)
                count(target) = RustCall.call_rust_function(target.func_ptr, UInt32)
                old = Any[]
                fresh = Any[]
                counters = Any[]
                inputs = Any[]
                try
                    for mod in modules
                        input = invoke(mod, :Owner572, Int32(1))
                        push!(inputs, input)
                        push!(old, invoke(mod, :mixed_owned572, input, nothing, [1.0]))
                        target = RustCall.resolve_call_target(
                            libname(mod),
                            "rustcall_factor_drops572";
                            fallback = false,
                        )
                        push!(counters, (target, count(target)))
                    end
                    for lib in unique(libname.(modules))
                        @test RustCall.alias_artifact!(
                            RustCall.crate_direct_policy(),
                            libname(replacement),
                            lib,
                        )
                    end
                    new_counter = RustCall.resolve_call_target(
                        libname(replacement),
                        "rustcall_factor_drops572";
                        fallback = false,
                    )
                    before_new = count(new_counter)
                    for (index, (mod, previous)) in enumerate(zip(modules, old))
                        input = invoke(mod, :Owner572, Int32(2))
                        push!(inputs, input)
                        object = RustCall.unwrap(
                            invoke(mod, :mixed_result572, input, nothing, [2.0], Int32(0)),
                        )
                        @test_throws ArgumentError invoke(
                            mod,
                            :mixed_owned572,
                            inputs[index],
                            nothing,
                            [1.0],
                        )
                        push!(fresh, object)
                        @test typeof(previous) === typeof(object)
                        @test previous.alive !== object.alive
                        @test previous.free_ptr != object.free_ptr
                        @test previous.alive[]
                    end
                    foreach(finalize, old)
                    @test all(pair -> count(first(pair)) >= last(pair) + 1, counters)
                    @test count(new_counter) == before_new
                    after_old = [count(first(pair)) for pair in counters]
                    foreach(finalize, fresh)
                    @test count(new_counter) == before_new + 10 * length(modules)
                    @test [count(first(pair)) for pair in counters] == after_old
                finally
                    foreach(finalize, (old..., fresh..., inputs...))
                    lib = libname(replacement)
                    haskey(RustCall.RUST_LIBRARIES, lib) &&
                        RustCall.unload_library(lib; close = true)
                    for lib in libname.(modules)
                        RustCall.close_retired_handles!(RustCall.retired_handles(lib))
                    end
                end
            end
        finally
            for mod in modules
                lib = Base.invokelatest(getfield, mod, :_LIB_NAME)
                haskey(RustCall.RUST_LIBRARIES, lib) &&
                    RustCall.unload_library(lib; close = true)
            end
        end
    end
end

_discard_owned572(call) = WeakRef(call(:owned_free572, Int32(1)))

@testset "returned owners are finalized after Julia GC (#572)" begin
    call = (name, args...) -> Base.invokelatest(getfield(@__MODULE__, name), args...)
    before = factor_drops572()
    references = [_discard_owned572(call) for _ = 1:20]
    for _ = 1:4
        GC.gc()
        yield()
    end
    @test all(ref -> ref.value === nothing, references)
    @test factor_drops572() >= before + 20
end

@testset "selected destructor and image survive retirement and replacement (#572)" begin
    scopes = (Module(gensym(:OwnedOld572)), Module(gensym(:OwnedNew572)))
    libraries = String[]
    objects = Any[]
    call(mod, fn, args...) =
        Base.invokelatest(Base.invokelatest(getfield, mod, fn), args...)
    counter(target) = RustCall.call_rust_function(target.func_ptr, UInt32)
    try
        for (generation, mod) in enumerate(scopes)
            Core.eval(mod, :(using RustCall))
            source = replace(
                OWNED572_SOURCE,
                "FACTOR_DROPS.fetch_add(1," => "FACTOR_DROPS.fetch_add($(generation == 1 ? 1 : 10),",
            )
            source *= "\n#[julia] pub fn owned_generation572() -> i32 { $generation }\n"
            push!(
                libraries,
                Core.eval(
                    mod,
                    Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source),
                ),
            )
        end
        old_counter = RustCall.resolve_call_target(
            first(libraries),
            "rustcall_factor_drops572";
            fallback = false,
        )
        new_counter = RustCall.resolve_call_target(
            last(libraries),
            "rustcall_factor_drops572";
            fallback = false,
        )
        mod = first(scopes)
        old_input = call(mod, :Owner572, Int32(3))
        old = call(mod, :mixed_owned572, old_input, nothing, [1.0])
        append!(objects, (old_input, old))
        old_free = old.free_ptr
        @test RustCall.alias_artifact!(
            RustCall.inline_rustc_policy(),
            last(libraries),
            first(libraries),
        )
        fresh_input = call(mod, :Owner572, Int32(4))
        fresh = RustCall.unwrap(
            call(mod, :mixed_result572, fresh_input, nothing, [1.0], Int32(0)),
        )
        append!(objects, (fresh_input, fresh))
        @test_throws ArgumentError call(mod, :mixed_owned572, old_input, nothing, [1.0])
        @test typeof(old) === typeof(fresh)
        @test old.alive !== fresh.alive
        @test old.free_ptr == old_free
        @test old.free_ptr != fresh.free_ptr
        @test old.alive[]
        finalize(old)
        @test counter(old_counter) == 1
        @test counter(new_counter) == 0
        finalize(fresh)
        @test counter(old_counter) == 1
        @test counter(new_counter) == 10
    finally
        foreach(finalize, objects)
        for lib in libraries
            haskey(RustCall.RUST_LIBRARIES, lib) &&
                RustCall.unload_library(lib; close = true)
            RustCall.close_retired_handles!(RustCall.retired_handles(lib))
        end
    end
end
