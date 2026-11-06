using Test, RustCall

const OPTIONAL_SLICE575_SOURCE = raw"""
use std::sync::atomic::{AtomicU32, Ordering};
static MIXED_ENTRIES575: AtomicU32 = AtomicU32::new(0);
fn entered575() { MIXED_ENTRIES575.fetch_add(1, Ordering::SeqCst); }
#[julia] pub fn mixed_entries575() -> u32 { MIXED_ENTRIES575.load(Ordering::SeqCst) }
#[repr(C)]
#[julia] pub struct MixedOwner575 { pub first: f64, pub second: f64 }
#[julia] impl MixedOwner575 {
    #[julia] pub fn new(value: f64) -> Self { Self { first: value, second: 7.0 } }
    #[julia] pub fn from_inputs(owner: Option<&Self>, xs: &[f64]) -> Self { entered575(); Self { first: owner.map_or(0.0, |v| v.first) + xs.iter().sum::<f64>(), second: 7.0 } }
    #[julia] pub fn value(&self) -> f64 { self.first }
    #[julia] pub fn apply(&self, owner: Option<&Self>, xs: &mut [f64]) -> Result<f64, String> { entered575(); let delta = self.first + owner.map_or(0.0, |v| v.first); for x in xs.iter_mut() { *x += delta; } Ok(xs.iter().sum()) }
    #[julia] pub fn describe(owner: Option<&Self>, xs: &[f64]) -> String { entered575(); (owner.map_or(0.0, |v| v.first) + xs.iter().sum::<f64>()).to_string() }
    #[julia] pub fn copy_inputs(&self, owner: Option<&Self>, xs: &[f64]) -> Self { entered575(); Self { first: self.first + owner.map_or(0.0, |v| v.first) + xs.iter().sum::<f64>(), second: 7.0 } }
    #[julia] pub fn result_copy(&self, owner: Option<&Self>, xs: &[f64]) -> Result<Self, String> { Ok(self.copy_inputs(owner, xs)) }
}
#[julia] pub struct MixedFallible575 { value: f64 }
#[julia] impl MixedFallible575 {
    #[julia] pub fn from_inputs(owner: Option<&MixedOwner575>, xs: &[f64]) -> Result<Self, String> { entered575(); Ok(Self { value: owner.map_or(0.0, |v| v.first) + xs.iter().sum::<f64>() }) }
    #[julia] pub fn fallible_value(&self) -> f64 { self.value }
}
#[julia] pub fn mixed_shared575(owner: Option<&MixedOwner575>, xs: &[f64]) -> f64 { entered575(); owner.map_or(0.0, |v| v.second) + xs.iter().sum::<f64>() }
#[julia] pub fn mixed_write575(owner: Option<&MixedOwner575>, xs: &mut [f64]) { entered575(); let delta = owner.map_or(1.0, |v| v.first); for x in xs { *x += delta; } }
#[julia] pub fn mixed_owner_mut575(owner: Option<&mut MixedOwner575>, xs: &[f64]) -> f64 { entered575(); if let Some(value) = owner { value.first += xs.iter().sum::<f64>(); value.first } else { xs.iter().sum() } }
#[julia] pub fn mixed_pair575(a: Option<&mut MixedOwner575>, b: Option<&MixedOwner575>, xs: &mut [f64]) { entered575(); if let Some(value) = a { value.first += b.map_or(1.0, |v| v.first); } for x in xs { *x += 1.0; } }
#[julia] pub fn mixed_err575(owner: Option<&mut MixedOwner575>, xs: &mut [f64]) -> Result<(), String> { entered575(); if let Some(value) = owner { value.first += 10.0; } if !xs.is_empty() { xs[0] += 10.0; } Err("mixed mutation".into()) }
#[julia] pub fn mixed_panic575(owner: Option<&mut MixedOwner575>, xs: &mut [f64]) { entered575(); if let Some(value) = owner { value.first += 20.0; } if !xs.is_empty() { xs[0] += 20.0; } panic!("mixed panic"); }
#[julia] pub fn mixed_callback575(owner: Option<&MixedOwner575>, xs: &mut [f64], callback: extern "C" fn() -> i32) -> f64 { entered575(); callback(); let delta = owner.map_or(1.0, |v| v.first); for x in xs.iter_mut() { *x += delta; } xs.iter().sum() }
#[julia] pub fn mixed_text575(owner: Option<&MixedOwner575>, xs: &[f64]) -> String { entered575(); (owner.map_or(0.0, |v| v.first) + xs.iter().sum::<f64>()).to_string() }
#[julia] pub fn mixed_label575(_owner: Option<&MixedOwner575>, _xs: &[f64]) -> &'static str { entered575(); "mixed" }
#[julia] pub fn mixed_option575(owner: Option<&MixedOwner575>, xs: &[f64]) -> Option<f64> { entered575(); owner.map(|v| v.first + xs.iter().sum::<f64>()) }
"""

