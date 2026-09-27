# Component tests loaded by test_regressions.jl.

@testset "Known Regressions" begin
    @testset "Library-scoped return type metadata" begin
        empty!(RustCall.FUNCTION_RETURN_TYPES_BY_LIB)

        code_i32 = "#[no_mangle] pub extern \"C\" fn same_name() -> i32 { 1 }"
        code_f64 = "#[no_mangle] pub extern \"C\" fn same_name() -> f64 { 1.0 }"

        RustCall._register_manifest(RustCall.expand_inline(code_i32), "lib_i32")
        @test RustCall.FUNCTION_RETURN_TYPES_BY_LIB[("lib_i32", "same_name")] == Int32
        @test RustCall.get_function_return_type("lib_i32", "same_name") == Int32

        RustCall._register_manifest(RustCall.expand_inline(code_f64), "lib_f64")
        @test RustCall.FUNCTION_RETURN_TYPES_BY_LIB[("lib_f64", "same_name")] == Float64
        @test RustCall.get_function_return_type("lib_i32", "same_name") == Int32
        @test RustCall.get_function_return_type("lib_f64", "same_name") == Float64
        # Neither library answers for a third one: registering `same_name`
        # twice makes the cross-library hint ambiguous, and there is no
        # name-only table that could pick a winner (#279).
        @test RustCall.get_function_return_type("lib_other", "same_name") === nothing
    end

    @testset "Library-scoped return type is used by dynamic calls" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required for dynamic-call compilation"
        else
            code_i32 = "#[no_mangle] pub extern \"C\" fn same_name() -> i32 { 7 }"
            code_f64 = "#[no_mangle] pub extern \"C\" fn same_name() -> f64 { 2.5 }"
            lib_i32 = RustCall._compile_and_load_rust(code_i32, "test_regressions", 0)
            lib_f64 = RustCall._compile_and_load_rust(code_f64, "test_regressions", 0)

            result_i32 = RustCall._rust_call_dynamic(lib_i32, "same_name")
            result_f64 = RustCall._rust_call_dynamic(lib_f64, "same_name")
            @test result_i32 isa Int32
            @test result_i32 == Int32(7)
            @test result_f64 isa Float64
            @test result_f64 == 2.5
        end
    end

    @testset "@rust supports library-qualified call syntax" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required for qualified-call compilation"
        else
            code = "#[no_mangle] pub extern \"C\" fn multiply(a: i32, b: i32) -> i32 { a * b }"
            lib_name = RustCall._compile_and_load_rust(code, "test_regressions", 0)
            untyped = eval(Meta.parse("@rust $(lib_name)::multiply(Int32(3), Int32(4))"))
            typed = eval(Meta.parse("@rust $(lib_name)::multiply(Int32(5), Int32(6))::Int32"))
            @test untyped == Int32(12)
            @test typed == Int32(30)
        end
    end

    @testset "Functions without return annotation are treated as Cvoid" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required for Cvoid return inference"
        else
            code = "#[no_mangle] pub extern \"C\" fn do_nothing(x: i32) { let _ = x; }"
            lib_name = RustCall._compile_and_load_rust(code, "test_regressions", 0)
            @test RustCall._rust_call_dynamic(lib_name, "do_nothing", Int32(7)) === nothing
        end
    end

    @testset "@irust stale cache after unload_all_libraries" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required for @irust compilation"
        else
            empty!(RustCall.IRUST_FUNCTIONS)
            RustCall.unload_all_libraries()
            @test RustCall._compile_and_call_irust("arg1 + 1", Int32(1)) == Int32(2)
            @test !isempty(RustCall.IRUST_FUNCTIONS)
            RustCall.unload_all_libraries()
            @test isempty(RustCall.RUST_LIBRARIES)
            # Since #277 Phase B the memo goes with the library: unloading is
            # one transaction that drops the handle and every registry row
            # naming it, `IRUST_FUNCTIONS` included, so there is no stale entry
            # left to detect. Recompiling transparently is still what happens.
            @test isempty(RustCall.IRUST_FUNCTIONS)
            @test RustCall._compile_and_call_irust("arg1 + 1", Int32(2)) == Int32(3)
            empty!(RustCall.IRUST_FUNCTIONS)
            RustCall.unload_all_libraries()
        end
    end

    @testset "@irust rejects unsupported argument types" begin
        err = try
            RustCall._compile_and_call_irust("arg1", 1 + 2im)
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("Unsupported Julia type for @irust", sprint(showerror, err))
    end

    @testset "Qualified @rust calls resolve libraries consistently" begin
        qualified = Expr(:call, Expr(:(::), :fake_lib, :fake_fn), :(Int32(1)))
        expansion = RustCall.rust_impl(@__MODULE__, qualified)
        expanded = sprint(show, expansion)
        # `lib::f(x)` must reach the dispatcher *naming its library*, so the
        # resolution starts there rather than at the module's active one. Since
        # #253 the library is resolved on the call site's slow path — the
        # expansion carries the name and a cache of its own instead of calling
        # `_resolve_lib` inline on every call — so this asserts the name is
        # carried, not which function carries it.
        @test occursin("_rust_call_dynamic_cached", expanded)
        @test occursin("\"fake_lib\"", expanded)
        @test any(arg -> arg isa RustCall.CallTargetCache, expansion.args)
        # And the dispatcher it names still resolves through `_resolve_lib`.
        @test occursin("_resolve_lib",
                       read(joinpath(dirname(@__DIR__), "src", "macros", "ruststr.jl"), String))
    end

    @testset "Manifest handles strings, chars, comments, and closures (#85/#124)" begin
        code = raw"""
        pub fn escaped() -> i32 { let _s = "a\\\"b\\\"c"; 1 }
        pub fn braces_in_string() -> i32 { let _s = "{ value }"; 2 }
        pub fn raw_hash() -> i32 { let _s = r#"{ "key": "value" }"#; 3 }
        pub fn raw_plain() -> i32 { let _s = r"some { braces }"; 4 }
        pub fn chars() -> i32 { let _open = '{'; let _close = '}'; 5 }
        pub fn comments() -> i32 {
            // A line comment containing { and }.
            /* A block comment containing { and }. */
            6
        }
        pub fn closure() -> i32 { let f = |x| { x + 1 }; f(6) }
        """
        sigs = all_signatures(code)
        @test [s.name for s in sigs] == [
            "escaped", "braces_in_string", "raw_hash", "raw_plain", "chars", "comments", "closure"
        ]
        @test all(s -> s.return_type == "i32", sigs)
        @test all(s -> s.arg_types == String[], sigs)
    end

    @testset "Nested block comments are parsed by Rust (#177/#201)" begin
        code = raw"""
        #[julia]
        pub fn nested_comments(x: i32) -> i32 {
            /* outer { "string" /* inner } #[julia] */ still outer } */
            x
        }
        """
        expanded = RustCall.expand_inline(code)
        sig = only(RustCall.manifest_function_signatures(expanded.manifest))
        @test sig.name == "nested_comments"
        @test sig.arg_types == ["i32"]
        @test sig.return_type == "i32"
        @test occursin("pub extern \"C\" fn rustcall_nested_comments", expanded.source)
    end

    @testset "derive(JuliaStruct) multiline/order metadata" begin
        code = """
        #[derive(
            Clone,
            JuliaStruct
        )]
        pub struct Point { x: i32 }
        """
        expanded = RustCall.expand_inline(code)
        info = only(RustCall.manifest_struct_infos(expanded.manifest))
        @test info.name == "Point"
        @test info.has_clone
        @test get(info.derive_options, "Clone", false)
        @test info.fields == [("x", "i32")]
        @test !occursin("JuliaStruct", expanded.source)
        @test occursin("#[derive(Clone)]", expanded.source)
    end

    @testset "Struct and impl where clauses (#169)" begin
        code = """
        #[julia]
        pub struct Container<T> where T: Clone { value: T }
        impl<T> Container<T> where T: Clone {
            pub fn new(value: T) -> Self { Self { value } }
            pub fn get(&self) -> T { self.value.clone() }
        }
        """
        info = only(RustCall.manifest_struct_infos(RustCall.extract_manifest(code; mode = "inline")))
        @test info.name == "Container"
        @test info.type_params == ["T"]
        @test info.constraints[:T].bounds[1].trait_name == "Clone"
        @test [m.name for m in info.methods] == ["new", "get"]
        @test info.methods[1].is_constructor
        @test any(w -> w[1] == "Container_get" && occursin("Clone", w[2]), info.generic_wrappers)
    end

    @testset "Manifest-driven type parameter inference (#170)" begin
        empty!(RustCall.GENERIC_FUNCTION_REGISTRY)
        code = "pub fn transform<T, U>(x: T, y: T, z: U) -> U { z }"
        sig = signature_for(code, "transform")
        RustCall.register_generic_function(
            sig.name, sig.source, Symbol.(sig.type_params), sig.constraints, "";
            arg_types = sig.arg_types, return_type = sig.return_type,
        )
        @test RustCall.infer_type_parameters(
            "transform", Type[Int32, Int32, Float64]
        ) == Dict(:T => Int32, :U => Float64)
        empty!(RustCall.GENERIC_FUNCTION_REGISTRY)
    end

    @testset "Nested generics and return metadata (#142/#184)" begin
        code = """
        #[julia]
        fn nested(x: HashMap<String, Vec<Option<i32>>>)
            -> Result<Vec<HashMap<String, Vec<i32>>>, Box<dyn Error>> { unimplemented!() }
        #[julia]
        fn optional() -> Option<HashMap<String, Vec<i32>>> { None }
        """
        sigs = attributed_signatures(code)
        @test sigs[1].arg_types == ["HashMap<String, Vec<Option<i32>>>"]
        @test sigs[1].return_kind == :result
        @test sigs[1].ok_type == "Vec<HashMap<String, Vec<i32>>>"
        @test sigs[1].err_type == "Box<dyn Error>"
        @test sigs[2].return_kind == :option
        @test sigs[2].inner_type == "HashMap<String, Vec<i32>>"
    end

    @testset "Generic source is top-level and specializable (#231)" begin
        code = "pub fn identity<T: Copy>(x: T) -> T { x }"
        sig = signature_for(code, "identity")
        @test sig.source == code * "\n" || occursin("pub fn identity<T: Copy>", sig.source)
        specialized = RustCall.specialize_generic(
            sig.source, sig.name, ["T" => "i32"], "identity_i32"
        )
        @test specialized.arg_types == ["i32"]
        @test specialized.return_type == "i32"
        @test occursin("pub extern \"C\" fn rustcall_identity_i32", specialized.source)
    end

    @testset "Const expressions containing comparison operators (#233)" begin
        code = """
        #[julia]
        fn array_arg(x: [u8; { if 1 < 2 { 3 } else { 4 } }], y: i32) { let _ = (x, y); }
        #[julia]
        fn array_return() -> [u8; { if 1 < 2 { 3 } else { 4 } }] { [0; 3] }
        """
        sigs = attributed_signatures(code)
        @test sigs[1].arg_names == ["x", "y"]
        @test replace(sigs[1].arg_types[1], " " => "") == "[u8;{if1<2{3}else{4}}]"
        @test sigs[1].arg_types[2] == "i32"
        @test replace(sigs[2].return_type, " " => "") == "[u8;{if1<2{3}else{4}}]"
    end

    @testset "Unicode-safe trailing backslash count (#234)" begin
        @test RustCall._count_trailing_backslashes("あ\\") == 1
        @test RustCall._count_trailing_backslashes("あ\\\\") == 2
    end

    @testset "Brace suggestions ignore string literals (#235)" begin
        suggestions = RustCall.suggest_fix_for_error(
            "error: unclosed delimiter", "fn foo() { let s = \"{\"; }"
        )
        @test !any(s -> occursin("more opening brace", s), suggestions)
    end

    @testset "Function modifiers are represented in manifests (#86)" begin
        code = """
        pub async fn fetch<T>(x: T) -> T { x }
        pub unsafe fn raw<T>(ptr: *const T) -> T { unsafe { ptr.read() } }
        pub const fn constant<T>(x: T) -> T { x }
        #[no_mangle]
        pub unsafe extern "C" fn unsafe_add(a: i32, b: i32) -> i32 { a + b }
        """
        sigs = all_signatures(code)
        @test [s.name for s in sigs] == ["fetch", "raw", "constant", "unsafe_add"]
        @test all(s -> s.is_generic, sigs[1:3])
        @test sigs[4].return_type == "i32"
        @test sigs[4].exported
    end

    @testset "RustVec/RustSlice typed pointer indexing (#122)" begin
        data = Int32[10, 20, 30, 40, 50]
        GC.@preserve data begin
            ptr = Ptr{Cvoid}(pointer(data))
            vec = RustCall.RustVec{Int32}(ptr, UInt(5), UInt(5))
            @test vec[1] == 10
            @test vec[5] == 50
            @test_throws BoundsError vec[0]
            @test_throws BoundsError vec[6]
            vec.dropped = true
            slice = RustCall.RustSlice{Int32}(Ptr{Int32}(ptr), UInt(5))
            @test slice[1] == 10
            @test slice[3] == 30
            @test_throws BoundsError slice[0]
            @test_throws BoundsError slice[6]
        end
    end

    @testset "safe_dlsym prevents NULL segfaults (#118)" begin
        @test isdefined(RustCall, :safe_dlsym)
        if RustCall.is_rust_helpers_available()
            lib = RustCall.get_rust_helpers_lib()
            @test_throws ErrorException RustCall.safe_dlsym(lib, :nonexistent_symbol_xyz)
        end
    end

    @testset "Concurrent registry access is safe (#112)" begin
        errors = Threads.Atomic{Int}(0)
        tasks = [Threads.@spawn begin
            for i in 1:10
                try
                    RustCall.is_generic_function("concurrent_$(t)_$(i)")
                    lock(RustCall.REGISTRY_LOCK) do
                        haskey(RustCall.IRUST_FUNCTIONS, "concurrent_$(t)_$(i)")
                    end
                catch
                    Threads.atomic_add!(errors, 1)
                end
            end
        end for t in 1:4]
        fetch.(tasks)
        @test errors[] == 0
    end

    @testset "Deeply nested generic specialization (#108)" begin
        specialized = RustCall.specialize_generic(
            "pub fn deep<T>(x: Vec<Option<Result<T, String>>>) -> T { todo!() }",
            "deep", ["T" => "i32"], "deep_i32",
        )
        @test specialized.arg_types == ["Vec<Option<Result<i32, String>>>"]
        @test specialized.return_type == "i32"
    end

    @testset "Dead API and macro source parameter regressions (#99/#100)" begin
        @test !isdefined(RustCall, :_convert_args_for_rust)
        call_expr = Expr(:call, :fake_fn, :(Int32(1)))
        @test occursin("_rust_call_dynamic", sprint(show, RustCall.rust_impl(@__MODULE__, call_expr)))
        @test_throws MethodError RustCall.rust_impl(@__MODULE__, call_expr, LineNumberNode(1))
    end

    @testset "Unique debug filenames (#101)" begin
        debug_dir = mktempdir()
        compiler = RustCall.RustCompiler(debug_mode = true, debug_dir = debug_dir)
        name1 = RustCall._unique_source_name("fn foo() {}", compiler)
        name2 = RustCall._unique_source_name("fn bar() {}", compiler)
        @test name1 != name2
        @test name1 == RustCall._unique_source_name("fn foo() {}", compiler)
        @test startswith(name1, "rust_")
        @test length(name1) == 5 + RustCall.RECOVERY_FINGERPRINT_LEN
        @test RustCall._unique_source_name(
            "fn foo() {}", RustCall.RustCompiler(debug_mode = false)
        ) == "rust_code"

        if RustCall.check_rustc_available()
            lib1 = RustCall.compile_rust_to_shared_lib(
                "#[no_mangle] pub extern \"C\" fn debug_a() -> i32 { 1 }"; compiler = compiler
            )
            lib2 = RustCall.compile_rust_to_shared_lib(
                "#[no_mangle] pub extern \"C\" fn debug_b() -> i32 { 2 }"; compiler = compiler
            )
            @test isfile(lib1)
            @test isfile(lib2)
            @test lib1 != lib2
        else
            @test_skip "rustc is required for debug filename integration"
        end
        rm(debug_dir; recursive = true, force = true)
    end

    @testset "@rust comparison processing (#87)" begin
        lhs = Expr(:call, :add, :(Int32(1)), :(Int32(2)))
        rhs = Expr(:call, :sub, :(Int32(5)), :(Int32(2)))
        expanded = RustCall.rust_impl(@__MODULE__, Expr(:call, :(==), lhs, rhs))
        @test expanded.head == :call
        @test expanded.args[1] == :(==)
        @test all(x -> occursin("_rust_call_dynamic", sprint(show, x)), expanded.args[2:3])

        julia_rhs = Expr(:call, :/, 10.0, 3.0)
        approx = RustCall.rust_impl(
            @__MODULE__, Expr(:call, Symbol("≈"), Expr(:call, :divide, 10.0, 3.0), julia_rhs)
        )
        @test occursin("_rust_call_dynamic", sprint(show, approx.args[2]))
        @test !occursin("_rust_call_dynamic", sprint(show, approx.args[3]))
    end
end
