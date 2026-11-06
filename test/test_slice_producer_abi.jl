using Test, RustCall

# A local identity attribute models an older producer without downloading or
# executing its unsupported native slice ABI. Every incompatible entry point
# increments ENTRIES; all consumer shapes must reject it before that happens.
@testset "slice consumers reject old producers before every return shape (#570)" begin
    mktempdir() do dir
        macro_dir = joinpath(dir, "legacy_macro")
        crate = joinpath(dir, "legacy_slices")
        mkpath(joinpath(macro_dir, "src"))
        mkpath(joinpath(crate, "src"))
        write(
            joinpath(macro_dir, "Cargo.toml"),
            """
[package]
name = "legacy_slice_macro"
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
pub fn julia(_: TokenStream, item: TokenStream) -> TokenStream { item }
""",
        )
        write(
            joinpath(crate, "Cargo.toml"),
            """
[package]
name = "legacy_slice_producer570"
version = "0.1.0"
edition = "2021"
[lib]
crate-type = ["cdylib"]
[dependencies]
legacy_slice_macro = { path = "../legacy_macro" }
""",
        )
        write(
            joinpath(crate, "src", "lib.rs"),
            raw"""
#![allow(improper_ctypes_definitions, non_snake_case)]
use legacy_slice_macro::julia;
use std::sync::atomic::{AtomicU32, Ordering};
static ENTRIES: AtomicU32 = AtomicU32::new(0);
fn entered() -> usize { ENTRIES.fetch_add(1, Ordering::SeqCst); 0 }
#[julia] pub fn entries() -> u32 { ENTRIES.load(Ordering::SeqCst) }
#[julia] pub fn legacy_sum(xs: &[f64]) -> f64 { xs.iter().sum() }
#[julia] pub fn legacy_text(_: &[f64]) -> String { String::new() }
#[julia] pub fn legacy_option(_: &[f64]) -> Option<i32> { None }
#[julia] pub fn legacy_result(_: &[f64]) -> Result<i32,i32> { Ok(0) }
#[julia] pub fn legacy_callback(_: &[f64], _: extern "C" fn() -> i32) -> i32 { 0 }
#[julia] pub struct LegacySlice { value: i32 }
#[julia] impl LegacySlice {
    #[julia] pub fn seed() -> Self { Self { value: 7 } }
    #[julia] pub fn from_slice(_: &[f64]) -> Self { Self::seed() }
    #[julia] pub fn checked(_: &[f64], _: bool) -> Result<Self,i32> { Ok(Self::seed()) }
    #[julia] pub fn static_sum(xs: &[f64]) -> f64 { xs.iter().sum() }
    #[julia] pub fn sum(&self, xs: &[f64]) -> f64 { xs.iter().sum() }
    #[julia] pub fn text(&self, _: &[f64]) -> String { String::new() }
    #[julia] pub fn view(&self, _: &[f64]) -> &'static str { "" }
    #[julia] pub fn option(&self, _: &[f64]) -> Option<i32> { None }
    #[julia] pub fn result(&self, _: &[f64]) -> Result<i32,i32> { Ok(0) }
    #[julia] pub fn duplicate(&self, _: &[f64]) -> Result<Self,i32> { Ok(Self::seed()) }
    #[julia] pub fn copy(&self, _: &[f64]) -> Self { Self::seed() }
}
#[no_mangle] pub extern "C" fn rustcall_entries() -> u32 { entries() }
#[no_mangle] pub extern "C" fn rustcall_LegacySlice_seed() -> *mut LegacySlice {
    Box::into_raw(Box::new(LegacySlice::seed()))
}
#[no_mangle] pub extern "C" fn LegacySlice_free(p: *mut LegacySlice) {
    if !p.is_null() { unsafe { drop(Box::from_raw(p)); } }
}
// Deliberately native-fat-pointer arguments and incompatible
// returns. A call to any of these would be an ABI violation.
#[no_mangle] pub extern "C" fn rustcall_legacy_sum(_: &[f64]) -> usize { entered() }
#[no_mangle] pub extern "C" fn rustcall_legacy_text(_: &[f64]) -> usize { entered() }
#[no_mangle] pub extern "C" fn rustcall_legacy_option(_: &[f64]) -> usize { entered() }
#[no_mangle] pub extern "C" fn rustcall_legacy_result(_: &[f64]) -> usize { entered() }
#[no_mangle] pub extern "C" fn rustcall_legacy_callback(_: &[f64], _: extern "C" fn() -> i32) -> usize { entered() }
#[no_mangle] pub extern "C" fn rustcall_LegacySlice_from_slice(_: &[f64]) -> usize { entered() }
#[no_mangle] pub extern "C" fn rustcall_LegacySlice_checked(_: &[f64], _: bool) -> usize { entered() }
#[no_mangle] pub extern "C" fn rustcall_LegacySlice_static_sum(_: &[f64]) -> usize { entered() }
#[no_mangle] pub extern "C" fn rustcall_LegacySlice_sum(_: *const LegacySlice, _: &[f64]) -> usize { entered() }
#[no_mangle] pub extern "C" fn rustcall_LegacySlice_text(_: *const LegacySlice, _: &[f64]) -> usize { entered() }
#[no_mangle] pub extern "C" fn rustcall_LegacySlice_view(_: *const LegacySlice, _: &[f64]) -> usize { entered() }
#[no_mangle] pub extern "C" fn rustcall_LegacySlice_option(_: *const LegacySlice, _: &[f64]) -> usize { entered() }
#[no_mangle] pub extern "C" fn rustcall_LegacySlice_result(_: *const LegacySlice, _: &[f64]) -> usize { entered() }
#[no_mangle] pub extern "C" fn rustcall_LegacySlice_duplicate(_: *const LegacySlice, _: &[f64]) -> usize { entered() }
#[no_mangle] pub extern "C" fn rustcall_LegacySlice_copy(_: *const LegacySlice, _: &[f64]) -> usize { entered() }
// Boxed-result compatibility is independent of slice compatibility.
#[no_mangle] pub extern "C" fn rustcall_LegacySlice_checked_boxed_result_v1() -> u8 { 1 }
#[no_mangle] pub extern "C" fn rustcall_LegacySlice_duplicate_boxed_result_v1() -> u8 { 1 }
#[no_mangle] pub extern "C" fn legacy_text_free_rust_string(_: *mut u8, _: usize, _: usize) {}
#[no_mangle] pub extern "C" fn LegacySlice_text_free_rust_string(_: *mut u8, _: usize, _: usize) {}
""",
        )
        bindings = @rust_crate crate
        memory = getfield(bindings, :module_ref)
        output = joinpath(dir, "OldSlices.jl")
        RustCall.write_bindings_to_file(crate, output; output_module_name = "OldSlices570")
        sandbox = Module(:OldSlicesSandbox570)
        Base.include(sandbox, output)
        written = Base.invokelatest(getfield, sandbox, :OldSlices570)
        field(mod, name) = Base.invokelatest(getfield, mod, name)
        invoke(f, args...) = Base.invokelatest(f, args...)
        function refused(f)
            before = length(RustCall._callback_frames())
            err = try
                f()
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin(
                "incompatible numeric slice argument ABI",
                sprint(showerror, err),
            )
            @test occursin("0.7.0", sprint(showerror, err))
            @test length(RustCall._callback_frames()) == before
        end
        try
            for mod in (memory, written)
                T = field(mod, :LegacySlice)
                owner = invoke(T) # Slice-free legacy producer remains usable.
                xs = [1.0, 2.0]
                try
                    for name in (:legacy_sum, :legacy_text, :legacy_option, :legacy_result)
                        refused(() -> invoke(field(mod, name), xs))
                    end
                    refused(() -> invoke(field(mod, :legacy_callback), xs, () -> Int32(0)))
                    refused(() -> invoke(T, xs))
                    refused(() -> invoke(T, xs, false))
                    refused(() -> invoke(field(mod, :static_sum), T, xs))
                    for name in (:sum, :text, :view, :option, :result, :duplicate, :copy)
                        refused(() -> invoke(field(mod, name), owner, xs))
                    end
                    @test invoke(field(mod, :entries)) == UInt32(0)
                    # The same captured-target guard used by inline methods.
                    lib = field(mod, :_LIB_NAME)
                    refused(
                        () -> RustCall._call_rust_method(
                            lib,
                            "rustcall_LegacySlice_sum",
                            owner.ptr,
                            Float64,
                            pointer(xs),
                            Csize_t(length(xs));
                            slice_args = true,
                        ),
                    )
                    @test invoke(field(mod, :entries)) == UInt32(0)
                    # The inline free-wrapper cache must not publish a cold
                    # target before validating its captured producer image.
                    previous = RustCall.CURRENT_LIB[]
                    try
                        RustCall.CURRENT_LIB[] = lib
                        inline_mod = Module(:LegacySliceInline570)
                        cache = RustCall.CallTargetCache()
                        symbol = "rustcall_legacy_sum"
                        refused(
                            () -> RustCall.cached_call_target(
                                cache,
                                inline_mod,
                                symbol;
                                slice_args = true,
                            ),
                        )
                        @test RustCall.cached_target_hit(cache) === nothing
                        # A previously populated cache must not bypass a newly
                        # requested slice producer requirement, either.
                        target = RustCall.resolve_call_target(lib, symbol; fallback = false)
                        RustCall.publish_call_target!(
                            cache,
                            RustCall.artifact_epoch(),
                            target,
                        )
                        refused(
                            () -> RustCall.cached_call_target(
                                cache,
                                inline_mod,
                                symbol;
                                slice_args = true,
                            ),
                        )
                        @test invoke(field(mod, :entries)) == UInt32(0)
                    finally
                        RustCall.CURRENT_LIB[] = previous
                    end
                finally
                    finalize(owner)
                end
            end
        finally
            for mod in (memory, written)
                RustCall.unload_library(field(mod, :_LIB_NAME); close = true)
            end
        end
    end
end
