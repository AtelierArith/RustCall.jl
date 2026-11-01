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
