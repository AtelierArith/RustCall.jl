using Test, RustCall

const OPTIONAL571_SOURCE = raw"""
#[julia]
pub struct OptionalOwner571 { value: i32 }
#[julia]
impl OptionalOwner571 {
    #[julia] pub fn new(value: i32) -> Self { Self { value } }
    #[julia] pub fn get(&self) -> i32 { self.value }
    #[julia] pub fn total(&self, other: Option<&Self>) -> i32 { self.value + other.map_or(0, |x| x.value) }
    #[julia] pub fn absorb(&mut self, other: Option<&Self>) { self.value += other.map_or(1, |x| x.value); }
    #[julia] pub fn give(&self, other: Option<&mut Self>) { if let Some(x) = other { x.value += self.value; } }
    #[julia] pub fn inspect(other: Option<&Self>) -> i32 { other.map_or(0, |x| x.value) }
    #[julia] pub fn checked(&self, other: Option<&Self>) -> Result<i32, String> { Ok(self.total(other)) }
    #[julia] pub fn optional(&self, other: Option<&Self>) -> Option<i32> { other.map(|x| x.value) }
    #[julia] pub fn text(&self, other: Option<&Self>) -> String { self.total(other).to_string() }
    #[julia] pub fn label(&self, _other: Option<&Self>) -> &'static str { "optional" }
    #[julia] pub fn duplicate(&self, other: Option<&Self>) -> Result<Self, String> { Ok(Self { value: self.total(other) }) }
    #[julia] pub fn copy_optional(&self, other: Option<&Self>) -> Self { Self { value: self.total(other) } }
}
#[julia] pub struct OtherOptional571 { value: i32 }
#[julia] impl OtherOptional571 { #[julia] pub fn new(value: i32) -> Self { Self { value } } }
#[julia] pub struct OptionalCtor571 { value: i32 }
#[julia] impl OptionalCtor571 {
    #[julia] pub fn from_owner(owner: Option<&OptionalOwner571>) -> Self { Self { value: owner.map_or(0, |x| x.value) } }
    #[julia] pub fn get(&self) -> i32 { self.value }
}
#[julia] pub struct OptionalFallibleCtor571 { value: i32 }
#[julia] impl OptionalFallibleCtor571 {
    #[julia] pub fn from_owner(owner: Option<&OptionalOwner571>) -> Result<Self, String> { Ok(Self { value: owner.map_or(0, |x| x.value) }) }
    #[julia] pub fn get(&self) -> i32 { self.value }
}
#[julia] pub fn optional_sum571(a: Option<&OptionalOwner571>, b: Option<&OptionalOwner571>) -> i32 {
    a.map_or(0, |x| x.value) + b.map_or(0, |x| x.value)
}
#[julia] pub fn optional_mut571(a: Option<&mut OptionalOwner571>, b: Option<&OptionalOwner571>) {
    if let Some(x) = a { x.value += b.map_or(1, |y| y.value); }
}
#[julia] pub fn optional_two_mut571(a: Option<&mut OptionalOwner571>, b: Option<&mut OptionalOwner571>) {
    if let Some(x) = a { x.value += 1; } if let Some(x) = b { x.value += 2; }
}
#[julia] pub fn optional_mixed571(a: &OptionalOwner571, b: Option<&OptionalOwner571>) -> i32 { a.value + b.map_or(0, |x| x.value) }
#[julia] pub fn optional_required_mut571(a: &mut OptionalOwner571, b: Option<&OptionalOwner571>) { a.value += b.map_or(1, |x| x.value); }
#[julia] pub fn optional_mut_required571(a: Option<&mut OptionalOwner571>, b: &OptionalOwner571) { if let Some(x) = a { x.value += b.value; } }
#[julia] pub fn optional_callback571(owner: Option<&OptionalOwner571>, callback: extern "C" fn() -> i32) -> i32 {
    callback(); owner.map_or(0, |x| x.value)
}
#[julia] pub fn optional_panic571(owner: Option<&mut OptionalOwner571>) { if let Some(x) = owner { x.value += 10; } panic!("optional panic"); }
#[julia] pub fn optional_err571(owner: Option<&mut OptionalOwner571>) -> Result<(), String> { if let Some(x) = owner { x.value += 20; } Err("changed".into()) }
#[julia] pub fn optional_result571(owner: Option<&OptionalOwner571>) -> Result<i32, String> { Ok(owner.map_or(0, |x| x.value)) }
#[julia] pub fn optional_option571(owner: Option<&OptionalOwner571>) -> Option<i32> { owner.map(|x| x.value) }
#[julia] pub fn optional_text571(owner: Option<&OptionalOwner571>) -> String { owner.map_or(0, |x| x.value).to_string() }
#[julia] pub fn optional_label571(_owner: Option<&OptionalOwner571>) -> &'static str { "optional" }
#[julia] pub fn direct_required571(owner: &OptionalOwner571) -> i32 { owner.value }
"""

