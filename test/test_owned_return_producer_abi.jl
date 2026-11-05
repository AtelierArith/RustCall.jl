using Test, RustCall

const OLD_OWNED572_SOURCE = raw"""
use legacy_owned_macro::julia;
use std::sync::atomic::{AtomicU32, Ordering};
static ENTRIES: AtomicU32 = AtomicU32::new(0);
fn entered() { ENTRIES.fetch_add(1, Ordering::SeqCst); }
#[repr(C)] pub struct BoxResult572 { flag: u8, value: *mut std::ffi::c_void, error: i32 }
#[julia] pub fn old_entries572() -> u32 { ENTRIES.load(Ordering::SeqCst) }
#[julia] pub struct OldOwner572 { n: i32 }
#[julia] impl OldOwner572 {
    #[julia] pub fn new(n: i32) -> Self { Self { n } }
    #[julia] pub fn get(&self) -> i32 { self.n }
    #[julia] #[rustcall_owned_return(OldFactor572)]
    pub fn direct(&self) -> OldFactor572 { OldFactor572 { n: self.n } }
    #[julia] #[rustcall_owned_return(OldFactor572)]
    pub fn checked(&self) -> Result<OldFactor572, i32> { Ok(OldFactor572 { n: self.n }) }
    #[julia] #[rustcall_owned_return(OldOwner572)]
    pub fn copy_owner(&self) -> Self { Self { n: self.n } }
    #[julia] #[rustcall_owned_return(OldOwner572)]
    pub fn result_self(&self) -> Result<Self, i32> { Ok(Self { n: self.n }) }
    #[julia] #[rustcall_owned_return(OldFactor572)]
    pub fn static_factor(n: i32) -> OldFactor572 { OldFactor572 { n } }
}
#[julia] pub struct OldFactor572 { n: i32 }
#[julia] impl OldFactor572 {
    #[julia] #[rustcall_owned_return(OldFactor572)]
    pub fn from_owner(owner: &OldOwner572) -> Self { Self { n: owner.n } }
}
#[julia] pub struct OldFallible572 { n: i32 }
#[julia] impl OldFallible572 {
    #[julia] #[rustcall_owned_return(OldFallible572)]
    pub fn from_owner(owner: &OldOwner572) -> Result<Self, i32> { Ok(Self { n: owner.n }) }
}
#[julia] #[rustcall_owned_return(OldFactor572)]
pub fn old_direct572(n: i32) -> OldFactor572 { OldFactor572 { n } }
#[julia] #[rustcall_owned_return(OldFactor572)]
pub fn old_result572(n: i32) -> Result<OldFactor572, i32> { Ok(OldFactor572 { n }) }
#[julia] #[rustcall_owned_return(OldFactor572)]
pub fn old_callback572(_: extern "C" fn() -> i32) -> OldFactor572 { OldFactor572 { n: 0 } }

// Explicit pointer shims make a failed regression safe; ENTRIES proves no
// new owned-return wrapper may enter this producer without its marker.
#[no_mangle] pub extern "C" fn rustcall_old_entries572() -> u32 { old_entries572() }
#[no_mangle] pub extern "C" fn rustcall_OldOwner572_new(n: i32) -> *mut OldOwner572 { Box::into_raw(Box::new(OldOwner572 { n })) }
#[no_mangle] pub extern "C" fn rustcall_OldOwner572_get(owner: *const OldOwner572) -> i32 { unsafe { (*owner).n } }
#[no_mangle] pub extern "C" fn OldOwner572_free(p: *mut OldOwner572) { if !p.is_null() { unsafe { drop(Box::from_raw(p)); } } }
#[no_mangle] pub extern "C" fn OldFactor572_free(p: *mut OldFactor572) { if !p.is_null() { unsafe { drop(Box::from_raw(p)); } } }
#[no_mangle] pub extern "C" fn OldFallible572_free(p: *mut OldFallible572) { if !p.is_null() { unsafe { drop(Box::from_raw(p)); } } }
#[no_mangle] pub extern "C" fn rustcall_old_direct572(_: i32) -> *mut OldFactor572 { entered(); Box::into_raw(Box::new(OldFactor572 { n: 0 })) }
#[no_mangle] pub extern "C" fn rustcall_old_result572(_: i32) -> BoxResult572 { entered(); BoxResult572 { flag: 1, value: Box::into_raw(Box::new(OldFactor572 { n: 0 })) as *mut _, error: 0 } }
#[no_mangle] pub extern "C" fn rustcall_old_callback572(_: extern "C" fn() -> i32) -> *mut OldFactor572 { entered(); Box::into_raw(Box::new(OldFactor572 { n: 0 })) }
#[no_mangle] pub extern "C" fn rustcall_OldOwner572_direct(_: *const OldOwner572) -> *mut OldFactor572 { entered(); Box::into_raw(Box::new(OldFactor572 { n: 0 })) }
#[no_mangle] pub extern "C" fn rustcall_OldOwner572_checked(_: *const OldOwner572) -> BoxResult572 { entered(); BoxResult572 { flag: 1, value: Box::into_raw(Box::new(OldFactor572 { n: 0 })) as *mut _, error: 0 } }
#[no_mangle] pub extern "C" fn rustcall_OldOwner572_copy_owner(_: *const OldOwner572) -> *mut OldOwner572 { entered(); Box::into_raw(Box::new(OldOwner572 { n: 0 })) }
#[no_mangle] pub extern "C" fn rustcall_OldOwner572_result_self(_: *const OldOwner572) -> BoxResult572 { entered(); BoxResult572 { flag: 1, value: Box::into_raw(Box::new(OldOwner572 { n: 0 })) as *mut _, error: 0 } }
#[no_mangle] pub extern "C" fn rustcall_OldOwner572_static_factor(_: i32) -> *mut OldFactor572 { entered(); Box::into_raw(Box::new(OldFactor572 { n: 0 })) }
#[no_mangle] pub extern "C" fn rustcall_OldFactor572_from_owner(_: *const OldOwner572) -> *mut OldFactor572 { entered(); Box::into_raw(Box::new(OldFactor572 { n: 0 })) }
#[no_mangle] pub extern "C" fn rustcall_OldFallible572_from_owner(_: *const OldOwner572) -> BoxResult572 { entered(); BoxResult572 { flag: 1, value: Box::into_raw(Box::new(OldFallible572 { n: 0 })) as *mut _, error: 0 } }
#[no_mangle] pub extern "C" fn rustcall_old_result572_boxed_result_v1() {}
#[no_mangle] pub extern "C" fn rustcall_OldOwner572_checked_boxed_result_v1() {}
#[no_mangle] pub extern "C" fn rustcall_OldOwner572_result_self_boxed_result_v1() {}
#[no_mangle] pub extern "C" fn rustcall_OldFallible572_from_owner_boxed_result_v1() {}
#[julia] #[rustcall_owned_return(OldFactor572)]
pub fn old_mixed_no_slice572(_owner: Option<&OldOwner572>, _xs: &[f64]) -> OldFactor572 { OldFactor572 { n: 0 } }
#[no_mangle] pub extern "C" fn rustcall_old_mixed_no_slice572(_: *const OldOwner572, _: *const f64, _: usize) -> *mut OldFactor572 { entered(); std::ptr::null_mut() }
#[no_mangle] pub extern "C" fn rustcall_old_mixed_no_slice572_optional_owner_ptr_v1() {}
#[no_mangle] pub extern "C" fn rustcall_old_mixed_no_slice572_owned_return_v1() {}
#[julia] #[rustcall_owned_return(OldFactor572)]
pub fn old_mixed_no_optional572(_owner: Option<&OldOwner572>, _xs: &[f64]) -> OldFactor572 { OldFactor572 { n: 0 } }
#[no_mangle] pub extern "C" fn rustcall_old_mixed_no_optional572(_: *const OldOwner572, _: *const f64, _: usize) -> *mut OldFactor572 { entered(); std::ptr::null_mut() }
#[no_mangle] pub extern "C" fn rustcall_old_mixed_no_optional572_slice_ptr_len_v1() {}
#[no_mangle] pub extern "C" fn rustcall_old_mixed_no_optional572_owned_return_v1() {}
#[julia] #[rustcall_owned_return(OldFactor572)]
pub fn old_mixed_no_owned572(_owner: Option<&OldOwner572>, _xs: &[f64]) -> OldFactor572 { OldFactor572 { n: 0 } }
#[no_mangle] pub extern "C" fn rustcall_old_mixed_no_owned572(_: *const OldOwner572, _: *const f64, _: usize) -> *mut OldFactor572 { entered(); std::ptr::null_mut() }
#[no_mangle] pub extern "C" fn rustcall_old_mixed_no_owned572_slice_ptr_len_v1() {}
#[no_mangle] pub extern "C" fn rustcall_old_mixed_no_owned572_optional_owner_ptr_v1() {}
"""

