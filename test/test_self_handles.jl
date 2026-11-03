using RustCall, Test

# #564: a receiver method returning `Result<Self, E>` hands Julia an owned
# handle of the image that ran it. #565: a `&Value` / `&Self` / `&mut Value`
# argument is passed as the pointer its Julia handle owns, never by value.

rust"""
use std::sync::atomic::{AtomicU32, Ordering};
static DROPS564: AtomicU32 = AtomicU32::new(0);
#[julia]
pub fn drops564() -> u32 { DROPS564.load(Ordering::SeqCst) }

#[julia]
pub struct Value564 { n: i32 }
impl Drop for Value564 {
    fn drop(&mut self) { DROPS564.fetch_add(1, Ordering::SeqCst); }
}
#[julia]
impl Value564 {
    pub fn new(n: i32) -> Self { Self { n } }
    pub fn get(&self) -> i32 { self.n }
    pub fn duplicate(&self) -> Result<Self, String> {
        if self.n == -2 { panic!("duplicate panic"); }
        if self.n < 0 { Err("negative".to_owned()) } else { Ok(Self { n: self.n }) }
    }
    pub fn split(&mut self) -> Result<Value564, i32> {
        if self.n < 2 { return Err(self.n); }
        let half = self.n / 2;
        self.n -= half;
        Ok(Value564 { n: half })
    }
    pub fn sum(&self, other: &Value564) -> i32 { self.n + other.n }
    pub fn same(&self, other: &Self) -> bool { self.n == other.n }
    pub fn absorb(&mut self, other: &Value564) { self.n += other.n; }
    pub fn give(&self, other: &mut Value564) { other.n += self.n; }
}

#[julia]
pub fn total564(a: &Value564, b: &Value564) -> i32 { a.n + b.n }
#[julia]
pub fn bump564(a: &mut Value564, b: &Value564) { a.n += b.n; }
"""

@testset "#564 inline: receiver method returning Result<Self, E>" begin
    v = Value564(Int32(6))
    before = drops564()
    r = duplicate(v)
    @test RustCall.is_ok(r)
    copy = RustCall.unwrap(r)
    @test get(copy) == 6
    @test copy.ptr != v.ptr
    @test copy.alive === v.alive
    finalize(copy)
    @test drops564() == before + 1
    @test get(v) == 6  # the receiver is untouched and still owned
    @test duplicate(Value564(Int32(-1))).value == "negative"
    @test_throws RustCall.RustPanicError duplicate(Value564(Int32(-2)))
    # `&mut self`: the receiver changes, the new object is independent.
    half = RustCall.unwrap(split(v))
    @test (get(v), get(half)) == (3, 3)
    @test split(Value564(Int32(1))).value == Int32(1)
    finalize(half)
end

@testset "#565 inline: borrowed handle arguments" begin
    a, b = Value564(Int32(2)), Value564(Int32(3))
    @test sum(a, b) == 5
    @test sum(a, a) == 4                      # shared borrows may alias
    @test same(a, Value564(Int32(2)))
    @test total564(a, b) == 5
    absorb(a, b)
    @test get(a) == 5
    give(b, a)
    @test get(a) == 8
    bump564(a, b)
    @test get(a) == 11
    # A `&mut` borrow may not alias another borrow of the call.
    @test_throws ArgumentError absorb(a, a)
    @test_throws ArgumentError give(a, a)
    @test_throws ArgumentError bump564(a, a)
    @test get(a) == 11
    # Only the struct's own handle type is accepted.
    @test_throws ArgumentError sum(a, 3)
    # A freed handle is refused before Rust sees it.
    gone = Value564(Int32(1))
    finalize(gone)
    @test_throws RustCall.RustError sum(a, gone)
    # A raw pointer is still passed through unchecked, as before #565.
    @test sum(a, b.ptr) == get(a) + get(b)
    # Temporaries stay rooted for the whole call.
    acc = 0
    for i in 1:200
        acc += total564(Value564(Int32(i)), Value564(Int32(1)))
        i % 50 == 0 && GC.gc()
    end
    @test acc == Base.sum(1:200) + 200
end

