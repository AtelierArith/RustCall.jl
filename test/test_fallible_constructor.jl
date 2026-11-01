using RustCall, Test

rust"""
#[julia]
pub struct FallibleInline559 { value: i32 }
#[julia]
impl FallibleInline559 {
    pub fn new(value: i32) -> Result<Self, String> {
        if value == -2 { panic!("constructor panic") }
        if value < 0 { Err("negative".to_owned()) } else { Ok(Self { value }) }
    }
    pub fn value(&self) -> i32 { self.value }
}
#[julia]
pub struct FallibleCode559 { value: i32 }
#[julia]
impl FallibleCode559 {
    pub fn new(value: i32) -> Result<Self, i32> {
        if value < 0 { Err(value) } else { Ok(Self { value }) }
    }
}
"""

@testset "fallible constructor inline" begin
    good = FallibleInline559(Int32(3))
    @test RustCall.is_ok(good)
    item = RustCall.unwrap(good)
    @test value(item) == 3
    finalize(item)
    bad = FallibleInline559(Int32(-1))
    @test RustCall.is_err(bad)
    @test bad.value == "negative"
    @test_throws RustCall.RustPanicError FallibleInline559(Int32(-2))
    code_error = FallibleCode559(Int32(-7))
    @test RustCall.is_err(code_error)
    @test code_error.value == Int32(-7)
    code_ok = FallibleCode559(Int32(5))
    @test RustCall.is_ok(code_ok)
    finalize(RustCall.unwrap(code_ok))
end

@testset "fallible constructor crate and written bindings" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "src"))
        runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
        write(joinpath(dir, "Cargo.toml"), """
            [package]
            name = "fallible_559"
            version = "0.1.0"
            edition = "2021"
            [lib]
            crate-type = ["cdylib"]
            [dependencies]
            rustcall_julia_macros = { path = "$runtime" }
            """)
        write(joinpath(dir, "src", "lib.rs"), """
            use rustcall_julia_macros::julia;
            use std::sync::atomic::{AtomicU32, Ordering};
            static DROPS: AtomicU32 = AtomicU32::new(0);
            #[julia]
            pub fn drops() -> u32 { DROPS.load(Ordering::SeqCst) }
            #[julia]
            pub struct Fallible { value: i32 }
            impl Drop for Fallible { fn drop(&mut self) { DROPS.fetch_add(1, Ordering::SeqCst); } }
            #[julia]
            pub struct FallibleCode { value: i32 }
            #[julia]
            impl FallibleCode {
                #[julia]
                pub fn new(value: i32) -> Result<Self, i32> {
                    if value < 0 { Err(value) } else { Ok(Self { value }) }
                }
            }
            #[julia]
            pub mod nested {
                use rustcall_julia_macros::julia;
                #[julia]
                pub struct Inner { value: i32 }
                #[julia]
                impl Inner {
                    #[julia]
                    pub fn new(value: i32) -> Result<Self, String> {
                        if value < 0 { Err("nested negative".to_owned()) } else { Ok(Self { value }) }
                    }
                    #[julia]
                    pub fn value(&self) -> i32 { self.value }
                }
            }
            #[julia]
            impl Fallible {
                #[julia]
                pub fn new(value: i32) -> Result<Self, String> {
                    if value == -2 { panic!("panic from constructor"); }
                    if value < 0 { Err("negative".to_owned()) } else { Ok(Self { value }) }
                }
                #[julia]
                pub fn value(&self) -> i32 { self.value }
            }
            """)
        bindings = @rust_crate dir
        output = joinpath(dir, "Written.jl")
        RustCall.write_bindings_to_file(dir, output; output_module_name="WrittenFallible559")
        sandbox = Module(:FallibleSandbox559)
        Base.include(sandbox, output)
        written = Base.invokelatest(getfield, sandbox, :WrittenFallible559)
        modules = (getfield(bindings, :module_ref), written)
        try
        for module_ in modules
            nested_mod = Base.invokelatest(getfield, module_, :nested)
            inner = Base.invokelatest(getfield, nested_mod, :Inner)
            nested_result = Base.invokelatest(inner, Int32(9))
            @test RustCall.is_ok(nested_result)
            nested_value = RustCall.unwrap(nested_result)
            @test Base.invokelatest(Base.invokelatest(getfield, nested_mod, :value), nested_value) == 9
            finalize(nested_value)
            nested_error = Base.invokelatest(inner, Int32(-1))
            @test RustCall.is_err(nested_error)
            @test nested_error.value == "nested negative"
            T = Base.invokelatest(getfield, module_, :Fallible)
            good = Base.invokelatest(T, Int32(3))
            @test RustCall.is_ok(good)
            item = RustCall.unwrap(good)
            @test Base.invokelatest(Base.invokelatest(getfield, module_, :value), item) == 3
            before = Base.invokelatest(Base.invokelatest(getfield, module_, :drops))
            finalize(item)
            @test Base.invokelatest(Base.invokelatest(getfield, module_, :drops)) == before + 1
            bad = Base.invokelatest(T, Int32(-1))
            @test RustCall.is_err(bad)
            @test bad.value == "negative"
            @test_throws RustCall.RustPanicError Base.invokelatest(T, Int32(-2))
            C = Base.invokelatest(getfield, module_, :FallibleCode)
            code_err = Base.invokelatest(C, Int32(-4))
            @test RustCall.is_err(code_err)
            @test code_err.value == -4
            code_ok = Base.invokelatest(C, Int32(4))
            @test RustCall.is_ok(code_ok)
            finalize(RustCall.unwrap(code_ok))
        end
        # A reload must never attach a successful allocation to the next
        # generation's destructor or liveness flag.
        state = RustCall.enable_hot_reload_for_crate(bindings; poll=true, interval=10.0)
        name = Base.invokelatest(getfield, first(modules), :_LIB_NAME)
        try
            mod = first(modules)
            T = Base.invokelatest(getfield, mod, :Fallible)
            old = RustCall.unwrap(Base.invokelatest(T, Int32(10)))
            oldgen = Base.invokelatest(getfield, mod, :_LIB_GEN)[]
            free_symbol = RustCall.ffi_struct_free_symbol("Fallible")
            @test old.alive === oldgen.alive
            @test old.free_ptr == RustCall.Libdl.dlsym(oldgen.handle, free_symbol)
            source = joinpath(dir, "src", "lib.rs")
            write(source, read(source, String) * "\n// generation 2\n")
            @test RustCall.trigger_reload(name)
            fresh = RustCall.unwrap(Base.invokelatest(T, Int32(11)))
            newgen = Base.invokelatest(getfield, mod, :_LIB_GEN)[]
            @test fresh.alive === newgen.alive
            @test fresh.free_ptr == RustCall.Libdl.dlsym(newgen.handle, free_symbol)
            @test oldgen.alive !== newgen.alive
            finalize(old)
            finalize(fresh)
        finally
            RustCall.disable_hot_reload(name)
        end
        finally
            for module_ in modules
                try
                    RustCall.unload_library(Base.invokelatest(getfield, module_, :_LIB_NAME); close=true)
                catch
                    # Windows cannot remove a loaded DLL; cleanup is best effort.
                end
            end
        end
    end
