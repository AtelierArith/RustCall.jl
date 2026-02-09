# Regression tests for parsing, generics, and hot-reload fixes
# Issues: #168, #169, #170, #172, #173, #184, #185

using Test
using RustCall

@testset "Parsing/Generics/HotReload Fixes" begin

    # ========================================================================
    # #168 - Field type parsing regex fails for generic types with commas
    # ========================================================================
    @testset "#168: Field type parsing with generic types" begin
        # Simple fields should still work
        simple_struct = """
        pub struct Simple {
            x: f64,
            y: f64,
        }
        """
        fields = RustCall.parse_struct_fields(simple_struct)
        @test length(fields) == 2
        @test fields[1] == ("x", "f64")
        @test fields[2] == ("y", "f64")

        # Generic types with commas (the bug)
        generic_struct = """
        pub struct Container {
            data: HashMap<String, Vec<Option<i32>>>,
            name: String,
        }
        """
        fields = RustCall.parse_struct_fields(generic_struct)
        @test length(fields) == 2
        @test fields[1] == ("data", "HashMap<String, Vec<Option<i32>>>")
        @test fields[2] == ("name", "String")

        # Multiple generic fields with commas
        multi_generic = """
        pub struct Multi {
            map: HashMap<String, i32>,
            pair: (String, i32),
            nested: Vec<Result<String, Error>>,
        }
        """
        fields = RustCall.parse_struct_fields(multi_generic)
        @test length(fields) == 3
        @test fields[1] == ("map", "HashMap<String, i32>")
        @test fields[2] == ("pair", "(String, i32)")
        @test fields[3] == ("nested", "Vec<Result<String, Error>>")

        # Empty struct
        empty_struct = "pub struct Empty {}"
        fields = RustCall.parse_struct_fields(empty_struct)
        @test isempty(fields)

        # Deeply nested generics
        deep_struct = """
        pub struct Deep {
            value: Vec<Option<Result<HashMap<String, Vec<i32>>, String>>>,
        }
        """
        fields = RustCall.parse_struct_fields(deep_struct)
        @test length(fields) == 1
        @test fields[1] == ("value", "Vec<Option<Result<HashMap<String, Vec<i32>>, String>>>")
    end

    # ========================================================================
    # #169 - Struct and impl parsing fails with where clauses
    # ========================================================================
    @testset "#169: Struct/impl parsing with where clauses" begin
        # Struct with where clause
        code_with_where = """
        pub struct Bounded<T> where T: Clone + Debug {
            value: T,
        }
        """
        structs = RustCall.parse_structs_and_impls(code_with_where)
        @test length(structs) == 1
        @test structs[1].name == "Bounded"

        # Impl with where clause
        code_with_impl_where = """
        pub struct MyStruct<T> {
            value: T,
        }

        impl<T> MyStruct<T> where T: Clone + Send {
            pub fn new(v: T) -> Self {
                MyStruct { value: v }
            }
        }
        """
        structs = RustCall.parse_structs_and_impls(code_with_impl_where)
        @test length(structs) == 1
        @test structs[1].name == "MyStruct"

        # Multiple where clause bounds
        code_multi_where = """
        pub struct Multi<T, U> where T: Clone, U: Debug {
            first: T,
            second: U,
        }
        """
        structs = RustCall.parse_structs_and_impls(code_multi_where)
        @test length(structs) == 1
        @test structs[1].name == "Multi"

        # Without where clause should still work
        code_no_where = """
        pub struct Simple<T> {
            value: T,
        }
        """
        structs = RustCall.parse_structs_and_impls(code_no_where)
        @test length(structs) == 1
        @test structs[1].name == "Simple"
    end

    # ========================================================================
    # #170 - Type parameter inference too simplistic
    # ========================================================================
    @testset "#170: Improved type parameter inference" begin
        # Register a generic function with 2 type params but 3 args
        # fn transform<T, U>(x: T, y: T, z: U) -> U
        lock(RustCall.REGISTRY_LOCK) do
            empty!(RustCall.GENERIC_FUNCTION_REGISTRY)
        end

        code = "pub fn transform<T, U>(x: T, y: T, z: U) -> U { z }"
        RustCall.register_generic_function(
            "transform", code, [:T, :U],
            Dict{Symbol, RustCall.TypeConstraints}(), ""
        )

        # With 3 args (2 for T, 1 for U), positional matching would fail
        # because #params != #args. Signature analysis should correctly map
        # x->T, y->T, z->U
        result = RustCall.infer_type_parameters("transform", Type[Int32, Int32, Float64])
        @test result[:T] == Int32
        @test result[:U] == Float64

        # Single type param with multiple args should still work
        code2 = "pub fn sum<T>(a: T, b: T) -> T { a }"
        RustCall.register_generic_function(
            "sum", code2, [:T],
            Dict{Symbol, RustCall.TypeConstraints}(), ""
        )
        result2 = RustCall.infer_type_parameters("sum", Type[Float64, Float64])
        @test result2[:T] == Float64

        # Clean up
        lock(RustCall.REGISTRY_LOCK) do
            empty!(RustCall.GENERIC_FUNCTION_REGISTRY)
        end
    end

    # ========================================================================
    # #172 - Race condition in enable_hot_reload
    # ========================================================================
    @testset "#172: HOT_RELOAD_REGISTRY thread safety" begin
        # Create a temporary directory to use as a fake crate
        test_dir = mktempdir()
        src_dir = joinpath(test_dir, "src")
        mkpath(src_dir)
        write(joinpath(src_dir, "lib.rs"), "fn main() {}")

        # Verify concurrent access to HOT_RELOAD_REGISTRY doesn't crash
        # by checking enable/disable from multiple tasks
        n_tasks = 4
        results = Vector{Bool}(undef, n_tasks)

        tasks = []
        for t in 1:n_tasks
            task = Threads.@spawn begin
                lib_name = "test_lib_$(t)"
                try
                    # is_hot_reload_enabled should be safe to call concurrently
                    RustCall.is_hot_reload_enabled(lib_name)
                    # list_hot_reload_crates should be safe too
                    RustCall.list_hot_reload_crates()
                    return true
                catch e
                    return false
                end
            end
            push!(tasks, task)
        end

        for (i, task) in enumerate(tasks)
            results[i] = fetch(task)
        end
        @test all(results)

        # Clean up
        rm(test_dir, recursive=true, force=true)
    end

    # ========================================================================
    # #173 - Watch task not properly synchronized in stop_watch_task
    # ========================================================================
    @testset "#173: stop_watch_task waits for task completion" begin
        # Create a state with a simple watch task
        state = RustCall.HotReloadState(
            "/tmp/test_crate",
            "/tmp/lib.so",
            "TestSyncLib",
            String[],
            Dict{String, Float64}(),
            nothing,
            true,
            nothing
        )

        # Start a task that runs briefly
        state.watch_task = @async begin
            while state.enabled
                sleep(0.05)
            end
        end

        # stop_watch_task should wait for the task to finish
        RustCall.stop_watch_task(state)

        # After stop_watch_task returns, the task should be done
        @test state.watch_task === nothing
        @test !state.enabled
    end

    # ========================================================================
    # #184 - Regex for #[julia] can't handle nested generic types
    # ========================================================================
    @testset "#184: #[julia] parsing with nested generics" begin
        # Simple function
        code_simple = """
        #[julia]
        fn add(a: i32, b: i32) -> i32 {
            a + b
        }
        """
        sigs = RustCall.parse_julia_functions(code_simple)
        @test length(sigs) == 1
        @test sigs[1].name == "add"
        @test sigs[1].arg_types == ["i32", "i32"]
        @test sigs[1].return_type == "i32"

        # Generic function with simple type params
        code_generic = """
        #[julia]
        fn identity<T>(x: T) -> T {
            x
        }
        """
        sigs = RustCall.parse_julia_functions(code_generic)
        @test length(sigs) == 1
        @test sigs[1].name == "identity"
        @test sigs[1].is_generic == true
        @test sigs[1].type_params == ["T"]

        # Nested generic types (the bug)
        code_nested = """
        #[julia]
        fn process<T: Clone + Into<Vec<String>>>(data: HashMap<String, Vec<T>>) -> Vec<T> {
            vec![]
        }
        """
        sigs = RustCall.parse_julia_functions(code_nested)
        @test length(sigs) == 1
        @test sigs[1].name == "process"
        @test sigs[1].is_generic == true
        @test sigs[1].type_params == ["T"]
        @test sigs[1].arg_types == ["HashMap<String, Vec<T>>"]
        @test sigs[1].return_type == "Vec<T>"

        # Multiple nested generic args
        code_multi = """
        #[julia]
        fn combine<K, V>(a: HashMap<K, Vec<V>>, b: Option<Result<K, V>>) -> Vec<(K, V)> {
            vec![]
        }
        """
        sigs = RustCall.parse_julia_functions(code_multi)
        @test length(sigs) == 1
        @test sigs[1].name == "combine"
        @test length(sigs[1].arg_types) == 2
        @test sigs[1].arg_types[1] == "HashMap<K, Vec<V>>"
        @test sigs[1].arg_types[2] == "Option<Result<K, V>>"

        # pub fn variant
        code_pub = """
        #[julia]
        pub fn greet(name: String) -> String {
            name
        }
        """
        sigs = RustCall.parse_julia_functions(code_pub)
        @test length(sigs) == 1
        @test sigs[1].name == "greet"
    end

    # ========================================================================
    # #185 - merge_constraints mutates shared TypeConstraints bounds vectors
    # ========================================================================
    @testset "#185: merge_constraints does not mutate originals" begin
        # Create two constraint dicts with overlapping keys
        c1 = Dict{Symbol, RustCall.TypeConstraints}(
            :T => RustCall.TypeConstraints([
                RustCall.TraitBound("Copy", String[]),
            ])
        )
        c2 = Dict{Symbol, RustCall.TypeConstraints}(
            :T => RustCall.TypeConstraints([
                RustCall.TraitBound("Clone", String[]),
            ])
        )

        # Save original bounds lengths
        c1_bounds_before = length(c1[:T].bounds)
        c2_bounds_before = length(c2[:T].bounds)

        # Merge
        merged = RustCall.merge_constraints(c1, c2)

        # Merged should have both bounds
        @test length(merged[:T].bounds) == 2
        @test any(b -> b.trait_name == "Copy", merged[:T].bounds)
        @test any(b -> b.trait_name == "Clone", merged[:T].bounds)

        # Originals should NOT be mutated
        @test length(c1[:T].bounds) == c1_bounds_before
        @test length(c2[:T].bounds) == c2_bounds_before
        @test c1[:T].bounds[1].trait_name == "Copy"
        @test c2[:T].bounds[1].trait_name == "Clone"

        # Modifying merged should not affect originals
        push!(merged[:T].bounds, RustCall.TraitBound("Debug", String[]))
        @test length(merged[:T].bounds) == 3
        @test length(c1[:T].bounds) == 1
        @test length(c2[:T].bounds) == 1
    end
end
