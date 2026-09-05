# Regression reproduction tests for known issues.

using RustCall
using Test
using Libdl

all_signatures(code; mode = "inline") = RustCall.manifest_function_signatures(
    RustCall.extract_manifest(code; mode = mode); only_attributed = false
)
attributed_signatures(code; mode = "inline") = RustCall.manifest_function_signatures(
    RustCall.extract_manifest(code; mode = mode)
)
signature_for(code, name; mode = "inline") = only(
    filter(sig -> sig.name == name, all_signatures(code; mode = mode))
)

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
            RustCall.unload_all_libraries()
            @test isempty(RustCall.RUST_LIBRARIES)
            @test !isempty(RustCall.IRUST_FUNCTIONS)
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
        expanded = sprint(show, RustCall.rust_impl(@__MODULE__, qualified))
        @test occursin("_rust_call_from_lib", expanded)
        @test occursin("_resolve_lib", expanded)
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
                        haskey(RustCall.IRUST_FUNCTIONS, UInt64(t * 1000 + i))
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

@testset "Prevention Regressions" begin
    @testset "Manifest cross-file dependencies are accessible (#130)" begin
        for name in (
            :extract_manifest, :expand_inline, :manifest_function_signatures,
            :manifest_struct_infos, :specialize_generic,
        )
            @test isdefined(RustCall, name)
            @test getproperty(RustCall, name) isa Function
        end
    end

    @testset "Per-library reload locks exist (#132)" begin
        @test isdefined(RustCall, :RELOAD_LOCKS)
        @test isdefined(RustCall, :RELOAD_LOCKS_LOCK)
        lock1 = RustCall._get_reload_lock("test_prevention_lib")
        @test lock1 isa ReentrantLock
        @test lock1 === RustCall._get_reload_lock("test_prevention_lib")
        lock2 = RustCall._get_reload_lock("test_prevention_other")
        @test lock1 !== lock2
        delete!(RustCall.RELOAD_LOCKS, "test_prevention_lib")
        delete!(RustCall.RELOAD_LOCKS, "test_prevention_other")
    end

    @testset "Lifetime parameters are filtered by manifest (#134)" begin
        mixed = signature_for(
            "pub fn mixed<'a, T: Clone + Send, U: Sync>(x: &'a T, y: U) -> U { y }", "mixed"
        )
        @test mixed.type_params == ["T", "U"]
        @test !haskey(mixed.constraints, Symbol("'a"))
        @test [b.trait_name for b in mixed.constraints[:T].bounds] == ["Clone", "Send"]
        lifetime_only = signature_for(
            "pub fn borrow<'a>(x: &'a i32) -> &'a i32 { x }", "borrow"
        )
        @test !lifetime_only.is_generic
        @test isempty(lifetime_only.type_params)
    end

    @testset "Generated finalizers have try-catch guards (#136)" begin
        info = RustCall.RustStructInfo(
            "TestStruct", String[], RustCall.RustMethod[], "",
            [("x", "i32"), ("y", "f64")], false, Dict{String, Bool}(),
        )
        code = RustCall._emit_struct_code(info)
        @test occursin("try", code)
        @test occursin("catch", code)
        @test occursin("finalizer", code)
        @test occursin("exception=e", code) || occursin("exception = e", code)
    end

    @testset "Generated wrappers include null pointer checks (#138)" begin
        alive = (ptr = Ptr{Cvoid}(1),)
        freed = (ptr = Ptr{Cvoid}(0),)
        @test_nowarn RustCall._check_not_freed(alive, "TestType")
        @test_throws ErrorException RustCall._check_not_freed(freed, "TestType")
        info = RustCall.RustStructInfo(
            "GuardTest", String[],
            [RustCall.RustMethod("do_something", false, false, String[], String[], "i32")],
            "", [("x", "i32")], false, Dict{String, Bool}(),
        )
        @test occursin("_check_not_freed", RustCall._emit_method_code(info, info.methods[1]))
        @test occursin("_check_not_freed", RustCall._emit_struct_code(info))
        static = RustCall.RustMethod("create", true, false, ["val"], ["i32"], "Self")
        @test !occursin("_check_not_freed", RustCall._emit_method_code(info, static))
    end

    @testset "LLVM optimization uses New Pass Manager (#140)" begin
        @test isdefined(RustCall, :optimize_module!)
        @test isdefined(RustCall, :optimize_function!)
        config = RustCall.OptimizationConfig()
        @test config.level == 2
        @test config.size_level == 0
        @test config.enable_vectorization
        @test RustCall.OptimizationConfig(level = 0, size_level = 0).level == 0
    end

    @testset "Float types supported in ownership wrappers (#144)" begin
        for wrapper in (RustCall.RustRc, RustCall.RustArc, RustCall.RustBox)
            @test hasmethod(wrapper, Tuple{Float32})
            @test hasmethod(wrapper, Tuple{Float64})
        end
    end

    @testset "Error codes preserved in result_to_exception (#146)" begin
        try
            RustCall.result_to_exception(RustCall.RustResult{String, Int32}(false, Int32(42)))
            @test false
        catch e
            @test e isa RustCall.RustError
            @test e.code == Int32(42)
            @test e.original_error == Int32(42)
        end
        try
            RustCall.result_to_exception(RustCall.RustResult{Int32, String}(false, "not found"))
            @test false
        catch e
            @test e.code == Int32(-1)
            @test e.original_error == "not found"
        end
        @test RustCall.result_to_exception(
            RustCall.RustResult{Int32, String}(true, Int32(99))
        ) == Int32(99)
    end

    @testset "Registry locks and deferred drops (#148/#150)" begin
        @test RustCall.LLVM_REGISTRY_LOCK isa ReentrantLock
        @test RustCall.REGISTRY_LOCK isa ReentrantLock
        @test isdefined(RustCall, :RUST_MODULES)
        initial = RustCall.deferred_drop_count()
        RustCall._defer_drop(Ptr{Cvoid}(UInt(0xDEAD)), "TestType{Int32}", :test_drop_sym)
        @test RustCall.deferred_drop_count() == initial + 1
        lock(RustCall.DEFERRED_DROPS_LOCK) do
            filter!(d -> d.type_name != "TestType{Int32}", RustCall.DEFERRED_DROPS)
        end
    end

    @testset "TOML escaping and wrapper cleanup (#162/#163)" begin
        @test RustCall.escape_toml_string("hello") == "hello"
        @test RustCall.escape_toml_string("path\\to") == "path\\\\to"
        @test RustCall.escape_toml_string("say \"hello\"") == "say \\\"hello\\\""
        malicious = "\" }\n[package]\nname = \"malicious"
        escaped = RustCall.escape_toml_string(malicious)
        @test !occursin("\n[package]", escaped)
        @test occursin("\\n", escaped)
        @test RustCall.cleanup_cargo_project isa Function
    end

    @testset "Cache naming and checksum (#179/#180/#198)" begin
        @test isdefined(RustCall, :load_cached_library)
        @test !isempty(RustCall._get_rustc_version())
        code = "fn test() -> i32 { 1 }"
        key1 = RustCall.generate_cache_key(code, RustCall.RustCompiler(optimization_level = 0))
        key2 = RustCall.generate_cache_key(code, RustCall.RustCompiler(optimization_level = 2))
        @test key1 != key2

        tmp = tempname()
        write(tmp, "test data for checksum")
        checksum = RustCall._compute_file_checksum(tmp)
        @test length(checksum) == 64
        @test checksum == RustCall._compute_file_checksum(tmp)
        rm(tmp)
    end