end

@testset "fallible constructor refuses an old producer ABI" begin
    mktempdir() do dir
        old_macro = joinpath(dir, "old_macro")
        crate = joinpath(dir, "crate")
        mkpath(joinpath(old_macro, "src"))
        mkpath(joinpath(crate, "src"))
        write(joinpath(old_macro, "Cargo.toml"), """
            [package]
            name = "legacy_julia_macro"
            version = "0.1.0"
            edition = "2021"
            [lib]
            proc-macro = true
            """)
        write(joinpath(old_macro, "src", "lib.rs"), """
            use proc_macro::TokenStream;
            #[proc_macro_attribute]
            pub fn julia(_: TokenStream, input: TokenStream) -> TokenStream { input }
            """)
        write(joinpath(crate, "Cargo.toml"), """
            [package]
            name = "legacy_constructor_abi"
            version = "0.1.0"
            edition = "2021"
            [lib]
            crate-type = ["cdylib"]
            [dependencies]
            legacy_julia_macro = { path = "../old_macro" }
            """)
        write(joinpath(crate, "src", "lib.rs"), """
            use legacy_julia_macro::julia;
            use std::sync::atomic::{AtomicU32, Ordering};
            static CALLS: AtomicU32 = AtomicU32::new(0);
            #[julia]
            pub struct Legacy { value: i32 }
            #[julia]
            impl Legacy {
                #[julia]
                pub fn new(value: i32) -> Result<Self, String> { Ok(Self { value }) }
            }
            #[julia]
            pub fn calls() -> u32 { CALLS.load(Ordering::SeqCst) }
            #[no_mangle]
            pub extern "C" fn rustcall_calls() -> u32 { calls() }
            // Deliberately incompatible legacy ABI: it must never be called.
            #[no_mangle]
            pub extern "C" fn rustcall_Legacy_new(_: i32) -> i32 {
                CALLS.fetch_add(1, Ordering::SeqCst);
                42
            }
            #[no_mangle]
            pub extern "C" fn rustcall_Legacy_free(_: *mut Legacy) {}
            """)
        bindings = @rust_crate crate
        mod = getfield(bindings, :module_ref)
        output = joinpath(dir, "LegacyWritten.jl")
        RustCall.write_bindings_to_file(crate, output; output_module_name="LegacyWritten559")
        sandbox = Module(:LegacySandbox559)
        Base.include(sandbox, output)
        written = Base.invokelatest(getfield, sandbox, :LegacyWritten559)
        try
            for module_ in (mod, written)
                T = Base.invokelatest(getfield, module_, :Legacy)
                err = try
                    Base.invokelatest(T, Int32(1))
                    nothing
                catch e
                    e
                end
                @test err isa ErrorException
                @test occursin("incompatible boxed constructor ABI", sprint(showerror, err))
                @test Base.invokelatest(Base.invokelatest(getfield, module_, :calls)) == UInt32(0)
            end
        finally
            for module_ in (mod, written)
                try
                    RustCall.unload_library(Base.invokelatest(getfield, module_, :_LIB_NAME); close=true)
                catch
                end
            end
        end
    end
end
