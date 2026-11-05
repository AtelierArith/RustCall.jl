using Test, RustCall

@testset "Explicit external generic instantiations" begin
    noargs = Pair{String,String}[]
    instances = Any[
        (name="F32Cell", rust_type="sample_generic::Cell<f32, 2>",
         constructor=(name="new", args=["value" => "f32"]),
         methods=[(name="get", args=noargs, return_type="f32", mutable=false),
                  (name="set", args=["value" => "f32"], return_type="()", mutable=true),
                  (name="rank", args=noargs, return_type="u32", mutable=false)]),
        (name="I64Cell", rust_type="sample_generic::Cell<i64, 3>",
         constructor=(name="new", args=["value" => "i64"]),
         methods=[(name="get", args=noargs, return_type="i64", mutable=false),
                  (name="set", args=["value" => "i64"], return_type="()", mutable=true),
                  (name="rank", args=noargs, return_type="u32", mutable=false)]),
    ]
    tensor_instance = (name="F32Tensor", rust_type="sample_generic::TypedTensor<f32, sample_generic::DynRank, sample_generic::Host>",
        constructor=(name="new", args=["value" => "f32"]),
        methods=[(name="get", args=noargs, return_type="f32", mutable=false)])
    push!(instances, tensor_instance)
    fallible = (name="F32Fallible", rust_type="sample_generic::Fallible<f32>",
        constructor=(name="new", args=["data" => "*const f32", "len" => "usize"], error_type="String",
            expression="if len == 0 { Err(\"empty tensor\".to_string()) } else { sample_generic::Fallible::<f32>::from_vec(unsafe { std::slice::from_raw_parts(data, len) }.to_vec()) }"),
        methods=[(name="get", args=noargs, return_type="f32", mutable=false)])
    push!(instances, fallible)
    code = RustCall.generate_crate_instances(instances)
    @test code == RustCall.generate_crate_instances(instances)
    @test_throws ArgumentError RustCall.generate_crate_instances([instances[1], instances[1]])
    duplicate_method = merge(instances[1], (methods=[instances[1].methods[1], instances[1].methods[1]],))
    @test_throws ArgumentError RustCall.generate_crate_instances([duplicate_method])
    invalid_argument = merge(instances[1], (constructor=(name="new", args=["bad-name" => "f32"]),))
    @test_throws ArgumentError RustCall.generate_crate_instances([invalid_argument])
    @test_throws ArgumentError RustCall.generate_crate_instances([merge(instances[1], (name="type",))])
    bad = merge(instances[1], (name="invalid name",))
    @test_throws ArgumentError RustCall.generate_crate_instances([bad])
    mktempdir() do root
        generic = joinpath(root, "generic")
        facade = joinpath(root, "facade")
        mkpath(joinpath(generic, "src"))
        mkpath(joinpath(facade, "src"))
        write(joinpath(generic, "Cargo.toml"), """
            [package]
            name = "sample_generic"
            version = "0.1.0"
            edition = "2021"
            """)
        write(joinpath(generic, "src", "lib.rs"), """
            use std::marker::PhantomData;
            use std::sync::atomic::{AtomicU32, Ordering};
            static DROPPED: AtomicU32 = AtomicU32::new(0);
            pub fn dropped() -> u32 { DROPPED.load(Ordering::SeqCst) }
            pub struct Fallible<T: Copy> { value: T }
            impl Fallible<f32> {
                pub fn from_vec(values: Vec<f32>) -> Result<Self, String> {
                    values.first().copied().map(|value| Self { value }).ok_or_else(|| "empty tensor".to_string())
                }
                pub fn get(&self) -> f32 { self.value }
            }
            pub struct DynRank;
            pub struct Host;
            pub struct TypedTensor<T: Copy, R, D> { value: T, marker: PhantomData<(R, D)> }
            impl<T: Copy, R, D> TypedTensor<T, R, D> {
                pub fn new(value: T) -> Self { Self { value, marker: PhantomData } }
                pub fn get(&self) -> T { self.value }
            }
            impl<T: Copy, R, D> Drop for TypedTensor<T, R, D> {
                fn drop(&mut self) { DROPPED.fetch_add(1, Ordering::SeqCst); }
            }
            pub struct Cell<T: Copy, const N: usize> { value: T }
            impl<T: Copy, const N: usize> Cell<T, N> {
                pub fn new(value: T) -> Self { Self { value } }
                pub fn get(&self) -> T { self.value }
                pub fn set(&mut self, value: T) { self.value = value; }
                pub fn rank(&self) -> u32 { N as u32 }
            }
            """)
        runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
        write(joinpath(facade, "Cargo.toml"), """
            [package]
            name = "generated_instances"
            version = "0.1.0"
            edition = "2021"
            [lib]
            crate-type = ["cdylib"]
            [dependencies]
            sample_generic = { path = "../generic" }
            rustcall_julia_macros = { path = "$runtime" }
            """)
        write(joinpath(facade, "src", "lib.rs"), code * "\n#[julia]\npub fn drops() -> u32 { sample_generic::dropped() }\n")
        bindings = Core.eval(@__MODULE__, :(@rust_crate $facade))
        try
            ok = RustCall.with_numeric_buffer(Float32[6]; element_type=Float32) do ptr, len
                Base.invokelatest(bindings.F32Fallible, ptr, len)
            end
            @test RustCall.is_ok(ok)
            fallible_tensor = RustCall.unwrap(ok)
            @test bindings.get(fallible_tensor) == Float32(6)
            err = RustCall.with_numeric_buffer(Float32[]; element_type=Float32) do ptr, len
                Base.invokelatest(bindings.F32Fallible, ptr, len)
            end
            @test RustCall.is_err(err)
            @test occursin("empty tensor", err.value)
            finalize(fallible_tensor)
            a = Base.invokelatest(bindings.F32Cell, Float32(1.5))
            b = Base.invokelatest(bindings.I64Cell, Int64(7))
            tensor = Base.invokelatest(bindings.F32Tensor, Float32(8))
            @test bindings.get(tensor) == Float32(8)
            @test bindings.drops() == UInt32(0)
            finalize(tensor)
            @test bindings.drops() == UInt32(1)
            @test bindings.get(a) == Float32(1.5)
            @test bindings.get(b) == Int64(7)
            bindings.set(a, Float32(3.5))
            bindings.set(b, Int64(11))
            @test bindings.rank(a) == UInt32(2)
            @test bindings.rank(b) == UInt32(3)
            @test bindings.get(a) == Float32(3.5)
            @test bindings.get(b) == Int64(11)
            # Rebuilding after an external dependency changes must not reuse a
            # stale concrete instantiation from the Cargo artifact cache.
            generic_source = joinpath(generic, "src", "lib.rs")
            write(generic_source, replace(read(generic_source, String), "N as u32" => "N as u32 + 10"))
            rebound = Core.eval(@__MODULE__, :(@rust_crate $facade))
            try
                fresh = Base.invokelatest(rebound.F32Cell, Float32(9))
                @test rebound.rank(fresh) == UInt32(12)
                finalize(fresh)
            finally
                RustCall.unload_library(Base.invokelatest(getfield, getfield(rebound, :module_ref), :_LIB_NAME); close=true)
            end
        finally
            RustCall.unload_library(Base.invokelatest(getfield, getfield(bindings, :module_ref), :_LIB_NAME); close=true)
        end
    end