function _handle_crate(dir; macro_dep)
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "Cargo.toml"), """
        [package]
        name = "self_handles_564"
        version = "0.1.0"
        edition = "2021"
        [lib]
        crate-type = ["cdylib"]
        [dependencies]
        $macro_dep
        """)
    write(joinpath(dir, "src", "lib.rs"), """
        use rustcall_julia_macros::julia;
        use std::sync::atomic::{AtomicU32, Ordering};
        static DROPS: AtomicU32 = AtomicU32::new(0);
        #[julia]
        pub fn drops() -> u32 { DROPS.load(Ordering::SeqCst) }
        #[julia]
        pub struct Value { n: i32 }
        impl Drop for Value { fn drop(&mut self) { DROPS.fetch_add(1, Ordering::SeqCst); } }
        #[julia]
        impl Value {
            #[julia]
            pub fn new(n: i32) -> Self { Self { n } }
            #[julia]
            pub fn get(&self) -> i32 { self.n }
            #[julia]
            pub fn duplicate(&self) -> Result<Self, String> {
                if self.n == -2 { panic!("duplicate panic"); }
                if self.n < 0 { Err("negative".to_owned()) } else { Ok(Self { n: self.n }) }
            }
            #[julia]
            pub fn split(&mut self) -> Result<Value, i32> {
                if self.n < 2 { return Err(self.n); }
                let half = self.n / 2;
                self.n -= half;
                Ok(Value { n: half })
            }
            #[julia]
            pub fn sum(&self, other: &Value) -> i32 { self.n + other.n }
            #[julia]
            pub fn same(&self, other: &Self) -> bool { self.n == other.n }
            #[julia]
            pub fn absorb(&mut self, other: &Value) { self.n += other.n; }
            #[julia]
            pub fn tagged(&self, other: &a::Other) -> i32 { self.n * 100 + other.m }
        }
        #[julia]
        pub fn total(a: &Value, b: &crate::Value) -> i32 { a.n + b.n }
        #[julia]
        pub mod a {
            use rustcall_julia_macros::julia;
            use super::Value;
            #[julia]
            pub struct Other { pub m: i32 }
            #[julia]
            impl Other {
                #[julia]
                pub fn new(m: i32) -> Self { Self { m } }
                #[julia]
                pub fn add(&self, v: &Value) -> i32 { self.m + v.get() }
            }
            #[julia]
            pub fn peek(o: &Other, v: &mut super::Value) -> i32 { *v = Value::new(v.get() + 1); o.m }
        }
        """)
end

@testset "#564/#565 crate and written bindings" begin
    mktempdir() do dir
        runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
        _handle_crate(dir; macro_dep = "rustcall_julia_macros = { path = \"$runtime\" }")
        bindings = @rust_crate dir
        output = joinpath(dir, "Written.jl")
        RustCall.write_bindings_to_file(dir, output; output_module_name = "WrittenHandles564")
        text = read(output, String)
        # A written file stays loadable by every 0.9 runtime: no helper added
        # after 0.9.0 is referenced (#560).
        @test !occursin("guard_boxed_result_panic_ptr", text)
        sandbox = Module(:HandlesSandbox564)
        Base.include(sandbox, output)
        written = Base.invokelatest(getfield, sandbox, :WrittenHandles564)
        modules = (getfield(bindings, :module_ref), written)
        f(mod, name) = Base.invokelatest(getfield, mod, name)
        call(fn, args...) = Base.invokelatest(fn, args...)
        try
            for mod in modules
                V = f(mod, :Value)
                v = call(V, Int32(6))
                before = call(f(mod, :drops))
                r = call(f(mod, :duplicate), v)
                @test RustCall.is_ok(r)
                copy = RustCall.unwrap(r)
                @test call(f(mod, :get), copy) == 6
                @test copy.ptr != v.ptr
                @test copy.alive === v.alive
                finalize(copy)
                @test call(f(mod, :drops)) == before + 1
                @test call(f(mod, :get), v) == 6
                @test call(f(mod, :duplicate), call(V, Int32(-1))).value == "negative"
                @test_throws RustCall.RustPanicError call(f(mod, :duplicate), call(V, Int32(-2)))
                half = RustCall.unwrap(call(f(mod, :split), v))
                @test (call(f(mod, :get), v), call(f(mod, :get), half)) == (3, 3)
                @test call(f(mod, :split), call(V, Int32(1))).value == Int32(1)

                a, b = call(V, Int32(2)), call(V, Int32(3))
                @test call(f(mod, :sum), a, b) == 5
                @test call(f(mod, :sum), a, a) == 4
                @test call(f(mod, :same), a, call(V, Int32(2)))
                @test call(f(mod, :total), a, b) == 5
                call(f(mod, :absorb), a, b)
                @test call(f(mod, :get), a) == 5
                @test_throws ArgumentError call(f(mod, :absorb), a, a)
                @test_throws ArgumentError call(f(mod, :sum), a, 3)
                gone = call(V, Int32(1))
                finalize(gone)
                @test_throws RustCall.RustError call(f(mod, :sum), a, gone)

                amod = f(mod, :a)
                O = f(amod, :Other)
                o = call(O, Int32(7))
                @test call(f(mod, :tagged), a, o) == 507
                @test call(f(amod, :add), o, a) == 12
                @test call(f(amod, :peek), o, a) == 7
                @test call(f(mod, :get), a) == 6
                # A module's own handle type only: an `Other` is not a `Value`.
                @test_throws ArgumentError call(f(mod, :sum), a, o)
                acc = 0
                for i in 1:100
                    acc += call(f(mod, :total), call(V, Int32(i)), call(V, Int32(1)))
                    i % 25 == 0 && GC.gc()
                end
                @test acc == Base.sum(1:100) + 100
                finalize(half)
            end
            # Two binding modules of one image define two handle types: a
            # handle of one is not accepted by the other's wrappers.
            mem, wr = modules
            @test_throws ArgumentError call(f(wr, :sum), call(f(wr, :Value), Int32(1)),
                                            call(f(mem, :Value), Int32(1)))

            # Across a hot reload: a successful `Ok` is bound to the image
            # that ran the call (#564), and one call never borrows objects of
            # two generations (#565).
            name = f(mem, :_LIB_NAME)
            RustCall.enable_hot_reload_for_crate(bindings; poll = true, interval = 10.0)
            try
                V = f(mem, :Value)
                old = call(V, Int32(4))
                oldgen = f(mem, :_LIB_GEN)[]
                @test old.alive === oldgen.alive
                source = joinpath(dir, "src", "lib.rs")
                write(source, read(source, String) * "\n// generation 2\n")
                @test RustCall.trigger_reload(name)
                newgen = f(mem, :_LIB_GEN)[]
                @test newgen.alive !== oldgen.alive
                fresh, fresh2 = call(V, Int32(5)), call(V, Int32(6))
                @test fresh.alive === newgen.alive
                @test call(f(mem, :sum), fresh, fresh2) == 11
                @test_throws ArgumentError call(f(mem, :sum), fresh, old)
                @test_throws ArgumentError call(f(mem, :total), old, fresh)
                @test_throws ArgumentError call(f(mem, :absorb), old, fresh)
                copy = RustCall.unwrap(call(f(mem, :duplicate), fresh))
                @test copy.alive === newgen.alive
                @test copy.free_ptr == RustCall.Libdl.dlsym(newgen.handle,
                                                            RustCall.ffi_struct_free_symbol("Value"))
                foreach(finalize, (old, fresh, fresh2, copy))
            finally
                RustCall.disable_hot_reload(name)
            end
        finally
            for mod in modules
                try
                    RustCall.unload_library(f(mod, :_LIB_NAME); close = true)
                catch
                    # Windows cannot remove a loaded DLL; cleanup is best effort.
                end
            end
        end
    end