end

# Since #279 a Rust item and the C symbol that exposes it can differ, and the
# mapping between them is recorded per library. It must stay that way: a
# library exporting `#[julia] fn f` as `rustcall_f` must not decide how a
# *different* library's plain `#[no_mangle] fn f` resolves, and unloading the
# first must not leave a mapping that redirects later lookups to a symbol that
# is gone.
@testset "#279: name -> symbol resolution is scoped to one library" begin
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping per-library symbol resolution test"
        return
    end

    # Library A: `#[julia]`, so the C entry point is `rustcall_scoped_probe`
    # and the Rust name is not exported at all.
    expanded_a = RustCall.expand_inline("""
    #[julia]
    pub fn scoped_probe(x: i32) -> i32 { x + 1 }
    """)
    # Library B: a plain `#[no_mangle]` function of the same Rust name,
    # exported under that name.
    expanded_b = RustCall.expand_inline("""
    #[no_mangle]
    pub extern "C" fn scoped_probe(x: i32) -> i32 { x + 100 }
    """)

    path_a = RustCall.compile_rust_to_shared_lib(expanded_a.source)
    path_b = RustCall.compile_rust_to_shared_lib(expanded_b.source)
    lib_a = "test279_a_" * string(hash(path_a), base = 16)
    lib_b = "test279_b_" * string(hash(path_b), base = 16)
    handle_a = Libdl.dlopen(path_a, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
    handle_b = Libdl.dlopen(path_b, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
    unloaded = Set{String}()
    unload!(name) = (name in unloaded || (push!(unloaded, name); RustCall.unload_library(name)))

    try
        lock(RustCall.REGISTRY_LOCK) do
            RustCall.RUST_LIBRARIES[lib_a] = (handle_a, Dict{String, Ptr{Cvoid}}())
            RustCall.RUST_LIBRARIES[lib_b] = (handle_b, Dict{String, Ptr{Cvoid}}())
        end
        RustCall._register_manifest(expanded_a, lib_a)
        RustCall._register_manifest(expanded_b, lib_b)

        # The mapping is not visible across libraries, and a library that
        # recorded nothing resolves the name to itself.
        @test RustCall.exported_symbol(lib_a, "scoped_probe") == "rustcall_scoped_probe"
        @test RustCall.exported_symbol(lib_b, "scoped_probe") == "scoped_probe"
        @test RustCall.exported_symbol("test279_unknown_lib", "scoped_probe") == "scoped_probe"
        # A's Rust name really is not a C symbol; B's really is.
        @test Libdl.dlsym(handle_a, "scoped_probe"; throw_error = false) === nothing
        @test Libdl.dlsym(handle_b, "rustcall_scoped_probe"; throw_error = false) === nothing

        # Both are callable and each resolves to its own library's symbol.
        ptr_a = RustCall.get_function_pointer(lib_a, "scoped_probe")
        ptr_b = RustCall.get_function_pointer(lib_b, "scoped_probe")
        @test ptr_a != ptr_b
        @test RustCall.call_rust_function(ptr_a, Int32, Int32(1)) == Int32(2)
        @test RustCall.call_rust_function(ptr_b, Int32, Int32(1)) == Int32(101)

        # Unloading A drops its mapping; B keeps resolving.
        unload!(lib_a)
        @test RustCall.exported_symbol(lib_a, "scoped_probe") == "scoped_probe"
        @test RustCall.exported_symbol(lib_b, "scoped_probe") == "scoped_probe"
        ptr_b_again = RustCall.get_function_pointer(lib_b, "scoped_probe")
        @test RustCall.call_rust_function(ptr_b_again, Int32, Int32(1)) == Int32(101)
    finally
        unload!(lib_a)
        unload!(lib_b)
    end
end

# #279 follow-up: a library handle and the name-to-symbol mappings its manifest
# describes must become visible together. Publishing the handle first left a
# window in which a concurrent `ensure_loaded` / `@rust f(...)` saw the library
# but not the mapping, and resolved `f` to `f` instead of `rustcall_f`.
@testset "#279: a library and its symbol mappings are published together" begin
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping concurrent publication test"
        return
    end

    rust"""
    #[julia]
    pub fn concurrent_probe(x: i32) -> i32 { x * 7 }
    """
    lib_name = RustCall.get_current_library()

    # The mapping is in place for the library that is now current.
    @test RustCall.exported_symbol(lib_name, "concurrent_probe") == "rustcall_concurrent_probe"

    # Several tasks calling the attributed function concurrently: every call
    # resolves and returns, none races the publication of the handle.
    results = Vector{Int32}(undef, 32)
    @sync for i in 1:length(results)
        Threads.@spawn begin
            results[i] = concurrent_probe(Int32(i))
        end
    end
    @test results == Int32[i * 7 for i in 1:length(results)]

    # The same through `@rust`, which resolves the Rust name at call time.
    macro_results = Vector{Int32}(undef, 16)
    @sync for i in 1:length(macro_results)
        Threads.@spawn begin
            macro_results[i] = @rust concurrent_probe(Int32(i))::Int32
        end
    end
    @test macro_results == Int32[i * 7 for i in 1:length(macro_results)]

    # Reloading the very same block (the in-memory hit path) keeps the mapping.
    RustCall.ensure_loaded(lib_name, "#[julia]\npub fn concurrent_probe(x: i32) -> i32 { x * 7 }")
    @test RustCall.exported_symbol(lib_name, "concurrent_probe") == "rustcall_concurrent_probe"
    @test concurrent_probe(Int32(3)) == Int32(21)
end

# #279 follow-up: registering one loaded handle under a second name has to
# carry the name-to-symbol mappings over, or a lookup through the alias
# resolves `f` to `f`, misses `rustcall_f`, and falls back to the ambiguous
# cross-library search.
@testset "#279: an aliased library keeps its symbol mappings" begin
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping alias mapping test"
        return
    end

    expanded = RustCall.expand_inline("""
    #[julia]
    pub fn aliased_probe(x: i32) -> i32 { x - 1 }
    """)
    path = RustCall.compile_rust_to_shared_lib(expanded.source)
    actual = "test279_actual_" * string(hash(path), base = 16)
    stored = "test279_stored_" * string(hash(path), base = 16)
    handle = Libdl.dlopen(path, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)

    try
        RustCall._register_manifest(expanded, actual; handle = handle, set_current = false)
        @test RustCall.exported_symbol(actual, "aliased_probe") == "rustcall_aliased_probe"
        # The alias has nothing of its own yet.
        @test RustCall.exported_symbol(stored, "aliased_probe") == "aliased_probe"

        RustCall._alias_reloaded_library(Main, stored, actual)
        @test RustCall.exported_symbol(stored, "aliased_probe") == "rustcall_aliased_probe"
        ptr = RustCall.get_function_pointer(stored, "aliased_probe")
        @test RustCall.call_rust_function(ptr, Int32, Int32(5)) == Int32(4)
        # The return-type hints travel with the mappings.
        @test RustCall.get_function_return_type(stored, "aliased_probe") === Int32

        # Dropping the alias must not disturb the library it pointed at.
        RustCall.clear_library_metadata!(stored)
        @test RustCall.exported_symbol(actual, "aliased_probe") == "rustcall_aliased_probe"
        @test RustCall.get_function_return_type(actual, "aliased_probe") === Int32
    finally
        for name in (stored, actual)
            lock(RustCall.REGISTRY_LOCK) do
                delete!(RustCall.RUST_LIBRARIES, name)
                RustCall.clear_library_metadata!(name)
            end
        end
        Libdl.dlclose(handle)
    end
end

# #279 follow-up: the alias must carry the return-type hints too, not just the
# symbol mappings. Otherwise an untyped `@rust f(...)` through the stored name
# misses the library-scoped entry and either takes another library's answer or
# none at all, instead of the type the aliased block declared.
@testset "#279: an aliased library keeps its return-type hints" begin
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping alias return-type test"
        return
    end

    # Two blocks declaring the same Rust name with different return types.
    expanded_i32 = RustCall.expand_inline("""
    #[julia]
    pub fn alias_typed(x: i32) -> i32 { x }
    """)
    expanded_f64 = RustCall.expand_inline("""
    #[julia]
    pub fn alias_typed(x: i32) -> f64 { x as f64 }
    """)
    path_i32 = RustCall.compile_rust_to_shared_lib(expanded_i32.source)
    path_f64 = RustCall.compile_rust_to_shared_lib(expanded_f64.source)
    lib_i32 = "test279_ret_i32_" * string(hash(path_i32), base = 16)
    lib_f64 = "test279_ret_f64_" * string(hash(path_f64), base = 16)
    stored = "test279_ret_stored_" * string(hash(path_i32), base = 16)
    handle_i32 = Libdl.dlopen(path_i32, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
    handle_f64 = Libdl.dlopen(path_f64, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)

    try
        RustCall._register_manifest(expanded_i32, lib_i32; handle = handle_i32, set_current = false)
        RustCall._register_manifest(expanded_f64, lib_f64; handle = handle_f64, set_current = false)
        @test RustCall.get_function_return_type(lib_i32, "alias_typed") === Int32
        @test RustCall.get_function_return_type(lib_f64, "alias_typed") === Float64
        # Two libraries declare the name, so a third gets no answer at all
        # rather than an arbitrary one.
        @test RustCall.get_function_return_type("test279_ret_unknown", "alias_typed") === nothing

        # Aliasing the i32 block must give the alias *its* type, not the other
        # block's and not nothing.
        RustCall._alias_reloaded_library(Main, stored, lib_i32)
        @test RustCall.get_function_return_type(stored, "alias_typed") === Int32
        @test RustCall.exported_symbol(stored, "alias_typed") == "rustcall_alias_typed"
    finally
        for name in (stored, lib_i32, lib_f64)
            lock(RustCall.REGISTRY_LOCK) do
                delete!(RustCall.RUST_LIBRARIES, name)
                RustCall.clear_library_metadata!(name)
            end
        end
        Libdl.dlclose(handle_i32)
        Libdl.dlclose(handle_f64)
    end
end

# #279 follow-up: the in-memory hit re-registers a library's volatile tables.
# The existence check and the registration must be one transaction, or an
# unload racing between them leaves metadata and `CURRENT_LIB[]` pointing at a
# library that is no longer in `RUST_LIBRARIES`.
@testset "#279: re-registering an unloaded library is refused" begin
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping unload-race test"
        return
    end

    expanded = RustCall.expand_inline("""
    #[julia]
    pub fn raced_probe(x: i32) -> i32 { x + 2 }
    """)
    path = RustCall.compile_rust_to_shared_lib(expanded.source)
    lib_name = "test279_raced_" * string(hash(path), base = 16)
    handle = Libdl.dlopen(path, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
    previous_current = RustCall.get_current_library()

    try
        RustCall._register_manifest(expanded, lib_name; handle = handle, set_current = false)
        @test RustCall.exported_symbol(lib_name, "raced_probe") == "rustcall_raced_probe"

        # The library goes away between a caller's `haskey` and its
        # re-registration; the guarded call must decline rather than register
        # metadata for a name that is no longer loaded.
        RustCall.unload_library(lib_name)
        @test !haskey(RustCall.RUST_LIBRARIES, lib_name)
        @test !RustCall._register_manifest(expanded, lib_name; require_loaded = true)

        # Nothing was left behind, and CURRENT_LIB does not dangle.
        @test RustCall.exported_symbol(lib_name, "raced_probe") == "raced_probe"
        @test RustCall.get_function_return_type(lib_name, "raced_probe") === nothing
        @test RustCall.get_current_library() != lib_name

        # Without the guard the caller is the one publishing the handle, which
        # is still allowed and still atomic.
        handle2 = Libdl.dlopen(path, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
        @test RustCall._register_manifest(expanded, lib_name; handle = handle2, set_current = false)
        @test RustCall.exported_symbol(lib_name, "raced_probe") == "rustcall_raced_probe"
    finally
        haskey(RustCall.RUST_LIBRARIES, lib_name) && RustCall.unload_library(lib_name)
        lock(RustCall.REGISTRY_LOCK) do
            RustCall.clear_library_metadata!(lib_name)
            RustCall.CURRENT_LIB[] = previous_current
        end
    end
end

# #279 follow-up: a return-type hint must never outlive the library that
# registered it. There is no name-only table, so clearing or rebuilding a
# library cannot leave its type answering for anyone else's function of the
# same name.
@testset "#279: return-type hints do not outlive their library" begin
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping stale return-type test"
        return
    end

    expanded_a = RustCall.expand_inline("""
    #[julia]
    pub fn stale_probe(x: i32) -> i32 { x }
    """)
    expanded_b = RustCall.expand_inline("""
    #[julia]
    pub fn stale_probe(x: i32) -> f64 { x as f64 }
    """)
    # The rebuilt A returns `Result`, for which no hint is recorded at all:
    # an untyped call must fall through to inference, never to A's old `Int32`.
    expanded_a2 = RustCall.expand_inline("""
    #[julia]
    pub fn stale_probe(x: i32) -> Result<i32, i32> { Ok(x) }
    """)

    path_a = RustCall.compile_rust_to_shared_lib(expanded_a.source)
    path_b = RustCall.compile_rust_to_shared_lib(expanded_b.source)
    path_a2 = RustCall.compile_rust_to_shared_lib(expanded_a2.source)
    lib_a = "test279_stale_a_" * string(hash(path_a), base = 16)
    lib_b = "test279_stale_b_" * string(hash(path_b), base = 16)
    handles = [Libdl.dlopen(p, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
               for p in (path_a, path_b, path_a2)]

    try
        RustCall._register_manifest(expanded_a, lib_a; handle = handles[1], set_current = false)
        RustCall._register_manifest(expanded_b, lib_b; handle = handles[2], set_current = false)
        @test RustCall.get_function_return_type(lib_a, "stale_probe") === Int32
        @test RustCall.get_function_return_type(lib_b, "stale_probe") === Float64

        # Clearing A leaves B answering for itself, and A answering for nobody.
        RustCall.unload_library(lib_a)
        @test RustCall.get_function_return_type(lib_b, "stale_probe") === Float64
        @test RustCall.get_function_return_type(lib_a, "stale_probe") === Float64 ||
              RustCall.get_function_return_type(lib_a, "stale_probe") === nothing

        # A comes back declaring `Result`, so it records no hint. The old
        # `Int32` must be gone: what answers is B's own type or nothing, never
        # the value A itself last wrote.
        RustCall._register_manifest(expanded_a2, lib_a; handle = handles[3], set_current = false)
        @test RustCall.get_function_return_type(lib_a, "stale_probe") !== Int32
        @test RustCall.get_function_return_type(lib_b, "stale_probe") === Float64

        # And with B gone too, nothing is left to answer at all.
        RustCall.unload_library(lib_b)
        @test RustCall.get_function_return_type(lib_a, "stale_probe") === nothing
    finally
        # Every handle here was published into RUST_LIBRARIES, and
        # `unload_library` dlcloses what it removes — closing them again here
        # would be a double close.
        for name in (lib_a, lib_b)
            haskey(RustCall.RUST_LIBRARIES, name) && RustCall.unload_library(name)
            RustCall.clear_library_metadata!(name)
        end
    end
end

# #279 follow-up: `_alias_reloaded_library` deliberately leaves one handle in
# `RUST_LIBRARIES` under two names. The cross-library fallback must not count
# that as two candidates, or every multi-block precompiled module raises the
# ambiguity error after any identity change.
@testset "#279: an aliased handle is one candidate, not an ambiguity" begin
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping alias ambiguity test"
        return
    end

    expanded_one = RustCall.expand_inline("""
    #[julia]
    pub fn aliased_block_fn(x: i32) -> i32 { x * 2 }
    """)
    expanded_two = RustCall.expand_inline("""
    #[julia]
    pub fn sibling_block_fn(x: i32) -> i32 { x + 3 }
    """)
    path_one = RustCall.compile_rust_to_shared_lib(expanded_one.source)
    path_two = RustCall.compile_rust_to_shared_lib(expanded_two.source)
    actual = "test279_amb_actual_" * string(hash(path_one), base = 16)
    stored = "test279_amb_stored_" * string(hash(path_one), base = 16)
    sibling = "test279_amb_sibling_" * string(hash(path_two), base = 16)
    handle_one = Libdl.dlopen(path_one, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
    handle_two = Libdl.dlopen(path_two, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)

    try
        RustCall._register_manifest(expanded_one, actual; handle = handle_one, set_current = false)
        RustCall._register_manifest(expanded_two, sibling; handle = handle_two, set_current = false)
        # The reload path: one handle, two names.
        RustCall._alias_reloaded_library(Main, stored, actual)
        @test RustCall.RUST_LIBRARIES[stored][1] == RustCall.RUST_LIBRARIES[actual][1]

        # Looking the aliased block's function up from the *sibling* block has
        # to fall back across libraries and finds it twice, through the same
        # handle. That is one function, not a conflict.
        ptr_via_sibling = RustCall.get_function_pointer(sibling, "aliased_block_fn")
        ptr_direct = RustCall.get_function_pointer(actual, "aliased_block_fn")
        ptr_via_alias = RustCall.get_function_pointer(stored, "aliased_block_fn")
        @test ptr_via_sibling == ptr_direct == ptr_via_alias
        @test RustCall.call_rust_function(ptr_via_sibling, Int32, Int32(4)) == Int32(8)

        # And the other block's function still resolves from the aliased names.
        ptr_sibling_fn = RustCall.get_function_pointer(stored, "sibling_block_fn")
        @test RustCall.call_rust_function(ptr_sibling_fn, Int32, Int32(4)) == Int32(7)

        # Two genuinely different libraries exporting one name are still refused.
        expanded_clash = RustCall.expand_inline("""
        #[julia]
        pub fn aliased_block_fn(x: i32) -> i32 { x * 5 }
        """)
        path_clash = RustCall.compile_rust_to_shared_lib(expanded_clash.source)
        clash = "test279_amb_clash_" * string(hash(path_clash), base = 16)
        handle_clash = Libdl.dlopen(path_clash, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
        try
            RustCall._register_manifest(expanded_clash, clash; handle = handle_clash, set_current = false)
            @test_throws ErrorException RustCall.get_function_pointer(sibling, "aliased_block_fn")
        finally
            haskey(RustCall.RUST_LIBRARIES, clash) && RustCall.unload_library(clash)
            RustCall.clear_library_metadata!(clash)
        end
    finally
        # `stored` and `actual` are two names for one handle: drop the alias
        # without unloading, so the handle is dlclosed exactly once (by
        # `unload_library(actual)`), and never again here.
        lock(RustCall.REGISTRY_LOCK) do
            delete!(RustCall.RUST_LIBRARIES, stored)
        end
        RustCall.clear_library_metadata!(stored)
        for name in (actual, sibling)
            haskey(RustCall.RUST_LIBRARIES, name) && RustCall.unload_library(name)
            RustCall.clear_library_metadata!(name)
        end
    end
end

# #279 follow-up: the pointer and the return type must come from the same
# library. A library whose `f` returns `Result` records no hint on purpose;
# another library's primitive hint for the same name would call it with the
# wrong ABI.
@testset "#279: a return-type hint is never borrowed across libraries" begin
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping cross-library ABI test"
        return
    end

    # A: `Result` return, so no hint is registered at all.
    expanded_a = RustCall.expand_inline("""
    #[julia]
    pub fn abi_probe(x: i32) -> Result<i32, i32> { Ok(x) }
    """)
    # B: a plain f64 return, which does register a hint.
    expanded_b = RustCall.expand_inline("""
    #[julia]
    pub fn abi_probe(x: i32) -> f64 { x as f64 }
    """)
    path_a = RustCall.compile_rust_to_shared_lib(expanded_a.source)
    path_b = RustCall.compile_rust_to_shared_lib(expanded_b.source)
    lib_a = "test279_abi_a_" * string(hash(path_a), base = 16)
    lib_b = "test279_abi_b_" * string(hash(path_b), base = 16)
    handle_a = Libdl.dlopen(path_a, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
    handle_b = Libdl.dlopen(path_b, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)

    try
        RustCall._register_manifest(expanded_a, lib_a; handle = handle_a, set_current = false)
        RustCall._register_manifest(expanded_b, lib_b; handle = handle_b, set_current = false)

        # A records nothing; B's Float64 must not leak into A.
        @test RustCall.get_function_return_type(lib_a, "abi_probe") === nothing
        @test RustCall.get_function_return_type(lib_b, "abi_probe") === Float64

        # The pointer and the owning library agree, for each library.
        ptr_a, owner_a = RustCall._resolve_call(lib_a, "abi_probe")
        ptr_b, owner_b = RustCall._resolve_call(lib_b, "abi_probe")
        @test owner_a == lib_a && owner_b == lib_b
        @test ptr_a != ptr_b

        # An untyped call into B uses B's own hint.
        @test RustCall._rust_call_dynamic(lib_b, "abi_probe", Int32(3)) == 3.0

        # An untyped call into A must not come back as B's `Float64`: with no
        # hint it falls through to inference, which for a `CResult_abi_probe`
        # return cannot produce a Float64.
        untyped_a = try
            RustCall._rust_call_dynamic(lib_a, "abi_probe", Int32(3))
        catch error
            error
        end
        @test !(untyped_a isa Float64)
    finally
        # `unload_library` dlcloses both handles; do not close them again.
        for name in (lib_a, lib_b)
            haskey(RustCall.RUST_LIBRARIES, name) && RustCall.unload_library(name)
            RustCall.clear_library_metadata!(name)
        end
    end
end

# #279 follow-up: an external crate is scanned leniently — only target
# predicates are decided, because its own features and build script are not
# RustCall's to evaluate — so mutually exclusive `#[cfg(feature = ...)]`
# variants of one `#[julia] fn` both reach the registry. Source order is not
# evidence of which one was built, so no return type may be registered for
# them; a wrong primitive hint would be a wrong ABI. (Deciding the crate's
# features exactly belongs to #277 Phase B.)
@testset "#279: ambiguous cfg variants register no return type" begin
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping ambiguous cfg variant test"
        return
    end

    mktempdir() do dir
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "Cargo.toml"), """
        [package]
        name = "cfg_variant_probe"
        version = "0.0.0"
        edition = "2021"

        [features]
        a = []

        [lib]
        crate-type = ["cdylib"]
        """)
        write(joinpath(dir, "src", "lib.rs"), """
        use juliacall_macros::julia;

        #[cfg(feature = "a")]
        #[julia]
        pub fn variant_probe() -> i32 { 1 }

        #[cfg(not(feature = "a"))]
        #[julia]
        pub fn variant_probe() -> f64 { 1.0 }

        #[julia]
        pub fn unambiguous_probe() -> i32 { 2 }
        """)

        # The lenient scan the crate paths use keeps both variants.
        info = RustCall.scan_crate(dir)
        variants = filter(f -> f.name == "variant_probe", info.julia_functions)
        @test length(variants) == 2
        @test Set(f.return_type for f in variants) == Set(["i32", "f64"])
        @test all(f -> f.symbol == "rustcall_variant_probe", variants)

        lib_name = "test279_cfg_variant"
        try
            lock(RustCall.REGISTRY_LOCK) do
                RustCall._register_exported_symbols!(info.julia_functions, lib_name)
            end

            # The symbol is unambiguous, so it is recorded ...
            @test RustCall.exported_symbol(lib_name, "variant_probe") ==
                  "rustcall_variant_probe"
            # ... but neither variant's return type is, so an untyped call
            # falls through to inference rather than to the wrong ABI.
            @test RustCall.get_function_return_type(lib_name, "variant_probe") === nothing
            @test RustCall.get_function_return_type(lib_name, "rustcall_variant_probe") === nothing

            # A function with only one variant is unaffected.
            @test RustCall.exported_symbol(lib_name, "unambiguous_probe") ==
                  "rustcall_unambiguous_probe"
            @test RustCall.get_function_return_type(lib_name, "unambiguous_probe") === Int32
        finally
            RustCall.clear_library_metadata!(lib_name)
        end
    end
end

# ---------------------------------------------------------------------------
# #276 Phase B: the FFI contract is the only type decision. These are the
# regression tests for the three bugs that came out of having five of them.
# ---------------------------------------------------------------------------

# #245: `rustcall_core` accepts `i128`, `u128` and `char`, and generates a
# wrapper for them — but every Julia table stopped at 13 primitives, so the
# generated `ccall` slot was `Any` (or the `Int64` guess). Same for a `u16`
# struct field, which `src/structs.jl` read as `Any` while a free function read
# it as `UInt16`.
@testset "#245: every type rustcall_core accepts crosses correctly" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        rust"""
        #[julia]
        pub fn rc245_add_i128(a: i128, b: i128) -> i128 { a + b }
        #[julia]
        pub fn rc245_add_u128(a: u128, b: u128) -> u128 { a + b }
        #[julia]
        pub fn rc245_upper(c: char) -> char { c.to_ascii_uppercase() }
        #[julia]
        pub struct Rc245Small { a: u16, b: i8, c: usize }
        impl Rc245Small {
            pub fn new(a: u16, b: i8, c: usize) -> Self { Self { a, b, c } }
        }
        """

        # 128-bit integers survive the boundary intact, which they cannot do
        # through an `Any` or `Int64` slot.
        @test rc245_add_i128(Int128(1) << 100, Int128(3)) === (Int128(1) << 100) + 3
        @test rc245_add_u128(UInt128(1) << 120, UInt128(7)) === (UInt128(1) << 120) + 7

        # Rust `char` travels as its C slot, a `UInt32` code point. It is
        # converted, never reinterpreted from Julia's left-aligned UTF-8 `Char`.
        @test rc245_upper('a') === UInt32('A')
        @test Char(rc245_upper('q')) === 'Q'
        @test RustCall.ffi_ccall_type("char") === UInt32
        @test RustCall.ffi_surface_type("char") === Char

        # Small integer and platform-sized struct fields read as themselves.
        small = Rc245Small(UInt16(65535), Int8(-3), UInt(9))
        @test small.a === UInt16(65535)
        @test small.b === Int8(-3)
        @test small.c === Csize_t(9)
    end
end

@testset "#245: an unannotated usize return is not the Int64 guess" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        code = "#[no_mangle] pub extern \"C\" fn rc245_usize_len() -> usize { 7 }"
        lib = RustCall._compile_and_load_rust(code, "test_regressions", 0)
        value = RustCall._rust_call_dynamic(lib, "rc245_usize_len")
        @test value === Csize_t(7)
        @test RustCall.get_function_return_type(lib, "rc245_usize_len") === Csize_t
    end
end

# #246: a returned Rust `String` is a `(ptr, len, cap)` buffer the caller must
# hand back to the library that allocated it. It was read as a `Cstring` (the
# wrong shape) or as `Any` (no shape at all), and never released.
@testset "#246: a String field is an owned buffer on both wrapper flavours" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        info = only(RustCall.manifest_struct_infos(RustCall.extract_manifest("""
        use juliacall_macros::julia;
        #[julia]
        pub struct Rc246Counter { count: u32, name: String }
        """; mode = "crate")))

        # The manifest, not the spelling, says the getter is lowered.
        @test info.field_abis["name"] == "string"
        c = RustCall._ffi_field_return(info, "name", "String")
        @test RustCall.ffi_owned_string_return(c)
        @test c.ownership === :owned_by_rust
        @test c.free_symbol == "Rc246Counter_free_rust_string"

        # Both crate-path generators read it through the owned-buffer helper and
        # release it through the contract's symbol. On `main` this branch read
        # `call_rust_function(ptr, Any, ...)` and leaked.
        emitted = RustCall._emit_struct_code(info)
        @test occursin("_call_rust_owned_string_ptr", emitted)
        @test occursin("Rc246Counter_free_rust_string", emitted)
        @test !occursin("call_rust_function(func_ptr, Any", emitted)

        generated = string(RustCall._generate_property_accessors(info))
        @test occursin("_call_rust_owned_string_ptr", generated)
        @test occursin("Rc246Counter_free_rust_string", generated)

        # A plain field is unaffected.
        @test info.field_abis["count"] == ""
        @test RustCall.ffi_return_symbol_or_throw("u32", "", "Rc246Counter::count") === :UInt32
    end
end

@testset "#246: a String return is released, not leaked" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        rust"""
        #[julia]
        pub struct Rc246Buf { n: usize }
        impl Rc246Buf {
            pub fn new(n: usize) -> Self { Self { n } }
            pub fn make(&self) -> String { "x".repeat(self.n) }
        }
        """
        buf = Rc246Buf(UInt(65536))
        @test length(make(buf)) == 65536

        # 10^4 calls allocate 640 MB of Rust buffers in total. If the wrapper
        # did not hand each one back to `Rc246Buf_free_rust_string`, the
        # high-water mark would grow by that much; releasing keeps it flat.
        GC.gc()
        before = Sys.maxrss()
        total = 0
        for _ in 1:10_000
            total += length(make(buf))
        end
        GC.gc()
        growth = Sys.maxrss() - before
        @test total == 10_000 * 65536
        @test growth < 200 * 1024 * 1024

        # And the release really is the contract's symbol, resolved inside the
        # allocating library rather than spelled at the call site.
        m = only(mm for mm in RustCall.manifest_struct_infos(RustCall.expand_inline("""
        #[julia]
        pub struct Rc246Buf { n: usize }
        impl Rc246Buf {
            pub fn make(&self) -> String { "x".repeat(self.n) }
        }
        """).manifest)[1].methods if mm.name == "make")
        c = RustCall.ffi_return_contract(m.return_type; abi = m.return_abi, owner = "Rc246Buf")
        @test c.free_symbol == "Rc246Buf_free_rust_string"
        @test c.ownership === :owned_by_rust
    end
end

# #249: the free symbol is per-owner, so two libraries can both export
# `X_free_rust_string`. Picking it by name from a global table frees a buffer
# through the wrong allocator; it must be resolved inside the library that
# allocated the value.
@testset "#249: the free symbol is resolved inside the allocating library" begin
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping per-library free-symbol test"
    else
        source = n -> """
        #[julia]
        pub struct Rc249X { }
        impl Rc249X {
            pub fn new() -> Self { Self { } }
            pub fn label(&self) -> String { "$n".to_string() }
        }
        """
        expanded_a = RustCall.expand_inline(source("alpha"))
        expanded_b = RustCall.expand_inline(source("beta"))
        path_a = RustCall.compile_rust_to_shared_lib(expanded_a.source)
        path_b = RustCall.compile_rust_to_shared_lib(expanded_b.source)
        lib_a = "test249_a_" * string(hash(path_a), base = 16)
        lib_b = "test249_b_" * string(hash(path_b), base = 16)
        handle_a = Libdl.dlopen(path_a, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
        handle_b = Libdl.dlopen(path_b, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
        try
            lock(RustCall.REGISTRY_LOCK) do
                RustCall.RUST_LIBRARIES[lib_a] = (handle_a, Dict{String, Ptr{Cvoid}}())
                RustCall.RUST_LIBRARIES[lib_b] = (handle_b, Dict{String, Ptr{Cvoid}}())
            end
            RustCall._register_manifest(expanded_a, lib_a)
            RustCall._register_manifest(expanded_b, lib_b)

            # Both libraries export the same free symbol — the name alone
            # cannot say which allocator owns a buffer.
            free_a = RustCall.get_function_pointer(lib_a, "Rc249X_free_rust_string")
            free_b = RustCall.get_function_pointer(lib_b, "Rc249X_free_rust_string")
            @test free_a != free_b

            # The generated call passes the *library* alongside the symbol, so
            # each buffer is released by the library that allocated it.
            info_a = only(RustCall.manifest_struct_infos(expanded_a.manifest))
            m = only(mm for mm in info_a.methods if mm.name == "label")
            c = RustCall.ffi_return_contract(m.return_type; abi = m.return_abi,
                                             owner = info_a.name)
            @test c.free_symbol == "Rc249X_free_rust_string"

            ptr_a = RustCall.call_rust_function(
                RustCall.get_function_pointer(lib_a, "rustcall_Rc249X_new"), Ptr{Cvoid})
            ptr_b = RustCall.call_rust_function(
                RustCall.get_function_pointer(lib_b, "rustcall_Rc249X_new"), Ptr{Cvoid})
            @test RustCall._call_rust_owned_string(lib_a, "rustcall_Rc249X_label",
                                                   c.free_symbol, ptr_a) == "alpha"
            @test RustCall._call_rust_owned_string(lib_b, "rustcall_Rc249X_label",
                                                   c.free_symbol, ptr_b) == "beta"
        finally
            RustCall.unload_library(lib_a)
            RustCall.unload_library(lib_b)
        end
    end
end
