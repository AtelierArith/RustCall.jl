using Test, RustCall

# This producer deliberately predates the optional-owner marker. Its identity
# attribute leaves the Rust signatures available for scanning. The hand-written
# exports use safe explicit pointer slots so a guard regression can be detected
# by a counter without ever invoking Rust's native Option/niche ABI.
function _legacy_optional571_source()
    definitions = raw"""
        use legacy_optional_macro::julia;
        use std::sync::atomic::{AtomicU32, Ordering};
        static ENTRIES: AtomicU32 = AtomicU32::new(0);
        fn entered() { ENTRIES.fetch_add(1, Ordering::SeqCst); }
        #[repr(C)] pub struct OldResult { flag: u8, ok: i32, err: i32 }
        #[repr(C)] pub struct OldOption { flag: u8, value: i32 }
        #[repr(C)] pub struct OldString { ptr: *mut u8, len: usize, cap: usize }
        #[repr(C)] pub struct OldStr { ptr: *const u8, len: usize }
        #[repr(C)] pub struct OldBoxResult { flag: u8, ok: *mut std::ffi::c_void, err: i32 }
        #[julia] #[repr(C)] pub struct LegacyOwner571 { value: i32 }
        #[julia] impl LegacyOwner571 {
            #[julia] pub fn new(value: i32) -> Self { Self { value } }
            #[julia] pub fn get(&self) -> i32 { self.value }
            #[julia] pub fn copy_owner(&self, _x: Option<&Self>) -> Self { Self { value: self.value } }
            #[julia] pub fn duplicate(&self, _x: Option<&Self>) -> Result<Self, i32> { Ok(Self { value: self.value }) }
        }
        #[julia] #[repr(C)] pub struct LegacyOptionalCtor571 { value: i32 }
        #[julia] impl LegacyOptionalCtor571 {
            #[julia] pub fn from_owner(_x: Option<&LegacyOwner571>) -> Self { Self { value: 0 } }
        }
        #[julia] #[repr(C)] pub struct LegacyOptionalFallible571 { value: i32 }
        #[julia] impl LegacyOptionalFallible571 {
            #[julia] pub fn from_owner(_x: Option<&LegacyOwner571>) -> Result<Self, i32> { Ok(Self { value: 0 }) }
        }
        #[julia] pub fn legacy_entries571() -> u32 { ENTRIES.load(Ordering::SeqCst) }
        #[julia] pub fn legacy_required571(owner: &LegacyOwner571) -> i32 { owner.value }
        #[julia] pub fn legacy_callback571(_owner: Option<&LegacyOwner571>, _callback: extern "C" fn() -> i32) -> i32 { 0 }
        #[no_mangle] pub extern "C" fn rustcall_legacy_entries571() -> u32 { legacy_entries571() }
        #[no_mangle] pub extern "C" fn rustcall_legacy_required571(owner: *const LegacyOwner571) -> i32 { unsafe { (*owner).value } }
        #[no_mangle] pub extern "C" fn rustcall_LegacyOwner571_new(value: i32) -> *mut LegacyOwner571 { Box::into_raw(Box::new(LegacyOwner571 { value })) }
        #[no_mangle] pub extern "C" fn rustcall_LegacyOwner571_get(owner: *const LegacyOwner571) -> i32 { unsafe { (*owner).value } }
        #[no_mangle] pub extern "C" fn LegacyOwner571_free(owner: *mut LegacyOwner571) { if !owner.is_null() { unsafe { drop(Box::from_raw(owner)); } } }
        #[no_mangle] pub extern "C" fn LegacyOptionalCtor571_free(owner: *mut LegacyOptionalCtor571) { if !owner.is_null() { unsafe { drop(Box::from_raw(owner)); } } }
        #[no_mangle] pub extern "C" fn LegacyOptionalFallible571_free(owner: *mut LegacyOptionalFallible571) { if !owner.is_null() { unsafe { drop(Box::from_raw(owner)); } } }
        #[no_mangle] pub extern "C" fn rustcall_legacy_callback571(_: *const LegacyOwner571, _: extern "C" fn() -> i32) -> i32 { entered(); 0 }
        #[no_mangle] pub extern "C" fn rustcall_LegacyOwner571_copy_owner(_: *const LegacyOwner571, _: *const LegacyOwner571) -> *mut LegacyOwner571 { entered(); Box::into_raw(Box::new(LegacyOwner571 { value: 0 })) }
        #[no_mangle] pub extern "C" fn rustcall_LegacyOwner571_duplicate(_: *const LegacyOwner571, _: *const LegacyOwner571) -> OldBoxResult { entered(); OldBoxResult { flag: 1, ok: Box::into_raw(Box::new(LegacyOwner571 { value: 0 })) as *mut _, err: 0 } }
        #[no_mangle] pub extern "C" fn rustcall_LegacyOptionalCtor571_from_owner(_: *const LegacyOwner571) -> *mut LegacyOptionalCtor571 { entered(); Box::into_raw(Box::new(LegacyOptionalCtor571 { value: 0 })) }
        #[no_mangle] pub extern "C" fn rustcall_LegacyOptionalFallible571_from_owner(_: *const LegacyOwner571) -> OldBoxResult { entered(); OldBoxResult { flag: 1, ok: Box::into_raw(Box::new(LegacyOptionalFallible571 { value: 0 })) as *mut _, err: 0 } }
        #[no_mangle] pub extern "C" fn rustcall_LegacyOwner571_duplicate_boxed_result_v1() {}
        #[no_mangle] pub extern "C" fn rustcall_LegacyOptionalFallible571_from_owner_boxed_result_v1() {}
        """
    shapes = (
        ("unit", "()", "{}", "()", "()"),
        ("plain", "i32", "0", "i32", "0"),
        (
            "result",
            "Result<i32, i32>",
            "Ok(0)",
            "OldResult",
            "OldResult { flag: 1, ok: 0, err: 0 }",
        ),
        ("option", "Option<i32>", "None", "OldOption", "OldOption { flag: 0, value: 0 }"),
        (
            "text",
            "String",
            "String::new()",
            "OldString",
            "OldString { ptr: std::ptr::null_mut(), len: 0, cap: 0 }",
        ),
        (
            "label",
            "&'static str",
            "\"\"",
            "OldStr",
            "OldStr { ptr: std::ptr::null(), len: 0 }",
        ),
    )
    for (name, surface, body, slot, sentinel) in shapes
        definitions *= "\n#[julia] pub fn legacy_$(name)571(_x: Option<&LegacyOwner571>) -> $surface { $body }\n"
        definitions *= "#[no_mangle] pub extern \"C\" fn rustcall_legacy_$(name)571(_: *const LegacyOwner571) -> $slot { entered(); $sentinel }\n"
        for (prefix, receiver, shim_receiver) in
            (("static_", "", ""), ("method_", "&self, ", "_: *const LegacyOwner571, "))
            method = prefix * name
            definitions *= "#[julia] impl LegacyOwner571 { #[julia] pub fn $method($(receiver)_x: Option<&Self>) -> $surface { $body } }\n"
            definitions *= "#[no_mangle] pub extern \"C\" fn rustcall_LegacyOwner571_$(method)($(shim_receiver)_: *const LegacyOwner571) -> $slot { entered(); $sentinel }\n"
        end
        if name == "text"
            for stem in (
                "legacy_$(name)571",
                "LegacyOwner571_static_$name",
                "LegacyOwner571_method_$name",
            )
                definitions *= "#[no_mangle] pub extern \"C\" fn $(stem)_free_rust_string(_: *mut u8, _: usize, _: usize) {}\n"
            end
        end
    end
    return definitions