function _old_owned572_checks(call, owner_type)
    owner = call(:OldOwner572, Int32(7))
    @test call(:get, owner) == 7  # legacy no-explicit-owned-return APIs remain valid
    try
        invocations = (
            () -> call(:old_direct572, Int32(1)),
            () -> call(:old_result572, Int32(1)),
            () -> call(:direct, owner),
            () -> call(:checked, owner),
            () -> call(:copy_owner, owner),
            () -> call(:result_self, owner),
            () -> call(:static_factor, owner_type, Int32(1)),
            () -> call(:OldFactor572, owner),
            () -> call(:OldFallible572, owner),
            () -> call(:old_callback572, () -> Int32(0)),
        )
        for invocation in invocations
            err = try
                value = invocation()
                hasfield(typeof(value), :ptr) && finalize(value)
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("incompatible explicit owned-return ABI", sprint(showerror, err))
            @test isempty(RustCall._callback_frames())
        end
        for constructor in (:OldFactor572, :OldFallible572)
            @test_throws ArgumentError call(constructor, C_NULL)
            @test_throws ArgumentError call(constructor, owner.ptr)
        end
        for (name, diagnostic) in (
            (:old_mixed_no_slice572, "incompatible numeric slice argument ABI"),
            (:old_mixed_no_optional572, "incompatible optional borrowed-owner ABI"),
            (:old_mixed_no_owned572, "incompatible explicit owned-return ABI"),
        )
            for optional in (nothing, owner)
                error = try
                    call(name, optional, [1.0])
                    nothing
                catch exception
                    exception
                end
                @test error isa ErrorException
                @test occursin(diagnostic, sprint(showerror, error))
                @test call(:old_entries572) == 0
            end
        end
        @test call(:old_entries572) == 0
    finally
        finalize(owner)
    end
