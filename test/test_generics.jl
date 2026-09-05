# Tests for generic function support through the rustcall-extract manifest.

using RustCall
using Test

function manifest_signatures(code)
    manifest = RustCall.extract_manifest(code; mode = "inline")
    RustCall.manifest_function_signatures(manifest; only_attributed = false)
end

function signature_named(code, name)
    only(filter(sig -> sig.name == name, manifest_signatures(code)))
end

@testset "Generic manifest metadata" begin
    @testset "Inline and where-clause constraints" begin
        code = """
        pub fn identity<T: Copy + Clone>(x: T) -> T { x }

        pub fn transform<T, U>(x: T) -> U
        where
            T: Into<U>,
            U: From<T> + core::fmt::Debug,
        {
            U::from(x)
        }

        pub fn add_values<T: Copy + core::ops::Add<Output = T>>(a: T, b: T) -> T {
            a + b
        }
        """

        identity = signature_named(code, "identity")
        @test identity.is_generic
        @test identity.type_params == ["T"]
        @test identity.arg_names == ["x"]
        @test identity.arg_types == ["T"]
        @test identity.return_type == "T"
        @test [b.trait_name for b in identity.constraints[:T].bounds] == ["Copy", "Clone"]

        transform = signature_named(code, "transform")
        @test transform.type_params == ["T", "U"]
        @test transform.constraints[:T].bounds[1].trait_name == "Into"
        @test transform.constraints[:T].bounds[1].type_params == ["U"]
        @test [b.trait_name for b in transform.constraints[:U].bounds] == ["From", "Debug"]
        @test transform.constraints[:U].bounds[1].type_params == ["T"]

        add_values = signature_named(code, "add_values")
        @test [b.trait_name for b in add_values.constraints[:T].bounds] == ["Copy", "Add"]
        @test add_values.constraints[:T].bounds[2].type_params == ["Output = T"]
    end

    @testset "Nested generic syntax is preserved (#184)" begin
        code = """
        pub fn nested<T: Into<Vec<Option<T>>>>(
            x: HashMap<String, Vec<Option<Result<T, String>>>>,
        ) -> Result<Vec<Option<T>>, Box<dyn Error>> {
            unimplemented!()
        }
        """
        sig = signature_named(code, "nested")
        @test sig.type_params == ["T"]
        @test sig.arg_types == ["HashMap<String, Vec<Option<Result<T, String>>>>"]
        @test sig.return_type == "Result<Vec<Option<T>>, Box<dyn Error>>"
        @test sig.constraints[:T].bounds[1].type_params == ["Vec<Option<T>>"]
    end

    @testset "Const-expression angle brackets do not affect signatures (#233)" begin
        sig = signature_named(
            "pub fn foo<const N: usize = { 1 + 2 }, T: Trait<{ 1 < 2 }>>(x: T) -> T { x }",
            "foo",
        )
        @test sig.type_params == ["T"]
        @test sig.arg_types == ["T"]
        @test sig.return_type == "T"
        @test sig.constraints[:T].bounds[1].trait_name == "Trait"
        const_arg = only(sig.constraints[:T].bounds[1].type_params)
        @test replace(const_arg, " " => "") == "{1<2}"
    end

    @testset "Lifetimes are not monomorphization parameters" begin
        with_type = signature_named(
            "pub fn process<'a, T: Clone>(data: &'a T, fallback: T) -> &'a T { data }",
            "process",
        )
        @test with_type.type_params == ["T"]
        @test with_type.arg_types == ["&'a T", "T"]
        @test haskey(with_type.constraints, :T)
        @test !haskey(with_type.constraints, Symbol("'a"))

        lifetime_only = signature_named(
            "pub fn borrow<'a>(data: &'a i32) -> &'a i32 { data }",
            "borrow",
        )
        @test !lifetime_only.is_generic
        @test isempty(lifetime_only.type_params)
    end

    @testset "Const generic parameter lists are parsed (#231/#232)" begin
        sig = signature_named(
            "pub fn const_generic<const N: usize = { 1 + 2 }, T>(x: T) -> T { x }",
            "const_generic",
        )
        @test sig.type_params == ["T"]
        @test sig.arg_types == ["T"]
        @test sig.return_type == "T"
    end
end

@testset "Constraint value types" begin
    copy_bound = RustCall.TraitBound("Copy", String[])
    add_bound = RustCall.TraitBound("Add", ["Output = T"])
    @test string(copy_bound) == "Copy"
    @test string(add_bound) == "Add<Output = T>"
    @test string(RustCall.TypeConstraints([copy_bound, add_bound])) == "Copy + Add<Output = T>"
    @test copy_bound == RustCall.TraitBound("Copy", String[])
end

@testset "Generic function registration and inference (#170)" begin
    lock(RustCall.REGISTRY_LOCK) do
        empty!(RustCall.GENERIC_FUNCTION_REGISTRY)
        empty!(RustCall.MONOMORPHIZED_FUNCTIONS)
    end

    code = "pub fn transform<T, U>(x: T, y: T, z: U) -> U { z }"
    sig = signature_named(code, "transform")
    info = RustCall.register_generic_function(
        sig.name,
        sig.source,
        Symbol.(sig.type_params),
        sig.constraints,
        "";
        arg_types = sig.arg_types,
        return_type = sig.return_type,
    )

    @test info.name == "transform"
    @test info.code == sig.source
    @test info.arg_types == ["T", "T", "U"]
    @test info.return_type == "U"
    @test RustCall.is_generic_function("transform")
    @test !RustCall.is_generic_function("not_registered")

    inferred = RustCall.infer_type_parameters("transform", Type[Int32, Int32, Float64])
    @test inferred == Dict(:T => Int32, :U => Float64)
    @test_throws ErrorException RustCall.infer_type_parameters(
        "transform", Type[Int32, Float64, Float64]
    )
    @test_throws ErrorException RustCall.infer_type_parameters("transform", Type[Int32])

    container_code = "pub fn first<T>(xs: Vec<T>) -> T { todo!() }"
    container_sig = signature_named(container_code, "first")
    RustCall.register_generic_function(
        container_sig.name,
        container_sig.source,
        Symbol.(container_sig.type_params),
        container_sig.constraints,
        "";
        arg_types = container_sig.arg_types,
        return_type = container_sig.return_type,
    )
    @test_throws ErrorException RustCall.infer_type_parameters("first", Type[Vector{Int32}])

    lock(RustCall.REGISTRY_LOCK) do
        empty!(RustCall.GENERIC_FUNCTION_REGISTRY)
        empty!(RustCall.MONOMORPHIZED_FUNCTIONS)
    end
