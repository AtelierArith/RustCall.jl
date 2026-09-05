# Regression tests for parsing, generics, and hot-reload fixes
# Issues: #168, #169, #170, #172, #173, #184, #185

using Test
using RustCall

@testset "Parsing/Generics/HotReload Fixes" begin

    # ========================================================================
    # #168 - Field type parsing regex fails for generic types with commas
    # ========================================================================
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping manifest-based parsing tests"
        return
    end

    struct_fields(code) = begin
        infos = RustCall.manifest_struct_infos(RustCall.extract_manifest(code; mode = "inline"))
        only(infos).fields
    end

    @testset "#168: Field type parsing with generic types" begin
        simple_struct = "#[julia] pub struct P { x: f64, y: f64 }"
        @test struct_fields(simple_struct) == [("x", "f64"), ("y", "f64")]

        generic_struct = "#[julia] pub struct S { data: Vec<i32>, name: String }"
        @test struct_fields(generic_struct) == [("data", "Vec<i32>"), ("name", "String")]

        multi_generic = "#[julia] pub struct M { map: HashMap<String, Vec<Option<i32>>>, count: u32 }"
        @test struct_fields(multi_generic) == [("map", "HashMap<String, Vec<Option<i32>>>"), ("count", "u32")]

        empty_struct = "#[julia] pub struct E {}"
        @test isempty(struct_fields(empty_struct))

        deep_struct = "#[julia] pub struct D { nested: Vec<Vec<Vec<(i32, String)>>> }"
        @test struct_fields(deep_struct) == [("nested", "Vec<Vec<Vec<(i32, String)>>>")]
    end

    @testset "#169: Struct/impl parsing with where clauses" begin
        code_with_where = """
        #[julia]
        pub struct Container<T> where T: Clone {
            value: T,
        }
        impl<T> Container<T> where T: Clone {
            pub fn new(value: T) -> Self { Self { value } }
            pub fn get(&self) -> T { self.value.clone() }
        }
        """
        infos = RustCall.manifest_struct_infos(RustCall.extract_manifest(code_with_where; mode = "inline"))
        @test length(infos) == 1
        @test infos[1].name == "Container"
        @test infos[1].type_params == ["T"]
        @test [m.name for m in infos[1].methods] == ["new", "get"]
        @test infos[1].constraints[:T].bounds[1].trait_name == "Clone"
        # generic wrappers carry the impl block's bounds
        @test any(w -> w[1] == "Container_get" && occursin("Clone", w[2]), infos[1].generic_wrappers)

        code_multi_where = """
        #[julia]
        pub struct Pair<A, B> where A: Copy, B: Clone + Default {
            a: A,
            b: B,
        }
        """
        infos = RustCall.manifest_struct_infos(RustCall.extract_manifest(code_multi_where; mode = "inline"))
        @test infos[1].type_params == ["A", "B"]
        @test [b.trait_name for b in infos[1].constraints[:B].bounds] == ["Clone", "Default"]

        code_no_where = """
        #[julia]
        pub struct Plain { x: i32 }
        impl Plain { pub fn new(x: i32) -> Self { Self { x } } }
        """
        infos = RustCall.manifest_struct_infos(RustCall.extract_manifest(code_no_where; mode = "inline"))
        @test infos[1].name == "Plain"
        @test isempty(infos[1].type_params)
        @test infos[1].methods[1].symbol == "Plain_new"
        @test infos[1].methods[1].is_constructor
    end

    @testset "#170: Improved type parameter inference" begin
        # Register a generic function with 2 type params but 3 args
        # fn transform<T, U>(x: T, y: T, z: U) -> U
        lock(RustCall.REGISTRY_LOCK) do
            empty!(RustCall.GENERIC_FUNCTION_REGISTRY)
        end

        code = "pub fn transform<T, U>(x: T, y: T, z: U) -> U { z }"
        RustCall.register_generic_function(
            "transform", code, [:T, :U],
            Dict{Symbol, RustCall.TypeConstraints}(), "";
            arg_types = ["T", "T", "U"], return_type = "U"
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
            Dict{Symbol, RustCall.TypeConstraints}(), "";
            arg_types = ["T", "T"], return_type = "T"
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
        sigs(code) = RustCall.manifest_function_signatures(RustCall.extract_manifest(code; mode = "inline"))

        code_simple = "#[julia]\nfn f<T>(x: T) -> T { x }"
        s = sigs(code_simple)
        @test s[1].is_generic
        @test s[1].type_params == ["T"]

        code_generic = "#[julia]\nfn g<T: Copy + Clone>(x: Vec<T>) -> Option<T> { x.first().copied() }"
        s = sigs(code_generic)
        @test s[1].type_params == ["T"]
        @test [b.trait_name for b in s[1].constraints[:T].bounds] == ["Copy", "Clone"]
        @test s[1].arg_types == ["Vec<T>"]
        @test s[1].return_type == "Option<T>"

        code_nested = "#[julia]\nfn h<T: Into<Vec<Option<T>>>>(x: HashMap<String, Vec<Option<T>>>) -> Result<Vec<T>, String> { unimplemented!() }"
        s = sigs(code_nested)
        @test s[1].type_params == ["T"]
        @test s[1].arg_types == ["HashMap<String, Vec<Option<T>>>"]
        @test s[1].return_type == "Result<Vec<T>, String>"

        code_multi = "#[julia]\nfn m<K: std::hash::Hash + Eq, V: Clone>(map: HashMap<K, V>, key: K) -> Option<V> { map.get(&key).cloned() }"
        s = sigs(code_multi)
        @test s[1].type_params == ["K", "V"]
        @test s[1].arg_names == ["map", "key"]

        code_pub = "#[julia]\npub fn p<T>(x: T) -> T where T: Copy { x }"
        s = sigs(code_pub)
        @test s[1].return_type == "T"
        @test s[1].constraints[:T].bounds[1].trait_name == "Copy"
    end
end
