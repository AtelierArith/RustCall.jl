# Component tests loaded by test_regressions.jl.

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
        # A destructor that raises must not take the GC down (#136). Since
        # #277 Phase B4 the guard lives in the shared implementation
        # `RustCall.finalize_rust_object!` rather than being inlined into every
        # generated finalizer, and it *counts* the failure instead of logging
        # it: `@warn` allocates and can yield, and a finalizer may run while
        # the thread holds `REGISTRY_LOCK` (#249).
        @test occursin("rustcall′Base.finalizer(rustcall′RustCall.finalize_rust_object!, rustcall′obj)", code)
        src = read(joinpath(dirname(dirname(pathof(RustCall))), "src", "ffi", "structs.jl"), String)
        i = findfirst("function finalize_rust_object!", src)
        @test i !== nothing
        body = src[first(i):end]
        body = body[1:first(findfirst("\nend", body))]
        @test occursin("try", body)
        @test occursin("catch", body)
        @test occursin("FINALIZER_FREE_FAILURES", body)
        @test !occursin("@warn", body)
        @test RustCall.finalizer_failure_count() isa Int
    end

    @testset "Generated wrappers include null pointer checks (#138)" begin
        alive = (ptr = Ptr{Cvoid}(1),)
        freed = (ptr = Ptr{Cvoid}(0),)
        @test_nowarn RustCall._check_not_freed(alive, "TestType")
        # One implementation for inline and crate structs since #277 Phase B4,
        # so it raises RustCall's own exception rather than a bare `error()`.
        @test_throws RustCall.RustError RustCall._check_not_freed(freed, "TestType")
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
        @test RustCall.REGISTRY_LOCK isa ReentrantLock
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
        # #252: the compiler in the key is the one RustToolChain resolves, and
        # an unidentifiable compiler raises instead of becoming "unknown".
        @test !isdefined(RustCall, :_get_rustc_version)
        if RustCall.check_rustc_available()
            @test !isempty(RustCall.artifact_compiler_identity())
            @test !occursin("unknown", RustCall.artifact_compiler_identity())
        end
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