end

function _reject_legacy_optional571(call)
    owner = call(:LegacyOwner571, Int32(7))
    @test call(:legacy_required571, owner) == 7  # slice-free legacy API stays usable
    @test call(:get, owner) == 7
    function reject(fn)
        err = try
            fn()
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("incompatible optional borrowed-owner ABI", sprint(showerror, err))
    end
    try
        for present in (nothing, owner)
            for name in ("unit", "plain", "result", "option", "text", "label")
                reject(() -> call(Symbol("legacy_$(name)571"), present))
                T = call(:type_only_LegacyOwner571)
                reject(() -> call(Symbol("static_$name"), T, present))
                reject(() -> call(Symbol("method_$name"), owner, present))
            end
            reject(() -> call(:copy_owner, owner, present))
            reject(() -> call(:duplicate, owner, present))
            reject(() -> call(:LegacyOptionalCtor571, present))
            reject(() -> call(:LegacyOptionalFallible571, present))
            reject(() -> call(:legacy_callback571, present, () -> Int32(0)))
            @test isempty(RustCall._callback_frames())
        end
        @test call(:legacy_entries571) == 0
    finally
        finalize(owner)
    end
    # A markerless producer makes this a safe liveness regression: if the
    # receiver check regresses, marker rejection still prevents any FFI call.
    for name in ("unit", "plain", "result", "option", "text", "label")
        @test_throws RustCall.RustError call(Symbol("method_$name"), owner, nothing)
    end
    @test_throws RustCall.RustError call(:copy_owner, owner, nothing)
    @test_throws RustCall.RustError call(:duplicate, owner, nothing)
    @test call(:legacy_entries571) == 0