end
@testset "Composed facade specification validation (#572)" begin
    emptyargs = Pair{String,String}[]
    legacy = (name=:Legacy, rust_type="native::Cell<f64>",
        constructor=(name=:new, args=["value" => "f64"]),
        methods=[(name=:get, args=emptyargs, return_type="f64", mutable=false)])
    golden = """
        use rustcall_julia_macros::julia;
        #[julia]
        pub struct Legacy { inner: native::Cell<f64> }
        #[julia]
        impl Legacy {
            #[julia]
            pub fn new(value: f64) -> Self {
                Self { inner: <native::Cell<f64>>::new(value) }
            }
            #[julia]
            pub fn get(&self) -> f64 {
                self.inner.get()
            }
        }
        """
    @test RustCall.generate_crate_instances([legacy]) == golden
    mapped = (name=:combine, args=["other" => (wrapper=:Later, mutable=false)],
        return_wrapper=:Later, mutable=false, expression="self.inner.make(&other.inner)")
    owner = merge(legacy, (name=:Owner, methods=[mapped],))
    later = merge(legacy, (name=:Later,))
    code = RustCall.generate_crate_instances([owner, later])
    @test code == RustCall.generate_crate_instances([owner, later])
    @test occursin("pub fn combine(&self, other: &Later) -> Later", code)
    @test occursin("#[julia]\n    #[rustcall_owned_return(Later)]", code)
    @test occursin("Later { inner: self.inner.make(&other.inner) }", code)
    default = (name=:combine, args=["other" => (wrapper=:Later, mutable=true)],
        return_wrapper=:Owner, error_type="String", mutable=true)
    code = RustCall.generate_crate_instances([merge(owner, (methods=[default],)), later])
    @test occursin("pub fn combine(&mut self, other: &mut Later) -> Result<Owner, String>", code)
    @test occursin("(self.inner.combine(&mut other.inner)).map(|inner| Owner { inner })", code)
    mapped_ctor = merge(later, (constructor=(name=:from_owner, args=["other"=>(wrapper=:Owner,)]),))
    ctor_source = RustCall.generate_crate_instances([mapped_ctor, owner])
    @test occursin("#[rustcall_owned_return(Later)]\n    pub fn from_owner(other: &Owner) -> Self", ctor_source)
    @test occursin("Self { inner: <native::Cell<f64>>::from_owner(&other.inner) }", ctor_source)
    for bad in [
        merge(mapped, (return_wrapper=:Unknown,)),
        merge(mapped, (return_type="f64",)),
        merge(mapped, (args=["x" => (wrapper=:Unknown, mutable=false)],)),
        merge(mapped, (args=["x" => (wrapper=:Later, mutable=1)],)),
        merge(mapped, (args=["x" => (wrapper=:Later, strange=true)],)),
        merge(mapped, (args=["x" => (mutable=false,)],)),
        merge(mapped, (args=["x" => (wrapper=:Later,), "x" => "f64"],)),
        merge(mapped, (mutable=1,)),
        merge(mapped, (expression="",)),
        merge(mapped, (error_type="",)),
        (name=:bad, args=emptyargs, return_type="f64", error_type="String", mutable=false),
        (name=:bad, args=emptyargs, mutable=false),
        (name=:bad, args=emptyargs, return_wrapper=:Later),
    ]
        @test_throws ArgumentError RustCall.generate_crate_instances([merge(owner, (methods=[bad],)), later])
    end
    @test_throws ArgumentError RustCall.generate_crate_instances([owner, later, later])
    @test_throws ArgumentError RustCall.generate_crate_instances([merge(owner, (methods=[mapped, mapped],)), later])