end

@testset "#564 refuses a producer without the boxed Result ABI" begin
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
            name = "legacy_receiver_abi"
            version = "0.1.0"
            edition = "2021"
            [lib]
            crate-type = ["cdylib"]
            [dependencies]
            legacy_julia_macro = { path = "../old_macro" }
            """)
        # The shape a pre-#564 macro produced: `Self` returned by value inside
        # the aggregate, and no `_boxed_result_v1` marker. It must never be
        # called, let alone decoded as an owning pointer.
        write(joinpath(crate, "src", "lib.rs"), """
            use legacy_julia_macro::julia;
            use std::sync::atomic::{AtomicU32, Ordering};
            static CALLS: AtomicU32 = AtomicU32::new(0);
            #[julia]
            pub struct Legacy { value: i32 }
            #[julia]
            impl Legacy {
                #[julia]
                pub fn make(value: i32) -> Self { Self { value } }
                #[julia]
                pub fn duplicate(&self) -> Result<Self, String> { Ok(Self { value: self.value }) }
            }
            #[julia]
            pub fn calls() -> u32 { CALLS.load(Ordering::SeqCst) }
            #[no_mangle]
            pub extern "C" fn rustcall_calls() -> u32 { calls() }
            #[no_mangle]
            pub extern "C" fn rustcall_Legacy_make(value: i32) -> *mut Legacy {
                Box::into_raw(Box::new(Legacy { value }))
            }
            #[no_mangle]
            pub extern "C" fn rustcall_Legacy_duplicate(_: *const Legacy) -> i32 {
                CALLS.fetch_add(1, Ordering::SeqCst);
                42
            }
            #[no_mangle]
            pub extern "C" fn Legacy_free(p: *mut Legacy) {
                if !p.is_null() { unsafe { drop(Box::from_raw(p)); } }
            }
            """)
        bindings = @rust_crate crate
        mod = getfield(bindings, :module_ref)
        output = joinpath(dir, "LegacyWritten.jl")
        RustCall.write_bindings_to_file(crate, output; output_module_name = "LegacyReceiver564")
        sandbox = Module(:LegacyReceiverSandbox564)
        Base.include(sandbox, output)
        written = Base.invokelatest(getfield, sandbox, :LegacyReceiver564)
        try
            for module_ in (mod, written)
                # `make` returns `Self`, so it is bound as the constructor.
                obj = Base.invokelatest(Base.invokelatest(getfield, module_, :Legacy), Int32(1))
                dup = Base.invokelatest(getfield, module_, :duplicate)
                err = try
                    Base.invokelatest(dup, obj)
                    nothing
                catch e
                    e
                end
                @test err isa ErrorException
                @test occursin("incompatible boxed", sprint(showerror, err))
                @test Base.invokelatest(Base.invokelatest(getfield, module_, :calls)) == UInt32(0)
            end
        finally
            for module_ in (mod, written)
                try
                    RustCall.unload_library(Base.invokelatest(getfield, module_, :_LIB_NAME); close = true)
                catch
                end
            end
        end
    end
end