const OPTIONAL571_LIB = Core.eval(
    @__MODULE__,
    Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), OPTIONAL571_SOURCE),
)

@testset "optional owner manifest explicitly describes nullable owner pointers (#571)" begin
    manifest = RustCall.extract_manifest(OPTIONAL571_SOURCE; mode = "inline")
    signatures = Dict(f.name => f for f in RustCall.manifest_function_signatures(manifest))
    @test signatures["optional_sum571"].arg_abis == ["handle_optional", "handle_optional"]
    @test signatures["optional_mut571"].arg_abis ==
          ["handle_optional_mut", "handle_optional"]
    @test signatures["optional_mixed571"].arg_abis == ["handle", "handle_optional"]
    @test all(
        h -> h !== nothing && h.name == "OptionalOwner571",
        signatures["optional_sum571"].arg_handles,
    )
    @test isempty(RustCall._present_call_borrows((nothing, nothing)))
    @test RustCall._present_call_borrows((nothing, :present, nothing)) == (:present,)
end

@testset "optional None/Some combinations, types and required compatibility (#571)" begin
    a, b = OptionalOwner571(Int32(3)), OptionalOwner571(Int32(4))
    @test optional_sum571(nothing, nothing) == 0
    @test optional_sum571(a, nothing) == 3
    @test optional_sum571(nothing, b) == 4
    @test optional_sum571(a, b) == 7
    @test optional_sum571(a, a) == 6
    @test optional_mixed571(a, nothing) == 3
    @test optional_mixed571(a, a) == 6
    @test direct_required571(a) == 3
    @test direct_required571(a.ptr) == 3
    for value in (C_NULL, a.ptr, Ptr{Int32}(a.ptr), 3, missing, Some(a))
        @test_throws ArgumentError optional_sum571(value, nothing)
    end
    wrong = OtherOptional571(Int32(9))
    @test_throws ArgumentError optional_sum571(wrong, nothing)
    @test_throws ArgumentError total(a, wrong)
    gone = OptionalOwner571(Int32(1))
    finalize(gone)
    @test_throws RustCall.RustError optional_sum571(gone, nothing)
    @test_throws RustCall.RustError total(a, gone)
    @test_throws RustCall.RustError total(gone, nothing)
    @test optional_sum571(nothing, nothing) == 0
    foreach(finalize, (a, b, wrong))
end

@testset "optional mutable aliases include required owners and receivers (#571)" begin
    a, b = OptionalOwner571(Int32(3)), OptionalOwner571(Int32(4))
    optional_mut571(nothing, nothing)
    optional_two_mut571(nothing, nothing)
    optional_mut571(a, nothing)
    @test get(a) == 4
    optional_mut571(nothing, a)
    optional_mut571(a, b)
    @test get(a) == 8
    for call in (
        () -> optional_mut571(a, a),
        () -> optional_two_mut571(a, a),
        () -> optional_required_mut571(a, a),
        () -> optional_mut_required571(a, a),
        () -> absorb(a, a),
        () -> give(a, a),
    )
        @test_throws ArgumentError call()
    end
    @test get(a) == 8
    @test total(a, a) == 16
    absorb(a, nothing)
    @test get(a) == 9
    give(a, nothing)
    give(a, b)
    @test get(b) == 13
    @test inspect(OptionalOwner571, nothing) == 0
    @test inspect(OptionalOwner571, a) == 9
    foreach(finalize, (a, b))
end

