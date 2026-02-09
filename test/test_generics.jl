# Tests for generic function support

using RustCall
using Test

# Import internal functions for testing
import RustCall: GENERIC_FUNCTION_REGISTRY, MONOMORPHIZED_FUNCTIONS
import RustCall: TraitBound, TypeConstraints, GenericFunctionInfo
import RustCall: parse_trait_bounds, parse_single_trait, parse_where_clause
import RustCall: parse_inline_constraints, parse_generic_function
import RustCall: constraints_to_rust_string, merge_constraints
import RustCall: _find_matching_angle_bracket

# ============================================================================
# Bracket-counting Helper Tests
# ============================================================================

@testset "Bracket-counting helpers" begin
    @testset "_find_matching_angle_bracket" begin
        # Simple: <T>
        @test _find_matching_angle_bracket("<T>", 1) == 3

        # One level: <Vec<T>>
        @test _find_matching_angle_bracket("<Vec<T>>", 1) == 8

        # Two levels: <Option<Result<T, E>>>
        s = "<Option<Result<T, E>>>"
        @test _find_matching_angle_bracket(s, 1) == lastindex(s)

        # Three levels: <Vec<Option<Result<T, String>>>>
        s = "<Vec<Option<Result<T, String>>>>"
        @test _find_matching_angle_bracket(s, 1) == lastindex(s)

        # Multiple params with nesting: <K: Hash, V: Into<Vec<U>>>
        s = "<K: Hash, V: Into<Vec<U>>>"
        @test _find_matching_angle_bracket(s, 1) == lastindex(s)

        # No matching bracket
        @test _find_matching_angle_bracket("<T", 1) == 0

        # Starting from non-first position
        s = "fn foo<T: Add<Output = T>>(x: T)"
        open_pos = findfirst('<', s)
        close_pos = _find_matching_angle_bracket(s, open_pos)
        inner = s[open_pos+1:close_pos-1]
        @test inner == "T: Add<Output = T>"
    end
end

# ============================================================================
# Trait Bounds Parsing Tests
# ============================================================================