function _optional_slice575_checks(mod)
    binding(name) = Base.invokelatest(getfield, mod, name)
    call(name, args...) = Base.invokelatest(binding(name), args...)
    owner_type = binding(:MixedOwner575)
    owner = call(:MixedOwner575, 3.0)
    objects = Any[owner]
    try
        xs = [1.0, 2.0]
        @test call(:mixed_shared575, nothing, xs) == 3.0
        @test call(:mixed_shared575, owner, xs) == 10.0
        @test call(:mixed_write575, nothing, xs) === nothing
        @test xs == [2.0, 3.0]
        @test call(:mixed_write575, owner, xs) === nothing
        @test xs == [5.0, 6.0]
        @test call(:mixed_owner_mut575, nothing, xs) == 11.0
        @test call(:mixed_owner_mut575, owner, [1.0]) == 4.0
        @test call(:value, owner) == 4.0
        @test call(:mixed_pair575, nothing, nothing, xs) === nothing
        @test xs == [6.0, 7.0]
        @test_throws ArgumentError call(:mixed_pair575, owner, owner, xs)
        @test_throws ArgumentError call(:mixed_write575, owner.ptr, xs)
        @test_throws ArgumentError call(:mixed_write575, C_NULL, xs)
        @test_throws ArgumentError call(:mixed_write575, owner, Float32[1, 2])
        @test_throws ArgumentError call(:mixed_write575, owner, @view(xs[1:2:2]))
        gone = call(:MixedOwner575, 1.0)
        finalize(gone)
        @test_throws RustCall.RustError call(:mixed_write575, gone, xs)
        @test call(:mixed_text575, owner, [1.0]) == "5"
        @test call(:mixed_label575, nothing, xs) == "mixed"
        @test RustCall.unwrap(call(:mixed_option575, owner, [1.0])) == 5.0
        @test call(:mixed_option575, nothing, xs).value === nothing
        @test call(:describe, owner_type, nothing, [2.0]) == "2"
        @test RustCall.unwrap(call(:apply, owner, owner, [1.0])) == 9.0
        constructed = call(:MixedOwner575, owner, [2.0])
        copied = call(:copy_inputs, owner, nothing, [2.0])
        result_copy = RustCall.unwrap(call(:result_copy, owner, owner, [2.0]))
        fallible = RustCall.unwrap(call(:MixedFallible575, owner, [2.0]))
        append!(objects, (constructed, copied, result_copy, fallible))
        @test call(:value, constructed) == 6.0
        @test call(:value, copied) == 6.0
        @test call(:value, result_copy) == 10.0
        @test call(:fallible_value, fallible) == 6.0
        callback_xs = [1.0, 2.0]
        @test call(:mixed_callback575, owner, callback_xs, () -> (GC.gc(); Int32(0))) ==
              11.0
        @test callback_xs == [5.0, 6.0]
        @test_throws ErrorException call(
            :mixed_callback575,
            owner,
            [1.0],
            () -> error("mixed callback"),
        )
        @test isempty(RustCall._callback_frames())
        error_xs = [1.0]
        result = call(:mixed_err575, owner, error_xs)
        @test !result.is_ok
        @test error_xs == [11.0]
        @test call(:value, owner) == 14.0
        @test_throws RustCall.RustPanicError call(:mixed_panic575, owner, error_xs)
        @test error_xs == [31.0]
        @test call(:value, owner) == 34.0

        # Initialized storage, a live owner and repr(C) establish this view's
        # representation. It stays rooted here; no hidden Rust references or
        # callbacks run during these deliberately overlapping calls.
        GC.@preserve owner begin
            interior = unsafe_wrap(
                Vector{Float64},
                Ptr{Float64}(owner.ptr) + sizeof(Float64),
                1;
                own = false,
            )
            @test interior == [7.0]
            @test call(:mixed_shared575, owner, interior) == 14.0  # shared/shared may alias
            entered = call(:mixed_entries575)
            @test_throws RustCall.RustPanicError call(:mixed_write575, owner, interior)
            @test_throws RustCall.RustPanicError call(:mixed_owner_mut575, owner, interior)
            @test interior == [7.0]
            @test call(:value, owner) == 34.0
            @test call(:mixed_entries575) == entered
        end
    finally
        foreach(finalize, objects)
    end