end

@testset "optional owner producer markers reject legacy ABI before every call (#571)" begin
    mktempdir() do root
        macro_dir = joinpath(root, "legacy_macro")
        crate = joinpath(root, "crate")
        mkpath(joinpath(macro_dir, "src"))
        mkpath(joinpath(crate, "src"))
        write(
            joinpath(macro_dir, "Cargo.toml"),
            """
[package]
name = "legacy_optional_macro"
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
name = "legacy_optional571"
version = "0.1.0"
edition = "2021"
[lib]
crate-type = ["cdylib"]
[dependencies]
legacy_optional_macro = { path = "../legacy_macro" }
""",
        )
        source = _legacy_optional571_source()
        write(joinpath(crate, "src", "lib.rs"), source)
        binding = @rust_crate crate
        direct = getfield(binding, :module_ref)
        output = joinpath(root, "WrittenLegacyOptional571.jl")
        RustCall.write_bindings_to_file(
            crate,
            output;
            output_module_name = "WrittenLegacyOptional571",
        )
        sandbox = Module(:LegacyOptionalSandbox571)
        Base.include(sandbox, output)
        written = Base.invokelatest(getfield, sandbox, :WrittenLegacyOptional571)
        modules = (direct, written)
        try
            for mod in modules
                direct_call =
                    (name, args...) ->
                        name === :type_only_LegacyOwner571 ?
                        Base.invokelatest(getfield, mod, :LegacyOwner571) :
                        Base.invokelatest(Base.invokelatest(getfield, mod, name), args...)
                _reject_legacy_optional571(direct_call)
            end
            # Feed the same scanned signatures to the inline emitters, bound
            # to the already loaded legacy image. This exercises the real
            # inline wrappers without compiling or calling a native Option ABI.
            inline = Module(:LegacyInlineOptional571)
            Core.eval(inline, :(using RustCall))
            Core.eval(
                inline,
                :(using RustCall:
                    _call_rust_constructor,
                    _call_rust_method,
                    _call_rust_owned_string,
                    _call_rust_borrowed_string),
            )
            manifest = RustCall.extract_manifest(source; mode = "inline")
            sigs = RustCall.manifest_function_signatures(manifest)
            structs = RustCall.manifest_struct_infos(manifest)
            definitions, functions = RustCall._inline_wrapper_exprs(sigs, structs)
            body = Expr(:block, definitions..., functions)
            Core.eval(inline, :(macro legacy_optional_definitions571()
                ;$(QuoteNode(body));
            end))
            Core.eval(
                inline,
                Expr(
                    :macrocall,
                    Symbol("@legacy_optional_definitions571"),
                    LineNumberNode(1),
                ),
            )
            lib = Base.invokelatest(getfield, direct, :_LIB_NAME)
            compiler = RustCall.get_default_compiler()
            symbols = [f.symbol for f in sigs]
            append!(
                symbols,
                [
                    RustCall.method_wrapper_symbol(owner.ffi_name, method) for
                    owner in structs for method in owner.methods
                ],
            )
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
                symbols,
            )
            inline_call =
                (name, args...) ->
                    name === :type_only_LegacyOwner571 ?
                    Base.invokelatest(getfield, inline, :LegacyOwner571) :
                    Base.invokelatest(Base.invokelatest(getfield, inline, name), args...)
            _reject_legacy_optional571(inline_call)
            cache = RustCall.CallTargetCache()
            @test_throws ErrorException RustCall.cached_call_target(
                cache,
                inline,
                "rustcall_legacy_plain571";
                optional_owner_args = true,
            )
            @test RustCall.cached_target_hit(cache) === nothing
            RustCall.cached_call_target(cache, inline, "rustcall_legacy_plain571")
            @test_throws ErrorException RustCall.cached_call_target(
                cache,
                inline,
                "rustcall_legacy_plain571";
                optional_owner_args = true,
            )
            @test inline_call(:legacy_entries571) == 0
        finally
            for mod in modules
                lib = Base.invokelatest(getfield, mod, :_LIB_NAME)
                haskey(RustCall.RUST_LIBRARIES, lib) &&
                    RustCall.unload_library(lib; close = true)
            end
        end
    end
end
