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
        empty!(RustCall.FUNCTION_RETURN_TYPES)
        empty!(RustCall.FUNCTION_RETURN_TYPES_BY_LIB)

        code_i32 = "#[no_mangle] pub extern \"C\" fn same_name() -> i32 { 1 }"
        code_f64 = "#[no_mangle] pub extern \"C\" fn same_name() -> f64 { 1.0 }"

        RustCall._register_manifest(RustCall.expand_inline(code_i32), "lib_i32")
        @test RustCall.FUNCTION_RETURN_TYPES["same_name"] == Int32
        @test RustCall.get_function_return_type("lib_i32", "same_name") == Int32

        RustCall._register_manifest(RustCall.expand_inline(code_f64), "lib_f64")
        @test RustCall.FUNCTION_RETURN_TYPES["same_name"] == Float64
        @test RustCall.get_function_return_type("lib_i32", "same_name") == Int32
        @test RustCall.get_function_return_type("lib_f64", "same_name") == Float64
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

        # Dropping the alias must not disturb the library it pointed at.
        RustCall.clear_function_symbols!(stored)
        @test RustCall.exported_symbol(actual, "aliased_probe") == "rustcall_aliased_probe"
    finally
        for name in (stored, actual)
            lock(RustCall.REGISTRY_LOCK) do
                delete!(RustCall.RUST_LIBRARIES, name)
                RustCall.clear_function_symbols!(name)
            end
        end
        Libdl.dlclose(handle)
    end
end