@testset "optional owners stay rooted and callback exceptions unwind cleanly (#571)" begin
    callback = () -> begin
        for _ = 1:3
            zeros(UInt8, 100_000)
            GC.gc()
        end
        Int32(0)
    end
    for _ = 1:10
        @test optional_callback571(OptionalOwner571(Int32(42)), callback) == 42
        @test optional_callback571(nothing, callback) == 0
    end
    a = OptionalOwner571(Int32(1))
    @test_throws ErrorException optional_callback571(a, () -> error("callback error"))
    @test isempty(RustCall._callback_frames())
    @test_throws RustCall.RustPanicError optional_panic571(a)
    @test get(a) == 11
    @test RustCall.is_err(optional_err571(a))
    @test get(a) == 31
    finalize(a)
end

function _optional571_return_checks(call)
    a = call(:OptionalOwner571, Int32(3))
    T = typeof(a)
    # A real generated handle carrying the current destructor/image but a
    # null pointer is malformed even though its image remains live.
    malformed =
        hasfield(T, :lib_name) ?
        Base.invokelatest(
            T,
            Ptr{Cvoid}(C_NULL),
            getfield(a, :lib_name),
            a.free_ptr,
            a.alive,
            a.free_channel,
        ) : Base.invokelatest(T, Ptr{Cvoid}(C_NULL), a.free_ptr, a.alive, a.free_channel)
    @testset "a malformed null owner is never optional absence (#571)" begin
        @test malformed.alive[]
        for fn in (
            :optional_result571,
            :optional_option571,
            :optional_text571,
            :optional_label571,
            :OptionalCtor571,
            :OptionalFallibleCtor571,
        )
            @test_throws RustCall.RustError call(fn, malformed)
        end
        @test_throws RustCall.RustError call(:optional_sum571, nothing, malformed)
        @test_throws RustCall.RustError call(:optional_mut571, malformed, nothing)
        for fn in (:total, :checked, :optional, :text, :label, :duplicate, :copy_optional)
            @test_throws RustCall.RustError call(fn, a, malformed)
            @test_throws RustCall.RustError call(fn, malformed, nothing)
        end
    end
    finalize(malformed)
    for other in (nothing, a)
        value = other === nothing ? 3 : 6
        @test RustCall.unwrap(call(:optional_result571, other)) ==
              (other === nothing ? 0 : 3)
        @test call(:optional_text571, other) == (other === nothing ? "0" : "3")
        @test call(:optional_label571, other) == "optional"
        option = call(:optional_option571, other)
        @test other === nothing ? RustCall.is_none(option) : RustCall.unwrap(option) == 3
        @test RustCall.unwrap(call(:checked, a, other)) == value
        @test call(:text, a, other) == string(value)
        @test call(:label, a, other) == "optional"
        opt = call(:optional, a, other)
        @test other === nothing ? RustCall.is_none(opt) : RustCall.unwrap(opt) == 3
        for copy in
            (RustCall.unwrap(call(:duplicate, a, other)), call(:copy_optional, a, other))
            @test call(:get, copy) == value
            finalize(copy)
        end
        for ctor_name in (:OptionalCtor571, :OptionalFallibleCtor571)
            @test_throws ArgumentError call(ctor_name, C_NULL)
            @test_throws ArgumentError call(ctor_name, a.ptr)
        end
        ctor = call(:OptionalCtor571, other)
        fallible = RustCall.unwrap(call(:OptionalFallibleCtor571, other))
        @test call(:get, ctor) == (other === nothing ? 0 : 3)
        @test call(:get, fallible) == (other === nothing ? 0 : 3)
        foreach(finalize, (ctor, fallible))
    end
    finalize(a)
end

@testset "optional owners work with all inline return and constructor paths (#571)" begin
    _optional571_return_checks(
        (name, args...) -> Base.invokelatest(getfield(@__MODULE__, name), args...),
    )
end