end

@testset "AST specialization" begin
    @testset "Primitive and multiple bindings" begin
        specialized = RustCall.specialize_generic(
            "pub fn pair<T, U>(a: T, b: U) -> T { let _ = b; a }",
            "pair",
            ["T" => "i32", "U" => "f64"],
            "pair_i32_f64",
        )
        @test specialized.name == "pair_i32_f64"
        @test specialized.arg_types == ["i32", "f64"]
        @test specialized.return_type == "i32"
        @test occursin("pub extern \"C\" fn pair_i32_f64", specialized.source)
        # the generic original is kept so that other callers in the block still compile
        @test occursin("fn pair<T", specialized.source)
    end

    @testset "Deeply nested types (#108/#184)" begin
        specialized = RustCall.specialize_generic(
            "pub fn deep<T>(x: Vec<Option<Result<T, String>>>) -> T { todo!() }",
            "deep",
            ["T" => "i32"],
            "deep_i32",
        )
        @test specialized.arg_types == ["Vec<Option<Result<i32, String>>>"]
        @test specialized.return_type == "i32"
        @test occursin("Vec<Option<Result<i32, String>>>", specialized.source)

        specialized_map = RustCall.specialize_generic(
            "pub fn lookup<K, V>(m: HashMap<K, Vec<V>>, key: K) -> V { todo!() }",
            "lookup",
            ["K" => "i32", "V" => "f64"],
            "lookup_i32_f64",
        )
        @test specialized_map.arg_types == ["HashMap<i32, Vec<f64>>", "i32"]
        @test specialized_map.return_type == "f64"
    end
end

@testset "Julia to Rust generic type spelling" begin
    @test RustCall.julia_type_to_rust_string(Int32) == "i32"
    @test RustCall.julia_type_to_rust_string(Float64) == "f64"
    @test RustCall.julia_type_to_rust_string(Ptr{Int32}) == "Ptr<i32>"
    @test_throws ErrorException RustCall.julia_type_to_rust_string(Union{Int32, Float64})
end

@testset "Generic monomorphization" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required for monomorphization"
    else
        lock(RustCall.REGISTRY_LOCK) do
            empty!(RustCall.GENERIC_FUNCTION_REGISTRY)
            empty!(RustCall.MONOMORPHIZED_FUNCTIONS)
        end

        code = "pub fn test_identity<T>(x: T) -> T { x }"
        sig = signature_named(code, "test_identity")
        RustCall.register_generic_function(
            sig.name,
            sig.source,
            Symbol.(sig.type_params),
            sig.constraints,
            "";
            arg_types = sig.arg_types,
            return_type = sig.return_type,
        )

        mono = RustCall.monomorphize_function("test_identity", Dict(:T => Int32))
        @test mono.name == "test_identity_i32"
        @test mono.return_type == Int32
        @test mono.arg_types == [Int32]
        @test mono.func_ptr != C_NULL

        cached = RustCall.monomorphize_function("test_identity", Dict(:T => Int32))
        @test cached.name == mono.name
        @test cached.func_ptr == mono.func_ptr
        @test RustCall.call_generic_function("test_identity", Int32(42)) == Int32(42)

        lock(RustCall.REGISTRY_LOCK) do
            empty!(RustCall.GENERIC_FUNCTION_REGISTRY)
            empty!(RustCall.MONOMORPHIZED_FUNCTIONS)
        end
    end
end

@testset "Manual registration compatibility (PR #266 review)" begin
    if RustCall.check_rustc_available()
        lock(RustCall.REGISTRY_LOCK) do
            empty!(RustCall.GENERIC_FUNCTION_REGISTRY)
        end
        # Three-argument registration: signature is recovered from the source
        code = "pub fn compat_identity<T: Copy>(x: T) -> T { x }"
        info = RustCall.register_generic_function("compat_identity", code, [:T])
        @test info.arg_types == ["T"]
        @test info.return_type == "T"
        @test info.constraints[:T].bounds[1].trait_name == "Copy"
        @test RustCall.infer_type_parameters("compat_identity", Type[Int32]) == Dict(:T => Int32)
        @test RustCall.call_generic_function("compat_identity", Int32(42)) == 42

        # Legacy string constraints are parsed on the Rust side
        info2 = RustCall.register_generic_function("compat_legacy", code, [:T],
                                                   Dict(:T => "Copy + std::ops::Add<Output = T>"))
        names = [b.trait_name for b in info2.constraints[:T].bounds]
        @test names == ["Copy", "Add"]
        @test info2.constraints[:T].bounds[2].type_params == ["Output = T"]
        lock(RustCall.REGISTRY_LOCK) do
            empty!(RustCall.GENERIC_FUNCTION_REGISTRY)
        end
    end
end