end

@testset "numeric slices and optional checked owners compose across emitters (#570/#571)" begin
    mktempdir() do root
        source = OPTIONAL_SLICE575_SOURCE
        inline = Module(gensym(:MixedInline575))
        Core.eval(inline, :(using RustCall))
        inline_lib = Core.eval(
            inline,
            Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source),
        )
        crate = joinpath(root, "crate")
        mkpath(joinpath(crate, "src"))
        runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
        write(
            joinpath(crate, "Cargo.toml"),
            """
[package]
name = "optional_slice575"
version = "0.1.0"
edition = "2021"
[lib]
crate-type = ["cdylib"]
[dependencies]
rustcall_julia_macros = { path = "$runtime" }
""",
        )
        write(
            joinpath(crate, "src", "lib.rs"),
            "use rustcall_julia_macros::julia;\n" * source,
        )
        info = RustCall.scan_crate(crate)
        symbols = RustCall._slice_arg_symbols(info)
        @test !isempty(symbols)
        @test symbols == RustCall._optional_owner_symbols(info)
        direct_proxy = @rust_crate crate
        direct = getfield(direct_proxy, :module_ref)
        output = joinpath(root, "WrittenMixed575.jl")
        RustCall.write_bindings_to_file(
            crate,
            output;
            output_module_name = "WrittenMixed575",
        )
        sandbox = Module(gensym(:WrittenMixedSandbox575))
        Base.include(sandbox, output)
        persisted = Base.invokelatest(getfield, sandbox, :WrittenMixed575)
        modules = (inline, direct, persisted)
        try
            for (name, mod) in zip(("inline", "direct", "persisted"), modules)
                @testset "$name" begin
                    lib =
                        mod === inline ? inline_lib :
                        Base.invokelatest(getfield, mod, :_LIB_NAME)
                    for symbol in symbols
                        target = RustCall.resolve_call_target(lib, symbol)
                        @test RustCall.Libdl.dlsym(
                            target.handle,
                            symbol * "_slice_ptr_len_v1",
                        ) != C_NULL
                        @test RustCall.Libdl.dlsym(
                            target.handle,
                            symbol * "_optional_owner_ptr_v1",
                        ) != C_NULL
                    end
                    _optional_slice575_checks(mod)
                end
            end
        finally
            libs = unique([
                inline_lib,
                Base.invokelatest(getfield, direct, :_LIB_NAME),
                Base.invokelatest(getfield, persisted, :_LIB_NAME),
            ])
            for lib in libs
                haskey(RustCall.RUST_LIBRARIES, lib) &&
                    RustCall.unload_library(lib; close = true)
            end
        end
    end
end