end

@testset "Composed native Cell facades (#572)" begin
    emptyargs = Pair{String,String}[]
    owner = (name=:Owner, rust_type="composed_native::Cell<f64>",
        constructor=(name=:new, args=["value"=>"f64"]), methods=[
            (name=:get, args=emptyargs, return_type="f64", mutable=false),
            (name=:combine, args=["other"=>(wrapper=:Owner, mutable=false)], return_type="f64", mutable=false),
            (name=:absorb, args=["other"=>(wrapper=:Owner, mutable=true)], return_type="()", mutable=true),
            (name=:pair, args=["a"=>(wrapper=:Owner,), "b"=>(wrapper=:Owner,)], return_type="f64", mutable=false),
            (name=:factor, args=["other"=>(wrapper=:Owner,)], return_wrapper=:Factor, mutable=false),
            (name=:checked, args=["other"=>(wrapper=:Owner,), "fail"=>"bool"], return_wrapper=:Factor, error_type="String", mutable=false,
                expression="self.inner.checked(&other.inner, fail)"),
            (name=:duplicate, args=emptyargs, return_wrapper=:Owner, mutable=false),
            (name=:try_duplicate, args=["fail"=>"bool"], return_wrapper=:Owner, error_type="String", mutable=false),
        ])
    factor = (name=:Factor, rust_type="composed_native::Factor",
        constructor=(name=:new, args=["value"=>"f64"]),
        methods=[(name=:value, args=emptyargs, return_type="f64", mutable=false)])
    clone_owner = (name=:CloneOwner, rust_type="composed_native::Cell<f64>",
        constructor=(name=:from_owner, args=["other"=>(wrapper=:Owner,)]),
        methods=[(name=:get, args=emptyargs, return_type="f64", mutable=false)])
    source = RustCall.generate_crate_instances([clone_owner, owner, factor])
    mktempdir() do root
        native = joinpath(root, "native")
        facade = joinpath(root, "facade")
        mkpath(joinpath(native, "src")); mkpath(joinpath(facade, "src"))
        write(joinpath(native, "Cargo.toml"), """
            [package]
            name = "composed_native"
            version = "0.1.0"
            edition = "2021"
            """)
        write(joinpath(native, "src", "lib.rs"), """
            use std::sync::atomic::{AtomicUsize, Ordering};
            static FACTOR_DROPS: AtomicUsize = AtomicUsize::new(0);
            pub fn factor_drops() -> usize { FACTOR_DROPS.load(Ordering::SeqCst) }
            pub struct Factor { value: f64 }
            impl Factor { pub fn new(value:f64)->Self { Self{value} } pub fn value(&self)->f64 { self.value } }
            impl Drop for Factor { fn drop(&mut self) { FACTOR_DROPS.fetch_add(1,Ordering::SeqCst); } }
            pub struct Cell<T> { value: T }
            impl Cell<f64> {
                pub fn new(value:f64)->Self { Self{value} }
                pub fn from_owner(other:&Self)->Self { Self::new(other.value) }
                pub fn get(&self)->f64 { self.value }
                pub fn combine(&self,other:&Self)->f64 { self.value+other.value }
                pub fn absorb(&mut self,other:&mut Self) { self.value+=other.value; other.value=0.0; }
                pub fn pair(&self,a:&Self,b:&Self)->f64 { self.value+a.value+b.value }
                pub fn factor(&self,other:&Self)->Factor { Factor::new(self.value*other.value) }
                pub fn checked(&self,other:&Self,fail:bool)->Result<Factor,String> {
                    let made=self.factor(other);
                    if fail { Err("factor failed".into()) } else { Ok(made) }
                }
                pub fn duplicate(&self)->Self { Self::new(self.value) }
                pub fn try_duplicate(&self,fail:bool)->Result<Self,String> {
                    if fail { Err("duplicate failed".into()) } else { Ok(self.duplicate()) }
                }
            }
            """)
        runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
        write(joinpath(facade, "Cargo.toml"), """
            [package]
            name = "composed_facade"
            version = "0.1.0"
            edition = "2021"
            [lib]
            crate-type = ["cdylib"]
            [dependencies]
            composed_native = { path = "../native" }
            rustcall_julia_macros = { path = "$runtime" }
            """)
        write(joinpath(facade, "src", "lib.rs"), source *
            "\n#[julia] pub fn factor_drops() -> usize { composed_native::factor_drops() }\n")
        output = joinpath(root, "bindings.jl")
        modules = Any[]
        inline = Module(Symbol("ComposedInline572_", time_ns()))
        Core.eval(inline, :(using RustCall))
        native_path = RustCall.escape_toml_string(native)
        # The emitted facade import is unnecessary in an inline block, which
        # owns its panic runtime. Remove this exact known scaffold prefix,
        # without inspecting or rewriting any user Rust expression.
        inline_body = chopprefix(source, "use rustcall_julia_macros::julia;\n")
        inline_source = "// cargo-deps: composed_native={path=\"$native_path\"}\n" *
            inline_body * "\n#[julia] pub fn factor_drops() -> usize { composed_native::factor_drops() }\n"
        Core.eval(inline, Expr(:macrocall, GlobalRef(RustCall, Symbol("@rust_str")),
            LineNumberNode(0), inline_source))
        push!(modules, RustCall.module_symbol_library(inline, "rustcall_Owner_factor"))
        bindings = Core.eval(@__MODULE__, :(@rust_crate $facade))
        push!(modules, Base.invokelatest(getfield, getfield(bindings, :module_ref), :_LIB_NAME))
        written_name = "ComposedFacade572_" * string(time_ns())
        RustCall.write_bindings_to_file(facade, output; output_module_name=written_name)
        host = Module(Symbol(written_name, "Host"))
        Base.include(host, output)
        written = Base.invokelatest(getfield, host, Symbol(written_name))
        push!(modules, Base.invokelatest(getfield, written, :_LIB_NAME))
        try
            for m in (inline, bindings, written)
                owner_type = Base.invokelatest(getproperty, m, :Owner)
                clone_type = Base.invokelatest(getproperty, m, :CloneOwner)
                factor_type = Base.invokelatest(getproperty, m, :Factor)
                get_value = Base.invokelatest(getproperty, m, :get)
                combine = Base.invokelatest(getproperty, m, :combine)
                pair = Base.invokelatest(getproperty, m, :pair)
                absorb = Base.invokelatest(getproperty, m, :absorb)
                make_factor = Base.invokelatest(getproperty, m, :factor)
                factor_value = Base.invokelatest(getproperty, m, :value)
                duplicate = Base.invokelatest(getproperty, m, :duplicate)
                checked = Base.invokelatest(getproperty, m, :checked)
                factor_drops = Base.invokelatest(getproperty, m, :factor_drops)
                try_duplicate = Base.invokelatest(getproperty, m, :try_duplicate)
                a = Base.invokelatest(owner_type, 2.0)
                b = Base.invokelatest(owner_type, 3.0)
                made = Any[a,b]
                try
                    adopted = Base.invokelatest(clone_type, a); push!(made, adopted)
                    @test adopted isa clone_type
                    @test Base.invokelatest(get_value, adopted) == 2.0
                    @test_throws ArgumentError Base.invokelatest(clone_type, C_NULL)
                    @test_throws ArgumentError Base.invokelatest(clone_type, getfield(a, :ptr))
                    @test Base.invokelatest(combine, a, b) == 5.0
                    @test Base.invokelatest(pair, a, b, b) == 8.0
                    @test_throws ArgumentError Base.invokelatest(absorb, a, a)
                    f = RustCall._unwrap_crate_binding_value(Base.invokelatest(make_factor, a, b)); push!(made,f)
                    @test f isa factor_type
                    @test Base.invokelatest(factor_value, f) == 6.0
                    @test_throws ArgumentError Base.invokelatest(combine, a, f)
                    GC.gc(true)
                    @test Base.invokelatest(factor_value, f) == 6.0
                    copy = RustCall._unwrap_crate_binding_value(Base.invokelatest(duplicate, a)); push!(made,copy)
                    @test copy isa owner_type
                    @test Base.invokelatest(get_value, copy) == 2.0
                    ok = Base.invokelatest(checked, a, b, false)
                    @test RustCall.is_ok(ok)
                    result = RustCall.unwrap(ok); push!(made,result)
                    @test result isa factor_type
                    @test Base.invokelatest(factor_value,result) == 6.0
                    before = Base.invokelatest(factor_drops)
                    err = Base.invokelatest(checked, a, b, true)
                    @test RustCall.is_err(err)
                    @test occursin("factor failed",err.value)
                    @test Base.invokelatest(factor_drops) == before+1
                    same = Base.invokelatest(try_duplicate,a,false)
                    @test RustCall.is_ok(same)
                    sameowner = RustCall.unwrap(same); push!(made,sameowner)
                    @test sameowner isa owner_type
                    @test RustCall.is_err(Base.invokelatest(try_duplicate,a,true))
                    Base.invokelatest(absorb,a,b)
                    @test Base.invokelatest(get_value,a) == 5.0
                    @test Base.invokelatest(get_value,b) == 0.0
                    finalize(b)
                    @test getfield(b, :ptr) == C_NULL
                    @test_throws RustCall.RustError Base.invokelatest(combine,a,b)
                    @test_throws RustCall.RustError Base.invokelatest(clone_type,b)
                finally
                    foreach(finalize,made)
                end
            end
        finally
            for lib in unique(modules)
                RustCall.unload_library(lib;close=true)
            end
        end
    end
end