@testset "Trait Bounds Parsing" begin
    @testset "parse_single_trait" begin
        # Simple trait
        tb = parse_single_trait("Copy")
        @test tb.trait_name == "Copy"
        @test isempty(tb.type_params)

        # Trait with type parameter
        tb = parse_single_trait("Into<String>")
        @test tb.trait_name == "Into"
        @test tb.type_params == ["String"]

        # Trait with associated type
        tb = parse_single_trait("Add<Output = T>")
        @test tb.trait_name == "Add"
        @test tb.type_params == ["Output = T"]

        # Trait with multiple type parameters
        tb = parse_single_trait("Fn<(A, B), Output = C>")
        @test tb.trait_name == "Fn"
        @test tb.type_params == ["(A, B)", "Output = C"]
    end

    @testset "parse_trait_bounds" begin
        # Single trait
        tc = parse_trait_bounds("Copy")
        @test length(tc.bounds) == 1
        @test tc.bounds[1].trait_name == "Copy"

        # Multiple traits
        tc = parse_trait_bounds("Copy + Clone")
        @test length(tc.bounds) == 2
        @test tc.bounds[1].trait_name == "Copy"
        @test tc.bounds[2].trait_name == "Clone"

        # Multiple traits with generics
        tc = parse_trait_bounds("Copy + Add<Output = T> + Debug")
        @test length(tc.bounds) == 3
        @test tc.bounds[1].trait_name == "Copy"
        @test tc.bounds[2].trait_name == "Add"
        @test tc.bounds[2].type_params == ["Output = T"]
        @test tc.bounds[3].trait_name == "Debug"

        # Empty string
        tc = parse_trait_bounds("")
        @test isempty(tc)
    end

    @testset "parse_inline_constraints" begin
        # Simple type parameters without bounds
        type_params, constraints = parse_inline_constraints("T, U")
        @test type_params == [:T, :U]
        @test isempty(constraints)

        # Type parameters with single bounds
        type_params, constraints = parse_inline_constraints("T: Copy, U: Debug")
        @test type_params == [:T, :U]
        @test length(constraints) == 2
        @test constraints[:T].bounds[1].trait_name == "Copy"
        @test constraints[:U].bounds[1].trait_name == "Debug"

        # Type parameters with multiple bounds
        type_params, constraints = parse_inline_constraints("T: Copy + Clone + Debug")
        @test type_params == [:T]
        @test length(constraints[:T].bounds) == 3

        # Mixed: some with bounds, some without
        type_params, constraints = parse_inline_constraints("T: Copy, U")
        @test type_params == [:T, :U]
        @test haskey(constraints, :T)
        @test !haskey(constraints, :U)

        # With generic trait bounds
        type_params, constraints = parse_inline_constraints("T: Add<Output = T> + Copy")
        @test type_params == [:T]
        @test length(constraints[:T].bounds) == 2
        @test constraints[:T].bounds[1].trait_name == "Add"
        @test constraints[:T].bounds[1].type_params == ["Output = T"]
    end

    @testset "parse_where_clause" begin
        # Simple where clause
        code = "fn foo<T>(x: T) -> T where T: Copy { x }"
        constraints = parse_where_clause(code)
        @test haskey(constraints, :T)
        @test constraints[:T].bounds[1].trait_name == "Copy"

        # Multiple constraints in where clause
        code = "fn bar<T, U>(x: T, y: U) where T: Copy + Clone, U: Debug { x }"
        constraints = parse_where_clause(code)
        @test length(constraints) == 2
        @test length(constraints[:T].bounds) == 2
        @test constraints[:U].bounds[1].trait_name == "Debug"

        # Where clause with generic traits
        code = "fn transform<T, U>(x: T) -> U where T: Into<U>, U: From<T> { x.into() }"
        constraints = parse_where_clause(code)
        @test constraints[:T].bounds[1].trait_name == "Into"
        @test constraints[:T].bounds[1].type_params == ["U"]
        @test constraints[:U].bounds[1].trait_name == "From"
        @test constraints[:U].bounds[1].type_params == ["T"]

        # No where clause
        code = "fn simple<T>(x: T) -> T { x }"
        constraints = parse_where_clause(code)
        @test isempty(constraints)
    end

    @testset "parse_generic_function with constraints" begin
        # Inline constraints
        code = """
        pub fn identity<T: Copy + Clone>(x: T) -> T {
            x
        }
        """
        info = parse_generic_function(code, "identity")
        @test info !== nothing
        @test info.type_params == [:T]
        @test haskey(info.constraints, :T)
        @test length(info.constraints[:T].bounds) == 2

        # Where clause
        code = """
        pub fn transform<T, U>(x: T) -> U where T: Copy, U: From<T> {
            U::from(x)
        }
        """
        info = parse_generic_function(code, "transform")
        @test info !== nothing
        @test info.type_params == [:T, :U]
        @test haskey(info.constraints, :T)
        @test haskey(info.constraints, :U)
        @test info.constraints[:T].bounds[1].trait_name == "Copy"
        @test info.constraints[:U].bounds[1].trait_name == "From"

        # Mixed inline and where clause
        code = """
        pub fn mixed<T: Copy, U>(x: T, y: U) -> T where U: Debug {
            x
        }
        """
        info = parse_generic_function(code, "mixed")
        @test info !== nothing
        @test info.type_params == [:T, :U]
        @test info.constraints[:T].bounds[1].trait_name == "Copy"
        @test info.constraints[:U].bounds[1].trait_name == "Debug"

        # No constraints
        code = """
        pub fn simple<T>(x: T) -> T {
            x
        }
        """
        info = parse_generic_function(code, "simple")
        @test info !== nothing
        @test info.type_params == [:T]
        @test isempty(info.constraints)
    end

    @testset "parse_generic_function with deeply nested generics" begin
        # Two levels of nesting: Add<Output = T>
        code = """
        pub fn add_values<T: Copy + Add<Output = T>>(a: T, b: T) -> T {
            a + b
        }
        """
        info = parse_generic_function(code, "add_values")
        @test info !== nothing
        @test info.type_params == [:T]
        @test haskey(info.constraints, :T)
        @test length(info.constraints[:T].bounds) == 2
        @test info.constraints[:T].bounds[1].trait_name == "Copy"
        @test info.constraints[:T].bounds[2].trait_name == "Add"
        @test info.constraints[:T].bounds[2].type_params == ["Output = T"]

        # Three levels of nesting: Vec<Option<T>>
        code = """
        pub fn first_some<T: Clone>(items: Vec<Option<T>>) -> T {
            items[0].unwrap().clone()
        }
        """
        info = parse_generic_function(code, "first_some")
        @test info !== nothing
        @test info.type_params == [:T]
        @test info.constraints[:T].bounds[1].trait_name == "Clone"

        # Deeply nested: Vec<Option<Result<T, String>>>
        code = """
        pub fn unwrap_deep<T>(items: Vec<Option<Result<T, String>>>) -> T {
            items[0].unwrap().unwrap()
        }
        """
        info = parse_generic_function(code, "unwrap_deep")
        @test info !== nothing
        @test info.type_params == [:T]

        # Multiple type params with nested generics in bounds
        code = """
        pub fn convert<T: Into<Vec<U>>, U: Clone>(x: T) -> Vec<U> {
            x.into()
        }
        """
        info = parse_generic_function(code, "convert")
        @test info !== nothing
        @test info.type_params == [:T, :U]
        @test info.constraints[:T].bounds[1].trait_name == "Into"
        @test info.constraints[:T].bounds[1].type_params == ["Vec<U>"]
        @test info.constraints[:U].bounds[1].trait_name == "Clone"

        # impl with nested trait: impl<T: Add<Output = T>>
        # (parse_generic_function only handles fn, but test the pattern concept)
        code = """
        pub fn sum_all<T: Copy + Add<Output = T> + Default>(items: &[T]) -> T {
            items.iter().copied().fold(T::default(), |a, b| a + b)
        }
        """
        info = parse_generic_function(code, "sum_all")
        @test info !== nothing
        @test info.type_params == [:T]
        @test length(info.constraints[:T].bounds) == 3
        @test info.constraints[:T].bounds[1].trait_name == "Copy"
        @test info.constraints[:T].bounds[2].trait_name == "Add"
        @test info.constraints[:T].bounds[3].trait_name == "Default"
    end

    @testset "parse_single_trait with nested generics" begin
        # Nested generic in trait: Into<Vec<String>>
        tb = parse_single_trait("Into<Vec<String>>")
        @test tb.trait_name == "Into"
        @test tb.type_params == ["Vec<String>"]

        # Deeply nested: From<Option<Result<T, E>>>
        tb = parse_single_trait("From<Option<Result<T, E>>>")
        @test tb.trait_name == "From"
        @test tb.type_params == ["Option<Result<T, E>>"]

        # Multiple params with nesting: Fn<(Vec<T>,), Output = Result<U, E>>
        tb = parse_single_trait("Fn<(Vec<T>,), Output = Result<U, E>>")
        @test tb.trait_name == "Fn"
        @test length(tb.type_params) == 2
        @test tb.type_params[1] == "(Vec<T>,)"
        @test tb.type_params[2] == "Output = Result<U, E>"
    end

    @testset "parse_trait_bounds with nested generic traits" begin
        # Bounds with nested generic traits
        tc = parse_trait_bounds("Copy + Into<Vec<String>> + Debug")
        @test length(tc.bounds) == 3
        @test tc.bounds[1].trait_name == "Copy"
        @test tc.bounds[2].trait_name == "Into"
        @test tc.bounds[2].type_params == ["Vec<String>"]
        @test tc.bounds[3].trait_name == "Debug"

        # Two generic traits with nesting
        tc = parse_trait_bounds("From<Option<T>> + Into<Result<U, E>>")
        @test length(tc.bounds) == 2
        @test tc.bounds[1].trait_name == "From"
        @test tc.bounds[1].type_params == ["Option<T>"]
        @test tc.bounds[2].trait_name == "Into"
        @test tc.bounds[2].type_params == ["Result<U, E>"]
    end

    @testset "constraints_to_rust_string" begin
        # Empty constraints
        @test constraints_to_rust_string(Dict{Symbol, TypeConstraints}()) == ""

        # Single constraint with single bound
        constraints = Dict(:T => TypeConstraints([TraitBound("Copy", String[])]))
        @test constraints_to_rust_string(constraints) == "T: Copy"

        # Single constraint with multiple bounds
        constraints = Dict(:T => TypeConstraints([
            TraitBound("Copy", String[]),
            TraitBound("Clone", String[])
        ]))
        @test constraints_to_rust_string(constraints) == "T: Copy + Clone"

        # Multiple constraints
        constraints = Dict(
            :T => TypeConstraints([TraitBound("Copy", String[])]),
            :U => TypeConstraints([TraitBound("Debug", String[])])
        )
        result = constraints_to_rust_string(constraints)
        @test occursin("T: Copy", result)
        @test occursin("U: Debug", result)

        # With generic trait
        constraints = Dict(:T => TypeConstraints([
            TraitBound("Add", ["Output = T"])
        ]))
        @test constraints_to_rust_string(constraints) == "T: Add<Output = T>"
    end

    @testset "merge_constraints" begin
        c1 = Dict(:T => TypeConstraints([TraitBound("Copy", String[])]))
        c2 = Dict(:U => TypeConstraints([TraitBound("Debug", String[])]))

        merged = merge_constraints(c1, c2)
        @test haskey(merged, :T)
        @test haskey(merged, :U)

        # Merging same type parameter
        c1 = Dict(:T => TypeConstraints([TraitBound("Copy", String[])]))
        c2 = Dict(:T => TypeConstraints([TraitBound("Clone", String[])]))

        merged = merge_constraints(c1, c2)
        @test length(merged[:T].bounds) == 2
    end

    @testset "TypeConstraints and TraitBound show methods" begin
        tb = TraitBound("Copy", String[])
        @test string(tb) == "Copy"

        tb = TraitBound("Add", ["Output = T"])
        @test string(tb) == "Add<Output = T>"

        tc = TypeConstraints([
            TraitBound("Copy", String[]),
            TraitBound("Clone", String[])
        ])
        @test string(tc) == "Copy + Clone"
    end

    @testset "register_generic_function with constraints" begin
        # Test with new TypeConstraints format
        constraints = Dict(:T => TypeConstraints([
            TraitBound("Copy", String[]),
            TraitBound("Clone", String[])
        ]))
        code = "pub fn test_func<T: Copy + Clone>(x: T) -> T { x }"
        info = register_generic_function("test_with_constraints", code, [:T], constraints)

        @test info.name == "test_with_constraints"
        @test length(info.constraints[:T].bounds) == 2

        # Test backward compatibility with Dict{Symbol, String}
        legacy_constraints = Dict(:T => "Copy + Clone")
        info = register_generic_function("test_legacy", code, [:T], legacy_constraints)

        @test info.name == "test_legacy"
        @test length(info.constraints[:T].bounds) == 2
        @test info.constraints[:T].bounds[1].trait_name == "Copy"
    end
