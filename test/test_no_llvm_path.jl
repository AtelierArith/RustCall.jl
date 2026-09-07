# #265 Phase 2: the LLVM IR integration path is gone.
#
# Phase 1 (#267) deprecated `@rust_llvm` and everything behind it; this file
# pins the removal so that none of it can quietly come back — not the macro,
# not the registries, not the source files, not the `LLVM.jl` dependency.

using RustCall
using Test
using TOML

const _NO_LLVM_ROOT = normpath(joinpath(@__DIR__, ".."))

@testset "The LLVM IR integration path is removed (#265)" begin

    @testset "no exported or internal name of the path survives" begin
        # The public surface Phase 1 deprecated, by name, so a user can grep
        # this list against the CHANGELOG.
        for name in (
                Symbol("@rust_llvm"), :_rust_llvm_call, :rust_call_generated,
                :compile_and_register_rust_function, :get_registered_function,
                :_get_registered_function, :RustFunctionInfo, :LLVM_FUNCTION_REGISTRY,
                :LLVMCodeGenerator, :get_default_codegen, :DEFAULT_CODEGEN,
                :generate_llvmcall_ir, :build_llvmcall_expr, :extract_function_ir,
                :julia_type_to_llvm_ir_string, :_julia_type_to_llvm_ir_string,
                :compile_rust_to_llvm_ir, :_compile_rust_to_llvm_ir,
                :load_llvm_ir, :_load_llvm_ir, :RustModule, :RUST_MODULES,
                :LLVM_REGISTRY_LOCK, :get_function, :list_functions,
                :get_function_signature, :_get_function_signature,
                :get_or_compile_function, :dispose_module,
                :llvm_type_to_julia, :julia_type_to_llvm,
                :sanitize_unsupported_llvm_ir_attributes,
                :parse_llvm_module_with_fallback, :_llvm_path_depwarn,
                :OptimizationConfig, :_optimization_config, :DEFAULT_OPT_CONFIG,
                :get_default_opt_config, :set_default_opt_config,
                :optimize_module!, :optimize_function!, :optimize_for_speed!,
                :optimize_for_size!, :optimize_balanced!,
                :get_optimization_stats, :verify_module,
                :print_module_ir, :print_function_ir,
                # Julia-side helpers that existed only for the path.
                :RUST_MODULE_REGISTRY, :get_rust_module, :_rust_module_key,
                :infer_function_types, :SignatureInferenceError,
                :get_cached_llvm_ir, :save_cached_llvm_ir,
                :llvm_to_julia_type, :julia_to_llvm_type, :llvm_policy,
            )
            @test !isdefined(RustCall, name)
        end
        @test Symbol("@rust_llvm") ∉ names(RustCall)
        @test !isdefined(RustCall, :LLVM)
    end

    @testset "the source files are gone" begin
        for file in ("llvmintegration.jl", "llvmcodegen.jl", "llvmoptimization.jl")
            @test !isfile(joinpath(_NO_LLVM_ROOT, "src", file))
        end
        # ...and nothing includes them.
        entry = read(joinpath(_NO_LLVM_ROOT, "src", "RustCall.jl"), String)
        @test !occursin("llvm", lowercase(entry))
    end

    @testset "LLVM.jl is not a dependency" begin
        project = TOML.parsefile(joinpath(_NO_LLVM_ROOT, "Project.toml"))
        @test !haskey(project["deps"], "LLVM")
        @test !haskey(project["compat"], "LLVM")
        docs = TOML.parsefile(joinpath(_NO_LLVM_ROOT, "docs", "Project.toml"))
        @test !haskey(docs["deps"], "LLVM")
    end

    @testset "no load policy is left for it" begin
        @test all(ctor -> ctor().name != "llvm-ir", RustCall.ALL_LOAD_POLICIES)
    end

    @testset "list_library_functions reads the manifest" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required"
        else
            lib = RustCall._compile_and_load_rust("""
            #[no_mangle]
            pub extern "C" fn no_llvm_listed_a(x: i32) -> i32 { x + 1 }

            #[julia]
            pub fn no_llvm_listed_b(x: i32) -> i32 { x + 2 }
            """, "test_no_llvm_path", 0)
            listed = RustCall.list_library_functions(lib)
            @test "no_llvm_listed_a" in listed
            @test "no_llvm_listed_b" in listed
            @test issorted(listed)
            @test isempty(RustCall.list_library_functions("no_such_library_#265"))
        end
    end
end