end

@testset "explicit owned-return producer marker protects every Julia emitter (#572)" begin
    mktempdir() do root
        macro_dir, crate = joinpath(root, "macro"), joinpath(root, "crate")
        mkpath(joinpath(macro_dir, "src"))
        mkpath(joinpath(crate, "src"))
        write(
            joinpath(macro_dir, "Cargo.toml"),
            """
[package]
name = "legacy_owned_macro"
version = "0.1.0"
edition = "2021"
[lib]
proc-macro = true
""",
        )
        write(
            joinpath(macro_dir, "src", "lib.rs"),
            """
use proc_macro::{TokenStream, TokenTree, Group, Delimiter};
fn strip_owned(input: TokenStream) -> TokenStream {
    let mut trees = input.into_iter().peekable();
    let mut output = TokenStream::new();
    while let Some(tree) = trees.next() {
        if matches!(&tree, TokenTree::Punct(p) if p.as_char() == '#') {
            let owned = matches!(trees.peek(), Some(TokenTree::Group(g))
                if g.delimiter() == Delimiter::Bracket &&
                matches!(g.stream().into_iter().next(), Some(TokenTree::Ident(i)) if i.to_string() == "rustcall_owned_return"));
            if owned { trees.next(); continue; }
        }
        let tree = if let TokenTree::Group(group) = tree {
            let mut replacement = Group::new(group.delimiter(), strip_owned(group.stream()));
            replacement.set_span(group.span());
            TokenTree::Group(replacement)
        } else { tree };
        output.extend([tree]);
    }
    output
}
#[proc_macro_attribute]
pub fn julia(_: TokenStream, input: TokenStream) -> TokenStream { strip_owned(input) }

""",
        )
        write(
            joinpath(crate, "Cargo.toml"),
            """
[package]
name = "legacy_owned_returns572"
version = "0.1.0"
edition = "2021"
[lib]
crate-type = ["cdylib"]
[dependencies]
legacy_owned_macro = { path = "../macro" }
""",
        )
        write(joinpath(crate, "src", "lib.rs"), OLD_OWNED572_SOURCE)
        bindings = @rust_crate crate
        direct = getfield(bindings, :module_ref)
        output = joinpath(root, "WrittenOldOwned572.jl")
        RustCall.write_bindings_to_file(
            crate,
            output;
            output_module_name = "WrittenOldOwned572",
        )
        sandbox = Module(:WrittenOldOwnedSandbox572)
        Base.include(sandbox, output)
        written = Base.invokelatest(getfield, sandbox, :WrittenOldOwned572)
        modules = (direct, written)
        try
            for mod in modules
                call =
                    (name, args...) ->
                        Base.invokelatest(Base.invokelatest(getfield, mod, name), args...)
                _old_owned572_checks(call, Base.invokelatest(getfield, mod, :OldOwner572))
            end
            inline = Module(:OldOwnedInline572)
            Core.eval(inline, :(using RustCall))
            Core.eval(
                inline,
                :(using RustCall:
                    _call_rust_constructor,
                    _call_rust_method,
                    _call_rust_owned_string,
                    _call_rust_borrowed_string),
            )
            manifest = RustCall.extract_manifest(OLD_OWNED572_SOURCE; mode = "inline")
            functions = RustCall.manifest_function_signatures(manifest)
            owners = RustCall.manifest_struct_infos(manifest)
            definitions, wrappers = RustCall._inline_wrapper_exprs(functions, owners)
            body = Expr(:block, definitions..., wrappers)
            Core.eval(inline, :(macro old_owned572_definitions()
                ;$(QuoteNode(body));
            end))
            Core.eval(
                inline,
                Expr(:macrocall, Symbol("@old_owned572_definitions"), LineNumberNode(1)),
            )
            compiler = RustCall.get_default_compiler()
            symbols = [f.symbol for f in functions]
            append!(
                symbols,
                [
                    RustCall.method_wrapper_symbol(owner.ffi_name, method) for
                    owner in owners for method in owner.methods
                ],
            )
            lib = Base.invokelatest(getfield, direct, :_LIB_NAME)
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
            call =
                (name, args...) ->
                    Base.invokelatest(Base.invokelatest(getfield, inline, name), args...)
            _old_owned572_checks(call, Base.invokelatest(getfield, inline, :OldOwner572))
            # Warm both direct and Result factory caches on a producer that
            # explicitly asserts the new ABI, then replace that image with the
            # original markerless one. All calls must validate the replacement.
            marked_dir = joinpath(root, "marked")
            mkpath(joinpath(marked_dir, "src"))
            write(
                joinpath(marked_dir, "Cargo.toml"),
                read(joinpath(crate, "Cargo.toml"), String),
            )
            marked_source =
                OLD_OWNED572_SOURCE *
                "\n#[no_mangle] pub extern \"C\" fn rustcall_old_direct572_owned_return_v1() {}\n" *
                "#[no_mangle] pub extern \"C\" fn rustcall_old_result572_owned_return_v1() {}\n"
            write(joinpath(marked_dir, "src", "lib.rs"), marked_source)
            marked_binding = @rust_crate marked_dir
            marked = getfield(marked_binding, :module_ref)
            libname(mod) = Base.invokelatest(getfield, mod, :_LIB_NAME)
            original_libs = unique(libname.(modules))
            saved = [string(lib, "_saved_markerless572") for lib in original_libs]
            original_counter = RustCall.resolve_call_target(
                first(original_libs),
                "rustcall_old_entries572";
                fallback = false,
            )
            try
                for (lib, save) in zip(original_libs, saved)
                    @test RustCall.alias_artifact!(
                        RustCall.crate_direct_policy(),
                        lib,
                        save,
                    )
                    @test RustCall.alias_artifact!(
                        RustCall.crate_direct_policy(),
                        libname(marked),
                        lib,
                    )
                end
                for mod in (modules..., inline)
                    invoke =
                        (name, args...) -> Base.invokelatest(
                            Base.invokelatest(getfield, mod, name),
                            args...,
                        )
                    for _ = 1:2
                        object = invoke(:old_direct572, Int32(1))
                        result = RustCall.unwrap(invoke(:old_result572, Int32(1)))
                        @test nameof(typeof(object)) == :OldFactor572
                        @test typeof(object) === typeof(result)
                        foreach(finalize, (object, result))
                    end
                end
                for (lib, save) in zip(original_libs, saved)
                    @test RustCall.alias_artifact!(
                        RustCall.crate_direct_policy(),
                        save,
                        lib,
                    )
                end
                for mod in (modules..., inline)
                    invoke =
                        (name, args...) -> Base.invokelatest(
                            Base.invokelatest(getfield, mod, name),
                            args...,
                        )
                    @test_throws ErrorException invoke(:old_direct572, Int32(1))
                    @test_throws ErrorException invoke(:old_result572, Int32(1))
                    @test isempty(RustCall._callback_frames())
                end
                @test RustCall.call_rust_function(original_counter.func_ptr, UInt32) == 0
                missing_dir = joinpath(root, "missing_destructor")
                mkpath(joinpath(missing_dir, "src"))
                write(
                    joinpath(missing_dir, "Cargo.toml"),
                    read(joinpath(crate, "Cargo.toml"), String),
                )
                missing_source = replace(
                    marked_source,
                    "#[no_mangle] pub extern \"C\" fn OldFactor572_free" => "pub extern \"C\" fn OldFactor572_free",
                )
                write(joinpath(missing_dir, "src", "lib.rs"), missing_source)
                missing_binding = @rust_crate missing_dir
                missing = getfield(missing_binding, :module_ref)
                missing_output = joinpath(root, "MissingDestructor572.jl")
                RustCall.write_bindings_to_file(
                    missing_dir,
                    missing_output;
                    output_module_name = "MissingDestructor572",
                )
                missing_scope = Module(:MissingDestructorSandbox572)
                Base.include(missing_scope, missing_output)
                missing_written =
                    Base.invokelatest(getfield, missing_scope, :MissingDestructor572)
                try
                    for mod in (missing, missing_written)
                        invoke =
                            (name, args...) -> Base.invokelatest(
                                Base.invokelatest(getfield, mod, name),
                                args...,
                            )
                        @test_throws ErrorException invoke(:old_direct572, Int32(1))
                        cache_name =
                            RustCall._target_cache_name(:fn, "rustcall_old_direct572")
                        cache = Base.invokelatest(getfield, mod, cache_name)
                        @test (@atomic :acquire cache.entry) === nothing
                        @test invoke(:old_entries572) == 0
                    end
                    for lib in original_libs
                        @test RustCall.alias_artifact!(
                            RustCall.crate_direct_policy(),
                            libname(missing),
                            lib,
                        )
                    end
                    inline_call =
                        (name, args...) -> Base.invokelatest(
                            Base.invokelatest(getfield, inline, name),
                            args...,
                        )
                    @test_throws ErrorException inline_call(:old_direct572, Int32(1))
                    @test inline_call(:old_entries572) == 0
                finally
                    for mod in (missing, missing_written)
                        lib = libname(mod)
                        haskey(RustCall.RUST_LIBRARIES, lib) &&
                            RustCall.unload_library(lib; close = true)
                    end
                end
            finally
                for lib in (saved..., libname(marked))
                    haskey(RustCall.RUST_LIBRARIES, lib) &&
                        RustCall.unload_library(lib; close = true)
                    RustCall.close_retired_handles!(RustCall.retired_handles(lib))
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