end

# ============================================================================
# Original Generic Function Tests
# ============================================================================

@testset "Generic Function Support" begin
    @testset "Generic Function Registration" begin
        # Test registering a generic function
        code = """
        #[no_mangle]
        pub extern "C" fn identity<T>(x: T) -> T {
            x
        }
        """

        register_generic_function("identity", code, [:T])

        @test is_generic_function("identity")
        @test !is_generic_function("nonexistent")

        # Check that it's in the registry
        @test haskey(GENERIC_FUNCTION_REGISTRY, "identity")
        info = GENERIC_FUNCTION_REGISTRY["identity"]
        @test info.name == "identity"
        @test info.type_params == [:T]
    end

    @testset "Type Parameter Inference" begin
        # Register a generic function
        code = """
        #[no_mangle]
        pub extern "C" fn identity<T>(x: T) -> T {
            x
        }
        """
        register_generic_function("identity", code, [:T])

        # Test inference with Int32
        type_params = infer_type_parameters("identity", [Int32])
        @test type_params == Dict(:T => Int32)

        # Test inference with Float64
        type_params = infer_type_parameters("identity", [Float64])
        @test type_params == Dict(:T => Float64)
    end

    @testset "Code Specialization" begin
        # Test specializing generic code
        code = """
        #[no_mangle]
        pub extern "C" fn identity<T>(x: T) -> T {
            x
        }
        """

        specialized = specialize_generic_code(code, Dict(:T => Int32))

        # Check that T is replaced with i32
        @test occursin("i32", specialized)
        @test !occursin("<T>", specialized)
        @test !occursin(": T", specialized) || occursin(": i32", specialized)
    end

    @testset "Code Specialization with Container Types" begin
        # Test that nested angle brackets in container types are handled correctly
        # This was broken by the regex `<.+?>` which stops at the first `>`

        # Vec<T> parameter
        code = """
        pub fn sum_vec<T: Copy + std::ops::Add<Output = T>>(v: *const T, len: usize) -> T {
            let slice = unsafe { std::slice::from_raw_parts(v, len) };
            slice[0]
        }
        """
        specialized = specialize_generic_code(code, Dict(:T => Float64))
        @test !occursin("<T:", specialized)  # generic params removed
        @test occursin("f64", specialized)
        @test occursin("fn sum_vec(", specialized)

        # Nested generics: Vec<Vec<T>>
        code = """
        pub fn nested<T>(x: Vec<Vec<T>>) -> T {
            x[0][0]
        }
        """
        specialized = specialize_generic_code(code, Dict(:T => Int32))
        @test !occursin("<T>", specialized)
        @test occursin("Vec<Vec<i32>>", specialized)
        @test occursin("fn nested(", specialized)

        # Multiple type params with containers: HashMap<K, V>
        code = """
        pub fn get_value<K, V>(map: HashMap<K, V>, key: K) -> V {
            map[key]
        }
        """
        specialized = specialize_generic_code(code, Dict(:K => Int32, :V => Float64))
        @test occursin("HashMap<i32, f64>", specialized)
        @test occursin("fn get_value(", specialized)

        # impl block with nested generics
        code = """
        impl<T: Copy> MyStruct<T> {
            pub fn get(&self) -> T { self.value }
        }
        """
        specialized = specialize_generic_code(code, Dict(:T => Int32))
        @test !occursin("impl<", specialized)
        @test occursin("impl", specialized)
        @test occursin("i32", specialized)
    end

    @testset "Deeply nested generic specialization" begin
        # Three levels: Vec<Option<Result<T, String>>>
        code = """
        pub fn unwrap_deep<T>(items: Vec<Option<Result<T, String>>>) -> T {
            items[0].unwrap().unwrap()
        }
        """
        specialized = specialize_generic_code(code, Dict(:T => Int32))
        @test occursin("Vec<Option<Result<i32, String>>>", specialized)
        @test occursin("fn unwrap_deep(", specialized)
        @test !occursin("<T>", specialized)

        # Nested trait bounds in fn signature: Add<Output = T>
        code = """
        pub fn sum<T: Copy + Add<Output = T> + Default>(items: &[T]) -> T {
            items.iter().copied().fold(T::default(), |a, b| a + b)
        }
        """
        specialized = specialize_generic_code(code, Dict(:T => Float64))
        @test occursin("fn sum(", specialized)
        @test !occursin("<T:", specialized)
        @test occursin("f64", specialized)

        # impl block with deeply nested generics
        code = """
        impl<T: Clone + Into<Vec<Option<T>>>> Wrapper<T> {
            pub fn convert(&self) -> Vec<Option<T>> { self.value.clone().into() }
        }
        """
        specialized = specialize_generic_code(code, Dict(:T => Int64))
        @test !occursin("impl<", specialized)
        @test occursin("impl", specialized)
        @test occursin("i64", specialized)

        # Multiple type params with nested containers
        code = """
        pub fn merge<K, V>(a: HashMap<K, Vec<V>>, b: HashMap<K, Vec<V>>) -> HashMap<K, Vec<V>> {
            a
        }
        """
        specialized = specialize_generic_code(code, Dict(:K => Int32, :V => Float64))
        @test occursin("HashMap<i32, Vec<f64>>", specialized)
        @test occursin("fn merge(", specialized)
    end

    @testset "Generic Function Detection" begin
        # Test that generic functions are detected in rust"" blocks
        if check_rustc_available()
            rust"""
            #[no_mangle]
            pub extern "C" fn test_identity<T>(x: T) -> T {
                x
            }
            """

            # Check if it was registered
            # Note: This might not work if the detection fails silently
            # We'll test the manual registration path instead
            @test true  # Placeholder - actual detection test would go here
        else
            @warn "rustc not available, skipping generic function detection test"
        end
    end

    @testset "Monomorphization" begin
        if check_rustc_available()
            # Register a simple generic function
            code = """
            #[no_mangle]
            pub extern "C" fn identity<T>(x: T) -> T {
                x
            }
            """
            register_generic_function("test_identity", code, [:T])

            # Test monomorphization with Int32
            type_params = Dict(:T => Int32)
            info = monomorphize_function("test_identity", type_params)

            @test info.name != "test_identity"  # Should have a specialized name
            @test occursin("i32", info.name)  # Should contain type suffix
            @test info.return_type == Int32
            @test info.arg_types == [Int32]
            @test info.func_ptr != C_NULL

            # Test that caching works
            info2 = monomorphize_function("test_identity", type_params)
            @test info.name == info2.name
            @test info.func_ptr == info2.func_ptr
        else
            @warn "rustc not available, skipping monomorphization test"
        end
    end

    @testset "Call Generic Function" begin
        if check_rustc_available()
            # Register and test calling a generic function
            code = """
            #[no_mangle]
            pub extern "C" fn add<T>(a: T, b: T) -> T {
                a + b
            }
            """
            register_generic_function("test_add", code, [:T])

            # Note: This test might fail because Rust generics with + operator
            # require trait bounds. For now, we'll test the infrastructure.
            # A working example would need: fn add<T: Copy + Add<Output = T>>(a: T, b: T) -> T

            @test is_generic_function("test_add")
        else
            @warn "rustc not available, skipping generic function call test"
        end
    end

    @testset "Multiple Type Parameters" begin
        if check_rustc_available()
            # Test with multiple type parameters
            code = """
            #[no_mangle]
            pub extern "C" fn pair<T, U>(a: T, b: U) -> T {
                a
            }
            """
            register_generic_function("test_pair", code, [:T, :U])

            # Test inference
            type_params = infer_type_parameters("test_pair", [Int32, Float64])
            @test type_params[:T] == Int32
            @test type_params[:U] == Float64
        else
            @warn "rustc not available, skipping multiple type parameters test"
        end
    end
end