@testset "optional owners share checks across direct and persisted crates (#571)" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "src"))
        runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
        write(
            joinpath(dir, "Cargo.toml"),
            """
[package]
name = "optional_owners571"
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
            "use rustcall_julia_macros::julia;\n" * OPTIONAL571_SOURCE,
        )
        bindings = @rust_crate dir
        output = joinpath(dir, "WrittenOptional571.jl")
        RustCall.write_bindings_to_file(
            dir,
            output;
            output_module_name = "WrittenOptional571",
        )
        sandbox = Module(:OptionalSandbox571)
        Base.include(sandbox, output)
        written = Base.invokelatest(getfield, sandbox, :WrittenOptional571)
        modules = (getfield(bindings, :module_ref), written)
        try
            for mod in modules
                call(name, args...) =
                    Base.invokelatest(Base.invokelatest(getfield, mod, name), args...)
                _optional571_return_checks(call)
                a, b = call(:OptionalOwner571, Int32(3)), call(:OptionalOwner571, Int32(4))
                @test call(:optional_sum571, nothing, nothing) == 0
                @test call(:optional_sum571, a, nothing) == 3
                @test call(:optional_sum571, nothing, b) == 4
                @test call(:optional_sum571, a, b) == 7
                @test call(:optional_sum571, a, a) == 6
                @test call(:optional_mixed571, a, a) == 6
                @test_throws ArgumentError call(:optional_mut571, a, a)
                @test_throws ArgumentError call(:optional_two_mut571, a, a)
                @test_throws ArgumentError call(:optional_required_mut571, a, a)
                @test_throws ArgumentError call(:optional_mut_required571, a, a)
                @test_throws ArgumentError call(:absorb, a, a)
                @test_throws ArgumentError call(:give, a, a)
                call(:optional_two_mut571, nothing, nothing)
                call(:optional_mut571, a, nothing)
                @test call(:get, a) == 4
                @test_throws ArgumentError call(:optional_sum571, a.ptr, nothing)
                @test_throws ArgumentError call(:optional_sum571, C_NULL, nothing)
                @test call(:direct_required571, a.ptr) == 4
                @test call(:optional_callback571, a, () -> (GC.gc(); Int32(0))) == 4
                @test_throws ErrorException call(
                    :optional_callback571,
                    a,
                    () -> error("optional callback"),
                )
                @test isempty(RustCall._callback_frames())
                wrong = call(:OtherOptional571, Int32(9))
                @test_throws ArgumentError call(:optional_sum571, wrong, nothing)
                @test_throws ArgumentError call(:total, a, wrong)
                finalize(wrong)
                finalize(a)
                @test_throws RustCall.RustError call(:optional_sum571, a, nothing)
                @test_throws RustCall.RustError call(:total, a, nothing)
                @test_throws RustCall.RustError call(:total, b, a)
                finalize(b)
            end
        finally
            for mod in modules
                RustCall.unload_library(
                    Base.invokelatest(getfield, mod, :_LIB_NAME);
                    close = true,
                )
            end
        end
    end
end

@testset "unresolved optional owners have actionable boundary refusals (#571)" begin
    source = """
        #[julia] pub struct Owner { value: i32 }
        mod hidden { #[julia] pub struct Foreign { pub value: i32 } }
        use hidden::*;
        #[julia] pub fn inspect_unknown(x: Option<&Foreign>) -> i32 { x.map_or(0, |v| v.value) }
        """
    # The local glob is now proved by the shared scoped resolver (#569).
    report = RustCall.inline_boundary_report(source; io = devnull)
    @test isempty(filter(f -> f.item == "inspect_unknown", report.unsupported))
    manifest = RustCall.extract_manifest(source; mode = "inline")
    signature = only(filter(f -> f.name == "inspect_unknown", RustCall.manifest_function_signatures(manifest)))
    @test signature.arg_abis == ["handle_optional"]
    @test only(signature.arg_handles).name == "Foreign"

    # A valid Rust type alias remains deliberately unproved as an owner.
    source = replace(source, "use hidden::*;" => "type Foreign = hidden::Foreign;")
    report = RustCall.inline_boundary_report(source; io = devnull)
    finding = only(filter(f -> f.item == "inspect_unknown", report.unsupported))
    @test occursin("alias", finding.reason)
    @test finding.position == "argument `x`"
    @test occursin("explicit import or qualified path", finding.reason)
    @test !occursin("register_ffi_struct", finding.reason)
end

@testset "optional owners check the captured image across retirement and replacement (#571)" begin
    scopes = (Module(gensym(:OptionalOld571)), Module(gensym(:OptionalNew571)))
    libraries = String[]
    objects = Any[]
    call(mod, name, args...) =
        Base.invokelatest(Base.invokelatest(getfield, mod, name), args...)
    try
        for (generation, mod) in enumerate(scopes)
            Core.eval(mod, :(using RustCall))
            source =
                OPTIONAL571_SOURCE *
                "\n#[julia] pub fn generation_optional571() -> i32 { $generation }\n"
            push!(
                libraries,
                Core.eval(
                    mod,
                    Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source),
                ),
            )
        end
        mod = first(scopes)
        old = call(mod, :OptionalOwner571, Int32(3))
        push!(objects, old)
        foreign = call(last(scopes), :OptionalOwner571, Int32(9))
        push!(objects, foreign)
        @test nameof(typeof(foreign)) == nameof(typeof(old))
        @test typeof(foreign) !== typeof(old)
        @test_throws ArgumentError call(mod, :optional_sum571, foreign, nothing)
        @test_throws ArgumentError call(mod, :total, old, foreign)
        @test call(mod, :optional_sum571, nothing, old) == 3
        @test RustCall.alias_artifact!(
            RustCall.inline_rustc_policy(),
            last(libraries),
            first(libraries),
        )
        fresh = call(mod, :OptionalOwner571, Int32(5))
        push!(objects, fresh)
        @test old.alive !== fresh.alive
        @test old.alive[]  # retired remains mapped; a live old owner has an image
        @test call(mod, :optional_sum571, nothing, nothing) == 0
        @test call(mod, :optional_sum571, nothing, fresh) == 5
        @test call(mod, :optional_sum571, fresh, fresh) == 10
        for _ = 1:2
            @test_throws ArgumentError call(mod, :optional_sum571, old, fresh)
            @test_throws ArgumentError call(mod, :optional_sum571, nothing, old)
            @test_throws ArgumentError call(mod, :optional_mixed571, fresh, old)
            @test_throws ArgumentError call(mod, :optional_mixed571, old, nothing)
            for fn in (
                :optional_result571,
                :optional_option571,
                :optional_text571,
                :optional_label571,
                :OptionalCtor571,
                :OptionalFallibleCtor571,
            )
                @test_throws ArgumentError call(mod, fn, old)
            end
            for fn in
                (:total, :checked, :optional, :text, :label, :duplicate, :copy_optional)
                @test_throws ArgumentError call(mod, fn, old, nothing)
                @test_throws ArgumentError call(mod, fn, fresh, old)
            end
            @test_throws ArgumentError call(mod, :optional_callback571, old, () -> Int32(0))
            @test isempty(RustCall._callback_frames())
        end
        @test call(mod, :optional_callback571, fresh, () -> Int32(0)) == 5
    finally
        foreach(finalize, objects)
        for lib in libraries
            haskey(RustCall.RUST_LIBRARIES, lib) &&
                RustCall.unload_library(lib; close = true)
            RustCall.close_retired_handles!(RustCall.retired_handles(lib))
        end
    end
end

@testset "an owner from an explicitly closed image is an error, never None (#571)" begin
    scope = Module(gensym(:OptionalClosed571))
    Core.eval(scope, :(using RustCall))
    lib = Core.eval(
        scope,
        Expr(
            :macrocall,
            Symbol("@rust_str"),
            LineNumberNode(1),
            OPTIONAL571_SOURCE * "\n#[julia] pub fn closed_optional571() -> i32 { 571 }\n",
        ),
    )
    call(name, args...) =
        Base.invokelatest(Base.invokelatest(getfield, scope, name), args...)
    owner = call(:OptionalOwner571, Int32(1))
    try
        @test call(:optional_sum571, nothing, owner) == 1
        RustCall.unload_library(lib; close = true)
        @test !owner.alive[]
        @test_throws RustCall.RustError call(:optional_sum571, nothing, owner)
    finally
        finalize(owner)
        haskey(RustCall.RUST_LIBRARIES, lib) && RustCall.unload_library(lib; close = true)
    end
end

@testset "crate optional owners follow replacement snapshots in both emitters (#571)" begin
    mktempdir() do root
        runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
        bindings = Any[]
        for generation = 1:2
            dir = joinpath(root, "generation$generation")
            mkpath(joinpath(dir, "src"))
            write(
                joinpath(dir, "Cargo.toml"),
                """
[package]
name = "optional_generations571"
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
                "use rustcall_julia_macros::julia;\n" *
                OPTIONAL571_SOURCE *
                "\n#[julia] pub fn optional_generation571() -> i32 { $generation }\n",
            )
            push!(bindings, @rust_crate dir)
        end
        first_mod = getfield(first(bindings), :module_ref)
        replacement = getfield(last(bindings), :module_ref)
        written_path = joinpath(root, "WrittenGenerations571.jl")
        RustCall.write_bindings_to_file(
            joinpath(root, "generation1"),
            written_path;
            output_module_name = "WrittenGenerations571",
        )
        sandbox = Module(:WrittenGenerationSandbox571)
        Base.include(sandbox, written_path)
        written = Base.invokelatest(getfield, sandbox, :WrittenGenerations571)
        modules = (first_mod, written)
        call(mod, fn, args...) =
            Base.invokelatest(Base.invokelatest(getfield, mod, fn), args...)
        libname(mod) = Base.invokelatest(getfield, mod, :_LIB_NAME)
        objects = Any[]
        try
            old = [call(mod, :OptionalOwner571, Int32(3)) for mod in modules]
            append!(objects, old)
            foreign = call(replacement, :OptionalOwner571, Int32(9))
            push!(objects, foreign)
            for (mod, owner) in zip(modules, old)
                @test nameof(typeof(foreign)) == nameof(typeof(owner))
                @test typeof(foreign) !== typeof(owner)
                @test_throws ArgumentError call(mod, :optional_sum571, foreign, nothing)
                @test_throws ArgumentError call(mod, :total, owner, foreign)
            end
            for lib in unique(libname.(modules))
                @test RustCall.alias_artifact!(
                    RustCall.crate_direct_policy(),
                    libname(replacement),
                    lib,
                )
            end
            for (mod, previous) in zip(modules, old)
                fresh = call(mod, :OptionalOwner571, Int32(5))
                push!(objects, fresh)
                @test previous.alive !== fresh.alive
                @test previous.alive[]
                for _ = 1:2
                    @test call(mod, :optional_sum571, nothing, nothing) == 0
                    @test call(mod, :optional_sum571, nothing, fresh) == 5
                    @test_throws ArgumentError call(
                        mod,
                        :optional_sum571,
                        nothing,
                        previous,
                    )
                    @test_throws ArgumentError call(
                        mod,
                        :optional_mixed571,
                        fresh,
                        previous,
                    )
                    @test_throws ArgumentError call(
                        mod,
                        :optional_mixed571,
                        previous,
                        nothing,
                    )
                    @test_throws ArgumentError call(mod, :optional_sum571, previous, fresh)
                    for fn in (
                        :total,
                        :checked,
                        :optional,
                        :text,
                        :label,
                        :duplicate,
                        :copy_optional,
                    )
                        @test_throws ArgumentError call(mod, fn, previous, nothing)
                        @test_throws ArgumentError call(mod, fn, fresh, previous)
                    end
                    for fn in (
                        :optional_result571,
                        :optional_option571,
                        :optional_text571,
                        :optional_label571,
                        :OptionalCtor571,
                        :OptionalFallibleCtor571,
                    )
                        @test_throws ArgumentError call(mod, fn, previous)
                    end
                    @test_throws ArgumentError call(
                        mod,
                        :optional_callback571,
                        previous,
                        () -> Int32(0),
                    )
                    @test isempty(RustCall._callback_frames())
                end
            end
        finally
            foreach(finalize, objects)
            for lib in unique(libname.((modules..., replacement)))
                haskey(RustCall.RUST_LIBRARIES, lib) &&
                    RustCall.unload_library(lib; close = true)
                RustCall.close_retired_handles!(RustCall.retired_handles(lib))
            end
        end
    end
end

@testset "retaining and unsupported optional borrows report precise refusals (#571)" begin
    for signature in (
        "pub fn bad571(x: Option<&'static Owner571>) -> i32 { 0 }",
        "pub fn bad571<'a: 'static>(x: Option<&'a Owner571>) -> i32 { 0 }",
        "pub fn bad571<'a>(x: Option<&'a Owner571>) -> Option<&'a Owner571> { x }",
        "pub fn bad571(x: Option<&&Owner571>) -> i32 { 0 }",
        "pub fn bad571(x: Option<Box<Owner571>>) -> i32 { 0 }",
        "pub fn bad571(x: Option<*const Owner571>) -> i32 { 0 }",
        "pub fn bad571(x: Option<&[Owner571]>) -> i32 { 0 }",
    )
        source = "#[julia] pub struct Owner571 { value: i32 }\n#[julia] " * signature
        manifest = RustCall.extract_manifest(source; mode = "inline")
        sig = only(RustCall.manifest_function_signatures(manifest))
        @test RustCall._rust_refuses(sig.skip_reason)
        report = RustCall.inline_boundary_report(source; io = devnull)
        @test any(
            f -> f.item == "bad571" && f.position == "entry point",
            report.unsupported,
        )
    end
end