@testset "mixed consumers require both producer markers before entry (#570/#571)" begin
    mktempdir() do root
        macro_dir = joinpath(root, "identity_macro")
        crate = joinpath(root, "partial_producer")
        mkpath(joinpath(macro_dir, "src"))
        mkpath(joinpath(crate, "src"))
        write(
            joinpath(macro_dir, "Cargo.toml"),
            """
[package]
name = "mixed_marker_macro575"
version = "0.1.0"
edition = "2021"
[lib]
proc-macro = true
""",
        )
        write(
            joinpath(macro_dir, "src", "lib.rs"),
            """
use proc_macro::TokenStream;
#[proc_macro_attribute]
pub fn julia(_: TokenStream, input: TokenStream) -> TokenStream { input }
""",
        )
        write(
            joinpath(crate, "Cargo.toml"),
            """
[package]
name = "partial_mixed_producer575"
version = "0.1.0"
edition = "2021"
[lib]
crate-type = ["cdylib"]
[dependencies]
mixed_marker_macro575 = { path = "../identity_macro" }
""",
        )
        # The actual exports use the correct raw C slots and never dereference
        # an input. If either gate regresses, entry is safe and the counter
        # records the failure; no native slice or Option layout is invoked.
        source = raw"""
        use mixed_marker_macro575::julia;
        use std::sync::atomic::{AtomicU32, Ordering};
        static ENTRIES: AtomicU32 = AtomicU32::new(0);
        #[julia] pub struct PartialMixed575 { value: i32 }
        #[julia] pub fn partial_entries575() -> u32 { ENTRIES.load(Ordering::SeqCst) }
        #[julia] pub fn partial_slice575(_owner: Option<&PartialMixed575>, _xs: &[f64]) -> i32 { 0 }
        #[julia] pub fn partial_optional575(_owner: Option<&PartialMixed575>, _xs: &[f64]) -> i32 { 0 }
        #[no_mangle] pub extern "C" fn rustcall_partial_entries575() -> u32 { partial_entries575() }
        #[no_mangle] pub extern "C" fn rustcall_partial_slice575(_: *const PartialMixed575, _: *const f64, _: usize) -> i32 { ENTRIES.fetch_add(1, Ordering::SeqCst); 0 }
        #[no_mangle] pub extern "C" fn rustcall_partial_optional575(_: *const PartialMixed575, _: *const f64, _: usize) -> i32 { ENTRIES.fetch_add(1, Ordering::SeqCst); 0 }
        #[no_mangle] pub extern "C" fn rustcall_partial_slice575_slice_ptr_len_v1() {}
        #[no_mangle] pub extern "C" fn rustcall_partial_optional575_optional_owner_ptr_v1() {}
        """
        write(joinpath(crate, "src", "lib.rs"), source)
        proxy = @rust_crate crate
        direct = getfield(proxy, :module_ref)
        output = joinpath(root, "WrittenPartialMixed575.jl")
        RustCall.write_bindings_to_file(
            crate,
            output;
            output_module_name = "WrittenPartialMixed575",
        )
        sandbox = Module(gensym(:PartialMixedSandbox575))
        Base.include(sandbox, output)
        persisted = Base.invokelatest(getfield, sandbox, :WrittenPartialMixed575)

        inline = Module(gensym(:PartialMixedInline575))
        Core.eval(inline, :(using RustCall))
        manifest = RustCall.extract_manifest(source; mode = "inline")
        signatures = RustCall.manifest_function_signatures(manifest)
        owners = RustCall.manifest_struct_infos(manifest)
        definitions, functions = RustCall._inline_wrapper_exprs(signatures, owners)
        body = Expr(:block, definitions..., functions)
        Core.eval(inline, :(macro mixed_partial_definitions575()
            ;$(QuoteNode(body));
        end))
        Core.eval(
            inline,
            Expr(:macrocall, Symbol("@mixed_partial_definitions575"), LineNumberNode(1)),
        )
        lib = Base.invokelatest(getfield, direct, :_LIB_NAME)
        compiler = RustCall.get_default_compiler()
        RustCall._record_module_block!(
            inline,
            lib,
            RustCall.RustBlockSnapshot(
                "",
                "",
                compiler.target_triple,
                compiler.optimization_level,
                nothing,
            ),
            [signature.symbol for signature in signatures],
        )
        try
            for (emitter, mod) in
                zip(("direct", "persisted", "inline"), (direct, persisted, inline))
                @testset "$emitter" begin
                    call(name, args...) =
                        Base.invokelatest(Base.invokelatest(getfield, mod, name), args...)
                    for (name, diagnostic) in (
                        (:partial_slice575, "incompatible optional borrowed-owner ABI"),
                        (:partial_optional575, "incompatible numeric slice argument ABI"),
                    )
                        error = try
                            call(name, nothing, [1.0])
                            nothing
                        catch exception
                            exception
                        end
                        @test error isa ErrorException
                        @test occursin(diagnostic, sprint(showerror, error))
                        @test call(:partial_entries575) == 0
                    end
                end
            end
            # Exercise both cold resolution and a cache hit on the captured
            # image. Failed conjunction checks must never publish a cold entry.
            for symbol in ("rustcall_partial_slice575", "rustcall_partial_optional575")
                cache = RustCall.CallTargetCache()
                @test_throws ErrorException RustCall.cached_call_target(
                    cache,
                    inline,
                    symbol;
                    slice_args = true,
                    optional_owner_args = true,
                )
                @test RustCall.cached_target_hit(cache) === nothing
                RustCall.cached_call_target(cache, inline, symbol)
                @test_throws ErrorException RustCall.cached_call_target(
                    cache,
                    inline,
                    symbol;
                    slice_args = true,
                    optional_owner_args = true,
                )
            end
            @test Base.invokelatest(
                Base.invokelatest(getfield, direct, :partial_entries575),
            ) == 0
        finally
            libs = unique([lib, Base.invokelatest(getfield, persisted, :_LIB_NAME)])
            for name in libs
                haskey(RustCall.RUST_LIBRARIES, name) &&
                    RustCall.unload_library(name; close = true)
            end
        end
    end
end
